# Standard-library boundary-test review

**Scope.** Maintainer review of all 26 current `it` blocks in the eight files
listed below. This is an inventory and reduction proposal, not an implementation
plan. “Unique oracle” means what the current case observes that a normal native
Titan assertion does not; fixture existence and historical cost are not treated
as reasons to keep a Busted case.

## Accepted maintainer disposition

The maintainer rejected the proposed retained Busted set after the numbered
review. The implemented disposition is:

- **1–8:** delete the coroutine generated-C, object/symbol, FFI, and injected
  implementation checks; existing compiler and native harness coverage owns
  those mechanics.
- **9–10:** preserve the observable Lua-host coroutine GC and API-error behavior
  in `coroutine.tests` native tests.
- **11:** delete the redundant standalone-import case; the unified native test
  executable already uses that configuration.
- **12:** fold late `os.stdout` lookup into the existing native `io.print` test.
- **13–17:** delete the `_loadlibglobal` implementation/cache variants; existing
  compiler, packaging, installer, and native loader coverage remains
  authoritative.
- **18:** migrate parent-stdin startup behavior to an `os.process_tests`
  standalone fixture.
- **19:** migrate the public process contract into three named native tests.
- **20:** delete the LPegLabel private-engine isolation implementation check;
  existing native behavior and build ownership is sufficient.
- **21:** migrate the TLS/HTTP sanitizer composition to a fresh standalone
  fixture selected through the native runner.
- **22–26:** migrate all parent-stdio cases to the compiled Titan parent. The
  parent links the narrow descriptor probe, prepares descriptors before each
  standalone child starts, launches that child through C99 `system`, waits for
  its Runtime teardown, checks post-teardown descriptors, reads an explicit
  temporary result file, and removes the result with `defer`.

The final layout therefore has **zero** standard-library boundary specs, zero
Lua files below `spec/stdlib/`, and one 22-root native executable. The original
analysis below is retained as the input to that maintainer decision, not as the
current implementation recommendation.

## Original executive summary

The current count overstates the amount of irreducible boundary coverage. It
mixes four different layers:

1. **Generated-C/build/ABI shape** — chiefly coroutine source/header/symbol
   scans. These are legitimate host-side assertions, but four separate cases
   inspect one transfer implementation and should become one focused shape gate
   (with archive-symbol assertions folded into an existing build spec).
2. **Loader/provider behavior** — `_loadlibglobal`, cross-engine LPegLabel
   isolation, and exact-provider coroutine load order. These genuinely need
   constructed DSOs, Lua, or independent states and should remain host-side.
3. **C/host interposition** — the inaccessible coroutine fault/GC windows and
   physical parent-descriptor classifications. These are the strongest reasons
   to retain Busted cases.
4. **Public standard-library behavior** — `io.print`, process streams and
   signals, ordinary Lua coroutine calls, and most TLS/HTTP assertions. These
   are already substantially covered by the native Titan suite and the
   production smokes; the remaining deltas can be expressed as native Titan
   tests that spawn a bounded child when a fresh process is part of the public
   contract.

### Recommendation totals for the 26 current `it` blocks

| Recommendation | Current cases | Meaning |
| --- | ---: | --- |
| **KEEP** | 8 | A distinct host/interposition/provider oracle remains. |
| **CONSOLIDATE** | 11 | Preserve the distinct part, but not as this standalone `it`. |
| **MIGRATE** | 6 | Move the worthwhile public behavior to native Titan coverage, then remove the Busted case. |
| **DELETE** | 1 | No distinct oracle remains after existing coverage is considered. |
| **Total** | **26** | |

### Proposed minimal retained set

The minimum practical set is **12 logical Busted gates**, of which **11 remain
in the boundary-file group** and one moves to `spec/lpeglabel_build_spec.lua`:

| Area | Retained gates | Count |
| --- | --- | ---: |
| Coroutine | one generated-transfer shape gate; injected `lua_checkstack` failure; two-order canonical-module matrix; injected transfer-window GC | 4 |
| `_loadlibglobal` | promotion/local-cache matrix; lazy mapping; error/canonical-path behavior; two-`lua_State` cache isolation | 4 |
| LPegLabel | private/external engine load-order and state isolation, colocated with the private archive build | 1 |
| Parent stdio | prepared-pipe facade/inheritance matrix; PTY path; unsupported file/socket matrix | 3 |
| **Total** | | **12** |

That removes the dedicated Busted public-behavior cases for `io`, ordinary
`os` process behavior, parent-stdin facade behavior, and TLS/HTTP behavior.
The proposal does **not** remove their worthwhile assertions: they migrate to
native Titan tests, with the sanitizer case retaining a dedicated native
fresh-process CI selector. It also avoids counting the assertions folded into
an already existing build-spec `it` as a new gate.

