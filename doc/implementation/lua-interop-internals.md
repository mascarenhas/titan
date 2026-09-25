# Lua interop internals

This chapter describes the machinery at the Lua↔Titan boundary: the
coercive source entry used by genuine Lua calls, the strict Lua-stack entries
used after branded exact-tag mismatches, the target adapter/consumer relay used
by realized callable wrappers, the shared per-type lowering plans, the
metatables that serve records and module variables to Lua, the qualified Array
proxy pair and mutable writer, the registry entries holding it all together,
the dynamic loader, the error handler, the standalone-executable
entrypoint, and the safety argument. Value representations (records and
the module state `_mod` as a single tagged `Udata` each) are in
[values and the GC](values-and-gc.md); the `_init`/`luaopen` protocol
and dependency linking are in the
[code generator overview](codegen-overview.md); the user-facing view is
[the language chapter on interoperability](../language/lua-interop.md).

All generated-C excerpts are real output of `coder.generate` for this
module:

```titan
-- interop.titan
record Point
    x: float
    y: float
end

function Point:move(dx: float, dy: float)
    self.x = self.x + dx
    self.y = self.y + dy
end

x: integer = 1

function fmod(a: float, b: integer): (float, string)
    return a + b, "ok"
end
```

Lua-internals background used throughout: when Lua calls a C function,
`L->ci->func.p` points at the stack slot holding the function object,
the arguments sit in the slots after it (`func + 1 … func + n`), and
`L->top.p` points one past the last argument; `s2v(slot)` views a stack
slot as a `TValue*`. `L->errfunc` is the `lua_State` field holding the
stack position of the current *message handler* — the function that gets
to inspect an error before the stack unwinds (what `lua_pcall`'s fourth
argument normally installs).

The normative policy matrix is
[Type relations and boundary plans](type-relations-and-boundaries.md). This
chapter describes how that policy is represented in generated C; it does not
define a second conversion relation.

## The two Lua-stack entries (`genluaentry`)

Every first-class Titan function has [three entry roles](codegen-overview.md):
the native-convention entry used by exact-tag Titan→Titan calls, a coercive
`lua_CFunction` used by genuine Lua calls, and a strict Lua-stack entry used
after a branded exact-tag mismatch. A realized callable wrapper fills those
same roles with its target adapter, copied source `CClosure.f`, and
consumer-local target relay. `genluaentry` in `coder.lua` emits the two
stack-convention entries for every non-`local` top-level function
(`<mod>_\u2133_<name>_titanentry_lua` and `…_strict` in C source, with the
UCN separator becoming UTF-8 at linkage) and every static (`…_titanentry_luastatic` and `…_strictstatic`).
A method has its ordinary `…_titanentry_luamethod`; each method's
self-removed first-class bound value has separate `…_boundlua` and
`…_boundstrict` trampolines. Static, method, bound, and Interface entries use
`<module>_\u2133_<owner>_\u2131_<member><role>`; their object linkage names
contain UTF-8 `ℳ` and `ℱ`. A local declaration that is never used as a value
needs neither stack entry; a first-class local value needs both even though it
is not exported to Lua. For methods, the parameter list is prefixed with
the record's nominal type, so `self` is checked like any record-typed
argument.

Named arguments do not change `genluaentry`. A Titan named call has already
been matched and lowered to positions by the checker, while a Lua table passed
with `f { x = 1 }` is just one ordinary positional value and is never inspected
for labels. Declaration `paramnames` exist only in Titan's compiled interface,
not in the Lua wrapper or a run-time map; see
[named-argument internals](named-arguments.md).

The following is the coercive entry for `fmod`, trimmed only of the two
argument conversions:

```c
static int interop_\u2133_fmod_titanentry_lua(lua_State *L) {
    StkId func = L->ci->func.p;
    ptrdiff_t _nargs = L->top.p - func - 1;
    if (_nargs < 2) {
        ptrdiff_t _missing = 2 - _nargs;
        titan_ensure_stack(L, (int)_missing);
        func = L->ci->func.p;
        while (_missing-- > 0) {
            setnilvalue2s(L->top.p);
            L->top.p++;
            _nargs++;
        }
    }
    ptrdiff_t __save_errfunc = L->errfunc;
    int __installed_errfunc = 0;
    if (TITAN_UNLIKELY(!titan_errfunc_is_errorhandler(L))) {
        lua_pushcfunction(L, errorhandler);
        L->errfunc = savestack(L, L->top.p - 1);
        __installed_errfunc = 1;
    }
    CClosure *_fn = clCvalue(s2v(func));
    Udata *_mod = uvalue(&_fn->upvalue[0]);
    lua_Number _param_1 = 0;
    /* ...checkandget(float) from s2v(func + 1)... */
    lua_Integer _param_2 = 0;
    /* ...checkandget(integer) from s2v(func + 2)... */
    TString* _outparam_2 = 0;
    lua_pushvalue(L, 1); /* make space for error slot */
    lua_pushnil(L);
    lua_replace(L, 1); /* replace first stack element with nil, this is our error slot */
    titan_ensure_stack(L, 2);
    ptrdiff_t _firstret_off = savestack(L, L->top.p);
    L->top.p += 2;
    lua_Number res = interop_\u2133_fmod_titan(L, _mod, _fn, _param_1, _param_2, &_outparam_2);
    StkId _firstret = restorestack(L, _firstret_off);
    setfltvalue(s2v(_firstret), res);;
    _firstret++;
    setsvalue(L, s2v(_firstret), _outparam_2);;
    _firstret++;
    if (TITAN_UNLIKELY(__installed_errfunc)) {
        L->errfunc = __save_errfunc;
    }
    return 2;
}
```

Walking through it:

* **Argument count adjustment.** Too few arguments are padded by writing nils to fresh Lua stack slots before any
  parameter is read; the later `checkandget` calls then accept or reject
  those nils according to the declared parameter types.
  `titan_ensure_stack` uses Lua's internal raising growth path and extends the
  active frame limit; a successful reservation can relocate the stack, so the wrapper reloads
  `func = L->ci->func.p` before filling the new slots. A fixed-parameter
  wrapper deliberately ignores surplus Lua arguments. An input-variadic
  wrapper converts the surplus into an element-typed `TitanVargX` descriptor,
  capped by `TITAN_VARARG_MAX`, and passes that descriptor plus `_start = 0`
  to the native entry.
