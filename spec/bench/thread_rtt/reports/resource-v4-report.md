# Issue #252: original versus resource-ownership baseline

**Measurement completed; final wake/join performance is not measured here.** The integrator ran the committed `f14260b4` frozen-v4 harness on the original and resource-ownership/pre-wake checkpoints. On the receipt date **2026-10-18 UTC**, the serial campaigns completed424 original rows,424 resource rows and848 alternating paired rows, covering all53 cases in both modes. The resulting **3,759,360 RTT samples**, command receipts and source/build evidence accompany this report. This is baseline publication, not a claim that the later shared-wake/actual-OS-join implementation is correct or faster.

## 1. Inputs and comparison boundary

| Identity | Original | Resource ownership / pre-wake |
|---|---|---|
| Source | `66d1aad63885246b42107b1131f1656a0386cc8b` | `resource-ownership-r3-74a02edbec731159` |
| Generated-code ABI | `2` | `2` |
| SDK / package / LSAPI | `0.6 / 0.6.0 / 1` | `0.6 / 0.6.0 / 1` |
| Profile | production | production |
| Raw decoder calling contract | `ordinary_consuming_value` | `native_consuming_slot` |
| SDK content-manifest SHA-256 | `d7905867300ce6517ba4764f27785cf7facc2c5ee065ed4d54882fed38cc1545` | `69d618aed7e0fad78000f736bb8a3e0f8173fbf24565d394d7a7bc4e6ff6859b` |
| Provider-binding receipt SHA-256 | `c3da3cfd417f6738620430b58e567b266bd9d56d0cc888b60a90a8210dac514e` | `7be82223bc57d44c67873735e33020ce171fcc0448b701c50a1f9d7141215876` |

The resource identity names an attested source snapshot, **not a Git commit**. Its exact production overlay SHA-256 is `74a02edbec7311595b8beb840a0060d01dde7c5f9600139c91e6f7838efdbc69`. Both checkpoints retain legacy per-wait async handles, detached worker retirement and known OS-join/pre-start proxy-early-terminal limitations. Worker-tail quiescence does not upgrade those contracts. Resource ownership correctness is not conditional on a speedup.

Resource ownership, cheap codec and direct-sync changes are compared together. The original raw helper uses ordinary consuming-value decode; the resource helper uses status-returning consuming-slot decode, saved Lua stack and a rooted result/error. Generated consumer bytes differ intentionally although authored harness bytes match. `BUILD.json` records each generated consumer hash. Neither this combined historical comparison nor a whole-workload endpoint contrast isolates only a wake/hook/retain cost.

Both SDKs retain their original installed Titan compiler. Later automatic-array-pointer/provider-handle lowering repairs are **not** silently installed. Installed compiler script/module hashes are in each complete `PREFIX-BEFORE.json` and `PROVIDER-RECEIPT.json`; canonical compiler source is in the original66d archive. A later corrected wake/join comparison needs common required compiler patches and affected-root/consumer/entrypoint rebuilds on both fresh lanes. ABI2/equal C flags alone do not establish compiler compatibility.

### Native and provider policy

