# Error handling implementation

This chapter covers two related pieces of the implementation:

* unified Titan/Lua tracebacks, captured on the error path; and
* the `raise` / `catch` / `finally` language feature.

The surface language is documented in
[the language reference](../language/error-handling.md). This chapter is
for contributors changing `titan-compiler/coder.lua`,
`titan-runtime/titan.c`, or the parser/checker rules.

## Runtime trace model

Every Lua-callable Titan entry wrapper installs `errorhandler` as
`L->errfunc` for the duration of the call. When Lua raises an error,
`luaG_errormsg` invokes that handler before the longjmp reaches either a
Lua `pcall` or Titan's inline catch/finally boundary.

The handler stores the rendered traceback in
`registry[TITAN_BACKTRACE_KEY]`. The error value itself is not wrapped:
Lua `pcall`, Titan's catch-local `error`, and any re-raise see the exact
Lua value that was raised.

### Trace pinning

The registry also contains `TITAN_TRACE_PINNED`, a boolean pin flag. The
handler's rule is:

* if the pin is set, clear the pin and keep the existing traceback;
* otherwise, regenerate the traceback from the current stack.

This prevents stale-trace reuse while still supporting bare re-raise.
When a Titan catch re-raises the original error, codegen first writes the
saved catch-local `traceback` back to `TITAN_BACKTRACE_KEY`, sets the pin,
pushes the saved `error`, and calls `lua_error`. The handler sees the pin
and preserves the original deep trace. A fresh `raise <exp>` leaves the
pin clear, so the handler captures a new trace at the new raise site.

When a boundary catches an error for a Titan `catch`, it snapshots the
trace into a reserved stack slot and then clears both the trace slot and
the pin. A fully handled catch therefore leaves `titan.backtrace()` as
`nil`; the handled trace is available only through the catch-local
`traceback`.

### libbacktrace and frame merging

The trace is a single innermost-to-outer stack. It is built from two
sources:

* Lua `CallInfo` frames, read with `lua_getstack`/`lua_getinfo`, provide
  the Lua-level activations, including pure Lua functions and genuine Lua
  C functions such as `pcall`.
* libbacktrace provides native frames from compiled Titan code, including
  native-to-native calls that have no Lua `CallInfo` of their own.

Generated Lua entry wrappers contain `titanentry` in their C symbol name.
Those wrapper frames are sentinels, not user-visible frames. The native
side drains a run of Titan frames until the next entry-wrapper sentinel,
emitting only the native Titan function frames and using the sentinel to
align that native run with the corresponding Lua `CallInfo`.

The trace builder also identifies Titan entry-wrapper CallInfos by
symbolizing their `lua_CFunction` pointer and looking for the same
`titanentry` tag. Those CallInfos are hidden; genuine Lua C functions are
shown as `[C]`. This keeps `Lua -> Titan -> Lua -> Titan` chains
interleaved in call order instead of grouping all Lua frames separately
from all native frames.

### Source lines and display names

The code generator emits `#line` directives at function entries and at
call/raise sites whose native frames should point back to Titan source.
The source file does not need to exist at run time: the filename and line
are carried in the object file's debug information.

libbacktrace reports C symbol names, which are mangled and cannot contain
Titan punctuation such as `.` or `:`. Each module `_init` contributes a
mapping from native C symbol name to display name in a shared registry
table under `TITAN_NAMES_KEY`. The runtime formats frames with those
display names:

* `<module>.<function>`
* `<module>.<record>:<method>`
* `<module>.<record>.<static>`
* `anonymous function at <file>.titan:<definition-line>`

`loadlib` invalidates the cached libbacktrace state after a successful
slow-path `dlopen`, because libbacktrace snapshots the process' loaded
objects when the state is created. A Titan module loaded by Lua's own
`require` also invalidates from its generated `luaopen_*`, since that
path bypasses Titan's `loadlib`.

Each generated module links its own copy of `titan.o`, so invalidation is
not just a C static reset. The runtime also bumps
`registry[TITAN_BT_GENERATION_KEY]`; every module's errorhandler compares
that shared generation with its local `titan_bt_generation_seen` before
reusing a cached libbacktrace state. Handles are cached and only closed at
Lua-state teardown, so unload staleness is not a mid-run concern.

