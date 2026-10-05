# Async and I/O allocation results

The corrected final comparison passes all 122 allocation cases, and every Lua allocator ledger equals Lua's actual live-heap count. Direct yield has no steady per-operation Lua allocation; observing status once after each yield adds one fresh 36-byte userdata. Repeated observations within the same phase use that cached snapshot. The client and Completion paths reduce allocation while preserving legacy facade behavior. Matched quiet timing and latency results are reported below.

## Compared artifacts and method

The baseline's 203 production inputs match `4eeaaf8a2621a6f72f91221ce2c8fb47e1525792`; it reuses the preserved optimized build from that work. Final provider source is `02fa27c796cdca724fd7d53b216c4c4f2bcb5ac4`. The final frozen source archive SHA-256 is `b640ef62b28e11b9b35b4ecc43fbf4dd83f5682631a3cdbd8d655c77ed61c15c`; provider `titan.so` is `08d400d2236fb289fceabfc6d0ff758b5fb1880c91820bd01e9c8045f9398a97` and archive `titan.a` is `be6e8a2141434b953965982c4df7e070571809c5a170ee6095f7012c23564a0d`.

Both are Linux x86_64 builds with the default `-O3 -flto=auto -ffat-lto-objects` policy, the patched bundled libuv and system OpenSSL. The Lua executable/archive, runtime archives, native dependency inputs, configured native tools and all 75 installed compiler Lua files match across the comparison. Each compiler also matches its frozen source; final source, SDK files, exact generated C/object files and native link/compile inputs have separate manifests. All 2,166 final canonical-prefix and copied-prefix files remain unchanged in bytes, size, mode and nanosecond mtime after the corrected matrix; the baseline prefix's 857 files remain unchanged. Copies have distinct inodes.

The authoritative allocation matrices use the preserved original harness and identical source bytes, including the same Lua chunk filenames and relative `./bench.titan` generated source path. The probe shared object is byte-identical in both lanes (`5ef650cf8612048052acf952f1ad1b3edbdc1c47a0adbf34bda6d03d9e1d1c5a`). The original runner clears Lua/Titan/loader/compiler policy overrides and records its selected settings, but inherits other ambient environment entries: this is not retroactively a hermetic baseline. The checked-in portable runner builds separately under an explicit environment and private prefixes; its paired timing run uses that common current policy. The first portable final matrix is preserved but superseded for quantitative comparison because its absolute consumer source paths affected diagnostic-string allocations. No provider rebuild was needed for the correction.

The 122-row matrix has counts 0, 100 and 1,000 for 18 cases under both Lua and typed hosts, one zero-work whole-lifecycle control per host, and six additional GC-stopped cases per host. Tables use the `(count1000 - count100) / 900` body slope. `U / F / B` means newly allocated userdata, function objects and successful requested Lua bytes per iteration; bytes include successful reallocations and are not retained bytes. Small fractional byte slopes can reflect string interning, stack growth and automatic GC. `nil` and `false` success/error cases and cleanup variants verify distinct result tags. OS writes send 32 bytes to a draining child; FS writes send 32 bytes to `/dev/null`. Body counting excludes per-case resource setup but cleanup remains measured separately.

## Steady body allocations

| Workload | Lua baseline U/F/B | Lua final U/F/B | Typed baseline U/F/B | Typed final U/F/B |
|---|---:|---:|---:|---:|
| Control | 0 / 0 / 0.0 | 0 / 0 / 0.0 | 0 / 0 / 0.0 | 0 / 0 / 0.0 |
| Legacy inline success/error, nil/false; inline cleanup | 5 / 4 / 844.0 | 1 / 3 / 500.0 | 5 / 7 / 1,260.0 | 1 / 6 / 948.0 |
| Yield | 8 / 8 / 1,812.0 | 0 / 0 / 0.0 | 8 / 8 / 1,812.0 | 0 / 0 / 0.0 |
| Yield with observed status | 8 / 8 / 1,812.0 | 1 / 0 / 36.0 | 8 / 8 / 1,812.0 | 1 / 0 / 36.0 |
| FS stat | 12 / 10 / 2,924.0 | 9 / 2 / 1,612.0 | 12 / 10 / 2,924.3 | 9 / 2 / 1,612.0 |
| FS rejected open | 8 / 11 / 3,328.3 | 5 / 3 / 1,984.0 | 8 / 11 / 3,292.4 | 5 / 3 / 1,947.0 |
| FS write | 11 / 10 / 3,013.0 | 8 / 2 / 1,701.0 | 11 / 10 / 3,013.1 | 8 / 2 / 1,701.0 |
| OS pipe write | 11 / 9 / 2,529.0 | 3 / 0 / 580.0 | 11 / 9 / 2,529.0 | 3 / 0 / 580.0 |
| Open and cleanup close | 14 / 20 / 5,012.6 | 7 / 3 / 2,176.0 | 14 / 20 / 5,012.6 | 7 / 3 / 2,176.1 |
| Timer sleep(0) | 34 / 36 / 8,015.7 | 5 / 0 / 688.0 | 34 / 36 / 8,009.7 | 5 / 0 / 688.0 |
| Subscription setup/close | 9 / 4 / 1,383.0 | 9 / 4 / 1,383.0 | 9 / 7 / 1,799.0 | 9 / 7 / 1,799.0 |
| Buffered publish/next | 2 / 0 / 132.0 | 2 / 0 / 132.0 | 2 / 0 / 132.0 | 2 / 0 / 132.0 |
| Queued cancellation | 24 / 14 / 7,011.0 | 11 / 4 / 4,378.9 | 24 / 15 / 7,228.6 | 11 / 5 / 4,592.4 |
| Running cancellation | 53 / 41 / 16,068.5 | 14 / 7 / 7,980.8 | 55 / 45 / 17,675.6 | 16 / 11 / 9,644.0 |

