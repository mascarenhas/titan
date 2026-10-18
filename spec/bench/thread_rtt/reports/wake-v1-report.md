# Issue #252: matched pre-wake resource versus combined Thread wake/join

**Matched measurement completed on 2026-10-18 UTC. This is not a blanket speedup or fairness-improvement result.** The parent executed all **53 cases** using the same frozen final harness and common CPP2 compiler inputs: **848 paired rows**, including **212 calibrated instrumented rows**, and **1,879,680 RTT samples**. Two preserved full-catalog smokes add **212 rows / 23,500 samples**, not additional full-count timing rounds.

The paired median body-time delta is lower for the candidate in **17 cases** and higher in **36**; **26 cases** have opposite-sign batch median deltas. Native wait handle creation clearly falls, but allocation traffic shifts and end-to-end/p95/p99/progress results are mixed, with important regressions. No geometric-mean score, pooled cross-workload speedup, regression-free claim or generalized starvation/fairness bound is asserted.

Publication: [all53-case tables](wake-v1-tables.md), [raw/source evidence](wake-v1-evidence.tar.gz), [publication manifest](wake-v1-publication.json). The [original/resource baseline publication](resource-v4-report.md) is preserved unchanged and is a separate experiment, not a final wake measurement.

## 1. Actual comparison and immutable inputs

The baseline is `resource-prewake-cpp2-a40babf3ad2b33cf`, a content-attested resource-ownership/pre-wake snapshot, not a Git commit. Its actual legacy per-wait handles, detached retirement, complex-cancellation transport and pre-start proxy-early-terminal limitations remain intact. The candidate is `wake-final-cpp2-24a6a6e77dff36d9`, the final combined Thread source freeze **0B97**, measured with CPP2. ABI **2**, SDK/package **0.6 / 0.6.0**, language-server API **1**, and all existing version numbers are unchanged.

This intervention includes shared wake targets, actual OS joins/native retirement, integration with generic async retirement, direct cancellation payloads with separate request/result kind tags, sticky child-root reasons, pre-start outcomes, and Group's one memoized public proxy/owner Map with explicit setup retry and idempotent terminal accounting. It also includes the final pre-OS admission transaction: private spawn inserts into the existing Group Map before starting a worker and rolls membership/resources back under control ownership on failure; standalone spawn passes nil, without an extra Map, Task or public API. It is **not wake-only**. Historical baseline lifecycle zero does not confer these final semantics on the baseline.

Both measured images use the same common automatic-array-pointer and canonical-provider-handle compiler fixes (`coder/statements.lua` and `coder/module.lua`). The instrumented image privately rebuilds the entire official **26-root** provider namespace, not an overlapping selected-root substitute. Each uninstrumented image links its unchanged installed provider. Real compile/link argv, seed inventories, source probes and provider correspondence are archived.

| Recorded identity | Resource / pre-wake CPP2 | Combined wake CPP2 |
|---|---|---|
| Receipt SHA-256 | `a40babf3ad2b33cf5a614b47df3426e6fd9296516298137426f45276d0d5dbd1` | `24a6a6e77dff36d9570f76c82ad2a2b6d825eabb8c8456f924a0bea52552203d` |
| SDK content-map SHA-256 | `49c792e165dc84545ba1a865e60c7dfc9dafbaaaff1b60223b159490ae4e21c0` | `e8b0bbe9d73e20d0272d2e0138bfe675e2215a9037b10ffaf89caf55f0a61eb7` |
| Source-probe SHA-256 | `b30c3955aacd540c889e4d8abd8c90a43120fad4a96097937e479a91715ff9ca` | `480423cce1d313714b23d59422b5eb6178529df61ae09b4ec57a3f2d5c557b5d` |
| Extracted Native archive SHA-256 | `72e5da2181c176c64eb38d6573416bb2657b3f7eebda6420fb8c45e64c12c628` | `822b7ebdb3890aaf700faf72e3cc8efa957f426a8fee481138c8fc6df1644f5c` |
| Wait contract | `legacy_register_before_yield` | `shared_register_after_yield_prearmed_retirement` |
| Codec contract | `native_consuming_slot` | `native_consuming_slot` |
| Generated consumer SHA-256 | `5a9e13bbed374169451611b064461c6312e69724328fa8f968140beacbe2a00b` | `5a9e13bbed374169451611b064461c6312e69724328fa8f968140beacbe2a00b` |
| Installed provider archive | `ccb6892101bae22fa954c240b6cd060ad7900cebbba826904e02d4bbb8e83106` | `3e67b718e3b5a8b90aad99a7afa9986f3c0ab7fdb789c372bba67f2f4ac53894` |
| Installed shared provider | `0031fe44035b0a58a4db918c4b68ff6a3d27f599290043ee8e1089c4a317e211` | `c476b2fba29936e052f45f1bfd3b291ac2c173245fcca9d8e4f35085313935b1` |
| Private provider archive | `be10652a64eb0e5a4529e31004da2a832573747d68acb8864c3f3247e5631504` | `4134252b74bc63c27ddba1e5ec69f61dc23e7d40a0b046faaa4d85d7adc497f6` |
| uninstrumented executable | `165707faa63a973eaf175c0417dc007e65456312d9c7b42e999f727166d5a7d1` | `5b947f9427c169680c4e70d66409035a4ce7310be920a09584aa0dbd058e9b41` |
| instrumented executable | `1c0d85b48ac53ab341115ce30226bc99e73eb71fa1835517fe2ec0abbfaac67a` | `d2e720f74b2cb858bc52775b93aa438c1717426eb6fa758b184d99e64f34bb52` |

