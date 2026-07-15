# Titan error handling: unified stack traces — research & recommendation

**Date:** 2026-06-20
**Scope:** the *trace-collection* mechanism for Titan's error handler (the two options in the design notes), grounded in the Lua 5.5 source (`lua-5.5.0/`), the Titan compiler, and external research on libbacktrace and pallene-tracer. The *language-level* `catch`/`finally`/`raise` design is touched only where it interacts with trace collection.

---

## TL;DR

1. **Do the `#line` + `-g` foundation first, unconditionally.** Emit `#line <n> "<file>.titan"` into the generated C and add `-g` to `driver.CFLAGS`. This is orthogonal to *which* unwinder you pick, has **zero ABI impact**, and is the prerequisite that makes a native trace report `.titan` files/lines at all (verified empirically on this box: a `#line` directive produces `foo.titan:42` rows in `.debug_line` at `-O2 -g`, GCC 16.1.1 / DWARF5). It also gives you `.titan` source in gdb and core dumps for free.

2. **Primary recommendation: Option 1 (libbacktrace), reframed as "error-path-only," as an incremental upgrade of your existing handler.** It is the only single dependency that does *both* stack unwinding *and* inline-aware DWARF symbolization, it preserves Titan's defining advantage (the fast path stays a bare C call with zero instrumentation), and the Lua-5.5 message-handler-runs-before-unwind fact means the full native stack *and* the Lua `CallInfo` chain are both live when you capture — so there is **nothing to unwind/reset**, which neatly dissolves the very worry you flagged about Option 2.