- Same Lua executable SHA-256: `4ff90fc0bccfffb89db1198b3807b2731b1f95686967a42d13f9b78f6f5561ee`; same Lua archive SHA-256: `7decdb6e81469ca27cd6f8bc9f2eef0830c77dd6c5bc15cefc8a89fe1258f721`.
- Lua source `025bfc35df0885656de347fb7a7c377e90042a75`; original skill snapshot `9d33f87bcce2e00693adf550617b93f115ac6ad0` is archived separately. Skills are not runtime ABI/version changes.
- GCC16.2.1 (`20260819`, Red Hat16.2.1-2), matching resolved compiler/ar/ranlib hashes; system OpenSSL3.5.9, patched bundled libuv1.53.0, llhttp9.4.3, SQLite3.53.4 and LPegLabel1.6.2-1. Exact native policy/header replay maps remain in the receipts.
- Complete ordered source flags: `--std=c99 -O3 -Wall -Wno-unused-but-set-variable -Wno-unused-function -fPIC -g1 -flto=auto -ffat-lto-objects -fno-strict-aliasing`.
- External CPP: `-DOPENSSL_API_COMPAT=30000 -D_GNU_SOURCE`; extra CFLAGS: `-fno-strict-aliasing`; external link flags: `-lpthread -lrt -lssl -lcrypto`; source-line directives enabled.
- Uninstrumented consumers use unchanged installed providers. Instrumented consumers privately rebuild the complete26-root provider namespace from matching source, preserving original Native archive payloads. Real C compile argv, per-module LTO seeds, original/private provider and executable hashes and final link inspection receipts are retained.
- Probe C adds its recorded C11/diagnostic/no-builtin/fixed-seed policy, without disabling production optimization, debug information or LTO. Every scoped source edit is hashed; changed/unrecognized owners fail closed. ABI remains exactly2 and all existing versions are unchanged.

## 2. Raw evidence and reconstruction

The publication set is [the raw/source/provenance archive](resource-v4-evidence.tar.gz), [publication metadata](resource-v4-publication.json) and [all53-case paired timing/counter/overhead tables](resource-v4-tables.md). Archive size/member count/SHA-256 are recorded in the linked metadata; the final archive also includes a per-file hash inventory and relocatable path index.

Included: exact frozen harness, original source reconstruction archives and resource overlay, private authored source copies, BUILD/provider receipts/attestations/prefix manifests/native policy/compiler hashes, preserved smoke evidence, independent/paired raw and summary JSON, successful v4 command stdout/stderr/receipts and RTT TSVs. Rejected earlier attempts and built SDK/Titan-provider/executable/generated-object binaries are excluded. Tiny original third-party dependency-input rocks and licenses are included separately; these are build inputs, not a bundled SDK. SDK images remain parent-owned local build artifacts.

`EVIDENCE-FILES.json` inventories original file bytes/hashes. `RECORDED-PATHS.json` maps archived absolute recorded paths to archive/extraction-relative members, sizes and SHA-256. Raw JSON paths are **not rewritten**, preserving original hashes. Resolve a receipt/sample path through the index after extraction anywhere:

```sh
mkdir -p "$EVIDENCE"
tar -xzf spec/bench/thread_rtt/reports/resource-v4-evidence.tar.gz -C "$EVIDENCE"
# Read $EVIDENCE/EVIDENCE-FILES.json and RECORDED-PATHS.json.
```

Source reconstruction uses the three archives under `titan-issue252-baseline-attested/`: extract `source-parent.tar`, `source-lua-5.5.1_.tar` and `source-.agents_skills_.tar` into each fresh source root. Overlay `titan-issue252-abi2-prewake-production-r3.tar.gz` only into the resource root. Their exact archives/commits and authored-file hashes are bound by `SOURCE-ARCHIVES.json`, `SOURCE-BEFORE.json` and `SOURCE-AFTER.json`.