Baseline source/SDK: `/tmp/titan-issue252-prewake-cpp2/{source,sdk}`; candidate: `/tmp/titan-issue252-wake-final-cpp2-v1/{source,sdk}`. Complete provider receipts, installed compiler hashes, source inventories, header maps and prefix manifests are under `build/` and `campaign/` in the archive. The common installed `titanc` hash is `567bdf8984e6631a199b3feae238483a632af62aa9239a5864a93fb074ce03b4`; common compiler source hashes are `c324ee5d2ab0862df7ac3eb5acf90a37da9097cf9764758a1e5bf4b03926201f` (`module.lua`) and `d7d735e742116798a696e995455e8392055ea0d4b117fe4c4d2c435cde88b4e4` (`statements.lua`).

### Native/build policy

The recorded `native_policy` objects are equal: GCC **16.2.1 20260819 (Red Hat16.2.1-2)**, `/usr/bin/gcc`, `/usr/bin/ar`, `/usr/bin/ranlib`, system OpenSSL **3.5.9**, Lua source `025bfc35df0885656de347fb7a7c377e90042a75`, libuv **1.53.0+spawn-close-v1**, llhttp **9.4.3**, SQLite **3.53.4**, and LPegLabel **1.6.2-1@912b0b9e8641074408ffc2259e069b188e0c717b**. Source profile is production, line directives enabled.

- Full ordered generated-C flags: `--std=c99 -O3 -Wall -Wno-unused-but-set-variable -Wno-unused-function -fPIC -g1 -flto=auto -ffat-lto-objects -fno-strict-aliasing`.
- External CPP: `-DOPENSSL_API_COMPAT=30000 -D_GNU_SOURCE`; extra CFLAGS: `-fno-strict-aliasing`; external link flags: `-lpthread -lrt -lssl -lcrypto`; benchmark link libraries: `pthread,rt,ssl,crypto`.
- Runtime flags: `--std=c99 -O3 -flto=auto -ffat-lto-objects -Wall -Wno-unused-but-set-variable -Wno-unused-function -fPIC -g1`; libbacktrace: `-fPIC -g -O2`; rock-host native flags: `-O2 -fPIC`.
- Lua executable/archive: `4ff90fc0bccfffb89db1198b3807b2731b1f95686967a42d13f9b78f6f5561ee` / `7decdb6e81469ca27cd6f8bc9f2eef0830c77dd6c5bc15cefc8a89fe1258f721`.
- Shared SDK runtime Native base `libtitan.a`: `f8123ef431b4a854bc1473d1f35296a39a3159d85a25303e60c6dbb7d5f8152f`; libbacktrace archive: `e134dff116b6441f9171bb6182897a1b9ddd87caf644b3d3b6a125ec4920fe01`.
- The private C probe inherits production flags and adds its recorded C11/diagnostic/no-builtin/fixed-seed options. Module/root and `bench` random seeds and actual native argv are retained separately.

The two **extracted** `original-native.a` hashes in the table differ. Shared attested SDK runtime/Lua/native-base inputs do not imply byte equality of these per-provider extracted containers. Both recorded identities are preserved; this report does not replace them with one claimed hash. UV/llhttp/SQLite SDK header replay maps and before/after inventories remain in the receipts. Installed/private provider and executable binaries are identified by hashes but excluded from this source/raw publication.

Both lanes use `native_consuming_slot` and the same generated consumer hash. The historical ordinary/native raw-helper difference is therefore not introduced between these two lanes; it still prevents silently pooling older harness phases.

### Measured CPP2 versus final delivered v3

