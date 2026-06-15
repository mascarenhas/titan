# Code generator: overview

The code generator is `titan-compiler/coder.lua`. Its single entry point is

```lua
coder.generate(modname, ast, static_deps)  --> string (one C translation unit)
```

where `modname` is the dot-separated module name, `ast` is the module's
AST *after* `checker.check` has decorated and rewritten it, and
`static_deps` is a set (module name → `true`) of the imports whose Titan
source was available, maintained by the driver's loader. The return value
is the complete text of one C translation unit; the driver
(`driver.compile`) runs it through `pretty.reindent_c`, writes the `.c`
file next to the `.titan` source, and invokes the system C compiler
([driver and toolchain](driver.md)). One consequence of the checker's
rewriting matters constantly here: every implicit coercion is already an
`Ast.ExpCast` node and every extra multiple-return value an
`Ast.ExpExtra` node, so the coder never decides to convert anything on
its own ([the type checker](checker.md)). This chapter covers the shape
of the output and the protocols it implements; value-level details are in
[values and the GC](values-and-gc.md), per-construct translations in
[code generator: constructs](codegen-constructs.md).

## No C AST: templates, `util.render`, and `pretty.lua`

The coder builds no intermediate representation of the C program. Each
code-generation function returns C source as a Lua string, produced by
substituting into literal templates with `util.render` (`util.lua`).
Placeholders are `$VAR` or `${VAR}`; substitution is **recursive** (the
replacement text is itself rendered against the same table, so templates
nest freely); a placeholder missing from the substitution table is a hard
error — `Internal compiler error: missing template variable <name>` plus
the offending template — unless the optional `ignore_missing` flag is
passed. The coder passes it in exactly one place, `codethrow`, whose
`luaL_error` templates deliberately leave placeholders such as `$FILE`,
`$LINE` and `$COL` for an enclosing render to fill.

Because there is no C AST, there is also no real C pretty-printer.
`pretty.reindent_c` (`pretty.lua`) is a purely *heuristic* reindenter: it
strips each line, dedents before a line that starts with `}` or `)`,
indents after a line that ends with `{` or `(` (four spaces per level,
indent clamped at zero so damage stays local to one function), and
collapses runs of blank lines. For those heuristics to work, every
template must follow the style contract in `pretty.lua`'s header comment:
K&R indentation; multi-line statements must use braces; prefer `/**/`
comments over `//`; never an inline comment right after a `{`; comments
must not span lines, contain user-generated text, or contain C code.
Violations only hurt readability of the generated `.c` — but readable
generated code is a deliberate feature, so treat the contract as binding.

## Anatomy of a generated translation unit

`coder.generate` assembles the unit from a fixed preamble template plus
a `code` list filled in two passes over the toplevels (imports, variables
and records first; functions second). The pieces appear in this order:

1. **Preamble includes**: `<stdlib.h>`, `<string.h>`, `<math.h>`, then
   Lua's **internal** headers (`lobject.h`, `ltable.h`, `lvm.h`, `lgc.h`,
   `lstring.h`, `lfunc.h`, `ldo.h`, `ltm.h`, plus `luaconf.h` and
   `lauxlib.h`) and `titan.h` from `titan-runtime/`. The internal headers
   are the point: generated code manipulates `TValue`s, tables and the
   Lua stack directly instead of going through the Lua C API — which is
   what makes Titan fast and ties each compiler release to one Lua
   version (currently 5.5.0).
2. **Foreign `#include`s** (`$FOREIGNIMPORTS`): one per `foreign import`
   — `#include "<header>"` for an absolute header path,
   `#include <<header>>` otherwise ([FFI internals](ffi-internals.md)) —
   followed by an `#ifdef __clang__` block silencing two warnings.
3. **Cross-module declarations** (`$INCLUDES`, filled by
   `init_data_from_other_modules`): `extern` or `static`-function-pointer
   declarations for every imported function actually called, plus a
   `static const void *<mangled-fqtn>_typetag;` cache per external record
   used (see the wiring section below).