## Review criteria

- **KEEP** only when Lua-host calls, a fresh/independent state, provider
  construction, generated-C inspection, or C/descriptor interposition is the
  thing being asserted rather than merely the way the fixture was written.
- **MIGRATE** public behavior even if its native test must launch a purpose-built
  child. A native Titan test spawning a bounded fresh process is still the
  correct owner for public standard-library behavior.
- **CONSOLIDATE** load-order/type matrices that need separate child processes
  but do not need separate `it` blocks, and move archive/symbol assertions to
  the root spec that already owns that artifact.
- Absence of ASan/UBSan diagnostics is a real oracle only in a sanitizer job;
  it does not turn all duplicated protocol assertions into separate Busted
  behavior coverage.

## Per-case inventory

### `spec/coroutine_runtime_boundary_spec.lua` — 11 cases

The suite setup source-rewrites and builds an exact `titan.coroutine` provider
while preserving/restoring shared root artifacts. That invasive setup is
justified for the two inaccessible fault windows, but not for every public API
smoke currently sharing the file.

#### 1. `"keeps minicoro runtime state in GC-owned module-local storage"`

- **Exact test:** `spec/coroutine_runtime_boundary_spec.lua` — `it("keeps minicoro runtime state in GC-owned module-local storage")`.
- **Layer:** generated-C/build/ABI shape.
- **Unique oracle:** scans the generated provider, Titan source, native C, and
  public header to pin the ownership arrangement: `mco_runtime` is an owned
  object reached from the module userdata; `current_co` is reached through its
  payload; the coroutine owner count is loaded and range-checked before native
  allocation; the old registry/upvalue/configuration machinery and retired
  transfer helpers are absent; and the public header exposes only the narrow
  `mco_coro` forward declaration/entry wiring rather than Titan-owned layout
  constants.
- **Concrete boundary:** **generated-C inspection** plus native source/header
  inspection and an **exact transformed provider build**. A native behavior
  test cannot prove where state lives or that symbols/registry keys are absent.
- **Native overlap:** native coroutine lifecycle and GC cases prove that the
  implementation works, especially
  `test_roots_nested_stacked_payloads_and_tags_across_gc`; `spec/minicoro_spec.lua`
  proves the underlying runtime behavior. Neither proves module-local storage
  or the negative ABI surface.
- **Recommendation: CONSOLIDATE.** Keep the ownership assertions in one
  “generated coroutine transfer/ownership shape” case with cases 2 and 5.
  Move archive/header export-set assertions shared with case 4 into the build
  spec that owns `libtitan.a`. Do not retain this broad, standalone inventory
  of historical spellings.

#### 2. `"roots transfers through checked public Lua uservalue APIs"`

- **Exact test:** `spec/coroutine_runtime_boundary_spec.lua` — `it("roots transfers through checked public Lua uservalue APIs")`.
- **Layer:** generated-C implementation shape.
- **Unique oracle:** within generated `root_transfer`, proves the exact order
  owner recovery → C-stack anchoring → saved Lua top → checked count conversion
  → `lua_checkstack` → owner/payload pushes → checked
  `lua_setiuservalue` → one exact top restore, and proves there is no direct
  `Udata.uv` write or handwritten GC barrier.
- **Concrete boundary:** **generated-C inspection** is the oracle. Ordinary
  success cannot distinguish public Lua API use from a direct internal write.
- **Native overlap:** the native coroutine GC cases cover values surviving
  transfers, while current case 3 checks the failing `lua_checkstack` path and
  case 8 checks GC in the otherwise inaccessible transfer window. They do not
  prove this exact lowering/API choice.
- **Recommendation: CONSOLIDATE.** Retain the few architectural invariants in
  the single generated-transfer shape case; do not keep a second textual-order
  `it` for the same helper.

#### 3. `"restores the exact top and pushes nothing on checkstack failure"`

- **Exact test:** `spec/coroutine_runtime_boundary_spec.lua` — `it("restores the exact top and pushes nothing on checkstack failure")`.
- **Layer:** interposed failure-path semantics.
- **Unique oracle:** forces the one `lua_checkstack` call after the saved top to
  fail, verifies the exact error, asks the C fixture to prove that no value was
  pushed and the exact top was restored, and then proves the same coroutine is
  still suspended and can resume successfully.
- **Concrete boundary:** a second **source-rewritten exact provider**, linked
  **C interposition/fault injection**, and a **fresh Lua process**. The public
  API has no way to force this native allocation failure at the required point.
- **Native overlap:** lifecycle tests prove normal suspension/resumption and
  error propagation, but no native case can inject this `lua_checkstack`
  failure.
- **Recommendation: KEEP.** This is a genuine inaccessible boundary. Keep it
  isolated so filtered sanitizer runs do not build the second provider.