The archived parent equivalence receipt records **121,249 identical normalized `bench.c` lines** and all **26 stdlib modules** identical except one cosmetic declaration in `os.c` line47739: `int volatile _spill_local_duplicate_1` versus `volatile int _spill_local_duplicate_1`. It covers the post-CPP2 borrowed-pointer spill fixes in `flow.lua`, `names.lua`, `statements.lua`, `values.lua`, and the conditional minicoro ASan stack-bounds guard. The measured source remains CPP2; it is not relabeled v3.

Both the exact measured **90-file v1 overlay** and the supplied final **51-file v3 delta**, plus both full source inventories and the v3 SHA manifest, are included. The supplied manifests identify exactly those51 changed/new files and no v1 deletions. Code-generation equivalence supports relevance to the delivered changes, **not** an independently rerun v3 performance campaign, whole-binary identity or sanitizer/platform result. Other final-v3 doc/test changes remain explicit in that overlay.

## 2. Raw evidence, commands and reconstruction

The archive is **45,549,260 bytes**, **5,031 members**, SHA-256 `8fe59cac8ad99657789b10631b8a66a4cc72809230a3b4896b88729aea5f5ca8`. Its **5,029 payload entries** are indexed by `EVIDENCE-FILES.json`; **5,020 recorded file paths/URIs** map to extraction-relative members in `RECORDED-PATHS.json`. Original raw JSON/TSV/log bytes and paths are not rewritten. Resolve a recorded receipt/sample path through this index after extracting anywhere.

Included: all paired/smoke/summary records and TSVs, all final-lane logs/stdout/stderr and build receipts, prefix/source audits, scoped private authored sources, exact frozen harness, original/source/CPP2/v1/v3 reconstruction inputs, approved dependency rocks/licenses and codegen-equivalence receipt. No Titan SDK, provider, executable or generated-object output tree is substituted for authored source. The v1 overlay includes the immutable old publication artifacts because those bytes are part of its1157-file authored inventory; none of the committed `resource-v4-*` files was modified.

| Archive member | SHA-256 |
|---|---|
| `campaign/paired-wake/PAIRED-RAW.json` | `d1a65e07d077901a67c49c60e832de144b5d54f1cd2ee88a3724a95728c3ad40` |
| `campaign/paired-wake/PAIRED-SUMMARY.json` | `348bd3e1e80df430bbab33181742d42d433f3deb53eba4fa4068563695b3191e` |
| `campaign/QUIESCENCE.txt` | `acd0cda2e94ef8ca5578b2b5c6a76e9fb14f2da6c84a3419b7c0665930aa7114` |
| `source-inputs/titan-issue252-final-measured-cpp2-v1-overlay.tar.gz` | `10fd531513b33ecadc1f2226950eb906f2e69fd8d8b8d2ad46774b1313145c0d` |
| `source-inputs/titan-issue252-final-corrective-abi2-v3-delta.tar.gz` | `06fd5e8fe39b44156094738ff724b43007f79179c0fe46481e13ccd68d0f7690` |
| `source-inputs/titan-issue252-final-corrective-abi2-v3.source.sha256` | `f0f8219f95c8115118c54c94fa593f2e494c4205d47dd7e6d87e636b514ac5f6` |
| `source-inputs/titan-issue252-cpp2-vs-v3-codegen-equivalence.json` | `9f7ed1032a78513b7663d450acba236b5031ae97c7412d1ef44cd62bf5f5090a` |

```sh
mkdir -p "$EVIDENCE"
tar -xzf spec/bench/thread_rtt/reports/wake-v1-evidence.tar.gz -C "$EVIDENCE"
# Read SOURCE-RECONSTRUCTION.md, EVIDENCE-FILES.json and RECORDED-PATHS.json.
```

`SOURCE-RECONSTRUCTION.md` supplies fresh-root extraction/build instructions without borrowing an old SDK. It layers original66d, Lua025b, skills9d, resource-r3 and common CPP2 inputs, then the actual measured v1 overlay and its exact obsolete-test-file deletion. Apply v3 only to a separate copy of that candidate. Native pins/toolchain/system OpenSSL and newly recorded source/SDK/header/build receipts remain required; an offline native-source bundle or path-independent bit-identical rebuild is not claimed. Four exact licensed dependency rocks total **97,333 bytes**; two contain approved original third-party `.so` build inputs, not Titan provider outputs.

Effective parent campaign arguments (exact per-run argv/environments are in the receipts):