All five grouped inline cases have the displayed exact slope. These typed legacy fixtures retain six closure allocations due to compatibility adapters; the public context API below avoids them. The unchanged subscription rows are useful controls. Zero steady yield allocation does not mean module loading, first Task creation or teardown is free.

## Setup, live heap and collection scope

Module loading and its named-function closures occur before the hook and are excluded. The zero-work `whole` control includes Runtime/Task creation and fixed harness overhead; it is not an isolated Runtime constructor measurement. Its body and teardown-inclusive totals are:

| Host / lane | Body U/F/tables/requested B | Through teardown U/F/tables/requested B |
|---|---:|---:|
| lua / baseline | 12 / 6 / 4 / 10,663 | 14 / 7 / 5 / 11,013 |
| lua / final | 8 / 3 / 4 / 10,224 | 12 / 6 / 5 / 10,982 |
| typed / baseline | 12 / 7 / 4 / 10,578 | 14 / 8 / 5 / 10,928 |
| typed / final | 8 / 4 / 4 / 10,139 | 12 / 7 / 5 / 10,897 |

The Task-owned Completion cell is allocated lazily once per participating Task; positive canonical inline runs have `N+1` userdata for `N` waits, while the steady slope is the single Result userdata. Runtime wake ownership is likewise setup/teardown work. Cleanup after the body control requests 321 B baseline versus 729 B final at 1,000 iterations; real OS child cleanup additionally drains/closes its three streams and is not represented by that small control.

Live-byte peaks below use the actual Lua allocator ledger at 1,000 iterations with automatic GC enabled. `Peak` and `body-end` are differences from the pre-body heap; `after GC` subtracts that same case's zero-count post-GC heap. Negative differences are possible because preexisting collectible objects disappear. These process-wide Lua heap totals include module/cache/trace/stack bookkeeping and do not identify live application contexts.

| Host / workload | Peak B baseline → final | Body-end B baseline → final | After one GC B baseline → final |
|---|---:|---:|---:|
| lua / yield | 1,812,106 → 107 | 1,812,106 → 107 | 29 → 29 |
| typed / yield | 1,812,890 → 139 | 1,812,890 → 139 | 781 → 29 |
| typed / fs_stat | 2,118,117 → 1,614,797 | 249,201 → 1,614,797 | 781 → 781 |
| typed / os_write | 2,136,948 → 581,764 | 101,984 → 581,764 | 29 → 29 |
| typed / timer_sleep | 2,127,095 → 642,753 | 177,262 → 642,753 | 1,901 → 781 |
| lua / cancel_queued | 3,144,503 → 3,186,545 | 231,711 → 730,876 | 29,474 → 60,450 |
| lua / cancel_running | 3,144,665 → 3,167,544 | 98,465 → 897,914 | 35,530 → 83,893 |
| typed / cancel_queued | 2,128,101 → 2,160,848 | 732,533 → 1,139,912 | 35,706 → 74,850 |
| typed / cancel_running | 2,118,132 → 2,152,170 | 700,792 → 977,457 | 36,358 → 27,318 |

Fewer allocations do not guarantee a lower body-end heap at the same sample: crossing an automatic-GC threshold at a different iteration can reverse that comparison. The GC-stopped control exposes cumulative Lua allocation pressure more directly. Typed 1,000-operation peak deltas fall from 1,812,890 to 139 B for yield, 2,925,245 to 1,614,797 B for FS stat, 2,517,604 to 581,764 B for OS write, and 7,949,321 to 642,753 B for timer sleep; buffered publish/next stays 132,761 B. Native coroutine stacks, native allocators and mapped providers are outside this Lua ledger. `ru_maxrss` is separately recorded but includes those process-wide costs and is not a Lua retained-heap measurement.

Forced post-body GC wall/CPU times are also recorded, but these hooked runs happened while other builds were active. They report observed collection work, not a GC speedup. For example, typed yield wall/CPU is 452/451 µs baseline and 183/183 µs final; typed timer is 304/304 versus 645/643 µs; Lua queued cancellation is 819/819 versus 1,637/1,618 µs. The probe does not count automatic GC cycles.

## Cancellation collection control

The higher single-GC cancellation residual was investigated in a separate 36-row experiment: both lanes × both hosts × control/queued/running × counts 0/100/1,000. Both lanes use the same current benchmark source paths in this experiment. After `async.loop()` returns and Task success is checked, the Task and status references are set to nil; two explicit full collections then precede `probe.finish()`'s third full collection. No result table is allocated until after these samples. All 36 ledgers match exactly, and independent review verified every command/result hash.

At 1,000 operations, each case's post-GC heap minus its own count-zero run is:

| Host / workload | First full GC B baseline → final | Second full GC B baseline → final | Third full GC B baseline → final |
|---|---:|---:|---:|
| lua / cancel_queued | 42,850 → 84,386 | 130 → 130 | 130 → 130 |
| lua / cancel_running | 39,338 → 93,205 | 714 → 757 | 714 → 757 |
| typed / cancel_queued | 38,986 → 84,394 | 130 → 130 | 130 → 130 |
| typed / cancel_running | 31,078 → 149,542 | 130 → 130 | 130 → 130 |

