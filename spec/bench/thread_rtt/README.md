# Cross-Thread RTT and Component Benchmark Harness

This developer harness supports the Issue #252 Workstream 2 baseline and later
matched performance comparisons. It owns its source copies, private providers,
executables, logs, and samples outside the repository and supplied SDK prefixes.
It adds no production telemetry.

This README is a procedure, not a measurement report. Failed historical builds
are failure receipts, not timings. A successful build or smoke does not establish
baseline repeatability, lifecycle correctness, or a speedup. Publish actual
results only after measurement, using [the report contract](REPORT_TEMPLATE.md).

The measured [original/resource-ownership baseline report](reports/resource-v4-report.md)
includes the full53-case tables and a self-contained raw/source/provenance archive.
It describes the pre-wake checkpoint and its known lifecycle/fairness limits,
not final corrected wake/join performance or platform acceptance.

## Checkpoints and Acceptance Order

1. Commit the baseline harness before switching the actual thread wait/spawn
   callers to the new wake/join design.
2. Measure the original pre-resource-table checkpoint and the **accepted
   resource-ownership correctness checkpoint** (Workstream 1 plus already
   implemented cheap-codec/synchronization changes), each against its own exact
   immutable source/production SDK pair. This is not final Thread correctness
   approval; resource-ownership correctness does not depend on a speedup.
3. Only after the committed harness and both measurements pass their baseline
   gate, cut over the actual thread callers/spawn implementation and compare
   that resource-ownership/pre-wake checkpoint with the final corrected
   wake/join candidate using the same harness and policy.

**Both the original and resource-ownership checkpoints use generated-code ABI
2.** Existing package/native versions remain unchanged; language-server API
stays 1. Distinguish checkpoints by source, provider, runtime, SDK, and native
input hashes, never an ABI-2/ABI-3 contrast. ABI equality is not source/provider
identity. Do not mix old providers with a new compiler or source tree.

The accepted resource-ownership/pre-wake checkpoint intentionally still has
legacy per-wait wakes, detached thread retirement, and the known OS-join and
pre-start proxy-early-terminal defects. Record those limitations in its report;
do not claim final Thread correctness or require the later join/proxy fixes as
a prerequisite to measuring this baseline. That would make the gate circular.
The joinable/prearmed-proxy/shared-wake cutover is gated by the committed
harness and original/resource-ownership measurements.

Actual OS join before proxy terminal status—including cancellation cleanup—is
mandatory for the **final corrected wake/join candidate**, with separate
production and platform proof. A finished flag or source-probed worker-tail
zero proves neither OS exit nor OS join; the tail probe establishes only the
end of benchmark-owned native work. Keep that quiescence evidence separate
from final join/terminal-ordering evidence.

The baseline gate requires reproducible raw observations, valid checksums,
all-state warmup, and native lifecycle quiescence. The later wake gate additionally
requires fewer handles and repeatable latency/throughput benefit without a
fairness or tail regression beyond measured noise. Codec microbenchmarks alone
cannot establish application RTT improvement, and unmeasured channel creation
cost must not be described as negligible.

### Compiler provenance between phases

The initial pre-wake body-performance checkpoints retain the compiler actually
installed in each immutable SDK. Later compiler/code-generation repairs needed
for correctness tests are not implicitly present in those checkpoints merely
because all builds still report ABI 2. Do not modify an attested SDK or the
frozen harness to retroactively apply such repairs.

Record installed Titan compiler script/module hashes, the exact compiler source
revision and patch set, and which provider roots, consumer, and entrypoint were
compiled with it. Equal ABI/version strings and native C flags do not establish
compiler compatibility. For a later isolated wake/join comparison, any required
compiler patches must be common to both lanes, with matching compiler inputs
and affected-root rebuild evidence. If they are not matched, disclose the
compiler change as another comparison boundary rather than attributing its
effect to the wake/join cutover. A selective root transplant must not overlap
the canonical 26-root provider.

## Measurement Lanes and Private Instrumentation

### Uninstrumented end-to-end lane

`measure.py build` creates `$OUTPUT/work/uninstrumented/bench` against the
unchanged installed provider, with `RTT_PROBE_WRAPPERS=0` and no linker wrapping.
Use this lane for primary throughput, loop time, and RTT results. Direct clock
sampling still has overhead: compare `call_control` and `overhead_control`, and
retain their observations rather than subtracting a guessed sampling cost.