```sh
H=/tmp/titan-issue252-rtt-harness-final-v1
R=/tmp/titan-issue252-rtt-final-cpp2-v1
python3 "$H/compare.py" --baseline "$R/final-resource" --candidate "$R/wake" \
  --output "$R/paired-wake" --quiescence-note "$R/QUIESCENCE.txt" \
  --batches 2 --repeats 3 --instrumented-repeats 2 --seed 252
python3 "$H/summarize.py" "$R/paired-wake/PAIRED-SUMMARY.json" \
  --output "$R/paired-wake/TABLES.md"
```

The parent executed the campaign and supplied the tables; the publication author did **not** run those commands. `MEASUREMENT-COMMANDS.json` also preserves the frozen build/smoke/audit contract and actual build configurations. `CATALOG.json` is derived from executed summary metadata, not an extra claimed plan run.

## 3. Host, repetitions and uncertainty

The actual paired interval is **22:27:27.065849–22:30:05.257211 UTC**, **158.191362s**, on Linux **7.2.8-ogc5.1.fc44.x86_64**, x86_64/glibc2.43, with24 visible CPUs and affinity0–23. Two independent randomized batches contain three alternating-lane uninstrumented repeats each: **318 rows per lane**. Two separate instrumented repetitions add **106 rows per lane**, not extra primary RTT rounds. Scale1, seed252, no catalog exclusions.

The dated operator note at22:26:50 states zero active local build/test background jobs, completed GCC/Clang-ASAN work, and finished/idle Windows NTFS and local macOS validation. It records load averages **22.48 /14.39 /9.28**; raw campaign snapshots record **13.4204 /13.0552 /9.0469** before and **6.2476 /10.0181 /8.5015** after. Thus “quiet” means a build/test exclusion interval, **not** low prior load, isolated cores or an exclusive host. Before/after process snapshots are retained, not continuous VM/CPU telemetry.

The final note/snapshots do not recapture CPU model, governor/EPP/boost/frequency policy, memory/THP or VM utilization continuously. The older resource-v4 host inventory is historical context, not silently substituted for final-campaign observations. Fixed clocks/pinning cannot be inferred. Scheduling, recent load, frequency changes, GC and residual desktop/VM activity remain uncertainty sources. Two batches expose disagreement; they are not a statistical confidence interval.

Each lane's `BASELINE-RAW/SUMMARY.json` currently contains the same **scale0.05, one-repeat106-row smoke** also preserved as `SMOKE-*`. They are **not independent full-count baseline campaigns**. The full-count comparative evidence is `PAIRED-*`. All **1,060** published measurement receipts exit0; all53 paired checksums match; no RTT/stage truncation is recorded. The publication did not rerun failed historical checks or any software verification.

## 4. Protocol, topology and warmup

| Family | Actual fixture contract |
|---|---|
|19 codec/clock/inspection controls|Encode/decode/raw round-trip, scalar/small/wide/64KiB payloads, 0/1/8/64-capture closures and complex signature; bounded preallocated samples.|
|6 same-state queue/clone cases|Common three-field endpoint/8-byte/opaque/packed contrasts; endpoint functionality outside timing; sender clone is a distinct operation.|
|9 SPSC cases|One isolated worker; scalar/record/opaque/carried endpoint; persistent, exclusive rotating pool-four and fresh-reply protocols remain distinct.|
|10 MPMC cases|Actual2p2c or4p4c isolated OS producer/consumer states; global1/4/16 reply-credit budget, independent of OS-thread count; P×F producer Task lanes, exclusive reply-slot permits and deterministic validated IDs.|
|4 directed waits|Controlled empty-receiver readiness or full-sender admission/previous-packet release acknowledgement, validated identity and final drain; not ordinary processing RTT for the newly admitted request.|
|3 churn +2 joins|Intentionally time fresh lifecycle/cancellation work; ordinary/proxy-cleanup waits separated, with a child cleanup gate preventing an already-finished “cleanup” path.|

For steady-state MPMC, every consumer privately warms request/endpoint/reply codec paths and collects before readiness; every producer lane performs real exchanges and two collections before its ready/release barrier. Readiness expects `P*F+C` signals (4,10 or68). SPSC warm exchanges reach its isolated worker with local collections. Tasks/workers and both-mode request storage precede body timing; automatic GC is not disabled. Frozen source/validated barriers and raw warmup clocks support this, **not independent named per-state collector telemetry**, which the schema does not emit. Cold initialization, warmup, retirement and two residual collections remain separate clocks. Churn/joins deliberately include fresh lifecycle work.

Endpoint-versus-record, payload-policy and application-protocol contrasts remain separate generated table sections. Fresh versus pooled/persistent reply channels and large64KiB endpoint-pool4 versus persistent replies change protocol/lifecycle as well as representation. Those contrasts do not isolate a retain, wrapper, hook or endpoint-transfer cost.

