# Error handling implementation

This chapter covers two related pieces of the implementation:

* unified Titan/Lua tracebacks, captured on the error path; and
* `raise`/`catch` and the internal `finally` that `defer` lowers to.

The surface language is documented in
[the language reference](../language/error-handling.md) and
[defer](../language/defer.md). This chapter is the canonical home for the trace
model, the error handler, trace pinning, the inline protected boundary, pending
`finally` actions, and scalar recovery storage across `setjmp`. The code lives
in `titan-runtime/titan.c` (`errorhandler` and the trace builder),
`titan-compiler/parser.lua`, the checker, and `titan-compiler/coder/statements.lua`
and `coder/flow.lua`. The `defer`-specific parser lowering is in
[Defer](defer.md).

## Runtime trace model

Every Lua-callable Titan entry wrapper ensures `errorhandler`
(`titan-runtime/titan.c`) is active as `L->errfunc` for the duration of the
call, reusing an outer Titan handler when one is already installed
(`titan_errfunc_is_errorhandler` in `titan-compiler/cpreamble.lua`). When Lua
raises an error, `luaG_errormsg` invokes that handler before the longjmp reaches
either a Lua `pcall` or Titan's inline protected boundary.

The handler stores the raw rendered traceback in
`registry[TITAN_BACKTRACE_KEY]`: frame lines only, with no error message, no
`stack traceback:` header, and no presentation tabs. The error value itself is
not wrapped. After the handler returns, Lua 5.5's `luaG_errormsg` replaces a nil
error object with `"<no error object>"` before throwing. Lua `pcall`, Titan's
catch-local `error`, and any re-raise observe that value; other values,
including false, remain unchanged.

Generated checked failures (`codethrow`, `titan-compiler/coder/values.lua`)
call `luaL_error` at the original Titan source line and then emit `abort()`.
Lua's public declaration returns `int`, so the C99 fallback makes the branch
terminal for the native compiler even without a nonreturning attribute. Lua
always raises first; the fallback is unreachable in normal execution. It
prevents optimized Option forces from retaining an impossible fallthrough with a
zero-initialized nominal result.

### Trace pinning

The registry also contains `TITAN_TRACE_PINNED`, a boolean pin flag. The
handler's rule is:

* if the pin is set, clear the pin and keep the existing traceback;
* otherwise, regenerate the traceback from the current stack.

This prevents stale-trace reuse while still supporting bare re-raise. For a bare
`raise` in a catch, `coderaise` (`titan-compiler/coder/statements.lua`) writes
the saved catch-local `traceback` back to `TITAN_BACKTRACE_KEY`, sets the pin,
places the saved `error` in the single top slot required by Lua's error ABI, and
calls `lua_error`. The handler sees the pin and preserves the original deep
trace. A fresh `raise <exp>` leaves the pin clear, so the handler captures a new
trace at the new raise site.

When a boundary catches an error for a `catch` or `finally`, it snapshots the
trace into a reserved stack slot and then clears both the trace slot and the
pin. A fully handled catch therefore leaves `titan.backtrace()` as `nil`; the
handled trace is available only through the catch-local `traceback`.