4. **Forward signatures** (`$SIGS`): the native-convention prototype of
   every function in this module, plus
   `extern CClosure *<dep>_init(lua_State *L);` per static import.
5. **Record support**: first, *up front* (before any record body), a
   `static const void *<mangled-fqtn>_typetag;` forward declaration for
   every record in the module — emitted ahead of the bodies so a field
   whose type is a record declared later in the file, or a pair of
   mutually-recursive records, references an already-declared tag. Then,
   per record (from `coderecorddec`), the
   `__index_<rec>`/`__newindex_<rec>` metamethods serving field access
   from Lua ([Lua interop internals](lua-interop-internals.md)).
6. **Function bodies**: for each function, method and static, the
   native-convention body followed by its Lua entry wrapper (local
   functions get no wrapper).
7. **Module-global metamethods**: if the module has exported variables,
   one `__index`/`__newindex` pair serving them through the module
   table's metatable.
8. **`<prefix>_types`**, **`<prefix>_init`**, **`luaopen_<prefix>`**: the
   module-protocol functions, described below.

A trimmed but real example (elisions marked `...`) — this module:

```lua
-- counter.titan
x = 1
function inc(n: integer): integer
    return n + x
end
```

generates:

```c
#include <stdlib.h>
...                /* C library and Lua internal headers, titan.h, pragmas */

lua_Integer counter_inc_titan(lua_State *L, CClosure *_mod, lua_Integer _param_n);

lua_Integer counter_inc_titan(lua_State *L, CClosure *_mod, lua_Integer _param_n) {
    {
        return (_param_n+ ivalue(&_mod->upvalue[1]));
    }
}

static int counter_inc_lua(lua_State *L) {
    ...    /* arity check, error handler, checkandget arguments */
    lua_Integer res = counter_inc_titan(L, _mod, _param_1);
    setivalue(s2v(_firstret), res);
    ...
}

static int __index(lua_State *L) { ... }    /* module metatable: 'x', read  */
static int __newindex(lua_State *L) { ... } /* module metatable: 'x', write */
int counter_types(lua_State* L) { ... }     /* serialized interface, below  */

static int _initialized = 0; /* tags and external functions are set up */
CClosure *counter_init(lua_State *L) { ... }

int luaopen_counter(lua_State *L) {
    CClosure *mod = counter_init(L);
    setobj2s(L, L->top.p, &mod->upvalue[0]);
    L->top.p++;
    return 1;
}
```

Symbol names come from `mangle_qn` (`coder.lua`), which replaces `.` and
`-` with `_`: module `foo.bar` yields `foo_bar_init`, `foo_bar_types` and
`luaopen_foo_bar`; a function `f` in it becomes `foo_bar_f_titan` /
`foo_bar_f_lua`; methods and statics use
`<mangled-fqtn>_<name>_titanmethod` / `_luamethod` and `_titanstatic` /
`_luastatic`.

## Two C functions per Titan function

Every Titan function compiles to **two** C functions — a native-convention
function used by Titan-to-Titan calls, and a Lua-stack entry wrapper for
calls from Lua; local (`local function`) functions get only the native one.

### The Titan-native function and its calling convention

The authoritative statement is the comment above `codefuncdec` in
`coder.lua`:

```
-- Titan calling convention:
--     first parameter is a lua_State*, other parameters
--     get the other arguments, with each being its actual
--     native type. Garbage-collectable arguments also need
--     to be pushed to the Lua stack by the *caller*. The
--     function returns its first return value directly.
--     Other return values go in out parameters, following
--     the in parameters. Gc-able return values *do not*
--     need to be pushed by the callee, as it is assumed
--     that the caller is going to push them if needed and
--     just returning from a function does not call GC
```

The signature shape, produced by `function_sig`:

```c
RETTYPE f(lua_State *L, CClosure *_mod, [CClosure *self,]
          <ctype(param_1)>, ..., <ctype(param_n)>,
          <ctype(ret_2)> *_outparam_2, ..., <ctype(ret_m)> *_outparam_m);
```

`RETTYPE` is `ctype(rettypes[1])` — the unboxed C type of the first
return value (`lua_Integer`, `TString*`, `Table*`, `TValue`, `CClosure*`,
…; full map in [values and the GC](values-and-gc.md)); a function
returning only `nil` returns `int` and ends with `return 0;`. `_mod` is
the callee's **own** module closure; a cross-module caller passes it from
one of its upvalues. The `CClosure *self` slot exists only for methods
(`Type.Method`) and is named `__self__` in the generated body. Return
values 2..m are written through out-pointers following the declared
parameters. Real signatures from a generated module:

```c
TString*    packtest_Point_getname_titanmethod(lua_State *L, CClosure *_mod, CClosure* __self__);
lua_Integer packtest_two_titan(lua_State *L, CClosure *_mod, TString* *_outparam_2);
```

A Titan-to-Titan call is therefore an ordinary C call — no Lua stack
traffic, no `CallInfo`, no boxing of integers, floats or booleans. The
stack is used only as a **GC anchor**, under two rules:

* **The caller anchors GC-able arguments.** Every garbage-collectable
  argument must already be visible to the collector from a stack slot
  owned by the caller. In practice this falls out of the expression
  discipline: every GC-able intermediate result is computed into a
  temporary with a paired stack slot (`newtmp` with `isgc`), so by the
  time it is an argument it is anchored. (Parameters *reassigned* inside
  the callee additionally get their own slot in the callee's preamble.)
* **The callee does not push its returns.** This is safe because merely
  returning from a C function cannot trigger a collection; the caller
  (`codecall`) stores every GC-able return value into a stack slot it
  reserved *before* doing anything else that could allocate. The Lua
  entry wrapper plays the caller's role for Lua callers.

### The Lua entry wrapper

For every exported function, method and static, `genluaentry` emits a
companion `static int <name>_lua(lua_State *L)` with the standard
`lua_CFunction` signature. It checks arity strictly (raising
`calling Titan function %s with %d arguments, but expected %d`), installs
the runtime's `errorhandler` as `L->errfunc` for the duration of the
call, recovers `_mod` from the wrapper closure's single upvalue, checks
and converts each argument with `checkandget`, reserves one stack slot
per return value, calls the native function, and writes the results back
with `setwrapped` (which hands records to Lua as their userdata wrapper).
The full anatomy — per-type boundary checks, error-slot juggling, exact
error messages, safety argument — is in
[Lua interop internals](lua-interop-internals.md).

## The module protocol

All per-Lua-state module state lives in one `CClosure` (`_mod`) created
by `_init`: `upvalue[0]` is the Lua-visible module table; the remaining
upvalues hold module variables, imported modules' closures, and cached
record metatables (allocation order below). Every generated function
receives this closure as its `_mod` parameter; the Lua wrappers recover
it from their closure upvalue. Around `_mod`, each module exports three
protocol symbols:

### `<prefix>_init` — idempotent at two levels

```c
static int _initialized = 0; /* tags and external functions are set up */
CClosure *counter_init(lua_State *L) {
    lua_checkstack(L, 10);
    lua_getfield(L, LUA_REGISTRYINDEX, "Titan module counter");
    if(lua_isnil(L, -1)) {
        _initialized = 1;
        /* create and register _mod; $LOADMODULES1 (dlopen dynamic deps),
           $INITMODULES (dep inits), $INITRECORDS (record metatables),
           $INITVARS (variable initializers); module table into upvalue[0];
           install functions; $CREATEMETA (variable metatable); $INITTAGS */
        return _mod;
    } else {
        CClosure *_mod = clCvalue(s2v(L->top.p - 1));
        lua_pop(L, 1);
        if(!_initialized) {
            _initialized = 1;
            $LOADMODULES2  /* re-stitch dlopened function pointers */
            $INITTAGS      /* re-fetch the tag cache */
        }
        return _mod;
    }
}
```

Idempotency works at two independent levels:

* **Per Lua state**: the module closure is registered in the Lua registry
  under `"Titan module <modname>"`; a second `require`, or a dependent
  module calling `_init` again, finds it and returns it untouched. A
  second Lua *state* in the same process misses the registry and gets a
  fresh closure, module table and metatables — there is no per-state C
  global state, so one compiled module serves many states.
* **Per process / translation unit**: the C `static int _initialized`
  guards the genuinely process-global pieces — record-tag statics and
  dlsym'd function pointers. This branch matters when the *same module's
  code* is present twice in a process (e.g. linked into an executable and
  also dlopened as someone else's dependency): the registry says the
  module exists, but this copy of the code still needs its statics
  stitched from the registry and the shared libraries.

*Detail:* the re-initialization branch substitutes `$LOADMODULES2` only
when the dynamic-load list has more than one entry (`#loadmods > 1` in
`coder.generate`); with exactly one entry it is left empty. Entries come
in two kinds — one `loadlib` handle line per dynamic dep, then one
`loadsym` stitch line per imported function, always after its handle —
so a single entry is necessarily a bare handle with no function pointers
to re-stitch, and skipping it just avoids declaring an unused handle.
(The converse is not exact: two dynamic deps with no functions called
would still re-emit their handles.)

### `luaopen_<prefix>` and `<prefix>_types`

`luaopen_<mangled-modname>` is what `require` finds: it calls `_init` and
pushes `mod->upvalue[0]` — so **`require` returns a plain Lua table**,
holding one C closure per exported function and one subtable per record
(carrying its statics), with exported variables served by the module
table's metatable. `<prefix>_types` is the separate-compilation
interface:

```c
int counter_types(lua_State* L) {
    lua_pushliteral(L, "Module('counter',{ModuleVariable('counter', 'x', Integer()),...})");
    return 1;
}
```

The literal is `types.serialize(ast._type)`: a Lua *expression* that
rebuilds the module's type when evaluated with `types.lua`'s constructors
as its environment. When the driver's loader finds only a compiled `.so`
for an import, it loads this one symbol with `package.loadlib`, calls it,
and `load`s `"return " .. serialized` to recover the interface — letting
the checker type the importing module against a dependency whose source
is gone. The policy is static linkage when the source is present and
dynamic linkage otherwise, and the tests' in-memory `tableloader`
exercises the same serialization round-trip. See
[driver and toolchain](driver.md).

## Static vs dynamic dependency wiring

`coder.generate` decides per import, by `static_deps[modname]`
(`import_module` and `init_data_from_other_modules`).

**Static** (the dep's `.titan` source was compiled in and its objects are
linked into the same artifact): plain `extern` declarations and direct
calls — each cross-module function used gets an `extern` prototype in
`$INCLUDES`, and the dep's init is declared and called directly:

```c
extern CClosure *dep_init(lua_State *L);
/* in _init: */ { CClosure *_m = dep_init(L); setclCvalue(L, &_mod->upvalue[1], _m); }
```

**Dynamic** (`.so`-only dep): each imported function is declared in
`$INCLUDES` as a `static` function *pointer*; the generated `_init`
dlopens the library and stitches the pointers by symbol name with the
runtime's `loadlib`/`loadsym` (`titan-runtime/titan.c`: Titan-path
search, registry-cached handles, Lua error on failure):

```c
static CClosure* (*dep_mk_titan)(lua_State *L, CClosure *_mod, lua_Integer);
/* in _init ($LOADMODULES1), at first init in the process: */
void *dep_handle = loadlib(L, "dep.so");
dep_mk_titan = titan_cast_func(CClosure* (*)(lua_State *L, CClosure *_mod, lua_Integer),
                               loadsym(L, dep_handle, "dep_mk_titan"));
```

The dep's `_init` is fetched and called the same way inside
`$INITMODULES`. In both regimes the *call sites are identical* C calls —
only the storage class of the callee name differs — and the caller passes
the callee's module closure read from its own upvalue:
`dep_mk_titan(L, clCvalue(&_mod->upvalue[1]), 7)`. Record tags and
metatables of imported records are not wired through symbols at all: they
synchronize through the Lua registry at init time (`"Titan record <fqtn>
tag"` / `"... metatable"`; [Lua interop internals](lua-interop-internals.md)).

## Upvalue allocation

`allocate_upvalues` assigns `_mod` upvalue slots before any code is
generated. `nextupvalue` pre-increments from 0, so slot 0 is always the
module table; then come **exported (non-`local`) module variables, in
declaration order** (slots 1..n); then local module variables and
imports, in declaration order; and finally, lazily during codegen, record
metatables (`type2metatable`) and the module closures needed only for
cross-module *method* calls (`ctx.modules`), both filled in by
`init_data_from_other_modules`.

Exported variables come first because their slot numbers are part of the
module's ABI: an importing module never sees this module's AST — in
`import_module` it recomputes the variables' upvalue indices on its own,
by numbering the `Type.ModuleVariable` members of the *serialized
interface* 1..n in order. Cross-module variable access then compiles to a
direct slot read, `clCvalue(&_mod->upvalue[MOD])->upvalue[VAR]`, with no
name lookup; if local variables or imports could claim earlier slots, the
importer's numbering would diverge from reality. (The module metatable's
name→slot varmap, serving the same variables to Lua, bakes in the same
indices.) Record *tags*, by contrast, live in plain C statics because
their value is identical across all instances of the module in a state,
while record *metatables* are per-Lua-state objects and must live in
upvalues — see the comment above `allocate_upvalues` in `coder.lua`.