#### 4. `"removes retired transfer helpers from runtime objects"`

- **Exact test:** `spec/coroutine_runtime_boundary_spec.lua` — `it("removes retired transfer helpers from runtime objects")`.
- **Layer:** runtime archive/export ABI shape.
- **Unique oracle:** `nm -g` on `titan_coro.o` and `libtitan.a` must show the
  retained `titan_coro_entry`/`titan_coro_tag_equal` wiring and must not show
  `titan_coro_root_transfer`/`titan_coro_clear_transfer`.
- **Concrete boundary:** host **object/archive symbol inspection**; Lua and the
  transformed provider are incidental.
- **Native overlap:** no native Titan behavior test can prove symbol absence.
  `spec/libuv_build_spec.lua` already owns the exact runtime archive members and
  other SDK/provider shape assertions.
- **Recommendation: CONSOLIDATE.** Fold the symbol allow/deny assertions into
  the existing runtime/archive build-shape case (or the consolidated coroutine
  shape gate). It should not pay for this suite's exact-provider setup as its
  own `it`.

#### 5. `"anchors a popped payload before clearing its transfer root"`

- **Exact test:** `spec/coroutine_runtime_boundary_spec.lua` — `it("anchors a popped payload before clearing its transfer root")`.
- **Layer:** generated-C GC-order shape.
- **Unique oracle:** in `pop_transfer_or_raise`, the second `mco_pop` of the
  `TValue` must be followed by the generated stack-anchor refresh (`setobj2t`)
  before `clear_transfer` removes the source-coroutine uservalue root.
- **Concrete boundary:** **generated-C inspection**. Normal outcomes, including
  case 8's GC before the pop, cannot place a collection in the tiny pop-to-clear
  interval and therefore cannot prove this ordering.
- **Native overlap:** native GC tests and case 8 strongly cover rooting before
  the pop, but not this post-pop anchor handoff.
- **Recommendation: CONSOLIDATE.** This is the strongest reason to keep one
  generated-transfer shape gate; fold it with cases 1 and 2 rather than
  deleting it or retaining a third textual scan.

#### 6. `"shares the canonical module when Titan imports before Lua requires"`

- **Exact test:** `spec/coroutine_runtime_boundary_spec.lua` — `it("shares the canonical module when Titan imports before Lua requires")`.
- **Layer:** provider/load-order and Lua-module identity, with some ABI-shape
  assertions mixed in.
- **Unique oracle:** preloads a compiled Titan importer, then verifies that the
  Lua shim returns the same canonical Titan module userdata and coroutine
  metatable; stock Lua's `coroutine` module remains untouched; the registry uses
  the canonical key rather than retired keys; the exact
  `luaopen_titan_coroutine` is idempotent; and unqualified legacy openers are
  absent.
- **Concrete boundary:** **compiled provider construction**, a compiled
  importer DSO, and a **fresh Lua process** with a specific load order. One Lua
  state cannot test both first-load orders.
- **Native overlap:** `coroutine/tests/lua_boundary_test.titan` checks poisoned
  and complete registry metatables, while `spec/rockspec_spec.lua` checks the
  installed shim/provider and that stock modules remain stock. Neither tests a
  compiled Titan importer winning the first load.
- **Recommendation: CONSOLIDATE.** Retain this order and case 7's reverse order
  as two child runs under one load-order matrix `it`. Move or drop the legacy
  name-absence inventory unless it is part of the explicit ABI export set.

#### 7. `"shares the canonical module when Lua requires before Titan imports"`

- **Exact test:** `spec/coroutine_runtime_boundary_spec.lua` — `it("shares the canonical module when Lua requires before Titan imports")`.
- **Layer:** provider/load-order identity.
- **Unique oracle:** loads the canonical Titan module from Lua first, then loads
  a compiled Titan importer, and proves both construction paths share the same
  module/metatable and idempotent opener without replacing stock Lua
  `coroutine`.
- **Concrete boundary:** the reverse **fresh-Lua-state load order** plus the same
  constructed exact provider/importer as case 6.
- **Native overlap:** installed-module and Lua metatable smokes cover each side
  independently, not the reverse-order identity handoff.
- **Recommendation: CONSOLIDATE.** Make cases 6 and 7 one explicit two-process
  matrix. Separate `it`s add setup/reporting surface but no third invariant.

#### 8. `"roots fresh terminal result and error transfers through pop-side GC"`

- **Exact test:** `spec/coroutine_runtime_boundary_spec.lua` — `it("roots fresh terminal result and error transfers through pop-side GC")`.
- **Layer:** interposed GC/lifetime semantics.
- **Unique oracle:** injects a full incremental collection and a generational
  step immediately after native resume, while a fresh result or error exists
  only in the transfer path. It proves the root/back barrier preserves each
  object, the exact object is returned/raised, and clearing the root later lets
  it finalize exactly once.