## 5. Primary uninstrumented observations

Units below are microseconds. Baseline/wake entries are **medians of per-run values**, including RTT percentiles—not percentiles of a pooled distribution. Paired delta is wake minus baseline for the six actual `(case,batch,repeat)` pairs; positive is slower. Marginal lane medians and paired median deltas are different statistics. Full p50/p95/p99, throughput, ranges, clocks and all53 rows remain in the linked tables/raw records.

| Case | Baseline / wake us/op | Paired delta median [range] | Batch 0 / 1 delta medians | Baseline / wake RTT p99 us |
|---|---|---|---|---|
| `spsc_record_persistent` | 18.0380 / 15.8619 | -4.0425 [-5.5123, +2.7868] | -3.6024 / -4.5692 | 107.061 / 48.425 |
| `spsc_endpoint_carried_persistent` | 21.8715 / 23.3469 | +1.3998 [+0.0724, +6.7005] | +2.2056 / +0.2598 | 115.816 / 133.319 |
| `spsc_endpoint_pool4_reply` | 22.2026 / 21.8078 | -0.7646 [-6.2906, +0.9902] | +0.0078 / -1.5370 | 141.034 / 116.918 |
| `spsc_endpoint_fresh_reply` | 17.6146 / 16.7936 | -0.2781 [-8.7444, +1.7569] | +0.8840 / -4.0015 | 44.353 / 30.261 |
| `spsc_large64k_persistent` | 38.5768 / 35.8575 | -2.0563 [-10.4348, +8.4017] | -9.2218 / -1.6124 | 192.945 / 181.144 |
| `spsc_large64k_endpoint_pool4` | 39.2684 / 37.9745 | +4.0261 [-9.1545, +13.9782] | +5.6071 / -6.4433 | 146.303 / 199.322 |
| `mpmc_record_inflight4_cap1_2p2c` | 6.7439 / 5.8047 | -0.7396 [-1.3931, -0.0275] | -0.3803 / -0.8727 | 63.218 / 61.921 |
| `mpmc_record_inflight16_cap2_4p4c` | 3.5153 / 4.8478 | +1.4528 [+0.4875, +3.0523] | +0.6991 / +1.8132 | 204.091 / 327.337 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 18.8597 / 20.5438 | +1.9836 [-4.8736, +2.5691] | +0.5725 / +2.4104 | 42.804 / 56.266 |
| `wait_full_sender_record` | 34.0717 / 38.7445 | +4.1677 [-4.3561, +7.8302] | +4.9132 / +1.4632 | 313.822 / 374.289 |
| `closure_roundtrip_cap1` | 6.7337 / 5.6439 | -0.7610 [-3.4554, -0.1416] | -3.4033 / -0.3379 | 67.025 / 48.130 |
| `queue_packed_hook8` | 5.0195 / 6.8118 | +1.5151 [-0.1951, +5.1013] | +2.3840 / +0.6461 | 53.820 / 87.954 |
| `join_ordinary` | 7034.7563 / 6969.3873 | -70.3536 [-808.0876, +419.6139] | -552.8989 / +134.3581 | 8624.882 / 8227.198 |
| `join_cleanup_cancelled_task` | 44861.2776 / 43898.0068 | +104.1531 [-6085.5794, +6306.8864] | +2141.9755 / -5504.7692 | 51755.178 / 50374.924 |

`SPSC record persistent` has negative batch medians in both batches; carried-endpoint persistent has positive batch medians in both, and its marginal p99 rises115.8165→133.319us. MPMC record16/cap2 rises3.5153→4.8478us/op with positive deltas in both batches and p99204.0915→327.337us. Directed full-sender record and packed queue also regress in both batch medians. These regressions are retained, not excluded.

The64KiB endpoint-pool4 marginal medians fall39.2684→37.9745us/op while the median **actual paired delta is +4.0261us/op**; batch medians are+5.6071 and−6.4432. Selecting only marginal medians would reverse the interpretation. Join/cancellation figures include the fixture's intentionally fresh lifecycle/gates, not isolated notification latency. Control/codec shifts likewise caution against attributing every difference solely to wake delivery.

## 6. Finite MPMC admission and progress

Every full-count MPMC row has1,000 completed requests; the **160 rows** preserve **160,000 six-column request records**, actual after-join consumer counts, and no empty lanes. Both smokes additionally exercise empty/single-completion lanes (the resource smoke alone has112 empty and400 single-completion lane observations). Empty lanes and one-completion gap series remain unavailable, not zero.

