# Values and the garbage collector

This chapter describes how Titan values are represented in the generated
C — every Titan type's C type, records in full detail, the module
userdata — and the discipline the code generator follows so that all of
those values stay safe under Lua's garbage collector. The structure of a
generated translation unit and the calling convention are covered in the
[code generator overview](codegen-overview.md); construct-by-construct
translations are in [code generator: constructs](codegen-constructs.md);
the Lua-side boundary checks in
[Lua interop internals](lua-interop-internals.md).

## Background: TValue, the Lua stack, and the GC

A **`TValue`** is Lua's boxed value: a small struct holding a value
union (integer, float, `GCObject*`, …) plus a type tag. Collectable
objects — strings (`TString`), tables (`Table`), userdata (`Udata`), C
closures (`CClosure`) — live on the heap, reached through `GCObject*`
pointers inside `TValue`s. The **Lua stack** is an array of `TValue`
slots owned by a `lua_State`; `L->top.p` points one past the last live
slot, and the collector treats every slot below the top as a root. (In
5.5 a stack slot is an `StkId`; `s2v(slot)` views it as a `TValue*`.)

The standalone `lua` 5.5 interpreter switches the collector to
**generational** mode at startup; freshly created states — including
Titan standalone executables — run the incremental collector, and
generated code must be correct for both. Generational mode runs
frequent *minor* collections that trace only the stack, other roots,
and old objects explicitly marked as modified — which is what *write
barriers* are for. Two consequences drive this chapter: a fresh object
is only safe once it is reachable from a stack slot, and an unbarriered
store of a collectable value into an older object is not a rare race
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
| `{T}` (array) | `Table*` | raw pointer; Titan arrays *are* Lua tables |
| `{K:V}` (map) | `Table*` | likewise |
| `value` | `TValue` | a full boxed Lua value, held **by value** |
| record type (`Type.Nominal`) | `Udata*` | the record value *is* this userdata (below) |
| `T?` (option) | `TValue` | boxed: nil or the payload |
| foreign pointer | per `foreignctype` | e.g. `void*`, `char*` ([FFI internals](ffi-internals.md)) |

