# Issue 196: async and I/O allocation implementation

Status: implemented, with matched measurements, independent review, and local
platform validation complete. Stacked PR #197 records final-head CI and remains
unmerged.

## Authorization and baseline

The maintainer authorized the full optimization scope in issue #196 after Oobii
reported clean CI. Run 37162335505 completed successfully at
`4eeaaf8a2621a6f72f91221ce2c8fb47e1525792`; all five jobs passed. Work continues
on `codex/issue-196-async-allocations`. PR #195 remains open and unmerged.
The maintainer authorized sharing among the implementation owner, Oobii and
agents recruited by either. Hosted macOS CI is not authorized; use local VMs.

Design source: https://github.com/mascarenhas/titan/issues/196
Verified issue body SHA256:
`30deea8157d7bc02a3ffc46d3d35df69dddf2443056680b8a517f524f29cb014`.

The system-OpenSSL baseline provider has the same production/compiler sources
as the green commit, uses patched bundled libuv 1.52.1, and was built with the
normal O3/fat-LTO configuration. Preserve it and all prior evidence unchanged.
Candidate measurements must match those inputs and flags. Counts from the old
O0 generic-async probe are historical evidence, not a timing baseline.

## Invariants

- UV owns native ABI, storage, roots and callback boundaries. Async owns generic
  scheduling, cancellation, waits and subscriptions; domain modules own policy.
- Registration is synchronous outside a Task; inline results are delivered only
  after it returns, with existing registration-error precedence.
- Sticky cancellation keeps its first identity. Accepted work retains requests,
  borrowed inputs and rollback state through actual terminal callback/close.
- Cleanup remains available during cancellation/fatal shutdown. A stale fatal
  reports Runtime failure without directly retiring a successor operation.
- Nil and false remain distinct valid result/error payloads.
- Queue acceptance occurs before settlement/reservation commits; failed arming
  leaves the original wait and resource ownership retryable.
- Epochs protect every suspension, queued wake and orphan snapshot, including
  private yields with no Wait. Pop snapshots and clears before reentrant code.
- Observed TaskStatus identities remain stable within a transition and fresh
  across transitions; retained snapshots are never mutated.
- Existing callback-triple APIs remain convenience facades initially.
- No compiler or generated ABI change is implied. Keep package/SDK 0.6.0/0.6,
  generated ABI 2 and language-server API 1 unless independent evidence requires
  a separately justified change.

## Staged implementation and evidence

1. Admission and I/O scaffolding
   - Add synchronous `async.checkpoint` with existing admission precedence.
   - Cache private handle/stream views without changing public view identity.
   - Add typed timer data/close operations and public scalar string writes in UV.
   - Preserve old-string roots through callback return and reentrant request use.
   - Reuse bounded private TCP receive storage, retaining public string copies.
   - Keep independent write requests where legal writes overlap.
   - Freeze and validate this stage before integrating scheduler changes.
2. Runtime scheduling
   - One reusable normally referenced zero timer per Runtime, active for queued
     work only; intrusive Task nodes and bounded FIFO draining.
   - Canonical private yield control; no per-yield Operation/Result/closures.
   - Lazy nonterminal status snapshots and scalar internal phase checks.
   - Exact epoch/wait guards, failure-safe remaining queue and orphan recovery.
   - Preserve explicit token validation and subscription reservation rollback.
3. Generic completions and domain migration
   - Prototype fused fresh Completion with typed context and exact registrar.
   - Compare Task-owned reusable storage with captured scalar operation identity;
     choose with allocation, retention, callback and API evidence.
   - Migrate applicable domain callbacks to named functions and existing owners;
     count every extra context/ticket/adapter and preserve concurrent operations.
   - Reuse request storage only after actual native cleanup under an exclusive
     ownership contract; do not pool overlapping work.
4. Regression and measurement
   - Preserve existing behavioral gates; add checkpoint, status identity,
     scheduling fairness/requeue/failure, epoch, Completion and UV lifetime cases.
   - Inspect generated C for exact, captured and bound registrars, nominal context
     erasure, typed timer callbacks and scalar writes.
   - Measure Lua-host and typed Titan callers for inline success/error, yield,
     filesystem success/rejection, cancellation, cleanup, OS writes, timers and
     subscriptions. Separate setup, per-operation and per-event costs.
   - Record allocation counts, byte traffic, live/peak/retained Lua bytes, GC work,
     wall/CPU time, fairness/tail latency and idle-resource retention. Distinguish
     native allocation domains and all first-use effects. No unmeasured claims.
5. Delivery
   - Independent implementation/lifetime/measurement review and exact consumers.
   - Update both manuals, affected skills and examples/contracts as appropriate.
   - Complete relevant Linux checks, local macOS/Windows validation and focused
     sanitizer gates. Record architecture and exclusions honestly.
   - Publish the follow-up PR with actual head and CI evidence; do not merge the
     baseline or follow-up PR without explicit authorization.

## Delivery evidence

Implementation selected one lazy Task-owned Completion cell with a checked
operation number after the fresh/reused prototype, lifetime tests, and exact
registrar/capture/context measurements. The direct yield path uses the shared
Runtime FIFO without a per-yield Completion or result object. Native domain
contexts retain accepted work through terminal callbacks and cleanup.

The checked-in [results](../../doc/implementation/async-allocation-results.md)
and [portable harness](../../spec/bench/async_allocations/README.md) record the
matched O3/fat-LTO baseline, 122 allocation comparisons, 48 canonical Completion
processes, 36 extra-collection controls, TCP retention, exact generated-C
inspection, and the quiet 538-process wall/CPU/latency experiment. The report
carries short-sample flags, native-allocation exclusions and the 65,632-byte
idle-reader cache cost.

Linux optimized native tests and the final async rollback ensemble pass. Local
macOS x86_64 runtime/packaging/compiler tests and both optimized OpenSSL modes
pass; universal-archive evidence does not imply arm64 runtime execution. Local
Windows x64 O0/O3 aggregate and source-free consumers pass with classified
platform exclusions. Focused local ASan/UBSan and both rollback supplements pass.
Independent implementation, ownership, public-client, generated-C, and measurement
reviews are preserved with the original failures and corrected runs. All platform
runs are bound to the producing source; later report/fixture changes are recorded
separately. PR #195 and [PR #197](https://github.com/mascarenhas/titan/pull/197)
remain open and unmerged. No hosted macOS workflow was dispatched.

## Ownership

- Integration owner: async core, checkpoint/scheduler/Completion and coordination.
- UV owner: concrete data/close APIs, scalar writes, native callback roots and UV
  public tests/docs.
- I/O owner: net/os private views/buffers/write adapters and owning tests/docs;
  later domain Completion migration after signature alignment.
- Measurement reviewer: frozen baseline, optimized harnesses, retention/latency
  evidence and independent scheduler/Completion design review.

All native builds use independent prefixes/checkouts and immutable input receipts;
no worker mutates a previously sealed provider or another worker's installation.