A trace records `request_id,producer,lane,permit_start_ns,send_start_ns,reply_received_ns` relative to body start, after preallocating storage in both modes; output is written outside the body. The parser enforces exact identity/partition/count, causal order, lane non-overlap and body bounds. Permit wait is send-start minus permit-start; old post-permit RTT is reply-received minus send-start; including-permit time is reply-received minus permit-start. Additional common clocks/storage are not claimed identical to frozen-v4 fixture overhead.

The following are medians of the six uninstrumented round diagnostics, B/W=baseline/wake; consumer extrema are actual per-consumer counts across those rounds. The linked tables and raw summary retain both modes, complete lane counts/distributions/first-last timestamps, per-round ranges and actual within-pair/batch deltas.

| Case (uninstrumented) | Worst-lane permit p99 us B/W | Worst-lane incl.-permit p99 us B/W | Max intercompletion gap us B/W | First-start spread us B/W | Last-completion skew us B/W | Consumer count min–max B/W |
|---|---|---|---|---|---|---|
| `mpmc_endpoint_inflight16_cap16_4p4c` | 3.361 / 4.023 | 164.632 / 143.789 | 170.423 / 154.524 | 198.440 / 224.965 | 2604.874 / 2662.818 | 196–334 / 76–355 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 3.732 / 4.874 | 240.154 / 371.309 | 294.285 / 417.060 | 215.303 / 207.778 | 2647.684 / 2944.660 | 93–375 / 57–501 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 2.751 / 2.885 | 52.743 / 62.532 | 139.041 / 365.774 | 5.315 / 6.859 | 9423.879 / 9667.124 | 500–500 / 498–502 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 2.555 / 3.050 | 73.588 / 72.906 | 135.153 / 90.289 | 50.815 / 47.890 | 2897.736 / 3336.827 | 451–549 / 452–548 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 4.123 / 3.446 | 60.158 / 66.519 | 117.053 / 104.756 | 41.553 / 47.514 | 3240.357 / 3187.087 | 454–546 / 470–530 |
| `mpmc_record_inflight16_cap16_4p4c` | 10.114 / 10.129 | 238.646 / 462.209 | 438.700 / 475.424 | 214.070 / 204.642 | 2854.070 / 2974.951 | 113–439 / 95–446 |
| `mpmc_record_inflight16_cap2_4p4c` | 2.785 / 7.699 | 259.399 / 380.406 | 318.495 / 579.107 | 218.669 / 236.352 | 2417.649 / 3499.787 | 57–471 / 78–540 |
| `mpmc_record_inflight1_cap1_2p2c` | 2.705 / 2.119 | 47.324 / 56.822 | 522.521 / 104.370 | 4.829 / 3.205 | 8821.363 / 8246.203 | 500–500 / 498–502 |
| `mpmc_record_inflight4_cap1_2p2c` | 3.993 / 3.075 | 93.309 / 76.924 | 191.398 / 138.734 | 31.709 / 35.396 | 3526.367 / 2956.341 | 395–605 / 485–515 |
| `mpmc_record_inflight4_cap4_2p2c` | 4.107 / 3.542 | 64.936 / 61.099 | 104.942 / 101.851 | 36.068 / 43.602 | 3006.289 / 2834.903 | 446–554 / 413–587 |

For record16/cap2, actual batch median permit-p99 deltas are **+5.410/+2.985us**, including-permit p99 **+94.968/+216.075us**, and maximum-gap **+144.490/+347.089us**. Its admission/progress regression is therefore not hidden by aggregate RTT. Other rows improve selected gaps or including-permit quantiles while worsening others. Finite16-request lanes also have coarse tail percentiles; raw maxima and counts remain available. This experiment establishes neither strict FIFO completion nor starvation bounds or a general fairness improvement. Frozen-v4 has no comparable pre-permit/consumer series.

## 7. Handles, allocation/copy and lifecycle

All **212 paired instrumented rows** ran/passed calibration; slot exhaustion is0. Every round has zero active async identities, active workers, channel/control/Lua-state deltas and pending waiter probes after the required retirement/collection boundary. Both preserved smokes also pass calibration/lifecycle. Seven recorded audits remain in the archive, all `unchanged:true, files:689`; the named resource pre/post and candidate post-smoke/post-campaign audits are retained without rerunning them.

The table below uses each lane's **actual upper-median-body-time representative instrumented round**, as selected by the frozen renderer—not a synthetic average counter record. All-round counter/lifecycle data remain in the raw/summary tables. Requested bytes are allocation traffic, not live footprint.