- **Concrete boundary:** the sole approved **source-rewrite fault window**, an
  **exact provider**, a **fresh Lua process**, weak/finalizable Lua objects, and
  (in CI) sanitizer execution. Public scheduling cannot put GC in this window.
- **Native overlap:**
  `test_roots_nested_stacked_payloads_and_tags_across_gc` covers ordinary and
  nested GC rooting but cannot collect between `mco_resume` and transfer-root
  consumption.
- **Recommendation: KEEP.** This is a distinct, high-value lifetime oracle and
  is the reason the source-rewrite exception exists.

#### 9. `"loads from Lua and roots value payloads and identity tags across GC"`

- **Exact test:** `spec/coroutine_runtime_boundary_spec.lua` — `it("loads from Lua and roots value payloads and identity tags across GC")`.
- **Layer:** public Lua-boundary behavior.
- **Unique oracle:** from a Lua caller, sends tables/functions through
  create/yield/resume across generational collection, checks metatable/object
  identity and liveness, and confirms raw numeric tag equality treats `1` and
  `1.0` as the same tag.
- **Concrete boundary:** a **fresh Lua host process** exercises coercive Lua
  entries. It does not need source rewriting or generated-C inspection.
- **Native overlap:** native
  `test_roots_nested_stacked_payloads_and_tags_across_gc`, basic tag cases, and
  `test_raw_tag_mismatch_does_not_call_lua_eq` cover most semantics from Titan.
  The remaining distinction is only the Lua entry boundary.
- **Recommendation: MIGRATE.** Add the Lua snippet to
  `coroutine/tests/lua_boundary_test.titan`, whose existing native cases already
  launch bounded independent `lua -E` processes. Then remove this Busted case
  and avoid building a special provider for ordinary Lua behavior.

#### 10. `"reports Lua call errors for bad coroutine API use"`

- **Exact test:** `spec/coroutine_runtime_boundary_spec.lua` — `it("reports Lua call errors for bad coroutine API use")`.
- **Layer:** public Lua-boundary error behavior.
- **Unique oracle:** a noncallable Lua callback fails on resume; `yield` without
  a non-nil tag reports the documented error; and `yield` outside a Titan
  coroutine reports `Invalid coroutine`.
- **Concrete boundary:** a **Lua caller** is needed to cover the dynamic
  callback entry, but no provider construction or interposition is needed.
- **Native overlap:** native lifecycle coverage already checks missing
  effective tags, dead/suspended misuse, and error propagation. Only the exact
  Lua dynamic-call surface is missing.
- **Recommendation: MIGRATE.** Put this fresh-Lua snippet beside the two
  existing native-owned Lua coroutine probes. It is public behavior, not a
  Busted implementation boundary.

#### 11. `"imports coroutine from a compiled module in a standalone executable"`

- **Exact test:** `spec/coroutine_runtime_boundary_spec.lua` — `it("imports coroutine from a compiled module in a standalone executable")`.
- **Layer:** generic compiled-provider smoke presented as public coroutine
  behavior.
- **Unique oracle:** compiles a standalone whose source imports the exact
  coroutine DSO, then checks one create/resume round trip and a zero exit.
- **Concrete boundary:** standalone **provider selection/link/load** and a fresh
  executable. There is no coroutine-specific host observation.
- **Native overlap:** the aggregate native runner is itself a standalone that
  imports and exercises coroutine; `test_creates_coroutine_and_returns_callback_result`
  covers the behavior; compiler DSO-import suites and production smokes own the
  generic compiled-module path.
- **Recommendation: DELETE.** It is redundant at both the behavior and provider
  layers. If a qualified standard-module DSO regression needs a compiler test,
  add it to the existing DSO/import provider matrix rather than retaining this
  coroutine smoke.

### `spec/io_print_host_boundary_spec.lua` — 1 case

#### 12. `"uses one atomic write to the current stdout"`

- **Exact test:** `spec/io_print_host_boundary_spec.lua` — `it("uses one atomic write to the current stdout")`.
- **Layer:** mostly public `io.print` behavior, with synthetic implementation
  instrumentation.
- **Unique oracle:** builds fake exact `titan.string` and `titan.os` providers
  to count `OutputStream:write` calls. It proves multi-value and zero-value
  prints each call `write` once, conversion failure happens before any write,
  and the exported `os.stdout` slot is read on each call rather than cached.
  The count is a Titan method-call count, not proof of one kernel/libuv write.
- **Concrete boundary:** **synthetic exact-provider construction** plus a fresh
  Lua process makes the private write counter observable. No real host stdout
  behavior requires Busted here.