The archived builder scripts and `BUILD-COMMANDS.json` preserve actual SDK preparation/provider-build argv and environments. Relocate recorded source/prefix paths to fresh roots, **never over an attested SDK**. Install the archived four dependency rocks directly instead of rerunning the historical `pack` step against its old handoff prefix. Native dependencies/toolchain must match the recorded pins/policy; no offline native-source bundle or byte-identical rebuild on a different toolchain/path is promised. Generate a real provider receipt for a rebuilt SDK before building its harness. The [README receipt contract](../README.md#exact-run-recipe) remains mandatory.

The final archive is **24,146,556 bytes**,8,219 members; SHA-256 `4650fc5c4095117c1b4a73a71bc39a9e1998aeb08bc173d4359baadb916715b2`. Its8,217 recorded-path entries include the four exact original dependency packages (97,333 bytes total), not a surviving old SDK:

| Dependency input under `titan-issue252-baseline-attested/dependency-rocks/` | SHA-256 |
|---|---|
| `argparse-0.7.2-1.all.rock` | `40eb4f03902365a285d4da4f72b3d1299db206b325773757c9c32ca78e8a210c` |
| `inspect-3.1.3-0.all.rock` | `f3f14a251a39e938d527762a3ce1d0926b5840f408ab47a5831a96d3ff6ce0f0` |
| `lpeglabel-1.6.2-1.linux-x86_64.rock` | `7151b98621c9eaf56e4579e7e7e888a696cc6b747c3254714aacb9d574f30c23` |
| `luafilesystem-1.9.0-1.linux-x86_64.rock` | `7490345e0a4b75319cdf52bcefb70522b9542c3e1534cb40cec8dba79595fc84` |

The latter two contain original third-party shared-library inputs for this Linux/Lua platform. MIT notices are preserved under `third-party-licenses/`, including inspect's full source with its embedded license. They are not portable substitute libraries.

Source/SDK reconstruction commands, derived from the archived actual builder argv, follow. They describe a **new** reproduction, not an execution claimed by the report author. Set `EVIDENCE` to the extracted archive and `REPLAY` to a fresh absolute directory; use the recorded GCC/Lua/system-OpenSSL/native policy on Linux x86_64:

```sh
A="$EVIDENCE/titan-issue252-baseline-attested"
for L in original resource; do
  S="$REPLAY/$L/source"
  mkdir -p "$S"
  tar -xf "$A/source-parent.tar" -C "$S"
  tar -xf "$A/source-lua-5.5.1_.tar" -C "$S"
  tar -xf "$A/source-.agents_skills_.tar" -C "$S"
done
tar -xzf "$EVIDENCE/titan-issue252-abi2-prewake-production-r3.tar.gz" \
  -C "$REPLAY/resource/source"

for L in original resource; do
  S="$REPLAY/$L/source"
  PFX="$REPLAY/$L/sdk"
  (
    cd "$S" || exit
    unset ROCKS_TREE TITAN_ROCKS_ROOT TITAN_EXTRA_CPPFLAGS TITAN_EXTRA_CFLAGS
    unset TITAN_EXTRA_LDFLAGS TITAN_NO_LINE_DIRECTIVES LUA_PATH LUA_CPATH
    unset LUA_PATH_5_5 LUA_CPATH_5_5
    export PREFIX="$PFX" PATH="$PFX/bin:/usr/local/bin:/usr/bin:/bin"
    export TITAN_BUILD_PROFILE=production OPENSSL_MODE=system
    export OPENSSL_PKG_CONFIG=/usr/bin/pkg-config TITAN_ABI_VERSION=2
    export TITAN_JOBS=4 MAKEFLAGS=-j4 CC=/usr/bin/gcc AR=/usr/bin/ar
    export RANLIB=/usr/bin/ranlib TITAN_PROBE_CACHE_DISABLE=1
    /usr/bin/make luarocks || exit
    for ROCK in "$A/dependency-rocks/"*.rock; do
      "$PFX/bin/luarocks" --tree="$PFX" install "$ROCK" --deps-mode=none || exit
    done
    "$PFX/bin/luarocks" --tree="$PFX" --force-lock make --force \
      --deps-mode=none titan-0.6.0-1.rockspec || exit
  ) || break
done
```

The archived receipts, rather than those relocated commands, remain the authority for the measured images. Rebuilt SDKs need newly recorded source/native/header/compiler/build evidence and receipts, not copied old hashes. Then invoke the frozen harness's documented `build` command against each new matching source/SDK/receipt and a fresh output; after its full-catalog smoke gate, rerun the independent/paired recipe below. This removes the historical builder's old-prefix `pack` prerequisite without inventing bit-identical output or claiming checks were rerun.

### Exact measured commands

```sh
H=/tmp/titan-issue252-rtt-harness-frozen-v4
O=/tmp/titan-issue252-rtt-original-v4
R=/tmp/titan-issue252-rtt-ownership-v4
P=/tmp/titan-issue252-rtt-paired-resource-v4
Q=/tmp/titan-issue252-quiescence-resource-v4.md
TITAN_PROBE_CACHE_DISABLE=1 python3 "$H/measure.py" --output "$O" \
  --batches 2 --repeats 3 --instrumented-repeats 2 --scale 1 --seed 252 baseline
TITAN_PROBE_CACHE_DISABLE=1 python3 "$H/measure.py" --output "$R" \
  --batches 2 --repeats 3 --instrumented-repeats 2 --scale 1 --seed 252 baseline
TITAN_PROBE_CACHE_DISABLE=1 python3 "$H/compare.py" --baseline "$O" --candidate "$R" \
  --output "$P" --quiescence-note "$Q" \
  --batches 2 --repeats 3 --instrumented-repeats 2 --scale 1 --seed 252
python3 "$H/summarize.py" "$O/BASELINE-SUMMARY.json" --output "$O/TABLES.md"
python3 "$H/summarize.py" "$R/BASELINE-SUMMARY.json" --output "$R/TABLES.md"
python3 "$H/summarize.py" "$P/PAIRED-SUMMARY.json" --output "$P/TABLES.md"
```

Paired output must be fresh. Previous smoke BASELINE files were preserved as `SMOKE-*.json` before replacement. The runner appends logs/samples/audits without modifying SDK/source/build provenance; persistent Titan probes and ccache are disabled. Archived `titan-issue252-baseline-campaign-v4/EXECUTION.json` and command0–5 logs record all six exit statuses0. Actual command wall times were71.814s,72.500s and151.162s, with295.75s total wrapper time. These include setup/retirement/evidence work, not just body timing. Builds/smokes were not repeated during the quiet campaign.

| Archive member | SHA-256 |
|---|---|
| `titan-issue252-rtt-original-v4/BUILD.json` | `6ba8c24aa7c33d6fe9ab72d92f61cbbb63090de812dc15513ab74bfa4d90284e` |
| `titan-issue252-rtt-original-v4/BASELINE-RAW.json` | `ec1d3ab465f1423dc394d79251acdd50a901659c3f640a99ed488c81e6822b71` |
| `titan-issue252-rtt-original-v4/BASELINE-SUMMARY.json` | `c0a0687924d53224f58351bb168a178e1747f54b1f9ccc610c25b2c88a2a7446` |
| `titan-issue252-rtt-ownership-v4/BUILD.json` | `f6dd8d8c8c8f0661f0b4236eab4f8193a691119f4014dcbe44ba735099cae4fa` |
| `titan-issue252-rtt-ownership-v4/BASELINE-RAW.json` | `3f8eb44c57526f8d1f257f6f4e0b851a67f9e8bae92eecf8aba2cbc5596c366c` |
| `titan-issue252-rtt-ownership-v4/BASELINE-SUMMARY.json` | `51726d116275834cdc5ba04044ec3097369cf4f48fb29d64f68756225c1118cc` |
| `titan-issue252-rtt-paired-resource-v4/PAIRED-RAW.json` | `86000028e47677296de784e522d2faaa05f6c8f4d7d920aae8a87e5a913148d8` |
| `titan-issue252-rtt-paired-resource-v4/PAIRED-SUMMARY.json` | `e218a9360443c3fdf0279ad79cd5f052982015b1e289a98ad71825a7fa8367bf` |

## 3. Host, repetition and uncertainty

The archived operator note `titan-issue252-quiescence-resource-v4.md` has SHA-256 `b9c72ffcc73c966ea50d5828a35f96cd2c2f227b9a6161c6d3157097f718b483`. Host: AMD Ryzen AI9 HX370,12 cores/24 logical CPUs, Linux x86_64,1 NUMA node; affinity0–23 without pinning/policy changes. amd-pstate-epp/powersave, balance_performance EPP, boost enabled,605.264–5157.895MHz reported range: clocks were dynamic, not fixed. THP madvise;125GiB memory/48GiB available,16GiB zram/2.2GiB used at observation. Desktop/services and idle VMs remained running.

This was a **quiet-build interval, not exclusive host isolation**. Parent builds/tests completed beforehand; one-shot local/macOS/Windows process observations found no matching build/test processes. Windows CIM was denied and not used as proof. The operator prohibited new build/test work during measurement; before/after process/load snapshots are retained. One-shot VM observations are not continuous VM CPU telemetry. Dynamic clocks, scheduling, GC and idle-VM activity remain noise sources.

Original observations spanned03:22:44.970–03:23:55.318 UTC; resource03:23:56.764–03:25:07.775; paired03:25:09.805–03:27:37.003. Before/after1-minute loads were3.134→3.837,3.610→2.942 and2.942→3.191. Full snapshots remain available.

Each independent campaign has2 batches×3 primary repeats plus2 diagnostic instrumented repeats. The pair has6 genuine primary pairs/case and2 diagnostic pairs, randomized case order/seed252 and globally alternating lane order. Across campaigns each case has12 primary and4 instrumented observations per checkpoint. The linked tables use the **paired campaign**; independent campaigns remain separate, not invented extra pairs.

Primary body intervals across the three campaigns ranged0.515–4808.906ms. There is no automatic duration calibration or confidence/significance claim. Some microbench intervals are short, joins include expensive fresh thread/state lifecycle, and six pairs establish no universal bound. Percentiles are medians of per-run percentiles, **not pooled percentiles**. Instrumented timings are never substituted for primary timings or overhead-subtracted into unobserved results.

## 4. Protocol, topology and warmup

| Family | Executed contract |
|---|---|
|19 codec/clock/inspection controls|Separate encode/decode/raw round-trip,0/1/8/64-capture closures and complex signature; preallocated bounded samples.|
|6 same-state queue/clone cases|Common three fields for endpoint/8-byte/opaque/packed contrasts; endpoint functionality checked outside timing; sender_clone is separate.|
|9 SPSC cases|One isolated worker; scalar/record/opaque/carried endpoint; persistent, exclusive pool4 and fresh-reply protocols distinct;64KiB persistent versus endpoint-pool4 is a protocol contrast.|
|10 MPMC cases|Actual2p2c/4p4c isolated OS states; global1/4/16 credits independent of producer count; varied capacities, deterministic IDs, exclusive reply ownership and validated payloads.|
|4 directed waits|Full-sender admission/previous-packet release acknowledgement, FIFO identity and final drain; controlled empty-receiver availability, not all ordinary processing RTTs.|
|3 churn +2 joins|Fresh setup intentionally timed; close/cancel and separate ordinary/proxy-cleanup native waits; child cleanup gate prevents a silently completed cleanup path.|

Frozen source and successful receipts bind readiness to completed code paths: each MPMC consumer privately warms request/endpoint/reply codecs and collects before ready; each producer lane warms real exchanges and collects before its ready/release barrier. Tasks are precreated. The barrier expects `producers * in_flight + consumers` messages (4,10 or68). SPSC warm exchanges visit its single worker with local collections. The harness does not disable automatic GC.

This is guarded source-path/aggregate-barrier evidence, not independent per-state telemetry: frozen-v4 does **not** emit named worker-state/collector-mode records. No such counters are invented. Timers stop before ordinary endpoint close/worker retirement; cold first-use, warmup, retirement and two residual full collections have separate raw clocks. Churn/joins deliberately time their fresh lifecycle.

## 5. Selected primary observations

[All53-case tables](resource-v4-tables.md) and raw JSON preserve throughput, sample counts, p50/p95/p99 and ranges without exclusions. Representative rows below deliberately include both improvements and regressions. Units are microseconds; positive paired delta means resource took longer. Marginal and within-pair medians are distinct statistics.

| Case | Original / resource us/op medians | Paired delta median [range] | Batch0 /1 delta medians | Original / resource RTT p99 |
|---|---:|---:|---:|---:|
| `call_control` |0.053 /0.054|+0.002 [-0.026,+0.031]|+0.011 /+0.001|0.036 /0.031|
| `overhead_control` |0.066 /0.067|+0.001 [+0.000,+0.033]|+0.003 /+0.000|0.050 /0.045|
| `codec_scalar_roundtrip` |0.163 /0.532|+0.380 [+0.273,+0.488]|+0.380 /+0.356|0.250 /1.859|
| `codec_small_transfer_roundtrip` |2.401 /2.610|+0.268 [-1.199,+0.576]|+0.398 /+0.226|14.887 /13.916|
| `closure_roundtrip_cap0` |5.633 /2.931|-2.725 [-4.301,-1.671]|-2.719 /-2.730|53.215 /7.554|
| `closure_roundtrip_cap64` |152.208 /147.201|-4.940 [-15.015,+6.457]|-4.992 /-0.883|866.094 /852.488|
| `queue_real_sender` |4.320 /3.944|-0.538 [-4.384,+0.464]|-1.852 /-0.423|50.144 /43.186|
| `spsc_scalar_persistent` |5.782 /8.535|+2.430 [-1.824,+5.454]|+3.293 /+1.566|18.149 /22.286|
| `spsc_record_persistent` |17.987 /21.278|+3.194 [-5.110,+8.364]|+5.235 /+0.964|76.382 /103.609|
| `spsc_endpoint_pool4_reply` |21.001 /19.740|-2.143 [-6.398,-1.115]|-6.051 /-1.920|105.762 /103.880|
| `spsc_endpoint_fresh_reply` |14.289 /18.960|+2.497 [-0.795,+8.191]|+3.345 /-0.299|35.401 /40.627|
| `spsc_large64k_persistent` |24.363 /43.289|+12.250 [-1.915,+23.928]|+18.026 /+8.029|108.312 /183.298|
| `mpmc_record_inflight1_cap1_2p2c` |18.843 /22.498|+2.409 [+1.592,+6.129]|+2.337 /+3.286|41.197 /51.496|
| `mpmc_record_inflight4_cap4_2p2c` |5.440 /6.853|+0.665 [+0.031,+2.596]|+0.684 /+0.645|48.757 /49.533|
| `mpmc_endpoint_inflight16_cap16_4p4c` |3.642 /3.660|+0.287 [-0.486,+0.436]|+0.129 /+0.379|150.190 /133.389|
| `join_ordinary` |6768.378 /6741.122|-55.990 [-738.967,+1069.023]|+72.675 /-70.594|8299.215 /7782.505|
| `join_cleanup_cancelled_task` |42153.114 /45503.579|+1934.005 [-2668.820,+5122.328]|-818.632 /+2906.419|60467.568 /55474.107|

Cap0 closure round-trip is lower in all six pairs, while scalar raw round-trip and several application workloads are higher. The scalar contrast includes the raw decoder/packet-ownership boundary; neither isolates a wake change. SPSC record/large observations do not support a general application speedup. Ranges/batch differences matter. Fresh-versus-pool4 changes protocol, not only endpoint cost.

Historical MPMC RTT begins **after acquiring the in-flight permit**. Frozen-v4 has no per-producer credit-wait/progress series or consumer-share record; aggregate p99 cannot establish fairness or exclude starvation before that boundary. No final reusable-wake fairness acceptance is claimed.

## 6. Semantic counts and lifecycle

The integrator accepted all1696 completed rows with expected checksum/topology/count/sample/stderr/timeout policy and zero native lifecycle fields; all424 instrumented rows ran/passed calibration with zero slot exhaustion. Raw distributions preserve min/max/sample/truncation values. Ordinary and controlled cleanup join each recorded100 actual native suspensions in every instrumented full-count round, not merely observer async.join. Cancellation/nonunique notifications stay unavailable; cleanup is partial-exact, not a fabricated zero-latency wake.

Fast first-check successes, slow registration-entry attempts, successful registration rechecks, accepted native suspensions, selected notifications and nominal CancellationReason cancellations are separate. Counts include worker/control operations inside the body, not a per-role/closed/failed split. Waits can begin before timing and wake within it, so totals need not match.

Per-wait handles remain: representative SPSC record bodies initialize/request-close2000 async handles per1000 requests on both lanes. This is not a shared-wake reduction. Identities retire at real callbacks or actual successful owning-loop close, never a guessed subtraction. Libuv internal work-queue async births have no public close callback; their successful-loop retirements remain separately recorded. Failed/busy closes discharge nothing.

Channel/control births/destruction, native end-of-worker release, Lua-state balance, active async identities and pending probe owners are distinct. Parent accepted zero post-retirement balances. Interposed native signed block/usable-byte net deltas in the supplied full campaigns were also0, but remain a partial allocator ledger, **not complete retained-native-memory proof**. Worker-tail zero is native domain-ownership retirement, **not actual OS join**.

## 7. Allocation/copy, stages and overhead

Every-case accounting/stage/retirement observations remain in the tables/raw summaries. Counter tables select the actual upper-median body-time instrumented round; all rounds/lifecycle ranges/wake modes remain. Stage aggregation independently retains total samples and per-round availability/ranges/modes.

Representative scalar round-trip changed from1.001 to4.001 Lua allocation calls/op,48.032 to512.044 requested Lua bytes/op and104→128 requested native bytes/op. Cap0 closure round-trip changed100.012→54.008 Lua calls/op and5011.559→3147.385 requested Lua bytes/op while native requested bytes changed128→384. These are **whole-path** measured checkpoint contrasts, not isolated signature-hydration counts or pooling justification.

Copy totals cover interposed memcpy **and memmove**, excluding inlined/libc-internal/other copies. Inside/outside lua_Alloc describes callback execution context, not ownership. Actual total wire bytes remain null/unavailable; analytical reference sizes are not all-case wire/copy traffic. gc.count is Lua-managed live memory, not native allocation traffic.

Encode, queue/registration, post-dequeue decode, reply processing and exact waiter notification-to-continuation intervals overlap across threads. Wake includes scheduler/ready-queue time, not isolated kernel/libuv latency. Cancelled/failed/nonunique notifications have no attributed sample. Do not add medians or subtract independent workloads into synthetic RTT.

Combined private rebuild/probe/wrapper overhead is substantial and noisy. Paired per-case instrumented/primary ratios ranged0.801–2.522 on original and0.664–2.517 on resource; median-across-case ratios1.334/1.316 are descriptive, not workload-weighted. Ratios below1 are observed variation, not negative-cost instrumentation. SPSC record ratios were2.522/2.092; MPMC record inflight4/cap4 were1.649/1.366. overhead_control instrumented-minus-primary was0.022/0.021us/op; it is not subtracted. Instrumented rows remain diagnostic, not extra primary repeats.

## 8. Acceptance boundary

The original/resource baseline has actual full-catalog matched-input/raw/lifecycle evidence, **no prescribed speedup**, no general regression-free result and no final Thread/fairness approval. This report/raw set is intended for the focused publication commit before any final speedup claim; it asserts no release/tag/upload.

The corrected candidate still requires common-compiler fresh resource/wake lanes, updated exact shared-wake/native-retirement probes, bounded permit/progress/consumer fairness evidence, actual OS join before every proxy terminal and cancellation reason/error preservation. Full Linux/sanitizer/source-free, Windows NTFS and local x86_64 macOS gates are separate. The operator note's231 async/223 UV preparation passes are not full final-platform approval.

No descriptor cache/tag plan, decoder/deep-buffer redesign, native pooling, strict FIFO-completion promise or unmeasured creation-cost claim follows from these observations.