Recovery must not allocate, because an allocation failure there would raise a
secondary `LUA_ERRMEM` that skips `catch` or `finally` cleanup. Snapshot and
clear therefore access `G(L)->l_registry` through Lua's internal table machinery
(`titan_registry_get_string` and `titan_registry_set_string`), without the Lua
stack, `L->top` changes, or string interning. The keys `TITAN_BACKTRACE_KEY` and
`TITAN_TRACE_PINNED` and the empty-trace fallback `""` are pre-interned
`TString`s held in compiler-private module user values. `recovery_string`
(`coder/statements.lua`) requests a slot only when generated recovery or
re-raise code needs it, and `coder.generate` (`coder/generate.lua`) fills each
one with a back barrier during module initialization, before dependencies are
initialized or any generated code runs; see
[user-value allocation](codegen-overview.md#user-value-allocation) for the slot
order. `luaH_getstr`, the rooted `""` fallback, and short-string `nil` clears in
`luaH_psetshortstr`/`luaH_finishset` never allocate, even after an emergency
collection has swept dead nil-valued registry keys. The lookup tag is checked
before its result: an absent trace (such as `LUA_ERRMEM` raised directly by
`luaD_throw` without calling `L->errfunc`) falls back to the rooted empty
string. A non-nil re-raise insertion can still grow the registry hash when no
free node exists, but only after the enclosing cleanup has already run.
Intervening Lua-frame `__close` handlers can allocate; `luaD_closeprotected`
runs them under its own protection.

Coroutines use one extra registry slot, `TITAN_TRACE_APPEND_KEY`, for uncaught
errors in a dead coroutine. The coroutine entry stages its own trace there; the
`resume`/`error` side then raises and catches the same payload to capture the
propagation trace in the caller, appends it to the staged trace, writes the
combined string to `TITAN_BACKTRACE_KEY`, sets `TITAN_TRACE_PINNED`, and
re-raises the original payload. The final handler therefore preserves the
combined trace instead of only the shallow propagation site. The code is in
`titan/coroutine.titan` (see [Coroutines](coroutines.md)).

### libbacktrace and frame merging

The trace is a single innermost-to-outer stack built from two sources:

* Lua `CallInfo` frames, read with `lua_getstack`/`lua_getinfo`, provide the
  Lua-level activations, including pure Lua functions and genuine Lua C
  functions such as `pcall` (shown as `[C]` from `ar.short_src`).
* libbacktrace provides native frames from compiled Titan code, including
  native-to-native calls that have no Lua `CallInfo` of their own.

Generated Lua entry wrappers contain `titanentry` in their C symbol name. Those
wrapper frames are sentinels, not user-visible frames. The native side drains a
run of Titan frames until the next entry-wrapper sentinel, emitting only the
native Titan function frames and using the sentinel to align that native run
with the corresponding Lua `CallInfo`.

The trace builder also identifies Titan entry-wrapper CallInfos by symbolizing
their `lua_CFunction` pointer and looking for the same `titanentry` tag. Those
CallInfos are hidden; genuine Lua C functions are shown. This keeps
`Lua -> Titan -> Lua -> Titan` chains interleaved in call order.

The native collector (`titan_bt_collect_cb`) keeps only frames whose debug
filename ends in `.titan` plus the entry-wrapper sentinels. It drops
`titan-runtime/*` frames, unsymbolized frames, and Lua core and standard-library
frames matched against a fixed list of Lua 5.5 source filenames
(`titan_is_lua_source`). Dropping the library files keeps a Lua C function such
as `pcall` from appearing twice, once as its `[C]` CallInfo and once as a native
frame. Source filenames accept both Windows path separators.

Alignment is greedy: at each C-level CallInfo the next sentinel-terminated
native Titan run is drained. Strictly alternating Lua/Titan chains align
exactly. In a `Titan -> Lua C function (e.g. pcall) -> Titan` chain an inner
native run can be spliced one C frame early, but no Lua or Titan frame is
dropped.

On macOS libbacktrace needs the `.dSYM` bundle that `driver.lua`
`run_dsymutil` produces after each final link; without it native Titan frames
are unsymbolized and dropped. With `TITAN_NO_LIBBACKTRACE` defined (for example
on musl/Alpine), `errorhandler` falls back to raw Lua traceback lines plus raw
`execinfo` C frames.

#### Backtrace state invalidation

libbacktrace snapshots the process's loaded objects on its first symbol lookup,
so a newly mapped provider must invalidate it. Every generated module selects
`titan.o` from `libtitan.a` into its own image, so the cache cannot be a C
static: every runtime copy reads the same registry-owned userdata at
`TITAN_BT_STATE_KEY`, whose payload is the cached `backtrace_state *`.
`titan_invalidate_backtrace_state` clears that slot, and the next error lazily
creates a fresh state. It is called by:

* `loadlibfrompath` (`titan-runtime/titan.c`), only after `dlopen` maps a new
  image (the cached-handle fast path does not invalidate); and
* every generated `luaopen_*` (the postamble in `titan-compiler/coder/module.lua`),
  which covers modules loaded by Lua's own `require`.

The Windows loader (`titan-runtime/titan_winloader.h` `titan_win_load_library`)
does not call it: it clears the same registry slot inline, only when it maps a
new image, because the support-only bootstrap that uses it does not link the
full runtime.

The opaque state may retain function pointers into the image whose
libbacktrace copy created it. Titan never `dlclose`s dependency handles during
the process lifetime, and a Lua C-library handle stays mapped until its state
closes.

Windows uses libbacktrace's PE/COFF reader and the LLVM static unwinder. The
Windows dependency patch relocates COFF symbols to each loaded image's actual
base, bounds symbol lookup to that image's extent, and disables the upstream DLL
notification callback, which retains transient callback data and parses images
under the loader lock. Titan's own load/open invalidation refreshes the
snapshot outside that boundary.

### Source lines and display names

Native frames point back to Titan source through the `#line` directives
described in [mixed-source line attribution](codegen-overview.md#mixed-source-line-attribution);
the debug-information level that keeps those line records is chosen by
[`driver.compile`](driver.md#compiling-one-module-drivercompile). The trace
builder never inspects variable locations. With line directives disabled, the
debug filename no longer ends in `.titan`, so logical tracebacks may omit
native Titan frames; an entry boundary can remain only as a hidden sentinel or
render as `[C]`.

libbacktrace reports C symbol names, which cannot contain Titan punctuation
such as `.` or `:`. Each module `_init` contributes a mapping from native C
symbol name to display name in a shared registry table under `TITAN_NAMES_KEY`.
The runtime formats frames with those display names:

* `<module>.<function>`
* `<module>.<record>:<method>`
* `<module>.<record>.<static>`
* `anonymous function at <file>.titan:<definition-line>`

## Frontend representation

`catch`, `finally`, and `raise` are reserved words. `finally` has no surface
syntax; `Ast.StatTry`'s finally block exists only as the target of `defer`
lowering.

The grammar has no `try` keyword. The `block` production parses a statement
block and then optionally absorbs a `catch` trailer. `defs.trywrap`
(`titan-compiler/parser.lua`) returns the plain `Ast.StatBlock` when there is no
trailer and otherwise builds:

```lua
Ast.StatTry(loc, block, catchblock, nil)
```

`defer` statements lower to `Ast.StatTry(loc, tail, nil, finallyblock)`; see
[Defer](defer.md#parser-lowering).

`raise <exp>` and bare `raise` parse as `Ast.StatRaise(loc, exp)`, where a nil
`exp` means bare re-raise.

The catch clause body is a plain statement list, not a full trailer-consuming
block. Every `case` arm and its optional `else` consume the ordinary full
`block` production, so an arm can carry its own `catch` trailer or `defer`
statements and produces the same `Ast.StatTry` wrapper; there is no
case-specific error-handling form.

## Checker rules

`StatTry` checks its body, catch, and finally in sibling scopes. Catch-local
bindings are synthesized only in the catch scope:

* `error: value`
* `traceback: string`

They are read-only snapshots. The checker marks them as implicit catch locals
and rejects assignment to either name.

Body locals are deliberately invisible in catch/finally, because a body error
may happen before a given local declaration has executed. A `case` payload
binding is visible in that arm's protected body and its clauses; see
[Unions](unions.md#case-checking-and-control-flow).

The checker state counters are declared in `titan-compiler/checker/common.lua`
and saved and reset across nested function bodies
(`checker/declarations.lua`):

* `catch_depth`: bare `raise` is legal only while it is positive, so a lambda
  written inside a catch does not inherit re-raise permission.
* `in_finally`: `return` while positive is a compile-time error.
* `finally_loop_floor`: `break` inside a finally is an error unless its target
  loop was opened inside that finally.

`raise <exp>` checks the expression normally and coerces it to `value`. It is
allowed in a finally, because ordinary run-time errors can always occur during
cleanup and must override pending control flow. `StatRaise` is non-fallthrough.

The non-fallthrough rule for a try is:

```text
(finally exists and finally is non-fallthrough)
or
(body is non-fallthrough and (no catch or catch is non-fallthrough))
```

As with `StatBlock`, `StatIf`, and `StatCase`, `checkstat` records that result
on the node as `_always_returns`. Statement-list code generation consumes this
decoration when stopping at a dead tail; see
[non-fallthrough analysis](checker.md#non-fallthrough-analysis).

## Code generator overview

`codetry` (`titan-compiler/coder/statements.lua`) emits catch/finally as
straight-line C inside the native function. It does not allocate thunks or
capture the body into a closure.

A `StatTry` body always gets an inline protected boundary, including
finally-only (`defer`) blocks. A catch gets its own boundary only when a
finally follows it, so an error raised by the catch still runs the finally. A
finally installs no boundary of its own.

The boundary uses Lua 5.5's `lua_longjmp` layout and `TITAN_SETJMP` selector,
vendored into `titan-runtime/titan.h` from `ldo.c`. `boundary_save` and
`boundary_recover_open` mirror the parts of `luaD_rawrunprotected` and
`luaD_pcall` that matter for generated code:

1. save `L->nCcalls`, `L->ci`, `L->allowhook`, `L->errfunc`, and the old top
   offset;
2. link a stack-allocated `lua_longjmp` into `L->errorJmp`;
3. run the protected body under `TITAN_SETJMP`;
4. restore `L->errorJmp` and `L->nCcalls` on every exit from the protected
   block;
5. on error, restore `ci` and `allowhook`, restore the saved `errfunc`, run
   `luaD_closeprotected`, move the error object to the saved top with
   `luaD_seterrorobj`, recompute `_base` from `_base_off`, snapshot the error
   and trace into reserved slots, clear the registry trace and pin, restore
   `L->top.p` to `_base + TITAN_RESERVED_NSLOTS`, and reload setjmp-sensitive
   spills.

The saved `errfunc` is restored before `luaD_closeprotected` because the
longjmp may have skipped an inner Titan Lua-entry wrapper before that wrapper
could restore its own message handler. A Lua `__close` metamethod that raises
during cleanup must be handled by a valid Titan error handler, not by a stale
stack slot belonging to the skipped entry.

The saved error object, saved traceback, pending raise object, and GC-typed
saved return values live in reserved Lua stack slots below the function's
steady-state top; stack slots are roots and need no write barrier. Non-GC
pending return values live in `volatile` C temporaries, because they can be
written before a finally runs and read after a longjmp out of that finally.

A flexible pending return additionally needs a saved actual count, typed
backing for the live tail, and traced slots for every GC-bearing saved element.
The transient `_flexout` descriptor is caller-owned C memory and is not a root;
the pending-action frame preserves the values independently while the finally
body allocates, calls, or raises.

### Pending actions for finally

A try with finally has a discriminator whose values are the Lua string
constants `PA_NONE`, `PA_RETURN`, `PA_BREAK`, and `PA_RAISE` (`"0"`..`"3"`) in
`coder/statements.lua`, emitted as C integer literals.

Body or catch fallthrough leaves `PA_NONE`. A `return` or `break` inside a
finally-protected body or catch does not use `longjmp`; it saves any return
values, records the pending action, restores any protected boundaries that the
generated `goto` is about to exit, and jumps to the finally label.

After the finally runs, `dispatch_after_finally` emits an if-chain over the
pending action. It is intentionally not a C `switch`, because the `PA_BREAK` arm
must emit a `goto` to the label after the target Titan loop, not a C `break`
that a `switch` could capture. If the finally itself raises, the longjmp skips
the dispatch and overrides the pending action.

Nested finally blocks chain inside-out. During a pending return or break, the
inner dispatch can copy saved return values into an outer finally frame or
route a break through the next enclosing finally before realizing the final
action.

For a flexible return, that inside-out copy carries both the count and the live
tail, respecting the inherited `_flexwant` budget. Normal completion
reconstructs the native output descriptor and resumes the pending return; a
raise from the finally abandons it. The flexible-tail frame owns bounded typed
backing and, for GC-bearing elements, a parallel traced stack range that stays
live throughout the finally body and any inside-out frame copy.

### Boundary restoration on generated `goto`

The main footgun is a `goto` to a finally label that exits the C lexical scope
of one or more inline boundaries. If `L->errorJmp` still points at a
stack-allocated `lua_longjmp` in a scope the goto has left, a later raise from
the finally would longjmp through a dangling pointer.

The coder keeps `ctx.protected_boundary_stack`. Each finally frame records the
stack depth at which it was opened. A return or break routed to that finally
calls `restore_boundaries_to`, which emits restoration for every boundary deeper
than that floor before the `goto`:

```c
L->errorJmp = _lj_N.previous;
L->nCcalls = _oldnC_N;
```

Restoration stops at the finally's floor, so outer still-active boundaries
remain installed and can catch or cascade a raise from the finally.

Loop breaks have a second restoration path. A loop that contains a try saves
its entry `errorJmp`/`nCcalls` (`_loop_errorjmp_<id>`); a direct break that
crosses a try boundary restores that loop-entry state before jumping to the
loop's after-label.

### setjmp-sensitive local/parameter spills

C's `setjmp` rule makes the value of a non-`volatile` automatic variable
indeterminate after a longjmp if it was changed between `setjmp` and the
longjmp and is then read. Titan does not make every local or parameter C auto
`volatile`. Instead, `analyze_try_spills` (`titan-compiler/coder/flow.lua`)
runs a small liveness pass over each function or lambda that contains a
`StatTry`, and `mark_spills` sets `_needs_spill` on a Decl only when all of these
are true:

* the Decl is a Titan local, parameter, or method `self` in the current
  generated C function;
* it is not boxed through a capture cell;
* it is assigned in a protected body whose error path can later read it from a
  catch, finally, or handled post-try path; or it is assigned in a catch that
  has its own protected boundary and its finally can read it. A contextual
  mutable C-address conversion of a scalar counts as a possible write, including
  for an ordinary Titan call that can raise.

Marked GC-typed Decls use their existing reserved Lua stack slots as the stable
storage. Assignments keep the slot current, and protected recovery reloads the
C auto from the slot after `_base` and the reserved top have been restored.
Lua's GC is non-moving, so pointers to GC objects remain valid; only pointers
to Lua stack locations are recomputed from saved offsets such as `_base_off`.

Marked non-GC scalar Decls whose address is not exposed get a small C-stack
spill:

```c
lua_Integer _local_n_1;
volatile lua_Integer _spill_local_n_1;
```

`spill_update` refreshes the spill after assignments, and `spill_reload`
reloads the C auto from it in the recovery arm before catch, finally, or
post-try code can read it. `push_spillscope`/`pop_spillscope`
(`coder/statements.lua`) track lexical spill scopes, so a recovery boundary
reloads only spills whose Decls are currently in C scope. C aggregates use byte
spills; see
[longjmp-safe aggregate spills](c-ffi-expressions.md#longjmp-safe-aggregate-spills).

A non-GC scalar whose **mutable** C address is taken anywhere in the function
instead uses **one genuinely volatile automatic object** as its canonical
recovery home, plus a compiler escape barrier at its declaration:

```c
void *volatile _local_raw_1;
__asm__ __volatile__("" : : "r"(&(_local_raw_1)) : "memory");
```

`coder._decl_volatile_home` selects this home for a marked, address-taken,
unboxed, non-GC, non-aggregate Decl, including one marked by an earlier
protected region. `coder._local_cvardecl` applies the qualifier to locals and
parameters (including lambda parameters); no second spill or reload is emitted.
The callee receives the address of that very object. The top-level qualifier is
removed from the outgoing address type, not from the object; native signatures
and ABI are unchanged. `spill_decl_init` and `spill_decl_zero` emit the escape
barrier for every volatile home, including parameters and predeclared locals.

Rules for changing this code:

* **Toolchain contract.** This is an implementation guarantee on the supported
  GCC and Clang toolchains (including Windows MSYS2 Clang), not a strictly
  conforming ISO C guarantee: ISO C 6.7.3p6 makes access to an object defined
  volatile through a non-volatile lvalue undefined, and the out-parameter API
  uses unqualified pointers. MSVC is not a supported generated-C toolchain.
* **Why the barrier exists.** Without it, GCC can delete an inlined unqualified
  store through the address when a later checked conversion raises through
  terminal `luaL_error`/`abort` and only nonlocal recovery reads the home.
  Volatility alone does not preserve that indirect store; the barrier's address
  operand and `"memory"` clobber keep the home escaped after inlining, within
  one translation unit or across units under Linux's default
  `-O3 -flto=auto -ffat-lto-objects`.
* **Inlining assumptions.** A function that contains a `catch` exposes a
  `returns_twice` call and stays out of line under
  [GCC's `setjmp` inlining restriction](https://gcc.gnu.org/onlinedocs/gcc/Inline.html)
  and [LLVM's `isInlineViable`](https://github.com/llvm/llvm-project/blob/llvmorg-22.1.8/llvm/lib/Analysis/InlineCost.cpp#L3346-L3350).
  The default Lua build has no LTO IR, so `lua_error` and its nonlocal exit stay
  opaque. Whole-program LTO that exposes Lua's error machinery, or new optimizer
  behavior, requires requalifying this design.
* **Cost and scope.** The barrier emits no instruction but is a compiler memory
  barrier once per declaration (including each loop iteration that redeclares
  it). The home adds loads and stores, not allocation, copying, or calls. It
  does not cover untracked aliases or asynchronous C writes.
* **Regression.** The coder spec builds
  `spec/fixtures/error_handling/scalar_recovery.titan` as a native executable at
  `-O2` and `-O3` with the driver's default inlining thresholds: a
  checked-return callee writes through the scalar's address and then raises,
  and only the catch reads the local.

Ordinary Titan callees do not commit a mutable aggregate out-argument to its
byte spill, so recovery can lose a completed write; the limitation is
documented in
[longjmp-safe aggregate spills](c-ffi-expressions.md#longjmp-safe-aggregate-spills).

The variadic descriptor structs follow the same rule. Their C-stack records
contain counts and pointers to GC objects or typed C arrays, not pointers to Lua
stack slots, so the descriptor being on the C stack is not a stack-relocation
hazard.

## ABI and search path

The inline boundary depends on the vendored `lua_longjmp` layout matching the
linked Lua build, and generated recovery depends on the runtime's registry keys
and `titan_registry_*` helpers, so this machinery is part of the
[compiled-module ABI](codegen-overview.md#compiled-module-abi). Errors raised by
adapters, guards, conversions, or downcasts use the same Titan error handler,
and all wrapper roots are ordinary Lua-traced values, so unwinding needs no
resource-specific cleanup path. ABI markers keep the unversioned `.` component
of the default binary [search path](driver.md#module-names-and-the-search-paths)
from silently loading stale build artifacts.

## Tests to keep close

* `spec/coder/backtrace_spec.lua`: unified trace order, source-line
  attribution, standalone top-level error handler.
* `spec/coder/so_trace_names_spec.lua`: dlopened module trace-name
  registration and libbacktrace state invalidation.
* `spec/checker/error_handling_spec.lua`: catch/finally scopes, bare raise
  legality, finally transfer bans, and non-fallthrough analysis.
* `spec/coder/error_handling_spec.lua`: catch, fresh raise versus re-raise,
  trace clearing, pending actions, finally override, nested finally order,
  sustained-OOM catch/defer recovery across functions, closures, and module
  initializers, GC-valued pending returns (including flexible tails), and
  standalone uncaught-error reporting.
* `spec/coder/stack_relocation_spec.lua`: stack relocation through protected
  recovery.
* `spec/abi_spec.lua`: runtime/compiler ABI constants.