## Frontend representation

`catch`, `finally`, and `raise` are reserved words.

The grammar has no `try` keyword. The `block` production parses a normal
statement block and then optionally absorbs a `catch` block and/or a
`finally` block. If neither trailer is present, the AST is the normal
`Ast.StatBlock`; otherwise the parser wraps it in:

```lua
Ast.StatTry(loc, block, catchblock_or_false, finallyblock_or_false)
```

`raise <exp>` and bare `raise` parse as:

```lua
Ast.StatRaise(loc, exp_or_false)
```

The catch/finally clause bodies are plain statement lists, not full
trailer-consuming blocks. That prevents an inner catch body from greedily
swallowing an outer `finally`.

## Checker rules

`StatTry` checks its body, catch, and finally in sibling scopes.
Catch-local bindings are synthesized only in the catch scope:

* `error: value`
* `traceback: string`

They are read-only snapshots. The checker marks them as implicit catch
locals and rejects assignment to either name.

Body locals are deliberately invisible in catch/finally, because a body
error may happen before a given local declaration has executed.

Bare `raise` is legal only while checking a catch block. The checker uses
a `catch_depth` counter for that rule and resets it across nested function
bodies, so a lambda written inside a catch does not inherit re-raise
permission.

`raise <exp>` checks the expression normally and coerces it to `value`.
`StatRaise` is an always-returning statement for the purpose of "function
must return" analysis.

`finally` blocks are not allowed to transfer control out explicitly:

* `return` while `in_finally > 0` is a compile-time error.
* `break` while `in_finally > 0` is a compile-time error unless the
  target loop was opened inside that finally. The checker tracks this
  with `finally_loop_floor`.
* `raise <exp>` is allowed in finally, because ordinary run-time errors
  can always occur during cleanup and must override pending control flow.

The always-returns rule for a try is:

```text
(finally exists and finally always-returns)
or
(body always-returns and (no catch or catch always-returns))
```

## Code generator overview

The code generator emits catch/finally as straight-line C inside the
native function. It does not allocate thunks or capture the body into a
closure.

A `StatTry` body always gets an inline protected boundary, including
finally-only blocks. A catch gets its own boundary only when a finally
follows it; that is the case where an error raised by the catch must still
run the finally. A finally installs no boundary of its own.

The inline boundary is based on Lua 5.5's `lua_longjmp` layout and
longjmp macro choices, vendored into `titan-runtime/titan_longjmp.h` and
included by `titan.h`. It mirrors the parts of `luaD_rawrunprotected` and
`luaD_pcall` that matter for generated code:

1. save `L->nCcalls`, `L->ci`, `L->allowhook`, and the old top offset;
2. link a stack-allocated `lua_longjmp` into `L->errorJmp`;
3. run the protected body under `TITAN_SETJMP`;
4. restore `L->errorJmp` and `L->nCcalls` on normal fallthrough;
5. on error, restore `ci`/`allowhook`, run `luaD_closeprotected`, move the
   error object to the saved top with `luaD_seterrorobj`, recompute `_base`
   from `_base_off`, snapshot the error and trace into reserved slots, clear
   the registry trace/pin, and restore `L->top.p` to the function's reserved
   stack area.

The saved error object, saved traceback, pending raise object, and
GC-typed saved return values live in reserved Lua stack slots below the
function's steady-state top. Stack slots are roots and need no write
barrier. Non-GC pending return values live in C temporaries.

### Pending actions for finally

A try with finally has a discriminator:

```text
PA_NONE
PA_RETURN
PA_BREAK
PA_RAISE
```

Body or catch fallthrough leaves `PA_NONE`. A `return` or `break` inside a
finally-protected body/catch does not use `longjmp`; it saves any return
values, records the pending action, restores any protected boundaries that
the generated `goto` is about to exit, and jumps to the finally label.

After the finally runs, an if-chain dispatches the pending action. This is
intentionally not a C `switch`, because the `PA_BREAK` arm must emit a
`goto` to the label after the target Titan loop, not a C `break` that a
`switch` could capture.

If the finally itself raises, the longjmp skips the dispatch and naturally
overrides the pending action.