Bounded sample/trace storage is preallocated before warmup and timing. Required
sample files/counts and truncation are acceptance checks, not optional output.
Automatic Lua GC remains enabled in primary measurements. Each steady-state
producer and consumer state must exercise its relevant encode/decode,
endpoint/control, and reply paths, collect locally, and reach readiness before
the measured release barrier. A ready signal alone does not prove that every
state warmed; shared-queue warmup may otherwise visit only some consumers.
Steady-state Tasks/workers are created before body timing. Churn cases
intentionally include fresh lifecycle work and are reported as such.
Record readiness/warmup/collector evidence per actual worker state; a shared
aggregate warmup count is not proof that every state ran those paths with its
collector enabled.

Timing stops before endpoint/channel close and worker join. Report cold
initialization, warmup, retirement, and the two post-retirement full collections
separately from the body. A historical public join/finished observation alone
does not prove detached native worker-tail quiescence, and worker-tail quiescence
alone does not prove actual OS join.

### Private semantic-probe lane

`$OUTPUT/work/instrumented/bench` uses a harness-owned copy of the **exact
matching provider source**. The build instruments audited branch owners and
rebuilds the complete 26-root standard-library provider, preserving its namespace
and the original `titan.a` Native object payload. It does not publish an
overlapping single-root thread provider, change the installed prefix, or
substitute a newly built native dependency payload.

The complete root set is `async`, `coroutine`, `fs`, `gc`, `http`, `io`,
`iteration`, `json`, `lua`, `math`, `net`, `os`, `path`, `peg`, `protobuf`,
`reflect`, `sqlite3`, `ssl`, `string`, `test`, `thread`, `timer`, `transfer`,
`url`, `uv`, and `websocket`. Retain the source/SDK binding receipt, source
fingerprints before and after private edits, probe-owner edit hashes, original
Native archive identity, all provider-build receipts, and final link evidence.
An unrecognized source anchor must fail, not fall back to a mutex-order guess.

The authored harness uses one private `raw_roundtrip` helper for raw codec
measurements. `measure.py` selects its calling form from the exact measured
`transfer.titan` declaration, **not the ABI number**:

- `codec_contract = ordinary_consuming_value`: the original provider's ordinary
  `decode_message(encode_message(candidate))` form;
- `codec_contract = native_consuming_slot`: the accepted provider's C-ABI
  `decode_message(state, slot)` form. The helper saves the Lua stack top and
  installs restoration before encoding, installs raw packet disposal, and
  passes the actual mutable raw-owner slot to decode. Native decode returns
  status without a native longjmp: `0` leaves one decoded value, positive
  status leaves one error value, and negative status identifies setup failure.
  On error the helper copies any error into a traced local before calling
  `raise_message_error`; on success it retrieves the decoded stack value.

Only this helper is specialized in the generated consumer. Both instrumented
and uninstrumented consumers within a checkpoint use that checkpoint's same
raw codec form. There is no substitution with a `Packet` benchmark and no
production compatibility shim. Both checkpoints remain ABI 2, but their
necessary raw calling-contract difference means generated consumer bytes are
not assumed identical. Publish `BUILD.json`'s `codec_contract` and
`generated_consumer_sha256` with the common authored payload hashes, and
disclose this difference when interpreting historical codec/ownership results.

On Linux ELF with GNU-compatible `--wrap`, the private probe also interposes
`malloc`, `calloc`, `realloc`, `free`, `memcpy`, `memmove`, `lua_newstate`,
`lua_close`, `uv_async_init`, `uv_async_send`, `uv_close`, `uv_loop_close`,
and `mco_yield`,
using the installed headers' exact C prototypes. Compare instrumented and
uninstrumented observations on the same cases to quantify the combined private
rebuild/probe/wrapper overhead. Instrumented timings are not the primary RTT
result and must not be overhead-corrected into an unobserved result.

The full-accounting build requires Linux/GNU wrapping. Unsupported platforms
must fail that build rather than emit zero-filled native counters. Separate
Windows NTFS and local macOS correctness gates do not make this instrumentation
portable, and Linux benchmark evidence does not establish platform correctness.

## Metric Meaning and Coverage

### Semantic waits and handles

