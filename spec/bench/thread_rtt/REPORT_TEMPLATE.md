# Issue #252 Cross-Thread RTT and Component Report Template

This is a report-writing contract, not a measurement result. Replace the fields
with observed evidence and links; never turn the acceptance checks below into
unconditional pass statements. `summarize.py` generates tables from a campaign
summary. Publish those tables **with this completed report and its raw
artifacts**; tables alone do not establish reproducibility, lifecycle correctness,
or a performance gate.

Use the [README's exact CLI and receipt schema](README.md#exact-run-recipe) for
the measured harness revision.

## 1. Status and Comparison Boundaries

- Report date, author, host, and immutable artifact location: `<evidence>`.
- Measurement status: `<completed / failed / incomplete; exact affected cases>`.
- Baseline-harness commit: `<commit and source hashes>`.
- Historical lane: `<pre-resource-table source revision and SDK identity>`.
- Resource-ownership baseline lane: `<accepted resource-ownership correctness checkpoint: Workstream 1 plus implemented cheap-codec/synchronization changes; pre-wake source revision and SDK identity>`.
- Final corrected wake/join lane, if measured: `<source revision and SDK identity, or not measured>`.
- Actual command, selected catalog, and case count: `<plan output and hashes>`.
- Changes between each pair: `<ownership / codec / wake changes actually present>`.

The historical pre-resource baseline and resource-ownership checkpoint both use
**generated-code ABI 2**. Other existing version numbers remain unchanged,
including language-server API 1. Revisions and content hashes distinguish these
images; an ABI-version change does not. Neither ABI equality nor a matching
`--source-commit` label proves that source and provider match.

Report pre-resource versus accepted resource ownership separately from resource
ownership/pre-wake versus the final corrected wake/join candidate. The former
does not isolate the wake change. A failed build, a smoke run, or a partial
catalog is not a completed baseline measurement. Do not report a speedup
without measured, matched lanes.

The accepted resource-ownership correctness checkpoint is not final Thread
correctness approval. Its actual wait/spawn paths remain legacy per-wait and
detached, with known OS-join and pre-start proxy-early-terminal defects.
Document those limitations without masking them or imposing the final
join/proxy/shared-wake cutover before this checkpoint can be measured.

## 2. Immutable Source, SDK, and Build Provenance

Complete one column per measured lane; add a third column for a wake candidate
when applicable. Link the exact receipt/manifest field for every identity.

| Field | Baseline lane | Candidate lane |
|---|---|---|
| Checkpoint role and source revision | `<evidence>` | `<evidence>` |
| Exact source snapshot and per-file SHA-256 manifest | `<evidence>` | `<evidence>` |
| Source/SDK binding receipt path and SHA-256 | `<evidence>` | `<evidence>` |
| Immutable SDK prefix and build profile | `<evidence>` | `<evidence>` |
| Generated-code ABI / language-server API | `2 / 1` | `2 / 1` |
| Existing package, Lua, and native dependency versions | `<evidence>` | `<evidence>` |
| Installed `titan.a` and shared-provider SHA-256 | `<evidence>` | `<evidence>` |
| `libtitan.a`, Lua executable/archive, and SDK header SHA-256 | `<evidence>` | `<evidence>` |
| Native dependency archives, headers, and patch identities | `<evidence>` | `<evidence>` |
| Compiler frontend, C compiler, archiver, linker identities | `<evidence>` | `<evidence>` |
| Installed Titan compiler script/module content hashes and exact source revision | `<evidence>` | `<evidence>` |
| Compiler patch set relative to the immutable pre-wake checkpoint, explicitly none when unchanged | `<evidence>` | `<evidence>` |
| Provider roots, consumer, and entrypoint built with that compiler; affected-root matching evidence | `<evidence>` | `<evidence>` |
| Complete ordered generated-C flags, preserved driver defaults plus actual standard-library extras, and link libraries | `<evidence>` | `<evidence>` |
| Canonical receipt `native_policy` and comparison-lane equality evidence | `<evidence>` | `<evidence>` |
| Required `native_policy.titan_cppflags` / `titan_ldflags` external dependency selection strings (explicit empty strings allowed for original system defaults) | `<evidence>` | `<evidence>` |
| Required `native_policy.titan_extra_cflags`, `titan_build_profile`, and boolean `emit_line_directives` | `<evidence>` | `<evidence>` |
| Exact `native_policy.sdk_header_replay` map, original/SDK byte hashes, and before/after UV header-inventory checks | `<evidence>` | `<evidence>` |
| `source_compile_policy`, actual `native_compile_argv`, 26-root / `bench` seed inventories, and probe-only flag differences | `<evidence>` | `<evidence>` |
| Harness source/helper hashes and catalog snapshot | `<evidence>` | `<evidence>` |
| `codec_contract`, specialized raw helper, and `generated_consumer_sha256` | `<evidence>` | `<evidence>` |
| Uninstrumented executable and original-provider link receipts | `<evidence>` | `<evidence>` |
| Private probe edits, before/after source hashes, and complete 26-root rebuild receipts | `<evidence>` | `<evidence>` |
| Original provider Native payload identities reused by private rebuild | `<evidence>` | `<evidence>` |
| Private instrumented provider and executable SHA-256 | `<evidence>` | `<evidence>` |
| Final static/shared provider selection and native link receipts | `<evidence>` | `<evidence>` |
| `BUILD.json` and `PREFIX-BEFORE.json` / `PREFIX-AFTER.json` hashes | `<evidence>` | `<evidence>` |
| Prefix/source immutability audit result | `<evidence>` | `<evidence>` |

Record the full ordered original generated-C flags—not just `-O3`—and preserve
installed-driver defaults plus the receipt's actual `titan_extra_cflags`.
The required profile and line-directive boolean must match the source/SDK
build. The compile guard checks the actual descriptor/prefix, not a rewritten
optimization default. Record external include/library/runtime-search flags
from `titan_cppflags` and `titan_ldflags` as originally built, not inferred from
the current host; SDK/source/LPeg roots and instrumented GNU-wrap flags are
separate.

The required header replay map binds `include/uv.h`, every `include/uv/**/*.h`,
`include/llhttp.h`, and `include/sqlite3.h` to original source-relative paths and
identical SHA-256 bytes; link before/after header/inventory checks. Retain actual
verbose native C argv and source policy, including the compiler-added per-module
seed inventory separately from common flags. The probe inherits the full flags
with its documented instrumentation-only C11/diagnostic/no-builtin/fixed-seed
additions. An OpenSSL/header or native-policy mismatch cannot be hidden by equal
optimization flags or by silently dropping LTO/debug/line directives.

The initial body-performance checkpoint uses its immutable SDK's original
compiler, not later correctness/code-generation fixes by implication. For a
later isolated wake/join comparison, identify any common compiler patch set and
prove matching compiler inputs for both lanes and every affected provider root,
consumer, and entrypoint. If those inputs differ, report the compiler change
as an additional comparison boundary; equal ABI 2 and native C flags do not
establish compatibility or isolate a wake effect. Do not modify an attested SDK
or frozen harness or substitute overlapping roots to hide that difference.

The uninstrumented lane uses the installed provider unchanged. The instrumented
lane privately rebuilds all 26 standard-library roots from the exact matching
source, applies only recorded semantic probes, and retains the original
provider's Native object payload. It must not substitute a single-root provider
that overlaps the installed bundle or silently rebuild a different native
payload. `--static` is a preference: retain final provider/link evidence rather
than assuming that every call was statically interposed.

The private `raw_roundtrip` consumer helper is selected from the exact measured
transfer source signature, not the ABI number. Record
`ordinary_consuming_value` for the original ordinary raw decoder and
`native_consuming_slot` for the accepted state/slot-consuming C-ABI decoder.
The latter saves the Lua stack top and installs restoration before encoding,
installs raw packet disposal, and decodes through the actual mutable raw-owner
slot. Its C-ABI status returns without native longjmp: `0` leaves one value,
positive status leaves one error, and negative status reports setup failure.
The helper copies the error into a traced local before `raise_message_error`,
or retrieves the decoded stack value after success.
This is a generated benchmark calling-contract specialization only: the raw
codec route is retained, with no `Packet` substitution or production shim.
Publish the generated consumer hash for each lane and disclose that necessary
helper difference; common authored harness hashes do not imply identical
generated consumer bytes.

## 3. Host, Campaign, and Raw-Evidence Inventory

- OS/kernel/architecture/CPU, affinity, frequency policy, memory, and relevant
  tool versions: `<evidence>`.
- Dated quiet-host note, its SHA-256, and before/after process/load snapshots;
  local and VM builds stopped during measurements: `<evidence>`.
- Command receipts and complete environments for build, smoke, baseline,
  paired run, audit, and report generation: `<evidence>`.
- Random seed, randomized case order, alternating lane order, independent
  batches, repeats, scale, operation counts, warmup counts, and instrumentation
  repeats: `<evidence>`.
- `BASELINE-RAW.json` / `PAIRED-RAW.json`, summary JSON, every per-run JSON and
  bounded raw sample TSV, plus SHA-256 and artifact-relative links: `<evidence>`.
- Complete catalog coverage in both modes and both lanes, including any
  exclusions, failed commands, stderr, and timeouts: `<evidence>`.
- Matched pair keys `(case, batch, repeat, mode)` and order-sensitive per-pair
  differences/ratios; separate within-batch variation from between-batch
  repeatability: `<evidence>`.

Keep raw paired observations even when generated tables display marginal lane
medians. Identify whether a reported percentile is from pooled samples, a
single run, or a median of per-run percentiles. Do not relabel the latter as a
pooled p99.

## 4. Protocol and Topology Validation

For each family, record payload/record shape, validation, request/reply channel
capacities, actual OS-thread producer and consumer states, total in-flight
budget, reply-slot protocol, and expected sample/checksum rule. A `2p2c` or
`4p4c` label must correspond to that many isolated OS producer and consumer
states, not multiple Tasks in one producer Runtime. In-flight credit is
independent of worker count.

| Family / cases | Protocol and exact topology | All-state warmup/readiness evidence | Validation and expected samples |
|---|---|---|---|
| Same-state codec / queue controls | `<evidence>` | `<evidence>` | `<evidence>` |
| SPSC persistent reply | `<evidence>` | `<evidence>` | `<evidence>` |
| SPSC exclusive pool of four | `<evidence>` | `<evidence>` | `<evidence>` |
| SPSC fresh reply channel | `<evidence>` | `<evidence>` | `<evidence>` |
| MPMC 1 / 4 / 16 in flight | `<evidence>` | `<evidence>` | `<evidence>` |
| Directed full-sender / empty-receiver waits | `<evidence>` | `<evidence>` | `<evidence>` |
| Close/cancel churn and ordinary/cleanup join | `<evidence>` | `<evidence>` | `<evidence>` |

Readiness alone is not warmup. Every steady-state producer/consumer state must
exercise its request decode, endpoint/control handling, reply path, and local
GC before the body begins, with automatic GC enabled during primary timing.
Record per-state evidence, not only a shared aggregate warmup count. Churn
intentionally measures fresh lifecycle work. Directed full-sender samples
measure admission/slot release, not processing/reply of the newly admitted
request. Record exact previous-packet validation and the final drain, rather
than presenting these admission-control samples as ordinary RTT.

## 5. Uninstrumented Timing and RTT

Attach the generated timing tables and link their summary/raw inputs. Report
sample count, truncation, min/max/range, p50/p95/p99, throughput, and loop time;
keep first-use, warmup, worker retirement, and residual collection separate.

| Case | Protocol | Ops/round and RTT samples | Loop us/op and range | p50 / p95 / p99 us | Throughput ops/s | Cold / warmup / retire us | Residual GC us/op |
|---|---|---:|---|---|---:|---|---:|
| `<case>` | `<protocol>` | `<evidence>` | `<evidence>` | `<evidence>` | `<evidence>` | `<evidence>` | `<evidence>` |

### Matched endpoint/control workloads

Admit a pair only after confirming identical record shape, capacities,
producer/consumer counts, in-flight budget, application protocol, and timed
validation. Candidate pairs include `queue_real_sender` / `queue_plain_bytes8`,
`queue_real_receiver` / `queue_plain_bytes8`,
`spsc_endpoint_carried_persistent` / `spsc_record_persistent`,
`spsc_endpoint_pool4_reply` / `spsc_record_pool4_control`, and the corresponding
MPMC/directed-wait endpoint/record pairs. `sender_clone` is a separate operation,
not a three-field queue pair.

| Endpoint workload | Control | Matching contract and validation evidence | Endpoint us/op | Control us/op |
|---|---|---|---:|---:|
| `<case>` | `<control>` | `<evidence>` | `<observed>` | `<observed>` |

These are whole-workload contrasts, not isolated retain, wrapper, or hook
timings. Any unmatched endpoint validation (for example, an extra
`reply:is_closed()` lock) must be disclosed and prevents an isolated component
claim.

### Application-protocol contrasts

| Workload | Other protocol | What changes besides endpoint representation | Observed timing / tail evidence |
|---|---|---|---|
| `spsc_endpoint_fresh_reply` | `spsc_endpoint_pool4_reply` | Fresh versus exclusive pooled reply-channel lifecycle; both carry endpoints | `<evidence>` |
| `spsc_endpoint_pool4_reply` | `spsc_endpoint_carried_persistent` | Pool-of-four versus persistent reply protocol | `<evidence>` |
| `spsc_large64k_endpoint_pool4` | `spsc_large64k_persistent` | Reply protocol and endpoint carriage | `<evidence>` |

Do not label these as matched endpoint-only component differences. A large
non-endpoint pool-four control would be required for that component claim.

## 6. Semantic Wait Counters and Handle Lifecycle

Use the private source probes, not a mutex-lock ordinal/retain-skip heuristic.
Report the emitted aggregate fast successes, slow attempts, successful
registration rechecks, actual suspensions, notifications, and cancellations.
These include worker request receives, replies, and protocol-control channels.
The schema has no general per-operation-role/direction breakdown and no
separate closed/failed counter fields; those outcomes are excluded from
successful fast/recheck counts. Mark unmeasured breakdowns unavailable rather
than deriving or inventing zeroes. Keep ordinary and cleanup join suspension
subcounts distinguishable.

| Case | Fast | Slow attempts | Recheck success | Suspensions | Ordinary / cleanup join suspensions | Notifications | Cancellations | Body and whole-case async init / public close requests |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| `<case>` | `<observed>` | `<observed>` | `<observed>` | `<observed>` | `<observed / observed>` | `<observed>` | `<observed>` | `<evidence>` |

Also report actual terminal close callbacks, attempted/successful
`uv_loop_close` calls, and async identities retired by successful loop close.
Pinned libuv creates its internal work-queue async through `uv_async_init` but
destroys it directly when the loop closes; do not invent a corresponding public
close request or callback. A failed/busy native loop close must leave identities
live. Link the process-birth identity/owning-loop ledger, including cold first
use; whole-case counter snapshots begin after that cold phase. Keep real UV
allocation traffic and the zero-unretired-handle requirement unchanged.

Show that directed waits and cleanup-join barriers exercised their intended
slow paths. A checksum or observer Task suspension alone does not prove that
the native operation parked.

## 7. Allocation, Copy Coverage, and Overlapping Stages

| Case | Lua allocation calls / requested bytes | Native allocation calls / requested bytes | Interposed memcpy/memmove bytes (outside / inside Lua allocator) | Analytical reference bytes | Native/host-Lua residuals |
|---|---|---|---|---|---|
| `<case>` | `<evidence>` | `<evidence>` | `<evidence>` | `<estimate, not actual traffic>` | `<evidence>` |

- Lua allocation traffic comes from the allocator installed before each state's
  first allocation; report calibration and slot-exhaustion results.
- Native allocation traffic excludes the Lua allocator and probe-owned storage.
  `gc.count()` is only a Lua-managed live-memory checkpoint, not a native
  allocator counter. Interposed allocator balance is not a complete native
  resource-lifetime proof.
- Copy wrappers observe calls crossing the `memcpy`/`memmove` symbols; inlined,
  dynamically bound, or internal copies may be absent. The inside/outside
  `lua_Alloc` split describes callback execution context, not object ownership.
  Analytical reference sizes are not actual all-case wire bytes or total copied
  bytes; unsupported/unknown coverage is unavailable, never measured zero.

| Case | Stage | Samples / truncation / availability | p50 / p95 / p99 / range us | Exact probe boundaries |
|---|---|---|---|---|
| `<case>` | `<stage>` | `<evidence>` | `<observed or unavailable>` | `<evidence>` |

Stage percentiles summarize multiple rounds independently of the representative
counter round. Preserve total sample counts, per-round count ranges, and every
observed wake-attribution mode from the same contributing rounds. A single
representative round's mode must not label a multi-round percentile aggregate.

Stages overlap across OS threads. Never add their medians into a synthetic RTT
or infer wake/component time by subtracting independent workload medians.
Native notification-to-continuation time includes scheduler/ready-queue delay;
it is not isolated libuv delivery time. Require exact waiter identity and a
causative notification, not a process-global last signal or an in-flight-one
assumption. Missing/ambiguous attribution, unsupported instrumentation, and
zero samples must be distinguished from an observed zero-duration interval.

## 8. Instrumentation Overhead and Lifecycle Evidence

| Case / lane | Uninstrumented us/op | Private-instrumented us/op | Ratio and batch variability | Sampling/call-control evidence |
|---|---:|---:|---|---|
| `<case/lane>` | `<observed>` | `<observed>` | `<evidence>` | `<evidence>` |

This measures the combined private rebuild/probe/wrapper overhead. Do not use
instrumented timings as primary end-to-end results or subtract their overhead
to invent an unobserved timing.

| Required lifecycle check | Observed result, count, and raw receipt |
|---|---|
| Every case/mode/lane exits 0, with expected stderr and no timeout | `<evidence; failures explicitly listed>` |
| Deterministic checksum and exact payload identity/order validation | `<evidence>` |
| Expected RTT/stage samples, no required missing TSV, no truncation | `<evidence>` |
| Lifecycle baseline precedes all benchmark-owned setup | `<evidence>` |
| Every steady-state worker ready, warmed, and released before body timing | `<evidence>` |
| Body stops before endpoint close/join; retirement timed separately | `<evidence>` |
| Channel/control balances and zero active native workers after quiescence | `<evidence>` |
| Native worker-tail release complete (end of owned native work, not OS-join proof) | `<evidence>` |
| Final corrected wake/join candidate only: actual OS join before every proxy terminal outcome, including cancellation cleanup | `<separate source/build and behavioral evidence, or not measured; not required of legacy pre-wake checkpoint>` |
| Final corrected candidate cancellation policy: reasonless native cleanup cancellation only absent an admitted child cancellation; preserve host reason/error and never overwrite an accepted child reason | `<separate behavioral evidence, or not measured>` |
| Endpoint/handle retirement and drain before two post-retirement full collections | `<evidence>` |
| UV async identities retire at real callbacks or actual successful owning-loop close; failed closes discharge none and active identity count is zero | `<callback/loop-retirement counters and source evidence>` |
| Residual Lua/native allocation ledgers and their coverage limitations | `<evidence>` |
| Original SDK/source unchanged at final audit | `<evidence>` |

Keep the original and resource-ownership/pre-wake checkpoints' actual legacy
join/proxy semantics explicit; neither is final Thread approval. A historical
finished signal or benchmark worker-tail zero proves neither OS exit nor OS
join. Actual join/terminal-ordering and cancellation-policy proof belongs to
the final corrected wake/join candidate. Do not make that later cutover a
circular prerequisite to the original/resource-ownership baseline measurements.

## 9. Conclusions and Remaining Evidence Gates

- Historical ownership/codec observations: `<supported observations only>`.
- Final corrected wake/join acceptance, only after its matched campaign:
  `<repeatable latency/throughput benefit, fewer handles, fairness/p95/p99
  evidence relative to batch noise, actual OS join and cancellation-policy
  proof, and full final platform gates; or not measured/not accepted>`.
- Unavailable metrics, excluded cases, failed attempts, and limits on inference:
  `<evidence>`.
- Linux, Windows NTFS, local macOS, sanitizer, and source-free correctness
  evidence are separate from benchmark results: `<links or not run>`.

Commit the baseline harness and measure both the original and accepted
resource-ownership correctness checkpoints before switching actual thread
wait/spawn callers to the final joinable/prearmed-proxy/shared-wake design.
Valid benchmark-owned lifecycle/quiescence evidence is required, but does not
upgrade the baseline's known legacy thread semantics into final correctness.
The final corrected candidate still requires actual OS join, cancellation
policy, and complete Linux/Windows NTFS/local macOS proof. Do not call channel
creation cost negligible or infer application RTT improvement from a codec
microbenchmark alone.

Descriptor caches/tag plans, decoder representation changes, deep-buffer
redesign, and native channel/packet pooling remain out of scope. Reopen only
with a representative post-wake profile showing material cost and a targeted
prototype demonstrating benefit while preserving the relevant identity,
decoding, ownership, and single-hook-invocation semantics.

