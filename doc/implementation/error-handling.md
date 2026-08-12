# Error handling implementation

This chapter covers two related pieces of the implementation:

* unified Titan/Lua tracebacks, captured on the error path; and
* the `raise` / `catch` / `finally` language feature.

The surface language is documented in
[the language reference](../language/error-handling.md). This chapter is
for contributors changing `titan-compiler/coder.lua`,
`titan-runtime/titan.c`, or the parser/checker rules.

## Runtime trace model

Every Lua-callable Titan entry wrapper ensures `errorhandler` is active
as `L->errfunc` for the duration of the call, reusing an outer Titan
handler when one is already installed. When Lua raises an error,
`luaG_errormsg` invokes that handler before the longjmp reaches either a
Lua `pcall` or Titan's inline catch/finally boundary.

The handler stores the raw rendered traceback in
`registry[TITAN_BACKTRACE_KEY]`: frame lines only, with no error message,
no `stack traceback:` header, and no presentation tabs. The error value
itself is not wrapped: Lua `pcall`, Titan's catch-local `error`, and any
re-raise see the exact Lua value that was raised.

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

Coroutines use one extra registry slot, `TITAN_TRACE_APPEND_KEY`, for
uncaught errors in a dead coroutine. The coroutine entry stages its own
trace there, then the `resume`/`error` side raises and catches the same
payload to capture the propagation trace in the caller. It appends the new
trace to the staged coroutine trace, writes the combined string to
`TITAN_BACKTRACE_KEY`, sets `TITAN_TRACE_PINNED`, and re-raises the
original payload. The final handler therefore preserves the combined trace
instead of replacing it with only the shallow propagation site.

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

`titanc --no-line-directives`, or `TITAN_NO_LINE_DIRECTIVES=1` for build
automation, suppresses those directives so native diagnostics instead report
the generated `.c` file and physical line. This is a diagnostic mode; the
default remains Titan source attribution. The display-name registry itself is
independent of the directives, but the traceback builder retains ordinary
native Titan frames only when their debug filename identifies Titan source.
With directives disabled, logical tracebacks may therefore omit those frames;
an entry boundary can remain only as a hidden sentinel or render as `[C]`.

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

Each generated module selects `titan.o` from `libtitan.a` into its own DSO;
installed mode uses the SDK archive and checkout mode uses the lazily rebuilt
local archive, never a direct object link. Invalidation is therefore not just
a C static reset. Every runtime copy reads the same registry-owned userdata at
`TITAN_BT_STATE_KEY`, whose payload is the cached `backtrace_state *`.
Invalidation clears that slot, and the next error lazily creates a fresh state
with the complete loaded-object snapshot. The opaque state may retain function
pointers into the DSO whose libbacktrace copy created it; Titan never `dlclose`s
dependency handles during the process lifetime, and a Lua C-library handle
remains mapped until its state closes, after which that registry cache cannot
be used. This keeps the cache per Lua state without mutable per-DSO C globals.

## Frontend representation

`catch`, `finally`, and `raise` are reserved words (`finally` is reserved in the lexer, though surface syntax `finally` blocks have been removed from the language).

The grammar has no `try` keyword. The `block` production parses a normal
statement block and then optionally absorbs a `catch` block trailer.
If no catch trailer is present (and no `defer` statements were lowered into `finallyblock`),
the AST is the normal `Ast.StatBlock`; otherwise the parser builds:

```lua
Ast.StatTry(loc, block, catchblock_or_false, finallyblock_or_false)
```

Lowered `defer` statements produce `Ast.StatTry` nodes with `finallyblock` set to an `Ast.StatBlock` containing the deferred statement.

`raise <exp>` and bare `raise` parse as:

```lua
Ast.StatRaise(loc, exp_or_false)
```

The catch clause body is a plain statement list, not a full
trailer-consuming block.

Every `case` arm and its optional `else` consume the ordinary full `block`
production. An arm can therefore carry its own `catch` trailer or `defer` statements, and
the parser produces the same `Ast.StatTry` wrapper used anywhere else. There
is no case-specific error-handling form.