Private source probes observe actual channel enqueue/dequeue results, waiter
registration, notifications, ordinary join, and the proxy's cleanup join. They
do not infer a slow path from a second mutex lock: endpoint retains, finalizers,
packet disposal, and terminal reconstruction also lock native domains.

Keep the emitted fast successes, slow-path attempts, registration-recheck
successes, actual suspensions, notifications, and cancellations distinct.
Closed/failed outcomes are excluded from successful fast/recheck counts, but
the current schema does not emit separate closed/failed counters.

Whole-body counters aggregate worker request receives, replies, and protocol-
control channels; they are not broken down by operation role or direction.
Ordinary/cleanup join suspension subcounts are reported separately. Do not
invent a per-role or closed/failed breakdown from those aggregate counts.
Operation-slot stage distributions cover only their stated bracketed calls,
not every operation included in the counters. Show that directed full/empty
waits and the controlled cleanup-join barrier actually parked in the intended
path; the observer's Task suspension is not a native cleanup-join sample.

Report body and whole-case async initialization, public close requests, terminal
close callbacks, and successful-loop-close retirements separately. Handle
identities and their owning loops are tracked from process birth, including
cold first use, through terminal retirement—not only while the body timer is
active. A cancelled operation retains its already-executed attempt/suspension
history.

Pinned libuv initializes its loop-internal work-queue async handle through
`uv_async_init`, but destroys it directly during successful `uv_loop_close`,
without a public `uv_close` callback. The probe therefore retires an identity
either at its real close callback or after its owning loop's **actual successful**
native close. Busy/failed loop closes retire nothing. This is an observed
lifetime boundary, not a guessed subtraction or suppression of real UV
allocations. The bounded registry publishes handle/loop/callback state together;
its private synchronization is part of instrumentation overhead. The
`active_async_handles` count must still be zero; neither loop close nor worker
quiescence substitutes for the final candidate's OS-join proof.

### Lua, native allocation, and copy traffic

- The Lua allocator wrapper is installed before a state's first allocation and
  remains owned through `lua_close`. Calibration checks Lua birth accounting,
  native allocation-cycle balance, post-close residuals, and slot exhaustion.
- Native allocation wrappers exclude calls made inside the Lua allocator and
  probe-owned storage. Host `gc.count()` checkpoints describe Lua-managed live
  memory only; they are not native allocation traffic.
- Native allocation and resource-lifetime ledgers must begin before any
  benchmark-owned channel/control setup. Interposed allocation balance is not a
  complete native resource oracle: retain channel/control balances and active
  native worker counts through quiescence, including native worker-tail release.
  That lifecycle ledger does not itself verify the production OS-join contract.
- `copy_traffic` counts symbol-interposed `memcpy`/`memmove` calls and bytes.
  Compiler-inlined copies, dynamic/internal calls that bypass interposition,
  and other copy mechanisms are outside its coverage. The inside/outside
  `lua_Alloc` split is callback execution context, **not** Lua/native object
  ownership.
- `analytical_reference_bytes_per_op` is a reference-size estimate, not actual
  per-operation serialized bytes or total copied traffic. Different hook
  envelopes, attachment indexes, changing varint widths, closure captures, and
  large-payload framing prevent treating one plain-record size as all-case wire
  coverage. Unknown actual wire totals stay unavailable, not zero.

### Overlapping stage intervals

Where a traced operation provides the necessary events, the probe samples
`sender_encode`, `queue_admission`, `wait_registration`, `receiver_decode`,
`reply_processing`, `req_one_way`, `reply_one_way`, and `native_wake`.
Publish exact source boundaries, sample counts, ranges/percentiles, truncation,
and availability with each stage. Queue-attempt intervals include their native
mutex/branch work; they are not a mutex-free queue cost.

Native notification-to-continuation attribution requires the **exact waiter
identity** and a causative successful notification. There is no process-global
last-signal fallback; one request in flight does not prove a single live waiter.
Cancelled, failed, duplicate, or otherwise ambiguous notifications cannot
become attributed samples. This interval includes scheduler/ready-queue delay,
not isolated libuv delivery time.

Stages overlap and execute on different OS threads. Never add their medians
into a synthetic RTT or infer wake/endpoint cost by subtracting separately
measured workload medians. Missing instrumentation, ambiguous attribution, and
zero samples mean unavailable coverage, not an observed zero-duration stage.
Preserve partial attribution labels rather than silently filling gaps.


## Case Catalog (53 Original Cases Across 5 Groups)

