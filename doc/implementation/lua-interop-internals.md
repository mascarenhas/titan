# Lua interop internals

This chapter describes the machinery at the Lua↔Titan boundary: the
generated wrapper every public function gets, the per-type checks that
admit Lua values into typed code, the metatables that serve records and
module variables to Lua, the registry entries holding it all together,
the dynamic loader, the error handler, the standalone-executable
entrypoint, and the safety argument. Value representations (records and
the module state `_mod` as a single tagged `Udata` each) are in
[values and the GC](values-and-gc.md); the `_init`/`luaopen` protocol
and dependency linking are in the
[code generator overview](codegen-overview.md); the user-facing view is
[the language chapter on interoperability](../language/lua-interop.md).

All generated-C excerpts are real output of `coder.generate` for this
module:

```lua
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

## The Lua entry wrapper (`genluaentry`)

Every Titan function exists as [two C functions](codegen-overview.md):
the native-convention one used by Titan→Titan calls, and a
`lua_CFunction` wrapper that Lua calls. `genluaentry` in `coder.lua`
emits the wrapper for every non-`local` top-level function
(`<mod>_<name>_titanentry_lua`, modulo C identifier mangling), every
method (`…_titanentry_luamethod`) and every static
(`…_titanentry_luastatic`); `local` functions get **no wrapper at all** and are
unreachable from Lua. For methods, the parameter list is prefixed with
the record's nominal type, so `self` is checked like any record-typed
argument. The generated wrapper for `fmod`, trimmed only of the two
argument checks (shown in the next section):

```c
static int interop_fmod_titanentry_lua(lua_State *L) {
    StkId func = L->ci->func.p;
    ptrdiff_t _nargs = L->top.p - func - 1;
    if(_nargs > 2) {
        luaL_error(L, "calling Titan function %s with %d arguments, but expected at most %d", "fmod", (int)_nargs, 2);
    }
    if (_nargs < 2) {
        ptrdiff_t _missing = 2 - _nargs;
        lua_checkstack(L, (int)_missing);
        func = L->ci->func.p;
        while (_missing-- > 0) {
            setnilvalue(s2v(L->top.p));
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
    lua_checkstack(L, 2);
    ptrdiff_t _firstret_off = savestack(L, L->top.p);
    L->top.p += 2;
    lua_Number res = interop_fmod_titan(L, _mod, _fn, _param_1, _param_2, &_outparam_2);
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

* **Argument count adjustment.** The wrapper rejects too many arguments
  with the error `calling Titan function %s with %d arguments, but
  expected at most %d` and the unqualified Titan name. Too few arguments
  are padded by writing nils to fresh Lua stack slots before any
  parameter is read; the later `checkandget` calls then accept or reject
  those nils according to the declared parameter types. `lua_checkstack`
  can relocate the stack, so the wrapper reloads
  `func = L->ci->func.p` before filling the new slots.
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
* **Module recovery.** The wrapper is registered as a C closure over the
  module `Udata` (`titan_pushmodule(L, _mod); lua_pushcclosure(L,
  interop_fmod_lua, 1)` — `titan_pushmodule` now pushes the udata), so
  `_mod` is recovered from its upvalue with `uvalue`.
* **Arguments.** Each parameter is a C local of its native
  [`ctype`](values-and-gc.md), filled by `checkandget` from
  `s2v(func + i)`. The location baked into boundary error messages is
  the **function declaration's** — errors point at the declaration, not
  the call site.
* **Results.** The wrapper reserves one stack slot per declared return
  value, saves the first return slot as a stack offset, calls the native
  function (extra returns come back through out-parameters), restores the
  slot pointer from the offset in case the native callee relocated the
  Lua stack with `lua_checkstack`, and writes each result into its slot with
  `setwrapped` — which for a record is just `setslot`, since the record
  *is* its Udata. `return NRET;` makes multiple Titan returns multiple
  Lua returns (`local x, y = titan_test.f(2)` works).

## `checkandget`: the per-type entry check

`checkandget(ctx, typ, cvar, exp, loc)` renders *the* check every Lua
value passes to enter typed Titan code. Besides wrapper arguments and
`self`, the same template guards the receivers of record
`__index`/`__newindex` (below), `value`→`T` casts inside Titan, and
every array/map element read — table interiors are never trusted
([code generator: constructs](codegen-constructs.md)). Per type, with
messages prefixed `%s:%d:%d: ` (file:line:col of the relevant
declaration, or of the read/cast expression for table reads and casts),
raised as run-time errors via `luaL_error`:

| Titan type | Accepts | On failure |
| --- | --- | --- |
| `integer` | Lua integers; floats with integral value are converted | non-integral float: `type error, number '%f' has no integer representation`; otherwise `type error, expected integer but found %s` |
| `float` | Lua floats; integers converted via `(lua_Number)ivalue` | `type error, expected float but found %s` |
| `boolean` | **anything**, by Lua truthiness: `l_isfalse(exp) ? 0 : 1` | never fails |
| `nil` | only nil (`ttisnil`) | `type error, expected nil but found %s` |
| `string` | only strings (`ttisstring`); no number→string coercion | `type error, expected string but found %s` |
| `{T}` / `{K:V}` | **any table** (`ttistable`); element types are *not* checked here | `type error, expected table but found %s` |
| `value` | anything, copied with `setobj2t` | never fails |
| `T?` | nil (stores nil), else delegates to `checkandset` on the base — an `integer?` accepts an integral float just like a plain `integer`, but `boolean?` is stricter than a bare `boolean` parameter (a real boolean required) | the base type's message |
| record | a full userdata whose metatable equals the record's metatable | three-way message, below |

The record case compares the userdata's metatable against the record's
metatable (read per-Lua-state from the `_mod` user value caching it) and,
on match, uses the userdata directly as the record value (there is no
wrapper to unwrap) — full excerpt and identity mechanism in
[values and the GC](values-and-gc.md#wrap-and-unwrap-at-the-boundary).
The failure message is always `type error, expected %s but found %s`,
with three arms for the found part: another Titan record reports its
FQTN, found through the registry's reverse metatable→name entry
(`expected test.Rec but found test.Point`); a full userdata with an
unknown metatable (a non-record userdata) is *meant* to report
`luaL_tolstring` of the userdata, but
the generated code writes the userdata to `s2v(L->top.p)` without
raising the top, so `luaL_tolstring(L, -1, …)` formats the nil the
registry lookup left behind and the message actually reads
`… but found nil`; anything else reports `lua_typename`
(`expected test.Rec but found number`). The spec asserts the two
working shapes.

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
The explicit `float`→`integer` cast inside Titan uses the same
double-precision, range-checked conversion.

### `checkandset`, the `TValue`-destination twin

`checkandset(ctx, typ, dst, src, loc)` is the same idea writing into a
`TValue*` destination instead of a native C variable; it serves
module-variable writes from Lua, record-field writes from Lua, and the
option base case. Three points matter:

* **Booleans are strict here.** `checkandset` requires an actual boolean
  (`ttisboolean`), failing with `type error, expected boolean but found
  %s` — whereas a boolean *function parameter* accepts anything by
  truthiness. The asymmetry is observable: `mod.flag = 42` errors,
  `mod.setflag(42)` silently stores `true`.
* **Integers match `checkandget` here.** `checkandset` performs the same
  integral-float coercion as the integer entry check: an integral float
  is accepted (`mod.x = 2.0` stores `2`), a non-integral or out-of-range
  one raises `number '%f' has no integer representation`, and a
  non-number raises `type error, expected integer but found %s` — so an
  `integer?` slot or parameter behaves exactly like a plain `integer` at
  the boundary.
* **A cosmetic bug in the float case**: the generated C contains two
  consecutive `luaL_error` calls (visible in the `__newindex` excerpt
  below); the second is unreachable dead code.

## Records from Lua

Lua holds the record's `Udata` (which is the record itself); field access
and method dispatch go through a metatable built once per Lua state in the
module's `_init`:

```c
luaL_newmetatable(L, "Titan record interop.Point metatable");
lua_pushliteral(L, "__metatable");
lua_pushliteral(L, "Titan record interop.Point");
lua_rawset(L, -3);
lua_newtable(L);                 /* the fieldmap */
lua_pushliteral(L, "x");
lua_pushinteger(L, 0);
lua_rawset(L, -3);
/* ... "y" -> 1 likewise ... */
lua_pushliteral(L, "move");
/* Module is upvalue of Lua entry point of method */
titan_pushmodule(L, _mod);
lua_pushcclosure(L, interop_Point_move_titanentry_luamethod, 1);
lua_rawset(L, -3);
lua_pushliteral(L, "__index");
lua_pushvalue(L, -2);
lua_pushcclosure(L, __index_interop_Point, 1);
lua_rawset(L, -4);
/* ... __newindex wired the same way ... */
```

`__metatable` is the **string** `"Titan record interop.Point"`, so
`getmetatable(p)` returns that string — the metatable is protected — and
`setmetatable` on a record raises, as it does on any userdata
(`debug.getmetatable` still sees the real table; the cross-module
identity spec compares metatables that way). The **fieldmap** table is
the single upvalue shared by
`__index_<rec>` and `__newindex_<rec>`: it maps each field name to its
integer user-value index (`uv[0..n-1]` in declaration order) and each public
method name to the method's Lua-entry C closure, itself closed over the module.
Local fields and local methods are not entered in this table, but public fields
keep their original indices even when a local field came before them.

### `__index`: fields and methods

```c
static int __index_interop_Point(lua_State *L) {
    TValue *_recslot = s2v(L->ci->func.p + 1);
    Udata *_rec = NULL;
    /* ... full nominal checkandget of the receiver: tag compare,
       three-way "expected interop.Point but found %s" errors ... */
    TValue *_fieldslot = s2v(L->ci->func.p + 2);
    CClosure *_func = clCvalue(s2v(L->ci->func.p));
    Table *_fieldmap = hvalue(&(_func->upvalue[0]));
    TValue _fieldidxv;
    lu_byte _fieldtag = luaH_get(_fieldmap, _fieldslot, &_fieldidxv);
    if(TITAN_LIKELY(!tagisempty(_fieldtag))) {
        const TValue *_fieldidx = &_fieldidxv;
        if(ttisCclosure(_fieldidx)) {
            setobj2s(L, L->top.p - 1, _fieldidx);   /* a method */
        } else {
            TValue *_slot = &_rec->uv[ivalue(_fieldidx)].uv;
            switch(ivalue(_fieldidx)) {
                case 0: { setobj2s(L, L->top.p - 1, _slot); break; }
                /* ... one case per field ... */
            }
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
`genluaentry` wrapper, with `p` then checked as argument 1). An integer
hit reads the corresponding record user value; a record-typed field is
already its own Udata, handed out directly. Unknown keys raise
`field '%s' not found in record '%s'`, located at the record
declaration.

### `__newindex`: checked writes

`__newindex_<rec>` does the same receiver re-validation and fieldmap
lookup, but additionally requires the hit to be an **integer** — so
assigning to a method name (`p.move = 2`) raises the same "not found"
error; methods are not assignable. The write goes through `checkandset`
per field, followed by a GC
[write barrier](values-and-gc.md#5-write-barriers-back-for-userdata-and-tables-forward-for-closures):

```c
case 1: {
    if (TITAN_LIKELY(ttisfloat(_src))) {
        setobj2t(L, _dst, _src);
    } else if (ttisinteger(_src)) {
        setfltvalue(_dst, ((lua_Number)ivalue(_src)));
    } else {
        luaL_error(L, "%s:%d:%d: type error, expected float but found %s", "interop.titan",1,1,lua_typename(L, ttype(_src)));
        luaL_error(L, "%s:%d:%d: type error, expected float but found %s", "interop.titan", 1, 1, lua_typename(L, ttype(_src)));
    }
    break;
}
/* ... */
luaC_barrierback(L, obj2gco(_rec), _dst);
```

(The duplicated `luaL_error` is `checkandset`'s dead line.) The barrier
is the **back** barrier now that `_rec` is a `Udata`, not the forward
barrier the old `CClosure` record used. Record-field
writes from Lua are thus **type-enforced** with the standard messages;
the spec covers correct-type mutation and the not-found errors, but no
test writes a wrongly-typed value to a field from Lua. Records with zero
fields get stub `__index`/`__newindex` that always error, with an
unquoted message variant (`field %s not found in record %s`).

Record functions need no record metatable: each record name becomes a plain Lua
**static-namespace table** with its public record functions inserted, held in a dedicated
`_mod` user-value slot and served by the module metatable's `__index`
(read-only) under the record's name. So `mod.Point.new(2, 3)` resolves
`mod.Point` through the module `Udata`'s `__index` to that table, then
does an ordinary table lookup plus a wrapped call — `new` was desugared
into a record function by the parser long before codegen.
Local records are not entered in the module member map. Public records with a
local `new` still allocate their namespace table for Titan-internal use, but
local record functions are not inserted into the Lua-visible table.

### Identity and tag security

From Lua, a record is a full userdata with stable identity: the same
instance always crosses out as the same Udata, two fresh instances are
`~=` (there is no `__eq`), and all instances of a type share one
metatable per state. That metatable pointer **is** the record's type
identity: `checkandget` reads the candidate `Udata*` and compares
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
module table**. Every member access — exported functions, exported
variables, and per-record static-namespace tables — flows through a
metatable installed on the `Udata`, driven by a single **member map**
(name→slot) shared by `__index`/`__newindex`. Functions and record
namespaces live in their own `_mod` user-value slots and are served
read-only; exported variables also live in `_mod` slots (so Titan reads
them as direct slot accesses) but are coerced in and out. The generated
`__index` for exported `x` (slot 1):

```c
static int __index(lua_State *L) {
    Udata *_me = uvalue(s2v(L->ci->func.p));   /* the module Udata */
    Udata *_mod = _me;
    TValue _indexv;
    lu_byte _indextag = luaH_get(<member map>, s2v(L->ci->func.p + 2), &_indexv);
    if(TITAN_UNLIKELY(tagisempty(_indextag))) {
        return luaL_error(L,
        "member '%s' does not exist in Titan module '%s'",
        lua_tostring(L, 2), "interop");
    }
    switch(ivalue(&_indexv)) {
        case 1: {
            /* exported variable: coerce out with copyslotwrapped */
            setobj2t(L, s2v(L->top.p - 1), &_mod->uv[1].uv);
            break;
        }
        /* exported functions / record namespaces: push the value from
           their uv slot read-only */
    }
    return 1;
}
```

Both metamethods are C closures closed over the module `Udata` and a
*member map* table mapping each exported name to its slot (variables,
functions and public record namespaces; `local` variables and local records are
not entered). A
name miss raises `member '%s' does not exist in Titan module '%s'` —
generalized from the old "global variable ..." message now that
functions and records route through the same metamethods. A hit switches
on the slot index: variable reads go through `copyslotwrapped` (a
record-typed variable is handed out as its Udata — itself, now), while
functions and record namespaces are pushed read-only from their slots.
`__newindex` allows only variable writes, through `checkandset` plus the
**back** barrier `luaC_barrierback(L, obj2gco(_mod), slot)` for GC-able
types (a userdata owner) — so module-variable writes from Lua are
type-checked, located at the variable's declaration; assigning to a
function or record namespace errors. The metatable (registry name
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
| `"Titan function type <serialized type> tag"` | a shared light-userdata identity tag for each first-class function type |

The UUID-string constants are defined in `titan-runtime/titan.h`.

## Dynamic loading: `loadlib`, `loadlibwithuv`, and `loadsym`

When a dependency exists only as a compiled `.so`, the importer's
`_init` loads it at run time with two helpers from
`titan-runtime/titan.c`:

```c
void *some_dep_handle = loadlib(L, "some/dep.so");
titan_check_abi(L, some_dep_handle, "some_dep_abi", "some/dep.so");
Udata* (*some_dep_init)(lua_State *L) =
    titan_cast_func(Udata* (*)(lua_State*), loadsym(L, some_dep_handle, "some_dep_init"));
```

`loadlib(L, file)` first consults the handle cache under
`TITAN_LIBS_KEY`; on a miss it walks the Titan path — environment
variable `TITAN_PATH_0_11`, then `TITAN_PATH`, then the default
`".;<root>/lib/titan/0.11"`, with `<root>` recovered from the first
literal `package.cpath` entry ending in `/lib/lua/5.5/?.so` and `;;` in
an env value splicing that default in — trying
`dlopen(dir "/" file, RTLD_NOW | RTLD_LOCAL)` per `;`-separated directory.
The exact qualified filename `titan/uv.so` is the one exception: `loadlib`
opens it with `RTLD_NOW | RTLD_GLOBAL` so it can provide bundled libuv symbols
to extension DSOs. This remains the ordinary path for every unmarked binary
dependency. Successes are
cached for the Lua-state lifetime and the underlying DSOs remain mapped for the
process lifetime. Titan does not
`dlclose` this manually wired dependency graph: no fixed insertion order is
safe for every root/dependency load order, and finalizable Lua objects can
still retain native entry pointers while a state is closing. Total failure raises
`luaL_error(L, dlerror())`. After `loadlib`, generated dynamic-import
code calls `titan_check_abi(L, handle, "<mangled>_abi", file)`, rejecting
missing or mismatched ABI markers before any native entry point is used.
`loadsym` is `dlsym` plus the same `dlerror()` raise on a missing symbol.

Standard-library dependencies use the same loader and cache under their
ordinary qualified filenames, such as `titan/timer.so`. The Titan-owned Lua
default puts `<root>/lib/titan/0.11/?.so` before its ordinary `lib/lua`
templates, so Titan's dynamic import and Lua `require "titan.<module>"` open
the same DSO. Post-install writes only that qualified file; there are no
copied, symbolic-link, or hard-link aliases. `titan/uv.so` is consequently the
sole complete bundled-libuv provider. A compiled module's `<mangled>_types`
function optionally returns `"uv-provider"` as its second result when its
origin map contains `titan.uv`
or a `"dynamic-uv"` dependency. Compiler interface recovery uses that marker
to classify the binary as `"dynamic-uv"`, establish or validate canonical
`titan/uv.so`, and record its compiler-process file identity, even when libuv was
already global. If an eager unresolved `uv_*` relocation prevents the initial
ABI-symbol load, the open-stage diagnostic bootstraps canonical `titan/uv.so` and the
compiler retries before requiring the marker; if it is absent, the binary is
rejected and must be rebuilt with an explicit `titan.uv` import. Generated imports of that origin
call `loadlibwithuv(L, file)`, which invokes `loadlib(L, "titan/uv.so")` before
`loadlib(L, file)`. The provider therefore precedes the extension's mapping and
satisfies eager relocations and native constructors as well as ordinary
function calls; unmarked binaries continue through plain `loadlib`. A Lua
caller loading the extension directly must
`require "titan.uv"` first. The installed `titan/uv.lua` module resolves the
canonical DSO through `package.cpath`, uses `package.loadlib(path, "*")` for
global visibility, and then invokes its exact `luaopen_titan_uv` entry. Other
Lua C-module entries keep ordinary local visibility. This stock-Lua path is
portable across macOS and Linux: the provider does not locate, reopen, or
promote itself. Binary-first qualified
module resolution prevents a visible source file from accidentally replacing
the installed provider.

Every cross-module function called from a dynamic dependency is declared as a
`static` C *function pointer* and stitched
by symbol name in
`_init` (`<sym> = titan_cast_func(<type>, loadsym(L, <handle>,
"<sym>"));`); static dependencies use plain `extern` declarations and
direct calls. The full wiring — including the re-initialization branch
that re-stitches pointers when the same module's code is present twice
in a process, and its `#loadmods > 1` quirk that can leave that branch
empty — is in the
[code generator overview](codegen-overview.md#static-vs-dynamic-dependency-wiring);
the binary-first dependency and source-first explicit-root rules are covered in
[driver and toolchain](driver.md#source-vs-so-the-selection-logic).

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

The retrieval side is the separate `titan` Lua support module: Make compiles
`titan-runtime/titanlib.c` into `titanlib.o`, links that object alone into
`titan.so`, and the rockspec installs it. `titan.backtrace()` rawgets that
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
objects and the active runtime SDK. Installed mode uses `libtitan.a`, the
separate `libbacktrace.a`, and the matching `liblua.a` from the Titan
SDK/rocks-tree root; checkout mode uses the same archive contract with local
`libtitan.a`, separate local `libbacktrace.a`, and local `liblua.a`. Generic
module and program links do not receive libuv; the canonical `titan/uv.so` build
alone receives the private bundled archive (or system libuv through ordered
pkg-config link flags). The bundled archive is not installed in the SDK;
bundled-mode extension DSOs leave their `uv_*` calls unresolved:

* **Preload registration, not eager loading.** The C `main` creates a
  state and runs `luaL_openlibs`. `titan_init_paths` then parses the inherited
  `package.cpath` for the first `/lib/lua/5.5/?.so` entry, initializes the
  Titan module-path default from that root, and ensures
  `<root>/lib/titan/0.11/?.so` is present in `package.cpath`. The
  prefix-configured Titan-owned Lua already places that template before its
  `lib/lua` entries. It then
  registers the module's `luaopen_` function in
  `package.preload["<modname>"]`; the module initializes only when the script
  `require`s it.
* **`pmain`** publishes the original `argc` and `argv` under
  `TITAN_MAIN_ARGC_KEY` and `TITAN_MAIN_ARGV_KEY`, then calls
  `require("<modname>")` and retrieves and retains its `main` callable. A
  transitive canonical `titan.uv` initialization calls `uv_setup_args` once
  and stores its possibly replaced `argv` pointer back in the registry.
  `pmain` rereads that pointer, then builds the argument table with
  `lua_rawseti(L, -2, i)` for `i = 0 .. argc-1` — so `args[0]` is the program
  name and `args[1]` is the first real argument. Requiring first initializes
  transitive imports, which may install an async hook under
  `TITAN_MAIN_BOOTSTRAP_KEY`. After retaining the exact `main`, `pmain` calls
  `main(arg)` when the key is nil or `hook(main, arg)` when it is present. Both
  paths remain inside the one outer protected call, and the hook cannot replace
  the program's entry callable.
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

The model is **checked at entry, unchecked inside**. Every value
entering typed Titan code from Lua passes `checkandget`/`checkandset` at
exactly these places: function/method/static arguments including `self`
(`genluaentry`); module-variable writes from Lua (module `__newindex`);
record-field writes from Lua (record `__newindex`); record metamethod
receivers (record `__index`/`__newindex`); `value`→`T` conversions
inside Titan; and every array/map element read inside Titan — table
interiors are never trusted, so each read re-checks the element type.

On the way **out**, every value leaving Titan is an ordinary Lua value:
numbers, strings, booleans and nil as-is; arrays and maps as the *same*
Lua tables (aliased, never copied — the spec asserts table identity
across the boundary); records as their stable `Udata` (the record value
itself). Between
those edges, Titan code runs with no checks at all — Titan→Titan calls
use the native convention and trust the checker.

The deliberate deferral: **container contents are not checked at the
boundary.** A `{T}` or `{K:V}` argument only has to be a table; Lua can
place wrongly-typed elements in it before or after the call (the table
is shared), and the error surfaces later, at the Titan read site —
*deterministically*, since every read is checked, with the standard
`expected X but found Y` message. The spec exercises exactly this for
maps.

Known soft spots, all verified in code:

1. **`boolean` parameters accept anything** by truthiness — `42`
   silently becomes `true` — inconsistent with `checkandset`'s strict
   boolean for variable and field writes.
2. **Container aliasing** means Titan-exported tables can be corrupted
   from Lua after the fact; the per-read checks contain the damage to a
   run-time error, never type confusion.
3. **`value` is a free pass-through by design**, but every `value`→`T`
   conversion is checked, so it is not a laundering hole.
4. **Forged userdata from privileged Lua/C code** can defeat the
   metatable-based nominal check, and undersized userdata can become
   unsafe when record field slots are accessed; plain Lua cannot
   construct or retag full userdata, so the trust boundary holds against
   ordinary Lua code — which is the boundary Titan promises to defend.
