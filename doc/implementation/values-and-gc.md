# Values and the garbage collector

This chapter describes how Titan values are represented in generated C (every
Titan type's C type, records, unions, Interface wrappers, and the module
userdata) and the rules the code generator follows so that those values stay
safe under Lua's garbage collector. It is the canonical home for rooting,
stack-slot, polling, and write-barrier rules. The translation-unit structure and
calling convention are in the [code generator overview](codegen-overview.md);
construct-by-construct translations are in
[code generator: constructs](codegen-constructs.md); Lua-side boundary checks
are in [Lua interop internals](lua-interop-internals.md); Array ownership,
boxing, length, and resize invariants are in [Dense Arrays](dense-arrays.md).

## Background: TValue, the Lua stack, and the GC

A **`TValue`** is Lua's boxed value: a value union (integer, float,
`GCObject*`, …) plus a type tag. Collectable objects (`TString`, `Table`,
`Udata`, `CClosure`) live on the heap, reached through `GCObject*` pointers
inside `TValue`s. The **Lua stack** is an array of slots owned by a
`lua_State`; `L->top.p` points one past the last live slot, and the collector
treats every slot below the top as a root. In 5.5 a stack slot is a `StkId`;
`s2v(slot)` views it as a `TValue *`.

Lua 5.5's collector is **non-moving**: collection never changes the address of
a heap object. The Lua stack is a separate resizable array. Stack growth or
shrinkage may relocate its slots, so a raw `StkId`/`TValue *` into that array
cannot survive such an operation, although the values it held and the heap
addresses they reference survive. Generated code therefore distinguishes
reachability roots from stack-position rebasing.

The standalone `lua` interpreter switches the collector to **generational**
mode at startup; other states, including Titan standalone executables, run the
incremental collector. Generated code must be correct for both. Minor
generational collections trace only roots and old objects explicitly marked as
modified, which is what write barriers are for. Two consequences drive this
chapter: every fresh allocation must acquire its own traced root immediately
(before another allocation or poll), and an unbarriered store of a collectable
value into an older object is a reliably reproducible use-after-free.

## The C type of every Titan value

### The `ctype` map

`ctype` (`titan-compiler/coder/values.lua`, delegating to `coder._raw_ctype`)
fixes the C type of each Titan type for locals, parameters, return values and
temporaries alike:

| Titan type | C type | Notes |
| --- | --- | --- |
| `integer` | `lua_Integer` | unboxed |
| `float` | `lua_Number` | unboxed |
| `boolean` | `int` | 0/1; 5.5 booleans carry no payload, truth lives in the tag |
| `nil` | `int` | always 0 |
| `string` | `TString*` | raw pointer to the collectable string object |
| `{T}` (Array) | `Table*` | internal backing Table; the Lua-visible value is its canonical proxy Udata |
| `{K:V}` (Map) | `Table*` | ordinary Lua table in both domains |
| `value` | `TValue` | a full boxed Lua value, held **by value** |
| function type | `TValue` | boxed callable; input/output tails change the callable type and native entry ABI, not the boxed representation |
| record, union, or Interface (`Type.Nominal`) | `Udata*` | the nominal value *is* this userdata |
| `T?` | `TValue`, or a native presence/value struct for C numeric bases | see [nominal storage](nominal-storage.md#exact-native-options-and-boxing) |
| `owned` C storage | its rendered C type | GC-bearing userdata |
| other foreign C types | the C type itself | ordinary pointers are borrowed and not GC objects ([FFI internals](ffi-internals.md)) |
| Lua-internal `Udata *` | `Udata *` | raw pointer to a full userdata; GC-bearing |
| Lua-internal `TValue` | `TValue` | boxed value copied by value; GC-bearing |

This is the central performance fact of the backend: Titan locals, parameters
and return values are ordinary C variables in their native, unboxed form. The
Lua stack is not the transport for values between Titan functions; it is used
only as a GC anchor (see [GC discipline](#gc-discipline-the-invariants)) and as
the VM calling convention on the generic call paths. `initval` gives each type
its zero value: `{ {0}, 0 }` (a nil `TValue`) for boxed values, `{0}` for
native numeric Options (absent) and C structs/unions, and `0` otherwise, so a
declared-but-unset temporary is never garbage.

Flexible input and output runs use the element-specific `TitanVargInteger`,
`TitanVargString`, … descriptors in `titan-runtime/titan.h`: an `lu_byte n_args`
count and a typed `args` pointer (the input start offset travels as a separate
`int _start` parameter). The descriptor and its C backing are generated C
storage and are never roots; see
[Calls](#calls-c-only-inputs-immediate-result-roots-and-vm-transport) for how
their elements stay alive.

### Conversion helpers

Three helper families mediate between C variables and `TValue` slots:

* `getslot(typ, dst, src)` (`coder/names.lua`) reads a `TValue *` into a C
  variable: `ivalue`, `fltvalue`, `ttistrue`, `tsvalue`, `hvalue`, `uvalue`
  (records, unions, non-nil `Udata *`), or a struct copy for `value`/Options/
  functions. A nil slot becomes NULL for `Udata *`.
* `setslot(typ, dst, src)` (`coder/values.lua`) writes a C value into a
  `TValue *`: `setivalue`, `setfltvalue`, `titan_setbvalue` (a `titan.h` macro;
  5.5 removed `setbvalue`), `setsvalue`, `sethvalue`, `setuvalue`, or
  `setobj2t`. For `Udata *` it emits `setuvalue` for a non-NULL pointer and nil
  for NULL, never a lightuserdata.
* `setboxed` and the matching unbox/mixed-read helpers (`coder/values.lua`)
  cross the representation domain. Records and unions already are their
  Lua-visible Udata, but an Array is not: boxing maps the internal backing
  `Table *` to its qualifier-exact canonical proxy (`titan_array_require_proxy`)
  and unboxing validates the target qualifier and recovers the backing. Map
  keys/values, `value`, generic calls, and Lua results use the boxed domain;
  typed slots and exact calls use the internal domain. See
  [Dense Arrays](dense-arrays.md#internal-and-boxed-representations).

C numeric slots are not handled by unchecked casts hidden inside these
helpers. The exact C scalar remains raw until a checker-owned plan requests a
Titan carrier or boxed slot. C-numeric `getslot`/strict-get paths use the
shared boxed predicate, native conversions use the checked numeric cast, and
`setslot` validates `lua_Integer`/`lua_Number` representability before
`setivalue`/`setfltvalue`. The cast and its non-raising `is` twin consume the
same target-profile predicate.

These helpers do not decide whether a conversion is legal. The checker attaches
an `AdjustmentPlan`, `GuardPlan`, `DynamicCoercionPlan`, or `WrittenCastPlan`;
the coder validates that plan and renders it into native-local,
`TValue`-destination, or mixed forms. Strict `value` projections, Array/Map
reads, and branded generic function calls share one tag-check family, while
genuine-Lua entries/writes and written casts share the separate dynamic family.
See [Type relations and boundary plans](type-relations-and-boundaries.md).

`types.is_gc` (`titan-compiler/types.lua`) decides which types need a traced
owner for any lifetime that crosses allocation: string, `value`, generic
parameter, function, Array, Map, record and nominal (record, union, or
Interface) values, C `TValue`, Lua-internal `Udata *`, `owned` C storage, and
`T?` when `T` is GC-bearing. A borrowed native C copy does not need a second
root while its existing owner remains live. Integers, floats, booleans, nil,
and ordinary foreign pointers need none.

### Array proxies and function closures

An Array is two stock-Lua objects in a strong cycle: a backing `Table` whose
array slot 0 holds the canonical proxy `Udata`, and the proxy whose user value
0 holds the backing (user value 1 holds the mutable writer closure, or nil for
a const Array). `titan_array_new` and `titan_const_array_new` build the cycle
with direct Lua-internal stores and barriers into one caller-provided traced
result slot, never through the public stack API. The complete protocol is in
[Dense Arrays](dense-arrays.md#representation-contract).

A Titan function value is a branded `CClosure` whose header holds the module
Udata, the canonical function-type tag, the native-entry pointer, and the
closure brand; captures follow and the strict entry is the final upvalue. The
layout and dispatch are in
[the overview](codegen-overview.md#closures-and-captured-variables); realized
callable-adjustment wrappers add one traced link to the immediate source
closure ([wrapper layout](closure-adjustment-wrappers.md#wrapper-layout)).
For the GC, closures are always filled while fresh-white and published
immediately; see [rule 3](#3-anchor-fresh-objects-before-the-next-allocation).

## Records: a single tagged Udata

A Titan record value is one Lua full userdata. Its metatable supplies nominal
identity; its dense uservalues trace only GC-bearing fields, and its raw C
payload holds native members. For `Point { x: float, y: float, name: string }`,
there are two native number members and one traced string slot. The record
constructor (`coderecord`, `coder/expressions.lua`) allocates with
`luaS_newudata(L, sizeof(<payload>), <nuv>)`, sets the metatable, and roots the
userdata in its stack slot before any field expression runs. Native field
access uses a generated C member; `name` uses UV index 0 with the ordinary back
barrier on writes.

Logical `Type.Field.index` values remain declaration-order indices, and
`Type.Record.nfields` is the total logical field count, not the UV count. The
public prefix, private layout, allocation, projections, union layouts, fresh
tails and binary reconstruction are in
[Native nominal storage](nominal-storage.md).

### Type identity: the metatable pointer

A nominal type's identity is its **metatable pointer**. Every full userdata has
a `metatable` field in its header, and each record, union, or Interface type
has exactly one metatable per Lua state, so two userdata carry the same type
exactly when their `metatable` fields are equal. There is no tag word, no C
static, and no per-type registry tag. Reading `_ud->metatable` is in bounds for
*any* full userdata, including payload-less module values and foreign-library
userdata, so the check is total; a tag stored in `getudatamem` would read past
the end of a zero-payload userdata.

The metatable, being a per-state heap object, cannot live in a C static: it is
cached in a `_mod` user value (`type2metatable`, `coder/names.lua`, allocates
the slot lazily; `_init` fills it), and the type check reads it from there.
`coderecorddec` and its union/Interface counterparts in `coder/module.lua`
register each metatable in three registry places (with `$TYPE` the fully
qualified type name):

| Registry key | Value | Used for |
| --- | --- | --- |
| `"Titan record $TYPE metatable"` (`union`/`interface` likewise) | the metatable (`luaL_newmetatable`) | wiring `_mod` user values; `__metatable` is protected with the string `"Titan record $TYPE"` |
| `TITAN_METATABLES_KEY` | table mapping `$TYPE` to metatable | global discovery of nominal metatables across modules |
| the metatable pointer itself (`lua_rawsetp`) | the FQTN string | the *reverse* map, metatable to name, for error messages |

Each nominal metatable also carries runtime metadata under lightuserdata keys
defined in `titan-runtime/titan/ffi.h`: `TITAN_BRAND` maps to the kind integer
(`TITAN_RECORD` 3, `TITAN_UNION` 4, `TITAN_INTERFACE` 5; Arrays use 1/2 and
owned C storage 6), `TITAN_MT_TYPE` to the serialized type descriptor,
`TITAN_MT_MEMBERMAP` to the member map, `TITAN_MT_STATICS` to the static
namespace, and `TITAN_MT_MOD` to the declaring module. Unions add
`TITAN_MT_PAYLOAD` (see [nominal storage](nominal-storage.md)); reflection and
generated codecs use `TITAN_MT_PROJECT`, `TITAN_MT_CONSTRUCT`,
`TITAN_MT_PUBLIC`, and `TITAN_MT_CODEC`.

Metatables that Titan creates on first use and may need to retry are built
off-registry: the shared Array proxy pair (`titan-runtime/titan.c`,
`TITAN_ARRAY_METATABLE_PAIR`), generated owned-C metatables
(`titan-compiler/coder/generate.lua`), and the private `titan.coroutine` owner
metatable (`titan/coroutine.titan`). Each is fully initialized before it is
stored in the registry, and a pre-existing non-table entry is an error. Do not
initialize conditionally on `luaL_newmetatable`'s return value: that call
publishes a minimally initialized entry first, so an allocation error during
later setup would leave a partial metatable that a retry trusts. Generated
record, union and Interface metatables call `luaL_newmetatable`
unconditionally during the module's first `_init`, so they do not have this
skip-on-retry hazard; module initialization as a whole is still not
transactional.

### Wrap and unwrap at the boundary

A record *is* its userdata, so the boundary has nothing to swap: Titan and Lua
hold the same object. `setboxed` for a record hands Lua the udata directly
(after a nil check for `T?`). Coming back, the nominal case of `checkandget`
(`coder/values.lua`) compares the udata's metatable against the expected
metatable cached in `_mod` (`coder._nominal_metatable_expr`) and uses the udata
as the value:

```c
if (TITAN_LIKELY(ttisfulluserdata($EXP))) {
  Udata* _ud = uvalue($EXP);
  if (TITAN_LIKELY(_ud->metatable == $MT)) {
    $VAR = _ud;
  } else {
    /* luaH_get(hvalue(&G(L)->l_registry), metatable pointer) for the found name */
    $THROWUNKNOWN or $THROWNAMED
  }
} else { $THROWPRIM }
```

All three failure arms raise `file:line:col: type error, expected %s but found
%s`, with the expected name printed as the FQTN and the found name taken from
the reverse metatable-to-name registry entry when the value is some *other*
Titan nominal, or from `lua_typename` for a non-userdata. The lookup uses
`luaH_get` directly on `G(L)->l_registry`, so it does not push or pop Lua stack
slots. A userdata without a reverse entry reports the static name `userdata`; it
neither consults `__name` nor invokes `__tostring`. `spec/coder/coder_spec.lua`
asserts both `expected test.Rec but found test.Point` and
`expected test.Rec but found number`, and proves that an unknown userdata's
`__tostring` is not called. Interface targets use a separate branch that can
also accept a compiler-witnessed metatable entry; see
[Interfaces](interfaces.md).

## Unions: native tag and independently stored parts

A Titan union is one `Udata *`, with a distinct per-union metatable as its
nominal identity. Each variant has its own generated payload struct and dense
traced-slot count. Every payload starts with an actual common tag-header
subobject containing the absolute variant tag, so even an empty variant needs
no UV slots.

Parts use the same physical classification as record fields. Non-GC scalars,
eligible fixed aggregates and arrays, and fresh const tails occupy native
storage; traced values occupy dense UV slots. An Array part retains its internal
`Table *` backing in its assigned UV, without boxing a Lua proxy. Direct C
functions remain ineligible, while C function pointers have native scalar
storage. Storage eligibility is separate from `has_tvalue_representation`;
embedding an aggregate does not make it generally boxable.

Construction (`coder._codeunioninit`) roots the final userdata before
initializing its stored fields, and traced stores apply `luaC_barrierback`.
`case` materializes the union once, reads the common tag header, and projects
each checked binding through the selected variant's storage plan. Logical
1-based part indices are independent of native member names and UV indices. No
tag or part is exposed as an ordinary Lua member, and union `__newindex` always
raises. Boxing into `value` keeps the same userdata, and unboxing compares the
exact union metatable just as a record check does.

## Interface wrappers

An Interface value is a full `Udata` whose metatable is the exact nominal
Interface identity. Its payload is a declaration-order array of
`TitanInterfaceMethod` function pointers, copied from a pair array in the
emitting module's native payload, and it has `2 + field_count` traced user
values: the emitting module's Udata, the concrete receiver, and
target-typed field snapshots. The payload holds no GC graph; every collectable
user-value store needs an ordinary Udata back barrier. Field-only wrappers have
zero payload bytes. The complete layout and dispatch contract is in
[Interfaces](interfaces.md#wrapper-representation).

For every pair whose static wrapper construction is emitted, initialization
may also store a one-upvalue witness closure in the concrete metatable under
the target Interface metatable object. Both key and closure are traced table
entries; the closure retains the emitting module, whose uservalues retain any
imported concrete owner and cached metatables. This is ordinary Lua
reachability, not a new root table or untraced cache.

Wrapper allocation follows [rule 3](#3-anchor-fresh-objects-before-the-next-allocation):
the concrete source is frozen once in an untraced C temporary while its ordinary
provenance remains live, and the new Udata receives its own root before its
metatable and traced edges are published. The lowering treats `luaS_newudata`
as a stack-rebase point and restores `_base` from `_base_off` immediately after
allocation (`coder/interfaces.lua`). When a witness is called, its concrete input
already occupies a traced argument slot; the new wrapper replaces that slot
before publication, and user value 1 then retains the input. Field adjustments
use traced temporaries and store each snapshot with a barrier before
publication.

## The module userdata

Each module instance is one `Udata`, `_mod`, passed to every generated native
function. It is the value `require` returns; there is no Lua-facing module
table. `_init` allocates it with
`luaS_newudata(L, sizeof(<prefix>native_data), NUPVALS)`.

The payload begins with `TitanModuleData`, whose immutable symbol resolver
identifies the code supplying this canonical logical module. The remaining
native fields cache dependency function pointers, public slot numbers,
canonical callable tags, and Interface implementation arrays for this Lua
state. They contain no collectable values; dependency modules, metatables,
canonical closures, Array writers, and variables live in traced uservalues.
Mutable bindings are never shared in file-global C storage between Lua states.
The uservalue order is in
[User-value allocation](codegen-overview.md#user-value-allocation).

Reading a module variable is `getslot` on `&_mod->uv[i].uv`; writing a GC-able
one is `setslot` plus `luaC_barrierback(L, obj2gco(_mod), slot)`. An imported
module's variable is written through `_imod = uvalue(&_mod->uv[MOD].uv)` with the
barrier on `_imod`. All member access from Lua flows through a metatable
installed on the `Udata` itself
([Lua interop internals](lua-interop-internals.md)).

## GC discipline: the invariants

Titan shares Lua's collector: there is no Titan heap and no reference counting.
Generated function bodies allocate through Lua internals: `luaH_new` and
`luaH_resizearray` (Maps), `luaS_new`/`luaS_newlstr`/`luaS_createlngstrobj`
(strings), `luaF_newCclosure` (closures and wrappers), `luaS_newudata` (records,
unions, Interface wrappers, module state), `luaC_newobj` through the preamble's
`titan_new_udata_object` (capture boxes and vararg payloads; it keeps the
allocating call out of `gco2u`, whose operand `-DLUAI_ASSERT` evaluates twice), and
runtime helpers such as `titan_array_new`. Module initialization also uses the
public API (`lua_pushcclosure`, `luaL_newmetatable`). Generated code runs
*outside* the Lua VM: it does not pass through `luaD_call`, keeps values in C
variables the collector cannot see, and never hits the VM's own GC polling. The
coder therefore maintains five invariants: 1–3 keep values *visible*, 4 keeps
the collector *running*, 5 keeps old objects *honest*.

### 1. The function frame: reserved, nil-initialized stack slots

A function whose body needs `nslots > 0` anchor slots gets this preamble
(`codefuncdec`, `coder/declarations.lua`):

```c
luaC_checkGC(L);
/* function preamble: reserve needed stack space */
titan_ensure_stack(L, $NSLOTS);
StkId _base = L->top.p;
L->top.p += $NSLOTS;
for(StkId _s = L->top.p - 1; _base <= _s; _s--) {
    setnilvalue2s(_s);
}
```

A function with no slots declares only `StkId _base = L->top.p;`. When the
whole body is a function-level `catch` (`ctx.entry_try`), the entry
`luaC_checkGC` moves inside that protected body so an emergency-GC allocation
failure lands in the Titan catch rather than unwinding across a native caller.

`titan_ensure_stack` (`titan-compiler/cpreamble.lua`) is a translation-unit-local
helper that calls Lua's internal raising `luaD_checkstack` and then extends
`L->ci->top.p` as the public API would. Every generated path that reserves
capacity before raw `L->top.p` writes calls it, so generated code never
continues to a raw push or slot write without capacity. Slots are
nil-initialized so a collection arriving before a slot's first real store sees
nil rather than stack garbage. Every generated stack-slot nil write uses
`setnilvalue2s`; stores into non-stack `TValue` locals keep `setnilvalue`.

Slots are addressed through the saved stack offset, never through a cached
pointer: `newslot`/`reserveslot` (`coder/flow.lua`) return
`s2v(restorestack(L, _base_off) + k)` and mark the function `uses_base_off`.
`pushd`/`popd` save and restore the depth around blocks and loop bodies so
sibling scopes reuse slots, and `nslots` records the high-water mark that sizes
the preamble. A return through the native ABI restores `L->top.p = _base`
before its C `return` (`codereturn`); a return routed through `finally` reaches
that reset after the pending action, and an
[immediate function](immediate-functions.md)'s inline return never resets the
containing frame. The module `_init`'s variable-initializer section reserves
and nil-initializes its slots the same way when it needs any, without an entry
GC poll.

### 2. Home roots, shadow slots, and borrowed C copies

A GC-bearing value that must live across allocation has a traced **home**: a
local shadow slot, module/record/container field, native-result slot, or another
GC object. `newtmp(ctx, typ, true)` (`coder/flow.lua`) creates a C temporary
`_tmp_N` plus a reserved stack slot when the temporary itself owns that
lifetime; `coder._codeinitializeddecl` does the same for used locals. Native
call sequencing is deliberately different: `coder._freeze_code` may copy a
callee, receiver, fixed argument, or variadic element into an untraced C
temporary for lexical order, but it never publishes a tracing-only
call-activation slot. Fresh allocations and native results already acquired
their mandatory roots; other inputs retain their ordinary semantic or VM homes.
For

```titan
function greet(s: string): string
    local t: string = s
    return t
end
```

the generated body contains:

```c
TString* _local_t_1;
_local_t_1 = _param_s;
/* update slot */
setsvalue(L, s2v((restorestack(L, _base_off) + 0)), _local_t_1);
```

The slot is refreshed at the declaration and at **every assignment** to the
local. Mutable C out-parameters additionally use the handoff rules below.
Parameters (including method `self`) get a slot only when the body assigns to
them or the checker marks them for spill across a catchable call. That is a
semantic local/spill home, not argument transport; otherwise the parameter
remains only its native C formal and its reachability comes from the input's
existing provenance. Module variables need no shadow: their `_mod` user value is
itself GC-visible.

A local roots its value from its declaration until its block ends, whether or
not anything reads it:

- An assignment to a GC-bearing local or parameter makes the checker mark the
  declaration `_used` (`Ast.StatAssign`, `checker/statements.lua`), so the
  variable has the slot above and the assignment stores into it. Otherwise a
  value assigned inside an inner block would be held only by that block's
  temporaries, and an owner declared in the outer block could not keep a
  buffer alive for a raw pointer that is used after the inner block.
- A local that is declared and then neither read nor assigned has no C
  variable and no slot of its own. The traced temporary that materialized its
  initializer holds the value until the block ends: `coder._codeadjustedfixed`
  creates it for every delivered initializer, and the `Ast.StatDecl` branch
  for a statement that also declares automatic C storage calls
  `materialize_code` for its GC-bearing initializers.

This keeps a value alive; it does not release one early. Assigning `nil`
clears the local's slot, but a temporary of a block that is still open can
hold the old value until that block ends.

#### Mutable GC out-parameters

A recovery-sensitive exact Lua `TValue` or `Udata *` local/parameter whose
mutable C address is exposed has a canonical volatile C home **and** its
existing traced Lua slot. The C home keeps the actual in-call writes; the
slot supplies reachability. Neither replaces the other.

`mutable_out_anchor` publishes a foreign call's current out-values immediately
after a normal return and stack rebasing. Ordinary Titan calls publish their
tracked GC out-values at the same handoff. If the callee exits nonlocally,
`coder._spill_address_roots` publishes every active canonical GC home at the
error landing, **before** Lua-frame close, `__close`, unwind helpers or any
other recovery action that can collect. These are nonallocating `setslot`
stores through the restored stack offset, without a heap barrier or new owner.
The landing must not reload the prior slot into the C home: doing so would
lose the fresh value or reinstate a cleared owner. A cleared home publishes
nil, so the old object can become collectable during close.

Defer-tail predeclarations initialize these C homes to nil/NULL and reserve
their root slots before an earlier protected region can fail. Normal locals,
named parameters and lambda parameters use the same home rule.

Foreign code still roots fresh objects through the complete call/error
handoff, just as it does before a normal out-value anchor. This mechanism
does not infer raw-pointer aliases or make unrooted intermediate C objects
safe. The native aggregate-recovery fixture leaves a fresh root above a Lua
to-be-closed cell; close truncates that borrowed root before forcing a full GC,
so the caller's committed home root is required to preserve the caught value.

### 3. Anchor fresh objects before the next allocation

An allocation may raise and may run an emergency collection on allocator
failure; later allocations or explicit polls can collect an unpublished object.
Every successfully created object therefore receives its own traced root
immediately, before another allocation or poll:

- A record or union constructor roots the fresh udata in its stack slot before
  any field expression runs; each field store then uses the back barrier.
- A capture box (`newbox`, `coder/statements.lua`) is anchored in its own slot
  before its initial value is written, and a GC-bearing box's `uv[0]` is set to
  nil before anchoring.
- A string result (literals, concatenation, number-to-string) is stored to its
  temporary's slot immediately after creation.
- `titan_array_new` roots the backing in the caller's result slot before
  allocating the proxy and leaves the completed cycle there
  ([Dense Arrays](dense-arrays.md#runtime-construction)). Map constructors
  root their table and each key and value temp.
- A closure or callable wrapper is allocated with `luaF_newCclosure` at its
  final size, filled while fresh-white, and published into its traced result
  slot before anything else can allocate. No barrier is needed during that
  initialization. Source-closure construction then pays the allocation's debt
  with `luaC_checkGC` and restores `_base`; wrapper construction adds no local
  poll ([Closure adjustment wrappers](closure-adjustment-wrappers.md#roots-relocation-and-errors)).
  `luaF_newCclosure` can raise, including after an emergency collection, but
  does not shrink or move the stack.

### 4. `luaC_checkGC` at entry and at allocating loop tails

Because Titan-to-Titan calls never enter `luaD_call`, generated code polls the
collector itself:

- at function entry, as the first line of a slot-reserving preamble (see rule
  1 for the function-level `catch` case);
- at the tail of every `while`/`repeat`/numeric-`for` body **iff** the loop's
  condition plus body reserved slots, measured by the change in
  `ctx.allocations` across loop generation, followed by `_base` restoration;
- at the tail of every generic `for ... in` iteration, unconditionally;
- at the entry of a synthesized callable or Interface native adapter iff its
  frozen action graph can allocate a nested wrapper
  (`coder._adapter_actions_allocate`), before stack reservation, `_base`, and
  every raw stack pointer;
- after publishing a freshly allocated source closure;
- after a counted pointer-to-string copy (`ptr as string(n)`), whose string is
  published before the poll as `lua_pushlstring` would.

Every poll after `_base` exists is followed by
`_base = restorestack(L, _base_off)`. A step that reaches the atomic phase
traverses the running thread and may shrink its stack (`luaD_shrinkstack`),
moving it; a stale `_base` would then become `L->top.p` at the next native
return.

A pure-arithmetic loop carries no GC polling; an allocating Titan loop polls
once per iteration and cannot starve the collector.

### 5. Write barriers: back for userdata and tables, forward for closures

Lua's generational collector only re-traces old objects that announce they were
modified. The barrier depends on the *owner's* type: `Udata` and `Table`
traversal calls `genlink`, so the **back** barrier (re-greying the container)
is valid for them, whereas `CClosure` traversal does not, so a store into an
existing closure would need the **forward** barrier (recolouring the value).

**Back barrier, `luaC_barrierback(L, obj2gco(owner), value)`**, used for:

* record field assignment and record-literal field initialization;
* union payload initialization;
* module-variable writes, local (`obj2gco(_mod)`) and imported
  (`obj2gco(_imod)`), including writes from Lua through the module metatable's
  `__newindex`;
* record field writes from Lua through the record's `__newindex`;
* Array backing-slot stores, Map stores, and container-literal fills, gated on
  `types.is_gc` of the stored type. Array element stores barrier the backing
  Table, never its proxy. `titan_array_new` installs the proxy's backing and
  writer user values with direct stores followed by `luaC_barrierback` on the
  proxy, and barriers the backing's key-0 proxy link;
* Interface wrapper user values;
* mutation of a GC-bearing capture box, whose one traced user value is owned by
  a `Udata` (`box_write`).

Back-barrier sites pass `obj2gco(owner)`, not the owner's concrete pointer type.
The `obj2gco` operand must be a typed GC object pointer (`Udata *`, `Table *`,
…): under `-DLUAI_ASSERT` the macro reads its `tt` field, which an untyped
`void *` does not have.
Map raw stores go through `luaH_set`/`luaH_setint` (`set_table_entry_raw`,
`coder/statements.lua`): "The GC barrier for the stored value is the caller's
responsibility; new keys are barriered internally by the insertion code."

**Forward barrier, `luaC_barrier(L, owner, value)`.** Generated code never
stores into an existing closure: captures, the strict trailer, and wrapper links
are installed while the closure is fresh-white, and captured-and-assigned
variables live in boxes. The coder therefore emits no forward barrier today. A
future store into an existing closure's upvalue would need one.

Under the generational collector, getting any of this wrong is promptly fatal:
minor collections are frequent, and an unbarriered old-to-young store is a
use-after-free on the next one.

## Calls: C-only inputs, immediate result roots, and VM transport

The [calling convention](codegen-overview.md#the-titan-native-function-and-its-calling-convention)
separates native C transport from GC publication. A native fast call does
**not** establish a new tracing lifetime for its inputs.

* **Native inputs.** The caller evaluates left-to-right. Where later setup is
  effectful, it freezes the first-class callee, receiver, fixed arguments, and
  variadic elements in ordinary C temporaries (`ordered_call_args`,
  `coder/calls.lua`). Pure trailing reads may remain direct C expressions.
  Neither form writes a tracing-only Lua-stack slot. Fresh values retain the
  roots installed at allocation or at an earlier native-result handoff;
  established values retain their semantic module/record/container/local home
  or an upstream Lua VM argument slot. A raw `TitanVargX` and its C `args` array
  merely borrow those values and are never roots. Callable and Interface
  adapters follow the same rule and have an empty input-source root inventory.
  A newly allocated argument conversion is the one exception in the
  *destination*: the fresh wrapper gets its mandatory initial allocation root.

  Consequently the no-copy native protocol does not manufacture a lifetime
  after a program destroys an input's sole traced provenance while retaining
  only its raw C formal. Supporting that stronger case would require the third
  call-activation root that this protocol deliberately excludes.

* **Native returns.** The callee returns its first fixed result in C and writes
  later results through out-parameters without rooting them. Merely returning
  cannot run the collector, although the callee may have relocated the Lua
  stack. The caller therefore rebases first (`_base = restorestack(L,
  _base_off)`), performs any nonallocating raw-to-visible projection, and then
  publishes **every live GC-bearing native result immediately** into its
  caller-owned result slot before any later allocating work. This publication
  is required even for an identity conversion: a transitive callee's allocation
  root lies above its restored caller top and no longer owns the handoff. A
  freshly allocated converted callable/Interface value separately gets its own
  allocation root. For `two(): (integer, string)`, lowering schematically
  separates raw ABI holders from the visible projection:

```c
lua_Integer _abi_1 = 0;
TString *_abi_2 = NULL;                 /* raw out-param, not yet a root */
_abi_1 = test_\u2133_two_titan(L, _mod, NULL, &_abi_2);
_base = restorestack(L, _base_off);
_visible_1 = _abi_1;
_visible_2 = _abi_2;
setsvalue(L, s2v(restorestack(L, _base_off) + 0), _visible_2); /* immediate handoff */
```

* **Flexible runs.** Native input descriptors borrow the existing provenance
  above. Every live GC-bearing native output prefix uses bounded caller-owned C
  backing plus a parallel traced range: after rebasing and validating its count,
  the caller copies the complete live prefix into that range and clears it only
  after the sink consumes the run. Adapters do this for every live fixed/open
  source result, not only when a later action allocates. A converted
  destination range exists only when conversion allocates fresh
  callable/Interface values. Neither descriptor nor raw C array ever becomes a
  root.

The generic paths are intentionally different. A non-Titan Lua call and a
branded strict call push the callee/carrier and every actual argument because
Lua's VM stack is their calling convention; those are transport slots, not
native activation copies. `luaD_callnoyield` may resize the stack, so saved
offsets recover positions afterward. Its results remain rooted in VM result
slots while strict/dynamic conversion runs, then are copied into the same
consumer homes or caller-owned result ranges used by the native path. A Lua
entry calling a native body similarly reserves its result area first and boxes
every returned value there.

A pending `return` that crosses `finally` must keep its flexible count and every
GC-bearing element in traced storage while the `finally` body allocates; see
[pending actions](error-handling.md#pending-actions-for-finally).
