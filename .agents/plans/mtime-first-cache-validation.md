# Mtime-first compiler cache validation

Authorized follow-up, 2026-09-08. Base: merged master
`534abf000ce7957113dfed780508e16535d0acd5`. Implementation belongs on a new
focused compiler branch. The extension plan is the cross-repository authority.

## Policy and scope

- Persist observed mtime seconds/nanoseconds separately from stable content
  identity. Matching mtime and cheap physical-file guards require metadata only:
  no file read, content hash, or readability open. This explicitly supersedes
  previous same-mtime changed-content invalidation requirements.
- Retain cheap missing/replacement/symlink and ordered include-search checks.
- Changed mtime hashes content once. Equal content refreshes saved observations
  without preprocessing, parsing, conversion, or importer reanalysis.
- Share validated observations across a caller-owned validation pass, with a
  fresh pass for each scan/analysis boundary. Standalone callers use the same
  validation policy without requiring a server cache adapter.
- Carry observations through normal C parser memory reuse, completed-header
  persistence, ordered FFI replay, compiler API normalization, and persistence
  transport. Keep observations out of semantic/cache-key equality.
- Refresh small persistence metadata independently of large semantic graphs.
- Add bounded inner graph-codec yield callbacks with cancellation identity
  preserved. Keep the existing native digest and standalone digest fallback.
- Keep `driver.LANGUAGE_SERVER_API_VERSION` at 1 until Titan's first public
  release, per the maintainer's explicit prerelease policy. Cache schemas and
  graph wire compatibility remain separate; missing old observations are a
  one-time hash fallback, never a metadata hit.

## Ownership and delivery

Compiler agent owns compiler Lua, existing-shard regressions, compiler docs and
this plan. Root owns bridge, SQLite/server integration, benchmark and final
extension CI pin. Use a private source/build stage; do not disturb shared
compiler/provider installations or run broad tests during final benchmarks.
No compiler PR until extension local verification completes. Leave it open
unless the maintainer explicitly authorizes that exact merge; final extension
CI pin must equal the then-live compiler master HEAD.

## Verification

Focused cases must prove zero content reads/hashes for unchanged observations;
one read/hash after a same-content touch followed by zero reads on next process;
direct cheap-guard/search invalidation; changed bytes with changed mtime;
per-pass deduplication; malformed/old observation fallback; stable semantic keys;
CLI/memory/header/FFI parity; bounded codec callbacks and cancellation during
encode/decode. Run the relevant full compiler/Linux gate before publication.

## Implementation checkpoint

The prerelease compiler API adds optional header observations, the explicit restater semantic-change
result, caller-owned validation passes, per-analysis current observation
baselines, metadata-only adapter refresh and cooperative graph work. Graph wire
version 1 remains unchanged; legacy byte adapters backfill observations by
re-encoding only a touched semantic graph. A physical replacement is a different
input and receives a fresh real content identity, with no sentinel identities.

Forced preprocessing uses a completed context within the existing CPP probe
cache and existing header transport under `titan-cpp-forced-v1:` keys. Failed or
in-progress scans/probes are not cached. Timestamp-only touches preserve the
semantic graph and final preprocessor key. Both memory and fresh-adapter replay
clone mutable macro state and preserve cancellation through the graph codec.

The combined focused compiler gate passed 487 cases, including exact mtime
reuse, copied-observation refresh, live source-import baselines, forced
include/imacros no-read/no-probe replay, failed-probe/retarget handling and inner
cancellation. A subsequent foreign-conversion gate passed all 10 cases including
two additional malformed-observation/cancellation regressions.

Independent review found and corrected three boundary cases before publication:
initial header reads now certify before/after metadata rather than stamping old
bytes with a newer timestamp; declared-registry validation shares one work
budget across many small entries; and complete FFI observation validation stays
inside the protected cache-acceptance gate before checker mutation. Regressions
cover ordinary/nested/include/imacros read races, exact cancellation propagation,
many-small-entry yields and a malformed literal metatable degrading to one miss.

Initial local verification used the exact reviewed API 1 compiler sources in an
isolated prepared checkout and prefix: the complete compiler gate passed 3,478
cases with zero failures/errors/pending, and the complete native standard-library
gate passed 455 tests. The companion extension's complete `make verify` gate
also passed, including 302 native, 56 JavaScript and 12 Extension Host tests.
Compiler runtime files remained byte-identical to the reviewed snapshot across
these gates. No production changes were needed after independent review.

Tracking: compiler issue #150 (Titan Project 3, P1/L), linked to merged #148 and
extension #20/#53/#55. The locally verified branch is ready for the companion PR;
final integrated benchmark results and push-triggered Linux/Codecov evidence
will be recorded on that PR before maintainer review is complete. macOS remains
outside this authorized validation run.

## Reconcile the concurrent source-only probe change

The maintainer subsequently merged #151 at
`9ee0d47ad79a0c28efa0c4c14075f054d86a7ebd` and authorized updating this PR while
preserving that simplification. The earlier verification and benchmark evidence
belongs to pre-reconciliation head `f628e0aa`; the combined tree requires fresh
focused/full/native gates, extension integration and both workspace benchmarks.

Compiled probe memory/disk identity remains only SHA-256 of raw unpreprocessed C
source, using format-1 `.result` acceptance/rejection records. No toolchain or
header keys, namespaces, negative markers, batching/bisection, generated identity
hashes or delayed composite scheduling are restored. The new checker-owned
header-input collector copies observations; the probe service only forwards
parser options. Source-order individual probes and immediate composites remain.

Parsed-header and compiler graph caches remain independent. Preserve metadata
validation and completed forced CPP contexts; #151 explicitly leaves that scope
unchanged. Foreign conversion retains the parsed graph/profile/dependency key
without the removed compiled-probe toolchain key. A combined regression checks
that changed bytes refresh the parsed type while identical compiled probe source
continues replaying both acceptance and rejection; subsequent warm parsing reads
and hashes no header contents.

Reconcile and verify privately, then publish one focused commit with an exact
lease on old PR head f628e0aa after paired extension local validation. The
maintainer has conditionally authorized the updated PR's merge once reviewed
and Linux CI is green; root owns that merge and the final live-master extension
pin. macOS remains outside this authorized run.