- **Native overlap:** native
  `test_io_print_formats_left_to_right_and_is_atomic` already proves conversion
  order, tab/newline bytes, the empty print, conversion failure, and absence of
  a written prefix by capturing real stdout. It does not swap `os.stdout`, and
  it cannot count synthetic method calls.
- **Recommendation: MIGRATE.** Preserve only the public “uses the current
  `os.stdout`” delta in the native test, using a real `os.OutputStream` such as
  a captured child stdin and restoring the canonical slot. Drop the synthetic
  exact-call-count assertion unless a one-method-call contract is explicitly
  documented; it is implementation shape and does not justify four private
  providers.

### `spec/loadlibglobal_boundary_spec.lua` — 5 cases

These are loader tests rather than Titan library behavior. Constructed DSOs and
Lua/C hosts are the intended layer, and native Titan tests would obscure the
actual oracle.

#### 13. `"promotes a previously local image into the process symbol namespace"`

- **Exact test:** `spec/loadlibglobal_boundary_spec.lua` — `it("promotes a previously local image into the process symbol namespace")`.
- **Layer:** native loader/provider behavior.
- **Unique oracle:** opens a provider locally with `package.loadlib`, proves a
  consumer with an unresolved provider symbol cannot map, promotes the already
  mapped image through `_loadlibglobal`, and then proves the consumer resolves
  the symbol and returns `42`.
- **Concrete boundary:** two purpose-built **DSOs**, process-global dynamic
  symbol resolution, and a **fresh Lua process**. This cannot be inferred from
  Lua module identity alone.
- **Native overlap:** installed-provider and multi-module specs prove shims call
  `_loadlibglobal` and that standard modules load, but not promotion of an
  already `RTLD_LOCAL` image.
- **Recommendation: KEEP.** This is the core promotion contract. Extend it into
  the preload-origin matrix described for case 14 rather than duplicating the
  provider/consumer fixture.

#### 14. `"does not let the compiler's local cache satisfy a global request"`

- **Exact test:** `spec/loadlibglobal_boundary_spec.lua` — `it("does not let the compiler's local cache satisfy a global request")`.
- **Layer:** loader cache separation.
- **Unique oracle:** repeats the promotion proof after the provider was opened
  through compiler-only `_loadlib`, showing that its local cache neither
  answers nor suppresses `_loadlibglobal`'s separate global promotion.
- **Concrete boundary:** the same constructed **provider/consumer DSOs** and a
  fresh process, but with `_loadlib` as the local opener.
- **Native overlap:** no native standard-library test calls the compiler-only
  loader. Case 13 covers the same global result from a different local opener.
- **Recommendation: CONSOLIDATE.** Run `package.loadlib`-first and
  `_loadlib`-first as two fresh child scenarios under case 13's one promotion
  matrix. The cache-origin distinction is real; the second copy of the C
  fixture is not.

#### 15. `"maps a provider lazily when eager package loading cannot"`

- **Exact test:** `spec/loadlibglobal_boundary_spec.lua` — `it("maps a provider lazily when eager package loading cannot")`.
- **Layer:** dynamic-loader flag behavior.
- **Unique oracle:** a provider containing a deliberately unresolved function
  reference fails under eager `package.loadlib`, while `_loadlibglobal` maps it
  with lazy binding and returns its opener without invoking the unresolved
  function.
- **Concrete boundary:** a purpose-built **DSO with an unresolved relocation**
  and a fresh Lua process. Only the host dynamic loader can distinguish
  `RTLD_NOW` from `RTLD_LAZY`.
- **Native overlap:** production extensions exercise lazy/global loading when
  their dependencies are available; none proves that a dormant unresolved
  call remains map-safe.
- **Recommendation: KEEP.** This is a small, direct test of an architectural
  loader invariant.

#### 16. `"reports canonical open and symbol failure stages"`

- **Exact test:** `spec/loadlibglobal_boundary_spec.lua` — `it("reports canonical open and symbol failure stages")`.
- **Layer:** loader API diagnostics and canonical cache behavior.
- **Unique oracle:** distinguishes `open` failure for a missing image from
  `init` failure for a missing symbol, and proves relative, absolute, and bare
  spellings resolve to the same opener/one canonical handle entry.
- **Concrete boundary:** filesystem canonicalization, a constructed DSO, the
  Lua-facing support API, and a fresh process. Busted is appropriate for the
  returned tuple and path aliases.
- **Native overlap:** shim/publication specs validate generated calls and bad
  staged shims, but not this runtime failure tuple or path alias coalescing.
  Case 17 separately proves state ownership of the cache.
- **Recommendation: KEEP, but tighten.** Keep the externally meaningful stage
  and opener-equality assertions. The hard-coded private registry UUID and
  exact table contents duplicate case 17's ownership proof and can be replaced
  by behavior unless that key itself is an explicit internal ABI invariant.