Second and third collections match in 34/36 rows; baseline typed control(100) and running cancellation(100) release another 64 B on the third. Third-collection case-minus-zero residuals at 100 versus 1,000 differ by only one byte in every lane/host/case, also seen in the controls; this does not identify that byte's object category. Coroutine owners have `__gc`, traced thread/callback/record uservalues, and a finalizer that destroys native coroutine storage without clearing that traced graph. Lua marks and propagates finalizable objects before finalization. This provides a concrete mechanism consistent with delayed reclamation. The control demonstrates no operation-count-proportional retained heap over the tested range; it does not classify each byte or exclude bounded retained objects. The remaining small residual should not be labeled entirely as strings without a heap census. Exact Completion context-finalizer tests and TCP resource retention tests provide separate reachability evidence.

## Canonical Completion shapes and generated C

A second consumer imports the final public API and runs 48 allocation processes (15 cases at 0/100/1,000 plus three GC-stopped cases at 1,000); all pass with zero ledger discrepancy. Its source-only import guard parses exactly one consumer module. The same final provider, probe and immutable prefix are used.

| Public API shape | Steady userdata / closures / requested B |
|---|---:|
| Exact named registrar; nil/false; cleanup; existing typed Context | 1 / 0 / 68 |
| Captured immutable scalar registrar | 1 / 1 / 196 |
| Bound registrar | 1 / 1 / 196 |
| Newly allocated five-field Context per wait | 2 / 0 / 180 |
| Existing-context native FS request | 3 / 0 / 204 |
| Bare native request with Completion/number ticket | 4 / 0 / 276 |
| Cancellable FS fixture | 4 / 0 / 272 |
| Legacy typed facade | 1 / 6 / 948 |
| Four differently typed waits per loop iteration | 4 / 0 / 272 |
| Direct yield | 0 / 0 / 0 |

The cancellable fixture constructs an extra Result for common checks, so its count is not a minimum cancellable API cost. Bare native requests need the operation number beside the reusable cell; an explicit ticket costs one userdata. Context storage and retained resources must therefore be included when choosing an adapter shape.

Exact generated-C function/branch extracts explain these results: named registrars and `await_*_with` have no direct closure constructor; typed context is passed as a `TValue`, with no boxing wrapper. Captured immutable integers and bound receivers go directly into closure upvalue 4; these fixtures do not represent mutable capture-cell cost. Both forms create one six-upvalue closure and no additional callable adapter. A fresh Context adds one userdata constructor. The Completion helper has one constructor site guarded by an absent cached Task cell; `wait_result` has five mutually exclusive Result constructor branches. Legacy closure accounting is one outer callable adapter, two resolve/reject argument adapters and three callbacks in `old_void_start`, matching six per call in this typed fixture. `start_suspend` uses the ResumeToken as context and has no direct userdata/closure constructor. Counts are branch-inclusive direct static sites, not whole-call transitive runtime counts.

The survey is tied to the final source/installed compiler/21 generated C files/21 objects and native compile inputs. Eight selected provider units contain 6,061 functions, 972 focused extracts and 5,160 classified sites with no unowned sites. Separate client and native ownership reviews interpret their relevant call chains; repository-wide text counts are not used as performance evidence.

The private fresh-vs-reused Completion prototype additionally compared 96 allocation processes, 14 semantic checks and 18 context-retention checks. The reused cell saved one 160-byte userdata per named wait after setup; captured/bound registrars still incurred their own closure, and a bare native ticket erased the one-object saving. Retaining stale fresh capabilities retained their 64 KiB contexts, while reusable numbered capabilities released them; exact result/rollback/stale/late-fatal tests are separate from those heap totals. The final canonical API measurements above, and the integrated native suite, are the final implementation evidence; prototype numbers are design-selection evidence only.

## Migrated client allocation sites

The final generated-C audit covers FS, net, OS, timer, io, and HTTP clients. It
counts direct lexical call sites, including conditional branches. These counts
are not per-operation totals: a named helper may allocate transitively, and a
string request may reuse an interned string. Module initialization, result
Arrays, public string copies, native request storage, and operation contexts
remain separate costs.

| Client path | Direct sites and remaining costs |
| --- | --- |
| Net close, DNS, connect, write, shutdown | The five named registrar/callback pairs create no closures, captured cells, or userdata directly. Callers still create operation contexts and native request owners. DNS completion constructs the result Array and requests its capacity. |
| FS operations | Named registrars/callbacks create no closures or userdata directly. `perform`, `acquire`, and `File:close_with` each construct an operation context. `File:write` and `stat` each retain a capturing begin callback and a conditional callable adapter for the imported decoder. |
| OS stdio write and close | Named registrars/callbacks create no closures or userdata directly. Write constructs an explicit context and owns its native request transitively. |
| Timer sleep | `sleep` directly constructs `ResumeToken` and `Sleep`, with no direct closure site. The native timer owner is transitive. Its fire and close callbacks create no closures or userdata directly. Ticker retains its separate subscription implementation. |
| HTTP terminal cleanup and handoff | Terminal cleanup retains one listener closure and one context. Handoff retains four source callbacks plus one conditional callable adapter. `Server:serve` has an ordinary handoff-context site and a cancellation-only reason site. |
| io forwarding | `InputOutputStream` read/read-until/write forwarding methods create no closures or userdata directly; their callees and stream construction remain separate. |

