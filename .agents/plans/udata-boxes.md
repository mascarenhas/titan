# Udata boxes for captured-and-mutated locals

## What a "box" is

A captured-and-mutated local/parameter/`self` (a `Decl` that is both
`_captured` by a nested closure and `_assigned`) cannot live in a C local: all
the closures that capture it must share one mutable cell so a write through any
of them is seen by all. That shared heap cell is the **box**. The box pointer is
what gets copied into each capturing closure's upvalue; reads and writes go
through the cell.

The box is **module-internal**: it backs a captured local inside one module's
closures, and only the module that defined the variable ever generates code that
touches it. A box never crosses a module boundary, so this representation change
does **not** alter the cross-module ABI, so the ABI marker is unchanged.

## The change: CClosure box -> Udata box

Previously a box was a 1-upvalue `CClosure` (`luaF_newCclosure(L, 1)`) holding a
`TValue` in `upvalue[0]`, written with the **forward** barrier `luaC_barrier`,
with a stub `->f = titan_box_trap` so an accidental call errored.

Now a box is a Lua **userdata** (`Udata *`). Two reasons, both proven with
standalone C probes (`/tmp/titan_udata_box.c`, functional and under
`-DLUAI_ASSERT`):

1. **Back barrier, no float.** Overwriting a box in a hot loop with fresh GC
   values, under the forward barrier, promotes each transient to the old
   generation (`G_OLD0`) and floats it until the next *major* GC. The **back**
   barrier `luaC_barrierback` avoids that — but the back barrier is only safe on
   object types whose GC traversal calls `genlink` (lgc.c). `traverseCclosure`
   does **not** call `genlink`, so back-barriering a CClosure box hits an illegal
   black+`G_TOUCHED1` state (assertion at lgc.c:271). `traverseudata` **does**
   call `genlink`. So a userdata box + back barrier is both safe and float-free,
   exactly like a table.

2. **Raw scalar boxes, no tagging, no barrier.** A box whose value is an
   unconditionally non-collectable C scalar (`integer`/`float`/`boolean`) can
   store the raw C value inside a **0-uservalue** userdata, skipping TValue
   tagging and all barriers.

## The two representations (selected by `is_rawbox(typ)`)

`is_rawbox(typ)` is `not types.is_gc(typ)`: a box uses the raw (N)
representation iff its value can never hold a GC pointer. Concretely (N) covers
`Type.Integer`, `Type.Float`, `Type.Boolean`, `Type.Nil`, a foreign
`Type.Pointer`, a scalar `Type.Typedef`, and an `Type.Option` of any non-gc base
(its TValue is only ever nil-or-scalar, never a GC reference). Everything that
may hold a GC object — String, Array, Map, record/Nominal, Function, Value, and
an Option of a gc base — uses the GC representation (G). When unsure, (G) is
always correct.

All of these raw cases are reachable in surface Titan (none is defensive-only):

- integer/float/boolean: ordinary scalar boxed locals.
- `Type.Nil`: `local n: nil = nil` captured and reassigned in a lambda — the box
  uses a dummy `int` payload. (Confirmed constructible end-to-end; the Nil raw
  branch is NOT dead code.)
- `Type.Option` of a non-gc base (`integer?`/`float?`/`boolean?`): a boxed
  option local — the box stores the raw `TValue` inline (`ctype` = `TValue`).
- foreign `Type.Pointer` (e.g. `FILE*`) and scalar `Type.Typedef` (e.g.
  `size_t`): a `foreign import` value bound to a local that is captured and
  reassigned in a lambda — both box as raw with `ctype` = `foreignctype(typ)` /
  `ctype(underlying)`.

`spec/coder/closures_spec.lua` exercises each (the foreign cases gated on the C
FFI toolchain).

