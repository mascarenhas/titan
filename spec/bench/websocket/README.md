# WebSocket benchmark preparation

Independent issue193 fixtures. Status: **final5 full allocation/lifetime matrix
397/397 complete; all397 Lua ledgers match independent heap bytes exactly**.
Fresh compilation/audit, allocator cleanup9/9, exact TLS failure replay and bounded
smoke68/68 passed. Full prefix audits are unchanged. Complete diagnostic history,
including the original checkpoint3 SIGSEGV, remains preserved. No timing/fairness
run has been authorized; instrumented clocks do not support timing claims.

All397 public endpoint weak references were absent after final release. Eight
GC-stopped rows deliberately held a closed endpoint through the first forced-GC
snapshot; 1000-message rows retained about69/71/152/154MB of Lua heap growth there.
A separately authorized eight-row second/third-GC diagnostic while endpoints
remain held is pending. Weak release alone does not classify that material
post-close observation. No ownership or queue-bound conclusion is inferred yet.

The previously failing raw TLS repeated-session row now passes against final5.
Six intentional errors exited1 after allocator restoration and three no-network
phase controls completed with exact heap accounting. This supports the harness
cleanup without proving the cause of the original crash.

Final5 is bound to verified provider/source/native receipts: five prefix keys,
98 production sources, 46 generated C/object files (22 production units plus
unused test support), 15 native inputs and exact compile argv. Direct site notes
exclude unused test support. The amended native-fixture receipt is diagnostic;
production/provider hashes remain unchanged and the accepted original b56 native
run is separately preserved. The current matrix scope is Lua allocation/lifetime
accounting. Timing/fairness and held-endpoint multi-GC classification are pending.