OS spawn still constructs its rollback machinery before attempting `uv.spawn`.
The whole spawn function contains eight closure sites and three mutable capture
cells. Four of those closures implement rollback; they and the three cells are
allocated even on successful spawn. The other closure sites cover the process
subscription producer and three conditional adapters. The rollback *execution*
path is cold; its construction cost is eager.

Twelve terminal callback checks confirm that native userdata and the context's
Completion reference are cleared before settlement. FS request cleanup and DNS
result cleanup retain their required ordering. All 1,923 non-initializer client
function bodies are byte-identical between the semantic and final optimized
builds. Six module initializer bodies differ, with unchanged direct allocation
category counts. The final audit independently checks the provider pair, exact
compile arguments, 21 generated-C files, 21 object files, 75 installed compiler
files, 67 recorded inputs, and 829 client function excerpts.

## TCP scratch retention

The separate Lua-host experiment runs six states at 0, 16, and 64 connected TCP
pairs: 18 fresh processes per provider. Only each client's reader is activated;
both the client and peer Connection records remain rooted unless the state
explicitly drops them. After the final callback, an `async.yield` and two full
collections precede the body snapshot. The final snapshot follows raw Runtime
teardown and another full collection. Connection arrays are used after that
snapshot to prove they remained reachable.

| State | Operations after pair construction |
| --- | --- |
| Unread | Neither endpoint starts reading. |
| Idle | Peer writes one byte; client consumes it and remains open. |
| EOF | Idle setup, then peer shutdown and client consumes EOF. |
| Closed | Idle setup, then public close on both endpoints. |
| Cleared | Idle setup, raw Runtime teardown, then closed-fast-path reads. |
| Dropped | Idle setup, raw Runtime teardown, then drop both Connection arrays. |

The candidate retains **65,632 Lua bytes per activated idle reader**: a 65,536
byte scratch buffer plus 96 bytes of owner/header overhead. Idle-minus-EOF live
bytes are identical at the body and final boundaries; idle-minus-cleared final
bytes confirms the same release after raw teardown.

| Activated readers | Buffer capacity | Measured buffer plus owner | Baseline idle-minus-EOF |
| ---: | ---: | ---: | ---: |
| 16 | 1,048,576 B | 1,050,112 B | 0 B |
| 64 | 4,194,304 B | 4,200,448 B | 0 B |

Raw Runtime teardown closes native handles without invoking the public
Connection cleanup path. A retained Connection can therefore retain its scratch
buffer after raw teardown. Consumed EOF, public close, a subsequent closed-path
read, or collection of the Connection releases it. Dropping all Connections
leaves no per-connection post-GC growth; both providers retain only the same
one-byte difference versus the zero-pair control.

This is a memory tradeoff, not a general memory reduction. With 64 idle readers,
the candidate's final live Lua heap is 5,895,204 bytes versus 1,662,540 bytes for
the baseline. The cache is bounded per activated reader; it is neither allocated
for every Connection nor a bound on queued public strings. Each queued data
string remains its own allocation.

The baseline and candidate use identical Lua executable/archive, allocator
probe, workload, and driver bytes. All 18 final samples passed with zero
allocator-ledger discrepancies, zero failed requests, empty stderr, and unchanged
recorded inputs; all 2,166 sealed prefix files remained unchanged. The probe
measures Lua allocator traffic and live Lua bytes, excluding native malloc and
native coroutine stacks. These instrumented single runs establish retention,
not throughput or latency. Results apply to this Linux x86_64 build.

## Behavioral validation

The allocation experiments do not replace behavior or ownership checks. The
frozen production inputs have these separate results:

| Lane | Result and scope |
| --- | --- |
| Linux optimized provider | All 26 native test roots: 630 passes, one expected POSIX exit-status skip, no failures. Disposable test objects use O0; the loaded provider is the measured O3/fat-LTO image. |
| Final shared-wake regressions | Two deterministic failure-and-retry cases added to the retained async ensemble; the rebuilt complete async root passes 60/60 against that same optimized provider. |
| Local Clang ASan/UBSan | 12 focused runtime selections: 297 passes and one expected skip, plus net/OS production smokes. Both supplementary shared-wake cases pass in fresh instrumented processes. This is the focused local lane; the full hosted sanitizer job is separate. |
| Local macOS x86_64 VM | Native aggregate: 627 passes and four platform skips; runtime/packaging: 154/154; compiler/language: 3,832 passes and one platform LTO skip across 144 files. Both optimized OpenSSL modes and static consumers pass, as do the two rollback supplements and source-free API/manual consumers. libuv remains the patched bundled build. |
| macOS universal archive | Real x86_64 and arm64 object/archive metadata lookup and repackaging pass. This does not establish arm64 runtime behavior. |
| Local Windows x64 VM | Both O0 and O3 providers pass publication and the complete 26-root native aggregate: 606 passes, 25 classified skips, no failures or portability skips. All test roots and native fixtures compile before execution. Each provider passes 55 source-free consumer/PE commands; O3 also passes three fresh-process domain selections and both shared-wake rollback cases. |