## Per-function code-generation contexts

Code generation for one function body runs inside a context created by
`newcontext(tlcontext)`. Its bookkeeping fields:

* `tmp` — autoincrement counter for temporary names (`_tmp_1`, …).
* `depth` / `nslots` — current Lua-stack-slot depth and its high-water
  mark. `newslot(ctx, name)` hands out the next slot as
  `TValue *<name> = s2v(_base + <depth>);`, bumping both; `pushd`/`popd`
  save and restore `depth` around blocks and loop bodies so sibling
  blocks reuse slots. The final `nslots` sizes the function preamble. The
  preamble **always** declares `_base = L->top.p`, and only when
  `nslots > 0` does it additionally run `luaC_checkGC`, reserve `nslots`
  stack slots above `_base`, and nil them. Every `return` unconditionally
  restores `L->top.p = _base` first — because an early return is coded
  before the function's final `nslots` is known (a later statement can
  still raise it), the reset is uniform across all return paths (a no-op
  when no slots were reserved) rather than chosen per-return from the
  current slot count.
* `allocations` — incremented by every `newslot`; loop generators compare
  it across the loop body and emit a per-iteration `luaC_checkGC(L)` only
  when the body actually allocates.
* `names` — autoincrement suffixes used by `localname` to give each
  declared local a distinct C name (`_local_x_1`, `_local_x_2`, …), so
  Titan redeclaration and shadowing translate to valid C.
* Shared accumulators pointing back into the toplevel context (`tags`,
  `metatables`, `functions`, `variables`, `modules`): codegen records
  here each external record, function or variable it touches;
  `init_data_from_other_modules` later turns the sets into declarations
  and init-time wiring.

The central value-handling idiom is the **dual representation** produced
by `newtmp(ctx, typ, isgc)`: a C variable `_tmp_N` of the value's native
unboxed type, paired — when the type is garbage-collectable — with a
stack slot `_tmp_N_slot`. Code computes into the C variable and
immediately stores into the slot, so the value is visible to the
collector before the next possible allocation. When a slot is required,
where `luaC_checkGC` goes, and which write barrier each store needs are
the subject of [values and the GC](values-and-gc.md).