> Note (orthogonal pre-existing bug, NOT introduced by the `not is_gc`
> generalization): a `nil` *literal* coerced to `boolean?` (e.g.
> `local b: boolean? = nil`, or `b = nil`) materializes boolean **false**
> instead of nil. The checker's `trycoerce` (checker.lua ~line 184) wraps it as
> `ExpCast(ExpCast(nil, boolean), boolean?)` — the inner `nil -> boolean`
> coercion (legal only because nil is falsy) drops the nil-ness, so the coder
> takes the `t -> t?` setslot path (`titan_setbvalue(.., 0)`) rather than the
> Nil->Option `setnilvalue` path. `integer?`/`float?` are unaffected because
> `nil -> integer`/`nil -> float` are not coerceable, so those keep the
> `ExpCast(nil, T?)` shape the coder handles correctly. This reproduces on a
> NON-boxed `boolean?` local too, so it is independent of the box
> representation; the raw `boolean?` box itself round-trips nil/true/false
> faithfully (the closures_spec boolean? test sources its nil from a real
> `boolean?` argument to avoid the literal-coercion bug).

### (G) GC / dynamic box — `nuvalue == 1`, TValue in `uv[0].uv`

Used for String, Array, Map, record/Nominal, Function, Value, and an Option of a
gc base.

- Create (inline `luaS_newudata(L,0,1)`, size check dropped):
  ```c
  Udata *BOX = gco2u(luaC_newobj(L, LUA_VUSERDATA, sizeudata(1, 0)));
  BOX->len = 0; BOX->nuvalue = 1; BOX->metatable = NULL;
  setnilvalue(&BOX->uv[0].uv);   /* before anchoring */
  setuvalue(L, SLOT, BOX);       /* anchor on the Lua stack */
  ```
- Write: `setslot(typ, "&BOX->uv[0].uv", cexp)` then, when the value may be
  collectable (`types.is_gc(typ)`), `luaC_barrierback(L, obj2gco(BOX), &BOX->uv[0].uv);`
  (a Nil-typed (G) box never stores a GC value, so its write needs no barrier).
- Read: `getslot(typ, nil, "&BOX->uv[0].uv")`.

### (N) non-GC raw box — `nuvalue == 0`, raw value inline

Used for any non-gc type: integer/float/boolean, Nil, an Option of a non-gc
base, a foreign pointer, and a scalar typedef. `CT` is the coder's existing C
type for the Titan type (`ctype`): integer -> `lua_Integer`,
float -> `lua_Number`, boolean -> `int`, Nil -> `int` (dummy),
Option-of-non-gc -> `TValue`, foreign pointer -> `foreignctype(typ)`, scalar
typedef -> the `ctype` of its resolved underlying type.

- Create (inline `luaS_newudata(L, sizeof(CT), 0)`):
  ```c
  Udata *BOX = gco2u(luaC_newobj(L, LUA_VUSERDATA, sizeudata(0, sizeof(CT))));
  BOX->len = sizeof(CT); BOX->nuvalue = 0; BOX->metatable = NULL;
  setuvalue(L, SLOT, BOX);
  ```
- Write: `*(CT *)getudatamem(BOX) = cexp;` — no barrier (non-collectable raw store).
- Read: `*(CT *)getudatamem(BOX)` — a plain rvalue yielding the unboxed C value.

`BOX->metatable = NULL` always (no metatable, no `__gc`).

## GC discipline

- The box is anchored via `setuvalue(L, SLOT, BOX)` **before any subsequent
  allocation**; the existing init ordering (evaluate init into an anchored temp,
  then create+anchor the box with no alloc in between, then store) is preserved.
- For (G), `setnilvalue(&BOX->uv[0].uv)` happens before anchoring, so a GC
  triggered by a later allocation never traverses a garbage `uv[0]`.
- (G) writes use the **back** barrier; (N) writes use no barrier.

## Capture install / read-back

When an inner closure captures a box, the box **pointer** is pushed onto the
stack (`setuvalue(L, s2v(L->top.p), BOX)`, was `setclCvalue`) and moved into the
fresh white closure by `lua_pushcclosure` — so no barrier at construction, as
before. Inside the inner closure the box pointer is read back from its upvalue
with `uvalue(&_fn->upvalue[i])` (was `clCvalue`), typed `Udata *`.

## Trap removal

A userdata cannot be accidentally called (it errors naturally), so the
`titan_box_trap` stub is gone: the `->f = titan_box_trap` emission in `newbox`,
the declaration in `titan-runtime/titan.h`, and the definition in
`titan-runtime/titan.c` were all removed.

## Includes

The box creation uses `gco2u` (defined in `lstate.h`), so `#include "lstate.h"`
was added to the generated-C preamble.