3. **But pure Option 1 has three real, gating risks** — (a) symbolizing PCs inside dlopened `.so` modules (Titan's primary artifact), (b) `-O2` tail-call elision silently dropping Titan frames, (c) vendoring + macOS `dsymutil`. Resolve (a) with a spike *before* committing.

4. **The honest nuance the original notes got backwards:** on the *portability* and *correctness-under-optimization* axes, the shadow stack (Option 2) is actually the *stronger* of the two (pure C, no DWARF/`-g`/object-format/`.so` dependency; records frames regardless of inlining/tail-calls). libbacktrace wins on *features* (free precise lines, inline frames, gdb) and on *cost model* (zero happy-path overhead). The decisive factor for Titan is your stated goal of **traces on by default** on a **performance-focused** language — and notably, even Pallene (the closest sibling) makes its shadow stack *opt-in / compiled-out in release*. That's strong evidence you cannot have shadow-stack tracing on-by-default without conceding the speed story, which tips me to Option 1.

---

## 1. The core technical pivot

Three facts, all verified against source, determine everything:

**(a) A plain Lua traceback cannot see Titan at all.** Titan→Titan fast-path calls compile to ordinary C calls `f(L, _mod, _fn, args…)` with no `lua_call`, no `CallInfo` pushed (`coder.lua:1958-1985`; `doc/implementation/codegen-overview.md:216-231`). `lua_getstack` only walks the `ci->previous` chain and only sees Lua closures + C functions entered via `luaD_call` (`ldebug.c:162-176`; `isLua` = `!(callstatus & CIST_C)`, `lstate.h:270,233`). **The Lua-visible footprint of an arbitrarily deep Titan call tree is exactly one `[C]` `CallInfo` — the entry wrapper — reported with no line number.** Both options exist solely to fill that gap.

**(b) The message handler runs *before* the stack unwinds, on the intact stack.** `luaG_errormsg` (`ldebug.c:840-847`) calls `luaD_callnoyield(handler)` and only *then* does `luaD_throw` longjmp (`ldo.c:125-147`). So at capture time **both** the full native C stack **and** the full Lua `CallInfo` chain are live and consistent. This is the single most important enabling fact: it means a one-shot capture in the handler needs no shadow bookkeeping, and a shadow stack (if you had one) would be perfectly consistent there too.

**(c) Exactly one (innermost) handler runs per error, into a single registry slot.** Each entry wrapper installs its own `errorhandler` as `L->errfunc` (`coder.lua:4013-4015`, restored `coder.lua:3978`); `luaG_errormsg` runs one handler and the trace is stored under one fixed key `TITAN_BACKTRACE_KEY` (`titan.h:50`), overwriting any prior. There is no per-frame accumulation — whatever you want in the unified trace must be assembled in that one invocation.

**What exists today:** the handler (`titan-runtime/titan.c:119-142`) concatenates `tostring(err)` + `luaL_traceback()` (Lua side) + glibc `backtrace()`/`backtrace_symbols()` (`execinfo.h`, native side) into that registry slot; `titan.backtrace()` reads it (`titanlib.c:6-9`). Errors are raised with `luaL_error` (`coder.lua:191-198`); there is no internal `pcall`. **`execinfo` gives no line numbers and is glibc-only — so today the runtime does not even build on musl/Alpine** (`titan.c:5` hard-includes `execinfo.h`), and the native portion of the trace is mangled C symbols, not Titan. Option 1 is the natural, incremental evolution of *this exact code path*.

---

## 2. Option 1 — libbacktrace (native unwind + DWARF), error-path-only

**How it would work.** Vendor libbacktrace (BSD-3) into `titan-runtime/`, build it like `titan.o`. Call `backtrace_create_state(...)` once during `_init` (idempotent — fits the existing `<mangled>_init` pattern). In the existing handler, call `backtrace_full(state, skip, cb, …)`: the callback receives `(pc, filename, lineno, function)` per frame. Because the generated C carries `#line` directives, the `filename`/`lineno` libbacktrace hands you **are the `.titan` values** — no post-processing. Build the merged string, store in the registry exactly as today.

**Reconciliation (merge with Lua frames).** `backtrace_full` returns *all* C frames — `luaV_execute`, `luaD_*`, Titan runtime, and user Titan functions, interleaved. To produce one clean intermingled trace: classify each frame by its (now `.titan`-attributed) DWARF filename — show `*.titan` frames, collapse `lua-5.5.0/src/*` into a `[Lua]` marker, hide runtime frames — and correlate the runs of `luaV_execute` against the live `L->ci` chain (via `lua_getinfo`) to substitute real Lua `source:line` for pure-Lua callers/callees. **Titan-specific de-risk:** because Titan *generates* the C, the entry wrappers can emit unmistakable sentinel function names (e.g. `__titan_boundary_<mangled>`) that the merge keys on, instead of fragile filename-suffix heuristics. You own the markers.

**Strengths**
- Free, precise, **inline-aware** `.titan` lines from DWARF; `#line` makes gdb and core dumps work too. Most valuable datum (exact fault line) is automatic.
- The only single dependency doing *both* unwind and DWARF file/line/inline symbolization. (libunwind / `_Unwind_Backtrace` only do the easy half — you'd hand-write a DWARF5 line-state-machine + inline walker. Strictly more work, no gain.)
- **Zero happy-path cost** — the fast path stays a bare C call. Right cost model for an AOT language: errors are rare, pay only when one fires.
- **No unwind-consistency problem at all** — capture happens before the longjmp; the C stack then unwinds itself. (This is precisely the Option-2 worry you raised, eliminated.)
- Incremental: it's the same architectural slot as today's `execinfo` call, just a better backtracer. Fixes the musl build gap as a side effect (libbacktrace is the right backtracer where `execinfo` is absent).

**Weaknesses / risks**
- **`.so` symbolization (gating).** Titan modules are dlopened shared libraries. `backtrace_create_state(NULL)` targets the main program; reliably symbolizing PCs across *multiple* dlopened `.so`s is the **largest unaddressed risk** — may need per-`.so` states keyed by load address. **Spike this first; it's go/no-go.**
- **`-O2` tail-call elision** removes tail-called Titan frames from the stack *and* from DWARF — no pure unwinder can recover them (inlined frames *are* recovered; tail-called are gone). Fix: `-fno-optimize-sibling-calls` on generated C (a real perf cost to name), accept the loss, or record frames with a shadow stack.
- **Not a system library** — must vendor (verified absent on this Fedora box despite GCC 16.1.1). Adds build-system surface + upstream tracking (incl. the DWARF5 line-table fixes).
- macOS needs a post-link `dsymutil` step or it finds no debug info.
- Requires shipping `-g` (binary size; or split `.debug`). Stripped → PC-only fallback.
- (Non-issue, to correct the notes: async-signal-safety / the `dl_iterate_phdr` warm-up is **irrelevant** here — you only ever call from the error handler, in normal context, not a signal handler.)

---

## 3. Option 2 — shadow stack (pallene-tracer style)

**How pallene-tracer does it (verified from source).** A `malloc`'d array of frames lives inside a Lua *full userdata* in the registry, per-`lua_State`, shared across modules (`__gc` frees it; `MAX_CALLSTACK = 100000`). Each frame = a tag (C vs Lua) + a line + a name/file (or a `lua_CFunction` pointer for Lua-interface frames). Generated functions use macros: `FRAMEENTER` (push), `SETLINE(__LINE__+1)` before each failing op, `FRAMEEXIT` (pop). The traceback walks Lua levels and, on each C frame, matches `lua_tocfunction` against the nearest recorded Lua/"black" frame to interleave the explicitly-recorded Titan frames between Lua activations. **Unwinding on error** is handled with a Lua 5.4 *to-be-closed* (`__close`) finalizer: when `lua_error` longjmps past the skipped `FRAMEEXIT`s, the finalizer truncates the shadow stack back to the enclosing Lua frame. The whole thing is gated by `PT_DEBUG`; **in release the macros compile to nothing (zero cost).**

**Strengths**
- **Robust, explicit frame identity and ordering** — boundaries are recorded, not inferred. The merge is cleaner than Option 1's filtering.
- **Records frames regardless of `-O2` inlining/tail-calls** — strictly more *correct* under optimization than any pure unwinder.
- **Pure portable C** — no DWARF, no `-g`, no object-format dependency, no `.so`-symbolization problem, no `dsymutil`. Works identically on glibc/musl/macOS/Windows. (This is the axis the original notes assumed favored libbacktrace; it actually favors the shadow stack.)
- Self-contained: no vendored third-party library.

**Weaknesses / risks**
- **Happy-path tax on every call** (and every statement, for `SETLINE`). For a language whose selling point is native-speed calls, instrumenting *all* code to support a *rare* event is the wrong default. Tellingly, **Pallene itself compiles it out in release** — i.e. the closest sibling does *not* run it on-by-default, which conflicts directly with your "collect by default" goal.
- **Manual line tracking** (`SETLINE`) — maintenance burden + per-statement cost; *unless* you delegate lines to `#line`/DWARF (→ the hybrid in §5).
- **Unwind-reset complexity** — exactly the "unwinding this stack on error is an issue" you flagged. Needs the to-be-closed dance (or, once Titan has `catch`/`finally`, a depth save/restore at catch sites + a tbc at the Lua boundary for errors that escape all Titan catches to a Lua `pcall`).
- Fixed 100k cap; degrades on overflow.
- Coroutine correctness: must be per-`lua_State` (registry/extraspace), as pallene-tracer does — **not** thread-local.

---

## 4. Head-to-head

| Axis | Option 1 — libbacktrace (error-path) | Option 2 — shadow stack |
|---|---|---|
| Happy-path cost | **None** (bare C call preserved) | Per-call + per-statement (compiled out only if opt-in) |
| "On by default" + fast | **Yes, free** | Conflicts (Pallene makes it release-off) |
| Line numbers | **Free, precise, inline-aware** (DWARF) | Manual `SETLINE` (or borrow `#line`) |
| gdb / core dumps | **Free** (via `#line`+`-g`) | No |
| Frame identity / merge | Filter + Titan-emitted sentinels | **Explicit, robust** |
| Correct under `-O2` | Loses **tail-called** frames | **Records all frames** |
| Unwind-on-error | **Nothing to reset** (capture pre-unwind) | Needs tbc / catch-depth reset |
| Portability | `.so` symbolization risk; macOS `dsymutil`; needs `-g` | **Pure C, runs anywhere** |
| Dependency / build | Vendor libbacktrace + track upstream | **Self-contained** |
| Relation to current code | **Incremental upgrade** of the existing handler | New architecture |

**Decision drivers, ranked for Titan:** (1) on-by-default + native speed → Option 1. (2) Build/portability simplicity & optimization-correctness → Option 2. (3) Merge robustness → slight Option 2, but Titan-controlled sentinels close it. Your stated priorities (default-on, fast) put (1) first, so **Option 1 wins** — provided the `.so` spike passes.

---

## 5. Third option / refinement: the `#line` foundation + a slim hybrid fallback

The agents surfaced one genuinely-overlooked point and one good fallback:

- **`#line` + `-g` is not really a competing option — it's a mandatory, orthogonal *foundation* that both options need** (Option 1 to produce `.titan` lines at all; Option 2 to *avoid* hand-written `SETLINE`). It's the highest-leverage, lowest-cost, zero-ABI change. Adopt it regardless. *Caveat:* emit `#line` respecting the coder's `(stats, expr)` structure and the "operands aren't auto-hoisted" gotcha, so a directive doesn't misattribute a multiply-spliced operand.

- **Slim hybrid (fallback if the `.so` spike fails or vendoring is unacceptable):** a *name-only* shadow stack (push a `const char*` + PC, **no line** — lines come from DWARF) purely for frame identity/ordering and tail-call survival, plus `#line`/`-g` for lines. This is strictly better than pure pallene-tracer (no manual `SETLINE`, free gdb) and fixes Option 1's two soft spots (merge fragility, tail-call loss). Cost: it re-introduces the happy-path tax and the unwind-reset, so keep it as a *toggleable* mode, not the default.

Rejected outright: routing every Titan call through a real `CallInfo` (destroys the fast path and forces you to synthesize fake `Proto`+`savedpc` line bookkeeping in compiled code); and libunwind/`_Unwind` + a hand-rolled DWARF symbolizer (more work than libbacktrace for the same result).

---

## 6. Recommended plan (staged)

- **Phase 0 — foundation (do now, low risk, no ABI change).** Emit `#line` in `coder.lua`; add `-g` to `driver.CFLAGS` (`driver.lua:18` — note it's one string feeding *all* artifacts, so decide release strip/`.debug` policy). `#ifdef`-guard `execinfo` so the runtime builds on musl. This alone gives `.titan` source in gdb and core dumps immediately.
- **Phase 1 — Option 1.** **Spike `.so`/dlopen symbolization first (go/no-go).** Then vendor libbacktrace, create the state in `_init`, replace the `execinfo` call in `titan.c:119-142` with `backtrace_full`, and implement the merge (filename classify + sentinel wrappers + `L->ci`/`lua_getinfo` correlation). Decide tail-call policy (`-fno-optimize-sibling-calls` vs documented loss). Add the macOS `dsymutil` step to the driver if macOS is a target.
- **Phase 2 — only if measurement demands it.** Add the slim name-only shadow stack as a toggleable mode for tail-call-heavy code / maximally-robust traces.

---

## 7. Interaction with the `catch` / `finally` / `raise` language design

The trace-collection mechanism is **orthogonal** to the language semantics, and Option 1 composes especially cleanly:

- `raise <exp>` → `lua_error`/`luaL_error` → `luaG_errormsg` → the installed handler. The handler **checks the registry slot first**: if empty, build the merged trace (libbacktrace + `CallInfo`) and store; if already filled, leave it. This directly implements your "don't regenerate if the slot is already filled" rule.
- `catch` copies the slot into the implicit `traceback: string` local and the error object into `error: value`, then **clears the slot** (so a later fresh `raise` regenerates).
- bare `raise` (re-raise) writes the saved `traceback` back into the slot and re-raises the `error` value; the handler sees the slot filled and preserves the original deeper trace. Exactly your spec.
- **The "unwinding the shadow stack on error is an issue" concern only exists for Option 2.** With Option 1 there is no shadow stack — the trace is captured before unwind and the C stack unwinds itself, so `catch`/`finally` need no trace-stack bookkeeping at all. If you ever adopt the slim hybrid, *then* `catch` becomes the natural depth save/restore site (plus a tbc at the Lua boundary for errors that escape all Titan catches).

(Per CLAUDE.md, whichever path is implemented must land with both manual chapters — `doc/language/error-handling.md` is currently a stub saying Titan has no error construct, and a new `doc/implementation/error-handling.md` for the handler/trace internals.)
