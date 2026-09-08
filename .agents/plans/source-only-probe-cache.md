# Source-only compiled C probe cache

Tracking: https://github.com/mascarenhas/titan/issues/149

## Intended result

Memoize each individual compiled C-FFI probe by SHA-256 of its complete raw,
unpreprocessed source. Remember both acceptance and rejection with diagnostics.
External compiler/header changes do not invalidate records: users clear the
cache or bypass persistent reuse when needed. Start at cache format 1, independent
of Titan ABI, with no old-format compatibility.

## Implementation sequence

1. Replace the probe cache codec and identity with one bounded result record and
   one source digest shared by memory and disk. Remove cache-only toolchain,
   header, forced-header, semantic, and namespace identities, including identity
   hashes hidden in generated C helper names. Preserve compiler execution,
   include resolution, diagnostic attribution, and I/O cleanup behavior.
2. Replace declaration batch rendering, bisection, and batch result publication
   with individual cached probes. Process redeclarations in source order,
   immediately forming accepted composites; delete batch-wave scheduling.
3. Update driver/analysis integration and CI cache paths to format 1. Keep
   unrelated parsed-header and compiler graph caches semantically unchanged.
4. Rewrite README, applicable language/implementation manuals, contributor
   guidance, and skills around only the new cache contract. Remove obsolete
   cache-system explanations rather than appending migration prose.
5. Update owning Lua/Busted regressions for raw-source reuse of both outcomes,
   changed external inputs with unchanged source, corrupt/bounded records,
   infrastructure retry, individual diagnostics, sequential composites, and
   enum carrier discovery. Measure representative cold/warm invocation counts.
6. Run focused validation, then canonical full local verification with an
   isolated absolute prefix and clean build-policy environment. Independently
   review implementation and documentation, resolve findings, then commit/push
   and open a PR closing #149. Track Linux CI on its final head until green.

## Scope and boundaries

- Worktree: `/tmp/titan-probe-cache-149`; branch: `agent/source-only-probe-cache`.
- Leave the existing checkout/branch and its untracked mtime plan untouched.
- No changes to C parsing/type semantics or runtime semantics beyond removing
  batching while preserving its sequential meaning.
- Cache I/O failures/malformed records are misses. Infrastructure failures are
  retryable. Completed compiler rejections are cacheable, including on disk.
- No new compiler diagnostic parser, result-vector cache, bisection fallback,
  dependency hashing, or generated-code witnesses to compensate for staleness.
- MacOS CI is explicitly waived; do not dispatch it. Linux CI must be green.

## Validation record

- Focused gates passed: 51 probe/record tests, 2 analysis-context tests, 162
  declaration/source-import tests, 20 pointer-conversion tests, 7 converted
  foreign-graph tests, 2 parser graph-identity tests, and 2 CI/ABI contracts.
- The declaration-cache workload makes four cold compiler calls (one baseline
  and three distinct pairs, including a rejection); a fresh service replays
  the three pairs in a different order with zero compiler calls.
- Independent implementation and documentation reviews completed with no open
  findings. Review retained forced-header dependencies for contextual-C-only
  modules. Full-suite follow-up removed a stale dependency from the converted
  foreign-graph cache to the deleted probe toolchain key; that graph continues
  using its parser-owned context and complete header/search dependencies.
- Documentation review checked 249 relative file links. Obsolete cache plans
  were deleted and descriptions in retained plans, manuals, README, contributor
  guidance, and the testing skill were rewritten.
- Canonical `make -j4 test` passed with the isolated prefix, clean build-policy
  environment, and four private compiler-test workers: 129 runtime/packaging
  tests, all 3,275 compiler tests, and all 455 aggregate native tests.
- Hosted Linux CI evidence is tracked on the PR closing #149. macOS dispatch
  remains explicitly waived for this change.