This directory is staged privately for owner integration into
`spec/bench/websocket/`. It makes no production changes and does not alter the
frozen 122-process issue196 matrix or its historical results. The authority is
the issue193 durable plan and [performance contract](https://github.com/mascarenhas/titan/issues/193#issuecomment-5976748176).

## Structure and measured topology

`bench.titan` is one private typed consumer of installed public APIs.
`peer.py` runs a separately supervised finite raw WS/TCP/TLS peer on loopback,
verifies outgoing masks, lengths, fragment types and bytes, and services controls.
Titan client rows measure masked writes and unmasked reads; Titan HTTP-handler
server rows measure unmasked writes and masked reads. WSS uses the checked-in
CA, certificate and key; both clients verify `localhost`. Server setup includes
HTTP listener/handler topology, while raw controls use TCP/TLS listeners.

`measure.py` imports hash/audit/tool/environment utilities from
`spec/bench/async_allocations/measure.py` without writing bytecode there. It
builds the existing `alloc_probe.c` and `latency_probe.c` read-only, and invokes
the existing source-fallback compile guard. It never builds/installs providers.
Snapshots archive private fixture source and hashes of the reused files.
The source guard admits exactly `./bench.titan`; imports must use compiled
modules. C consumers use `-O3`, the owner's native tool commands, and explicit
provider-matching link inputs.

Each subprocess saves argv, complete controlled environment, raw stdout/stderr,
exit/timeout status and input hashes. Peer process groups are killed and joined
on every exit. The prefix is fingerprinted before/after build and at batch
boundaries; selected provider/Lua identities and payload hashes are checked per
row. Output is forbidden inside the prefix, source checkout or harness source.
Certificates are copied into private output before compilation. No root outputs
or shared caches are written. Errors after probe startup stop the body if needed
and finish the probe before being rethrown, so Lua shutdown does not keep the
allocator callback pointing into an unloaded probe DSO. `cleanup_regression.py`
checks active-hook API and Task errors with both GC settings; failed runs emit
no successful allocation result. Its injected Tasks test the harness error path.

## Allocation and lifetime rows

`plan` emits **397 distinct processes**:

- WS/WSS and raw TCP/TLS, both endpoint roles, read/write, empty, 32-byte,
  4-KiB and 64-KiB payloads; WS rows include binary and text.
- 0/100/1000 operations, with a connected zero-work row per ordinary workload
  plus whole bootstrap/no-connection controls for every measured phase.
- Incoming 64-byte/16-KiB fragmentation, automatic Pong during reads, and
  application Ping with the required concurrent reader.
- Separate zero-operation setup and abort/graceful WebSocket teardown phases.
- 0/10/100 repeated complete sessions, explicitly labeled `sessions`, and
  selected GC-stopped rows with closed endpoints retained through post-GC.

Normal payload construction, module loading and role configuration precede the
probe. `setup` starts before scheduling the endpoint Task and stops after public
connection/handshake readiness. `steady` starts at readiness and stops after
the declared operations. `teardown` starts after operations and stops when
session retirement returns. Every row keeps accounting through Runtime drain,
releases the Task/status roots, then forces GC. Server session-body teardown
ends before the HTTP parent/listener drain, which remains in the probe's
after-close snapshot. The Lua callback bridge and sideband marker are fixture
overhead; report zero controls without hiding them. Repeated server sessions use
an exact listener-generation sideband to prevent reconnecting into the previous
listener before it retires. Session totals include that coordination overhead.

The unchanged allocator hook records successful requested Lua-byte traffic,
userdata/function/string/table counts, live/peak Lua bytes, after-close and
post-GC counters, and exact agreement with independent Lua heap totals. It
handles the `ptr == NULL` type tag and reallocations as in issue196. Forced-GC
cost is separate. Whole-process peak RSS is reported separately from Lua
counts. The hook excludes native allocations and coroutine stacks; RSS cannot
be decomposed into native-only bytes here.

`summarize.py` rejects incomplete or noninstrumented runs, reports both
`(count100-count0)/100` and `(count1000-count100)/900` slopes, preserves zero
rows, and prints after-close/after-GC snapshots. Instrumented clocks are never
used for timing claims. Raw receiving controls count the identical byte budget
through arbitrary chunks; they do not preserve message boundaries. Empty raw
operations intentionally perform no native I/O. Text payloads are ASCII `x`;
UTF-8 validation coverage is limited to that workload. Payloads are reused,
and small returned strings may be interned by Lua.

A weak table records the public endpoint. Optional strong retention keeps its
closed state reachable through post-GC; dropping that root and collecting twice
records whether the endpoint is collected. This tests endpoint reachability,
not every internal context or fragment root. Native ownership/finalizer tests
remain necessary; allocations and aggregate GC totals do not replace them.

## Quiet timing and buffered fairness

All compilation happens before an owner-agreed quiet interval. `timing` runs
uninstrumented consumers, calibrates one common count for the WS/raw pair until
both bodies reach 250 ms or the declared cap, labels/excludes calibration and
warmup, alternates pair order over seven repeats, and reports wall/process CPU
median/range and short-sample flags. Peer Python masking/validation and transport
flow control can constrain Titan wall time; peer CPU is excluded from Titan
process CPU. These are topology comparisons, not an isolated codec-cost proof
or a baseline/candidate regression study.

`fairness` preloads a declared finite 32-byte binary-message burst. A sideband
marker proves the peer finished submitting that burst before sampling. The
watcher can buffer transport input while the Titan Task awaits that marker;
the marker cannot identify TCP/TLS/WebSocket buffer partitioning. The reader
then runs without caller yields, alongside 1/16/64/256 yield-sampling Tasks and
a raw repeating 1-ms UV timer. The reused native probe uses preallocated arrays
to report per-Task yield-return intervals and timer interarrival p50/p95/p99/max.
Timer interarrival is not deadline lateness. Tracer/timer startup and terminal
drain contribute a small fixed sampling overhead. GC runs after the latency
snapshot. Calibration seeks 250 ms and 100 timer intervals, capped at 200,000
messages and the sample budget; insufficient/empty samples are explicitly
marked. Native sample arrays are overhead and contribute to process RSS.

This bounded submission profile does not establish queue bounds, stability
under indefinite producers, zero-copy messages, or starvation freedom for all
payloads. No such claim should appear in the results document.

## Running after owner readiness

The owner must first provide exact immutable provider/source identities and
confirm consumer compilation. `READINESS.example.json` is deliberately disabled;
copy it to private output and populate it from the owner's explicit confirmation.
The fields record an owner attestation; the harness cannot reconstruct or prove
provider/source correspondence from a manifest hash alone. Keep exact generated
provider C, native dependency/compile receipts and source manifest alongside it.
Use a fresh SSD-backed output, outside this source directory. This preparation
workspace is NVMe-backed btrfs; host `/tmp` is tmpfs.

```sh
python3 measure.py plan
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_harness.py
python3 measure.py build --repo "$TITAN_CHECKOUT" --output "$PRIVATE_OUTPUT" \
  --readiness "$OWNER_READY_JSON" --link-libraries "$PROVIDER_LINK_LIBRARIES"
python3 measure.py audit --repo "$TITAN_CHECKOUT" --output "$PRIVATE_OUTPUT"
```

For initial instrumented smoke/allocation work, the owner separately sets
`allocations_ready` after correctness and exact frozen-provider readiness.
That signal can permit allocation accounting on a busy host; its clocks are
not used for timing claims. The owner must also supply a quiet-window JSON
(disabled example provided) for uninstrumented timing/fairness, with start/expiry
epoch seconds and a note about VM and build/test activity. Each timing/fairness
row checks that window and archives host process/load snapshots without unrelated
command arguments. The runner cannot inspect activity inside VMs.

```sh
python3 cleanup_regression.py --repo "$TITAN_CHECKOUT" --output "$PRIVATE_OUTPUT"
python3 measure.py allocations --repo "$TITAN_CHECKOUT" --output "$PRIVATE_OUTPUT"
python3 summarize.py "$PRIVATE_OUTPUT/allocations-EXACT_TIMESTAMP.json"
python3 measure.py timing --repo "$TITAN_CHECKOUT" --output "$PRIVATE_OUTPUT" \
  --quiet-note "$OWNER_QUIET_JSON" --transport wss --role client --operation write --size 65536
python3 measure.py fairness --repo "$TITAN_CHECKOUT" --output "$PRIVATE_OUTPUT" \
  --quiet-note "$OWNER_QUIET_JSON" --transport wss --role server
```

Run both roles over WS and WSS for fairness and selected timing workloads, and
archive final prefix audits. The full 397-process allocation/lifetime plan completed against final5
after the bounded smoke passed. Preserve those outputs; further runs require
the current owner directive and immutable identities. Diagnostic workloads compiled and ran on Linux. No benchmark run
has validated macOS or Windows; Windows is unsupported by the reused POSIX
probes. Do not infer platform support from the historical async harness.