| Case | Body async init B/W | Whole async init B/W | Body actual close callbacks B/W | Whole loop-retired async B/W | Lua alloc/op B/W | Lua requested B/op B/W | Native alloc/op B/W | Native requested B/op B/W |
|---|---|---|---|---|---|---|---|---|
| `spsc_endpoint_carried_persistent` | 2000 / 0 | 2134 / 5 | 2000 / 0 | 2 / 2 | 109.202 / 99.020 | 8036.230 / 7186.931 | 5.000 / 7.000 | 864.000 / 992.000 |
| `spsc_record_persistent` | 2000 / 0 | 2134 / 5 | 2000 / 0 | 2 / 2 | 100.396 / 90.011 | 7359.620 / 6490.497 | 4.000 / 6.000 | 768.000 / 896.000 |
| `mpmc_record_inflight16_cap2_4p4c` | 2711 / 0 | 14333 / 26 | 2771 / 0 | 9 / 9 | 115.402 / 100.027 | 8966.149 / 7704.560 | 5.068 / 7.629 | 904.704 / 1068.608 |
| `wait_empty_receiver_endpoint` | 1000 / 0 | 1070 / 5 | 1000 / 0 | 2 / 2 | 108.168 / 97.040 | 17702.056 / 16812.098 | 4.000 / 6.000 | 608.000 / 736.000 |
| `wait_full_sender_endpoint` | 1470 / 0 | 1572 / 5 | 1470 / 0 | 2 / 2 | 153.896 / 136.132 | 21127.938 / 19684.316 | 6.000 / 8.786 | 992.000 / 1170.304 |
| `join_ordinary` | 500 / 300 | 541 / 326 | 400 / 200 | 109 / 109 | 24674.330 / 24672.710 | 4004943.100 / 4003511.500 | 20.000 / 25.000 | 2832.000 / 3144.000 |
| `join_cleanup_cancelled_task` | 800 / 300 | 865 / 326 | 700 / 200 | 109 / 109 | 25107.950 / 24847.770 | 4062701.780 / 4031021.890 | 27.000 / 33.000 | 3752.000 / 3762.000 |

For carried-endpoint SPSC, body async initialization falls **2000→0**, with similar actual suspension counts (**1973→1977** in the representative rounds). But native allocation calls rise **5→7/op**, native requested bytes **864→992/op**, while Lua allocation calls fall **109.202→99.020/op** and Lua requested bytes **8036.230→7186.931/op**. The symbol-interposed copy count remains **265B/op** for that representative workload. Lower UV handle churn is not equivalent to fewer allocations in every allocator class or lower total cost.

Close-request counts, actual callbacks and successful-loop retirements are separate. A pinned libuv internal work-queue async can retire directly with successful loop close without a public close callback; failed/busy loop close discharges none. The preserved ledger/counters include this distinction. Zero workers/tail work is benchmark quiescence evidence, not independent proof of OS exit/join or every proxy terminal ordering.

Lua allocator traffic begins at state birth; native allocation counters exclude the Lua allocator and probe-owned storage. `gc.count()` is live Lua memory, not native allocation. Symbol-interposed memcpy/memmove coverage misses inlined or internal/dynamically bound copies that bypass the symbols. Inside/outside `lua_Alloc` is callback context, not object ownership. Analytical reference bytes are not actual all-case wire or total copy bytes. Residual Lua/native and RSS observations remain in the tables with those limits; allocator balance alone is not a complete resource oracle.

## 8. Native suspension, wake stages and endpoint qualification

Both lanes' empty-receiver directed cases record exactly **1000 actual suspensions per instrumented round**. Full-sender endpoint records **1272–1278 baseline /1159–1173 wake** aggregate suspensions; these include protocol/control waits, not a general role breakdown. Ordinary join records **100 native ordinary-join suspensions** each round in each lane. Cleanup join records **100 cleanup-join and100 ordinary-join suspensions**,600 aggregate, each round in each lane. Proxy prearm is not counted as parking.

Carried-endpoint SPSC `native_wake` has **3946 baseline /3954 wake samples** over its two diagnostic rounds; median-of-round p99 is **14.552 /7.5135us**. This narrower improvement does not translate into that workload's end-to-end body/p99 improvement above. Cleanup rows remain `partial_exact_only`:400 eligible wake samples per round despite600 aggregate suspensions; cancelled/ambiguous/unawaited work is not filled with zeroes or relabeled fully attributed. Per-stage sample ranges and all observed modes remain in the tables.

Ordinary request/reply RTT starts after an MPMC producer obtains its fixture permit and ends when that producer receives the reply. It excludes permit admission delay. The new request sidecar adds pre-permit and completion clocks without redefining that historical RTT metric.

