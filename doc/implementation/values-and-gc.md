# Values and the garbage collector

This chapter describes how Titan values are represented in the generated
C — every Titan type's C type, records in full detail, the module
userdata — and the discipline the code generator follows so that all of
those values stay safe under Lua's garbage collector. The structure of a
generated translation unit and the calling convention are covered in the
[code generator overview](codegen-overview.md); construct-by-construct
translations are in [code generator: constructs](codegen-constructs.md);
the Lua-side boundary checks in
[Lua interop internals](lua-interop-internals.md). Array-specific ownership,
boxing, length, and resize invariants are centralized in
[Dense Arrays](dense-arrays.md).

## Background: TValue, the Lua stack, and the GC

A **`TValue`** is Lua's boxed value: a small struct holding a value
union (integer, float, `GCObject*`, …) plus a type tag. Collectable
objects — strings (`TString`), tables (`Table`), userdata (`Udata`), C
closures (`CClosure`) — live on the heap, reached through `GCObject*`
pointers inside `TValue`s. The **Lua stack** is an array of `TValue`
slots owned by a `lua_State`; `L->top.p` points one past the last live
slot, and the collector treats every slot below the top as a root. (In
5.5 a stack slot is an `StkId`; `s2v(slot)` views it as a `TValue*`.)

Lua 5.5's collector is **non-moving**: collection never changes the address of
a string, table, userdata, closure, or other heap object. The Lua stack is a
separate resizable array. Stack growth or shrinkage may relocate its slots, so a
raw `StkId`/`TValue *` into that array cannot survive such an operation; Lua
copies the rooted values to the new stack, however, and their referenced heap
addresses remain stable. Generated code therefore distinguishes reachability
roots from stack-position rebasing.

The standalone `lua` 5.5 interpreter switches the collector to
**generational** mode at startup; freshly created states — including
Titan standalone executables — run the incremental collector, and
generated code must be correct for both. Generational mode runs
frequent *minor* collections that trace only the stack, other roots,
and old objects explicitly marked as modified — which is what *write
barriers* are for. Two consequences drive this chapter: every fresh
allocation must acquire its own traced root immediately (before another
allocation or poll), and an unbarriered store of a collectable value into an
older object is not a rare race
but a reliably reproducible use-after-free — see the
[Lua 5.5 migration report](../lua-5.5-migration.md) and the
[internals catalogue](../lua-5.3-to-5.5-internals.md) for the project's
history with exactly this.

## The C type of every Titan value

### The `ctype` map

`ctype` in `coder.lua` fixes the C type of each Titan type; it is used
for locals, parameters, return values and temporaries alike:

| Titan type | C type | Notes |
| --- | --- | --- |
| `integer` | `lua_Integer` | unboxed |
| `float` | `lua_Number` | unboxed |
| `boolean` | `int` | 0/1 — 5.5 booleans carry no payload, truth lives in the tag |
| `nil` | `int` | always 0 (`getslot` for nil yields the constant `0`) |
| `string` | `TString*` | raw pointer to the collectable string object |
| `{T}` (array) | `Table*` | internal backing Table; the Lua-visible value is its canonical proxy Udata |
| `{K:V}` (map) | `Table*` | ordinary Lua table in both domains |
| `value` | `TValue` | a full boxed Lua value, held **by value** |
| function type (`function (P..., ...: I): (R..., ...: O)`) | `TValue` | boxed callable value; input/output tails change the callable type and native entry ABI, not the boxed representation |
| record or union type (`Type.Nominal`) | `Udata*` | the nominal value *is* this userdata (below) |
| `T?` (option) | `TValue` | boxed: nil or the payload |
| foreign pointer except Lua `Udata *` | per `foreignctype` | e.g. `void*`, `char*`; ordinary borrowed pointers are not GC objects ([FFI internals](ffi-internals.md)) |
| Lua-internal `Udata *` | `Udata *` | raw pointer to the full userdata object; GC-bearing |
| Lua-internal `TValue` | `TValue` | boxed value copied by value; GC-bearing |