1. **`same_state_codec` (19 cases):**
   - `call_control`, `overhead_control`
   - `inspect_record`, `inspect_function`
   - `codec_scalar_roundtrip`
   - `codec_small_encode`, `codec_small_decode`, `codec_small_transfer_roundtrip`
   - `codec_wide16_encode`, `codec_wide16_decode`, `codec_wide16_transfer_roundtrip`
   - `codec_large64k_encode`, `codec_large64k_decode`, `codec_large64k_transfer_roundtrip`
   - `closure_roundtrip_cap0`, `closure_roundtrip_cap1`, `closure_roundtrip_cap8`,
     `closure_roundtrip_cap64`, `closure_roundtrip_complex_sig`
2. **`same_state_queue` (6 cases):**
   - Three-field queue records (`id`, `body`, `reply`):
     `queue_plain_bytes8`, `queue_opaque_hook8`, `queue_packed_hook8`,
     `queue_real_sender`, `queue_real_receiver`
   - `sender_clone` is a separate clone operation, not a matched queue record.
3. **`spsc_rtt` (9 cases):**
   - `spsc_scalar_persistent`, `spsc_record_persistent`,
     `spsc_opaque_persistent`, `spsc_endpoint_carried_persistent`
   - `spsc_record_pool4_control`, `spsc_endpoint_pool4_reply` (exclusive reply
     pool of 4)
   - `spsc_endpoint_fresh_reply` (per-request fresh reply channel)
   - `spsc_large64k_persistent`, `spsc_large64k_endpoint_pool4` (64 KiB payloads)
4. **`mpmc_rtt` (14 cases):**
   - Non-endpoint (`mpmc_record_*`) and endpoint (`mpmc_endpoint_*`) catalog
     pairs at `in_flight` 1, 4, and 16, with validation eligibility checked
     before any matched-component report:
     - `mpmc_record_inflight1_cap1_2p2c`, `mpmc_endpoint_inflight1_cap1_2p2c`
     - `mpmc_record_inflight4_cap1_2p2c`, `mpmc_endpoint_inflight4_cap1_2p2c`
     - `mpmc_record_inflight4_cap4_2p2c`, `mpmc_endpoint_inflight4_cap4_2p2c`
     - `mpmc_record_inflight16_cap2_4p4c`, `mpmc_endpoint_inflight16_cap2_4p4c`
     - `mpmc_record_inflight16_cap16_4p4c`, `mpmc_endpoint_inflight16_cap16_4p4c`
   - Directed full-sender admission-control and empty-receiver wait cases:
     - `wait_full_sender_record`, `wait_full_sender_endpoint`
     - `wait_empty_receiver_record`, `wait_empty_receiver_endpoint`
5. **`churn_and_join` (5 cases):**
   - `churn_close_parked_senders`, `churn_close_parked_receivers`,
     `churn_cancel_parked_waiters`
   - `join_ordinary`, `join_cleanup_cancelled_task`

`measure.py plan` is the authoritative catalog for the measured harness
revision. These original counts are `19 + 6 + 9 + 14 + 5 = 53`; retain every
original case. If the catalog changes, publish its actual count and additions,
not an inherited “48” or “53” label.

MPMC `2p2c` and `4p4c` mean actual isolated OS producer and consumer states,
not multiple producer Tasks in one host Runtime. The global 1/4/16 in-flight
credit budget is separate from those thread counts. Preserve request/reply
capacities, reply slots, record shape, and validation across each endpoint/
non-endpoint pair.

Only call a contrast matched after checking **all** those dimensions.
`spsc_endpoint_fresh_reply` versus `spsc_endpoint_pool4_reply` compares fresh
versus pool-four lifecycle protocols, with endpoints on both sides.
`spsc_large64k_endpoint_pool4` versus `spsc_large64k_persistent` changes both
endpoint carriage and reply protocol. Neither isolates endpoint transfer cost.
Persistent, exclusive pool-four, and fresh-reply protocols need separate report
sections. The full-sender directed cases measure admission/slot release, not
processing/reply of the newly admitted request. Report them as admission-control
samples even though they share the `mpmc_rtt` catalog group. Validate the
previous buffered item, identity/order, and final drain.

## Exact Run Recipe