## Checker rules

`StatTry` checks its body, catch, and finally in sibling scopes.
Catch-local bindings are synthesized only in the catch scope:

* `error: value`
* `traceback: string`

They are read-only snapshots. The checker marks them as implicit catch
locals and rejects assignment to either name.

Body locals are deliberately invisible in catch/finally, because a body
error may happen before a given local declaration has executed.

A `case` payload binding is established in the arm scope outside a possible
`StatTry`, so it is visible in that arm's protected body, `catch`, and
`finally`. Locals declared by the protected body remain invisible to the
sibling clauses.

Bare `raise` is legal only while checking a catch block. The checker uses
a `catch_depth` counter for that rule and resets it across nested function
bodies, so a lambda written inside a catch does not inherit re-raise
permission.

`raise <exp>` checks the expression normally and coerces it to `value`.
`StatRaise` is non-fallthrough for the purpose of checking that a function
with fixed nonnil returns cannot fall off the end.

`finally` blocks are not allowed to transfer control out explicitly:

* `return` while `in_finally > 0` is a compile-time error.
* `break` while `in_finally > 0` is a compile-time error unless the
  target loop was opened inside that finally. The checker tracks this
  with `finally_loop_floor`.
* `raise <exp>` is allowed in finally, because ordinary run-time errors
  can always occur during cleanup and must override pending control flow.

The non-fallthrough rule for a try is:

```text
(finally exists and finally is non-fallthrough)
or
(body is non-fallthrough and (no catch or catch is non-fallthrough))
```

As with `StatBlock`, `StatIf`, and `StatCase`, `checkstat` records that result
on the node under the historical name `_always_returns`. Statement-list code
generation consumes this decoration when stopping at a dead tail; it does not
recognize only direct `return`, `break`, or `raise` tags.

## Code generator overview

The code generator emits catch/finally as straight-line C inside the
native function. It does not allocate thunks or capture the body into a
closure.

A `StatTry` body always gets an inline protected boundary, including
finally-only blocks. A catch gets its own boundary only when a finally
follows it; that is the case where an error raised by the catch must still
run the finally. A finally installs no boundary of its own.

The inline boundary is based on Lua 5.5's `lua_longjmp` layout and
longjmp macro choices, vendored directly into `titan-runtime/titan.h` and
included by `titan.h`. It mirrors the parts of `luaD_rawrunprotected` and
`luaD_pcall` that matter for generated code:

1. save `L->nCcalls`, `L->ci`, `L->allowhook`, `L->errfunc`, and the
   old top offset;
2. link a stack-allocated `lua_longjmp` into `L->errorJmp`;
3. run the protected body under `TITAN_SETJMP`;
4. restore `L->errorJmp` and `L->nCcalls` on normal fallthrough;
5. on error, restore `ci`/`allowhook`, run `luaD_closeprotected`, move the
   error object to the saved top with `luaD_seterrorobj`, recompute `_base`
   from `_base_off`, snapshot the error and trace into reserved slots, clear
   the registry trace/pin, and restore `L->top.p` to the function's reserved
   stack area.

Before `luaD_closeprotected`, Titan restores the `errfunc` value saved at
boundary entry. This matters when the longjmp skipped an inner Titan
Lua-entry wrapper before that wrapper could restore its own message
handler. Lua `__close` metamethods can raise while cleanup runs; those
replacement errors should be handled by a valid Titan error handler, not
by a stale stack slot belonging to an inner entry wrapper.

The saved error object, saved traceback, pending raise object, and
GC-typed saved return values live in reserved Lua stack slots below the
function's steady-state top. Stack slots are roots and need no write
barrier. Non-GC pending return values live in internal `volatile` C
temporaries, because they can be written before a finally runs and read
after a longjmp out of that finally.