#### 17. `"creates a distinct canonical cache in each independent Lua state"`

- **Exact test:** `spec/loadlibglobal_boundary_spec.lua` — `it("creates a distinct canonical cache in each independent Lua state")`.
- **Layer:** embedding/state-isolation invariant.
- **Unique oracle:** a C harness creates two `lua_State`s in one process,
  verifies loading in the first does not create registry state in the second,
  then verifies distinct registry tables but the same process-global native
  handle after both load the provider.
- **Concrete boundary:** an **independent-two-`lua_State` C harness** linked
  with `titanlib.c` and `liblua.a`. Two OS processes would not test this, and a
  normal Lua script cannot create/inspect the states.
- **Native overlap:** none. Standard semantic state tests use one Lua state;
  ordinary loader tests cannot detect a shared C-global cache.
- **Recommendation: KEEP.** This directly enforces the “semantic state lives in
  the Lua registry/GC graph, not shared C globals” invariant.

### `spec/os_parent_stdio_boundary_spec.lua` — 1 case

#### 18. `"reads binary-safe parent stdin through the stable facade"`

- **Exact test:** `spec/os_parent_stdio_boundary_spec.lua` — `it("reads binary-safe parent stdin through the stable facade")`.
- **Layer:** public `titan.os` parent-stream behavior with a startup boundary.
- **Unique oracle:** starts Lua with fd 0 already supplied by a shell pipeline,
  then checks Interface conversion, delimiter chopping, retained excess, EOF,
  and EOF after closing the borrowed parent facade. Despite the title, the
  current payload (`first|second`) contains no NUL byte; its unique part is
  pre-Lua-state parent descriptor installation, not binary data.
- **Concrete boundary:** a **fresh process whose stdin exists before Lua and
  module initialization**. That timing cannot be recreated by changing input
  inside the already-running aggregate process.
- **Native overlap:** native process/IO tests cover stream Interfaces,
  delimiter/excess behavior (including actual NUL data), close idempotence, and
  terminal EOF. The parent-fd timing is not covered in the aggregate itself.
- **Recommendation: MIGRATE.** Let a native `os.process_tests` case launch a
  small compiled/Lua child under a pipe and assert its exit/result. This keeps
  the real pre-initialization boundary while making the public behavior
  source-owned. Do not retain a Busted case merely because the native test
  needs a child process.

### `spec/os_process_host_boundary_spec.lua` — 1 case

#### 19. `"spawns, captures binary streams, waits, and kills"`

- **Exact test:** `spec/os_process_host_boundary_spec.lua` — `it("spawns, captures binary streams, waits, and kills")`.
- **Layer:** a large public `titan.os` integration matrix.
- **Unique oracle:** one Titan task currently covers all of the following:
  invalid empty/NUL executable and NUL argument rejection; exact cwd,
  environment, `argv[0]`, ordered arguments, and an empty argument; NUL-safe
  stdin/stdout echo and idempotent input close; separate stdout/stderr capture;
  normal and signal exit status plus repeated wait; rejecting kill after exit
  and invalid signal spellings without changing live state; and cancellation
  of an accepted process wait/read remaining pending until each native callback
  arrives, without killing the child, followed by a successful replacement
  wait.
- **Concrete boundary:** a purpose-built external **C child process** supplies
  reliable argv, binary stdio, readiness, exit, and signal stimuli. A fresh Lua
  process drives the canonical async DSO. The external child is essential; Lua
  and Busted are not.
- **Native overlap:**
  `test_stream_facades_capture_merge_inheritance_options_and_interfaces`
  covers capture separation/inheritance; IO process tests cover binary
  delimiter streams, repeated status, and termination; signal tests cover
  signal validation/cancellation; and `os_production_smoke.lua` already uses
  the same C child for binary echo, exit, and signal behavior in bundled,
  system, and sanitizer modes. The accepted-operation cancellation/replacement
  path and exact argv/env/cwd matrix are the clearest remaining deltas.
- **Recommendation: MIGRATE.** Split this monolith into focused native Titan
  cases (validation/argv metadata, binary/status, and accepted-operation
  cancellation). Make the existing C child a Make-owned test fixture or pass
  the already-built production-smoke child to the runner. The assertions are
  already written in Titan; Busted only compiles and launches them.

### `spec/peg_engine_isolation_boundary_spec.lua` — 1 case

#### 20. `"keeps private and external LPegLabel engines isolated"`

- **Exact test:** `spec/peg_engine_isolation_boundary_spec.lua` — `it("keeps private and external LPegLabel engines isolated")`.
- **Layer:** private native payload/provider composition, not ordinary PEG API
  behavior.