Run from the repository root with Python 3 supporting `hashlib.file_digest`,
the matched installed Titan 0.6 / Lua 5.5 SDK, and Linux GNU-compatible native
tools (`cc`, `ar`, `ranlib`, `readelf`, and linker `--wrap`). Keep the host and
VMs free of competing builds during measurement.

### 1. Select immutable inputs and inspect the plan

Set these shell variables to actual owned inputs before using the commands:

| Variable | Required value |
|---|---|
| `RTT_ROOT` | Fresh absolute campaign directory outside the checkout, provider-source trees, and SDK prefixes; use separate child outputs below it |
| `ORIGINAL_PREFIX`, `ACCEPTED_PREFIX` | Separate immutable production SDK prefixes for the pre-resource baseline and resource-ownership correctness checkpoint before thread wake/join cutover |
| `ORIGINAL_SOURCE`, `ACCEPTED_SOURCE` | Immutable source roots that actually produced those providers, not the changing working checkout |
| `ORIGINAL_RECEIPT`, `ACCEPTED_RECEIPT` | Matching source/SDK build-binding JSON receipts described below |
| `ORIGINAL_COMMIT`, `ACCEPTED_COMMIT` | Full source revision identities; include exact file hashes for any uncommitted snapshot in the receipt |
| `BENCH_CC`, `BENCH_AR`, `BENCH_RANLIB` | Same native tool commands for both lanes; manifests record their resolved binaries/hashes |
| `PROVIDER_TITAN_CFLAGS` | Required complete ordered generated-C flag sequence: installed-driver defaults plus the original standard-library extra flags, not a partial `-O3` override; exclude CPP/include roots and compiler-added per-module random seeds |
| `LINK_LIBRARIES` | Matched link-library policy; the Linux default is `pthread,rt,ssl,crypto` |
| `QUIESCENCE_NOTE` | Existing nonempty dated note describing host/VM build quiescence, host policy, and campaign conditions |

The build **requires** `--provider-source`, `--provider-receipt`, and
`--titan-cflags` with the complete original generated-C flag sequence.
`--source-commit` is a descriptive label, not a substitute for the source and
receipt. The receipt is a JSON object with these five required top-level fields:

| Field | Exact content |
|---|---|
| `source_sha256` | Object mapping source-root-relative paths to lowercase SHA-256 strings, for every `.titan` or `.h` file recursively under `titan/` and `vendor/lpeglabel/` |
| `sdk_sha256` | Object mapping prefix-relative paths to lowercase SHA-256 strings for every regular SDK file; symlink entries are recorded separately by prefix fingerprints and are not regular-file map entries |
| `titan_cflags` | Complete ordered original generated-C flags, including defaults and actual standard-library extras; string exactly equal to `--titan-cflags`, not an optimization-only override |
| `build_evidence` | Nonempty original build/source-matching evidence, with immutable receipt/log references and hashes; preserve effective compiler/native/dependency flags and source revision identities there |
| `native_policy` | Nonempty canonical JSON object recording the original native compiler/toolchain, dependency/runtime policy, and the required nested fields below; use the same schema and matched native policy in both lanes |

Required fields inside `native_policy`:

| Field | Exact content |
|---|---|
| `titan_cppflags` | String of original external dependency preprocessing/include-selection flags; explicit empty string is valid for intentional system defaults |
| `titan_extra_cflags` | String containing the original source-module extra C flags, replayed in addition to preserved installed-driver defaults; explicit empty string is valid |
| `titan_ldflags` | String of original external dependency link/runtime-search flags; explicit empty string is valid for intentional system defaults |
| `titan_build_profile` | `"production"` or `"validation"`, exactly matching the installed SDK profile; use production inputs for the primary campaign |
| `emit_line_directives` | Explicit JSON boolean preserving the original source-line policy |
| `sdk_header_replay` | Exact map for installed `include/uv.h`, every header under `include/uv/`, `include/llhttp.h`, and `include/sqlite3.h`; each entry is an object containing `source` (original source-root-relative path) and `sha256` (SHA-256 of both original and installed bytes) |

The header replay must cover the complete pinned UV header inventory without
extra or missing entries, and all mapped paths must remain inside their
immutable source/SDK roots. Source/header bytes and the inventory are checked
before and after the private build. A header merely found on the current host
is not an acceptable substitute for the original installed-header receipt.