* **Error handler.** The wrapper saves `L->errfunc` and checks whether it
  already points at Titan's runtime `errorhandler`
  ([below](#the-error-handler-and-titanbacktrace)). If not, it pushes the
  handler, points `L->errfunc` at it, and restores the old value before
  returning. If an outer Titan entry or standalone bootstrap already
  installed the same handler, the wrapper reuses it instead of pushing a
  duplicate light C function. The handler is always pushed with
  `lua_pushcfunction`, because it has no upvalues and does not need a
  full C closure. Every error raised during the call passes
  through the active Titan handler first.
* **The error slot.** With parameters present, the three-line juggle
  makes stack index 1 nil: a copy of argument 1 is pushed on top —
  keeping it anchored for the GC, since `checkandget` has already
  extracted a raw pointer into a C local (arguments 2..n stay anchored
  in their original slots) — and a nil is written over slot 1. With zero
  parameters the wrapper just does `lua_pushnil(L);`. The slot was
  reserved by commit `11a2109` ("add basic error handler function to
  validate approach", upstream PR #257 — "reserve first stack slot for
  error value"), but **nothing in the current tree reads or writes it
  after reservation**: all Titan run-time errors go through `codethrow`
  → `luaL_error`. It is leftover groundwork from that experiment.
* **Module recovery.** The canonical source closure is built with the module
  `Udata` in upvalue 0, followed by its type tag, native entry pointer, fixed
  closure brand, any captures, and the declaration strict-entry trailer. A
  realized adjustment wrapper copies that module/captures and source Lua entry,
  replaces the tag/native pointer, and appends the immediate source plus target
  relay. The ordinary Lua entry therefore recovers `_mod` from
  `_fn->upvalue[0]` with `uvalue`; it does not rely on the obsolete one-upvalue
  wrapper shape.
* **Arguments.** Each parameter is a C local of its native
  [`ctype`](values-and-gc.md), filled by the checker-attached
  `DynamicCoercionPlan` from `s2v(func + i)`. The location baked into boundary error messages is
  the **function declaration's** — errors point at the declaration, not
  the call site.
* **Results.** For a fixed result shape, the wrapper reserves one stack slot per declared return
  value, saves the first return slot as a stack offset, calls the native
  function (extra returns come back through out-parameters), restores the
  slot pointer from the offset in case the native callee relocated the
  Lua stack with `titan_ensure_stack`, and writes each result into its slot with
  `setboxed` — records and unions remain their Udata, while Arrays become their canonical
  proxy Udata. `return NRET;` makes multiple Titan returns multiple
  Lua returns (`local x, y = titan_test.f(2)` works).
  For a flexible result shape it reads the caller's requested count through
  `get_nresults(L->ci->callstatus)`, subtracts the fixed prefix to derive
  `_flexwant`, allocates bounded typed backing, and calls the native entry with
  `_flexout`. It then reserves/restores the destination stack by offset, wraps
  the fixed prefix plus `_flexdesc.n_args` actual tail elements, and returns
  that actual combined count. `LUA_MULTRET` therefore requests the open tail;
  a finite Lua caller pays only for the requested tail capacity.

The strict entry shares all of that arity, error-frame, tail, result-request,
and stack-relocation machinery, but has one hidden first argument: the Titan
closure selected by dispatch. An ordinary declaration entry verifies that the
hidden value is a C closure and that its coercive entry, private header, final
strict-entry trailer, and source function tag match the declaration exactly.
The dispatch site has already established the fixed brand, so the entry does
not repeat that comparison. It roots and passes the source closure as `_fn`,
excluding the hidden argument from every user-visible arity calculation,
consumes strict `GuardPlan`s for formals/tail, and boxes results under the
source type before caller-attached strict result actions run.

A realized wrapper cannot copy this declaration entry: its target tag would
fail the baked source-tag check, while its `CClosure.f` must remain the source
entry. Its consumer-local relay uses the same shell but validates the target
tag, target native adapter/header shapes, and its own final trailer. It then
calls the target adapter with the wrapper as `_fn`; the adapter follows the
penultimate immediate-source link and executes the frozen B→A/A→B actions.
Numeric conversion and Lua truthiness are unavailable on either strict path.

The canonical source closure's `f` remains the coercive entry, and every
adjustment wrapper copies its immediate source's `f`. Source closures store a
declaration strict light C function last; wrappers store their target relay.
`codevaluecall` first performs the likely exact static-tag comparison; an exact
match uses the native pointer (ordinary body or wrapper adapter) without a Lua
registry lookup. Only after a mismatch does it compare fixed `upvalue[3]`
against `TITAN_BRAND`. Both predicates require the minimum
private shape and otherwise compare trusted raw pointer bits. A branded
mismatch pushes the closure's trailer plus the closure; non-Titan callable
values use Lua's ordinary call machinery, receive the already adjusted and
boxed static arguments, and dynamically coerce results as they enter Titan.

The guarded construction/layout/rooting details are in
[Closure adjustment wrappers](closure-adjustment-wrappers.md).

## Dynamic boundary conversion

The historical `checkandget`/`checkandset` split is now only a destination
detail. Both consume the same checker-built `DynamicCoercionPlan`; a native C
local and a `TValue` slot cannot disagree about which sources a target type
accepts. This common path serves genuine-Lua function arguments,
mutable module-variable and record-field writes from Lua, non-nil mutable Array writes,
written `value as/is T`, and non-Titan callable results.

The generated helper family renders the plan into either a C local or a
`TValue` destination. Per type, with
messages prefixed `%s:%d:%d: ` (file:line:col of the relevant
declaration, write, or cast expression),
raised as run-time errors via `luaL_error`:

| Titan type | Accepts | On failure |
| --- | --- | --- |
| `integer` | Lua integers; floats with integral value are converted | non-integral float: `type error, number '%f' has no integer representation`; otherwise `type error, expected integer but found %s` |
| `float` | Lua floats; integers converted via `(lua_Number)ivalue` | `type error, expected float but found %s` |
| `boolean` | **anything**, by Lua truthiness: `l_isfalse(exp) ? 0 : 1` | never fails |
| `nil` | only nil (`ttisnil`) | `type error, expected nil but found %s` |
| `string` | only strings (`ttisstring`); no number→string coercion | `type error, expected string but found %s` |
| `{T}` | a structurally valid canonical mutable Array proxy Udata; elements are *not* checked here | `type error, expected array but found %s` |
| `const { T }` | a structurally valid canonical const Array proxy Udata; elements are *not* checked here | `type error, expected array but found %s` |
| `{K:V}` | **any table** (`ttistable`); elements are *not* checked here | `type error, expected table but found %s` |
| `value` | anything, copied with `setobj2t` | never fails |
| `T?` | nil, otherwise the same dynamic plan as `T`; in particular `boolean?` uses Lua truthiness for every non-nil value | the base type's message |
| record or union | a full userdata whose metatable equals the nominal owner's metatable | three-way message, below |
| Interface | an existing exact wrapper, or bare full userdata whose metatable has a non-nil compiler-witnessed entry under the target Interface metatable; the entry is called for one trusted result | missing witness: `type error, expected <interface> but found %s`; forged non-callable entries raise Lua's ordinary call error |
| function | any Lua value, copied unchanged; exact/strict/Lua dispatch checks it when Titan later calls it | the later call either dispatches or raises Lua's ordinary non-callable error |
| C integer | strict: integer tag; dynamic: integer or exactly integral float that first fits `lua_Integer`; both then check the C target interval and `_Bool` admits only 0/1 | expected-tag, integer-representation, or target-range error |
| C float | strict: float tag; dynamic: either numeric tag; both then check the C target range | expected-tag or target-range error |

C scalar locals remain native C values, while boxed destinations store through
the same checked predicate. Same-or-wider floating conversion preserves NaNs
and infinities; narrowing rejects non-finite or out-of-range values while
allowing rounding and underflow. Written `is` consumes this identical
predicate without performing the cast, including when the C scalar plan is
nested beneath an Option. The complete policy and its C-expression exceptions
are normative in
[Type relations and boundary plans](type-relations-and-boundaries.md#checked-c-scalar-conversions).

The record/union nominal case compares the userdata's metatable against the
owner's metatable (read per-Lua-state from the `_mod` user value caching it) and,
on match, uses the userdata directly as the record value (there is no
wrapper to unwrap) — full excerpt and identity mechanism in
[values and the GC](values-and-gc.md#wrap-and-unwrap-at-the-boundary).
The failure message is always `type error, expected %s but found %s`,
with three arms for the found part: another Titan record or union reports its
FQTN, found through the registry's reverse metatable→name entry
(`expected test.Rec but found test.Point`). The generated native path reads
that entry directly with `luaH_get` from `G(L)->l_registry`; an unknown full
userdata reports the static name `userdata`, without consulting `__name` or
invoking `__tostring`. Anything else reports
`lua_typename` (`expected test.Rec but found number`). The coder spec asserts
the named, primitive, and unknown-userdata shapes.

The Interface leaf keeps that exact metatable comparison as its fast path.
After a mismatch it requires full userdata with a metatable and performs an
internal raw table lookup keyed by the canonical target Interface metatable.
A present entry and the original userdata are placed in traced VM slots and
called through `luaD_callnoyield` for one result. No record-kind, callability,
or returned-wrapper validation is added. Stack positions are saved as offsets
and reacquired after the call can grow the stack; a native `_base` is restored,
while a Lua-stack entry reloads from `L->ci->func.p`. The argument/result slots
already provide the required reachability, so discovery adds no parallel GC
root range.

### The integer check

The integer branch as generated for `fmod`'s second parameter:

```c
if (TITAN_LIKELY(ttisinteger(s2v(func + 2)))) {
    _param_2 = ivalue(s2v(func + 2));
} else if (ttisfloat(s2v(func + 2))) {
    lua_Number _v = fltvalue(s2v(func + 2));
    lua_Number _flt = l_floor(_v);
    if (TITAN_UNLIKELY(_v != _flt)) {
        luaL_error(L, "%s:%d:%d: type error, number '%f' has no integer representation", "interop.titan",13,1,_v);
    } else if (TITAN_UNLIKELY(!lua_numbertointeger(_flt, &_param_2))) {
        luaL_error(L, "%s:%d:%d: type error, number '%f' has no integer representation", "interop.titan",13,1,_v);
    }
} else {
    luaL_error(L, "%s:%d:%d: type error, expected integer but found %s", "interop.titan",13,1,lua_typename(L, ttype(s2v(func + 2))));
}
```

The temporaries are `lua_Number` (a double), so the integrality test
runs at full double precision: an integral-valued float is accepted and
its exact value handed to `lua_numbertointeger`, which range-checks the
conversion and raises `number '%f' has no integer representation` when
the value has a fractional part *or* falls outside the integer range.
The written `value as integer` cast inside Titan uses the same
double-precision, range-checked conversion. An implicit gradual observation
does not: its strict integer guard accepts only a Lua integer tag.

### Native-local and `TValue` destinations

The `TValue`-destination renderer serves mutable module-variable writes from
Lua, mutable record-field writes from Lua, mutable Array writers, and Option payloads. It has the
same dynamic matrix as the native-local renderer:

* **Booleans use truthiness everywhere on a dynamic boundary.**
  `mod.flag = 42`, `rec.flag = 42`, an Array write to `{boolean}`, and a
  genuine-Lua call parameter all store or pass `true`. An Option first
  preserves nil, then applies truthiness to a non-nil payload.
* **Integers match everywhere.** The renderer performs the same
  integral-float coercion as the integer entry check: an integral float
  is accepted (`mod.x = 2.0` stores `2`), a non-integral or out-of-range
  one raises `number '%f' has no integer representation`, and a
  non-number raises `type error, expected integer but found %s` — so an
  `integer?` slot or parameter behaves exactly like a plain `integer` at
  the boundary.
* **Failure is transactional.** Conversion completes into a temporary before
  a field, module slot, or Array backing table is mutated.

Strict Titan observations use the separate `GuardPlan` renderer: implicit
`value` projections, Array reads, Map reads, realized callable-adapter
components, and branded exact-tag-mismatch arguments/results accept the
runtime representation required by the static target and otherwise raise. They
never use the broad dynamic numeric/truthiness policy. Compiler-witnessed
Interface discovery is the named shared-leaf exception: an exact-wrapper miss
may perform the same raw lookup and witness call under either plan.

## Records from Lua

Lua holds the record's `Udata` (which is the record itself); field access
and method dispatch go through a metatable built once per Lua state in the
module's `_init`:

```c
luaL_newmetatable(L, "Titan record interop.Point metatable");
const void *_mtp = lua_topointer(L, -1);
lua_pushinteger(L, TITAN_RECORD);
lua_rawsetp(L, -2, TITAN_BRAND);
lua_pushliteral(L, "__metatable");
lua_pushliteral(L, "Titan record interop.Point");
lua_rawset(L, -3);
lua_pushliteral(L, "Record('interop.Point', ...)");
lua_rawsetp(L, -2, TITAN_MT_TYPE);
titan_pushmodule(L, _mod);
lua_rawsetp(L, -2, TITAN_MT_MOD);
lua_newtable(L);                 /* the membermap / fieldmap */
lua_pushliteral(L, "x");
lua_pushlightuserdata(L, (void *)interop_ℳ_Point_ℱ_x_fieldaccessor);
lua_rawset(L, -3);
/* ... "y" -> its generated typed accessor likewise ... */
lua_pushliteral(L, "move");
/* Module is upvalue of Lua entry point of method */
titan_pushmodule(L, _mod);
lua_pushcclosure(L, interop_ℳ_Point_ℱ_move_titanentry_luamethod, 1);
lua_rawset(L, -3);
lua_pushvalue(L, -1);            /* membermap */
lua_rawsetp(L, -3, TITAN_MT_MEMBERMAP); /* metatable[TITAN_MT_MEMBERMAP] = membermap */
lua_pushliteral(L, "__index");
lua_pushvalue(L, -2);            /* membermap */
titan_pushmodule(L, _mod);       /* _mod as upvalue[1] */
lua_pushcclosure(L, interop_ℳ_Point_ℱ_meta_index, 2);
lua_rawset(L, -4);
/* ... __newindex wired the same way ... */
// Set _titan_metatables[type] = metatable
TString *_type = luaS_new(L, "interop.Point");
int _hres = luaH_psetstr(_titan_metatables, _type, s2v(L->top.p-2));
if (_hres == HOK) {
  luaC_barrierback(L, obj2gco(_titan_metatables), s2v(L->top.p - 2));
} else {
  setsvalue2s(L, L->top.p - 1, _type);
  luaH_finishset(L, _titan_metatables, s2v(L->top.p - 1), s2v(L->top.p - 2), _hres);
  luaC_barrierback(L, obj2gco(_titan_metatables), s2v(L->top.p - 2));
}
lua_pop(L, 2);                   /* pop membermap and metatable */
/* Index from metatable pointer to typename for error messages */
lua_pushliteral(L, "interop.Point");
lua_rawsetp(L, LUA_REGISTRYINDEX, _mtp);
```

`__metatable` is the **string** `"Titan record interop.Point"`, so
`getmetatable(p)` returns that string — the metatable is protected — and
`setmetatable` on a record raises, as it does on any userdata
(`debug.getmetatable` still sees the real table; the cross-module
identity spec compares metatables that way). The **membermap** (fieldmap) table is
the first upvalue shared by the
`<module>_ℳ_<rec>_ℱ_meta_index` and `..._meta_newindex` closures;
the second is the module. The membermap is also stored directly in the
metatable at lightuserdata key `TITAN_MT_MEMBERMAP` for runtime reflection.
It maps each public field name to the lightuserdata address of its generated
typed accessor and each public method name to the method's Lua-entry C
closure, itself closed over the module. Local fields and local methods are
absent. The accessor maps its logical field through the separate native/UV
storage plan. Reads use checked boxing; writes use the field's dynamic
conversion plan and apply a GC barrier only to traced stores.
Reflection caches that same accessor with the module owner stored
under `TITAN_MT_MOD`; it does not inspect the metamethod closure's upvalues.

The record metatable also records:
* `TITAN_BRAND`: lightuserdata key set to integer constant `TITAN_RECORD` (3),
  distinguishing record metatables from arrays, unions, interfaces, and owned C types;
* `TITAN_MT_TYPE`: lightuserdata key set to the serialized type descriptor
  string (`types.serialize(...)`), providing discoverable runtime type schema;
* `TITAN_MT_MEMBERMAP`: lightuserdata key set to the member map table (field
  accessor addresses and method closures);
* `TITAN_MT_MOD`: lightuserdata key retaining the declaring module userdata;
* `TITAN_MT_STATICS`: lightuserdata key set to the record's static-namespace
  table containing constructors (`Point.new`) and static functions (attached during
  function/static initialization);
* `_titan_metatables["interop.Point"] = metatable`: registered in the global
  metatables table (keyed in the Lua registry by `TITAN_METATABLES_KEY`).

### `__index`: fields and methods

```c
static int interop_\u2133_Point_\u2131_meta_index(lua_State *L) {
    TValue *_recslot = s2v(L->ci->func.p + 1);
    CClosure *_func = clCvalue(s2v(L->ci->func.p));
    Udata *_mod = uvalue(&_func->upvalue[1]);
    Udata *_rec = NULL;
    /* ... full nominal checkandget of the receiver: tag compare,
       three-way "expected interop.Point but found %s" errors ... */
    TValue *_fieldslot = s2v(L->ci->func.p + 2);
    Table *_fieldmap = hvalue(&(_func->upvalue[0]));
    TValue _memberv;
    lu_byte _fieldtag = luaH_get(_fieldmap, _fieldslot, &_memberv);
    if(TITAN_LIKELY(!tagisempty(_fieldtag))) {
        if(ttisCclosure(&_memberv)) {
            setobj2s(L, L->top.p - 1, &_memberv);   /* a method */
        } else if (ttislightuserdata(&_memberv) && pvalue(&_memberv) != NULL) {
            void (*_accessor)(lua_State *, Udata *, Udata *, TValue *, int) =
                titan_cast_func(
                    void (*)(lua_State *, Udata *, Udata *, TValue *, int),
                    pvalue(&_memberv));
            _accessor(L, _mod, _rec, s2v(L->top.p - 1), 0);
        } else {
            return luaL_error(L, "malformed internal member map for record 'interop.Point'");
        }
        return 1;
    } else {
        return luaL_error(L, "%s:%d:%d: field '%s' not found in record '%s'", "interop.titan", 1, 1, lua_tostring(L, 2), "interop.Point");
    }
}
```

The receiver is re-validated with the full nominal `checkandget` even
though dispatch already went through the right metatable — so extracting
the raw metamethod with the `debug` library and calling it on a bogus
receiver still errors safely. A fieldmap hit that is a C closure is a
method, returned as-is (this is how `p:move(2, 3)` from Lua reaches the
`genluaentry` wrapper, with `p` then checked as argument 1). A non-NULL
lightuserdata hit selects the typed accessor in read mode. It loads the native
member or traced slot and boxes the result; an exact wide C number may fail
this conversion without changing storage. A record-typed field is already
its own Udata, handed out directly. Unknown keys raise
`field '%s' not found in record '%s'`, located at the record
declaration.

### `__newindex`: checked mutable writes and const rejection

`<module>_\u2133_<rec>_\u2131_meta_newindex` does the same receiver re-validation and fieldmap
lookup, but additionally requires a non-NULL **lightuserdata accessor** — so
assigning to a method name (`p.move = 2`) raises the same "not found"
error; methods are not assignable. The accessor runs in write mode and checks
the descriptor's required `isconst` boolean. A const accessor raises the const-field
write error without conversion or mutation. A mutable accessor consumes the field's
`DynamicCoercionPlan` into a temporary and, only after conversion succeeds,
stores that value in its selected native member or UV slot. A traced-slot write
also applies a GC
[write barrier](values-and-gc.md#5-write-barriers-back-for-userdata-and-tables-forward-for-closures).
For example, the traced-store portion is:

```c
TValue _converted;
/* render the field's DynamicCoercionPlan into _converted */
setobj2t(L, _dst, &_converted);
luaC_barrierback(L, obj2gco(_rec), _dst);
```

The barrier is the **back** barrier now that `_rec` is a `Udata`, not the forward
barrier the old `CClosure` record used. Mutable record-field writes from Lua
are thus **coerced and type-enforced by the same matrix as function
arguments**, while const fields remain readable but cannot be replaced.

Record functions need no record metatable: each record name becomes a plain Lua
**static-namespace table** with its public record functions inserted, held in a dedicated
`_mod` user-value slot and served by the module metatable's `__index`
(read-only) under the record's name. So `mod.Point.new(2, 3)` resolves
`mod.Point` through the module `Udata`'s `__index` to that table, then
does an ordinary table lookup plus a wrapped call — `new` was desugared
into a record function by the parser long before codegen.
To make these constructors and static methods discoverable from instance values
at runtime without going through the module table, generated initialization also
attaches this static-namespace table directly to the record metatable under the
lightuserdata key `TITAN_MT_STATICS` (`metatable[TITAN_MT_STATICS] = <statics table>`).
Local records are not entered in the module member map. Public records with a
local `new` still allocate their namespace table for Titan-internal use, but
local record functions are not inserted into the Lua-visible table.

## Arrays from Lua

Every Array proxy uses one of the canonical mutable/const per-state metatable
pair, so an outer guard remains a direct qualifier-exact metatable comparison
even for nested Arrays. Both metatables are branded under lightuserdata key
`TITAN_BRAND`: `TITAN_ARRAY` (1) for mutable arrays and `TITAN_CONST_ARRAY` (2)
for const arrays. The proxy has exactly two traced user values: user
value 1 is the private backing Table; mutable user value 2 is the Lua writer
closure chosen from the final constructed element type, while const user value
2 is nil. The backing Table retains its key-0 reverse link to the proxy.

Mutable `__newindex` handles nil first: nil deletes the backing entry
without invoking an element conversion, which is essential for
`{boolean}` because Lua truthiness would otherwise turn deletion into
`true`. For a non-nil source it calls the carried writer while holding stable
heap pointers to the proxy and backing, and receives one converted `TValue`
rooted on the Lua stack. Only then does `titan_array_set_stack` update
length/capacity/content and perform the table barrier, refreshing the converted
result from its stack index after a resize that may move the stack. A failing
conversion therefore leaves the Array unchanged.

The const metatable has `__index` and `__len` but no `__newindex`. Lua
assignment and mutating `table.*` paths therefore fail without invoking a
writer or modifying the backing. Nested read callbacks recognize either tag,
but strict/dynamic recovery still requires the qualifier named by the target
type.

Each generated module emits and caches one writer closure per constructed
mutable element type. The closure captures the owning `_mod` needed by nominal and C
conversions; it is behavior, not an Array type tag, and is never interned or
registered globally. Views such as `{integer}` observed as `{value}` keep the
same proxy and therefore the construction writer. Titan writes already have a
statically checked source and mutate the backing Table directly; only genuine
Lua writes enter `__newindex`.

Titan Array reads of either qualifier ignore the writer slot and use the strict element `GuardPlan`.
Map values are likewise checked strictly on every typed read, regardless of
whether Lua might have written the raw Table. See
[Dense Arrays](dense-arrays.md) for construction, GC, and nested-Array
details.

## Unions from Lua

Each exported union name is served by the module metatable as the same kind of
read-only static-namespace table. It contains public variant constructors and
public user-declared union functions. Generated constructors are canonical
`CClosure`s from the ABI-visible public prefix, with one positional Lua
argument per payload part. Titan named calls use their declared part names at
compile time; Lua calls still pass positional arguments through the ordinary
entry wrapper.

The value returned by a constructor is the union's `Udata` itself. Its
metatable is protected as `"Titan union <fqtn>"`; `__index` exposes only
public methods, and `__newindex` rejects every write. Variant names, the
native tag, and all payload parts are deliberately absent from
the instance map. Both metamethods re-check the exact union metatable before
dispatch, so a method extracted with `debug` cannot be borrowed onto another
record or union. Plain Lua can construct and pass union values but cannot
inspect or mutate their representation.

The backing userdata contains the active variant's native payload, starting
with a real common tag-header subobject, plus dense UV slots only for traced
parts. Generated construction and case projection follow the separate physical
plan; logical part ordinals never stand in for UV indices. Native access uses
payload members and traced access uses `Udata.uv` directly, without Lua's
uservalue getter/setter API. Collectable stores retain normal rooting and write
barriers. The producer's `TITAN_MT_PAYLOAD` reader gives reflection the tag,
logical arity, and checked boxed part values; see
[Native nominal storage](nominal-storage.md).

Like record metatables, union metatables carry discoverable runtime metadata:
* `TITAN_BRAND`: lightuserdata key set to integer constant `TITAN_UNION` (4);
* `TITAN_MT_TYPE`: lightuserdata key set to the serialized union type descriptor (`Union(...)`);
* `TITAN_MT_MEMBERMAP`: lightuserdata key holding the public method map table (also used as `__index`);
* `TITAN_MT_STATICS`: lightuserdata key holding the union's static-namespace table containing variant constructors and static functions;
* Registered in the global metatables table `_titan_metatables[<fqtn>]` (`TITAN_METATABLES_KEY`) and in the reverse pointer registry map `registry[metatable_pointer] = <fqtn>`.

## Interfaces from Lua

An Interface wrapper is a protected full userdata whose `__index` map exposes
its read-only field snapshots and public methods and whose `__newindex` rejects
every write. A field name boxes user value `2 + field_index`; a method closure
first applies the exact-or-witnessed Interface conversion to its
receiver, applies the Interface signature's dynamic argument plans, and then
loads the declaration-order payload entry. It invokes that entry with wrapper
user value 0 as the concrete owner's `_mod` and user value 1 as the concrete
receiver.

Interface metatables also carry discoverable runtime metadata:
* `TITAN_BRAND`: lightuserdata key set to integer constant `TITAN_INTERFACE` (5);
* `TITAN_MT_TYPE`: lightuserdata key set to the serialized interface type descriptor (`Interface(...)`);
* `TITAN_MT_MEMBERMAP`: lightuserdata key holding the member map table (used as `__index`);
* Registered in the global metatables table `_titan_metatables[<fqtn>]` (`TITAN_METATABLES_KEY`) and in the reverse pointer registry map `registry[metatable_pointer] = <fqtn>`.

Lua can retain and call a wrapper produced by Titan, pass it back through a
sink expecting the same nominal Interface, or pass bare full userdata whose
metatable advertises a compiler-witnessed pair. The generated witness recovers
the already checked field and method mappings rather than rediscovering
members, applies each field adjustment once in declaration order, and stores
the snapshots before publishing the wrapper. A bare
record/union with no initialized witness still fails.
Bound Interface methods use the same three-role closure split as other Titan
functions, with the wrapper captured before the strict trailer. See
[Interfaces](interfaces.md#four-dispatch-paths).

### Identity and tag security

From Lua, a record is a full userdata with stable identity: the same
instance always crosses out as the same Udata, two fresh instances are
`~=` (there is no `__eq`), and all instances of a type share one
metatable per state. That metatable pointer **is** the record's type
identity: the nominal guard reads the candidate `Udata*` and compares
`uvalue(v)->metatable` against the canonical metatable for the fully
qualified record type.

Same-named records from different modules have different FQTNs, hence
different metatables, and reject each other with both names in the error
message. Conversely, the registry synchronization of record metatables
means records built by any copy of a module's code in the state are
accepted by every other.

The trust boundary is therefore Lua code that cannot manufacture or
retag full userdata. Plain Lua cannot create full userdata at all, so
pure-Lua forgery is impossible. Debug-library or C-capable code is
outside that boundary: it can put a record metatable on foreign userdata,
which is enough to satisfy the nominal check, and an undersized or
malformed userdata may still become unsafe when later record field slots
are accessed. The current metatable check avoids the old raw-payload tag
read, but it is not a sandbox boundary against privileged Lua/C code.

## The module metatable and its members

`require` of a Titan module returns the module `Udata` itself —
`luaopen_<mangled>` calls `_init` and pushes it; there is **no separate
module table**. After `_init` completes successfully, generated module code
stores that same `luaopen_<mangled>` function under the logical module name in
`registry[LUA_PRELOAD_TABLE]`. `package.preload` aliases this registry table.
This self-publication does not write `package.loaded`; a later Lua `require`
calls the loader, receives the canonical registry `Udata`, and performs the
ordinary loaded-table update. A failed initialization does not publish its
module loader.

Every member access — exported functions, exported
variables, and per-nominal static-namespace tables — flows through a
metatable installed on the `Udata`, driven by a single **member map**
(name→slot) shared by `__index`/`__newindex`. Functions and nominal
namespaces live in their own `_mod` user-value slots and are served read-only;
exported variables also live in `_mod` slots (so Titan reads them as direct
slot accesses) and are boxed on reads. Mutable variables are dynamically
coerced on Lua writes; const-variable arms explicitly reject replacement. The generated
`__index` for exported `x` (slot 1):

```c
static int __index(lua_State *L) {
    CClosure *_me = clCvalue(s2v(L->ci->func.p));
    Udata *_mod = uvalue(&_me->upvalue[0]);
    TValue _indexv;
    lu_byte _indextag =
        luaH_get(hvalue(&_me->upvalue[1]),
                 s2v(L->ci->func.p + 2), &_indexv);
    if(TITAN_UNLIKELY(tagisempty(_indextag))) {
        return luaL_error(L,
        "member '%s' does not exist in Titan module '%s'",
        lua_tostring(L, 2), "interop");
    }
    switch(ivalue(&_indexv)) {
        case 1: {
            /* exported variable: coerce out with copyboxed */
            setobj2t(L, s2v(L->top.p - 1), &_mod->uv[1].uv);
            break;
        }
        /* exported functions / nominal namespaces: push the value from
           their uv slot read-only */
    }
    return 1;
}
```

Both metamethods are C closures closed over the module `Udata` and a
*member map* table mapping each exported name to its slot (variables,
functions, and public nominal namespaces; local variables and owners are not
entered). A
name miss raises `member '%s' does not exist in Titan module '%s'` —
generalized from the old "global variable ..." message now that
functions and nominal owners route through the same metamethods. A hit switches
on the slot index: variable reads go through `copyboxed` (a record-typed
variable remains its Udata; an Array backing becomes its canonical proxy),
while
functions and nominal namespaces are pushed read-only from their slots.
`__newindex` allows only mutable-variable writes, through the variable's
`DynamicCoercionPlan` plus the
**back** barrier `luaC_barrierback(L, obj2gco(_mod), slot)` for GC-able
types (a userdata owner) — so mutable module-variable writes from Lua are
coerced and type-checked exactly like genuine-Lua function arguments, located
at the variable's declaration. A public const variable remains readable but
its generated arm raises a const-write error before conversion; assigning to a
function or nominal namespace also errors. The metatable (registry name
`"Titan module interop metatable"`, `__metatable` protected with the
string `"Titan module interop"`) is created whenever the module exports
**any** member — functions now route through it too, so essentially every
real module has one. Without the metatable (a module that exports
nothing) the `Udata` has no members to reach and any attribute read on it
fails the userdata-has-no-`__index` way.

## The registry footprint

Everything per-Lua-state that generated code and runtime must find again
lives in the Lua registry or in GC-traced objects reachable from it. Semantic
module state and native caches never live in mutable shared or per-image C
globals; translation-unit statics are limited to immutable constants and
non-stateful wiring that is identical for every Titan module. The complete key
inventory:

| Registry key | Value |
| --- | --- |
| `"Titan module <modname>"` | the module `Udata` (`_init`'s idempotency check) |
| `"Titan module <modname> metatable"` | the module `Udata`'s member metatable (only if the module exports anything) |
| `"Titan record <fqtn> metatable"` | the record metatable (`luaL_newmetatable`) — also the record's type identity (a type check compares `uvalue(v)->metatable`) |
| `"Titan union <fqtn> metatable"` | the union metatable and exact nominal identity; its `__index` exposes only methods and its `__newindex` rejects writes |
| `"Titan interface <fqtn> metatable"` | the interface metatable and nominal wrapper identity; its `__index` exposes member snapshots/methods and its `__newindex` rejects writes |
| `"Titan owned C <display> metatable"` | the owned C metatable; stamped with `TITAN_BRAND` = `TITAN_OWNED` and `TITAN_MT_TYPE` |
| `TITAN_METATABLES_KEY` (`"9db55616-03e8-4dec-8077-618025b1bb69"`) | the global metatables table mapping each nominal fully qualified type name (`<fqtn>`) to its canonical metatable |
| `TITAN_ARRAY_METATABLE_PAIR` (`"Titan array metatable pair"`) | the canonical pair table containing the mutable and const proxy metatables; generated modules cache both Table pointers in consecutive `_mod` slots |
| `TITAN_ARRAY_METATABLE` / `TITAN_CONST_ARRAY_METATABLE` | named mutable/const projections repaired from the canonical pair for ordinary registry lookup |
| the metatable pointer itself (via `lua_rawsetp`) | the FQTN string — the reverse map, metatable → name, used only in error messages |
| `TITAN_ROOT_KEY` (`"9efb91a8-4a1b-4bdb-aa6b-b84d9ed1dd77"`) | the normalized Titan SDK/rocks-tree root cached by `titan_init_paths`/`pushroot`; current supported installs discover it through the equal Lua `PREFIX` |
| `TITAN_PATH_KEY` (`"ec10e486-d8fd-11e7-87f4-e7e9581a929c"`) | the resolved Titan search path (cached by `pushpath`) |
| `TITAN_LIBS_KEY` (`"ecfc9174-d8fd-11e7-8be2-abbaa3ded45f"`) | the dlopen-handle cache table (below) |
| `TITAN_MAIN_BOOTSTRAP_KEY` (`"41c48a97-55a5-4514-a76f-79ab028ae6e0"`) | an optional async standalone hook installed by the canonical `uv` module |
| `TITAN_MAIN_ARGC_KEY` (`"fd9c8d85-f521-4052-92e6-8af5c349e5bb"`) | the original process argument count published by a generated standalone entrypoint before module initialization |
| `TITAN_MAIN_ARGV_KEY` (`"fc1376f3-2cb7-48d4-969c-c02df930cf68"`) | the original process argument vector, replaced with the pointer returned by `uv_setup_args` when canonical `titan.uv` initializes |
| `TITAN_BT_STATE_KEY` (`"a222927d-0e7b-4f7a-93d9-1a6ce7111a5c"`) | registry-owned userdata containing the shared per-state `backtrace_state *`; invalidation clears the slot so the next capture resnapshots loaded objects without mutable per-DSO C globals |
| `TITAN_BACKTRACE_KEY` (`"57d80578-2534-4856-ad3b-bde8cba4c445"`) | the last error's raw merged backtrace string |
| `TITAN_TRACE_APPEND_KEY` (`"4f895b66-bae0-4e97-afb3-83a31f2f9e96"`) | temporary coroutine trace handoff slot used before appending resume/error propagation frames |
| `TITAN_NAMES_KEY` (`"a7c4e2f0-1d6b-4e3a-9c5f-8b2d7e0a4f16"`) | the native-symbol display-name table used by unified trace formatting |
| `TITAN_TRACE_PINNED` (`"5b3f0f7e-4b1a-4d2e-9a8c-2f6d4c1e7a90"`) | the one-shot flag that preserves an existing traceback for bare re-raise |
| `TITAN_LAZY_LIBS_KEY` (private to `ltitanlib.c`) | compiler `_loadlib`'s per-state lazy/local handle cache |
| `TITAN_LAZY_GLOBAL_LIBS_KEY` (private to `ltitanlib.c`) | generated-shim `_loadlibglobal`'s per-state canonical-path lazy/global handle cache |
| `"Titan function type <runtime identity> tag"` | a shared light-userdata identity tag for each first-class function type, using `types.runtime_identity` with named C scopes |

The UUID-string constants are defined in `titan-runtime/titan.h` and `titan-runtime/titan/ffi.h`.

### Discoverable runtime type information

Beyond string-keyed registry entries, Titan embeds discoverable runtime type
information directly in Titan metatables and function closures using
lightuserdata keys:

* **`TITAN_BRAND`** (`0x649b61b49f68a8b2`):
  - In every Titan function closure, stored in `upvalue[3]` to distinguish Titan
    closures from foreign closures on generic calls.
  - In every Titan metatable, stored as a key mapped to an integer enum distinguishing
    the type kind:
    - `TITAN_ARRAY` (1): mutable dense array
    - `TITAN_CONST_ARRAY` (2): const dense array
    - `TITAN_RECORD` (3): record
    - `TITAN_UNION` (4): union
    - `TITAN_INTERFACE` (5): interface
    - `TITAN_OWNED` (6): owned C type (`COwned`)
* **`TITAN_MT_TYPE`** (`0xD70BB58499779830`): lightuserdata key stored on
  nominal metatables (records, unions, interfaces) and owned C metatables
  mapping to the serialized type descriptor string (`types.serialize(...)`).
* **`TITAN_MT_MEMBERMAP`** (`0x310D781561E92F6D`): lightuserdata key stored on
  nominal metatables mapping to the member map table (field indices and method
  closures for records; method closures for unions; member map for interfaces).
* **`TITAN_MT_STATICS`** (`0x83370ABAA56047AE`): lightuserdata key stored on
  record and union metatables mapping to the nominal type's static table
  (containing constructors like `Point.new` and user-declared static functions).

In compiler test builds (`#ifdef TITAN_COMPILER_TESTS`),
`titan_ensure_metatables_table` additionally publishes these lightuserdata keys
into the Lua registry under their string names (`"TITAN_BRAND"`, `"TITAN_MT_TYPE"`,
`"TITAN_MT_MEMBERMAP"`, `"TITAN_MT_STATICS"`) for test inspection.

Interface witnesses add no registry key. They are ordinary traced entries at
raw `concrete_metatable[target_Interface_metatable]`; the value is the first
registered one-upvalue wrapper closure for that compiler-observed pair. The
registry roots both canonical metatables through their existing keys, and the
entry itself roots the closure and its emitting-module upvalue.

## Four shared-library loading paths

The current provider layout has four deliberately separate loading paths. They
share the ordinary
per-logical-module symbols but differ in selection, flags, cache, and whether
module initialization runs.

### 1. Lua's eager/local support bootstrap

The first `require "titan"` uses Lua's ordinary C searcher. It finds
`titan.so`, maps it with Lua's eager/local policy, calls `luaopen_titan`, and
returns only the native support table. The private source-install bootstrap
and the full combined standard image both satisfy that entry. Bare support
loading does not call a `titan.*_init`, create a standard module `Udata`, or
install the async program hook.

### 2. Compiler lazy/local interface inspection

`driver.find_compiled_interface` searches shallow-to-exact providers and uses
`titan._loadlib(path, symbol)` to inspect each existing candidate with
`RTLD_LAZY | RTLD_LOCAL`. It probes the requested `<mangled>_abi` and
`<mangled>_types` pair, calls only those metadata functions, and never runs
`_init` or globalizes the image. Handles live in an internal per-state cache.
The selected relative provider is attached transiently as `Type.Module.file`;
it is not serialized.

### 3. Titan runtime lazy/global imports

Generated code loads that exact selected provider through
`titan-runtime/titan.c`:

```c
void *some_dep_handle = loadlib(L, "some/provider.so");
titan_check_abi(L, some_dep_handle, "some_dep_abi", "some/provider.so");
titan_check_types(L, some_dep_handle, "some_dep_types", "some/provider.so",
    "Module(...)");
Udata* (*some_dep_init)(lua_State *L) =
    titan_cast_func(Udata* (*)(lua_State*),
        loadsym(L, some_dep_handle, "some_dep_init"));
```

`loadlib` consults `TITAN_LIBS_KEY`, then walks `TITAN_PATH_0_6`,
`TITAN_PATH`, or `".;<root>/lib/titan/0.6"`, with `;;` splicing the
ordinary default. It maps `dir/file` with `RTLD_LAZY | RTLD_GLOBAL`, caches
the handle by relative provider for the state, invalidates native backtrace
state, and never calls `dlclose`. Two logical modules in one image reuse the
handle and resolve different mangled entries. `titan_check_abi` and
`titan_check_types` validate the logical ABI marker and complete type/layout
manifest before native use; `loadsym` resolves handle-local symbols;
`loadglobalsym` uses `RTLD_DEFAULT` only after explicit providers initialize,
for entries owned through re-exported record aliases.

Lazy binding permits an imported extension to initialize a provider before
its ordinary unresolved function calls bind. Global visibility lets that
provider satisfy the calls. Native constructors, imported data, and taken
function-address relocations are eager and remain outside this ordering
contract.

### 4. Generated-shim lazy/global loading and promotion

Every linked source module has a generated `<logical/path>.lua` shim. It uses
`package.searchpath(provider, package.cpath)`, requires the bare support table,
and calls `titan._loadlibglobal(path, "luaopen_<logical>")`. That helper
canonicalizes the path with `realpath`, keeps a separate per-state canonical
handle cache, performs `dlopen(canonical, RTLD_LAZY | RTLD_GLOBAL)` on its
first request in that cache, and resolves the exact Lua entry. It returns
`nil, message, stage` rather than raising directly and preserves the requested
pathname in errors.

The helper deliberately does not consult Lua's C-library cache or
`_loadlib`'s local cache. For an unrelated provider this is its first
lazy/global mapping. For the combined standard library, Lua's support bootstrap
has just mapped the same `titan.so` eager/local; the second `dlopen` promotes
that process image globally before the shim invokes `luaopen_titan_uv` (or
another logical entry). It cannot undo eager relocations already performed by
Lua, so both the private bootstrap and full `titan.so` are link-complete under
eager load. A second Lua state repeats its own cache insertion and promotion
request while the operating-system loader may reuse the mapped image.

The installed standard layout has paired providers at
`<root>/lib/titan/0.6/{titan.so,titan.a}` and twenty-one generated shims below
`<root>/share/lua/5.5/titan/`; the shims use the DSO form. A direct-libuv
extension explicitly imports
`uv` and foreign-imports `uv.h`; Titan runtime initialization loads the
combined provider before lazy function calls bind. A Lua caller loads
`titan.uv` first through its generated shim. The shim route globalizes the
provider before the extension is mapped and can therefore also satisfy eager
relocations and constructors. Neither path has libuv-specific metadata or a
provider-specific runtime loader.

Every cross-module function called from a dynamic dependency is declared as a
`static` C function pointer and stitched by symbol name in `_init`; static
dependencies use plain `extern` declarations and direct calls. This includes
the reinitialization branch that re-stitches pointers when the same module code
is present twice in a process, and its `#loadmods > 1` quirk that can leave that
branch empty. The complete wiring is in the [code generator
overview](codegen-overview.md#static-vs-dynamic-dependency-wiring), and the
provider claim/search rules are in [Multi-module
libraries](multi-module-libraries.md#compiled-module-candidate-search).

## The error handler and `titan.backtrace()`

`errorhandler` (`titan-runtime/titan.c`) is the message handler every
wrapper ensures is active in `L->errfunc`. When an error is raised during
the call, it builds **one unified, intermingled, innermost→outer stack
trace** mixing pure-Lua and Titan frames in call order, stores it in the
registry under `TITAN_BACKTRACE_KEY`, then restores the stack top and
returns the **original** error object unchanged — a Lua-side `pcall` sees
exactly the error Titan raised, and the backtrace is retrieved out of
band.

The stored trace is the raw frame list only: one line per frame, with no
error message, no `stack traceback:` header, and no presentation tabs.
Consumers that print a report add that formatting themselves.

The trace is built from **two stacks walked innermost→outer in
lockstep**:

* The **CallInfo chain** (via `lua_getstack`+`lua_getinfo`, exactly as
  `luaL_traceback` does) is the backbone — it enumerates every Lua
  activation, so a single native `luaV_execute` correctly expands into
  the *multiple* Lua frames it ran (the point of the merge: a
  `Lua→Titan→Lua→Titan→…` chain yields several pure-Lua frames per
  `luaV_execute`). Lua closures become `source:line: in <name>`; genuine
  Lua C-functions (`pcall`, `string.format`, …) become `[C]: in <name>`.
* The **native libbacktrace stack** (`backtrace_full`, symbolized to
  `#line`-attributed `.titan` file/line via DWARF; on macOS this needs
  the `dsymutil`-produced `.dSYM` bundle) is used **only** to recover the
  **Titan native frames** — those whose DWARF filename ends in `.titan`,
  plus the **entry-wrapper boundaries** (recognized by the C symbol
  substring `titanentry`, which `coder.lua` stamps into every Lua
  entry-wrapper name). These native runs are **spliced** at the
  entry-wrapper boundaries. Everything else on the native side is
  dropped: interpreter and standard-library frames (matched against a
  maintained list of Lua 5.5 source filenames — dropping the *library*
  files specifically prevents double-counting a Lua C-function that
  already appears once as a CallInfo `[C]` frame), `titan-runtime/*`, and
  unsymbolized frames.

Alignment is greedy: at each C-level CallInfo the next sentinel-
terminated native Titan run is drained (a Titan entry wrapper appears as
a C function and is represented by its rich native frames, so no extra
`[C]` line is emitted for it). In the strictly-alternating Lua↔Titan
case this is exact; in the rarer `Titan→LuaC(e.g. pcall)→Titan` case an
inner Titan native run may splice one C-frame too early, but **no frame
is ever dropped** (every Lua frame and every Titan frame appears) and the
trace remains a single innermost→outer section. When libbacktrace is
unavailable (`TITAN_NO_LIBBACKTRACE`, e.g. musl/Alpine) it falls back to
raw Lua traceback lines plus raw `execinfo` C frames.

The retrieval side is the bare `titan` Lua support entry: Make compiles
`titan-runtime/ltitanlib.c` into `ltitanlib.o`, links that object alone into the
private bootstrap, and carries it once into each form of the full standard
`titan.so`/`titan.a` provider pair.
`titan.backtrace()` rawgets that
registry key. The same test-support module exposes internal `pin` and `clear`
helpers; none of these functions is part of `libtitan.a`.
Regeneration follows the **pin discipline**
(`TITAN_TRACE_PINNED`): a pinned slot (a pending re-raise) is preserved
verbatim and the pin cleared; an unpinned (fresh) error regenerates.
Coroutines use `TITAN_TRACE_APPEND_KEY` before setting the pin: an
uncaught dead-coroutine trace is staged there, then the resume/error side
captures a propagation trace, appends it, stores the combined trace under
`TITAN_BACKTRACE_KEY`, and pins that combined trace for the final
re-raise. See also the [language error-handling
chapter](../language/error-handling.md).

## The standalone entrypoint

When exactly one requested module defines `main(args: {string}):
integer`, `driver.compile_program` emits a srlua-derived C entrypoint
(`entrypoint_template` in `driver.lua`) and links it with all source module
objects, selected static providers, caller `-X` inputs, and the active runtime
SDK. Installed mode uses `lib/titan/0.6/libtitan.a`, the separate
`lib/libbacktrace.a`, and the matching `lib/liblua.a` from the Titan
SDK/rocks-tree root; checkout mode uses the same archive contract with local
`libtitan.a`, separate local
`libbacktrace.a`, and local `liblua.a`. Generic links do not receive libuv
merely from the SDK, but selecting bundled standard `titan.a` carries its
private libuv payload into an executable. The combined standard build receives
that private archive as payload in both `titan.so` and `titan.a`; system mode
instead repeats ordered pkg-config link flags at final link and never copies
them into `titan.a`. The private bundled archive is not installed in the SDK;
bundled-mode extension DSOs leave their `uv_*` calls unresolved:

* **Preload registration, not eager loading.** The C `main` creates a
  state and runs `luaL_openlibs`. `titan_init_paths` then parses the inherited
  `package.cpath` for the first `/lib/lua/5.5/?.so` entry, initializes the
  Titan module-path default from that root, and ensures
  `<root>/lib/titan/0.6/?.so` is present in `package.cpath`. The
  executable-relative Titan-owned Lua already places that template before its
  `lib/lua` entries; `<root>/bin/program` uses `<root>` unless Lua path
  environment overrides select another tree. It then registers only the main
  module's `luaopen_` function in `package.preload`; this registration
  initializes nothing.
* **`pmain`** publishes the original `argc` and `argv` under
  `TITAN_MAIN_ARGC_KEY` and `TITAN_MAIN_ARGV_KEY`, then calls
  `require("<modname>")` and retrieves and retains its `main` callable. A
  transitive canonical `titan.uv` initialization calls `uv_setup_args` once
  and stores its possibly replaced `argv` pointer back in the registry.
  `pmain` rereads that pointer, creates the standalone
  `DynamicCoercionPlan(string)` writer closure, then builds an Array with that
  writer and capacity `argc - 1` and stores `argv[i]` at logical index `i` for
  `i = 1 .. argc-1`. The program name is not inserted, so `args[0]` is nil,
  `args[1]` is the first user argument, and `#args == argc - 1`.
  Requiring first initializes transitive imports, which may install an async
  hook under
  `TITAN_MAIN_BOOTSTRAP_KEY`. After retaining the exact `main`, `pmain` calls
  `main(arg)` when the key is nil or `hook(main, arg)` when it is present. Both
  paths remain inside the one outer protected call, and the hook cannot replace
  the program's entry callable. As each transitive import finishes `_init`, its
  generated code self-registers its `luaopen_` entry in
  `registry[LUA_PRELOAD_TABLE]`. A later Lua require calls that entry, which
  returns the canonical initialized module value and lets ordinary
  `package.loaded` cache it. This includes private static imports reached by the
  initialization recursion. A linked module outside the initialized closure
  has no preload entry.
* **Top-level error handler.** The standalone bootstrap installs Titan's
  own `errorhandler` as the message handler for the `lua_pcall` of
  `pmain`. On failure, `errorhandler` captures the raw unified trace into
  `TITAN_BACKTRACE_KEY` and returns the original raised object unchanged,
  so the error object is still on the stack after `lua_pcall` returns.
* **Top-level reporting.** On `lua_pcall != 0`, `main` reads
  `registry[TITAN_BACKTRACE_KEY]`: if it is a string (the usual case for
  a Titan error), it converts the original error object with the same
  string/number, `__tostring`, or typed-placeholder policy as `lua.c`,
  then prints `<progname>: <error message>`, `stack traceback:`, and the
  raw unified trace with a tab prepended to each frame line through the
  Titan `main` frame. The standalone report removes the synthetic
  bootstrap chunk prefix from the headline and does not print the
  bootstrap Lua/C frames beyond `main`. If no trace slot exists, it
  reports only the converted error message. Either way the process exits
  non-zero.
* **Exit-code protocol.** An error reaching the top prints the report
  (`<progname>: <report>`) to stderr and exits with `EXIT_FAILURE`;
  otherwise the process exit status is `lua_tointeger(L, -1)` — the
  integer returned by Titan `main`. The spec verifies statuses 0
  and 42, and that an uncaught deep `Lua↔Titan` error prints a trace
  carrying both Lua and Titan frames.

## Safety summary

The model distinguishes **dynamic boundary conversion** from **strict gradual
observation**. Genuine-Lua function arguments, record and module writes,
non-nil Array writes, written `value as/is T`, and results returned to Titan
by a non-Titan callable consume one canonical `DynamicCoercionPlan`. Results
returned from Titan to Lua are only boxed. Implicit `value`
projections and Array/Map reads consume strict `GuardPlan`s. Callable strict
operations run either in a realized wrapper's frozen native adapter or through
the branded exact-tag-mismatch stack path. Direct numeric/Option coercions
inserted by the checker do not become structural callable consistency.

On the way **out**, every value has one canonical Lua representation:
numbers, strings, booleans and nil as-is; Maps as their ordinary Tables;
Arrays as their proxy Udata; records/unions as their stable `Udata`; and
Interfaces as their nominal wrapper Udata. Identity is preserved and no
container is copied. An exactly tagged Titan source closure uses its native body; an exactly tagged
adjustment wrapper uses its target-native adapter. A branded mismatch uses the
closure's declaration entry or target relay; a Lua closure/C function or
`__call` object uses Lua's internal call machinery and the dynamic boundary
plan. Wrapper identity is deliberately fresh when construction is realized,
but its boxed Lua representation remains that same CClosure object and its
`CClosure.f` remains the source coercive entry. Finite calls use a concrete result request;
every statically open generic producer uses
`luaD_callnoyield(..., LUA_MULTRET)` and keeps the complete run rooted on the
Lua stack. On normal return, the outer Titan caller measures, trims, validates,
and copies it under the policy selected by the callable brand.
See [flexible-return internals](flexible-returns.md) for the exact/generic
result-demand split.

The deliberate deferral is that a container boundary validates the outer
representation, not every element. A `{K:V}` argument must be a Table; a
`{T}` argument must be a structurally valid canonical proxy with two user
values and the key-0 reverse link. Lua can still mutate a Map directly; every
Titan Map read therefore applies a strict key/value guard. Array writes from
ordinary Lua are intercepted and dynamically converted by the carried writer,
but every Titan Array read still applies the strict element guard. The writer
is not evidence about the current contents. The complete conversion matrix
and nested-Array rule are in [Dense Arrays](dense-arrays.md).

**Stock Lua 5.5 table-library reality.** `table.*` accepts the proxy through
its `__index`, `__newindex`, and `__len` callbacks and therefore operates
through the maintained Array protocol. `rawget`, `rawset`, and `rawlen` require
a real Table and reject the Udata. No patched Lua or alternate Array
representation is involved.

The remaining trust boundary is explicit:

1. **Container aliasing** can leave a Map or Array with a value that does not
   satisfy a later strict read. The read raises a well-behaved type error
   before typed code uses the value.
2. **`value` is pass-through by design.** A later implicit observation is
   strict; a written cast is intentionally dynamic and records programmer
   intent.
3. **The debug API and native extensions are privileged.** Exact dispatch and
   wrapper construction trust Titan's private closure slots only after the
   existing tag/brand/header predicate; arbitrary Lua callables stay on generic
   dispatch. Debug/C code can nevertheless mutate private Array/Interface user
   values, function upvalues, or nominal metatables and thereby violate Titan
   invariants. Ordinary untrusted Lua cannot do so; the debug library remains
   forbidden there.
4. **Raw C pointers are outside gradual safety.** No strict or dynamic
   `value` guard fabricates one. Only the deliberately unsafe written cast can
   extract raw pointer bits.