- **Unique oracle:** under both load orders, requiring `titan.peg` neither
  publishes nor replaces `package.loaded.lpeglabel`; private and external
  pattern userdata are mutually rejected; and each engine's mutable max-stack
  setting affects only its own recursive pattern.
- **Concrete boundary:** an exact Titan PEG provider carrying the private
  namespaced archive, the independently installed external Lua C module, and
  **two fresh Lua processes for opposite load orders**. This is a real
  cross-provider/symbol-state isolation boundary.
- **Native overlap:** native PEG tests thoroughly cover constructors, grammars,
  matching, stack controls, labels, and GC for the private engine.
  `spec/lpeglabel_build_spec.lua` proves the archive contains only private
  definitions. Neither alone proves coexistence with the external engine.
- **Recommendation: CONSOLIDATE.** Preserve one two-order isolation gate, but
  move it into `spec/lpeglabel_build_spec.lua`, which owns the private archive,
  namespace patch, and external upstream module. It should not masquerade as a
  second public PEG behavior suite.

### `spec/ssl_http_sanitizer_boundary_spec.lua` — 1 case

#### 21. `"cancels an idle read, then streams a fragmented HTTPS request through TLS and llhttp"`

- **Exact test:** `spec/ssl_http_sanitizer_boundary_spec.lua` — `it("cancels an idle read, then streams a fragmented HTTPS request through TLS and llhttp")`.
- **Layer:** sanitizer/lifetime composition wrapped around mostly public
  SSL/HTTP behavior.
- **Unique oracle:** in one sanitizer process, uses the module-initialized
  default client context (`SSL_CERT_FILE`), completes a verified keep-alive
  request, lets the server's idle deadline cancel/join its TLS reader, observes
  `TLS_TRUNCATED_EOF`, checks the timeout setter, then sends a second HTTPS
  request one byte at a time through llhttp and reads a binary response. Clean
  task/server shutdown and clean process exit implicitly test the default
  context finalizer; absence of ASan/UBSan diagnostics is the real extra
  oracle.
- **Concrete boundary:** a **sanitizer-instrumented fresh process** is required
  for the lifetime/finalizer oracle. The current Busted wrapper also constructs
  a fixture DSO and Lua host, but neither is necessary to express the protocol.
- **Native overlap:** native
  `test_ssl_distinguishes_truncated_transport_from_clean_eof`,
  `test_https_header_idle_timeout_protocol`,
  `test_public_verified_https_request_and_server`, the fragmented HTTP parser
  cases, and the binary TLS exchange cover every public component more deeply.
  The sanitizer job already runs focused native lifetime gates, but currently
  uses this case to compose TLS and llhttp and to reach the default-context
  process finalizer.
- **Recommendation: MIGRATE.** Keep a dedicated sanitizer selector, but make
  the case a native Titan test (or a very small native production smoke) and
  set `SSL_CERT_FILE` around that fresh runner process. Reuse existing native
  helpers/assertions and add only the default-context/finalizer delta. If Lua
  DSO loading itself is considered part of the sanitizer oracle, cover that
  with a minimal provider smoke rather than duplicating the HTTP protocol
  matrix.

### `spec/uv_process_stdio_boundary_spec.lua` — 5 cases

These cases use `uv_stdio_probe.c` to replace real fds 0/1/2, inspect flags,
read peer output, restore the descriptors, and count open descriptors. That C
probe is a real boundary; the reduction is mainly to table-drive related host
kinds rather than remove it.

#### 22. `"classifies and transfers parent pipe stdio"`

- **Exact test:** `spec/uv_process_stdio_boundary_spec.lua` — `it("classifies and transfers parent pipe stdio")`.
- **Layer:** physical host-descriptor/libuv adapter behavior.
- **Unique oracle:** replaces all three parent descriptors with real pipes,
  proves canonical parent facades classify them as non-TTY, transfers seeded
  stdin and distinct stdout/stderr bytes, keeps the host descriptors open, and
  observes the expected nonblocking flag transition.
- **Concrete boundary:** linked **C descriptor interposition**, real libuv
  handle classification, and a **fresh Lua process/Runtime** so cached parent
  handles cannot contaminate another kind.
- **Native overlap:** native process stream tests cover captured pipes and
  `is_tty`, but not replacing the host's own fds or verifying their flags and
  restoration.
- **Recommendation: KEEP.** This is the supported named-pipe branch. Fold case
  23's inheritance scenario into the same prepared-pipe matrix while retaining
  separate fresh child runs inside the `it`.

#### 23. `"inherits only prepared parent streams"`

