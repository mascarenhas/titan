# Code generator: overview

The code generator is `titan-compiler/coder.lua`. Its single entry point is

```lua
coder.generate(modname, ast, static_deps)  --> string (one C translation unit)
```

where `modname` is the dot-separated module name, `ast` is the module's
AST *after* `checker.check` has decorated and rewritten it, and
`static_deps` is the driver's finalized direct-native name set. It contains
every source module compiled into the invocation plus every logical module
physically carried by a selected static provider; imports selected from DSOs
are absent. `titanc` passes the resolver context's
`native_static_names`, after provenance and producer-binding constraints have
been finalized, to every source module's code-generation pass. The return
value is the complete text of one C translation unit. For a
[folder module](folder-modules.md), `ast` is the same dense root list as for a
flat module, assembled from independently parsed files and checked once; the
checker may visit declarations in dependency stages, but it never rearranges
this list. The coder therefore still observes the logical source order that
defines interface members, module slots, module-variable initialization, and
emission; it has no source-unit node or contributor context. The driver
(`driver.compile`) runs the result through `pretty.reindent_c`, writes the
`.c` file next to the canonical flat source or folder main, and invokes the
system C compiler
([driver and toolchain](driver.md)). One consequence of the checker's
rewriting matters constantly here: every implicit coercion is already an
`Ast.ExpCast` node, every statically demanded extra result is an
`Ast.ExpExtra` node, and finite/open expression-list demand is recorded on
the enclosing sink. The coder therefore lowers an explicit checked result
plan instead of inventing conversions or arity rules of its own
([the type checker](checker.md)). This chapter covers the shape
of the output and the protocols it implements; value-level details are in
[values and the GC](values-and-gc.md), per-construct translations in
[code generator: constructs](codegen-constructs.md), and ABI-0.17 Array
representation and lowering in [Dense Arrays](dense-arrays.md).

One no-`main` CLI invocation may link several such translation units into a
single [multi-module provider](multi-module-libraries.md). The coder still runs
once per logical module; it never sees a provider AST or emits aggregate
metadata.

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

`coder.generate` assembles the unit from a fixed preamble template plus a
`code` list filled by kind-filtered passes over the top levels (imports,
variables and records first; functions second). Each whole-root-list allocation
and emission walk uses `ipairs`, preserving relative dense
main/contributor order within those categories; maps whose order has no
semantic effect may still use `pairs`. The pieces appear in this order:

1. **Preamble includes**: `<stdlib.h>`, `<string.h>`, `<math.h>`, then
   Lua's **internal** headers (`lobject.h`, `ltable.h`, `lvm.h`, `lgc.h`,
   `lstring.h`, `lfunc.h`, `ldo.h`, `ltm.h`, plus `luaconf.h` and
   `lauxlib.h`) and `titan.h` from `titan-runtime/`. The internal headers
   are the point: generated code manipulates `TValue`s, tables and the
   Lua stack directly instead of going through the Lua C API — which is
   what makes Titan fast and ties each compiler release to one Lua
   version (currently 5.5.0).
2. **Foreign `#include`s** (`$FOREIGNIMPORTS`): one per `foreign import`
   — quoted includes for absolute paths and local relative headers, angle
   includes for compiler-provided and system headers ([FFI
   internals](ffi-internals.md)) — followed by an `#ifdef __clang__` block
   silencing two warnings.
3. **Cross-module declarations** (`$INCLUDES`, filled by
   `init_data_from_other_modules`): `extern` or `static`-function-pointer
   declarations for every imported function actually called. (A record's
   type identity is its metatable, cached per-Lua-state in a `_mod` user
   value rather than a C static, so an external record needs no
   per-translation-unit tag declaration — see the wiring section below.)
4. **Forward signatures** (`$SIGS`): the native-convention prototype of
   every function in this module, plus
   `extern Udata *<dep>_init(lua_State *L);` per static import.
5. **Record support**: per record (from `coderecorddec`), the
   `__index_<rec>`/`__newindex_<rec>` metamethods serving field access
   from Lua ([Lua interop internals](lua-interop-internals.md)). A
   record's type identity is its metatable (cached per-Lua-state in a
   `_mod` user value), so there is no per-record C tag static to declare
   up front.
6. **Function bodies**: for each function, method and static, the
   native-convention body followed by its Lua entry wrapper (local
   functions get no wrapper).
7. **Module-global metamethods**: if the module exports anything, one
   `__index`/`__newindex` pair serving all members — variables, functions
   and public record namespaces — through the metatable installed on the module
   `Udata`.
8. **`<prefix>_abi`**, **`<prefix>_types`**, **`<prefix>_init`**, **`luaopen_<prefix>`**: the
   module-protocol functions, described below. One final DSO may contain this
   complete set for several translation units; every set remains independent.