The installed compiler's defaults are preserved and its attested
`titan_extra_cflags` replayed. The compile guard checks the actual toolchain
descriptor and generated-C compile prefix against the complete expected flag
sequence plus recipe CPP/include inputs; it does not replace driver defaults
with `-O3`. The current attested production recipe uses this full sequence:

```sh
PROVIDER_TITAN_CFLAGS='--std=c99 -O3 -Wall -Wno-unused-but-set-variable -Wno-unused-function -fPIC -g1 -flto=auto -ffat-lto-objects -fno-strict-aliasing'
```

For that recipe, the corresponding receipt records
`titan_extra_cflags = "-fno-strict-aliasing"`,
`titan_cppflags = "-DOPENSSL_API_COMPAT=30000 -D_GNU_SOURCE"`,
`titan_ldflags = "-lpthread -lrt -lssl -lcrypto"`,
`titan_build_profile = "production"`, and `emit_line_directives = true`.
These are attested inputs, not portable defaults: use the actual matching
builder receipt and rebuilt SDKs, not earlier partial-flag/handoff artifacts.

`native_policy.titan_cppflags` and `native_policy.titan_ldflags` specify the
original **external dependency selection** flags, including relevant `-I`,
`-L`, and runtime search paths. Both keys must be present as strings; `""` is
valid when the original build intentionally used system defaults. Do not omit
them or reconstruct them from today's host defaults: a different OpenSSL
header/library selection is a mismatched build, even with identical
`--titan-cflags`.

The harness replays the source and external-selection policies for consumers,
native probe-header compilation, and the private full-provider rebuild.
Recipe-owned SDK, source, and LPeg include roots remain separate; GNU wrapping
is added only for the instrumented lane. The native probe inherits the complete
flags, then adds its explicit instrumentation-only C11 mode, diagnostics,
no-builtin policy, and fixed `rtt_probe` random seed. Do not silently drop LTO,
debug information, line directives, or the source-module extras.

Publish `source_compile_policy` and `native_compile_argv` from `BUILD.json`,
including actual verbose C commands, the private 26-root and `bench` per-module
seed inventories, and probe-only policy differences. Compiler-added per-module
seeds are recorded separately, not inserted into the common `--titan-cflags`
string. Retain the effective commands/environment to establish which external
headers and libraries were actually selected.

Obtain this receipt from the owner of the original SDK build and retain its
underlying evidence. Hashing an arbitrary source tree and installed prefix
together after the fact does **not** prove that the tree produced the provider.
The harness checks exact source/SDK maps and generated-C flag equality and
records `native_policy`; require matched native policy across comparison lanes.
Original build evidence supplies the source/provider correspondence that these
comparisons cannot infer.
There is no compatibility shim, version migration, or receipt field permitting
an ABI-3 provider.

```sh
python3 spec/bench/thread_rtt/measure.py plan
```

Save that output with the report. The default commands below select the full
catalog; `--cases` is for focused diagnosis, not a substitute for the full gate.

### 2. Build both lanes into fresh harness outputs

```sh
python3 spec/bench/thread_rtt/measure.py \
  --prefix "$ORIGINAL_PREFIX" \
  --provider-source "$ORIGINAL_SOURCE" \
  --provider-receipt "$ORIGINAL_RECEIPT" \
  --source-commit "$ORIGINAL_COMMIT" \
  --output "$RTT_ROOT/original" \
  --cc "$BENCH_CC" --ar "$BENCH_AR" --ranlib "$BENCH_RANLIB" \
  --titan-cflags="$PROVIDER_TITAN_CFLAGS" \
  --link-libraries "$LINK_LIBRARIES" \
  build

python3 spec/bench/thread_rtt/measure.py \
  --prefix "$ACCEPTED_PREFIX" \
  --provider-source "$ACCEPTED_SOURCE" \
  --provider-receipt "$ACCEPTED_RECEIPT" \
  --source-commit "$ACCEPTED_COMMIT" \
  --output "$RTT_ROOT/accepted" \
  --cc "$BENCH_CC" --ar "$BENCH_AR" --ranlib "$BENCH_RANLIB" \
  --titan-cflags="$PROVIDER_TITAN_CFLAGS" \
  --link-libraries "$LINK_LIBRARIES" \
  build
```

Use `--compiler-script /absolute/path/to/installed/titanc` only when a prefix
contains more than one compiler candidate; record the selected script hash.
Never point it at an unrelated checkout compiler. The build records commands
and link dependencies and rejects a dynamic Titan/Lua fallback rather than
assuming `--static` alone establishes interposition.