`native_wake` is a causally attributed diagnostic, not the complete request/reply RTT. Its start clock immediately precedes the selected real native notification call. A usable sample requires a successful, unique, causative notification of an operation that actually suspended and completed normally. Cancelled, failed, non-unique, never-awaited or otherwise ineligible operations do not receive fabricated zero-cost wake samples.

The end-clock placement differs by wait path:

- **Ordinary waits:** after `wait_on_native_waiter` or the private wrapper around `async.wait_external` returns, **including the wait helper's defers**.
- **Cleanup joins:** at the normal **body end, before that function's own defers**, in legacy `Thread:wait_until_finished_cleanup` or native `ExternalWait:await`. Those defers include legacy `finish_handle`, or clearing `done`, clearing suspension and closing the final wait as applicable.

Thus not every endpoint is post-cleanup, and the two cleanup paths' own deferred work is not included by the same shorthand. This qualification supersedes the broader endpoint wording retained in the immutable frozen README/template/renderer. It requires no probe-code or harness-hash change.

Operation entry, initial-poll fast completion, actual suspension, selected notification and return are distinct events. A post-yield registration recheck that finds readiness is not a native suspension. A pending native waiter accepted after yield is attributed directly to its operation slot, not left in scheduler-local pending state where a sibling coroutine could inherit it. Binding a controller's primary waiter and shared target alias is not itself parking; selected native notification remains distinct from ordinary queue activity.

The start clock deliberately precedes the notification call because another OS thread can resume before that call returns. Notification success and selected-target eligibility determine usable attribution. A later post-return timestamp must not replace the causative start.


The stage intervals (`sender_encode`, `queue_admission`, `wait_registration`, `receiver_decode`, `reply_processing`, request/reply one-way and native wake) overlap across OS threads. Queue attempts include mutex/branch work; notification-to-continuation includes scheduling/ready-queue delay. Do not add stage medians into RTT or subtract independent workload medians to invent component time. There is no general per-role/direction or separate closed/failed semantic counter series; unsupported breakdowns remain unavailable.

## 9. Instrumentation overhead and acceptance boundary

| Case | Baseline uninstrumented / instrumented us/op (ratio) | Wake uninstrumented / instrumented us/op (ratio) |
|---|---|---|
| `overhead_control` | 0.0736 / 0.0980 (1.331x) | 0.0684 / 0.1173 (1.715x) |
| `call_control` | 0.0539 / 0.0679 (1.261x) | 0.0553 / 0.0731 (1.322x) |
| `spsc_endpoint_carried_persistent` | 21.8715 / 26.4188 (1.208x) | 23.3469 / 21.0093 (0.900x) |
| `mpmc_record_inflight16_cap2_4p4c` | 3.5153 / 7.4654 (2.124x) | 4.8478 / 7.1846 (1.482x) |

These compare independently scheduled instrumented and uninstrumented series, including private rebuild/probe/wrapper effects. A ratio below1 (carried-endpoint wake here) is **not negative instrumentation cost** or permission to subtract overhead; it exposes the limitations of these noisy small samples. Primary performance uses uninstrumented measurements only. Calibration success does not prove zero perturbation.

Main separately reported final-source provider bg27 PASS31.78s,30-root aggregate bg29 PASS148.54s, native suite bg31 **1794 pass /1 POSIX skip /0 fail**, owners30/30, and **82/82 Thread cases including all23 native fault scenarios**. Its final admission causal BEFORE observed an improperly started worker on Map OOM; the same final AFTER records `THREAD_RETIREMENT_OK`, no selected worker start, native-create rollback, retain/FIFO completion. The archived source receipt binds the final transaction; the earlier81-case pre-transaction pass is not substituted. No failing-before case was repeated by the publication author.

The operator note says Linux/GCC/Clang-ASAN, Windows NTFS and local macOS validation finished before measurement. This benchmark input set does not supply detailed final-v3 platform/sanitizer pass inventories; full final integration evidence remains Main-owned, not inferred from an idle VM, RTT lifecycle zero or C-codegen equivalence. No cross-platform performance result follows from this Linux run.

**Conclusion:** the requested matched full-catalog benchmark and reproducible publication are complete. The observed design greatly reduces per-wait UV handle initialization, but these data do **not** establish a blanket latency/throughput benefit, allocation reduction across classes, or fairness improvement beyond batch noise. Specific improvements, regressions and unavailable metrics remain visible. Correctness/release acceptance is separate from these performance observations. No descriptor-cache/tag plan, decoder/deep-buffer redesign, native pooling or unmeasured channel-creation claim follows from this result.

All build/test/smoke/audit/table executions cited above were parent-produced. This publication author performed only supplied-data analysis, source/raw packaging and documentation; no builds, tests, lint, formatters, performance reruns, commits or branch changes.
