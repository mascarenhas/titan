# Deterministic negative C-probe caching

Status: the exact pre-#108 cache identity and hot lookup order are restored,
deterministic rejections are persisted under those existing keys, and the
isolated stdlib A/B profile plus the complete Titan test gate are green. The
language-server consumer, actual-repository benchmark, and responsiveness
checks are complete; PR and CI delivery remain active.

Scope authority: [Titan issue #108](https://github.com/mascarenhas/titan/issues/108)

Branch: `codex/negative-c-probe-cache`, initially stacked on the compiler
prerequisite in PR #109. Retarget to `master` after that prerequisite lands.

## Objective

Make completed C-probe answers reusable across resolver contexts and compiler
processes regardless of whether the configured compiler accepted or rejected a
semantic candidate. Preserve infrastructure failures as retryable failures,
measure the physical compiler wall time avoided, and keep Titan at semantic
version `0.6.0`, library path `0.6`, and ABI `2`.

Prior motivation: the warm Titan-repository baseline issued 1,085 persistent
lookups. Its success-only cache hit 337 and missed 748 candidate requests; the
fresh trace-level run hit 10 and missed 1,075 after rebuilding the isolated
toolchain.
The first #108 implementation eliminated warm C-compiler launches, but made
Titan-repository indexing slower by deriving a new source digest and reading a
structured result before the original in-memory fast path. The revised design
therefore leaves the successful cache and its key untouched and adds only a
negative sibling record.

## Semantic and safety invariants

- Persist every completed semantic probe result under that exact probe
  invocation's established source/key identity, not arbitrary nonzero compiler
  executions. A rejected declaration-compatibility batch is reusable evidence
  only that at least one member failed; consume that exact aggregate evidence
  by bisection, and assign an individual rejected verdict only at a rejected
  singleton.
- Cache only completed `success` and deterministic `compiler_rejection`
  results. Spawn failure, exit 126/127, signals, cancellation, runner errors,
  malformed or contradictory runner results, header instability, workspace
  I/O, and cleanup failures remain infrastructure and are never published as a
  semantic negative.
- Baseline success may be cached. A rejected/broken header baseline remains
  infrastructure for candidate probes and is not a persistent negative.
- Preserve exact accepted/rejected diagnostics and public result shapes across
  service-local, analysis-local, and persistent reuse. Successful persistent
  hits remain diagnostic-free empty markers; negative records retain only the
  stable bounded diagnostic required to reconstruct a rejection.
- Preserve the exact pre-#108 identity. The toolchain key length-prefixes the
  parsed compiler argv, compile flags, language mode and flag, CPP/C flags,
  ordered include flags and paths, target-profile identity, compile mode, and
  forced-header manifest. The version-2 header context includes `source_dir`,
  the forced-header manifest, and each ordered descriptor's original, resolved,
  kind, name, rendered spelling, and dependency/search kind, path, identity,
  and restat flag. The
  version-3 persistent digest covers `persistent_success_version = 3`, that
  toolchain key, the forced-header manifest, the semantic key, and the complete
  probe C source.
- Do not add speculative partitions beyond that established identity.
  `TITAN_PROBE_CACHE_IDENTITY` remains the caller's optional extra namespace.
  This unchanged key is a practical optimization boundary rather than a
  complete model of C compiler state; final generated-C compilation remains the
  authoritative correctness check.
- Preserve the original hot order: consult service-local and analysis-local
  tables by the raw semantic key before rendering or hashing a full probe
  source. Derive the version-3 persistent digest only after a memory miss.
  Positive hits check the existing empty `.success` marker first; only its miss
  can require reading a `.negative` record.
- Outside an explicit analysis, validate/hash the forced-header snapshot once
  per service and the deduplicated ordinary-header snapshot once per module
  context. Repeated probes and persistent hits perform no further header work.
  Inside `process_analysis`, perform zero probe-local restats because the
  compiler client owns the coherent snapshot and publication boundary. Do not
  add a post-invocation restat; a header change which races one compiler call is
  deliberately outside this approximate optimization boundary.
- Existing positive publication keeps its empty `.success` marker behavior.
  Negative publication uses the compiler I/O strategy's atomic
  sibling-write/rename primitive. Missing, old, truncated, corrupt,
  incompatible, or key-swapped negative records fail open as misses.
- Within one service/analysis, the first completed semantic result is
  authoritative. A lookup must recheck in-memory authority after any yielding
  negative-record read. Independent processes may race complete-file
  replacements without locks; ordinary deterministic runs produce the same
  payload, and replacement remains whole.
  Failed writes accept only an already-present byte-equivalent result.
- Bounded persistent reads use the optional `read_file(path, max_bytes)` I/O
  strategy form, which returns at most one byte past the limit. The unbounded
  one-argument form remains the ordinary compiler contract.
- One explicit compiler analysis may reuse semantic results across its
  short-lived resolver contexts. Separate analyses do not share mutable result
  tables; persistent records remain the only cross-analysis/process authority.
- Observability callbacks are bounded scalar data, protected from exceptions,
  disabled unless requested, and never write to stdout.
- Declaration batching may reduce launches but must not duplicate physical
  child wall time across logical members in telemetry.

## Workstream A: analysis-local result authority

- [x] Broaden `cdriver.new_process_analysis()` from completed-header reuse to a
  complete C-analysis authority without changing its public name.
- [x] Add a validating accessor which partitions probe baseline/result caches
  by compiler I/O provider and semantic toolchain identity.
- [x] Keep service-local lookup state for tier/repetition telemetry while
  consulting and publishing the shared analysis authority.
- [x] Restore raw semantic keys as the first service/analysis lookup and carry
  the persistent digest as result metadata rather than deriving it before every
  memory hit.
- [x] Share only completed semantic success/rejection results; never share an
  infrastructure failure across resolver contexts.
- [x] Cover same service, two services in one analysis, separate analyses,
  provider isolation, and toolchain isolation.

## Workstream B: persistent negative-result records

- [x] Restore the exact pre-#108 toolchain, version-2 header-context, and
  version-3 persistent digest construction without adding or removing fields.
- [x] Preserve empty `<digest>.success` markers as the diagnostic-free positive
  fast path, and store deterministic compiler rejection in a bounded,
  checksummed `<digest>.negative` sibling using the same digest.
- [x] Memoize non-analysis header validation at service/context scope and prove
  repeated probes do not restat or rehash; prove an explicit analysis performs
  zero probe-local restats.
- [x] Leave existing `.success` markers in place without migration or deletion.
- [x] Centralize service -> analysis -> persistent lookup and publication for
  pointer, operator, and declaration-compatibility results, including exact
  batch execution evidence.
- [x] Preserve declaration batching: accepted batches retain their existing
  batch success marker, while every rejected batch/sub-batch/singleton stores
  its negative under that exact historical batch source/key. A cached aggregate
  rejection only re-enters bisection and is never assigned to its leaves.
- [x] Store sufficient bounded result data to reconstruct the exact public
  semantic answer and rejection diagnostic without retaining temporary paths,
  argv, commands, or full generated sources in persistent records.
- [x] Fail open on publication/read corruption and leave the computed semantic
  verdict unchanged when cache publication fails.
- [x] Bound persistent reads through optional `read_file(path, max_bytes)` and
  cover a replacement which grows between stat and read.
- [x] Preserve first-winner analysis authority across yielding lookups and
  negative publishers while allowing equal concurrent durable publication.

## Workstream C: runner classification and trace lifecycle

- [x] Normalize runner results strictly: normal numeric exit 0 is success;
  normal candidate exit other than 126/127 is compiler rejection; every other
  shape is infrastructure. Reject missing/NaN/nonintegral status and
  contradictory `ok`, `status`, `started`, or signal fields.
- [x] Propagate an optional finite nonnegative `wall_ms` supplied by the I/O
  strategy. CPU time is not a substitute for compiler child wall time.
- [x] Emit one logical terminal event per semantic request with requesting
  module, semantic-key digest, probe kind, header identity, outcome, cache tier
  (`service`, `analysis`, `persistent`, or `compiler`), and repeat status.
- [x] Emit one physical terminal event per compiler launch with execution-key
  digest, single/batch kind, header identity, outcome, persistent lookup and
  publication result, and child wall time.
- [x] Keep the existing lookup-only callback backward-compatible until its
  consumers move to the complete streams.
- [x] Cover callback failure isolation, publication failure visibility,
  repeated-key counting, and one-time batch wall attribution.

## Workstream D: language-server measurement consumer

- [x] Create a separate vscode-titan follow-up branch after PR #34 and pin the
  exact #108 compiler commit for CI.
- [x] Measure high-resolution monotonic wall time around async child spawn/wait
  in `CompilerIO:run` and return it through the existing Lua result table.
- [x] Normalize both logical and physical probe trace streams at the compiler
  bridge boundary without retaining sources or commands.
- [x] Extend the benchmark schema and unit tests with unique/repeated keys by
  outcome/tier, publication failures, physical launches, and child wall by
  requesting module/header.
- [x] Capture clean-fill and warm Titan-repository runs and verify ready hover,
  source-import definition, unchanged-request responsiveness, diagnostics, and
  one indexing pass.

## Required invalidation and failure regressions

- [x] Parsed compiler argv/flags, include roots, forced-header manifest,
  source directory, ordered header descriptors and header/search identities,
  target profile, compile mode, probe kind/declaration, semantic key, and exact
  source changes partition the unchanged version-3 digest as they did before
  #108.
- [x] Cross-process-style deterministic negative pointer, operator, and
  declaration results reuse without invoking the runner.
- [x] Regrouping/reordering a declaration batch never treats a cached aggregate
  rejection as all-negative. Each grouping has its own exact key; only a
  rejected singleton supplies an individual negative verdict.
- [x] Spawn failure, 126/127, signal, interruption, runner exception,
  malformed/contradictory result, write failure, cleanup failure, and a failed
  initial snapshot validation publish no negative record and retry later.
- [x] A header change after the service/context snapshot, including one racing
  a physical compiler invocation, triggers no probe-local restat; final
  generated-C compilation remains authoritative.
- [x] Corrupt/truncated/unknown/swapped negative records miss safely and a later
  valid run atomically replaces them; existing empty success markers remain
  presence-only authority.
- [x] Same-analysis lookup/publication interleavings retain the first completed
  result, avoid duplicate compilation after a yielding persistent lookup, and
  keep module attribution on the requesting Task.
- [x] A repeated clean `titan.uv` run proves every unchanged positive probe
  still takes the original marker/memory fast path and deterministic rejected
  discovery candidates launch no compiler.

## Measured stdlib A/B profile

An isolated build of all 18 standard-library roots compared historical
`f707216f` with the candidate using separate output/cache prefixes,
`TITAN_JOBS=1`, and `CCACHE_DISABLE=1`.

| Run | Historical | Candidate | Delta |
| --- | ---: | ---: | ---: |
| Clean fill | 256.03 s | 256.89 s | +0.86 s (+0.34%) |
| Warm reuse | 244.16 s | 211.27 s | -32.89 s (-13.5%) |

The clean candidate populated 244 `.success` markers and 748 `.negative`
records totaling 910,462 bytes. On warm reuse, system CPU fell from 16.94 s
to 4.06 s, consistent with avoiding the 748 deterministic rejected-probe
subprocesses. Warm peak RSS was 1,278,164 KiB versus 1,248,584 KiB.

The focused C-probe/compiler integration gate passed 559 tests. The canonical
isolated `make -j4 test` gate then passed all four compiler shards and all 197
standard-library tests with `CCACHE_DISABLE=1`.

## Verification and delivery

1. Run focused `cprobe`, `cdriver`, driver, and affected checker specs from the
   worktree with persistent-cache isolation.
2. Run the owning compiler shards and canonical isolated four-way `make test`;
   run `git diff --check` and verify `0.6.0` / `0.6` / ABI `2`.
3. Rebuild vscode-titan's isolated toolchain/server, run its complete gate, and
   produce clean-fill plus warm actual-usage benchmark artifacts with SHA-256.
4. Report wall time, server CPU, peak RSS, cache hit/miss and publication
   counts, unique/repeated keys by outcome, compiler launches, avoided launches,
   and physical child wall by module/header. Quantify the former 748 warm
   candidate misses directly.
5. Commit exact paths, push both separate branches, open/update linked PRs,
   move #108 to In review, and verify ordinary Ubuntu/Codecov/sanitizer CI.
   Do not dispatch the macOS-only job unless explicitly requested.