Nested finally blocks chain inside-out. During a pending return/break, the
inner dispatch can copy saved return values into an outer finally frame or
route a break through the next enclosing finally before realizing the
final action.

### Boundary restoration on generated `goto`

The main footgun is a `goto` to a finally label that exits the C lexical
scope of one or more inline boundaries. If `L->errorJmp` still points at a
stack-allocated `lua_longjmp` object in a scope the goto has left, a later
raise from the finally would longjmp through a dangling pointer.

`coder.lua` tracks a protected-boundary stack. Each finally frame records
the stack depth at the point where it was opened. A return/break routed to
that finally emits restoration code for every boundary deeper than that
floor before the `goto`:

```c
L->errorJmp = _lj_N.previous;
L->nCcalls = _oldnC_N;
```

The restoration stops at the finally's floor so outer still-active
boundaries remain installed and can catch or cascade a raise from the
finally.

Loop breaks have a second restoration path. Loop frames remember the
entry `errorJmp`/`nCcalls` if the loop contains a try; a direct break that
crosses a try boundary restores that loop-entry state before jumping to
the loop's after-label.

### setjmp and `volatile`

C's `setjmp` rule makes the value of a non-`volatile` automatic variable
indeterminate after a longjmp if it was changed between `setjmp` and the
longjmp and is then read. Titan avoids the precise liveness problem with
a conservative rule: if a generated function contains any `StatTry`,
Titan local/parameter C autos are declared `volatile`, including GC
pointer values and boxed `TValue` values. Pointer-shaped declarations use
`T * volatile x` so the pointer variable, not the pointed-to Lua object,
is volatile.

The Lua stack slots still matter: they keep GC objects alive and provide
stable roots. Lua's GC is non-moving, so pointers to GC objects remain
valid across collections. Stack relocation only invalidates pointers to
Lua stack locations; code that may run after `lua_checkstack`,
`luaD_callnoyield`, or protected recovery must recompute stack addresses
from saved offsets such as `_base_off`.

The variadic descriptor structs follow the same rule. Their C-stack
records contain counts and pointers to GC objects or typed C arrays, not
pointers to Lua stack slots. The descriptor object being on the C stack is
therefore not itself a stack-relocation hazard.

## ABI and search path

The current compiled-module ABI is `0.10`. The error-handling control-flow
machinery did not by itself require an ABI bump, but this branch also
changed the `TitanVargX` structs from inline flexible-array backing
objects to descriptor structs with an `args` pointer. That layout change
is visible across `.so` boundaries even though the native parameter type
names stayed the same, so `0.9` and `0.10` modules must not be mixed.

The compiler and runtime therefore agree on:

* `TITAN_VER "0.10"`
* `TITAN_VER_SUFFIX "_0_10"`
* versioned binary path variable `TITAN_PATH_0_10`
* default binary path `.;/usr/local/lib/titan/0.10`

Every generated module also exports `<mangled>_abi`, a Lua C function
returning `TITAN_VER`. The compiler's `.so`-only rehydration path checks
that marker before trusting `<mangled>_types`, and generated dynamic
imports call `titan_check_abi` after `loadlib` and before `dlsym`ing
native entries. Missing marker means "old module" and is rejected; this
protects the unversioned `.` component of the default path from silently
loading stale ABI-0.9 build artifacts.

`spec/abi_spec.lua` pins the compiler/runtime agreement and rejection of
markerless legacy `.so` files.

## Tests to keep close

The highest-value regression tests are:

* `spec/coder/backtrace_spec.lua` — unified trace order, source-line
  attribution, standalone top-level error handler.
* `spec/coder/so_trace_names_spec.lua` — dlopened module trace-name
  registration and libbacktrace state invalidation.
* `spec/checker/error_handling_spec.lua` — catch/finally scopes, bare
  raise legality, finally transfer bans, always-returns.
* `spec/coder/error_handling_spec.lua` — catch, fresh raise vs. re-raise,
  trace clearing.
* `spec/coder/finally_spec.lua` — pending actions, finally override,
  nested finally order, GC-valued pending returns.
* `spec/coder/stack_relocation_spec.lua` — stack relocation through
  protected recovery.
* `spec/abi_spec.lua` — runtime/compiler ABI constants.