### Mixed-source `#line` attribution

One folder-module C file contains functions and statements originating in
several Titan files. `emitline(node)` therefore retains its existing per-node
design: it C-quotes `node.loc.filename` and emits `#line` at safe physical-line
sites such as function entries, statements, calls, `raise`, and related throw
paths. Code generation does not install one directive for the whole
translation unit or stamp expression fragments that may be embedded mid-line.
The directive naturally changes filenames as root nodes and nested bodies from
different contributors are emitted, so compiler diagnostics, DWARF, and
libbacktrace frames identify the actual source file and line.

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

lua_Integer counter_inc_titan(lua_State *L, Udata *_mod, CClosure *_fn, lua_Integer _param_n);

lua_Integer counter_inc_titan(lua_State *L, Udata *_mod, CClosure *_fn, lua_Integer _param_n) {
    {
        return (_param_n+ ivalue(&_mod->uv[1].uv));
    }
}

static int counter_inc_titanentry_lua(lua_State *L) {
    ...    /* argument count adjustment, error handler, checkandget arguments */
    lua_Integer res = counter_inc_titan(L, _mod, _fn, _param_1);
    setivalue(s2v(_firstret), res);
    ...
}

static int __index(lua_State *L) { ... }    /* module metatable: member read  */
static int __newindex(lua_State *L) { ... } /* module metatable: member write */
int counter_abi(lua_State* L) { ... }       /* returns TITAN_VER */
int counter_types(lua_State* L) { ... }     /* serialized interface, below  */

static int _initialized = 0; /* tags and external functions are set up */
Udata *counter_init(lua_State *L) { ... }

int luaopen_counter(lua_State *L) {
    titan_invalidate_backtrace_state(L);
    Udata *mod = counter_init(L);
    setuvalue(L, s2v(L->top.p), mod);   /* require returns the module Udata */
    L->top.p++;
    return 1;
}
```

Symbol names come from `mangle_qn` (`coder.lua`), which replaces `.` and
`-` with `_`: module `foo.bar` yields `foo_bar_init`, `foo_bar_abi`,
`foo_bar_types` and
`luaopen_foo_bar`; a function `f` in it becomes `foo_bar_f_titan` /
`foo_bar_f_titanentry_lua`; methods and record functions use
`<mangled-fqtn>_<name>_titanmethod` / `_titanentry_luamethod` and
`_titanstatic` / `_titanentry_luastatic`.

`coder.external_symbols` inventories the non-file-local subset of these names
plus each module protocol. Library-mode orchestration compares that exact set
before code generation, including collisions that cross a flattened
module/member boundary; it does not wait for the linker to diagnose duplicate
definitions.

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
RETTYPE f(lua_State *L, Udata *_mod, CClosure *_fn, [Udata *self,]
          <ctype(param_1)>, ..., <ctype(param_n)>,
          [TitanVargX *_varargs, int _start,]
          <ctype(ret_2)> *_outparam_2, ..., <ctype(ret_m)> *_outparam_m,
          [TitanVargY *_flexout, int _flexwant]);
```