Do not reuse a failed output directory: choose a fresh one and retain the old
failure receipts. Build/run artifacts and helpers are fingerprinted; changing
the harness after building requires new outputs for both lanes.

### 3. Smoke the entire catalog in both modes

```sh
python3 spec/bench/thread_rtt/measure.py --output "$RTT_ROOT/original" smoke
python3 spec/bench/thread_rtt/measure.py --output "$RTT_ROOT/accepted" smoke
```

`smoke` uses 5% scale, one uninstrumented repeat and one instrumented repeat.
Inspect the actual plan count, completed rows, expected samples, checksums,
directed suspensions, calibration, and native lifecycle balance. These are
functional checks, not production performance numbers.

Smoke uses the `BASELINE-RAW.json` / `BASELINE-SUMMARY.json` filenames. Archive
them before the full campaign replaces those files:

```sh
cp "$RTT_ROOT/original/BASELINE-RAW.json" "$RTT_ROOT/original/SMOKE-RAW.json"
cp "$RTT_ROOT/original/BASELINE-SUMMARY.json" "$RTT_ROOT/original/SMOKE-SUMMARY.json"
cp "$RTT_ROOT/accepted/BASELINE-RAW.json" "$RTT_ROOT/accepted/SMOKE-RAW.json"
cp "$RTT_ROOT/accepted/BASELINE-SUMMARY.json" "$RTT_ROOT/accepted/SMOKE-SUMMARY.json"
```

### 4. Capture independent full campaigns and paired batches

```sh
python3 spec/bench/thread_rtt/measure.py \
  --output "$RTT_ROOT/original" \
  --batches 2 --repeats 3 --instrumented-repeats 2 --seed 252 \
  baseline

python3 spec/bench/thread_rtt/measure.py \
  --output "$RTT_ROOT/accepted" \
  --batches 2 --repeats 3 --instrumented-repeats 2 --seed 252 \
  baseline

python3 spec/bench/thread_rtt/compare.py \
  --baseline "$RTT_ROOT/original" \
  --candidate "$RTT_ROOT/accepted" \
  --output "$RTT_ROOT/paired-ownership" \
  --quiescence-note "$QUIESCENCE_NOTE" \
  --batches 2 --repeats 3 --instrumented-repeats 2 --seed 252
```

These are minimum independent-batch/repeat settings, not a guarantee that noise
is small enough. `compare.py` randomizes case order and alternates lane order
while retaining batch/repeat/mode pair keys and raw observations. It records
actual within-pair differences/ratios, their ranges, and independent per-batch
median differences separately from lane marginal medians. Keep those paired
observations and within/between-batch variation. Instrumented repeats are a
separate diagnostic series, not additional primary RTT rounds.
`--quiescence-note` is required and must name a nonempty operator-evidence file.

After the original/resource-ownership baseline measurements and harness commit
gate pass, build the final corrected wake/join candidate with the same `build`
command and policy, using its own `WAKE_PREFIX`, `WAKE_SOURCE`, `WAKE_RECEIPT`,
and `WAKE_COMMIT`:

```sh
python3 spec/bench/thread_rtt/measure.py \
  --prefix "$WAKE_PREFIX" \
  --provider-source "$WAKE_SOURCE" \
  --provider-receipt "$WAKE_RECEIPT" \
  --source-commit "$WAKE_COMMIT" \
  --output "$RTT_ROOT/wake" \
  --cc "$BENCH_CC" --ar "$BENCH_AR" --ranlib "$BENCH_RANLIB" \
  --titan-cflags="$PROVIDER_TITAN_CFLAGS" \
  --link-libraries "$LINK_LIBRARIES" \
  build

python3 spec/bench/thread_rtt/measure.py --output "$RTT_ROOT/wake" smoke

python3 spec/bench/thread_rtt/compare.py \
  --baseline "$RTT_ROOT/accepted" \
  --candidate "$RTT_ROOT/wake" \
  --output "$RTT_ROOT/paired-wake" \
  --quiescence-note "$QUIESCENCE_NOTE" \
  --batches 2 --repeats 3 --instrumented-repeats 2 --seed 252
```