The local sanitizer configuration retains its previously established
OpenSSL-only `-fno-sanitize=function` exclusion; ASan and the other UBSan checks
remain enabled there and on Titan. Original failures, capacity-corrected runs,
compiler/provider identities and explicit platform exclusions remain in the
evidence. Public compiled consumers and source-only guards check the new
Completion API, existing facades, typed request data and documented examples.
Both manuals and affected skills describe operation-number and context-lifetime
requirements. The [pull request](https://github.com/mascarenhas/titan/pull/197)
records the final commit's Linux CI and coverage checks.

## Timing and latency

The predeclared comparison completed without a failed process, retry or policy change from 2026-10-04T03:33:16.371142+00:00 to 2026-10-04T03:37:26.691648+00:00. It retained **538 processes**: 124 body pilots, 40 body warmups, 280 body timing samples, 30 latency pilots, 8 latency warmups and 56 latency samples. Both immutable prefix audits passed (857 baseline files; 2,166 candidate files). These are observed results for the measured programs on this host, not a universal speedup claim.

### Host and measurement conditions

The host is an AMD Ryzen AI 9 HX 370 with 12 physical cores/24 logical CPUs, Linux x86_64 (Linux-7.2.7-ogc1.1.fc44.x86_64-x86_64-with-glibc2.43). Both lanes had affinity 0–23; no pinning, frequency or governor change was applied. The observed governor after the run was powersave; frequency boost was enabled. The 1/5/15-minute load averages were 2.21, 2.85, 4.08 before and 2.67, 2.88, 3.80 after. Coordinated local, macOS VM, Windows VM and sanitizer build/test/archive/transfer/hash/audit work was held idle; VMs and ordinary desktop/OS background processes remained running. The root confirmed the Windows guest and both audit helpers idle, with guest check at 03:30:40 UTC. Static CPU metadata was collected after the timed interval.

The two prepared consumers use identical current harness payload/helper bytes, matching Lua executable/archive and native tool identities, the same explicit environment policy and fixture, and their independently bound baseline/final optimized providers. Source imports are guarded; the per-lane absolute generated source path has been replaced with common relative spelling. Module setup and the initial full collection precede body timing. The allocation hook is disabled. Process CPU includes process threads but excludes child-process CPU; FS thread-pool work can therefore have CPU time greater than wall time. Raw command receipts include arguments, environment, stdout/stderr hashes and built-provider bindings.

For each workload/host, paired pilots selected one common count, followed by one warmup per lane and seven retained pairs in alternating AB/BA order. The 0.1-second body target and 1,000,000-operation cap were fixed before outcomes. No count or cap changed after retained samples. All original insufficient pilots and short retained samples remain in raw data.

### Body wall and CPU observations

Values are **µs per operation: median [minimum–maximum] across seven full-run observations**. Dividing each full-run clock by its common iteration count does not turn these into sampled per-operation latency percentiles. `B/C short` counts retained body samples below 0.1 seconds. `cap` marks the predeclared count limit, whether or not the target was met.

| Host / workload | Count | Baseline wall | Candidate wall | Baseline CPU | Candidate CPU | B/C short |
|---|---:|---:|---:|---:|---:|---:|
| lua / inline_success_nil | 1,000,000 cap | 0.619 [0.591–0.651] | 0.490 [0.470–0.501] | 0.614 [0.588–0.646] | 0.488 [0.468–0.498] | 0/7; 0/7 |
| lua / yield | 1,000,000 cap | 1.266 [1.224–1.295] | 0.573 [0.553–0.646] | 1.260 [1.219–1.288] | 0.571 [0.550–0.642] | 0/7; 0/7 |
| lua / yield_observed | 1,000,000 cap | 1.454 [1.416–1.488] | 0.819 [0.781–0.831] | 1.447 [1.410–1.481] | 0.814 [0.778–0.827] | 0/7; 0/7 |
| lua / fs_stat | 10,000 | 13.186 [9.885–14.805] | 13.034 [11.896–14.426] | 13.048 [9.815–14.295] | 12.831 [11.596–14.165] | 1/7; 0/7 |
| lua / fs_write | 100,000 | 8.142 [6.132–10.313] | 6.941 [6.169–9.482] | 8.163 [6.121–10.417] | 7.056 [6.079–9.630] | 0/7; 0/7 |
| lua / os_write | 100,000 | 2.368 [2.240–2.665] | 1.471 [1.416–1.558] | 2.351 [2.224–2.638] | 1.458 [1.400–1.537] | 0/7; 0/7 |
| lua / timer_sleep | 100,000 | 5.321 [4.931–5.661] | 1.870 [1.759–1.993] | 5.297 [4.912–5.635] | 1.862 [1.754–1.985] | 0/7; 0/7 |
| lua / subscription_next | 1,000,000 cap | 0.139 [0.132–0.156] | 0.141 [0.135–0.146] | 0.138 [0.131–0.155] | 0.140 [0.134–0.145] | 0/7; 0/7 |
| lua / cancel_queued | 10,000 | 28.690 [27.110–32.256] | 28.321 [27.442–32.263] | 28.303 [26.658–31.873] | 27.958 [27.090–31.897] | 0/7; 0/7 |
| lua / cancel_running | 10,000 | 28.800 [27.786–35.092] | 26.247 [25.964–26.506] | 28.484 [27.433–34.722] | 25.811 [25.512–26.080] | 0/7; 0/7 |
| typed / inline_success_nil | 1,000,000 cap | 0.698 [0.684–0.709] | 0.597 [0.574–0.642] | 0.695 [0.681–0.706] | 0.594 [0.572–0.638] | 0/7; 0/7 |
| typed / yield | 1,000,000 cap | 1.259 [1.184–1.282] | 0.511 [0.503–0.528] | 1.252 [1.178–1.275] | 0.508 [0.501–0.526] | 0/7; 0/7 |
| typed / yield_observed | 1,000,000 cap | 1.241 [1.223–1.284] | 0.634 [0.626–0.642] | 1.234 [1.218–1.277] | 0.631 [0.622–0.639] | 0/7; 0/7 |
| typed / fs_stat | 10,000 | 12.997 [9.343–13.534] | 12.430 [11.761–12.569] | 12.805 [9.262–13.650] | 12.214 [11.628–12.295] | 1/7; 0/7 |
| typed / fs_write | 100,000 | 7.498 [7.349–10.485] | 7.044 [6.681–7.436] | 7.574 [7.422–10.540] | 7.130 [6.756–7.458] | 0/7; 0/7 |
| typed / os_write | 100,000 | 2.219 [2.125–2.592] | 1.416 [1.259–1.806] | 2.202 [2.098–2.560] | 1.397 [1.237–1.786] | 0/7; 0/7 |
| typed / timer_sleep | 100,000 | 5.173 [5.034–5.364] | 1.785 [1.729–1.838] | 5.148 [5.008–5.337] | 1.777 [1.719–1.829] | 0/7; 0/7 |
| typed / subscription_next | 1,000,000 cap | 0.090 [0.089–0.108] | 0.090 [0.089–0.101] | 0.089 [0.089–0.107] | 0.090 [0.089–0.101] | 6/7; 6/7 |
| typed / cancel_queued | 10,000 | 29.297 [27.904–30.609] | 27.986 [27.192–31.290] | 28.832 [27.468–30.160] | 27.526 [26.756–30.842] | 0/7; 0/7 |
| typed / cancel_running | 10,000 | 39.992 [37.639–42.283] | 35.942 [34.091–36.848] | 39.528 [37.181–41.871] | 35.474 [33.646–36.382] | 0/7; 0/7 |

Quality exceptions are deliberately retained: Lua FS-stat baseline repeat 4 is 0.098848 s; typed FS-stat baseline repeat 7 is 0.093428 s. The typed publish/next control reached the 1,000,000 cap: six of seven samples in each lane were below 0.1 s (baseline 0.089120–0.107824 s; candidate 0.088923–0.101113 s). Its final baseline pilot was also short; the candidate pilot met the target. No stronger conclusion is drawn from that control. FS-stat and queued-cancellation ranges overlap substantially; the unchanged subscription workload remains a useful control. The table supports workload-specific observations, not the assumption that lower allocation must reduce every elapsed time.

### Explicit post-run GC observations

These clocks cover the single forced full collection after body/teardown and root drop. They do not count automatic collection cycles or measure total GC time during the body. Finalizable graphs can require another collection, as the separate cancellation control demonstrates. Values below are **milliseconds per full run: median [minimum–maximum]**, at the same counts listed above.

| Host / workload | Baseline GC wall | Candidate GC wall | Baseline GC CPU | Candidate GC CPU |
|---|---:|---:|---:|---:|
| lua / inline_success_nil | 0.663 [0.613–0.776] | 0.606 [0.582–0.855] | 0.663 [0.609–0.772] | 0.598 [0.576–0.850] |
| lua / yield | 0.641 [0.466–0.681] | 0.597 [0.543–0.713] | 0.635 [0.466–0.681] | 0.594 [0.540–0.710] |
| lua / yield_observed | 0.657 [0.639–0.752] | 0.923 [0.696–1.104] | 0.658 [0.634–0.748] | 0.919 [0.696–1.098] |
| lua / fs_stat | 0.710 [0.455–1.330] | 0.913 [0.563–1.040] | 0.707 [0.450–1.321] | 0.903 [0.558–1.030] |
| lua / fs_write | 0.767 [0.422–0.912] | 0.769 [0.685–0.969] | 0.767 [0.422–0.905] | 0.769 [0.680–0.960] |
| lua / os_write | 0.567 [0.516–0.684] | 0.604 [0.538–0.771] | 0.564 [0.509–0.685] | 0.595 [0.539–0.771] |
| lua / timer_sleep | 0.453 [0.419–0.936] | 0.598 [0.369–1.358] | 0.447 [0.413–0.896] | 0.594 [0.370–1.354] |
| lua / subscription_next | 0.482 [0.432–0.762] | 0.643 [0.464–1.283] | 0.482 [0.432–0.757] | 0.644 [0.461–1.270] |
| lua / cancel_queued | 0.844 [0.789–1.086] | 1.095 [0.982–1.426] | 0.836 [0.789–1.018] | 1.093 [0.980–1.424] |
| lua / cancel_running | 0.782 [0.658–1.032] | 1.115 [1.057–1.772] | 0.775 [0.655–0.944] | 1.109 [1.057–1.768] |
| typed / inline_success_nil | 0.609 [0.566–0.665] | 0.645 [0.540–0.880] | 0.605 [0.564–0.658] | 0.646 [0.540–0.875] |
| typed / yield | 0.610 [0.577–0.847] | 0.502 [0.467–0.594] | 0.606 [0.574–0.847] | 0.503 [0.467–0.589] |
| typed / yield_observed | 0.607 [0.444–0.651] | 0.674 [0.615–0.864] | 0.607 [0.444–0.643] | 0.671 [0.615–0.860] |
| typed / fs_stat | 0.834 [0.541–0.930] | 0.853 [0.742–0.934] | 0.830 [0.541–0.930] | 0.847 [0.733–0.929] |
| typed / fs_write | 0.589 [0.432–0.900] | 0.726 [0.674–0.841] | 0.579 [0.433–0.889] | 0.719 [0.674–0.836] |
| typed / os_write | 0.505 [0.381–0.570] | 0.600 [0.547–0.798] | 0.497 [0.381–0.562] | 0.592 [0.543–0.794] |
| typed / timer_sleep | 0.517 [0.442–0.611] | 0.582 [0.516–0.621] | 0.513 [0.443–0.607] | 0.580 [0.512–0.618] |
| typed / subscription_next | 0.644 [0.575–0.828] | 0.625 [0.580–0.695] | 0.639 [0.573–0.821] | 0.618 [0.580–0.690] |
| typed / cancel_queued | 0.819 [0.675–0.989] | 1.171 [1.062–1.656] | 0.815 [0.673–0.986] | 1.167 [1.058–1.475] |
| typed / cancel_running | 0.653 [0.484–0.956] | 1.063 [0.834–1.435] | 0.638 [0.484–0.949] | 1.061 [0.829–1.416] |

### Yield and timer latency

Each latency run samples elapsed time between consecutive resumption samples for each Task, alongside intervals between callbacks of one raw repeating 1 ms timer. Task samples from one run are combined to calculate that run's quantiles; the timer values are **interarrival intervals, not deadline lateness**. Native sample arrays are allocated before the clock starts; the same sampling calls and clock overhead are present in both lanes. These elapsed clocks start before Runtime/Task launch and stop at the collector's finish entry, after the loop and success check. They include Runtime/Task setup and teardown but exclude sample sorting and result-table construction, unlike the body-only timing table. The latency probe performs no forced GC.

The common pilot policy required at least 250 ms wall duration and 100 measured timer intervals in each lane, bounded by 1,000,000 iterations per Task and 4,000,000 total yield samples. Every retained latency run met both requirements. The 1-Task pilot reached the iteration cap with adequate quality; higher concurrency pilots stopped below their caps. Original pilots remain included.

The next tables show **the median [minimum–maximum] across seven per-run quantiles**; samples are not pooled across processes. The `max` column likewise summarizes each run's maximum and is not a single pooled worst-case maximum.

| Tasks / lane | Iterations per Task | Yield samples/run | Run wall s | Run CPU s | Timer intervals/run | Quality |
|---|---:|---:|---:|---:|---:|---|
| 1 / baseline | 1,000,000 | 1,000,000 | 1.248 [1.238–1.276] | 1.243 [1.231–1.267] | 1237–1275 | 7/7 adequate |
| 1 / candidate | 1,000,000 | 1,000,000 | 0.539 [0.528–0.558] | 0.536 [0.526–0.556] | 528–557 | 7/7 adequate |
| 16 / baseline | 64,000 | 1,024,000 | 1.178 [1.138–1.235] | 1.173 [1.133–1.229] | 1137–1234 | 7/7 adequate |
| 16 / candidate | 64,000 | 1,024,000 | 0.327 [0.315–0.338] | 0.326 [0.314–0.336] | 314–337 | 7/7 adequate |
| 64 / baseline | 16,000 | 1,024,000 | 1.250 [1.228–1.272] | 1.244 [1.223–1.266] | 1227–1271 | 7/7 adequate |
| 64 / candidate | 16,000 | 1,024,000 | 0.309 [0.302–0.344] | 0.307 [0.301–0.342] | 300–343 | 7/7 adequate |
| 256 / baseline | 4,000 | 1,024,000 | 1.678 [1.642–1.755] | 1.670 [1.634–1.746] | 1615–1706 | 7/7 adequate |
| 256 / candidate | 4,000 | 1,024,000 | 0.331 [0.321–0.346] | 0.329 [0.320–0.344] | 282–344 | 7/7 adequate |

Yield-resumption sample intervals, **µs**:

| Tasks / lane | p50 | p95 | p99 | Per-run max |
|---|---:|---:|---:|---:|
| 1 / baseline | 0.98 [0.97–0.98] | 1.35 [1.29–1.42] | 6.49 [5.80–6.91] | 470.18 [410.03–1345.47] |
| 1 / candidate | 0.51 [0.51–0.52] | 0.53 [0.53–0.73] | 1.04 [0.78–1.24] | 79.24 [60.87–121.91] |
| 16 / baseline | 14.95 [14.57–15.55] | 54.08 [52.40–54.93] | 64.68 [61.34–76.18] | 532.62 [444.87–1074.64] |
| 16 / candidate | 4.74 [4.72–4.76] | 7.53 [5.61–9.80] | 12.42 [9.79–13.10] | 94.40 [30.88–160.44] |
| 64 / baseline | 73.96 [72.97–75.14] | 153.32 [151.22–155.85] | 190.86 [183.75–241.49] | 844.91 [708.06–1003.49] |
| 64 / candidate | 18.19 [18.07–18.33] | 24.74 [22.54–38.43] | 39.03 [33.25–42.95] | 117.69 [75.18–239.13] |
| 256 / baseline | 393.25 [390.63–397.32] | 855.80 [751.50–960.66] | 1383.85 [1321.65–1551.90] | 4598.73 [2297.16–7207.74] |
| 256 / candidate | 77.97 [77.45–78.71] | 104.46 [94.28–161.50] | 128.05 [117.79–174.92] | 467.86 [372.11–776.29] |

One-millisecond timer interarrival intervals, **ms**:

| Tasks / lane | p50 | p95 | p99 | Per-run max |
|---|---:|---:|---:|---:|
| 1 / baseline | 0.9999 [0.9998–1.0000] | 1.0213 [1.0191–1.0247] | 1.0332 [1.0315–1.0419] | 1.1749 [1.0443–1.3964] |
| 1 / candidate | 0.9999 [0.9999–1.0000] | 1.0102 [1.0097–1.0113] | 1.0147 [1.0136–1.0160] | 1.0298 [1.0247–1.0652] |
| 16 / baseline | 1.0003 [0.9997–1.0008] | 1.0321 [1.0289–1.0334] | 1.0505 [1.0416–1.0585] | 1.2634 [1.1720–1.4370] |
| 16 / candidate | 1.0000 [0.9996–1.0002] | 1.0118 [1.0085–1.0139] | 1.0155 [1.0126–1.0218] | 1.0310 [1.0209–1.0820] |
| 64 / baseline | 1.0049 [1.0022–1.0092] | 1.0673 [1.0640–1.0728] | 1.0970 [1.0948–1.1276] | 1.2640 [1.1851–1.5660] |
| 64 / candidate | 0.9993 [0.9985–1.0016] | 1.0204 [1.0156–1.0259] | 1.0280 [1.0257–1.0466] | 1.0587 [1.0358–1.2278] |
| 256 / baseline | 1.0783 [1.0665–1.0849] | 1.4645 [1.3851–1.5857] | 1.8960 [1.8680–2.0371] | 3.6676 [2.3006–6.2050] |
| 256 / candidate | 1.0000 [0.9981–1.0037] | 1.0208 [1.0170–2.0026] | 1.0407 [1.0294–2.0180] | 1.1095 [1.0436–2.0818] |

One retained candidate run at 256 Tasks had timer p95 about 2.003 ms and p99 about 2.018 ms; it remains visible in the ranges above. The lower across-run medians do not remove that outlier.

These observations cover the uniform yielding workload and its one timer. They do not establish deadlines, starvation freedom for arbitrary workloads or a real-time guarantee. The full per-run wall/count/adequacy flags are present in the machine-readable summary; none are suppressed.

### Evidence and integration

`paired/PAIRED.json` preserves pilots, warmups, retained samples, repeat order, exact commands/receipts, environments and before/after host snapshots. `MEASURED-SUMMARY.json` contains full unrounded clock statistics, all per-run short/adequacy flags, latency quantiles, fixed policy and input/audit hashes. `results-issue196-with-timing.json` extends the current repository allocation/retention artifact and preserves its TCP section; `PORTABLE-BASE.json` records the exact base hash. All portable evidence references use basenames and hashes, with no machine-local absolute paths. `HOST-METADATA.json`, `LSCPU.json`, `QUIESCENCE.txt` and `COORDINATION-SUPPLEMENT.txt` retain the host and quiet-window records. No further timed workload is planned for this evidence set.

## Reproduction and evidence

The [portable measurement harness](../../spec/bench/async_allocations/README.md)
records build identities and runs allocation and uninstrumented comparisons.
[Machine-readable results](../../spec/bench/async_allocations/results-issue196.json)
retain the comparison quantities and raw evidence hashes. The measurements
describe the frozen provider above; subsequent documentation, harness and
regression-only changes do not alter its production inputs.

Local evidence (all original/superseded receipts are preserved):

- `FINAL-COMPARISON.json`: corrected complete comparison; baseline raw matrix `/tmp/titan-issue-196/measurements/baseline-matrix-1791074566.json`; final raw matrix `/tmp/titan-issue-196/measurements/final-matrix-1791082502.json`.
- `COPY-AUDIT.json`, `AFTER-CORRECTED-MATRIX-PREFIX-AUDIT.json`, source/SDK/compiler/generated/native manifests and `READY.json`: exact frozen build and immutable prefix correspondence.
- `titan-issue-196-completion-final/FINAL-COMPLETION-REPORT.json`, `MATRIX.json`, `SUMMARY.json`, `generated-c-survey/`: 48 final public-API processes and exact function/branch witnesses.
- `titan-issue-196-cancellation-retention/RESULTS.json`, `ANALYSIS.json`, `run-extra-gc.lua`: roots-dropped three-collection control and command receipts.
- `titan-issue-196-io-retention/PHASE3-FINAL-COMPARISON.json`, baseline `matrix-1791075349293702054.json`, and final `phase3a-final/matrix-1791081769480000610.json`: the TCP scratch experiment. The `tcp_retention` section of the linked JSON records their hashes and comparison quantities. Its private workload and drivers are `/tmp/titan-issue-196/io-retention/{retention.lua,run.py,matrix.py}`; the evidence bundle includes these exact sources and their input hashes.
- `titan-issue-196-generated-survey/final-optimized/`, `FINAL-CLIENT-C-AUDIT.json`, and the native ownership audit: function-scoped canonical C evidence.
- `titan-issue-196-portable-{baseline,final}-relative/BUILD.json`: current portable runner builds for the completed quiet timing run, same helper/payload/tool/Lua identities and source-only guards.
- `titan-issue-196-quiet-timing/{TIMING-REPORT.md,MEASURED-SUMMARY.json,paired/PAIRED.json}`: all 538 paired process records, exact inputs, full ranges, short-sample flags, host/VM quiescence, forced-GC scope and per-run latency quality.