This is the central performance fact of the backend: Titan locals,
parameters and return values are ordinary C variables in their native,
unboxed form. The Lua stack is never the transport for values between
Titan functions — it is used only as a GC anchor, as described under
[GC discipline](#gc-discipline-the-invariants). The two dynamic types,
`value` and `T?`, are carried as `TValue` *by value* (struct copy),
still without touching the Lua stack. `initval` gives each type its
zero value — `{ {0}, 0 }` (a nil `TValue`) for `value` and options, `0`
for everything else — so a declared-but-unset temporary is never
garbage (it initializes `newtmp` temporaries and the Lua entry
wrappers' argument holders; plain locals are declared bare and
assigned immediately).

### Conversion helpers

Three helper families in `coder.lua` mediate between C variables and
`TValue` slots; all generated code goes through them:

* `getslot(typ, dst, src)` reads a `TValue*` into a C variable —
  `ivalue`, `fltvalue`, `ttistrue`, `tsvalue`, `hvalue`, `uvalue` (for
  records), or a struct copy `*($SRC)` for `value`/options.
* `setslot(typ, dst, src)` writes a C value into a `TValue*` —
  `setivalue`, `setfltvalue`, `titan_setbvalue` (a `titan.h` macro; 5.5
  removed `setbvalue` along with the boolean payload), `setsvalue`,
  `sethvalue`, `setuvalue` (for records), `setobj2t` for
  `value`/options.
* `setwrapped(typ, dst, src)` was historically `setslot` except for
  records, where it had to swap the Titan-side closure for the
  Lua-visible userdata. Now that a record *is* its userdata, `setwrapped`
  for records is just `setslot` — there is no wrapper to swap to (next
  section). It is still used whenever a value escapes anywhere Lua can
  see — table elements, map keys/values, results returned to Lua —
  because other code paths historically distinguished the two; for
  records the two are identical. `copyslotwrapped` is the slot-to-slot
  variant.

`types.is_gc` in `types.lua` decides which types the collector cares
about, and therefore which values need anchoring: string, value,
function, array, map, record/nominal, and `T?` when `T` is itself
GC-able (the list also tests a `Type.Interface` tag for which no
constructor exists). Integers, floats, booleans, nil and foreign
pointers need none.

## Records: a single tagged Udata

A Titan record value is **one** Lua object — a full userdata (`Udata`).
For

```lua
-- Titan
record Point
    x: float
    y: float
    name: string
end
```

the synthesized `Point.new` (the parser desugars every record into a
declaration plus a `new` static method) generates, in `coderecord`
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
  compiles to `fltvalue(&((_param_p)->uv[0].uv))` — and a field write is
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
type check reads it per-state from there. One registry entry per record
type survives, plus a metatable-keyed reverse map for error messages
(with `$TYPE` the fully qualified type name):

| Registry key | Value | Used for |
| --- | --- | --- |
| `"Titan record $TYPE metatable"` | the metatable (`luaL_newmetatable`) | wiring `_mod` user values; `__metatable` is protected with the string `"Titan record $TYPE"` |
| the metatable pointer itself (`lua_rawsetp`) | the FQTN string | the *reverse* map, metatable → name, for error messages |

### Wrap and unwrap at the boundary

Now that a record *is* its userdata, the boundary has nothing to swap:
Titan and Lua hold the same object. `setwrapped` for a record is just
`setslot` — it hands Lua the udata directly (for `T?` over a record,
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
    lua_pushlightuserdata(L, _ud->metatable);
    if(lua_rawget(L, LUA_REGISTRYINDEX) == LUA_TNIL) {
        /* not a Titan record: describe the userdata itself */  $THROW...
    } else {
        /* another Titan record: registry gave its name */ $THROW...
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
Titan record (a non-record userdata has no such entry, so the message
falls back to stringifying the value) — the spec suite asserts both
`expected test.Rec but found test.Point` and
`expected test.Rec but found number` (`spec/coder_spec.lua`).

### Why one object

A record needs to be two things at once and a single full userdata
serves both in O(1). **Lua needs** a value with identity, a metatable
and metamethod dispatch — a full userdata; the metatable's
`__index`/`__newindex` serve field access and methods from Lua
([Lua interop internals](lua-interop-internals.md)), and the spec
verifies `type(p) == "userdata"` and that two instances share a
metatable. **Titan needs** fixed-slot, unboxed-pointer field access and
a GC object with barrier support for mutable slots — exactly
what a `Udata`'s `UValue uv[]` array is. `setwrapped`/`checkandget`
(Titan↔Lua) need no wrap or unwrap at all: the value crossing the
boundary is the record itself, leaving only the one-pointer metatable
compare on the way in.

## The module userdata

Module state uses the same representation as records: each module
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
allocation order: exported module variables (slots 0..n-1 — their
indices are part of the module's ABI), then local module
variables, imported modules' `Udata`s and exported-function canonical
closures, then lazily allocated slots for record metatables,
per-record static-namespace tables, and modules needed only by
cross-module method calls. Reading a module variable is `getslot` on
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
if (L->stack_last.p - L->top.p > $NSLOTS) {
    if (L->ci->top.p < L->top.p + $NSLOTS) L->ci->top.p = L->top.p + $NSLOTS;
} else {
    lua_checkstack(L, $NSLOTS);
}
StkId _base = L->top.p;
L->top.p += $NSLOTS;
for(StkId _s = L->top.p - 1; _base <= _s; _s--) {
    setnilvalue(s2v(_s));
}
```

The fast path bumps `L->ci->top.p` (the current call's allowed stack
ceiling) only when needed, skipping the `lua_checkstack` call when room
already exists; the slow path may reallocate the stack. Slots are
nil-initialized so a collection arriving before a slot's first real
store sees nil rather than stack garbage. Anchor slots are addressed as
`s2v(_base + k)`: `newslot` hands out indices, `pushd`/`popd` save and
restore the depth around blocks and loop bodies so sibling scopes reuse
slots, and `nslots` records the high-water mark that sizes the
preamble. Every `return` (and the implicit return of a nil-returning
function) first restores `L->top.p = _base;` (`codereturn`). The module
`_init`'s variable-initializer section reserves and nil-initializes
slots the same way, though with an unconditional `lua_checkstack` and
no entry GC poll.

### 2. Shadow slots: the dual representation

Every GC-typed value the function computes with lives **twice**: in a C
variable (what the code reads and writes) and in a paired stack slot
(what the collector sees). `newtmp(ctx, typ, isgc)` creates the pair for
temporaries (`_tmp_N` + `_tmp_N_slot`); `Ast.StatDecl` does the same for
locals. For

```lua
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
live value. Parameters get a shadow slot (`_paramslot_<name>`) only
when the body *assigns* to them — an unassigned parameter is already
anchored by its caller ([below](#calls-the-caller-anchors)). Module
variables need no shadow: their home, a `_mod` user value, is itself a
GC-visible location.

### 3. Anchor fresh objects before the next allocation

Any allocation can trigger a collection, so a freshly created object
must reach a stack slot before the code allocates again. The record
constructor shown earlier is simpler now that it is a single object: one
`luaS_newudata` returns the udata already nil-filled and white, and the
generated code anchors it in its stack slot
(`setuvalue(L, _tmp_1_slot, _ud)`) *before* any field expression runs.
Each field store then happens with the udata already anchored, and the
back barrier on each GC-able field store keeps the (possibly old/black)
udata honest. There is no longer a separate closure-then-udata sequence
to order, and no forward-barriered cross-link to install.

Container literals follow the same pattern. `codearray` anchors the
fresh table immediately — and *always* in a stack slot, even when the
constructor has a destination variable, per this comment in the source:

> always build the array anchored in a stack slot; a target slot such as
> a module-global upvalue is not scanned by minor collections, so the
> fresh table could be swept while a callee in the fill loop triggers
> the GC (caller stores + barriers after we return)

Every element expression is then evaluated into its own GC-anchored
temp (via `setwrapped`, so records are stored as their userdata), and
only after all elements exist does the code pre-size the array part
(`luaH_resizearray`) and copy the slots in with `obj2arr` — a
collection triggered by element *k*'s expression cannot sweep elements
1..k−1. Map constructors (`codemap`) do the same with anchored key and
value temps. String results — literals (`luaS_new`), concatenation,
number→string casts — are likewise stored to their temp's slot
immediately after creation.

### 4. `luaC_checkGC` at entry and at allocating loop tails

Because Titan-to-Titan calls never enter `luaD_call`, generated code
must poll the collector itself. `luaC_checkGC(L)` is emitted at exactly
two kinds of places: function entry, as the first line of the preamble
(only when the function reserves slots at all); and the tail of every
`while`/`repeat`/numeric-`for` body **iff** the loop's
condition-plus-body allocated — measured as the delta of
`ctx.allocations` (a counter bumped by every `newslot`) across the
loop's code generation. A pure-arithmetic loop carries no GC polling; a
loop that builds strings or tables polls once per iteration, so an
allocating Titan loop cannot starve the collector. (History: commits
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
* module-variable writes — local
  (`luaC_barrierback(L, obj2gco(_mod), slot)`) and imported
  (`luaC_barrierback(L, obj2gco(_imod), _varslot)`), including writes
  coming from Lua through the module metatable's `__newindex`;
* record field writes from Lua through the record's `__newindex`;
* array element stores, map stores, and array/map-literal fills, each
  gated on `types.is_gc` of the stored element or value type.

(The argument shape differs from the forward barrier: back takes the
*value* and an `obj2gco`-wrapped container; forward takes the *slot
pointer*.) Both `_mod` and record instances became `Udata` in the 0.7
ABI, flipping these stores from the forward barrier the closure
representation used. (The 0.8 ABI changed only a record's *type
identity* — from a `getudatamem` tag word to the udata's metatable
pointer — not its barriers.)

**Forward barrier — `luaC_barrier(L, owner, slot)`** remains for the
owners that are still `CClosure`s — every store of a captured value into
a function value's upvalue array ([closures and captured
variables](codegen-overview.md#closures-and-captured-variables)).
(A capture *box* cell is itself a one-uservalue `Udata`, so its own
mutation uses the back barrier — for the same genlink reason records and
modules now do.)

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

## Calls: "the caller anchors"

The [calling convention](codegen-overview.md) makes the *caller*
responsible for GC-visibility on both sides of a call:

* **Arguments.** GC-able argument values must already be anchored when
  the call happens. No code is emitted at the call site to do this — it
  falls out of invariants 2 and 3: an argument expression's result is
  either a local/parameter (anchored at its home) or a temporary
  (anchored in its `_tmp_N_slot`).
* **Returns.** The callee returns its first result in C and writes
  results 2..n through out-parameters, anchoring none of them — safe
  because merely returning from a C function cannot trigger a
  collection. The caller re-anchors: `codecall` allocates a temp (with
  shadow slot when GC-able) per extra return before the call and, when
  *any* return type is GC-able, stores every GC-able result into its
  reserved slot immediately after the call. For a Titan function
  `two(): integer, string` the call site compiles to:

```c
TValue *_tmp_1_slot = s2v(_base + 0);
TString* _tmp_1 = 0;                    /* out-param for return 2 */
lua_Integer _tmp_2 = 0;                 /* first return: not GC-able, no slot */
_tmp_2 = test_two_titan(L, _mod, &_tmp_1);
setsvalue(L, _tmp_1_slot, _tmp_1);
```

The string out-parameter is live in `_tmp_1` the moment the callee
returns and is in a stack slot before any subsequent allocation can run.
When a Lua program is the caller, the Lua entry wrapper plays this role:
it reserves one stack slot per result (`lua_checkstack` + bumping
`L->top.p`) before invoking the native function and writes each result
back with `setwrapped` — for a record that is just the record's own
userdata, since the value and its Lua face are one object
([Lua interop internals](lua-interop-internals.md)).