A flexible pending return additionally needs a saved actual count, typed
backing for the live tail, and traced slots for every GC-bearing saved element.
The transient `_flexout` descriptor is caller-owned C memory and is not a root;
the pending-action frame must preserve the values independently while the
`finally` body allocates, calls, or raises.

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

For a flexible return, that inside-out copy must carry both the count and the
live tail, respecting the inherited `_flexwant` budget. Normal completion
reconstructs the native output descriptor and resumes the pending return; a
raise from `finally` abandons it and overrides the action. The flexible-tail
frame owns bounded typed backing and, for GC-bearing elements, a parallel
traced stack range that remains live throughout the finally body and any
inside-out frame copy.

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

### setjmp-sensitive local/parameter spills

C's `setjmp` rule makes the value of a non-`volatile` automatic variable
indeterminate after a longjmp if it was changed between `setjmp` and the
longjmp and is then read. Titan does not make every local/parameter C
auto `volatile`. Instead, each function/lambda that contains a `StatTry`
runs a small liveness pass before code generation.

The pass marks a Decl as needing a spill only when all of these are true:

* the Decl is a Titan local, parameter, or method `self` in the current
  generated C function;
* it is not boxed through a capture cell;
* it is assigned in a protected body whose error path can later read it
  from a catch, finally, or handled post-try path; or it is assigned in a
  catch that has its own protected boundary and its finally can read it.

Marked GC-typed Decls use their existing reserved Lua stack slots as the
stable storage. Assignments keep the slot current, and protected recovery
reloads the ordinary C auto from the slot after `_base` and the reserved
top have been restored. Lua's GC is non-moving, so pointers to GC objects
remain valid across collections; the relocation hazard is only pointers to
Lua stack locations, which are always recomputed from saved offsets such
as `_base_off`.

Marked non-GC scalar Decls get a tiny internal C-stack spill:

```c
lua_Integer _local_n_1;
volatile lua_Integer _spill_local_n_1;
```

Codegen updates the spill after assignments that update the Titan
local/parameter, and protected recovery reloads the ordinary C auto from
the volatile spill before catch/finally/post-try code can read it. The
`volatile` qualifier is therefore limited to internal spill storage; the
Titan-visible local/parameter variables and the native function ABI remain
plain C declarations.

`coder.lua` also tracks lexical spill scopes, so a recovery boundary
reloads only spill slots whose Decls are currently in C scope.

The variadic descriptor structs follow the same rule. Their C-stack
records contain counts and pointers to GC objects or typed C arrays, not
pointers to Lua stack slots. The descriptor object being on the C stack is
therefore not itself a stack-relocation hazard.

## ABI and search path

The current compiled-module ABI is `0.23`. The error-handling control-flow
machinery did not by itself require an ABI bump. The earlier ABI-0.10 change
changed the `TitanVargX` structs from inline flexible-array backing
objects to descriptor structs with an `args` pointer. That layout change
is visible across `.so` boundaries even though the native parameter type
names stayed the same, so `0.9` and `0.10` modules must not be mixed.
The later `0.11` ABI keeps those descriptors and additionally changes
record-interface serialization for module-local records and record members.
The `0.12` ABI keeps that layout and adds the public type-alias namespace to
serialized module interfaces. The `0.13` ABI adds formal-name metadata to the
serialized module-function, method, and record-static descriptor constructors;
the native function ABI is unchanged.

Flexible result metadata and the trailing native `_flexout`/`_flexwant` pair
are incompatible with the 0.13 interface/native shape. ABI 0.14 moves the
serialized constructors, native signature, constants, and paths together and
does not accept a mixed layout.

ABI 0.15 keeps that callable shape but deliberately reorders the exported
members of `titan.uv` as its public declarations move into semantic folder
contributors. Separating 0.15 paths prevents 0.14 importers from reconstructing
those canonical closure slots with the old order.