`RETTYPE` is `ctype(rettypes[1])` — the unboxed C type of the first
return value (`lua_Integer`, `TString*`, `Table*`, `TValue`, `Udata*`,
…; full map in [values and the GC](values-and-gc.md)); a function
returning only `nil` returns `int` and ends with `return 0;`; a flex-only
function returns C `void` and writes its caller-owned descriptor. The input
vararg pair, when present, precedes fixed result out-pointers. The flexible
output pair, when present, comes last. `_mod` is
the callee's **own** module `Udata`; a cross-module caller passes it from
one of its user values. `_fn` is the **callee's own closure** — the
`CClosure` of the function value being invoked, whose `upvalue[3..]` hold
its captured variables; it is what a closure body reads its captures
through (see [closures and captured variables](#closures-and-captured-variables)).
It comes **immediately after `_mod` and before the method `self`**, and
*every* Titan function takes it even when the body never reads it: the
fast value-call path dispatches purely on the function-type tag, so all
native entries of a given `Type.Function` must share one ABI. Its value
at a call site depends on the path:

* **`NULL`** on a static direct call (`codecall`) — a top-level
  function/method/static reached by name has no closure to pass;
* **the callee value itself** (`_vc_callee`) on the fast value-call path
  (`codevaluecall`);
* **`clCvalue(s2v(func))`** in the Lua entry wrapper, which then derives
  `_mod = uvalue(&_fn->upvalue[0])` (the module value stored in the
  closure's upvalue 0 is now a `Udata`, read with `uvalue`, not
  `clCvalue`).

`TitanVargX` and `TitanVargY` stand for the element-specific descriptor
types (`TitanVargInteger`, `TitanVargString`, and so on); input and output
tails use the same descriptor family even when their element types differ.

The `Udata *self` slot exists only for methods (`Type.Method`) and is
named `__self__` in the generated body — `self` is a record, and a record
is a `Udata`. Return values 2..m are written through out-pointers
following the declared parameters. Real signatures from a generated
module:

```c
TString*    packtest_Point_getname_titanmethod(lua_State *L, Udata *_mod, CClosure *_fn, Udata* __self__);
lua_Integer packtest_two_titan(lua_State *L, Udata *_mod, CClosure *_fn, TString* *_outparam_2);
void        strings_titan(lua_State *L, Udata *_mod, CClosure *_fn,
                          TitanVargString *_flexout, int _flexwant);
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
  entry wrapper plays the caller's role for Lua callers. A flexible result
  descriptor likewise points at caller-owned typed storage. For an open
  GC-bearing run the caller reserves a parallel traced stack range, publishes
  returned elements there before a later allocation, and clears that live
  range after the consuming sink has copied or stored it; the descriptor and
  raw C array are not themselves GC roots.

### Named direct calls and lexical evaluation order

The checker has already normalized an eligible named call to a dense
formal-order `ArgsFunc` or `ArgsMethod`, but leaves `_named_arg_order` with the
formal indexes of explicit expressions in lexical order. `codecall` sends that
pair through `named_ordered_call_args`: it generates and immediately
materializes each explicit expression in lexical order, then materializes the
synthetic nil omissions, and finally emits the unchanged positional native
argument list. For a method, the receiver is materialized once before this
sequence. Immediate materialization both freezes effects before formal
reordering and gives GC-bearing values their ordinary caller-owned stack
anchors.

Positional direct calls follow the same checked adjustment plan. Every
explicit argument is evaluated once in lexical order; surplus expressions are
evaluated only for effect, while only the fixed prefix and any accepted input
tail reach the native call. On the result side `codecall` allocates fixed
holders required by the declared ABI, publishes only the consumer-visible
projection, and, for a flexible producer, allocates a typed caller-owned buffer
sized to the finite demand or to the bounded open budget.

Direct foreign calls use the parallel branch in `codeforeigncall`. Each named
expression is converted and assigned to a target-typed C temporary in lexical
order; the call prints those temporaries in formal order. Mutable GC-bearing
out-parameter anchors are still refreshed after the C call. Neither branch
emits a runtime name table, and a named call never reaches `codevaluecall`.
See [named-argument internals](named-arguments.md).

### Calling function values (`codevaluecall`)

Calling a first-class function value is the one Titan-to-Titan call form
that may deliberately fall back to Lua's ordinary call machinery. The
callee expression has static type `Type.Function`, but its runtime value
is a boxed `TValue`: it may be a Titan `CClosure`, a Lua closure, a Lua C
function, or an object with a `__call` metamethod. `codevaluecall`
therefore emits two branches.

The **fast path** is taken only when the boxed value is a Titan
`CClosure` whose runtime function-type tag is the exact tag for the
callee expression's static type:

```c
if (ttisCclosure(&fn) && clCvalue(&fn)->nupvalues >= 3
    && ttislightuserdata(&clCvalue(&fn)->upvalue[1])
    && pvalue(&clCvalue(&fn)->upvalue[1]) == <function-type tag>) {
    ...
}
```

Those tags are the `static const void *` identities allocated by
`function_type_tag`, keyed by `types.tostring(ftype)` and
publish-or-recovered through the Lua registry so source-linked and
`.so`-loaded modules agree on the pointer for the same canonical type.
Matching the tag is stricter than ordinary compatibility: a Titan
`(value) -> integer` viewed as `(integer) -> integer` through a gradual
`value` round trip is callable, but its tag does not match the call
site's exact type and it cannot use this branch.

Once the fast predicate holds, the call is again an unboxed native call:
`_vc_callee = clCvalue(&fn)`, `_vc_mod =
uvalue(&_vc_callee->upvalue[0])`, and the native entry pointer in
`upvalue[2]` is cast to the exact `function_sig` typedef and called with
`L`, `_vc_mod`, `_vc_callee`, the already-evaluated native arguments and
the usual out-parameters. Passing `_vc_callee` as `_fn` is what lets
anonymous closures and bound-method trampolines read their captured
upvalues while still using the same fast branch as top-level function
values.

The **generic path** is used for everything else: non-exact Titan
function values, Lua closures, Lua C functions, and `__call` objects.
It pushes the boxed callee followed by the already-evaluated arguments
onto the Lua stack with `setslot`. Ordinary finite calls use
`luaD_callnoyield(L, restorestack(L, _vc_func), nresults)`. A generic producer
that is statically open at the call site uses `LUA_MULTRET`, measures the raw
result count, nil-fills any missing fixed prefix, converts the tail into the
same typed descriptor used by the exact path, and caps the retained run at
`TITAN_VARARG_MAX` (or copies only an inherited finite remainder). An open sink
over a fixed-only static callable remains an ordinary finite call.

Lua 5.5 encodes a finite VM result request in `CallInfo` with a maximum of
250. The checker rejects generic function-value sites whose finite visible
request exceeds that count. This is independent of Titan's 200-element
descriptor cap; direct native calls and statically open generic producers do
not use the finite VM field.

Every statically open generic producer uses `LUA_MULTRET`, including when an
enclosing flexible native entry has a finite `_flexwant`. The returned values
remain rooted on the Lua stack while the generic branch measures the raw count,
nil-pads a missing fixed prefix, converts the retained tail, and applies the
enclosing finite/open Titan budget. It then resets `L->top.p` to discard the
call frame and result slots. This is also where non-callable values fail
cleanly at runtime.
The parameter and result checks still use the Titan function type at the
call site; if the callee is a Titan function with a different compatible
type, its Lua entry wrapper performs the callee-side coercions before
entering the native body. That wrapper itself received an open Lua request, so
it owns and enforces its 200-value open-tail bound before any enclosing finite
Titan copy budget can discard surplus results.

Because the generic branch can grow and relocate the Lua stack,
`codevaluecall` marks the enclosing function as `uses_base_off`, saves
the callee stack slot as an offset with `savestack`, and recomputes
`_base = restorestack(L, _base_off)` after both branches. GC-able
arguments were already anchored when evaluated, and GC-able fixed results are
stored into reserved caller slots immediately after the branch joins. An open
GC-bearing run is copied into its reserved traced range before the sink can
allocate.

### The Lua entry wrapper

For every exported function, method and static, `genluaentry` emits a
companion `static int <name>_lua(lua_State *L)` with the standard
`lua_CFunction` signature. It pads missing fixed arguments with nil on the Lua
stack, ignores surplus arguments for a fixed-parameter function, and converts
surplus arguments into a typed input descriptor for a variadic one. It
installs the runtime's `errorhandler` as `L->errfunc` for the duration of the call,
recovers the called closure as `_fn = clCvalue(s2v(func))` and `_mod =
uvalue(&_fn->upvalue[0])` from it (the module value is a `Udata`; so a
closure entered from Lua still reaches its own captures), checks and
converts each argument with
`checkandget`, reserves stack space for the requested return values, calls the
native function (passing `_fn` so a closure body can read its captures), and
writes the results back with `setboxed` (which leaves records as userdata and
maps an internal Array backing to its canonical proxy). For a flexible result
shape it reads Lua's requested
result count with `get_nresults`, derives the tail budget after the fixed
prefix, passes a typed `_flexout` descriptor plus `_flexwant`, and returns the
fixed count plus the number the native body actually produced.
The full anatomy — per-type boundary checks, error-slot juggling, exact
error messages, safety argument — is in
[Lua interop internals](lua-interop-internals.md).

## Closures and captured variables

An anonymous function ([closures](../language/closures.md)) is a function
value just like a top-level reference — a `CClosure` whose `f` is a Lua
entry wrapper, with `upvalue[0]=_mod`, `upvalue[1]=`function-type tag,
`upvalue[2]=`native entry pointer. A closure adds **one upvalue per
captured variable**, giving the layout

```
upvalue[0]     = _mod                  (the module Udata, captured lexically)
upvalue[1]     = function-type tag     (light userdata)
upvalue[2]     = native entry ptr      (light userdata)
upvalue[3 + i] = captured variable i   (a box, or a copied value)
```

so the constant `3` separates the closure header from the captures, and a
closure body reaches capture *i* as `_fn->upvalue[3 + i]`. The `_fn`
parameter (above) is exactly what makes this work: a top-level call passes
`NULL`, but a closure is always entered with `_fn` pointing at itself.

### The captured-variable box

A variable that is both **captured and assigned** (mutated by an inner
function) cannot be a plain C local — the inner closure must share one
mutable cell with the declarer and any sibling closures. The
representation is a **box**: a `CClosure` with exactly **one** upvalue,
used purely as a heap cell. The boxed value lives in `box->upvalue[0]`;
the box's `f` is a per-module trap stub (`titan_box_trap`) that
`luaL_error`s if the box is ever mistakenly called, since a box is never a
real callable and never flows into Lua. A box is chosen over a literal
`UpVal` (which crashes under the generational GC — Lua assumes every
`UpVal` is born open) or a one-uservalue `Udata` (8 bytes larger, with an
unused metatable slot): the `CClosure` cell is the smallest GC-safe option
that survives every collector mode.

Crucially the box uses the **same forward `luaC_barrier`** the coder
already emits for every closure-upvalue store, for *both* installing the
box into the enclosing closure *and* mutating the boxed value — one
uniform barrier rule. The mutation barrier is load-bearing: under the
generational collector, omitting it is a near-deterministic use-after-free
(blacken box → store fresh white value → sweep frees it). A box is
allocated and **immediately anchored** in a dedicated stack slot before
its initializer is stored into it, so there is never an unanchored-box
window. A variable that is captured-but-immutable, or mutated-but-not-
captured, keeps its ordinary representation; only the conjunction is boxed.

### Capture lists, lambda hoisting, transitive capture

The checker computes, for each `ExpFunction`, the ordered de-duplicated
list of enclosing-function declarations it captures (see
[the type checker](checker.md#closures-capture-analysis-and-lambda-inference)); the coder
turns that list into the `upvalue[3 + i]` slots in agreed order. At the
use site the closure is built by pushing the three header upvalues then,
in capture-list order, each capture — the box `CClosure*` for a boxed
capture, or the copied value for a by-value capture — and calling
`lua_pushcclosure` (preceded by a `lua_checkstack(L, 3 + ncaptured)`,
since the capture pushes are raw transient stack pushes, not
slot-reserved). `lua_pushcclosure` moves the pushed upvalues into the new
white closure, so no barrier is needed at construction.

Each lambda's native and Lua entries are **hoisted to file scope** and
emitted alongside the top-level functions, named `<modprefix>lambda_<N>`.
Because a lambda nested inside another lambda is discovered only while the
outer one's body is generated, the emission loop drains the lambda list
with an index-based `while` that re-reads its length each iteration rather
than iterating a snapshot.

**Transitive capture** (a deep lambda using a variable from a function it
is not directly inside) falls out of the per-frame capture lists: the
variable appears in the capture list of *every* intervening lambda, so
each level reads it from its own `_fn` and pushes it into the next
level's closure. A boxed transitive capture copies the one box pointer all
the way down — every level shares the cell; a by-value transitive capture
copies the immutable value down.

### Bound-method trampolines

A bound method reference `obj:m` is a one-capture closure whose captured
"variable" is the receiver `self`, with a pair of **trampolines** that
delegate to the method's real entries. Both are emitted by the method's
**defining module for every method**. Public methods use exported/recoverable
symbols mirroring the method's own entries plus a `function_type_tag` for the
self-removed type, so a bind site in another module — which may have only the
`.so` — can point at them. Local methods keep those trampoline symbols
file-local and are not serialized into `.so` interfaces. The **native
trampoline** matches the
self-removed function type's ABI, extracts `self` from its closure's
`upvalue[3]`, and tail-calls the method's native entry with that `self`;
the trailing flexible-output descriptor and budget, when present, pass through
unchanged. The **Lua trampoline** inserts `self` as the first stack argument and
delegates to the method's existing Lua entry, reusing its boundary checks.
At the bind site `obj` is evaluated once into an anchored temp, then the
closure is built exactly like a one-capture lambda (`_mod`, the
self-removed tag, the native trampoline pointer, and `self`). The result
is an ordinary `Type.Function` value with no special downstream handling.

### The `.so` ABI bump

Adding `_fn` to `function_sig` changes **every** native-entry signature,
including the cross-`.so` value fast path and the cross-module externs.
Old (`TITAN_VER` 0.5) and new compiled `.so`s are therefore
**ABI-incompatible** — mixing them is undefined behavior — so this work
bumps `TITAN_VER` from **0.5 to 0.6** (`titan-runtime/titan.h`), which
also changes the compiled-module search-path suffix. All dependency `.so`s
must be recompiled against 0.6.

A later change bumped `TITAN_VER` again, **0.6 to 0.7**: record instances
and module state (`_mod`) collapsed from a `CClosure`+`Udata` pair to a
single `Udata`, so `_mod` and every record-typed parameter/return/`self`
changed C type (`CClosure*`→`Udata*`) and `<mangled>_init` now returns
`Udata*` — all cross-`.so` ABI points. 0.6 and 0.7 `.so`s are likewise
ABI-incompatible and live under different `TITAN_PATH` directories.

A further change bumped `TITAN_VER`, **0.7 to 0.8**: a record's type
identity moved from a `void*` tag word in the udata's raw payload to the
udata's **metatable pointer**, so record instances now carry no raw
payload (`luaS_newudata(L, 0, N)`) and a cross-module type check compares
`uvalue(v)->metatable` rather than reading `getudatamem`. A 0.7 checker
reading a 0.8 record's `getudatamem` would read out of bounds, so 0.7 and
0.8 `.so`s are ABI-incompatible and live under different `TITAN_PATH`
directories.

The 0.10 to 0.11 bump covers module-local
records and record members: `<mangled>_types` omits local records and local
fields/methods/record functions from the serialized public interface, while retaining
the full record field-slot count so an imported `.so` still reads public fields
from their original `Udata` user-value slots. A 0.10 checker would not know how
to interpret that layout metadata. The 0.11 to 0.12 bump added the separately
serialized `Type.Module.type_members` map for public type aliases; a 0.11
checker cannot rehydrate that interface shape. ABI **0.13** introduced the
named-argument metadata.
The 0.12 to 0.13 bump adds declaration `paramnames` to the serialized
`Type.ModuleMember`, `Type.Method`, and `Type.StaticMethod` constructor shapes
for named calls. Native entry signatures are unchanged, but a 0.12 checker
cannot evaluate the new interface descriptors safely.

Flexible result types add `flexrettype` to callable interface descriptors and
the trailing native `_flexout`/`_flexwant` pair shown above. That ABI and
serialization-shape change shipped as 0.14 rather than making 0.13 accept both
layouts. ABI **0.15** made `titan.uv` order exported module
members by semantic contributor, so marker constants and installed paths move
together rather than letting 0.14 importers reconstruct the changed slots. The
later checker staging, relocation of private uv records, and move of the
private `FS` constants instance alter private slot/initialization order but add
no serialized descriptor field, native parameter, or importer-visible slot
change: the exact `titan_uv_types` interface remained unchanged.

ABI **0.16** kept per-module descriptor and native-call shapes but changed the
generated/imported physical-provider contract from an exact logical DSO to a
compiler-selected prefix container. A 0.15 runtime cannot discover the
combined standard `titan.so`.

The current ABI is **0.17**. `Type.Array` keeps `Table *` in exact native
signatures and `Table **` in variadic/flexible descriptors, but the Table is
now private backing storage and every Lua-visible Array is a canonical proxy
Udata. Generated modules also reserve a per-state Array-metatable cache and
use explicit internal-versus-boxed conversions. A 0.16 module would
misinterpret Array values even when a serialized interface happens not to
mention one, so the semantic/runtime boundary requires a full rebuild. See
[Dense Arrays](dense-arrays.md#abi-017-boundary).

## The module protocol

All semantic module state lives in the Lua registry or GC-traced Lua objects,
never in shared C globals. In particular, per-Lua-state module state lives in
one `Udata` (`_mod`) created by `_init`: the module table's slot is gone
entirely, and member slots are 0-based with no reserved user value. The user values hold module
variables, imported modules' `Udata`s, exported-function canonical
closures, the unconditional Array-metatable cache, cached record metatables,
and per-record static-namespace tables
(allocation order below). Every generated function receives this `Udata` as its
`_mod` parameter; the Lua wrappers recover it from their closure's
upvalue 0. Around `_mod`, each module exports three protocol symbols:

### `<prefix>_init` — idempotent at two levels

```c
static int _initialized = 0; /* external functions are stitched up */
Udata *counter_init(lua_State *L) {
    lua_checkstack(L, 10);
    lua_getfield(L, LUA_REGISTRYINDEX, "Titan module counter");
    if(lua_isnil(L, -1)) {
        _initialized = 1;
        /* create and register _mod (luaS_newudata(L, 0, NUPVALS));
           $LOADMODULES1 (dlopen dynamic deps), $INITMODULES (dep inits),
           $LOADGLOBALS (symbols published by transitive RTLD_GLOBAL deps),
           $INITRECORDS (record metatables), $INITVARS (variable
           initializers); install functions and public record namespaces into
           their uv slots; $CREATEMETA (member metatable on the udata) */
        return _mod;
    } else {
        Udata *_mod = uvalue(s2v(L->top.p - 1));
        lua_pop(L, 1);
        if(!_initialized) {
            _initialized = 1;
            $LOADMODULES2  /* re-stitch directly imported function pointers */
            $LOADGLOBALS   /* re-stitch transitive global symbols */
        }
        return _mod;
    }
}
```

Idempotency works at two independent levels:

* **Per Lua state**: the module `Udata` is registered in the Lua registry
  under `"Titan module <modname>"`; a second `require`, or a dependent
  module calling `_init` again, finds it and returns it untouched. A
  second Lua *state* in the same process misses the registry and gets a
  fresh `Udata` and metatables — there is no semantic per-state C global, so
  one compiled module serves many states.
* **Per translation unit**: the C `static int _initialized` guards only
  nonsemantic native wiring and caches — here, the dlsym'd function pointers.
  Several translation units may share a physical provider, but each retains
  this separate flag and module protocol. The standard library installs a
  paired `titan.so`/`titan.a` provider; dynamic Titan imports and Lua requires
  share the DSO form, while static selection uses the archive. Record type
  identity is the metatable, a
  per-Lua-state object cached in a `_mod` user value rather than a C static, so
  this branch no longer re-fetches any tag cache.

*Detail:* the re-initialization branch substitutes `$LOADMODULES2` only
when the dynamic-load list has more than one entry (`#loadmods > 1` in
`coder.generate`); with exactly one entry it is left empty. Entries come
in two kinds — one `loadlib` handle line per dynamic dep, then one
`loadsym` stitch line per imported function, always after its handle —
so a single entry is necessarily a bare handle with no function pointers
to re-stitch, and skipping it just avoids declaring an unused handle.
(The converse is not exact: two dynamic deps with no functions called
would still re-emit their handles.) `$LOADGLOBALS` is independent of that
optimization because its symbols are not associated with a direct import
handle.

### Lua entries, `<prefix>_abi`, and `<prefix>_types`

`luaopen_<mangled-modname>` is what `require` finds. Standard-library short
imports are desugared before module resolution, so Titan `import "os"` compiles
as an import of `titan.os`; its ordinary qualified module name naturally emits
`luaopen_titan_os`, the same entry used by Lua `require "titan.os"`, without
defining `luaopen_os` or replacing Lua's own `os` library. The Lua entry calls
`_init` and pushes
the module `Udata` itself — so **`require` returns a userdata**, not a table,
with **no separate module table at all**. Its members —
exported functions, exported variables, and one static-namespace table
per record (carrying its public record functions) — are all served by a metatable on the
`Udata` ([Lua interop internals](lua-interop-internals.md)).
`<prefix>_abi` is a tiny marker function that returns the current
`TITAN_VER`; both the compile-time DSO loader and generated dynamic imports
check it before trusting any other callable symbol. Static providers embed
the same ABI and serialized interface in each logical object, and archive
validation compares those bytes with the callable protocol before
publication. `<prefix>_types` is the separate-compilation interface:

```c
int counter_abi(lua_State* L) {
    lua_pushliteral(L, TITAN_VER);
    return 1;
}

int counter_types(lua_State* L) {
    lua_pushliteral(L, "Module('counter',{ModuleVariable('counter', 'x', Integer()),...},{['Count'] = Integer()})");
    return 1;
}
```

The literal is `types.serialize(ast._type)`: a Lua *expression* that
rebuilds the module's type when evaluated with `types.lua`'s constructors
as its environment. A `Type.Module` serializes runtime `members` and public
alias `type_members` separately; aliases therefore create no module slot or
Lua-visible member. Keyed alias, record-method, and record-static maps are
serialized in locale-independent numeric-byte name order so equivalent
interfaces have reproducible text; ordered module members and record fields
retain their established source/slot order. Callable declaration descriptors also serialize formal
`paramnames`, while structural `Type.Function` values do not. Callable shapes
also carry their optional `flexrettype`; accepting that new constructor shape
from compiled interfaces is gated on the coordinated ABI transition described
above. It returns that
serialized interface as its sole result;
there is no dependency-origin metadata in the module protocol.
`Type.Module.file` is likewise omitted. It defaults to the exact logical path
when the expression is evaluated; only a successful DSO claim overwrites it
with the selected relative shared-provider path. Static archive paths never
enter the serialized type or this transient field.

When the driver's loader finds a compiled provider for an import, it recovers
the requested ABI/types from either the DSO's callable pair or the selected
archive object's canonical metadata section, rejects partial or invalid
claims, and evaluates the serialized expression to recover the interface —
letting the checker type the importing module against a dependency whose
source is gone. Libuv does not add another result or a special binary
classification. Dependencies selected from a DSO use dynamic handle-scoped
wiring; dependencies selected from source or a static provider use direct
native wiring. Explicit command-line roots are the source-first exception.
The tests' in-memory `tableloader` exercises the same serialization
round-trip. See [driver and toolchain](driver.md) and [Static compiled
modules](static-compiled-modules.md).

Folder and provider representation change none of this logical protocol. Mangled symbols,
nominal names, registry keys, `luaopen_*`, and the serialized module identity
remain derived solely from logical `modname`; there is no contributor ABI.
The repository's historical 0.15 transition is a compatibility boundary for the
intentional `titan.uv` public-member reorder caused by semantic ownership.
Moving local record declarations and the private `FS` constants instance among
contributors after that boundary changes private initialization layout but
does not alter the serialized interface. ABI 0.16 changes how the physical
provider is found and recorded transiently; ABI 0.17 then changes Array
representation and adds the module-local metatable cache without changing the
serialized `Type.Array` constructor.

## Static vs dynamic dependency wiring

`coder.generate` decides per import, by `static_deps[modname]`
(`import_module` and `init_data_from_other_modules`).

**Direct/static** (the dependency's source object is compiled in, or its
logical module is physically carried by a selected static provider): plain
`extern` declarations and direct calls — each cross-module function used gets
an `extern` prototype in `$INCLUDES`, and the dependency's initializer is
declared and called directly:

```c
extern Udata *dep_init(lua_State *L);
/* in _init: */ { Udata *_m = dep_init(L); setuvalue(L, &_mod->uv[1].uv, _m); }
```

**Ordinary dynamic** (shared-provider dependency): each imported function is
declared in `$INCLUDES` as a `static` function *pointer*; the generated
`_init` dlopens the exact selected DSO and stitches the pointers by symbol
name with the runtime's lazy/global `loadlib` and handle-scoped `loadsym`
(`titan-runtime/titan.c`: Titan-path search, registry-cached handles, Lua
error on failure):

```c
static Udata* (*dep_mk_titan)(lua_State *L, Udata *_mod, CClosure *_fn, lua_Integer);
/* in _init ($LOADMODULES1), at first init in the process: */
void *dep_handle = loadlib(L, "selected/provider.so");
dep_mk_titan = titan_cast_func(Udata* (*)(lua_State *L, Udata *_mod, CClosure *_fn, lua_Integer),
                               loadsym(L, dep_handle, "dep_mk_titan"));
```

A direct-libuv DSO follows this exact regime. Its explicit `import "uv"` is
ordinary generated import wiring inside that DSO: lazy mapping leaves normal
`uv_*` function calls unresolved long enough for the DSO's initializer to load
the combined `titan.so` globally before those calls bind. `RTLD_NOW` would reject the DSO
before its initializer ran, while a provider loaded `RTLD_LOCAL` later would
not satisfy those bindings. The coder emits no provider marker or alternate
loader call. Eager libuv relocations and constructors cannot rely on this
initializer ordering. Compiler interface inspection is a separate
`RTLD_LAZY | RTLD_LOCAL` operation.

The dep's `_init` is fetched and called the same way inside
`$INITMODULES`. In both regimes the *call sites are identical* C calls —
only the storage class of the callee name differs — and the caller passes
the callee's module `Udata` read from its own user value and `NULL` for
the direct-call `_fn`: `dep_mk_titan(L, uvalue(&_mod->uv[1].uv), NULL, 7)`.
Imported record metatables are not wired through symbols at all: they are
recovered through the Lua registry at init time under
`"Titan record <fqtn> metatable"`. The metatable pointer itself is the record's
type identity; see [Lua interop internals](lua-interop-internals.md).

A third, **global/dynamic**, path handles a nominal record owner re-exported
through another compiled interface when that producer selected the owner
dynamically. If C imports only re-exporter B but calls a method owned by A,
B's initializer has already loaded A with `RTLD_GLOBAL`. C therefore does not
`loadlib` A: after `$INITMODULES` initializes B, `$LOADGLOBALS` resolves A's
native method entry (and any bound-method Lua trampoline) with
`loadglobalsym`/`dlsym(RTLD_DEFAULT, ...)`. The corresponding module userdata
and record metatable are then recovered from the Lua registry. Resolver
finalization rejects an independently selected A that could violate this
producer-chosen native identity. See
[Type aliases](type-aliases.md).

## User-value allocation

`allocate_upvalues` assigns `_mod` user-value slots before any code is
generated. `nextupvalue` hands out slots 0-based with no reserved slot
(the now-removed module table no longer takes slot 0), so `NUPVALS`
equals the number of slots. First come **exported (non-`local`) module
variables, in declaration order** (slots 0..n-1), followed by a canonical
closure slot for every exported ordinary function, also in declaration order.
Those are the two importer-visible groups. The unconditional per-module Array
metatable cache is the first private slot, followed by local module variables
and imports. A final AST-order allocation pass assigns slots to referenced
local ordinary-function closures, every record-function closure, and every
record's static-namespace table. Record metatables (`type2metatable`), owned-C
metatables, and the transitive module `Udata` caches needed by cross-module
method calls (`ctx.modules`) are then allocated on first use during codegen and
filled in by `init_data_from_other_modules` or the module initializer. Thus all
private groups, beginning with the Array cache, come *after* the
importer-visible variable and exported-function slots, so moving or adding
them does not perturb the importer slot math.

Exported variables come first because their slot numbers are part of the
module's ABI: an importing module never sees this module's AST — in
`import_module` it recomputes the variables' slot indices on its own, by
numbering the `Type.ModuleVariable` members of the *serialized interface*
1..n in order. Cross-module variable access then compiles to a direct
slot read, `uvalue(&_mod->uv[MOD].uv)->uv[VAR].uv`, with no name lookup;
if local variables or imports could claim earlier slots, the importer's
numbering would diverge from reality. (The module metatable's name→slot
member map, serving the same variables to Lua, bakes in the same
indices.) A record's type identity is its per-Lua-state metatable pointer, so
record metatables must live in module user values and are recovered through the
Lua registry for imported records. Function-type tags use a separate
registry-published C-static mechanism.

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