Do not describe the ownership comparison as a wake-only improvement. Report
fewer initialized/closed handles, measured latency/throughput, and fairness/tail
behavior against paired-batch noise before accepting the final wake change.
The final candidate must also prove actual OS join before every proxy terminal
outcome, including cancellation cleanup, and the required cancellation policy:
reasonless native cleanup cancellation only if no child cancellation was
admitted, preservation of the host's original reason/error, and no overwrite of
an accepted child cancellation reason. Run the full final Linux, Windows NTFS,
and local macOS correctness/platform gates; benchmark worker-tail zero is not
that proof. None of these final-candidate requirements is claimed for, or made
a prerequisite to measuring, the legacy pre-wake checkpoint.

### 5. Generate tables, audit, and complete the report

```sh
python3 spec/bench/thread_rtt/summarize.py \
  "$RTT_ROOT/original/BASELINE-SUMMARY.json" \
  --output "$RTT_ROOT/original/TABLES.md"

python3 spec/bench/thread_rtt/summarize.py \
  "$RTT_ROOT/accepted/BASELINE-SUMMARY.json" \
  --output "$RTT_ROOT/accepted/TABLES.md"

python3 spec/bench/thread_rtt/summarize.py \
  "$RTT_ROOT/paired-ownership/PAIRED-SUMMARY.json" \
  --output "$RTT_ROOT/paired-ownership/TABLES.md"

python3 spec/bench/thread_rtt/measure.py --output "$RTT_ROOT/original" audit
python3 spec/bench/thread_rtt/measure.py --output "$RTT_ROOT/accepted" audit
```

For a measured wake campaign, render its `PAIRED-SUMMARY.json` with the same
`summarize.py` interface and audit its build output as well.

Complete [REPORT_TEMPLATE.md](REPORT_TEMPLATE.md) outside the source checkout
and publish it alongside the generated evidence. The renderer includes recorded
provenance, lifecycle ranges for all instrumented rounds, actual paired
differences, and separate component/payload-policy/protocol contrasts. Its
counter/traffic tables identify their representative round: the actual
upper-median body-time instrumented round, not an aggregate of all rounds.
Retain the full counter rounds and lifecycle ranges.

Generated sections still do not replace the completed report contract:
link the raw artifacts, document topology/per-state warmup and host conditions,
and supply the measured interpretation and remaining evidence limits. Do not
call tables alone a complete report. Percentiles in lane summaries are medians
of per-run percentiles, not percentiles of a pooled raw distribution.

The publishable artifact set includes:

- the completed report, exact plan/catalog, commands, selected case count,
  host/quiescence note and hash, and before/after campaign host snapshots;
- each lane's `BUILD.json`, `PROVIDER-RECEIPT.json`, `SOURCE-PROBES.json`,
  `PREFIX-BEFORE.json`, `PREFIX-AFTER.json`, and final `AUDIT-*.json`
  immutability result;
- original and private source manifests/snapshots, harness/helper hashes,
  private provider and original Native payload identities, compiler/runtime/
  Lua/native dependency identities, canonical native policy, effective flags,
  final link receipts, and `codec_contract` / `generated_consumer_sha256`;
- full `BASELINE-RAW.json` / `PAIRED-RAW.json`, summaries, all per-command
  JSON/stdout/stderr receipts under `logs/`, and required raw TSV samples under
  `samples/`, with hashes and artifact-relative links that remain usable after
  publishing the output tree;
- actual checksums/sample counts/truncation, semantic wait/handle counters,
  calibration, retirement and channel/control/native-worker balances,
  residual collection, copy/allocator coverage, and instrumentation overhead.

The report author must inspect every round, not only a representative
instrumented row. Preserve failures and unavailable metrics explicitly. A
successful process exit does not excuse missing samples, a checksum mismatch,
an unwarmed producer/consumer state, or native worker activity after retirement.

## Deferred Optimizations

Descriptor caches/tag plans, compact decoder metadata, deep/large-buffer
redesign, and native channel/packet pooling are not part of this harness
delivery. Reopen them only after a representative post-wake workload/profile
shows material cost and a targeted prototype demonstrates benefit. Preserve
nominal identity and state-local resolution for caches; sparse/merge/unknown/
malformed-field semantics for decoders; copy/reallocation boundary measurements
and exact single hook invocation for deep buffers; and explicit lifetime/
retirement semantics for any pooling proposal. Do not pre-justify these changes
with a microbenchmark or an unmeasured claim about creation cost.