This is the central performance fact of the backend: Titan locals,
parameters and return values are ordinary C variables in their native,
unboxed form. The Lua stack is never the transport for values between
Titan functions — it is used only as a GC anchor, as described under
[GC discipline](#gc-discipline-the-invariants). The dynamic types
`value`, function types and `T?` are carried as `TValue` *by value*
(struct copy), still without touching the Lua stack except when the
function-value generic call path intentionally invokes Lua's call
machinery. `initval` gives each type its zero value — `{ {0}, 0 }` (a nil
`TValue`) for `value`, function values and options, `0` for everything
else — so a declared-but-unset temporary is never garbage (it
initializes `newtmp` temporaries and the Lua entry wrappers' argument
holders; plain locals are declared bare and assigned immediately).

Flexible input and output runs use the same element-specific
`TitanVargInteger`/`TitanVargString`/… descriptor structs: a byte-sized actual
count and a typed `args` pointer. The descriptor itself lives in generated C
storage and is not traced. Its C backing is never a root either. A native input
run borrows each element's existing provenance: a semantic variable/container
home, an initial allocation root, a prior native-result root, or an actual Lua
VM argument slot. The native call creates no element roots. Every live
GC-bearing native output run is copied into a caller-owned parallel traced range
immediately after return and rebasing, until its sink consumes it. A conversion
adds a separate destination range only for freshly allocated elements.

### Conversion helpers

Three helper families in `coder.lua` mediate between C variables and
`TValue` slots; all generated code goes through them:

* `getslot(typ, dst, src)` reads a `TValue*` into a C variable —
  `ivalue`, `fltvalue`, `ttistrue`, `tsvalue`, `hvalue`, `uvalue` (for
  records, unions, and non-nil `Udata *`), or a struct copy `*($SRC)` for
  `value`/options. A nil slot becomes NULL for `Udata *`.
* `setslot(typ, dst, src)` writes a C value into a `TValue*` —
  `setivalue`, `setfltvalue`, `titan_setbvalue` (a `titan.h` macro; 5.5
  removed `setbvalue` along with the boolean payload), `setsvalue`,
  `sethvalue`, `setuvalue` (for nominal values), `setobj2t` for
  `value`/options. For `Udata *`, it emits `setuvalue` for a non-NULL pointer
  and nil for NULL rather than boxing the pointer as lightuserdata.
* `setboxed(ctx, typ, dst, src)` and the corresponding unbox/mixed-read
  helpers cross a representation domain. Records and unions already are their
  Lua-visible Udata, but Arrays are not: boxing maps an internal backing
  `Table*` to its qualifier-exact canonical proxy Udata, while unboxing
  validates the target qualifier and recovers the backing. Map keys/values,
  `value`, generic calls, and Lua
  results use the boxed domain. Typed slots and exact calls retain the
  internal domain. This split replaces the old representation-blind
  `setwrapped`/`copyslotwrapped` model; see
  [Dense Arrays](dense-arrays.md#internal-and-boxed-representations).

C numeric slots are not handled by unchecked casts hidden inside these
helpers. The exact C scalar remains raw until a checker-owned plan requests a
Titan carrier or boxed slot. C-numeric `getslot`/strict-get paths use the
shared boxed predicate, native conversions use the checked numeric cast, and
`setslot` validates `lua_Integer`/`lua_Number` representability before
`setivalue`/`setfltvalue`. The cast and its non-raising `is` twin consume the
same target-profile predicate.

These representation helpers do not decide whether a conversion is legal.
The checker attaches an `AdjustmentPlan`, `GuardPlan`,
`DynamicCoercionPlan`, or `WrittenCastPlan`; the coder first validates that
plan and then renders it into native-local, `TValue`-destination, or mixed
forms. Strict `value` projections, Array/Map reads, and branded generic
function calls therefore share one tag-check family, while genuine-Lua
entries/writes and written casts share the separate dynamic family. See
[Type relations and boundary plans](type-relations-and-boundaries.md).

`types.is_gc` in `types.lua` decides which types the collector can care
about, and therefore which values require a traced owner for any lifetime that
crosses allocation: string, value, function, array, map, record/union nominal,
Interface wrapper, C `TValue`, Lua-internal `Udata *`, owned C userdata, and
`T?` when `T` is itself GC-able. A borrowed native C copy does not need a
second root when its existing owner remains live. Integers, floats, booleans,
nil, and ordinary foreign pointers need none.

### Array proxies and function closures

An Array has two simultaneously live objects. Titan's native `Table *` points
at the backing Table; the backing key 0 points to the exact mutable or const
canonical proxy Udata. The proxy has exactly two traced user values: `uv[0]`
points back to the backing Table; mutable `uv[1]` holds the module-cached
genuine-Lua writer closure, while const `uv[1]` is nil. The mutable closure in
turn traces its owning module Udata. `titan_array_new` and
`titan_const_array_new` use one caller-provided traced result slot: it first
roots the backing, then roots the proxy after the proxy already points back to
that backing, and finally leaves the completed backing/proxy cycle there. They
install the metatable and two user values directly with Lua-internal stores and
barriers, never through the public stack API. No user-value edge is untraced.

A canonical Titan **source** function is a `CClosure`. Its header is `_mod`,
canonical function-type tag, native-entry pointer, and opaque closure brand (`TITAN_BRAND`);
captures begin at upvalue 4; the final upvalue is the declaration's strict
light C function. The last slot does not move capture indices. Exact dispatch
first compares the canonical static tag and then trusts this private layout
without a registry lookup. After an exact-tag mismatch, generic dispatch
compares the fixed 64-bit brand sentinel (`TITAN_BRAND`) in upvalue 3. Both require the private
minimum shape and otherwise read trusted raw pointer bits without `ttis*`
checks. With five structural source upvalues, at most 250 captures fit under
Lua's 255-upvalue limit.

A realized callable-adjustment wrapper is also a CClosure, but adds one traced
link. For a source with `n` upvalues it copies header/captures through `n-2`,
replaces tag/native with target B's tag/adapter, stores the immediate source
closure at `n-1`, and stores B's consumer-local strict relay at `n`.
`CClosure.f` remains the source coercive entry. Wrapper chains copy older
private links and append the new immediate source, so every adapter receives
the correct `_fn`. Eligibility checks only a non-null CClosure,
`5 <= n < MAXUPVAL`, the exact lightuserdata tag in slot 1, and the
lightuserdata brand in slot 3; the rest of the private branded layout is
trusted. The final closure is allocated with `luaF_newCclosure`, initialized
fresh-white with `setobj2n`/`setpvalue`/`setclCvalue`/`setfvalue`, and published
directly to its own traced result slot. If `n == MAXUPVAL`, construction
preserves the already rooted operand for generic fallback. See
[Closure adjustment wrappers](closure-adjustment-wrappers.md#wrapper-layout).

## Records: a single tagged Udata

A Titan record value is **one** Lua object — a full userdata (`Udata`).
For

```titan
-- Titan
record Point
    x: float
    y: float
    name: string
end
```

the synthesized `Point.new` (the parser desugars every record into a
declaration plus a `new` record function) generates, in `coderecord`
(`coder.lua`), a single allocation:

```c
{
    Udata* _ud = luaS_newudata(L, 0, 3);               /* #fields user values, no raw payload */
    setuvalue(L, _tmp_1_slot, _ud);                    /* anchor the udata first */
    _ud->metatable = hvalue(&_mod->uv[3].uv);          /* this metatable IS the type identity */
    /* per field i: store into &_ud->uv[i].uv, then for GC-able fields
       luaC_barrierback(L, obj2gco(_ud), &_ud->uv[i].uv) */
}
```

The layout:

* **The `Udata`** has `#fields` user values (no reserved `uv[0]`):
  `uv[i].uv` holds field `i`, **0-based** (`0..N-1`), assigned in
  declaration order by the checker — `types.Field` in
  `checker.lua`. Inside Titan code a record value *is* this udata
  (`ctype` = `Udata*`), so field access is an indexed load — `p.x`
  compiles to `fltvalue(&((_param_p)->uv[0].uv))` — and a mutable field write is
  `setslot` into `&(_recobj->uv[i].uv)` plus a **back** barrier when the
  field type is GC-able (a userdata owner uses `luaC_barrierback`, see
  [write barriers](#5-write-barriers-back-for-userdata-and-tables-forward-for-closures)).
  Local fields use the same slots as public fields. A serialized `.so`
  interface may omit those local `Type.Field` entries, so `Type.Record.nfields`
  carries the full allocation count and each public `Type.Field.index` keeps
  the original slot number.
* The udata has **no** raw payload (`luaS_newudata(L, 0, N)`): a record's
  *type identity* is its `metatable` field (next section), set directly
  from the module user value caching this record's metatable.

There is no longer a backing `CClosure` and no closure↔udata
cross-references: the value Titan computes with and the value Lua sees
are the same object.

### Type identity: the metatable pointer

A record's type identity is its **metatable pointer**. Every full
userdata has a `metatable` field in its header, and each record type has
exactly one metatable (allocated with `luaL_newmetatable`, per Lua
state), so two userdata carry the same record type exactly when their
`metatable` fields are equal. There is no separate tag word, no C static,
and no per-type registry tag entry: the identity already lives in the
udata header that Lua maintains anyway.

This deliberately replaced an earlier scheme that stored a unique
`void*` "tag" in the udata's raw payload (`luaS_newudata(L, sizeof(void*),
N)` plus `*((void**)getudatamem(_ud)) = …`) and compared that tag word.
The problem was **safety**: the check reads `getudatamem(_ud)` only after
`ttisfulluserdata` passes, but a full userdata with *no* custom storage
section — a Titan module value (a len-0 userdata), or a foreign-library
userdata — passes `ttisfulluserdata` while `getudatamem` points *past*
the object, so reading the tag word is out-of-bounds. The metatable
pointer is always in bounds: every full userdata has the field, whether
or not it has a payload, so the check is total.

The metatable, being a per-Lua-state heap object, cannot live in a C
static: it is cached in a `_mod` user value (`type2metatable` allocates
the slot lazily; `_init` fills it with `luaL_getmetatable`), and the
type check reads it per-state from there. In the Lua registry, the
canonical metatable is registered under its conventional name, mapped by
its fully qualified type name in the global `TITAN_METATABLES_KEY` table,
and indexed in reverse by pointer for error messages (with `$TYPE` the fully
qualified type name):

| Registry key | Value | Used for |
| --- | --- | --- |
| `"Titan record $TYPE metatable"` | the metatable (`luaL_newmetatable`) | wiring `_mod` user values; `__metatable` is protected with the string `"Titan record $TYPE"` |
| `TITAN_METATABLES_KEY` | table mapping `$TYPE` -> metatable | global discovery of nominal metatables across modules |
| the metatable pointer itself (`lua_rawsetp`) | the FQTN string | the *reverse* map, metatable → name, for error messages |

In addition, each record metatable embeds discoverable runtime type metadata
using lightuserdata keys:
* `TITAN_BRAND`: integer tag `TITAN_RECORD` (3), identifying the metatable kind;
* `TITAN_MT_TYPE`: serialized type descriptor string (`Record(...)`);
* `TITAN_MT_MEMBERMAP`: member map table holding field indices and method closures;
* `TITAN_MT_STATICS`: table holding constructors (`Point.new`) and static methods.

### Wrap and unwrap at the boundary

Now that a record *is* its userdata, the boundary has nothing to swap:
Titan and Lua hold the same object. `setboxed` for a record hands Lua the
udata directly (for `T?` over a record,
after a nil check). Coming back, the nominal case of `checkandget`
compares the udata's metatable against the expected record's metatable
(read per-Lua-state from the `_mod` user value caching it) and uses the
udata as the value:

```c
if (TITAN_LIKELY(ttisfulluserdata($EXP))) {
  Udata* _ud = uvalue($EXP);
  if (TITAN_LIKELY(_ud->metatable == hvalue(&_mod->uv[META].uv))) {
    $VAR = _ud;
  } else {
    TValue key, name;
    setpvalue(&key, (void *)_ud->metatable);
    lu_byte tag = luaH_get(hvalue(&G(L)->l_registry), &key, &name);
    if (tagisempty(tag) || !ttisstring(&name)) {
        /* not a named Titan nominal: report static "userdata" */ $THROW...
    } else {
        /* another Titan nominal: use getstr(tsvalue(&name)) */ $THROW...
    }
  }
} else { /* not even a userdata */ $THROW... }
```

Reading `_ud->metatable` is safe for *any* full userdata — a Titan
record, a Titan module, or a foreign-library userdata — because the
field is part of the udata header and exists regardless of payload size;
the old scheme's `getudatamem` read was out-of-bounds for a payload-less
userdata. All three failure arms raise the run-time error
`file:line:col: type error, expected %s but found %s`, with the
expected name printed as the FQTN and the found name taken from the
reverse metatable→name registry entry when the value is some *other*
Titan nominal. The lookup uses `luaH_get` directly on `G(L)->l_registry`, so it
does not push or pop Lua stack slots. A userdata without a reverse entry reports
the static name `userdata`; it neither consults `__name` nor invokes
`__tostring`. The spec
suite asserts both
`expected test.Rec but found test.Point` and
`expected test.Rec but found number` (`spec/coder/coder_spec.lua`), and proves
that an unknown userdata's `__tostring` is not called.

### Why one object

A record needs to be two things at once and a single full userdata
serves both in O(1). **Lua needs** a value with identity, a metatable
and metamethod dispatch — a full userdata; the metatable's
`__index`/`__newindex` serve field access and methods from Lua
([Lua interop internals](lua-interop-internals.md)), and the spec
verifies `type(p) == "userdata"` and that two instances share a
metatable. **Titan needs** fixed-slot, unboxed-pointer field access and
a GC object with barrier support for mutable slots — exactly
what a `Udata`'s `UValue uv[]` array is. `setboxed`/`checkandget`
(Titan↔Lua) need no wrap or unwrap at all: the value crossing the
boundary is the record itself, leaving only the one-pointer metatable
compare on the way in.

## Unions: tag and optional payload user values

A Titan union is also one zero-byte `Udata *`, with a distinct per-union
metatable as its nominal identity. Its user-value layout is deliberately not
the record field layout:

```text
uv[0]  integer absolute variant tag
uv[1]  payload, only for a payload variant
```

An empty variant allocates with `luaS_newudata(L, 0, 1)`; a payload variant
uses `luaS_newudata(L, 0, 2)`. The constructor roots the userdata before
evaluating/storing a payload and applies `luaC_barrierback` when that payload
may be collectable. No tag or payload is exposed as a Titan field or ordinary
Lua member.

Payloads use the same `types.has_tvalue_representation` rule as record fields
because both are stored in a traced `TValue` user-value slot. Ordinary boxed
Titan values—including Arrays, Maps, and function values—are eligible;
options recurse into their base. Direct C aggregates, C arrays, direct C
functions, and C function pointers have no such representation and are
rejected. An Array payload stores its internal `Table *` backing in `uv[1]`,
not its Lua proxy userdata.

`case` materializes the union once, reads the integer tag, and extracts
`uv[1]` only for a checked payload binding. Boxing into `value` keeps the same
userdata, and unboxing compares the exact union metatable just as a record
check compares the exact record metatable. The reverse metatable map includes
the protected `"Titan union <fqtn>"` identity for diagnostics.

## Interface wrappers

An Interface value is a full `Udata` whose metatable is the exact nominal
Interface identity. Its opaque payload is a declaration-order array of
`TitanInterfaceMethod` function-pointer storage, while its `2 + field_count`
traced user values retain the concrete owner's module Udata, the concrete
record/union receiver, and target-typed field snapshots in Interface field
order. The payload is copied from a nonempty process-static pair array and is
not a GC graph; every collectable user-value store needs an ordinary Udata
backward barrier. Field-only wrappers have zero payload bytes and no pair-array
copy.

For every pair whose static wrapper construction is emitted, initialization
may also store a one-upvalue witness closure in the concrete metatable under
the target Interface metatable object. Both key and closure are traced table
entries; the closure retains the emitting module, whose uservalues retain any
imported concrete owner and cached metatables. Canonical nominal metatables are
also owned by the registry. This is ordinary stock-Lua reachability, not a new
root table or untraced cache.

Wrapper allocation follows the fresh-object rule below: the concrete source is
frozen once in an untraced C temporary while its ordinary provenance remains
live, and the new Udata receives its own root immediately before its metatable
and `2 + field_count` traced edges are published. The lowering conservatively treats
`luaS_newudata` as a stack-rebase point, saves `_base` as an offset, and restores
it immediately after allocation. This protects stack-slot addresses; the
non-moving collector keeps the source and new Udata heap objects stable. A bound
Interface method closure pushes the receiver as an actual closure upvalue and
adds a strong edge to the wrapper in upvalue 4; it does not create a preliminary
receiver root. Adjustment entries likewise keep native inputs in C, root every
live fixed/open GC result immediately after the native call, and add destination
roots only for newly allocated converted objects. Raw descriptors and
allocation-free destination runs receive no parallel root range. See
[Interfaces](interfaces.md#wrapper-representation) for the complete layout and
dispatch contract.

When the witness is called, its concrete input already occupies a traced
argument slot. The new Interface Udata replaces that slot before its metatable
and owner/receiver uservalues are published; user value 1 then retains the
input. Field adjustments use traced temporaries and store each snapshot with a
barrier before publication. `luaS_newudata` may grow the stack, so saved offsets
are restored before slot access even though Lua heap objects themselves do not
move.

## The module userdata

Module state uses the same representation family as nominal values: each module
instance is one `Udata`, `_mod`, passed as the second argument to every
generated function (`Udata *_mod` in every native signature). It is the
value `require` returns directly — there is **no separate Lua-facing
module table** — and it is allocated in `_init` with zero raw bytes and
`NUPVALS` user values:

```c
Udata *_mod = luaS_newudata(L, 0, $NUPVALS);
```

There is **no reserved user value**: the module table was removed
entirely, so member slots are 0-based. The user values hold, in
allocation order: the importer-reconstructible public prefix (exported module
variables, ordinary-function canonical closures, then public nominal statics),
then the consecutive mutable/const Array-metatable cache, one immutable lightuserdata
physical-provider identity token, and fixed AST-order private slots for
locals/imports, remaining canonical closures, and nominal namespace tables.
An explicit source importer verifies that token against its exact linked producer
before reading any of those source-private slots. The remaining Array-writer,
nominal/owned-C metatable, and transitive-owner
module slots are allocated in inventory/first-use order and may interleave.
That private order is a coder detail and is not serialized. Array writers are
initialized before module variable initializers. Callable tags
are published even earlier, before either writers or any initializer-created
lambda/bound-method closure can copy them; canonical top-level/static closures
are initialized later but still before module exposure. Reading a module variable is `getslot` on
`&_mod->uv[i].uv`; writing a GC-able one is `setslot` plus the **back**
barrier `luaC_barrierback(L, obj2gco(_mod), slot)` (a userdata owner,
not a closure). All member access from Lua — functions, variables and
record namespaces alike — flows through a metatable installed on the
`Udata` itself ([Lua interop internals](lua-interop-internals.md)); the
allocation rules and the init protocol are in the
[code generator overview](codegen-overview.md).

## GC discipline: the invariants

Titan shares Lua's collector — there is no Titan heap and no reference
counting; `luaH_new`, `luaS_new*`, `luaS_createlngstrobj` (long
concatenation results), `luaF_newCclosure` and `luaS_newudata` are the
only allocators generated code calls. But
generated code runs *outside* the Lua VM: it does not pass through
`luaD_call`, keeps values in C variables the collector cannot see, and
never hits the VM's own GC polling. The coder therefore maintains five
invariants: 1–3 keep values *visible*, 4 keeps the collector *running*,
5 keeps old objects *honest*.

### 1. The function frame: reserved, nil-initialized stack slots

A function whose body needs `nslots > 0` anchor slots gets this preamble
(`codefuncdec`, `coder.lua`):

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

The translation-unit-local `titan_ensure_stack` calls Lua's internal raising
`luaD_checkstack` path and then extends `L->ci->top.p` (the current call's
allowed stack ceiling) exactly as the public API would. It does not cross the
public Lua stack API. Slots are
nil-initialized through Lua's stack-aware `setnilvalue2s` macro so a
collection arriving before a slot's first real store sees nil rather than
stack garbage. Anchor slots are addressed as
`s2v(_base + k)`: `newslot` hands out indices, `pushd`/`popd` save and
restore the depth around blocks and loop bodies so sibling scopes reuse
slots, and `nslots` records the high-water mark that sizes the
preamble. Every `return` (and the implicit return of a nil-returning
function) first restores `L->top.p = _base;` (`codereturn`). The module
`_init`'s variable-initializer section reserves and nil-initializes
slots the same way, though with an unconditional `titan_ensure_stack`
and no entry GC poll.

Every other generated path that reserves capacity before raw `L->top.p`
writes calls the same helper. Internal stack growth raises on failure, so
generated code never continues to a raw push or slot write without capacity.

### 2. Home roots, shadow slots, and borrowed C copies

A GC-bearing value that must live across allocation has a traced **home**: a
local shadow slot, module/record/container field, native-result slot, or another
GC object. `newtmp(ctx, typ, true)` creates a C temporary plus a paired stack
slot (`_tmp_N` + `_tmp_N_slot`) when the temporary itself owns that lifetime;
`Ast.StatDecl` does the same for locals. Native call sequencing is deliberately
different: `coder._freeze_code` may copy a callee, receiver, fixed argument, or
static/open variadic element into an untraced C temporary for lexical order, but
it never publishes a tracing-only call-activation slot. Fresh allocations and
native results already acquired their mandatory roots; other inputs retain their
ordinary semantic or VM homes. For

```titan
-- Titan
function greet(s: string): string
    local t: string = s
    return t
end
```

the generated body contains:

```c
TString* _local_t_1;
TValue *_localslot_t_2 = s2v(_base + 0);
_local_t_1 = _param_s;
/* update slot */
setsvalue(L, _localslot_t_2, _local_t_1);
```

The slot is refreshed at the declaration and at **every assignment** to
the local (`codeassignment` emits `$CVAR = $CEXP;` followed by the
`setslot`), so the slot is never stale while the C variable holds a
live value. Parameters (including method `self`) get a shadow slot
(`_paramslot_<name>`) only when the body assigns to them or the checker marks
them for spill across a catchable call. That is a semantic local/spill home, not
argument transport. Otherwise the parameter remains only its native C formal
and its reachability comes from the input's existing provenance. Module
variables need no shadow: their home, a `_mod` user value, is itself a GC-visible
location.

### 3. Anchor fresh objects before the next allocation

An allocation may raise and may invoke emergency collection on allocator
failure; later allocations or explicit polls can collect an unpublished object.
Every successfully created object therefore receives its own traced root
immediately, before another allocation or poll. The record constructor shown
earlier is simpler now that it is a single object: one
`luaS_newudata` returns the udata already nil-filled and white, and the
generated code anchors it in its stack slot
(`setuvalue(L, _tmp_1_slot, _ud)`) *before* any field expression runs.
Each field store then happens with the udata already anchored, and the
back barrier on each GC-able field store keeps the (possibly old/black)
udata honest. There is no longer a separate closure-then-udata sequence
to order, and no forward-barriered cross-link to install.

Container literals preserve the same rooting rule with a different order:
every Array element expression is first evaluated into an appropriately boxed
or internal anchored temp. Generated code supplies `titan_array_new` an active
result slot. The helper roots the backing there before resizing, temporarily
roots the proxy there after directly installing its metatable/uservalues, and
then leaves the completed backing in that same slot after building the
key-0/uservalue cycle. It never changes `L->top` or uses the public Lua stack
API. Generated code then fills positive array slots from the element temps.
The constructor records its highest non-nil position in `lenhint`; resizes save
and restore that authoritative length.
Map constructors root their ordinary Table plus key and value temps, boxing an
Array used as a raw-visible key or value. See
[Dense Arrays](dense-arrays.md#runtime-construction).

Callable adjustment evaluates its operand once and borrows that value's existing
root. Eligible realization calls `luaF_newCclosure` for the final size, fills the
fresh-white object directly (`source->f`, `setobj2n`, `setpvalue`,
`setclCvalue`, `setfvalue`), and publishes it immediately into the assigned
traced result slot. There is no transient stack assembly, `lua_pushcclosure`,
construction barrier, local GC poll, construction-only root copy, or
construction rebase. `luaF_newCclosure` can allocate or raise, including after
an emergency collection, but it does not ordinarily poll and the emergency
cycle does not shrink the stack. Nested callable conversion is likewise
allocating/raising but not stack-relocating; every fresh wrapper still receives
its own immediate root.
String results —
literals (`luaS_new`), concatenation,
number→string casts — are likewise stored to their temp's slot
immediately after creation.

### 4. `luaC_checkGC` at entry and at allocating loop tails

Because Titan-to-Titan calls never enter `luaD_call`, generated code
must poll the collector itself. `luaC_checkGC(L)` appears at function entry as
the first line of a slot-reserving preamble, and at the tail of every
`while`/`repeat`/numeric-`for` body **iff** the loop's condition-plus-body
allocated—measured as the delta of `ctx.allocations` across loop generation. A
synthesized callable or Interface native adapter has no ordinary Titan body, so
it separately polls at entry iff its frozen action graph can allocate a nested
wrapper. That poll precedes stack reservation, `_base`, and every raw stack
pointer; native inputs remain C values whose ordinary provenance already
protects them.

A pure-arithmetic loop carries no GC polling; an allocating Titan loop polls
once per iteration and cannot starve the collector. Direct callable-wrapper
construction itself adds no local poll: `luaF_newCclosure` links a fresh-white
object, and no poll is permitted between allocation and immediate publication.
The containing ordinary entry/loop or allocating-adapter entry remains the
polling authority. (History: commits
`eade55d` "add GC checks to loops and function preambles" and `b839f59`
"be smarter about avoiding calling GC when the loop does not allocate",
November 2017.)

### 5. Write barriers: back for userdata and tables, forward for closures

Lua's generational collector only re-traces old objects that announce
they were modified. Generated code announces with the two internal
barrier macros, chosen by the *owner's* type. The choice turns on a GC
detail: a `Udata`'s and a `Table`'s traversal call `genlink`, so the
**back** barrier (re-greying the *container*) is safe for them, whereas a
`CClosure`'s traversal does not, so a closure store must use the
**forward** barrier (recolouring the *value*).

**Back barrier — `luaC_barrierback(L, obj2gco(o), v)`** when the owner is
a `Udata` or a `Table`; used for:

* record field assignment, and record-literal field initialization (the
  owner is the record's `Udata`);
* union payload initialization (the owner is the union's `Udata`);
* module-variable writes — local
  (`luaC_barrierback(L, obj2gco(_mod), slot)`) and imported
  (`luaC_barrierback(L, obj2gco(_imod), _varslot)`), including writes
  coming from Lua through the module metatable's `__newindex`;
* record field writes from Lua through the record's `__newindex` (union
  `__newindex` always rejects);
* Array backing-slot stores, Map stores, and container-literal fills, each
  gated on `types.is_gc` of the stored element or value type. Array stores
  barrier the backing Table, never its proxy; the cycle edges use the barrier
  appropriate to their actual Table/Udata owners. Array construction installs
  the backing and writer in the proxy's two traced user values through the Lua
  userdata API and barriers the backing's key-0 proxy link.
* mutation of a GC-bearing captured-variable box, whose one traced user value
  is owned by a `Udata`.

(The argument shape differs from the forward barrier: back takes the
*value* and an `obj2gco`-wrapped container; forward takes the *slot
pointer*.) Both `_mod` and record instances are `Udata`, so these stores use
the back barrier rather than the forward barrier used by the superseded closure
representation. Moving record type identity from a `getudatamem` tag word to
the udata metatable pointer did not change its barriers.

**Forward barrier — `luaC_barrier(L, owner, slot)`** remains for the
owners that are still `CClosure`s — every store of a captured value into
a function value's upvalue array ([closures and captured
variables](codegen-overview.md#closures-and-captured-variables)).
The strict-entry trailer is installed at source-closure construction like the
header and captures. A callable wrapper is instead initialized directly while
fresh-white. `setobj2n` copies ordinary upvalues, `setpvalue` installs
tag/native pointers, `setclCvalue` installs the immediate source, and
`setfvalue` installs the relay. The completed closure is then published directly
to its traced result slot.
Fresh-white construction needs no forward/back barrier. A later store into an
existing closure would still require the forward barrier. A
capture *box* is a `Udata`: GC-bearing boxes have one traced user value and use
the back barrier, while non-GC values use an untraced raw payload and need no
barrier.

The division of labor with Lua's table internals is spelled out in a
comment in `coder.lua`: raw stores go through `luaH_set`/`luaH_setint`
(5.5 removed the writable-slot API), and "The GC barrier for the stored
value is the caller's responsibility; new keys are barriered internally
by the insertion code." Under the generational collector, getting any
of this wrong is promptly fatal: minor collections are frequent, and an
unbarriered old→young store is a use-after-free on the next one. The
[migration report](../lua-5.5-migration.md) ("GC write barriers") and
the [internals catalogue](../lua-5.3-to-5.5-internals.md) record the
barriers the 5.3-era code skipped and the `obj2gco` signature change
that all back-barrier sites needed.

## Calls: C-only inputs, immediate result roots, and VM transport

The [calling convention](codegen-overview.md) separates native C transport from
GC publication. A native fast call does **not** establish a new tracing lifetime
for its inputs.

* **Native inputs.** The caller evaluates left-to-right. Where later setup is
  effectful, it freezes the first-class callee, receiver, fixed arguments, and
  static/open variadic elements in ordinary C temporaries. Pure trailing reads
  may remain direct C expressions. Neither form writes a tracing-only Lua-stack
  slot. Fresh values retain the roots installed at allocation or at an earlier
  native-result handoff; established values retain their semantic
  module/record/container/local home or an upstream Lua VM argument slot. A raw
  `TitanVargX` and its C `args` array merely borrow those values and are never
  roots. Callable and Interface adapters follow the same rule and have an empty
  input-source root inventory. A newly allocated argument conversion is the one
  exception in the *destination*: the fresh wrapper gets its mandatory initial
  allocation root.

  Consequently the no-copy native protocol does not manufacture a lifetime
  after a program destroys an input's sole traced provenance while retaining
  only its raw C formal. Supporting that stronger case would require the third
  call-activation root that this protocol deliberately excludes.

* **Native returns.** The callee returns its first fixed result in C and writes
  later results through out-parameters without rooting them. Merely returning
  cannot run the collector, although the callee may have relocated the Lua
  stack. The caller therefore rebases first, performs any nonallocating
  raw-to-visible projection, and then publishes **every live GC-bearing native
  result immediately** into its caller-owned result slot before any later
  allocating work. This publication is required even for an identity
  conversion; a transitive callee's allocation root lies above its restored
  caller top and no longer owns the handoff. A freshly allocated
  converted callable/Interface value separately gets its own allocation root.
  For `two(): integer, string`, lowering schematically separates raw ABI holders
  from the visible projection and roots the live string immediately after
  rebasing:

```c
lua_Integer _abi_1 = 0;
TString *_abi_2 = NULL;                 /* raw out-param, not yet a root */
lua_Integer _visible_1 = 0;
TString *_visible_2 = NULL;
_abi_1 = test_\u2133_two_titan(L, _mod, NULL, &_abi_2);
_base = restorestack(L, _base_off);
_visible_1 = _abi_1;
_visible_2 = _abi_2;
setsvalue(L, s2v(_base + 0), _visible_2); /* immediate result handoff */
```

* **Flexible runs.** Native input descriptors borrow the existing provenance
  above. Every live GC-bearing native output prefix uses bounded caller-owned C
  backing plus a parallel traced range: after rebasing and validating its count,
  the caller copies the complete live prefix into that range and clears it only
  after the sink consumes the run. Adapters do this for every live fixed/open
  source result, not only when a later action allocates. A converted destination
  range exists only when conversion allocates fresh callable/Interface values.
  Neither descriptor nor raw C array ever becomes a root.

The generic paths are intentionally different. A non-Titan Lua call and a
branded strict call push the callee/carrier and every actual argument because
Lua's VM stack is their calling convention; those are transport slots, not
native activation copies. `luaD_callnoyield` may resize the stack, so saved
offsets recover positions afterward. Its results remain rooted in VM result
slots while strict/dynamic conversion runs, then are copied into the same
consumer homes or caller-owned result ranges used by the native path. A Lua
entry calling a native body similarly reserves its result area first and boxes
every returned value there.

A pending `return` that crosses `finally` is the difficult lifetime case: the
saved action must retain both the flexible count and every GC-bearing element
in traced storage while the `finally` body allocates or calls again. Normal
completion resumes that saved run; a raise from `finally` supersedes it and
must not leave stale live roots. This is a required invariant of the
error-handling lowering, not permission to rely on the native descriptor as a
root.
