# Lua interop internals

This chapter describes the machinery at the Lua↔Titan boundary: the coercive
entry used by genuine Lua calls and the strict Lua-stack entry used after a
branded exact-tag mismatch, the dynamic conversion plans, the metatables that
serve records, unions, Interfaces, Arrays and module members to Lua, the
registry footprint, the shared-library loading paths, and the safety argument.
Related material lives elsewhere:

* value representations: [values and the GC](values-and-gc.md);
* the `_init`/`luaopen` protocol and dependency wiring:
  [code generator overview](codegen-overview.md#the-module-protocol);
* the conversion policy itself:
  [Type relations and boundary plans](type-relations-and-boundaries.md); this
  chapter only shows how generated C represents it;
* the error handler, `titan.backtrace()` and trace pinning:
  [error handling](error-handling.md#runtime-trace-model);
* the standalone executable entrypoint:
  [driver](driver.md#linking-a-standalone-program-drivercompile_program);
* the user-facing view: [the language chapter](../language/lua-interop.md).

Generated-C excerpts are abridged output of `coder.generate` for this module:

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

Lua-internals background: when Lua calls a C function, `L->ci->func.p` points
at the stack slot holding the function object, the arguments follow it
(`func + 1 … func + n`), and `L->top.p` points one past the last argument;
`s2v(slot)` views a stack slot as a `TValue*`. `L->errfunc` holds the stack
position of the current message handler (what `lua_pcall`'s fourth argument
normally installs).

## The two Lua-stack entries (`genluaentry`)

Every first-class Titan function has
[three entry roles](codegen-overview.md#three-entry-roles-per-first-class-titan-function):
the native entry used by exact-tag Titan→Titan calls, a coercive
`lua_CFunction` used by genuine Lua calls, and a strict Lua-stack entry used
after a branded exact-tag mismatch. `genluaentry`
(`titan-compiler/coder/declarations.lua`) emits the two stack-convention
entries for every top-level function (`…_titanentry_lua` and
`…_titanentry_strict`) and every static (`…_titanentry_luastatic` and
`…_titanentry_strictstatic`). Local top-level functions and statics also get
both entries and a canonical closure in a source-private module slot
(`allocate_upvalues`, `coder/module.lua`), but are not exported through the
module member map. A method has its `…_titanentry_luamethod`, with the record's
nominal type prepended to the parameter list so `self` is checked like any
record argument; each bound method value has separate `…_boundlua` and
`…_boundstrict` trampolines. Name construction is in `coder/names.lua`; the
naming scheme is described in
[the translation-unit anatomy](codegen-overview.md#anatomy-of-a-generated-translation-unit).

Named arguments do not affect these entries: a Titan named call is lowered to
positions by the checker, and a Lua table passed as `f { x = 1 }` is one
ordinary positional value. See [named-argument internals](named-arguments.md).

The abridged coercive entry for `fmod`, without adapter-source traversal and
the two argument conversions:

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

* **Argument count adjustment.** Missing arguments are padded with nil in
  fresh stack slots before any parameter is read; the conversions then accept
  or reject those nils by parameter type. `titan_ensure_stack` uses Lua's
  internal raising growth path and can relocate the stack, so the entry reloads
  `func = L->ci->func.p` afterward. A fixed-parameter entry ignores surplus
  arguments; an input-variadic entry collects them into a descriptor (see
  [Lua-entry vararg collection](variadic-parameters.md#lua-entry-vararg-collection)).
* **Error handler.** The entry checks whether `L->errfunc` already points at
  Titan's runtime `errorhandler`. If not, it pushes the handler with
  `lua_pushcfunction` (it has no upvalues), points `L->errfunc` at it, and
  restores the old value before returning. Nested Titan entries and the
  standalone bootstrap therefore share one handler. Its behavior is in
  [error handling](error-handling.md#runtime-trace-model).
* **The error slot.** With parameters present, the three-line juggle makes
  stack index 1 nil while a copy of argument 1 stays anchored on top (the
  conversion has already extracted a raw pointer into a C local); with zero
  parameters the entry pushes one nil. Nothing reads or writes this slot after
  reservation: run-time errors go through `codethrow` → `luaL_error`.
* **Module recovery.** The canonical source closure holds the module `Udata`
  in upvalue 0, then its type tag, native entry pointer, fixed brand, captures,
  and the declaration strict-entry trailer
  ([closures](codegen-overview.md#closures-and-captured-variables)). A
  realized adjustment wrapper copies the source's `f`, so its Lua entry follows
  the guarded immediate-source links back to the original closure and uses the
  original provider's `_mod` and captures; see
  [Closure adjustment wrappers](closure-adjustment-wrappers.md#source-lua-entry-and-target-strict-relay).
* **Arguments.** Each parameter is a C local of its native
  [`ctype`](values-and-gc.md#the-ctype-map), filled from `s2v(func + i)` by the
  checker-attached `DynamicCoercionPlan`. Boundary errors carry the function
  declaration's location, not the call site.
* **Results.** For a fixed result shape, the entry reserves one stack slot per
  declared result, saves the first slot as an offset, calls the native
  function (later results come back through out-parameters), restores the slot
  pointer because the callee may have relocated the stack, and boxes each
  result with `setboxed` (records and unions stay their `Udata`; Arrays become
  their proxy). `return NRET;` makes multiple Titan results multiple Lua
  results. Flexible result shapes derive `_flexwant` from the caller's result
  request; see [flexible-return internals](flexible-returns.md#lua-stack-entries).

The strict entry shares the arity, error-frame, tail, result-request and
relocation machinery, but takes one hidden first argument: the Titan closure
selected by dispatch. The declaration strict entry verifies that the hidden
value is a C closure whose coercive entry, private header, final strict-entry
trailer and source function tag match the declaration. The dispatch site has
already checked the brand, so the entry does not repeat it. It roots and
passes the source closure as `_fn`, excludes the hidden argument from every
arity calculation, consumes strict `GuardPlan`s for formals and tail, and boxes
results under the source type before the caller's strict result actions run.
Numeric conversion and Lua truthiness are unavailable on this path. A realized
wrapper cannot reuse the declaration strict entry because its target tag would
fail the source-tag check; it uses a consumer-local target relay built from the
same shell, described in
[Closure adjustment wrappers](closure-adjustment-wrappers.md#source-lua-entry-and-target-strict-relay).

How `codevaluecall` chooses between the native pointer, the strict trailer,
and Lua's ordinary call machinery is described in
[Calling function values](codegen-overview.md#calling-function-values-codevaluecall).

## Dynamic boundary conversion

`checkandget` (C-local destination) and `checkandset` (`TValue` destination)
in `coder/values.lua`, through `coder._dynamiccheckandget` and
`coder._dynamiccheckandset`, render the same checker-built
`DynamicCoercionPlan`, so a native local and a `TValue` slot cannot disagree
about which sources a type accepts. This path serves genuine-Lua function
arguments, mutable module-variable and record-field writes from Lua, non-nil
mutable Array writes, written `value as/is T`, and results of non-Titan
callables. Which sources each type accepts is defined in
[Dynamic coercion](type-relations-and-boundaries.md#dynamic-coercion). The
generated failures, raised with `luaL_error` and prefixed `%s:%d:%d: ` (the
declaration, write, or cast location), are:

| Titan type | On failure |
| --- | --- |
| `integer` | non-integral or out-of-range float: `type error, number '%f' has no integer representation`; otherwise `type error, expected integer but found %s` |
| `float` | `type error, expected float but found %s` |
| `boolean` | never fails (Lua truthiness: `l_isfalse(exp) ? 0 : 1`) |
| `nil` | `type error, expected nil but found %s` |
| `string` | `type error, expected string but found %s` (no number→string coercion) |
| `{T}`, `const { T }` | `type error, expected array but found %s` (outer proxy and qualifier only; elements unchecked) |
| `{K:V}` | `type error, expected table but found %s` (any table; elements unchecked) |
| `value`, function | never fails; the value is copied unchanged |
| `T?` | nil passes; otherwise the base type's message |
| record or union | `type error, expected %s but found %s`, three arms below |
| Interface | `type error, expected <interface> but found %s` when no exact wrapper or witness exists |
| C integer / C float | expected-tag, integer-representation, or target-range error |

The checked C scalar rules, including NaN and infinity handling and `_Bool`,
are in
[Checked C scalar conversions](type-relations-and-boundaries.md#checked-c-scalar-conversions).
Written `is` consumes the same predicate without performing the cast.

The record/union case compares the userdata's metatable with the owner's
canonical metatable (cached in a `_mod` user value) and on a match uses the
userdata itself as the value; see
[values and the GC](values-and-gc.md#wrap-and-unwrap-at-the-boundary). The
found part of the failure message has three arms: another Titan record or
union reports its FQTN from the registry's reverse metatable→name entry
(read directly with `luaH_get` on `G(L)->l_registry`), giving
`expected test.Rec but found test.Point`; an unknown full userdata reports
`userdata` without consulting `__name` or `__tostring`; anything else reports
`lua_typename` (`expected test.Rec but found number`).

The Interface case keeps the exact metatable comparison as its fast path.
After a miss it requires full userdata with a metatable and does a raw lookup
keyed by the canonical target Interface metatable. A present entry and the
original userdata are placed in traced VM slots and called through
`luaD_callnoyield` for one result, with no further record-kind, callability, or
result validation. Stack positions are saved as offsets and reacquired after
the call (a native `_base` is restored; a Lua-stack entry reloads from
`L->ci->func.p`). The argument and result slots already provide reachability,
so discovery adds no root range.

### The integer check

The integer branch generated for `fmod`'s second parameter:

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

The temporaries are `lua_Number`, so the integrality test runs at full double
precision and `lua_numbertointeger` range-checks the conversion. A written
`value as integer` uses the same conversion. An implicit gradual observation
does not: its strict integer guard accepts only a Lua integer tag.

### Native-local and `TValue` destinations

The `TValue`-destination renderer serves mutable module-variable writes,
mutable record-field writes, mutable Array writers, and Option payloads, with
the same matrix as the native-local renderer:

* **Booleans use truthiness everywhere on a dynamic boundary.**
  `mod.flag = 42`, `rec.flag = 42`, an Array write to `{boolean}`, and a
  genuine-Lua call parameter all store or pass `true`. An Option preserves nil
  first, then applies truthiness to a non-nil payload.
* **Integers match everywhere.** An integral float is accepted
  (`mod.x = 2.0` stores `2`), so an `integer?` slot behaves like `integer` at
  the boundary.
* **Failure is transactional.** Conversion completes into a temporary before
  a field, module slot, or Array backing table is mutated.

Strict Titan observations use the separate `GuardPlan` renderer
(`coder._checked_gradual_guard`): implicit `value` projections, Array and Map
reads, realized callable-adapter components, and branded exact-tag-mismatch
arguments and results accept only the runtime representation the static target
requires. Compiler-witnessed Interface discovery is the one shared leaf: an
exact-wrapper miss may perform the same raw lookup and witness call under
either plan.

## Records from Lua

Lua holds the record's `Udata`, which is the record itself. Field access and
method dispatch go through a metatable built once per Lua state in the
module's `_init`; the template is the `initrecs` block of `coderecorddec`
(`coder/module.lua`). It:

1. creates `"Titan record <fqtn> metatable"` with `luaL_newmetatable`;
2. sets `__metatable` to the string `"Titan record <fqtn>"`, so `getmetatable`
   returns that string and `setmetatable` raises (`debug.getmetatable` still
   sees the real table);
3. stores the lightuserdata-keyed metadata listed in
   [Discoverable runtime type information](#discoverable-runtime-type-information);
4. builds the **membermap**: each public field name maps to the lightuserdata
   address of its generated typed accessor, and each public method name to its
   Lua-entry C closure (closed over the module). Local fields and methods are
   absent. The map is stored under `TITAN_MT_MEMBERMAP` and is upvalue 0 of the
   `__index`/`__newindex` closures, whose upvalue 1 is the module;
5. registers the metatable in `_titan_metatables[<fqtn>]` and the reverse
   entry `registry[metatable pointer] = "<fqtn>"`.

A field accessor maps its logical field through the native/user-value storage
plan ([Native nominal storage](nominal-storage.md)). Reads use checked boxing;
writes use the field's dynamic conversion plan and apply a barrier only to
traced stores.

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

The receiver is re-validated with the full nominal check even though dispatch
went through the right metatable, so a metamethod extracted with the `debug`
library and called on a bogus receiver still fails safely. A C-closure hit is a
method, returned as-is (`p:move(2, 3)` from Lua then reaches the method's Lua
entry with `p` checked as argument 1). A lightuserdata hit runs the typed
accessor in read mode, which boxes the native member or traced slot; an exact
wide C number may fail this conversion without changing storage. Unknown keys
raise `field '%s' not found in record '%s'`, located at the record
declaration.

### `__newindex`: checked mutable writes and const rejection

`…_meta_newindex` performs the same receiver re-validation and lookup, but
requires a non-NULL lightuserdata accessor, so assigning to a method name
(`p.move = 2`) raises the same "not found" error. The accessor runs in write
mode and checks the field's `isconst` flag: a const field raises the const-write
error without conversion or mutation. A mutable field converts through its
`DynamicCoercionPlan` into a temporary and only then stores into the native
member or user-value slot. A traced store applies the
[back barrier](values-and-gc.md#5-write-barriers-back-for-userdata-and-tables-forward-for-closures):

```c
TValue _converted;
/* render the field's DynamicCoercionPlan into _converted */
setobj2t(L, _dst, &_converted);
luaC_barrierback(L, obj2gco(_rec), _dst);
```

Mutable record-field writes from Lua are thus coerced by the same matrix as
function arguments.

### Static namespaces

Each record name becomes a read-only Lua **static-namespace table** holding its
public record functions, stored in a dedicated `_mod` user-value slot and served
by the module metatable's `__index` under the record's name. `mod.Point.new(2, 3)`
resolves `mod.Point` through the module `Udata`, then performs an ordinary table
lookup and call. When `new` is public, the namespace table also gets a `__call`
metatable whose C bridge replaces the namespace receiver with `new` and calls it
with `lua_callk`, preserving Lua yields; see
[record constructors](record-constructors.md#lua-namespace-calls). The same
table is attached to the instance metatable under `TITAN_MT_STATICS`. Local
records are not in the module member map. A public record with a local `new`
still allocates its namespace table for Titan-internal use, but local record
functions are not inserted and no `__call` is installed.

## Arrays from Lua

Array representation, construction, barriers and nested-Array rules are in
[Dense Arrays](dense-arrays.md#representation-contract). The Lua-facing
behavior is:

* Every proxy uses one of the canonical per-state mutable/const metatables
  (`TITAN_BRAND` = `TITAN_ARRAY` or `TITAN_CONST_ARRAY`), so an outer guard is a
  qualifier-exact metatable comparison even for nested Arrays.
* Mutable `__newindex` handles nil first: nil deletes the backing entry
  without calling the writer, which matters for `{boolean}` because truthiness
  would otherwise turn deletion into `true`. A non-nil source goes through the
  proxy's writer closure (user value 2), which returns one converted `TValue`
  rooted on the Lua stack; only then does `titan_array_set_stack` update
  length, capacity and contents and apply the table barrier. A failed
  conversion leaves the Array unchanged.
* The const metatable has `__index` and `__len` but no `__newindex`, so Lua
  assignment and mutating `table.*` calls fail without touching the backing.
  Strict and dynamic recovery still require the qualifier named by the target
  type.
* Each module emits and caches one writer per constructed mutable element type,
  capturing the owning `_mod`. The writer is behavior, not a type tag: a view
  such as `{integer}` observed as `{value}` keeps the same proxy and writer.
  Titan writes are statically checked and mutate the backing directly; only
  genuine Lua writes enter `__newindex`.
* Titan reads of either qualifier ignore the writer and apply the strict
  element `GuardPlan`. Map values are likewise checked strictly on every typed
  read.

## Unions from Lua

Each exported union name is served by the module metatable as a read-only
static-namespace table containing public variant constructors and public union
functions. Constructors are canonical `CClosure`s that take one positional Lua
argument per payload part; Titan named calls use the declared part names at
compile time only.

A constructor returns the union's `Udata` itself. Its metatable is protected
as `"Titan union <fqtn>"`; `__index` exposes only public methods and
`__newindex` rejects every write. Variant names, the native tag and payload
parts are absent from the instance map. Both metamethods re-check the exact
union metatable before dispatch, so a method extracted with `debug` cannot be
borrowed onto another nominal. Plain Lua can construct and pass union values
but cannot inspect or mutate their representation; reflection reads parts
through `TITAN_MT_PAYLOAD`. The payload layout is in
[Native nominal storage](nominal-storage.md) and case dispatch in
[Unions](unions.md#generated-case-dispatch). The metatable is built by
`coder._codeuniondec` (`coder/module.lua`).

## Interfaces from Lua

An Interface wrapper is a protected full userdata (layout in
[Interfaces](interfaces.md#wrapper-representation)) whose `__index` map exposes
its read-only field snapshots and public methods and whose `__newindex`
rejects every write. A field name boxes the corresponding snapshot user value.
A method closure applies the exact-or-witnessed Interface conversion to its
receiver and the signature's dynamic argument plans, then invokes the
declaration-order payload entry with the wrapper's user value 0 (its emitting
module) and receiver. The metatable is built by `coder._codeinterfacedec`
(`coder/module.lua`).

Lua can retain and call a wrapper produced by Titan, pass it back to a sink
expecting the same Interface, or pass bare full userdata whose metatable
advertises a compiler-witnessed pair. The witness recovers the already checked
field and method mappings, applies each field adjustment once in declaration
order, and stores the snapshots before publishing the wrapper. A bare
record or union with no initialized witness still fails. Bound Interface
methods use the same three-role closure split as other functions; see
[Interfaces](interfaces.md#four-dispatch-paths).

### Identity and tag security

From Lua, a record is a full userdata with stable identity: the same instance
always crosses out as the same `Udata`, two fresh instances are `~=` (there is
no `__eq`), and all instances of a type share one metatable per state. That
metatable pointer **is** the type identity: the nominal guard compares
`uvalue(v)->metatable` with the canonical metatable for the fully qualified
type. Same-named records from different modules have different FQTNs and hence
different metatables, and reject each other with both names in the message.
Because canonical metatables are shared through the registry, records built by
any copy of a module's code in a state are accepted by every other copy.

The trust boundary is Lua code that cannot manufacture or retag full userdata.
Plain Lua cannot create full userdata, so pure-Lua forgery is impossible.
Debug-library or C-capable code is outside that boundary: it can put a record
metatable on foreign userdata, which satisfies the nominal check, and an
undersized or malformed userdata may then become unsafe when record slots are
accessed. The metatable check is not a sandbox against privileged Lua or C.

## The module metatable and its members

`require` of a Titan module returns the module `Udata` itself:
`luaopen_<mangled>` calls `_init` and pushes it, and there is no separate module
table. After a successful `_init`, the module publishes its `luaopen_<mangled>`
in `registry[LUA_PRELOAD_TABLE]` and a native descriptor in
`TITAN_MODULE_PRELOADS_KEY` (`titan_module_preload`, `titan-runtime/titan_path.c`);
this does not write `package.loaded`. How standalone programs and static
providers rely on that self-publication is in
[driver](driver.md#linking-a-standalone-program-drivercompile_program) and
[Static compiled modules](static-compiled-modules.md#three-way-validation).

Every member access (exported functions, exported variables, and per-nominal
static-namespace tables) goes through a metatable on the `Udata`, driven by one
**member map** (name → slot) shared by `__index` and `__newindex`, both C
closures over the module and the map. Functions and namespaces live in their
own `_mod` user-value slots and are served read-only; exported variables also
live in `_mod` slots (Titan reads them directly) and are boxed on read. Local
variables and owners are not in the map. The generated `__index` (built in
`coder.generate`, `coder/generate.lua`) for exported `x` (slot 1):

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

A miss raises `member '%s' does not exist in Titan module '%s'`. Variable reads
go through `copyboxed` (a record stays its `Udata`; an Array backing becomes its
proxy). `__newindex` accepts only mutable-variable writes, converted by the
variable's `DynamicCoercionPlan` and followed by
`luaC_barrierback(L, obj2gco(_mod), slot)` for collectable types; errors are
located at the variable's declaration. A public const variable's arm raises a
const-write error before conversion, and assigning to a function or namespace
also fails. The metatable (registry name `"Titan module <modname> metatable"`,
`__metatable` set to `"Titan module <modname>"`) exists whenever the module
exports any member; a module that exports nothing has none, and any attribute
read fails as on any userdata without `__index`.

## The registry footprint

Everything per-Lua-state that generated code and the runtime must find again
lives in the Lua registry or in traced objects reachable from it. Semantic
module state and native caches never live in mutable shared or per-image C
globals. Translation-unit statics hold immutable candidates and generated
code; state-dependent pointers and Interface arrays belong to the module native
payload. String keys are defined in `titan-runtime/titan.h`,
`titan-runtime/titan/ffi.h`, `titan-runtime/titan.c`
(`TITAN_ARRAY_METATABLE_PAIR`), `titan-runtime/titan_path.c` (the searcher
marker and SDK-fallback record), and `titan-runtime/ltitanlib.c` (the two
support-helper caches). The complete inventory:

| Registry key | Value |
| --- | --- |
| `"Titan module <modname>"` | canonical module `Udata`, including its native export descriptor and per-state binding caches |
| `TITAN_MODULE_PRELOADS_KEY` (`"Titan module preload providers"`) | native preload descriptors keyed by logical module name; each holds only matching loader and symbol-resolver pointers, without module state |
| `"Titan module <modname> metatable"` | the module `Udata`'s member metatable (only if the module exports anything) |
| `"Titan record <fqtn> metatable"` | the record metatable, which is also the record's type identity |
| `"Titan union <fqtn> metatable"` | the union metatable and exact nominal identity |
| `"Titan interface <fqtn> metatable"` | the Interface metatable and wrapper identity |
| `"Titan owned C <display> metatable"` | the owned C metatable |
| `TITAN_METATABLES_KEY` (`"9db55616-03e8-4dec-8077-618025b1bb69"`) | table mapping each nominal FQTN to its canonical metatable |
| `TITAN_ARRAY_METATABLE_PAIR` (`"Titan array metatable pair"`) | the canonical table holding the mutable and const proxy metatables; generated modules cache both Table pointers in consecutive `_mod` slots |
| `TITAN_ARRAY_METATABLE` / `TITAN_CONST_ARRAY_METATABLE` (`"Titan array metatable"`, `"Titan const array metatable"`) | named projections repaired from the canonical pair for ordinary registry lookup |
| the metatable pointer itself (via `lua_rawsetp`) | the FQTN string: the reverse map used only in error messages |
| `TITAN_PATH_KEY` (`"ec10e486-d8fd-11e7-87f4-e7e9581a929c"`) | the state's effective Titan path string, computed on first lookup by `titan_path.c`; a string an application stores first is used as-is |
| `TITAN_SDK_FALLBACK_KEY` (`"c2a9e5d4-1b7f-4e3a-8d26-5f9b0c7a4e18"`) | private record binding SDK-fallback eligibility to the computed path and caching the one probe outcome (`titan_path.c`) |
| `TITAN_SEARCHER_KEY` (`"6f0b7c1e-3f0a-4b8e-9c55-2d3b1f6a9e47"`) | marker that this state's `package.searchers` already has the Titan searcher (`titan_install_searcher`) |
| `TITAN_LIBS_KEY` (`"ecfc9174-d8fd-11e7-8be2-abbaa3ded45f"`) | the runtime handle cache shared by `loadlib` and the Titan searcher (paths 3 and 4 below) |
| `TITAN_MAIN_BOOTSTRAP_KEY` (`"41c48a97-55a5-4514-a76f-79ab028ae6e0"`) | an optional standalone hook installed by `titan.async` |
| `TITAN_MAIN_ARGC_KEY` (`"fd9c8d85-f521-4052-92e6-8af5c349e5bb"`) | the process argument count published by a standalone entrypoint |
| `TITAN_MAIN_ARGV_KEY` (`"fc1376f3-2cb7-48d4-969c-c02df930cf68"`) | the process argument vector, replaced by the pointer `uv_setup_args` returns when `uv.setup_process_args()` runs |
| `TITAN_BT_STATE_KEY` (`"a222927d-0e7b-4f7a-93d9-1a6ce7111a5c"`) | userdata holding the per-state `backtrace_state *`; invalidation clears it so the next capture resnapshots loaded objects |
| `TITAN_BACKTRACE_KEY` (`"57d80578-2534-4856-ad3b-bde8cba4c445"`) | the last error's raw merged backtrace string |
| `TITAN_NAMES_KEY` (`"a7c4e2f0-1d6b-4e3a-9c5f-8b2d7e0a4f16"`) | native-symbol display names for trace formatting |
| `TITAN_TRACE_PINNED` (`"5b3f0f7e-4b1a-4d2e-9a8c-2f6d4c1e7a90"`) | the one-shot flag that preserves an existing traceback for a bare re-raise |
| `TITAN_LAZY_LIBS_KEY` (`"b03f87d2-aea4-407c-87df-054d5be15ef2"`) | `titan._loadlib`'s lazy/local handle cache (path 2) |
| `TITAN_LAZY_GLOBAL_LIBS_KEY` (`"3f6cae7b-8aeb-42eb-9f72-a978cfe96f7c"`) | `titan._loadlibglobal`'s canonical-path lazy/global handle cache |
| `"Titan function type <runtime identity> tag"` | a shared light-userdata identity tag per first-class function type, keyed by `types.runtime_identity` (`coder/generate.lua`) |

The trace keys are used as described in
[error handling](error-handling.md#runtime-trace-model).

### Discoverable runtime type information

Titan metatables and function closures also carry metadata under private
lightuserdata keys, defined in `titan-runtime/titan/ffi.h`. `TITAN_BRAND` is
also stored in `upvalue[3]` of every Titan function closure, where generic
dispatch compares it as raw pointer bits.

| Key | Value | Record | Union | Interface | Owned C | Array |
| --- | --- | --- | --- | --- | --- | --- |
| `TITAN_BRAND` | kind: `TITAN_ARRAY` 1, `TITAN_CONST_ARRAY` 2, `TITAN_RECORD` 3, `TITAN_UNION` 4, `TITAN_INTERFACE` 5, `TITAN_OWNED` 6 | ✓ | ✓ | ✓ | ✓ | ✓ |
| `TITAN_MT_TYPE` | serialized type string (`types.serialize_semantic` for nominals) | ✓ | ✓ | ✓ | ✓ | |
| `TITAN_MT_PUBLIC` | whether the declaration is public | ✓ | ✓ | | | |
| `TITAN_MT_PROJECT` | generated typed field/part storage projector | ✓ | ✓ | | | |
| `TITAN_MT_CONSTRUCT` | generated default-storage construction callback | ✓ | ✓ | | | |
| `TITAN_MT_CODEC` | generated transfer codec entry, only when the module emits one | ✓ | ✓ | | | |
| `TITAN_MT_MOD` | declaring module `Udata` | ✓ | ✓ | ✓ | | |
| `TITAN_MT_MEMBERMAP` | member map: field accessors and methods (records, Interfaces), methods only (unions) | ✓ | ✓ | ✓ | | |
| `TITAN_MT_STATICS` | static-namespace table (constructors, static functions) | ✓ | ✓ | | | |
| `TITAN_MT_PAYLOAD` | generated typed payload reader | | ✓ | | | |

Record and union keys are set in `coderecorddec` and `coder._codeuniondec`,
Interface keys in `coder._codeinterfacedec` (all `coder/module.lua`),
`TITAN_MT_STATICS` and the owned C keys in `coder.generate`, and
`TITAN_MT_CODEC` by `coder._codec_binding` (`coder/nominal_codec.lua`). How
reflection consumes each key is in
[Reflection: metadata ownership](standard-library-reflect.md#metadata-ownership).

The keys are light userdata, which Lua code cannot spell. The runtime does
not publish them by name. A compiler spec that inspects a metatable from Lua
loads the fixture module `spec/fixtures/runtime_brands.titan`
(`h.with_runtime_brands` in `spec/support/helpers.lua`), whose public
variables hold `TITAN_BRAND`, `TITAN_MT_TYPE`, `TITAN_MT_STATICS`,
`TITAN_MT_MEMBERMAP`, `TITAN_MT_MOD` and `TITAN_MT_PAYLOAD`.

Interface witnesses add no registry key. They are traced entries at raw
`concrete_metatable[target_Interface_metatable]`; the value is the first
registered one-upvalue wrapper closure for that compiler-observed pair. The
registry roots both metatables, and the entry roots the closure and its
emitting-module upvalue.

## Four shared-library loading paths

Four separate loading paths share the per-logical-module symbols but differ in
selection, `dlopen` flags, cache, and whether module initialization runs. The
helpers are registered by `titan-runtime/ltitanlib.c` (`_loadlib`) and
implemented in `titan-runtime/titan_path.c` (`loadlib` and the package
searcher).

### 1. Lua's eager/local support load

A plain Lua host's first `require "titan"` uses Lua's ordinary C searcher: it
maps the support module `<root>/lib/lua/5.5/titan.so` from `package.cpath`
with Lua's eager/local policy, calls `luaopen_titan`, and returns only the
native support table. `luaopen_titan` appends the Titan searcher (path 4) to
that state's `package.searchers`. Support loading does not map any provider,
run any `titan.*_init`, create a standard module `Udata`, or install the async
program hook. Generated executables, independent states and thread children
install the searcher directly instead.

### 2. Compiler lazy/local interface inspection

`driver.find_compiled_interface` searches shallow-to-exact providers and calls
`titan._loadlib(path, symbol)` to inspect each candidate with
`RTLD_LAZY | RTLD_LOCAL`. It probes the `<mangled>_abi` and `<mangled>_types`
pair, calls only those metadata functions, and never runs `_init` or
globalizes the image. Handles are cached per state under
`TITAN_LAZY_LIBS_KEY`. The selected relative provider is attached transiently
as the module type's `file` field; it is not serialized.

### 3. Canonical Titan runtime imports

Generated code selects the logical provider through `titan-runtime/titan_path.c`:

```c
TitanModuleProvider some_dep_provider =
    titan_module_provider(L, "some.dep", "some/provider.so");
titan_check_module_abi(L, some_dep_provider, "some_dep_abi", "some/provider.so");
titan_check_module_compatibility(L, some_dep_provider, "some_dep_compatibility",
    "some/provider.so", verifier_source, verifier_length);
Udata* (*some_dep_init)(lua_State *L) =
    titan_cast_func(Udata* (*)(lua_State*),
        titan_module_symbol(L, some_dep_provider, "some_dep_init"));
```

`titan_module_provider` looks up `"Titan module some.dep"` before loading any
file. An initialized module must have a native payload beginning with
`TitanModuleData` and a non-null symbol callback, which supplies the canonical
provider's metadata, native entries and public slot symbols whether it came
from a linked executable, an archive, or a local `package.loadlib`. Returning
the canonical module does not initialize a second image's caches.

When the logical module is absent, selection first looks for a matching copied
native preload descriptor, whose resolver supplies symbols without running a
Lua loader or initializing the dependency. Only when that is also absent does
it call `loadlib` for the compile-selected relative filename. `loadlib`
consults `TITAN_LIBS_KEY`, selects the first occupied `<entry>/<file>` along the
state's effective Titan path (`TITAN_PATH_0_6`, `TITAN_PATH`, or the run-time
default `!;!/../lib/titan/0.6`, followed by the lazy SDK fallback), maps it with
`RTLD_LAZY | RTLD_GLOBAL`, caches the handle per state, invalidates native
backtrace state, and never calls `dlclose`. Two logical modules in one image
can share the handle and resolve different mangled entries. The path rules are
in [the run-time Titan
path](driver.md#the-run-time-titan-path-and-sdk-fallback).

The ABI check precedes the consumer's erased-signature and nominal-shape
checks, all before the dependency initializes. `titan_module_symbol` resolves
through the canonical/copied callback or the new handle; variable and callable
slots are provider-owned data symbols. Resolved pointers, function-tag caches
and Interface pair arrays stay in the importer's per-state native payload, so
another Lua state cannot overwrite them.

After explicit imports initialize, transitive nominal owners use the same
logical lookup with a null filename. They must already exist (an uninitialized
copied descriptor does not count) and receive their own ABI-first
compatibility checks; no global symbol lookup chooses their code. Same-binary
dependencies keep direct constant-slot access and check the linked producer's
physical identity; see
[Selective binary dependency verification](binary-compatibility.md). The full
wiring is in the
[code generator overview](codegen-overview.md#static-vs-dynamic-dependency-wiring)
and the candidate search in
[Multi-module libraries](multi-module-libraries.md#compiled-module-candidate-search).

Lazy binding lets an imported extension initialize a provider before its own
unresolved C calls bind, and global visibility lets that provider satisfy them.
This linker behavior does not choose Titan's logical provider. Native
constructors, imported data and taken function-address relocations are eager
and stay outside the initializer-ordering contract.

### 4. The Titan package searcher

`require(name)` reaches `titan_path_searcher` after Lua's own searchers. It
returns the state's canonical module first, without opening any image, then a
matching native preload loader. Otherwise it walks the shallow-to-exact
candidates of the effective Titan path root-major, probes each occupied
candidate with `dlopen(realpath, RTLD_LAZY | RTLD_LOCAL)` for the
`<mangled>_abi`/`<mangled>_types` pair, and promotes a valid claim to
`RTLD_LAZY | RTLD_GLOBAL` before checking the ABI and resolving
`luaopen_<mangled>`. The promotion happens before any initializer runs, so a
provider's unresolved calls can later bind to dependencies loaded through
path 3. It cannot undo eager relocations, so every provider must still be
link-complete with respect to eager loading. The handle joins the same
`TITAN_LIBS_KEY` cache, keyed by the image's realpath. Errors in a selected
provider raise; a clean miss returns Lua's ordinary searcher message. The full
contract is in [the Titan package
searcher](driver.md#the-titan-package-searcher).

`require` passes the requested name and the provider path to
`luaopen_<mangled>`, whose generated [file-load name
guard](codegen-overview.md#lua-entries-and-abi-type-and-layout-metadata)
rejects a different logical name with the same mangled spelling before
initialization. A `package.preload` alias, whose loader data is `":preload:"`,
is not compared.

The support table's `_loadlibglobal(path, symbol)` is a separate internal
helper for native harnesses. It canonicalizes the path with `realpath`, keeps
its own per-state cache (`TITAN_LAZY_GLOBAL_LIBS_KEY`), calls
`dlopen(canonical, RTLD_LAZY | RTLD_GLOBAL)` on the first request, and returns
the requested Lua entry or `nil, message, stage`. Because that cache is
distinct from Lua's C-library cache and `_loadlib`'s cache, its first request
in a state always performs a lazy/global `dlopen`.

The installed standard layout is the pair
`<root>/lib/titan/<version>/{titan.so,titan.a}` with no Lua files; the root
list is in
[Multi-module libraries](multi-module-libraries.md#reserved-titan-and-the-standard-library-image).
The `provider_probe` loader fixture that exercises lazy/global provider
loading is described in
[Linking a provider pair](driver.md#linking-a-provider-pair).

## Safety summary

The model distinguishes **dynamic boundary conversion** from **strict gradual
observation**. Genuine-Lua function arguments, record and module writes,
non-nil Array writes, written `value as/is T`, and results of non-Titan
callables consume one canonical `DynamicCoercionPlan`. Results returned from
Titan to Lua are only boxed. Implicit `value` projections and Array/Map reads
consume strict `GuardPlan`s. Callable strict operations run either in a
realized wrapper's frozen native adapter or through the branded
exact-tag-mismatch stack path. Direct numeric/Option coercions inserted by the
checker never become structural callable consistency.

On the way **out**, every value has one canonical Lua representation: numbers,
strings, booleans and nil as-is; Maps as their Tables; Arrays as their proxy
`Udata`; records and unions as their stable `Udata`; Interfaces as their wrapper
`Udata`. Identity is preserved and no container is copied. A realized callable
wrapper is a fresh `CClosure` whose `f` remains the source's coercive entry.
Finite generic calls use a concrete result request; statically open generic
producers use `LUA_MULTRET` and keep the run rooted on the Lua stack (see
[flexible-return internals](flexible-returns.md#choosing-the-lua-vm-result-request)).

A container boundary validates the outer representation, not every element. A
`{K:V}` argument must be a Table; a `{T}` argument must be a structurally valid
canonical proxy with two user values and the key-0 reverse link. Lua can still
mutate a Map directly, so every Titan Map read applies a strict key/value
guard. Array writes from Lua go through the carried writer, but every Titan
Array read still applies the strict element guard; the writer is not evidence
about the current contents.

**Stock Lua 5.5 table library.** `table.*` accepts the proxy through its
`__index`, `__newindex` and `__len` callbacks and therefore uses the maintained
Array protocol. `rawget`, `rawset` and `rawlen` require a real Table and reject
the `Udata`.

The remaining trust boundary is explicit:

1. **Container aliasing** can leave a Map or Array with a value that fails a
   later strict read. The read raises a type error before typed code uses the
   value.
2. **`value` is pass-through by design.** A later implicit observation is
   strict; a written cast is intentionally dynamic.
3. **The debug API and native extensions are privileged.** Exact dispatch and
   wrapper construction trust Titan's private closure slots only after the
   tag/brand/header predicate; arbitrary Lua callables stay on generic
   dispatch. Debug or C code can still mutate private Array/Interface user
   values, function upvalues, or nominal metatables and break Titan's
   invariants. Untrusted Lua must not have the debug library.
4. **Raw C pointers are outside gradual safety.** No strict or dynamic `value`
   guard fabricates one; only the deliberately unsafe written cast extracts raw
   pointer bits.
