# Titan error handling — implementation plan

**Date:** 2026-06-20 (rev. 2 — incorporates review feedback on the boundary, finally, and ABI)
**Depends on:** `.claude/plans/error-handling-traceback-research.md` (option analysis) + the libbacktrace spike (validated 2026-06-20, GCC 16.1.1 / DWARF5).
**Scope:** (A) unified Titan+Lua stack traces via libbacktrace + `#line` (error-path-only), and (B) the `catch`/`finally`/`raise` language feature with faithful `finally` semantics.

Two loosely-coupled deliverables. **A is lower-risk, high-value, and lands first** (an incremental upgrade of the existing `errorhandler`); B builds on it.

A surface-syntax correction to the research: per the design sketch there is **no `try` keyword** — `catch`/`finally` attach to *any* block, so they are modeled as optional trailers on the `block` grammar yielding a `StatTry` wrapper only when present.

---

## Part A — Unified traces (libbacktrace + `#line`)

The spike proved it: `backtrace_full` symbolizes PCs across **multiple dlopened `.so`s** to `#line`-attributed `.titan` file+line, recovers inlined frames, works at `-O2` with `-fno-optimize-sibling-calls`.

### A.1 `#line` emission in codegen
Add an `emitline(node)` helper rendering `#line <node.loc.line> "<node.loc.filename>"`:
- At function entry — `codefuncdec` after parameter setup, before the body (`coder.lua:4119`) — so the first frame attributes to the definition.
- At statement starts in `codestat` (`coder.lua:2211`).
- For `codeexp`'s `(stats, expr)` tuples, **prepend** to `stats`; never splice between multiply-evaluated operand slots (the "operands are not auto-hoisted" gotcha, `coder.lua` ~4045).
- Reference the `.titan` path. The source need **not** exist at runtime: a traceback needs only file+line, carried in the `.so`'s DWARF (always present with `-g`). Source snippets (needing the file) are out of scope.