ABI 0.16 keeps the callable and serialized-type shapes again, but changes the
physical provider contract: compiled lookup may select a prefix container and
the standard library's dynamic form is one `titan.so` plus logical-module
shims. A 0.15 runtime hard-codes exact module DSOs and cannot discover that
layout. The later self-describing `titan.a` repeats the same ABI/types
protocol, so paired static providers do not require another ABI bump.

ABI 0.17 keeps the same error and nonlocal-control-flow machinery but changes
the meaning of Array values at native and Lua boundaries. Exact paths retain
`Table *` / `Table **`; generic paths use canonical proxy Udata, and a resize
must keep backing, proxy, RHS, and pending flexible values rooted across any
allocation or `luaL_error`. A 0.16 module cannot safely participate in that
protocol. See [Dense Arrays](dense-arrays.md#failure-and-performance-boundaries).

ABI 0.18 also left this error and nonlocal-control-flow machinery unchanged.
It advances the compiled-module boundary because standard-library archive
objects now directly reference promoted libuv callback trampolines and no
longer reference replaced libuv/coroutine helper symbols. A 0.18 provider and
runtime had to be distributed together.

ABI 0.19 likewise kept the pending-action and longjmp machinery unchanged.
It advanced the boundary for serialized union/variant schemas, union userdata
dispatch, and the reconstructible public nominal-static slot prefix. A case
arm still runs through the ordinary `StatTry` cleanup path.

ABI 0.20 again left pending actions and longjmp unwinding unchanged. Its
boundary covered the two-user-value Array proxy, the strict-entry-bearing
first-class function closure, and Interface metadata/wrappers/bound
trampolines. ABI 0.21 retained this machinery while advancing the matched Lua
internal-header/runtime contract to 5.5.1. ABI 0.22 retained it while changing
the source-local `titan.uv` schema/module prefix and adding the fixed physical-
provider identity slot. ABI 0.23 retains all of this error machinery again;
its boundary is the source-defined callback and separated
module/nominal/member native-name contract. Errors raised by an Interface adapter,
strict guard, dynamic conversion, or failed exact downcast still use the same
Titan error handler; all wrapper and adapter roots are ordinary Lua-traced
values, so unwinding requires no resource-specific cleanup path.

The compiler and runtime therefore agree on:

* `TITAN_VER "0.23"`
* `TITAN_VER_SUFFIX "_0_23"`
* versioned binary path variable `TITAN_PATH_0_23`
* default binary path `.;<root>/lib/titan/0.23`, with `<root>` recovered from
  the Lua `PREFIX`'s `package.cpath` in the currently supported layout where
  that path also names the equal Titan `ROCKS_TREE`

Every generated module also exports `<mangled>_abi`, a Lua C function
returning `TITAN_VER`. DSO rehydration checks that marker before trusting
`<mangled>_types`, and generated dynamic imports call `titan_check_abi` after
`loadlib` and before `dlsym`ing native entries. Static-provider rehydration
checks the same ABI value in the canonical embedded metadata before decoding
its types. A missing DSO marker or missing exact archive entry is rejected;
this protects the unversioned `.` component of the default path from silently
loading stale build artifacts.

`spec/abi_spec.lua` pins the compiler/runtime agreement and rejection of
markerless legacy `.so` files.

## Tests to keep close

The highest-value regression tests are:

* `spec/coder/backtrace_spec.lua` — unified trace order, source-line
  attribution, standalone top-level error handler.
* `spec/coder/so_trace_names_spec.lua` — dlopened module trace-name
  registration and libbacktrace state invalidation.
* `spec/checker/error_handling_spec.lua` — catch/finally scopes, bare
  raise legality, finally transfer bans, and non-fallthrough analysis.
* `spec/coder/error_handling_spec.lua` — catch, fresh raise vs. re-raise,
  trace clearing, pending actions, finally override, nested finally order,
  GC-valued pending returns, including flexible tails across allocating/nested
  finally blocks, and standalone uncaught-error reporting.
* `spec/coder/stack_relocation_spec.lua` — stack relocation through
  protected recovery.
* `spec/abi_spec.lua` — runtime/compiler ABI constants.