- **Exact test:** `spec/uv_process_stdio_boundary_spec.lua` — `it("inherits only prepared parent streams")`.
- **Layer:** physical parent-descriptor spawn inheritance.
- **Unique oracle:** with all parent fds replaced by prepared pipes, spawning
  with `with_parent_*` exposes no captured child endpoints, the child exits
  normally, and the original parent fds remain open and are back in their expected
  blocking state after the spawn handoff.
- **Concrete boundary:** the same **C descriptor fixture**, real `uv_spawn`
  inheritance, flag inspection, and an independent fresh Runtime.
- **Native overlap:** native
  `test_stream_facades_capture_merge_inheritance_options_and_interfaces`
  checks that inherited streams expose no captured endpoints, but does not
  prove the physical parent fds remain open/blocking.
- **Recommendation: CONSOLIDATE.** Preserve the physical-fd delta as the second
  scenario in the prepared-pipe case. It needs a fresh child process, not a
  separate top-level `it` or another probe compilation.

#### 24. `"classifies and transfers a portable pseudo-terminal"`

- **Exact test:** `spec/uv_process_stdio_boundary_spec.lua` — `it("classifies and transfers a portable pseudo-terminal")`.
- **Layer:** physical PTY/libuv adapter behavior.
- **Unique oracle:** installs a real raw PTY slave as stdout, proves
  `os.stdout:is_tty()` is true, transfers bytes to the PTY master, keeps fd 1
  valid, and verifies the TTY path does not apply the pipe nonblocking policy.
- **Concrete boundary:** POSIX **PTY construction/C descriptor interposition**,
  libuv's TTY implementation, and a fresh state. A redirected ordinary pipe is
  not equivalent.
- **Native overlap:** native tests can observe whatever TTY status the CI
  runner happens to have, but cannot portably require a TTY or inspect its
  transfer/flag behavior.
- **Recommendation: KEEP.** This is the only deterministic supported-TTY
  branch oracle.

#### 25. `"rejects regular-file parent stdio without leaking"`

- **Exact test:** `spec/uv_process_stdio_boundary_spec.lua` — `it("rejects regular-file parent stdio without leaking")`.
- **Layer:** unsupported physical descriptor classification and cleanup.
- **Unique oracle:** after warming the Runtime, replaces stdout with a regular
  file, proves `with_parent_stdout`/spawn rejects it, and compares open-fd
  counts before/after to catch duplicate/handle leaks; the fixture also proves
  the original fd can be restored.
- **Concrete boundary:** a real regular file, `uv_guess_handle`, **C fd-count
  interposition**, and a fresh process. Public error checking alone cannot show
  a leaked duplicate.
- **Native overlap:** native spawn-option tests cover option rejection and
  cleanup generally, not this host kind or descriptor count. Case 26 runs the
  same Titan rejection/cleanup path with a different `uv_guess_handle` result.
- **Recommendation: CONSOLIDATE.** Table-drive regular-file and socket modes in
  one “rejects unsupported parent kinds without leaking” case, using a fresh
  process for each mode.

#### 26. `"rejects socket parent stdio without leaking"`

- **Exact test:** `spec/uv_process_stdio_boundary_spec.lua` — `it("rejects socket parent stdio without leaking")`.
- **Layer:** unsupported physical descriptor classification and cleanup.
- **Unique oracle:** repeats case 25 with a real socket, covering the `UV_TCP`
  classification rather than `UV_FILE`, and proves rejection leaves the open-fd
  count unchanged.
- **Concrete boundary:** socket **C descriptor interposition**, libuv
  classification, and a fresh process.
- **Native overlap:** no native public test owns a deterministic parent socket;
  all Titan-side rejection/cleanup logic is otherwise identical to case 25.
- **Recommendation: CONSOLIDATE.** Preserve the distinct host-kind row, not a
  duplicate top-level `it`.

## Suggested ownership after reduction

- Keep `spec/coroutine_runtime_boundary_spec.lua` narrowly about the generated
  transfer shape, the two inaccessible injected failure windows, and the
  exact-provider load-order identity matrix.
- Keep `spec/loadlibglobal_boundary_spec.lua` as the loader boundary owner; it
  should not become a standard-library API suite.
- Move the LPegLabel coexistence matrix beside the private archive/namespace
  build assertions in `spec/lpeglabel_build_spec.lua`.
- Keep `spec/uv_process_stdio_boundary_spec.lua` narrowly about physical host
  descriptor classes, with three table/matrix cases.
- Move Lua coroutine API snippets into
  `spec/stdlib/titan/coroutine/tests/lua_boundary_test.titan`; move print and
  process behavior into the existing `io.tests`/`os.process_tests` roots; move
  the TLS/HTTP sanitizer scenario into the native HTTP/SSL roots with a
  dedicated fresh-process sanitizer filter.
- Remove the five emptied boundary files from the boundary list only after the
  native replacements land and the Linux uncovered plus sanitizer gates select
  them explicitly.