### A.2 `errorhandler` → libbacktrace (`titan-runtime/titan.c:119-142`)
Replace `execinfo` `backtrace()`/`backtrace_symbols()` with libbacktrace:
- `static struct backtrace_state *state`, created lazily (`backtrace_create_state(NULL, 1, err_cb, NULL)`).
- Capture with `backtrace_full`; the callback gives `(pc, filename, lineno, function)`, already `.titan`-attributed via `#line`.
- **Merge with Lua frames:** keep `luaL_traceback` for the Lua side; filter native frames by DWARF filename — show `*.titan`, collapse `lua-5.5.0/src/*` to a single `[Lua]` marker, hide `titan-runtime/*`, drop unsymbolized libc frames. **Plant boundary sentinels:** give the generated Lua entry-wrappers a recognizable name prefix (Titan owns these — `genluaentry`) so the merge delimits native subtrees unambiguously instead of relying solely on filename heuristics.
- `#ifdef`-guard the old `execinfo` path as a no-line fallback (also fixes today's musl/Alpine build gap — `titan.c:5` hard-includes `execinfo.h`).

### A.3 libbacktrace state lifecycle (the spike's key caveat)
libbacktrace snapshots loaded `.so`s **once** at first symbolization and never re-scans → **invalidate the cached `state` (set `NULL`) after each successful `dlopen`** in `loadlib` (`titan.c:80-111`), **slow path only** (the cached-handle fast path loads no SO). Bounded leak (state is never freed; never recreate per-error). Handles are only `dlclose`d at state teardown (`gctm`), so mid-run staleness from unload is not a concern.

### A.4 Build/driver changes (`driver.lua`)
- `driver.CFLAGS` (`:18`): add `-g -fno-optimize-sibling-calls` (propagates to `titan.o`, line 139, and module `.o`s, line 159).
- **Vendor `libbacktrace.a`** into `titan-runtime/` (BSD-3); link into **every** final link — the per-module `.so` (`compile_library`, ~283-295) **and** the standalone-executable path (~269-295) — ordered **before `liblua.a`**.

### A.5 Registry trace discipline (a pin flag — fixes a stale-trace hazard)
"Regenerate iff slot nil" is wrong: a stale trace from a prior *unhandled* error would suppress the next fresh one. Use an explicit **pin flag**:
- Keys: `TITAN_BACKTRACE_KEY` (trace string, `titan.h:50`) + new `TITAN_TRACE_PINNED` (boolean).
- **Handler:** `if pinned { clear pin; keep slot } else { regenerate slot }`.
- A re-propagation pins (writes the saved trace, sets pin) → original preserved; a fresh error leaves pin clear → fresh trace; a `catch` reads the slot into `traceback` then clears slot + pin.

This is **load-bearing** for "a pending re-raise keeps the original trace; a newly-raised error (incl. in finally) gets a fresh one," and is an **observable change** (no more last-write-wins within a Lua entry) — ship documented, with a test that a fresh error after a handled one regenerates.

---

## Part B — `catch` / `finally` / `raise`

### B.0 Surface syntax
No `try` keyword. `catch`/`finally` attach to any block:

```titan
do
    <body>
catch              -- implicit locals: error: value, traceback: string
    <handler>
finally
    <cleanup>
end
```

…and identically as a function body, loop body, `if`/`then`/`else` branch, bare `do`. Both clauses individually optional (at least one forms the construct). Statements: `raise <exp>` (new error, `<exp>` has type `value`) and bare `raise` (only inside a catch; re-raise preserving the original traceback).

### B.1 Parser / lexer / AST
- **`lexer.lua:170-177`** — add `catch`, `finally`, `raise` to the keyword set (bars them as identifiers; were valid → changelog note).
- **`parser.lua:452`** — extend the `block` rule to optionally absorb `(CATCH block)? (FINALLY block)?` → a `StatTry` wrapper when present, plain `StatBlock` otherwise. Since every construct consumes `block`, catch/finally become available everywhere with no per-construct edits; the new keywords naturally terminate the inner statement list.
- **AST (`ast.lua`)** — `StatTry = {loc, block, catchblock?, finallyblock?}`, `StatRaise = {loc, exp?}` (`exp` absent ⇒ bare). `StatBlock` unchanged.
- **`syntax_errors.lua`** — labels for the new productions (`EndCatch`/`EndFinally`-style closers, `ExpRaise`).
- **Visitor exhaustiveness** — `StatTry`/`StatRaise` need arms in `checkstat` (`checker.lua:480`) and `codestat` (`coder.lua:2211`) only. No new `Exp`/`Type`/`Var` tags (the `raise` operand reuses `checkexp`).

### B.2 Checker (`checker.lua`)
- **Sibling scopes (not nested):** body locals are *not* visible in catch/finally (a body local may be undeclared when the error fires). Check the body in its own scope and close it; then a **separate** catch scope in which you `declare()` `error: value` + `traceback: string` (`types.Value()` / `types.String()` exist — `types.lua:12,281`); then a **separate** finally scope.
- **Bare-`raise` legality:** add a `catch_depth` counter (mirror `loop_depth`, `:26`) incremented **only inside catch blocks**; reject bare `raise` unless `catch_depth > 0`. **Save/restore to 0 across every nested function body** (a bare `raise` in a lambda defined in a catch must be rejected) and reset in `checker.check`.
- **A control transfer that *exits* a `finally` block is a compile-time error** (`return`, and a `break` that escapes the finally). The principle: nothing may statically leave a finally; only an (unpreventable) raise can. Mechanism:
  - `in_finally` counter — incremented entering a finally block. `StatReturn` errors if `in_finally > 0`.
  - `finally_loop_floor` — set to the current `loop_depth` on entry to the innermost finally. `StatBreak` errors as a finally-escape if `in_finally > 0 AND loop_depth <= finally_loop_floor` (i.e. no loop was opened *inside* the finally, so the target loop encloses it). A `break` targeting a loop written inside the finally (`loop_depth > finally_loop_floor`) is contained and **legal**.
  - Both `in_finally` and `finally_loop_floor` (like `catch_depth` and `loop_depth`) are **saved/reset across nested function bodies** and reset in `checker.check`, so a `return`/`break` inside a lambda defined in a finally is governed by the lambda, not the finally.
  - **`raise` in finally is allowed:** runtime errors can raise from finally regardless and cannot be statically prevented, so banning the explicit keyword would be an inconsistent half-measure. `raise <exp>` (and runtime errors) propagate out and override the pending action — the one unavoidable override path. (Bare `raise` in finally is already illegal: it requires `catch_depth > 0`, and a finally is not a catch.)
- **`raise <exp>`:** check `exp` with no target type; `<exp>` has type `value` (any value coerces to `value`; matches the `error: value` binding).
- **Always-returns rule** (corrected — the naive `(B and C)` under-reports and would force spurious "missing return"). With body `B`, optional catch `C`, optional finally `F`, and `raise` treated as a terminator like `return`:
  > `StatTry` always-returns iff `(F present AND F always-returns)` **OR** `(B always-returns) AND (C absent OR C always-returns)`.

  `StatRaise` always-returns ⇒ `true`. (With `return` banned in finally, `F` reaches "always-returns" only via an unconditional `raise`.)

### B.3 Faithful `finally` semantics
One mechanism: every exit records a **pending action** ∈ `{NONE, RETURN(vals), BREAK, RAISE}`; `finally` runs on **every** exit; then a dispatch performs the pending action — **unless `finally` raises** (explicit `raise <exp>` or a runtime error), which overrides and abandons the pending action and propagates out. (`return` and a finally-*escaping* `break` are compile errors, so raising is the *only* override path — a deliberate restriction; a `break` contained within a loop inside the finally is local and overrides nothing.)

Mechanism distinction (important): **errors** (`raise`, runtime faults) propagate by `longjmp` and are caught by the nearest inline boundary; **`return`/`break`** are *not* errors — they set the pending action and `goto` the finally label directly. This matters for the trace: the handler captures the trace at the **original raise point** (correct stack depth), which the boundary then snapshots; `finally` runs; the dispatch **reinstalls + pins** the saved trace before re-raising, so finally running in between never causes a shallower re-capture.

| # | Situation | Behavior |
|---|---|---|
| a | body completes normally | `pending=NONE`; finally; fall through |
| b | body raises, catch present | boundary catches longjmp; bind `error`←caught value, `traceback`←slot snapshot; clear slot+pin; run catch |
| c | body raises, **no catch** | snapshot trace, `pending=RAISE`; clear slot+pin; finally; if it completes → reinstall+pin, re-raise |
| d | body `return`/`break` | not an error: save temps, set `pending`, `goto finally` |
| e | catch completes normally | `pending=NONE`; finally; error swallowed; slot stays clear (`titan.backtrace()`→nil) |
| f | catch bare `raise` | reinstall the snapshotted **original** trace + pin, then `lua_error(error)` → handler keeps original; boundary catches; finally; dispatch re-raises (C# `throw;`) |
| g | catch `raise <exp>` / new error | `lua_error` → handler builds **fresh** trace at the raise point; boundary catches; snapshot; finally; dispatch re-raises with that fresh trace |
| h | catch `return`/`break` | as (d); error handled |
| i | finally completes normally with a pending action | dispatch (if-chain): RAISE→reinstall+pin+`lua_error`; RETURN→`L->top.p=_base; return <saved>`; BREAK→`goto` past enclosing loop; NONE→fall through |
| j | **finally raises** (explicit/runtime; `return` & escaping `break` are compile errors) | **overrides**: the raise `longjmp`s out (past the dispatch), abandoning the pending action; the slot is clear ⇒ fresh trace |
| k | nested try | each has its own discriminator+finally+dispatch; a re-raise `longjmp`s through outer boundaries (running their finallys inside-out); a cross-try `return`/`break` is realized as the outer try observing a return/break leaving its region (chained rewrites) |

Errors are plain Lua values with an out-of-band trace; there is **no error-object-with-cause**, so "chaining" is not a concept here — a new error in catch/finally simply replaces the in-flight one (the previous error value and its trace are not retained). Document this plainly.

### B.4 Codegen lowering (`coder.lua` + runtime) — inline boundary, no thunks
**Vendor the setjmp machinery.** Copy `ldo.c:61-109` *verbatim* — `struct lua_longjmp` (`previous`, `jmp_buf b`, `volatile TStatus status`) and the `LUAI_THROW`/`LUAI_TRY` `#ifdef` ladder (C++ / POSIX `_setjmp` / ISO `setjmp`) — into a **runtime header** (e.g. `titan-runtime/titan.h` or a dedicated `titan_longjmp.h`) included by both `titan.c` **and the generated module `.c`** (the generated code must see the type/macros to emit the boundary inline). Mark it clearly as vendored from Lua 5.5.0 `ldo.c` so it tracks future Lua releases. `lstate.h` only forward-declares the struct (a pointer field), so a verbatim full definition is conflict-free **and stays byte-compatible with the linked `liblua.a`** — that compatibility is exactly why it must remain verbatim and be re-synced on Lua upgrades. Since `LUAI_TRY` is function-form (takes a `Pfunc`), also define a statement-form `TITAN_SETJMP(buf)` from the same `#ifdef` selection (`_setjmp`/`setjmp`). The inline boundary requires Lua built with longjmp (not C++ exceptions) — which is what `make lua` produces.

**Inline the boundary (no thunk, no capture conversion).** The protected body and the catch block are emitted as **straight-line C inside the generated native function**, each wrapped in its own inline boundary that replicates `luaD_rawrunprotected` plus `luaD_pcall`'s error recovery:

```c
/* save (rawrunprotected) */
l_uint32   _oldnC   = L->nCcalls;
CallInfo  *_old_ci  = L->ci;
lu_byte    _old_ah  = L->allowhook;
ptrdiff_t  _oldtop  = savestack(L, L->top.p);   /* level to restore the error obj to */
lua_longjmp _lj; _lj.status = LUA_OK; _lj.previous = L->errorJmp; L->errorJmp = &_lj;
if (TITAN_SETJMP(_lj.b) == 0) {
    <BODY inline>           /* return/break -> set _pa(+temps); restore errorJmp; goto _finally */
}                           /* fall off end -> _pa stays NONE */
L->errorJmp = _lj.previous; L->nCcalls = _oldnC;
if (_lj.status != LUA_OK) { /* body raised (errfunc already ran, trace in slot) */
    L->ci = _old_ci; L->allowhook = _old_ah;
    _lj.status = luaD_closeprotected(L, _oldtop, _lj.status);  /* run __close of any called-Lua tbc vars */
    luaD_seterrorobj(L, _lj.status, restorestack(L, _oldtop)); /* moves err to _oldtop; sets top */
    _base = restorestack(L, _base_off);                        /* recompute if a value-call moved the stack */
    /* error object now at L->top.p-1; snapshot slot trace; clear slot+pin; save error to a reserved slot */
    /* then: run CATCH (also under its own inline boundary) OR _pa = RAISE for the no-catch case */
}
_finally:  <FINALLY inline>          /* straight-line; return & escaping break are compile errors,
                                     ** so finally never touches the pending machinery; only a raise
                                     ** here longjmps out, naturally skipping the dispatch (override) */
/* dispatch (IF-CHAIN, never a C switch): */
if      (_pa == PA_RETURN) { /* L->top.p=_base; return <saved temps> (out-params copied) */ }
else if (_pa == PA_BREAK)  { goto _after_enclosing_loop; }
else if (_pa == PA_RAISE)  { /* reinstall saved trace + pin; push saved err; lua_error(L) */ }
/* PA_NONE: fall through */
```

Why this is correct and cheap:
- The message handler is on `L->errfunc` (installed once by `genluaentry`, `coder.lua:4013-4015`) and is invoked by `luaG_errormsg` regardless of which boundary is on `L->errorJmp` — so the inner boundary inherits it; no closure, no `errfunc` plumbing.
- Recovery mirrors `luaD_pcall` (not just `rawrunprotected`): restore `errorJmp`/`nCcalls`/`ci`/`allowhook`; `luaD_closeprotected` so to-be-closed vars in *called Lua* code still run (Titan generates none itself, but called Lua may have them); `luaD_seterrorobj` to place the error object and reset `top`.
- **The only residual obligation** (the C `setjmp` rule, C11 §7.13.2.1): it applies to automatic variables of the **whole generated function**, not just the protected block. Locals *declared inside* the protected block are out of scope in catch/finally (sibling scopes) and after the block, so they are never read post-`longjmp` and need nothing. The at-risk set is **non-GC locals from an *enclosing* scope (including parameters)** that are assigned inside a protected region and read afterward — in catch, in finally, or after the construct when the error was handled. Example: `local n = 0; do n = f(); risky() catch log(n) end; return n` — `n` is enclosing, mutated in the body, read after. Such locals must be `volatile` (or stack-anchored). **GC-typed locals are already safe** (they live in Lua stack slots off `_base`, i.e. memory, not C autos), so this only touches non-GC enclosing locals live across a boundary — the coder marks them `volatile`. This replaces capture conversion entirely.

**Pending dispatch — `if`-chain, not `switch`.** Titan `break` lowers to a literal C `break` and loops to `while(1){…}` (`coder.lua:2322`, 846+); a C `switch` for the dispatch would *capture* the `PA_BREAK` arm's `break`. Use an `if`-chain and realize `PA_BREAK` as a `goto` to a label after the enclosing Titan loop.

**GC anchoring (barrier note).** Saved RAISE error objects and saved GC-typed RETURN values go in per-try `newslot`-reserved stack slots (**not** the `genluaentry` entry-wrapper error slot, which is a fixed Lua index that would alias across native→native calls). A write into a **stack slot needs no write barrier** (the stack is a GC root): `setobj2s` + keep `top` above the slot. Non-GC saved scalars stay in C temps (`volatile` per the rule above). Saved multi-returns mirror `codereturn`'s out-param order/fill (`coder.lua:2184-2188`).

**`raise` lowering.** `raise <exp>` reuses the `codethrow`/`luaL_error` path (`coder.lua:191-198`) with pin clear (handler builds a fresh trace at the raise point). Bare `raise` reinstalls the `traceback` local + sets pin, then `lua_error(error)` so the handler preserves the original trace.

---

## Resolved decisions (per review)
- **`raise <exp>` type** = `value` (any value; matches the `error: value` binding).
- **ABI stays `0.9`** — native signatures, `<mangled>_types`, and the out-param convention are unchanged (control-flow only). The `errorhandler` pin-flag and libbacktrace state are process-wide runtime changes, documented as a minimum-runtime requirement rather than an ABI bump.
- **No exception chaining** — not a concept (errors are plain values); a new error in catch/finally replaces the in-flight one.
- **No control transfer may exit a `finally`** — `return` and a finally-escaping `break` are compile-time errors; a `break` to a loop *inside* the finally is fine; `raise` (explicit/runtime) is allowed and is the sole override path.
- **Boundary** — inline setjmp via vendored `lua_longjmp`/`LUAI_TRY` (no thunks, no capture conversion).

## Remaining risks
1. **`volatile` correctness for non-GC *enclosing* locals across the boundary** — body-declared locals are out of scope post-`longjmp` and need nothing; the at-risk set is non-GC locals from an enclosing scope (incl. parameters) assigned inside a protected region and live across its boundary (read in catch/finally/after). The coder must mark those `volatile`. Get the liveness set right (over-mark if unsure; correctness > a few extra `volatile`s). Highest-attention item in Phase 4.
2. **Recovery sequence parity with `luaD_pcall`** — `_base`/`top`/`ci` restoration after a caught longjmp, especially when a value-call moved the stack (`ctx.uses_base_off`, `coder.lua:4124`). Specify and test.
3. **Vendored-struct sync** — `struct lua_longjmp` must stay byte-compatible with the linked `liblua.a`; re-sync on Lua upgrades (it's marked for that).
4. **`raise` of non-string values** — `errorhandler`'s `luaL_tolstring`/`luaL_traceback` and the standalone `msghandler` must handle non-string error objects gracefully. Test.
5. **Reserved-word break** — `catch`/`finally`/`raise` were valid identifiers; changelog note.

## Phased implementation order (each independently testable)
- **Phase 0 — runtime traces** (A.2–A.5): libbacktrace in `errorhandler` + cached state + dlopen invalidation + pin-flag; vendor & link `libbacktrace.a` into `.so` *and* executable; CFLAGS `-g -fno-optimize-sibling-calls`. Tests: existing `titan.backtrace()` spec passes; new specs for `.titan` frames across a dlopened `.so`, pin-flag preserve, regeneration after clear. No syntax yet.
- **Phase 1 — `#line`** (A.1): `emitline` at function entry + statement starts. Verify Phase-0 traces show correct `.titan` lines under `-O2`.
- **Phase 2 — `raise` only**: reserve keywords; `StatRaise` (+ `StatTry` AST shape), grammar, `syntax_errors` labels; parser specs. `raise <exp>` via `codethrow`; bare `raise` rejected by checker.
- **Phase 3 — checker**: `catch_depth` + `in_finally` + `finally_loop_floor` (all saved/reset across lambdas, reset in `check`), implicit `error`/`traceback` in sibling catch scope, bare-raise-only-in-catch, return-in-finally + finally-escaping-break errors, corrected always-returns. `spec/checker/` incl. negatives (bare raise in body/finally/lambda; return in finally; escaping break in finally) and positives (contained break in a loop inside finally; return/break in a lambda inside finally).
- **Phase 4 — codegen boundary + catch (no finally)**: vendor `lua_longjmp`/`LUAI_TRY` + `TITAN_SETJMP` into the runtime header; inline boundary + the `luaD_pcall`-parity recovery + `volatile` marking of non-GC crossing locals + per-try anchored error/traceback slots + catch snapshot/clear + bare-raise reinstall + raise-new-leaves-clear. `spec/coder/`: body-raise→catch, bare re-raise preserves original trace, raise-new gets fresh trace, catch-that-itself-raises still reaches its boundary.
- **Phase 5 — codegen finally + pending-action**: discriminator, return/break rewrite-to-finally (for body/catch), finally-only re-propagation, finally-override via raise only (finally is straight-line; no return/escaping-break to handle), `if`-chain dispatch with `PA_BREAK` as goto-past-loop, saved multi-returns, GC-anchored saved returns. `spec/coder/`: finally-on-every-exit, return-in-try-runs-finally, finally-raise-overrides-pending-action, nested inside-out finally, break-in-try-in-for.
- **Phase 6 — docs + ABI note (release gate)**: rewrite `doc/language/error-handling.md` (syntax, finally-override, return-in-finally rule, no-chaining, runtime requirement); add `doc/implementation/error-handling.md` (parser/checker/coder/registry-trace/libbacktrace/vendored-longjmp internals); link both from the `index.md`s. Document the `0.9`-stays decision + min-runtime requirement. Full suite green (`make test`).

## Documentation deliverables (CLAUDE.md mandate)
`doc/language/error-handling.md` **exists** and says Titan has no try/catch — it must be **rewritten**. Add `doc/implementation/error-handling.md`. Both are part of "done."
