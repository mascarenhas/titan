# Paired baseline/candidate cross-thread evidence

Raw evidence: `/tmp/titan-issue252-rtt-paired-resource-v4/PAIRED-RAW.json` (SHA-256 `86000028e47677296de784e522d2faaa05f6c8f4d7d920aae8a87e5a913148d8`).

## Operator quiescence evidence

# Pre-wake resource comparison operator evidence
Observed 2026-10-18T03:22:09Z. Host Linux x86_64, AMD Ryzen AI 9 HX370 (12 cores/24 logical CPUs), 1 NUMA node; no affinity pinning or CPU/memory-policy changes. amd-pstate-epp, powersave governor, balance_performance energy preference, boost enabled; reported frequency range605.264–5157.895MHz. Dynamic frequency remains a noise source; do not claim controlled fixed clocks. THP madvise. Mem125Gi total/48Gi available at observation; zram swap16Gi/2.2Gi used. Background desktop/services and both idle VMs remain running; this is a quiet-build interval, not an exclusive host.

All parent build/test jobs completed before measurement: aggregate rebuild77.85s PASS; async231/231PASS12.17s; fullUV223/223PASS50.20s. One-shot local ps observation found zero make/clang/gcc/cc1/lua/titanc/busted build/test processes. Mac VM one-shot SSH observation: Darwin x86_64 and zero matching build/test processes; Windows one-shot Get-Process found zero matching processes (CIM inventory unavailable/access denied, not used as proof). No VM or parent builds/tests will be started during the serial independent baseline and paired campaigns. Subagents are restricted to source inspection/edits, no checks. VM quiescence observations taken during preparation shortly before local final quiet observation.

Measure committed harness f14260b4 from unchanged frozen-v4 copy against original attested source/SDK and resource-ownership attested source/SDK, both ABI2. Prior smoke raw/summary archived as SMOKE-*.json in each lane; builds/manifests/source/SDK remain immutable, output logs/samples/audits append by design. Campaigns: original full2batches×3repeats+2instrumented; resource same; then alternating/randomized paired same settings, scale1/seed252/all53cases. Actual per-command timestamps/status/logs in /tmp/titan-issue252-baseline-campaign-v4/EXECUTION.json. No result is claimed in this pre-run note; historical legacy detached Thread/per-wait-wake/proxy-early-terminal limitations remain explicit.


Note SHA-256: `b9c72ffcc73c966ea50d5828a35f96cd2c2f227b9a6161c6d3157097f718b483`.

## Actual within-pair differences

| Case | Pairs | Median candidate - baseline us/op | Difference range | Median within-pair ratio | Independent batch median differences |
|---|---:|---:|---:|---:|---|
| `call_control` | 6 | +0.002 | -0.026..+0.031 | 1.034 | 0: +0.011, 1: +0.001 |
| `churn_cancel_parked_waiters` | 6 | +5.396 | -7.084..+28.308 | 1.073 | 0: +5.606, 1: +0.301 |
| `churn_close_parked_receivers` | 6 | +1.747 | +0.798..+8.493 | 1.073 | 0: +1.744, 1: +1.749 |
| `churn_close_parked_senders` | 6 | -1.218 | -5.192..+2.004 | 0.969 | 0: -2.086, 1: +0.831 |
| `closure_roundtrip_cap0` | 6 | -2.725 | -4.301..-1.671 | 0.516 | 0: -2.719, 1: -2.730 |
| `closure_roundtrip_cap1` | 6 | -3.641 | -7.847..-2.236 | 0.680 | 0: -4.204, 1: -2.381 |
| `closure_roundtrip_cap64` | 6 | -4.940 | -15.015..+6.457 | 0.967 | 0: -4.992, 1: -0.883 |
| `closure_roundtrip_cap8` | 6 | -5.445 | -30.667..+2.389 | 0.816 | 0: -0.406, 1: -13.030 |
| `closure_roundtrip_complex_sig` | 6 | -4.199 | -8.543..-2.352 | 0.583 | 0: -3.500, 1: -4.884 |
| `codec_large64k_decode` | 6 | +0.907 | +0.182..+7.169 | 1.132 | 0: +0.924, 1: +0.890 |
| `codec_large64k_encode` | 6 | -3.774 | -8.892..+0.037 | 0.697 | 0: -3.569, 1: -3.979 |
| `codec_large64k_transfer_roundtrip` | 6 | +0.426 | -4.047..+2.165 | 1.046 | 0: +1.633, 1: -0.242 |
| `codec_scalar_roundtrip` | 6 | +0.380 | +0.273..+0.488 | 3.407 | 0: +0.380, 1: +0.356 |
| `codec_small_decode` | 6 | +0.101 | -0.075..+0.678 | 1.087 | 0: +0.116, 1: +0.086 |
| `codec_small_encode` | 6 | +0.058 | -0.465..+0.480 | 1.122 | 0: +0.023, 1: +0.299 |
| `codec_small_transfer_roundtrip` | 6 | +0.268 | -1.199..+0.576 | 1.120 | 0: +0.398, 1: +0.226 |
| `codec_wide16_decode` | 6 | +0.087 | -0.086..+1.299 | 1.036 | 0: +0.177, 1: -0.030 |
| `codec_wide16_encode` | 6 | -0.119 | -0.704..+0.380 | 0.941 | 0: -0.308, 1: -0.018 |
| `codec_wide16_transfer_roundtrip` | 6 | +1.088 | +0.553..+6.726 | 1.270 | 0: +0.941, 1: +1.266 |
| `inspect_function` | 6 | +0.063 | -0.064..+1.247 | 1.032 | 0: +0.583, 1: +0.056 |
| `inspect_record` | 6 | -0.006 | -0.106..+0.045 | 0.964 | 0: -0.005, 1: -0.007 |
| `join_cleanup_cancelled_task` | 6 | +1934.005 | -2668.820..+5122.328 | 1.045 | 0: -818.632, 1: +2906.419 |
| `join_ordinary` | 6 | -55.990 | -738.967..+1069.023 | 0.992 | 0: +72.675, 1: -70.594 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 6 | +0.287 | -0.486..+0.436 | 1.080 | 0: +0.129, 1: +0.379 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 6 | -0.186 | -1.408..+0.934 | 0.946 | 0: -0.211, 1: -0.161 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 6 | +1.454 | -0.405..+2.283 | 1.069 | 0: +2.227, 1: +1.008 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 6 | +0.012 | -1.281..+0.695 | 1.000 | 0: -0.283, 1: +0.686 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 6 | +0.619 | -0.289..+1.046 | 1.104 | 0: -0.110, 1: +0.901 |
| `mpmc_record_inflight16_cap16_4p4c` | 6 | -0.170 | -2.010..+0.872 | 0.951 | 0: -0.003, 1: -1.143 |
| `mpmc_record_inflight16_cap2_4p4c` | 6 | -0.361 | -1.402..+0.420 | 0.908 | 0: +0.157, 1: -0.404 |
| `mpmc_record_inflight1_cap1_2p2c` | 6 | +2.409 | +1.592..+6.129 | 1.151 | 0: +2.337, 1: +3.286 |
| `mpmc_record_inflight4_cap1_2p2c` | 6 | +0.696 | -1.265..+1.617 | 1.124 | 0: -0.287, 1: +1.005 |
| `mpmc_record_inflight4_cap4_2p2c` | 6 | +0.665 | +0.031..+2.596 | 1.106 | 0: +0.684, 1: +0.645 |
| `overhead_control` | 6 | +0.001 | +0.000..+0.033 | 1.016 | 0: +0.003, 1: +0.000 |
| `queue_opaque_hook8` | 6 | +0.249 | -0.813..+4.321 | 1.067 | 0: +1.076, 1: -0.271 |
| `queue_packed_hook8` | 6 | +0.814 | +0.209..+1.295 | 1.218 | 0: +0.800, 1: +0.828 |
| `queue_plain_bytes8` | 6 | +0.617 | -0.052..+1.137 | 1.301 | 0: +0.365, 1: +0.703 |
| `queue_real_receiver` | 6 | -0.422 | -0.574..+0.340 | 0.896 | 0: -0.405, 1: -0.526 |
| `queue_real_sender` | 6 | -0.538 | -4.384..+0.464 | 0.875 | 0: -1.852, 1: -0.423 |
| `sender_clone` | 6 | +0.006 | -0.101..+0.113 | 1.032 | 0: +0.014, 1: -0.085 |
| `spsc_endpoint_carried_persistent` | 6 | -0.919 | -16.815..+13.207 | 0.962 | 0: -0.920, 1: +6.910 |
| `spsc_endpoint_fresh_reply` | 6 | +2.497 | -0.795..+8.191 | 1.187 | 0: +3.345, 1: -0.299 |
| `spsc_endpoint_pool4_reply` | 6 | -2.143 | -6.398..-1.115 | 0.913 | 0: -6.051, 1: -1.920 |
| `spsc_large64k_endpoint_pool4` | 6 | +19.944 | -17.018..+32.963 | 1.752 | 0: +6.117, 1: +23.657 |
| `spsc_large64k_persistent` | 6 | +12.250 | -1.915..+23.928 | 1.451 | 0: +18.026, 1: +8.029 |
| `spsc_opaque_persistent` | 6 | -1.629 | -11.120..+11.542 | 0.907 | 0: -4.031, 1: +2.786 |
| `spsc_record_persistent` | 6 | +3.194 | -5.110..+8.364 | 1.154 | 0: +5.235, 1: +0.964 |
| `spsc_record_pool4_control` | 6 | +3.916 | -1.091..+13.545 | 1.206 | 0: +4.503, 1: +3.662 |
| `spsc_scalar_persistent` | 6 | +2.430 | -1.824..+5.454 | 1.525 | 0: +3.293, 1: +1.566 |
| `wait_empty_receiver_endpoint` | 6 | +0.829 | -18.003..+10.271 | 1.026 | 0: -11.371, 1: +6.949 |
| `wait_empty_receiver_record` | 6 | +1.966 | -4.680..+16.699 | 1.060 | 0: +2.512, 1: +1.420 |
| `wait_full_sender_endpoint` | 6 | -1.693 | -12.239..+5.425 | 0.960 | 0: -2.725, 1: +2.916 |
| `wait_full_sender_record` | 6 | +1.169 | -5.436..+4.134 | 1.040 | 0: +0.155, 1: +3.864 |

These are statistics of actual alternating-order matched observations, not differences of marginal medians. Raw per-pair observations/order and lane marginal summaries are retained. Ranges and batch differences expose observed variation; this renderer does not assert statistical significance or attribute a resource-ownership checkpoint change to a later final corrected wake/join cutover.

### baseline provenance

| Input | Recorded evidence |
|---|---|
| ABI / SDK / language-server API | `2 / 0.6 / 1 (compile guard)` |
| Claimed source revision (builder-attested, not inferred) | `66d1aad63885246b42107b1131f1656a0386cc8b` |
| SDK profile | `production` |
| Complete generated-C flags (including optimization / LTO / debug) | `--std=c99 -O3 -Wall -Wno-unused-but-set-variable -Wno-unused-function -fPIC -g1 -flto=auto -ffat-lto-objects -fno-strict-aliasing` |
| Generated-C source-line directives | `True` |
| Full SDK content manifest SHA-256 | `d7905867300ce6517ba4764f27785cf7facc2c5ee065ed4d54882fed38cc1545` |
| Source hash-map SHA-256 | `3982eb1a81374295f47efb857284e1cbc6a0a3c54412dc971438c898fbc3503a` |
| Source probe recipe SHA-256 | `dcde3e6c1acf22d858ea88105c07356a2d0ce75fadcf226b991bf080e2da0299` |
| Original builder receipt SHA-256 | `c3da3cfd417f6738620430b58e567b266bd9d56d0cc888b60a90a8210dac514e` |
| Preserved native payload archive SHA-256 | `c2b6206a6491bbed19ff4b6c542da963d9a24e1f899a3d8f995d5b368370e47e` |
| Generated consumer SHA-256 | `3f1718f65b8f677681dfaa436fd3276a1b4c084a1f8f3826d2dd3833cda4074c` |
| Raw codec calling contract | `ordinary_consuming_value` |

<details><summary>Exact provider/source/tool/link evidence</summary>

```json
{
  "executable_sha256": {
    "instrumented": "374f26179e2ef2f2d40a8c527cfebd667ced511fee7c4a2c1b9bed92945e3507",
    "uninstrumented": "2276bc6894f990772a404c3c124592a728b305d51d0802ce897fc21772eeb15a"
  },
  "link_evidence": {
    "instrumented": "/tmp/titan-issue252-rtt-original-v4/logs/1792292446181720171-link-dependencies-instrumented.json",
    "uninstrumented": "/tmp/titan-issue252-rtt-original-v4/logs/1792292446176947732-link-dependencies-uninstrumented.json"
  },
  "lua_sha256": {
    "bin/lua": "4ff90fc0bccfffb89db1198b3807b2731b1f95686967a42d13f9b78f6f5561ee",
    "lib/liblua.a": "7decdb6e81469ca27cd6f8bc9f2eef0830c77dd6c5bc15cefc8a89fe1258f721"
  },
  "native_compile_argv": {
    "consumer_instrumented": [
      [
        "/usr/bin/gcc",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=bench",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/instrumented/bench.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/instrumented/bench.o.compile.tmp.lua_rqQnYz"
      ],
      [
        "/usr/bin/gcc",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/instrumented/.titan-temporary.tmp.lua_rOEHR7.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/instrumented/.titan-temporary.tmp.lua_rOEHR7.o"
      ],
      [
        "/usr/bin/gcc",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/instrumented/bench__entrypoint.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/instrumented/bench__entrypoint.o"
      ]
    ],
    "consumer_uninstrumented": [
      [
        "/usr/bin/gcc",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=bench",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/uninstrumented/bench.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/uninstrumented/bench.o.compile.tmp.lua_f1s9RC"
      ],
      [
        "/usr/bin/gcc",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/uninstrumented/.titan-temporary.tmp.lua_HGaxAo.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/uninstrumented/.titan-temporary.tmp.lua_HGaxAo.o"
      ],
      [
        "/usr/bin/gcc",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/uninstrumented/bench__entrypoint.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/uninstrumented/bench__entrypoint.o"
      ]
    ],
    "private_provider": [
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.async",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/async.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/async.o.compile.tmp.lua_Cn6XTX"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.coroutine",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/coroutine.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/coroutine.o.compile.tmp.lua_HfM9QR"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.fs",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/fs.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/fs.o.compile.tmp.lua_B2ws44"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.gc",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/gc.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/gc.o.compile.tmp.lua_YjfMp8"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.http",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/http/http.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/http/http.o.compile.tmp.lua_orKxUS"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.io",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/io.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/io.o.compile.tmp.lua_1WUmyl"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.iteration",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/iteration.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/iteration.o.compile.tmp.lua_Gc4aIi"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.json",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/json/json.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/json/json.o.compile.tmp.lua_Taq8FT"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.lua",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/lua/lua.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/lua/lua.o.compile.tmp.lua_mB3vje"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.math",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/math.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/math.o.compile.tmp.lua_ldqlDf"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.net",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/net.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/net.o.compile.tmp.lua_dtejLr"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.os",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/os.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/os.o.compile.tmp.lua_2RMSmP"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.path",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/path.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/path.o.compile.tmp.lua_ihc4Cq"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.peg",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/peg/peg.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/peg/peg.o.compile.tmp.lua_xlx9J1"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.protobuf",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/protobuf/protobuf.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/protobuf/protobuf.o.compile.tmp.lua_uDha0l"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.reflect",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/reflect.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/reflect.o.compile.tmp.lua_hpUdO2"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.sqlite3",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/sqlite3/sqlite3.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/sqlite3/sqlite3.o.compile.tmp.lua_sXaTvv"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.ssl",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/ssl.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/ssl.o.compile.tmp.lua_VAJ5Jk"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.string",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/string/string.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/string/string.o.compile.tmp.lua_3ijQ35"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.test",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/test.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/test.o.compile.tmp.lua_VOqkSO"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.thread",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/thread/thread.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/thread/thread.o.compile.tmp.lua_imDAxn"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.timer",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/timer.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/timer.o.compile.tmp.lua_NZqaV8"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.transfer",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/transfer.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/transfer.o.compile.tmp.lua_JApEXM"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.url",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/url.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/url.o.compile.tmp.lua_089PKo"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.uv",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/uv/uv.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/uv/uv.o.compile.tmp.lua_CCbpH1"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-original-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-original-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-baseline-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.websocket",
        "-c",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/websocket/websocket.c",
        "-o",
        "/tmp/titan-issue252-rtt-original-v4/work/provider/titan/websocket/websocket.o.compile.tmp.lua_GMyiiM"
      ]
    ]
  },
  "native_policy": {
    "ar": "/usr/bin/ar",
    "cc": "/usr/bin/gcc",
    "cc_version": "gcc (GCC) 16.2.1 20260819 (Red Hat 16.2.1-2)",
    "emit_line_directives": true,
    "libbacktrace_cflags": "-fPIC -g -O2",
    "lua_archive_sha256": "7decdb6e81469ca27cd6f8bc9f2eef0830c77dd6c5bc15cefc8a89fe1258f721",
    "lua_binary_sha256": "4ff90fc0bccfffb89db1198b3807b2731b1f95686967a42d13f9b78f6f5561ee",
    "lua_source_commit": "025bfc35df0885656de347fb7a7c377e90042a75",
    "native_dependency_versions": {
      "libuv": "1.53.0+spawn-close-v1",
      "llhttp": "9.4.3",
      "lpeglabel": "1.6.2-1@912b0b9e8641074408ffc2259e069b188e0c717b",
      "sqlite3": "3.53.4"
    },
    "openssl_mode": "system",
    "openssl_pkg_config": "/usr/bin/pkg-config",
    "openssl_version": "3.5.9",
    "ranlib": "/usr/bin/ranlib",
    "rock_host_cflags": "-O2 -fPIC",
    "runtime_cflags": "--std=c99 -O3 -flto=auto -ffat-lto-objects -Wall -Wno-unused-but-set-variable -Wno-unused-function -fPIC -g1",
    "sdk_header_replay": {
      "include/llhttp.h": {
        "sha256": "5bc82fa51b19aa8bee7d921038393fbfc74e8cc9bae0844c2d82c102fb8cfd68",
        "source": "llhttp-release-v9.4.3/include/llhttp.h"
      },
      "include/sqlite3.h": {
        "sha256": "919e7f2e8ed1d8f56ac17b412b8971c76aa5d1a879752cc6058f75e7d5910e1d",
        "source": "sqlite-autoconf-3530400/sqlite3.h"
      },
      "include/uv.h": {
        "sha256": "565b25538707aa7244eb197af397e566be591b26cb66b5742ed095063946a558",
        "source": "libuv-v1.53.0/include/uv.h"
      },
      "include/uv/aix.h": {
        "sha256": "bed77e4cf6c06f1224e681cbe607eff04713ca0c1e1f4a102e6a6565ee3f02aa",
        "source": "libuv-v1.53.0/include/uv/aix.h"
      },
      "include/uv/bsd.h": {
        "sha256": "963533ff4b16f72a204a8c760896a857c54d0ac50570f1793e3bef1f2ae8b35f",
        "source": "libuv-v1.53.0/include/uv/bsd.h"
      },
      "include/uv/darwin.h": {
        "sha256": "222b6dd3ce67cfbb735b14b1662f065fc23570d6969acf463b39d946b7590d8c",
        "source": "libuv-v1.53.0/include/uv/darwin.h"
      },
      "include/uv/errno.h": {
        "sha256": "4242edf790e4569ef349026ab4c6e31093334ee5fc02b16ed7a0d9fbacdffd16",
        "source": "libuv-v1.53.0/include/uv/errno.h"
      },
      "include/uv/linux.h": {
        "sha256": "adce0ed0821c8466a87a0a4c9e0df9ea7e4a4b24d099c7d7ed196f72a13f669d",
        "source": "libuv-v1.53.0/include/uv/linux.h"
      },
      "include/uv/os390.h": {
        "sha256": "98388ae32ce2c4390b82c3529539d2a476c44f590e960ed30a79f72b807ecd02",
        "source": "libuv-v1.53.0/include/uv/os390.h"
      },
      "include/uv/posix.h": {
        "sha256": "e9d7218b34e6e89b7b412891b7e2aa8b3a561c5ce9714c1f4def6c8a8593a6a6",
        "source": "libuv-v1.53.0/include/uv/posix.h"
      },
      "include/uv/sunos.h": {
        "sha256": "29d4b4ef48dc3c3ab32d75e0a85bcb80e084d42b32aae40d67fc1d882b93298a",
        "source": "libuv-v1.53.0/include/uv/sunos.h"
      },
      "include/uv/threadpool.h": {
        "sha256": "09ae41099af710289155be012df45c2fce04da6a02e813278b4558935e645938",
        "source": "libuv-v1.53.0/include/uv/threadpool.h"
      },
      "include/uv/tree.h": {
        "sha256": "34393c74082c71ddd5bd9ec4afe30ef03df7fa7bb64be5a50ae070cdfebb5c43",
        "source": "libuv-v1.53.0/include/uv/tree.h"
      },
      "include/uv/unix.h": {
        "sha256": "bfa9e31bccf6991f795074316d323eaeef5dcdf6b1b6b8b9d1093e871e6484db",
        "source": "libuv-v1.53.0/include/uv/unix.h"
      },
      "include/uv/version.h": {
        "sha256": "8e216f0998cae52664f5a9889a2ec921e43c7abf7970c4780ab4e1bb6262932c",
        "source": "libuv-v1.53.0/include/uv/version.h"
      },
      "include/uv/win.h": {
        "sha256": "414f87cfec6fe111b893c71894bb3bf4afd1ae8e9fc601aa6cf7fb54dc3a1ca7",
        "source": "libuv-v1.53.0/include/uv/win.h"
      }
    },
    "titan_build_profile": "production",
    "titan_cppflags": "-DOPENSSL_API_COMPAT=30000 -D_GNU_SOURCE",
    "titan_extra_cflags": "-fno-strict-aliasing",
    "titan_ldflags": "-lpthread -lrt -lssl -lcrypto"
  },
  "private_provider_files": {
    "/tmp/titan-issue252-rtt-original-v4/work/provider/titan.a": "db45604b7314352b5e185139940e29f8801cb29c33a62e498f3361f5540e5dd6",
    "/tmp/titan-issue252-rtt-original-v4/work/provider/titan.so": "10ba2b75635a210e583417c7a2984259e4b2c4e80abf371965c76e4bdf996caf"
  },
  "private_source_sha256": {
    "titan/async.titan": "b384f0e672566f34bbadbeb44c0c2c517e7e925f727df9b9c1a096ec402d43a7",
    "titan/async_receiver_native.h": "0fa7dd008ecb50fc84070eb52014e4223f57d66ab3f82bfeda793ebc475150db",
    "titan/async_signal_platform.h": "3a413448397988560fe12a07e288be7bab73124964c44bac749497b61b069296",
    "titan/coroutine.titan": "be5fd08a6fd6d3b0b2f6b798f4e3ad42c10d1fb5e88aced6209faa59b9e2144b",
    "titan/fs.titan": "a327d9b30d8f680bfb9faa24f514eec2812fede877ab46e3f9531c822e3b99f9",
    "titan/fs_platform.h": "00da49bdf0851c3a4e2f44ed74243ba40a7b41e3d528f41e50b953503b11d879",
    "titan/gc.titan": "03cabaf0a6e2a48be14280d898236fce5334d3cfa769abc4b7c7a4b1632bb638",
    "titan/http/client.titan": "deed2100ec9da07aa4796f90b05d2491846d04accaa9491805548bc8180855b2",
    "titan/http/headers.titan": "8827e4cd9ae5a18cf660289fee5acb0bd774daa97f7c10cc1e220e724c70557d",
    "titan/http/http.titan": "ff6cc19963ed720c9cc3db435cba78fd7b4457260dd49674d983a0c21f725ae2",
    "titan/http/native.titan": "c6dc067689edb2b9cfd7c012e2497806b7c405a500a024aecedcd1b0695f8390",
    "titan/http/pool.titan": "04e290cd0f8f50b120541339ed15b1aa573a49afd145c0d9e8b6d4cae1987646",
    "titan/http/server.titan": "0032dc51c27b386d06ee912f62e27e7fb122c45e84fc58bf1b1f1f2db1066cec",
    "titan/http/transfer.titan": "fbc27658c9752325e48e748f4fa60c148e6cd56e794254df8cfc42fc830411f4",
    "titan/http/upgrade.titan": "82660410330005aca4c3846eea3b3b46cd4196ac280684f14658d1f4b92884c8",
    "titan/io.titan": "a85aea6ee8d66da0d8fc594426b9e9da812c8701916cd37703548513f7c8b57a",
    "titan/iteration.titan": "c5d33ca7f159aef0e9c07163ae8871920f46ce73ad8a6c9565265ec5e636e3d7",
    "titan/json/decoder.titan": "d4def8fce5de08c7c87508ce0a411a1bafe4b9ac5dd6e318ab4062fd99f4a144",
    "titan/json/json.titan": "1fd824d91d9bee28e2093bebc3598fabdcec594d00aafad6d00a991f4643050a",
    "titan/json/numbers.titan": "88f8a136d374276e98d05e047ed32aaa03efd63e56f4a83c516d48d513f3b13a",
    "titan/json/parser.titan": "7f12a7ba9c72bcc3103f2f84939e23a968fd8c4619fa10e8d8495c5f89dffeb2",
    "titan/json/writer.titan": "6667abde3d9f08e1e5711a30ff1ab636288c5c286c9c6916d98e088c52732703",
    "titan/lua/lua.titan": "fe0b752e006c2d8eda5d16a1b4a93f8ff0328b41a30993ef8f53ed2f63ad362e",
    "titan/lua/native.h": "9b5cdc28cab74588ec8ac44085886300d900d7d547c467b171888e2094660d8a",
    "titan/lua/worker.titan": "a405570e4f22e7e42c0af38e29e0e15b9458b9b8ad4206d0c4a3e9d0c96ff88a",
    "titan/math.titan": "15005d85308ffd3e42a79e548f55c5e5d59cd33e8bb7d4cb2608fe1e0d593f3e",
    "titan/net.titan": "e0c586a511979ac7150b2308ef8581740b481cec13441ac3c1196ba1323c19dd",
    "titan/os.titan": "da276574dec7c8a4dee575782ab22a61184baf083d0739be5569597aa6031835",
    "titan/os_environment.h": "e6b805d75104076751c555af08c4ea80881dd93df104dec8ebefd6b12aca982b",
    "titan/os_platform.h": "2ca67def9f3c87a409a9a80c6458aa9d53d7bbc227c0b3a6c07cabafd226770c",
    "titan/path.titan": "43c194cf9b3b4b79c37f652e74b20f20ab77996bbd326ba188b1e4ee2c601086",
    "titan/path_platform.h": "c56729270bb299092c6ac7dd88ae117c97a874393520ce810ef1c8af03e6ecc8",
    "titan/peg/combinators.titan": "e630451865326ab2ccc9b4078f17c12412e6af19155539a28868df7f34751f11",
    "titan/peg/native.titan": "768cb146b1e578521fb97c2318053ff5fc80a7d5b1765d997518002f083e8fd0",
    "titan/peg/peg.titan": "f3771893b9b648af80027ab839ca27e9165a95b94b28ec1d6637b3fa40ece24a",
    "titan/peg/relabel.titan": "3b6bcccd8da929aa1d56da040bc53df9cd24413361536ac9b66d39a3ec186d0f",
    "titan/peg/relabel_parser.titan": "22df8b78c74e0e596d642f60be244f9f17ee20860a52e8d67d90c3cc14eef1d8",
    "titan/protobuf/decoder.titan": "a864fd7450aa83d286ec173a1928b2f6b07f310d484497b0d8ab6e373802be7f",
    "titan/protobuf/encoder.titan": "3c4cc2b49ca8ff3b45334af70ba72a0f5c84c7cd3639d72aafefcd2f040714b9",
    "titan/protobuf/native.h": "256dd809670f6f1a20a2951ff3783f96ce93341cff0408bd55d89af6fcb40d52",
    "titan/protobuf/protobuf.titan": "39cb281542ec090c7f9de94f5ac8eb690ed5f47dec253decc46f78841bdef24f",
    "titan/protobuf/schema.titan": "924b9d92ad0b2f82f61e82ef18cd0be5fbad1dcbbb53dccc929ea569c8294c8f",
    "titan/reflect.titan": "a611557c47f100f7b3f44badbd47dda0bf11b4d7869df7aa7c0d73214ba2fef9",
    "titan/sqlite3/bindings.titan": "17a46365e8c8cb93e329676d35a9e74d151cc9590489a8591c0fd7b6c04a103d",
    "titan/sqlite3/native.h": "ac82a1b9730c6e6692b9e08e3fd8b3d83337df66a6a2c6264a366040d9e992ef",
    "titan/sqlite3/row.titan": "58f91cec279562e60559ab66937a80d01fdd30532a2cff4622da1171b9181618",
    "titan/sqlite3/sqlite3.titan": "bae3cb85db17d0fd48ed4f0b9f3479ecda6842c3994bf25f7b8f2a67d597bc45",
    "titan/sqlite3/worker.titan": "421db60859260a0ed96ca325e0def109b8dbd661a0619870790140668fb23092",
    "titan/ssl.titan": "79b741432798a3f2b73ec85fa33851b1bd3cc3e43fd7a4315a8ea74213ca1fd0",
    "titan/string/bytes.titan": "9448b332fd42bf409b453158305890c8c12eb5eb18df1be9bc92342bcc9c8b3e",
    "titan/string/format.titan": "ff8794649730b36d0185cdecb28cbb9eb0a76ffd0b122e67864de3715b02ae34",
    "titan/string/format_native.h": "f3f97457a9296ea6e32e72e036b05e945f15eb8ef02cccdca8ea816a3ac76b75",
    "titan/string/pack.titan": "20bc7a5a3d4f8b499ae27246559040124886b9925cdf6f05b13167690d2a99c2",
    "titan/string/regex_api.titan": "281d06298980e53cdd2e133bbf5ae1ffbbd5e2dc49974979a17b1970362c6160",
    "titan/string/regex_compile.titan": "8aa476969a2854cdd921e112a5c6d6bf860a9c655261851f8f6cebe7bd0dd786",
    "titan/string/regex_parser.titan": "8402206160bceefe85d38abceb52588357afcf5991d753da4ec4a56c4b84b969",
    "titan/string/string.titan": "e1015dcb814d4c2173e8f14dbe506e3a9d5b96e814a58e818306960e0d2b72ea",
    "titan/test.titan": "1098b360eb4e1312cc3e41fb2c6bc258a68a9d9aba47da5fe7dbbc3a3843edcf",
    "titan/thread/channel.titan": "ce91242d1563becf5674c575192431042813ab4b435e2ebb10f5820293041659",
    "titan/thread/group.titan": "4fe8c6b4d535ea88a5d9e0ab92c2a570c78576e95682ca97ec10de44f9d7bf40",
    "titan/thread/native.h": "3f256682e2e58e8cdc64df768be99874791812c5de4db7dcaf15d02009ce0a10",
    "titan/thread/spawn.titan": "68148c5f0ad29b2de0e645183a0b5c91b036885e0c8d84943dd3869ce009724a",
    "titan/thread/thread.titan": "ea9740dd8dcf7087c37d9b862d5111288f08fd610a7a53f6586e62753c5e3720",
    "titan/timer.titan": "bcbbaf7ca0a83e6305b7c436523bbe938454254b1967a1e2c717417d44e69d1b",
    "titan/transfer.titan": "4e6c0181e4c9f69f62afca227e2b05b2530b9fa5a7188d1372b6c543ded8948c",
    "titan/url.titan": "c130c7e2736759cceed9f0c9955e457d9253c94cbe0784adb74d990b2891f9ab",
    "titan/uv/address-native.h": "a77fc869a5ddefee6dd053c0f1df552e6bb96a320a1f8bf0e2a5b3c28ac61525",
    "titan/uv/address.titan": "67d85cfbf9382484c49dd7e3b396963db5ef337508d2cbafc2dc50d9ea4f3c84",
    "titan/uv/callback.h": "de7a15347fe4586ffe9dd7a7f3dfc9931ed488a8babde23f81dfc53bd1d89bee",
    "titan/uv/callbacks.titan": "d605d2cd36704a1c1cd19eb5b988045865141738b94dd1d9c92c85b507b0832f",
    "titan/uv/capabilities.titan": "b79d72cb392a74828f1aa0a82a781b2d83ab09d7803c17a85986c899a4ad9b5f",
    "titan/uv/constants.titan": "58042ab8d85fe014a4dd3c940b0594710fdc76cf35f4e6eb64bc8eecc8bed330",
    "titan/uv/data.titan": "565de88997eba8034f5431ead7a80a2ed37aff12a8932aedf85a225d0474fb8a",
    "titan/uv/data_native.h": "68cf454e225b200572d5de46ada8b091d774a661ebe39b7160c18bf4c5d195c1",
    "titan/uv/dll.titan": "51aae662b051bb5fcd4bc61fd41e36e032c5ce95f45822f6e81fec347a214800",
    "titan/uv/dns.titan": "d79ae8118ee8d2d17e29ac050370d967f7096d4c56efdc5c7e4eef281f93d868",
    "titan/uv/fd-native.h": "310b9f22163030d72ae29bf32f06b63ac253db23ada7dce7ef5833ce3ef3dd9f",
    "titan/uv/fd.titan": "0d754b9e83e2d3506ae988d46bd160a3b9df867a751c43ba7ec6e8c8caff7953",
    "titan/uv/identifiers.titan": "a5b033d59b4593db7ed8512558468708b7cc55fe94555505ada36f32a3406d08",
    "titan/uv/network-native.h": "aa68b33b4533ccf0a9a21da5037c8a75d942b5cf0fcbfaf860501673ebb1b78d",
    "titan/uv/pipe_tty.titan": "c993616548c9e0957355ce7cfad76daef24b44353749c7af9f4648acd5c8b0c8",
    "titan/uv/platform-constants.h": "026ede031bc7ebb28ed0504d29a2a077175c152cf18d181120944bd43ac46a26",
    "titan/uv/platform_constants.titan": "c322cb9c80ffdb8406ab643ac935f8cc5ad7d7736e09711abb3e826e2d007255",
    "titan/uv/process.titan": "94145f180cc85848c118adec809c6e4efa153199053b874b5b035046f518e14d",
    "titan/uv/startup.titan": "31e0376df10ec0ef59257f59160b7e6958df301fb1e3d167544519dc35f2381f",
    "titan/uv/stream_ops.titan": "6ecb4e474f66c6507c8c7f29114e2c95cf84a0d6df62aa7b37f0ce1708037071",
    "titan/uv/stream_owners.titan": "8cc33b19287a8f4edd25e05e65270bda2f6bbefbc024da80187f6e3e5ba1de4e",
    "titan/uv/sync.titan": "95906e8bd3f522351014942298633dfba96872545ccdb94e1a401ca2bae03e8e",
    "titan/uv/sync_storage.h": "735846d522d0d8ac547b90b72c4104bd91bbf35ce77a9485ad57bd49f2eea579",
    "titan/uv/tcp.titan": "d60f9e62432719f0dd2f2387fb58ad185fef0861c7b1251923c085c36c4295e9",
    "titan/uv/thread-native.h": "3f21558b5d56f539bf293e25f21feaf20b13738d84591e6af7f26cc18762060a",
    "titan/uv/threading.titan": "31272c0fea232f4ad79188443322e64af89cc04bb2dd565f5fe5c2775a811777",
    "titan/uv/transfer-native.h": "cb758073064a42bc66d3ffe4829403d179c5ba943a5824e3a753544917c47335",
    "titan/uv/transfer.titan": "23a4475f92f4b65b99c8e1238bfbcf59a878a8badff6e476a4fffc77f02eed2f",
    "titan/uv/udp.titan": "dbdcca8e11d86e14e275462f2134dfe12b49a459ffcd5861541154c97df4bec5",
    "titan/uv/utilities.titan": "c04d0930ef4748efe2229e8f56e376f0422c332378f919faf8ac3874621f20aa",
    "titan/uv/utility_bits.h": "266f6acacbbe4789cf2d5a193290940d005a89fb472f1170bf5f4ad9ffe484fe",
    "titan/uv/uv.titan": "e1b9d3ee90fd9bb8988166179a873cfd1ebab30cacb092a80173048149cae055",
    "titan/uv/version-native.h": "f50904be5213e873f965a9c0df91fdd84e7bb81c64c754c644a4f01b243f7b13",
    "titan/uv/work-data.h": "6c5d07725136b16e44931d7063166521c3dd36b698669547cdfaae768624f131",
    "titan/websocket/connection.titan": "3b12bd5104ed1d8909f277705071a904aef6c7f0cfcde2ceaef40fe29b862087",
    "titan/websocket/frames.titan": "5f1186d677e4181c84a1ff88d7f03211ad7c594eddd89484637e5bc9843f9fb3",
    "titan/websocket/handshake.titan": "75687fd219930545303c1b6e89f6e1fe58f8c9b93990753f10202d4cc517315b",
    "titan/websocket/native.titan": "e5cb28322f7ef8ee33531482fca6e2bb6d6019cc0ab525d502045365677864d1",
    "titan/websocket/utf8.titan": "b0eda22bfbcd8cb0fb13d105ff49af15cee41316ae8acd5a1d1cd79fae51f26c",
    "titan/websocket/websocket.titan": "9e25d2affc279a4e6cb986b7e6c164d05e91e76c0ee2f0fcd3062c3e6c849b62",
    "vendor/lpeglabel/lplcap.h": "1114fe329cc34c7054938035e73e6bf25802e3b0b88e0f17ebe592587d405013",
    "vendor/lpeglabel/lplcode.h": "84dfbddbd78d4a0f6861dd8be065d5fd1c4c4aac8cd77cea3af4ad286d9be9ac",
    "vendor/lpeglabel/lplprint.h": "1b70e48cc3f8f1a57a3485f5125bda90f230b1c24e06e18adbf4e3c753af992e",
    "vendor/lpeglabel/lpltree.h": "e92d8d4676a7757a028052d0e05056575b3821ba577a63231f37902c0dd180eb",
    "vendor/lpeglabel/lpltypes.h": "d07a72b2470210de6ba82ae868bec93be6b15d15b060d8a8abc926de7d090b70",
    "vendor/lpeglabel/lplvm.h": "6eafc02d33ff9d11abf77b8eb49b086ed684d4394c7303972d46dda7f81c2fe7",
    "vendor/lpeglabel/titan_lpeglabel.h": "3384372e7ed10ca5a18bba7f16dbcf4859a740aff3a4f11ec379e79569eb4a22",
    "vendor/lpeglabel/titan_lpeglabel_namespace.h": "233f2208d0669204031c3475abe4ae3dc376f9381fa1ace36d2330e41554640f"
  },
  "provider_build_evidence": {
    "attestation": "/tmp/titan-issue252-baseline-attested/BUILD-ATTESTATION.json",
    "attestation_sha256": "39e62c71d4010cfe3caf252317b373c4b35036e5d1f66dd82af9b0816de427cf",
    "commands": "/tmp/titan-issue252-baseline-attested/BUILD-COMMANDS.json",
    "commands_sha256": "39a09f78512b5423788290f6bd8df55af8fce5a2cb526941ee529aec8ac113a3",
    "effective_make_policy": "/tmp/titan-issue252-baseline-attested/EFFECTIVE-MAKE-POLICY.txt",
    "effective_make_policy_sha256": "c092161a981e7d599991a3e1e34511369fe92b0669a1f72839471f167c2e5d29",
    "source_after": "/tmp/titan-issue252-baseline-attested/SOURCE-AFTER.json",
    "source_before": "/tmp/titan-issue252-baseline-attested/SOURCE-BEFORE.json"
  },
  "provider_files": {
    "/tmp/titan-issue252-baseline-attested/sdk/bin/lua": "4ff90fc0bccfffb89db1198b3807b2731b1f95686967a42d13f9b78f6f5561ee",
    "/tmp/titan-issue252-baseline-attested/sdk/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc": "567bdf8984e6631a199b3feae238483a632af62aa9239a5864a93fb074ce03b4",
    "/tmp/titan-issue252-baseline-attested/sdk/lib/titan/0.6/libtitan.a": "36b4ef287068434844e7a6da5fc145ad5ae37859103a302e460fb4875fc3513f",
    "/tmp/titan-issue252-baseline-attested/sdk/lib/titan/0.6/titan.a": "35067395ea483ae354f2c9e918fcbed1e97447acf280e24e6723873012c132ef",
    "/tmp/titan-issue252-baseline-attested/sdk/lib/titan/0.6/titan.so": "f786d5c03a682efc0fe3905915853bd2f597cbe9e72349d169500973bf5ef087"
  },
  "source_compile_policy": {
    "build_profile": "production",
    "emit_line_directives": true,
    "extra_cflags": [
      "-fno-strict-aliasing"
    ],
    "generated_cflags": [
      "--std=c99",
      "-O3",
      "-Wall",
      "-Wno-unused-but-set-variable",
      "-Wno-unused-function",
      "-fPIC",
      "-g1",
      "-flto=auto",
      "-ffat-lto-objects",
      "-fno-strict-aliasing"
    ],
    "module_random_seed": {
      "consumer_instrumented": [
        "bench"
      ],
      "consumer_uninstrumented": [
        "bench"
      ],
      "private_provider": [
        "titan.async",
        "titan.coroutine",
        "titan.fs",
        "titan.gc",
        "titan.http",
        "titan.io",
        "titan.iteration",
        "titan.json",
        "titan.lua",
        "titan.math",
        "titan.net",
        "titan.os",
        "titan.path",
        "titan.peg",
        "titan.protobuf",
        "titan.reflect",
        "titan.sqlite3",
        "titan.ssl",
        "titan.string",
        "titan.test",
        "titan.thread",
        "titan.timer",
        "titan.transfer",
        "titan.url",
        "titan.uv",
        "titan.websocket"
      ]
    },
    "private_provider_compile_receipt": "/tmp/titan-issue252-rtt-original-v4/logs/1792291787310150438-compile-private-full-provider.json",
    "probe_cflags": [
      "--std=c99",
      "-O3",
      "-Wall",
      "-Wno-unused-but-set-variable",
      "-Wno-unused-function",
      "-fPIC",
      "-g1",
      "-flto=auto",
      "-ffat-lto-objects",
      "-fno-strict-aliasing",
      "-std=c11",
      "-Wextra",
      "-Werror",
      "-fno-builtin",
      "-frandom-seed=rtt_probe"
    ],
    "probe_policy_difference": "C11, instrumentation diagnostics, no builtins, fixed probe-only random seed"
  },
  "source_sha256": {
    "titan/async.titan": "b384f0e672566f34bbadbeb44c0c2c517e7e925f727df9b9c1a096ec402d43a7",
    "titan/async_receiver_native.h": "0fa7dd008ecb50fc84070eb52014e4223f57d66ab3f82bfeda793ebc475150db",
    "titan/async_signal_platform.h": "3a413448397988560fe12a07e288be7bab73124964c44bac749497b61b069296",
    "titan/coroutine.titan": "be5fd08a6fd6d3b0b2f6b798f4e3ad42c10d1fb5e88aced6209faa59b9e2144b",
    "titan/fs.titan": "a327d9b30d8f680bfb9faa24f514eec2812fede877ab46e3f9531c822e3b99f9",
    "titan/fs_platform.h": "00da49bdf0851c3a4e2f44ed74243ba40a7b41e3d528f41e50b953503b11d879",
    "titan/gc.titan": "03cabaf0a6e2a48be14280d898236fce5334d3cfa769abc4b7c7a4b1632bb638",
    "titan/http/client.titan": "deed2100ec9da07aa4796f90b05d2491846d04accaa9491805548bc8180855b2",
    "titan/http/headers.titan": "8827e4cd9ae5a18cf660289fee5acb0bd774daa97f7c10cc1e220e724c70557d",
    "titan/http/http.titan": "ff6cc19963ed720c9cc3db435cba78fd7b4457260dd49674d983a0c21f725ae2",
    "titan/http/native.titan": "c6dc067689edb2b9cfd7c012e2497806b7c405a500a024aecedcd1b0695f8390",
    "titan/http/pool.titan": "04e290cd0f8f50b120541339ed15b1aa573a49afd145c0d9e8b6d4cae1987646",
    "titan/http/server.titan": "0032dc51c27b386d06ee912f62e27e7fb122c45e84fc58bf1b1f1f2db1066cec",
    "titan/http/transfer.titan": "fbc27658c9752325e48e748f4fa60c148e6cd56e794254df8cfc42fc830411f4",
    "titan/http/upgrade.titan": "82660410330005aca4c3846eea3b3b46cd4196ac280684f14658d1f4b92884c8",
    "titan/io.titan": "a85aea6ee8d66da0d8fc594426b9e9da812c8701916cd37703548513f7c8b57a",
    "titan/iteration.titan": "c5d33ca7f159aef0e9c07163ae8871920f46ce73ad8a6c9565265ec5e636e3d7",
    "titan/json/decoder.titan": "d4def8fce5de08c7c87508ce0a411a1bafe4b9ac5dd6e318ab4062fd99f4a144",
    "titan/json/json.titan": "1fd824d91d9bee28e2093bebc3598fabdcec594d00aafad6d00a991f4643050a",
    "titan/json/numbers.titan": "88f8a136d374276e98d05e047ed32aaa03efd63e56f4a83c516d48d513f3b13a",
    "titan/json/parser.titan": "7f12a7ba9c72bcc3103f2f84939e23a968fd8c4619fa10e8d8495c5f89dffeb2",
    "titan/json/writer.titan": "6667abde3d9f08e1e5711a30ff1ab636288c5c286c9c6916d98e088c52732703",
    "titan/lua/lua.titan": "fe0b752e006c2d8eda5d16a1b4a93f8ff0328b41a30993ef8f53ed2f63ad362e",
    "titan/lua/native.h": "9b5cdc28cab74588ec8ac44085886300d900d7d547c467b171888e2094660d8a",
    "titan/lua/worker.titan": "a405570e4f22e7e42c0af38e29e0e15b9458b9b8ad4206d0c4a3e9d0c96ff88a",
    "titan/math.titan": "15005d85308ffd3e42a79e548f55c5e5d59cd33e8bb7d4cb2608fe1e0d593f3e",
    "titan/net.titan": "e0c586a511979ac7150b2308ef8581740b481cec13441ac3c1196ba1323c19dd",
    "titan/os.titan": "da276574dec7c8a4dee575782ab22a61184baf083d0739be5569597aa6031835",
    "titan/os_environment.h": "e6b805d75104076751c555af08c4ea80881dd93df104dec8ebefd6b12aca982b",
    "titan/os_platform.h": "2ca67def9f3c87a409a9a80c6458aa9d53d7bbc227c0b3a6c07cabafd226770c",
    "titan/path.titan": "43c194cf9b3b4b79c37f652e74b20f20ab77996bbd326ba188b1e4ee2c601086",
    "titan/path_platform.h": "c56729270bb299092c6ac7dd88ae117c97a874393520ce810ef1c8af03e6ecc8",
    "titan/peg/combinators.titan": "e630451865326ab2ccc9b4078f17c12412e6af19155539a28868df7f34751f11",
    "titan/peg/native.titan": "768cb146b1e578521fb97c2318053ff5fc80a7d5b1765d997518002f083e8fd0",
    "titan/peg/peg.titan": "f3771893b9b648af80027ab839ca27e9165a95b94b28ec1d6637b3fa40ece24a",
    "titan/peg/relabel.titan": "3b6bcccd8da929aa1d56da040bc53df9cd24413361536ac9b66d39a3ec186d0f",
    "titan/peg/relabel_parser.titan": "22df8b78c74e0e596d642f60be244f9f17ee20860a52e8d67d90c3cc14eef1d8",
    "titan/protobuf/decoder.titan": "a864fd7450aa83d286ec173a1928b2f6b07f310d484497b0d8ab6e373802be7f",
    "titan/protobuf/encoder.titan": "3c4cc2b49ca8ff3b45334af70ba72a0f5c84c7cd3639d72aafefcd2f040714b9",
    "titan/protobuf/native.h": "256dd809670f6f1a20a2951ff3783f96ce93341cff0408bd55d89af6fcb40d52",
    "titan/protobuf/protobuf.titan": "39cb281542ec090c7f9de94f5ac8eb690ed5f47dec253decc46f78841bdef24f",
    "titan/protobuf/schema.titan": "924b9d92ad0b2f82f61e82ef18cd0be5fbad1dcbbb53dccc929ea569c8294c8f",
    "titan/reflect.titan": "a611557c47f100f7b3f44badbd47dda0bf11b4d7869df7aa7c0d73214ba2fef9",
    "titan/sqlite3/bindings.titan": "17a46365e8c8cb93e329676d35a9e74d151cc9590489a8591c0fd7b6c04a103d",
    "titan/sqlite3/native.h": "ac82a1b9730c6e6692b9e08e3fd8b3d83337df66a6a2c6264a366040d9e992ef",
    "titan/sqlite3/row.titan": "58f91cec279562e60559ab66937a80d01fdd30532a2cff4622da1171b9181618",
    "titan/sqlite3/sqlite3.titan": "bae3cb85db17d0fd48ed4f0b9f3479ecda6842c3994bf25f7b8f2a67d597bc45",
    "titan/sqlite3/worker.titan": "421db60859260a0ed96ca325e0def109b8dbd661a0619870790140668fb23092",
    "titan/ssl.titan": "79b741432798a3f2b73ec85fa33851b1bd3cc3e43fd7a4315a8ea74213ca1fd0",
    "titan/string/bytes.titan": "9448b332fd42bf409b453158305890c8c12eb5eb18df1be9bc92342bcc9c8b3e",
    "titan/string/format.titan": "ff8794649730b36d0185cdecb28cbb9eb0a76ffd0b122e67864de3715b02ae34",
    "titan/string/format_native.h": "f3f97457a9296ea6e32e72e036b05e945f15eb8ef02cccdca8ea816a3ac76b75",
    "titan/string/pack.titan": "20bc7a5a3d4f8b499ae27246559040124886b9925cdf6f05b13167690d2a99c2",
    "titan/string/regex_api.titan": "281d06298980e53cdd2e133bbf5ae1ffbbd5e2dc49974979a17b1970362c6160",
    "titan/string/regex_compile.titan": "8aa476969a2854cdd921e112a5c6d6bf860a9c655261851f8f6cebe7bd0dd786",
    "titan/string/regex_parser.titan": "8402206160bceefe85d38abceb52588357afcf5991d753da4ec4a56c4b84b969",
    "titan/string/string.titan": "e1015dcb814d4c2173e8f14dbe506e3a9d5b96e814a58e818306960e0d2b72ea",
    "titan/test.titan": "1098b360eb4e1312cc3e41fb2c6bc258a68a9d9aba47da5fe7dbbc3a3843edcf",
    "titan/thread/channel.titan": "365c86bf871cb2e71821eefd5b83e13a9cea0f6b24f2801d9fab362ed7e02418",
    "titan/thread/group.titan": "4fe8c6b4d535ea88a5d9e0ab92c2a570c78576e95682ca97ec10de44f9d7bf40",
    "titan/thread/native.h": "3f256682e2e58e8cdc64df768be99874791812c5de4db7dcaf15d02009ce0a10",
    "titan/thread/spawn.titan": "1f12294172ff283d50a361b8cdafcd582bd3e70e6718c300d6f660a50c57d273",
    "titan/thread/thread.titan": "0b7f77fa0e3e89b569a9b4243f8bc2485a1a3e82b6b65e357e7107439be33083",
    "titan/timer.titan": "bcbbaf7ca0a83e6305b7c436523bbe938454254b1967a1e2c717417d44e69d1b",
    "titan/transfer.titan": "4e6c0181e4c9f69f62afca227e2b05b2530b9fa5a7188d1372b6c543ded8948c",
    "titan/url.titan": "c130c7e2736759cceed9f0c9955e457d9253c94cbe0784adb74d990b2891f9ab",
    "titan/uv/address-native.h": "a77fc869a5ddefee6dd053c0f1df552e6bb96a320a1f8bf0e2a5b3c28ac61525",
    "titan/uv/address.titan": "67d85cfbf9382484c49dd7e3b396963db5ef337508d2cbafc2dc50d9ea4f3c84",
    "titan/uv/callback.h": "de7a15347fe4586ffe9dd7a7f3dfc9931ed488a8babde23f81dfc53bd1d89bee",
    "titan/uv/callbacks.titan": "d605d2cd36704a1c1cd19eb5b988045865141738b94dd1d9c92c85b507b0832f",
    "titan/uv/capabilities.titan": "b79d72cb392a74828f1aa0a82a781b2d83ab09d7803c17a85986c899a4ad9b5f",
    "titan/uv/constants.titan": "58042ab8d85fe014a4dd3c940b0594710fdc76cf35f4e6eb64bc8eecc8bed330",
    "titan/uv/data.titan": "565de88997eba8034f5431ead7a80a2ed37aff12a8932aedf85a225d0474fb8a",
    "titan/uv/data_native.h": "68cf454e225b200572d5de46ada8b091d774a661ebe39b7160c18bf4c5d195c1",
    "titan/uv/dll.titan": "51aae662b051bb5fcd4bc61fd41e36e032c5ce95f45822f6e81fec347a214800",
    "titan/uv/dns.titan": "d79ae8118ee8d2d17e29ac050370d967f7096d4c56efdc5c7e4eef281f93d868",
    "titan/uv/fd-native.h": "310b9f22163030d72ae29bf32f06b63ac253db23ada7dce7ef5833ce3ef3dd9f",
    "titan/uv/fd.titan": "0d754b9e83e2d3506ae988d46bd160a3b9df867a751c43ba7ec6e8c8caff7953",
    "titan/uv/identifiers.titan": "a5b033d59b4593db7ed8512558468708b7cc55fe94555505ada36f32a3406d08",
    "titan/uv/network-native.h": "aa68b33b4533ccf0a9a21da5037c8a75d942b5cf0fcbfaf860501673ebb1b78d",
    "titan/uv/pipe_tty.titan": "c993616548c9e0957355ce7cfad76daef24b44353749c7af9f4648acd5c8b0c8",
    "titan/uv/platform-constants.h": "026ede031bc7ebb28ed0504d29a2a077175c152cf18d181120944bd43ac46a26",
    "titan/uv/platform_constants.titan": "c322cb9c80ffdb8406ab643ac935f8cc5ad7d7736e09711abb3e826e2d007255",
    "titan/uv/process.titan": "94145f180cc85848c118adec809c6e4efa153199053b874b5b035046f518e14d",
    "titan/uv/startup.titan": "31e0376df10ec0ef59257f59160b7e6958df301fb1e3d167544519dc35f2381f",
    "titan/uv/stream_ops.titan": "6ecb4e474f66c6507c8c7f29114e2c95cf84a0d6df62aa7b37f0ce1708037071",
    "titan/uv/stream_owners.titan": "8cc33b19287a8f4edd25e05e65270bda2f6bbefbc024da80187f6e3e5ba1de4e",
    "titan/uv/sync.titan": "95906e8bd3f522351014942298633dfba96872545ccdb94e1a401ca2bae03e8e",
    "titan/uv/sync_storage.h": "735846d522d0d8ac547b90b72c4104bd91bbf35ce77a9485ad57bd49f2eea579",
    "titan/uv/tcp.titan": "d60f9e62432719f0dd2f2387fb58ad185fef0861c7b1251923c085c36c4295e9",
    "titan/uv/thread-native.h": "3f21558b5d56f539bf293e25f21feaf20b13738d84591e6af7f26cc18762060a",
    "titan/uv/threading.titan": "31272c0fea232f4ad79188443322e64af89cc04bb2dd565f5fe5c2775a811777",
    "titan/uv/transfer-native.h": "cb758073064a42bc66d3ffe4829403d179c5ba943a5824e3a753544917c47335",
    "titan/uv/transfer.titan": "23a4475f92f4b65b99c8e1238bfbcf59a878a8badff6e476a4fffc77f02eed2f",
    "titan/uv/udp.titan": "dbdcca8e11d86e14e275462f2134dfe12b49a459ffcd5861541154c97df4bec5",
    "titan/uv/utilities.titan": "c04d0930ef4748efe2229e8f56e376f0422c332378f919faf8ac3874621f20aa",
    "titan/uv/utility_bits.h": "266f6acacbbe4789cf2d5a193290940d005a89fb472f1170bf5f4ad9ffe484fe",
    "titan/uv/uv.titan": "e1b9d3ee90fd9bb8988166179a873cfd1ebab30cacb092a80173048149cae055",
    "titan/uv/version-native.h": "f50904be5213e873f965a9c0df91fdd84e7bb81c64c754c644a4f01b243f7b13",
    "titan/uv/work-data.h": "6c5d07725136b16e44931d7063166521c3dd36b698669547cdfaae768624f131",
    "titan/websocket/connection.titan": "3b12bd5104ed1d8909f277705071a904aef6c7f0cfcde2ceaef40fe29b862087",
    "titan/websocket/frames.titan": "5f1186d677e4181c84a1ff88d7f03211ad7c594eddd89484637e5bc9843f9fb3",
    "titan/websocket/handshake.titan": "75687fd219930545303c1b6e89f6e1fe58f8c9b93990753f10202d4cc517315b",
    "titan/websocket/native.titan": "e5cb28322f7ef8ee33531482fca6e2bb6d6019cc0ab525d502045365677864d1",
    "titan/websocket/utf8.titan": "b0eda22bfbcd8cb0fb13d105ff49af15cee41316ae8acd5a1d1cd79fae51f26c",
    "titan/websocket/websocket.titan": "9e25d2affc279a4e6cb986b7e6c164d05e91e76c0ee2f0fcd3062c3e6c849b62",
    "vendor/lpeglabel/lplcap.h": "1114fe329cc34c7054938035e73e6bf25802e3b0b88e0f17ebe592587d405013",
    "vendor/lpeglabel/lplcode.h": "84dfbddbd78d4a0f6861dd8be065d5fd1c4c4aac8cd77cea3af4ad286d9be9ac",
    "vendor/lpeglabel/lplprint.h": "1b70e48cc3f8f1a57a3485f5125bda90f230b1c24e06e18adbf4e3c753af992e",
    "vendor/lpeglabel/lpltree.h": "e92d8d4676a7757a028052d0e05056575b3821ba577a63231f37902c0dd180eb",
    "vendor/lpeglabel/lpltypes.h": "d07a72b2470210de6ba82ae868bec93be6b15d15b060d8a8abc926de7d090b70",
    "vendor/lpeglabel/lplvm.h": "6eafc02d33ff9d11abf77b8eb49b086ed684d4394c7303972d46dda7f81c2fe7",
    "vendor/lpeglabel/titan_lpeglabel.h": "3384372e7ed10ca5a18bba7f16dbcf4859a740aff3a4f11ec379e79569eb4a22",
    "vendor/lpeglabel/titan_lpeglabel_namespace.h": "233f2208d0669204031c3475abe4ae3dc376f9381fa1ace36d2330e41554640f"
  },
  "tools": {
    "ar": {
      "argv": [
        "/usr/bin/ar"
      ],
      "executable_sha256": "97910d3148c2a6bbaf899821e6f6c07c602fcd1ef00f081ec7a58a348288b7c5"
    },
    "cc": {
      "argv": [
        "/usr/bin/gcc"
      ],
      "executable_sha256": "153e46b4657620f2baef1b4a70b4b4f275772faa5b0fb9e415697e87ebcb7fea"
    },
    "ranlib": {
      "argv": [
        "/usr/bin/ranlib"
      ],
      "executable_sha256": "dc7e8f99cf5956e5ba2540f61f213cc4bbfa08ba2d40a33fe2adbfe726f2948d"
    }
  }
}
```

</details>

## baseline marginal results

Catalog: 53 cases; this report contains 53 measured cases.

Uninstrumented timing uses the original immutable SDK. Instrumented timing uses a private full-provider rebuild with source-scoped semantic probes and the original native payload. The difference below is instrumentation overhead, not a production speedup.

### Uninstrumented end-to-end timing

| Case | Protocol | Rounds / samples | us/op median [range] | RTT p50/p95/p99 us | ops/s | Cold first use us | Residual GC us/op | Retire us |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `call_control` | `same_state` | 6 / 60000 | 0.053 [0.052..0.079] | 0.030/0.030/0.036 | 18707532.8 | 7967.0 | 0.046 | 0.4 |
| `churn_cancel_parked_waiters` | `cancel_churn` | 6 / 3000 | 73.467 [69.899..83.195] | 52.037/129.702/518.214 | 13611.6 | 8366.5 | 3.616 | 54.5 |
| `churn_close_parked_receivers` | `close_churn` | 6 / 3000 | 23.243 [21.295..24.564] | 13.891/39.404/261.339 | 43024.5 | 7553.2 | 6.197 | 54.0 |
| `churn_close_parked_senders` | `close_churn` | 6 / 3000 | 38.728 [36.780..43.611] | 27.026/71.920/392.163 | 25821.6 | 8102.1 | 8.838 | 58.6 |
| `closure_roundtrip_cap0` | `same_state` | 6 / 6000 | 5.633 [5.351..7.164] | 4.062/10.530/53.215 | 177522.1 | 7732.3 | 0.773 | 2.3 |
| `closure_roundtrip_cap1` | `same_state` | 6 / 6000 | 9.232 [8.609..16.122] | 6.482/24.986/67.907 | 108631.9 | 8710.0 | 0.588 | 2.7 |
| `closure_roundtrip_cap64` | `same_state` | 6 / 6000 | 152.208 [141.913..155.756] | 84.828/598.875/866.094 | 6570.1 | 9173.1 | 0.904 | 2.3 |
| `closure_roundtrip_cap8` | `same_state` | 6 / 6000 | 27.664 [22.590..52.477] | 13.991/111.222/215.167 | 36677.8 | 8933.3 | 1.357 | 2.8 |
| `closure_roundtrip_complex_sig` | `same_state` | 6 / 6000 | 10.259 [9.227..14.886] | 6.592/30.698/67.416 | 97729.6 | 7905.9 | 0.875 | 2.3 |
| `codec_large64k_decode` | `same_state` | 6 / 1536 | 6.985 [6.582..7.517] | 2.304/17.944/55.864 | 143185.2 | 7425.5 | 2.272 | 1.3 |
| `codec_large64k_encode` | `same_state` | 6 / 1536 | 11.538 [7.597..16.270] | 6.447/34.013/90.013 | 86683.7 | 9902.7 | 2.484 | 2.2 |
| `codec_large64k_transfer_roundtrip` | `same_state` | 6 / 1536 | 9.685 [8.474..17.414] | 5.886/23.514/85.821 | 103265.0 | 7176.7 | 3.237 | 1.7 |
| `codec_scalar_roundtrip` | `same_state` | 6 / 30000 | 0.163 [0.147..0.214] | 0.120/0.185/0.250 | 6143343.3 | 8842.1 | 0.104 | 0.8 |
| `codec_small_decode` | `same_state` | 6 / 30000 | 1.082 [0.972..1.340] | 0.601/1.558/3.933 | 926946.8 | 7478.9 | 0.188 | 2.0 |
| `codec_small_encode` | `same_state` | 6 / 30000 | 0.568 [0.455..0.942] | 0.376/1.062/1.667 | 1806523.7 | 10058.1 | 0.207 | 1.6 |
| `codec_small_transfer_roundtrip` | `same_state` | 6 / 30000 | 2.401 [1.930..3.865] | 1.247/3.341/14.887 | 418351.9 | 7266.5 | 0.203 | 2.5 |
| `codec_wide16_decode` | `same_state` | 6 / 30000 | 2.573 [2.410..2.632] | 1.603/3.091/38.608 | 388680.0 | 8941.9 | 0.160 | 2.3 |
| `codec_wide16_encode` | `same_state` | 6 / 30000 | 1.333 [1.034..2.159] | 1.252/2.018/2.660 | 750864.2 | 10413.5 | 0.249 | 1.8 |
| `codec_wide16_transfer_roundtrip` | `same_state` | 6 / 30000 | 4.051 [3.787..4.577] | 2.750/5.390/43.627 | 246884.0 | 10961.4 | 0.150 | 2.3 |
| `inspect_function` | `same_state` | 6 / 6000 | 1.979 [1.953..2.055] | 1.744/2.500/4.037 | 505334.3 | 10059.3 | 0.962 | 1.0 |
| `inspect_record` | `same_state` | 6 / 30000 | 0.198 [0.155..0.261] | 0.126/0.206/0.837 | 5207028.9 | 8425.8 | 0.130 | 0.8 |
| `join_cleanup_cancelled_task` | `cleanup_join` | 6 / 600 | 42153.113 [40409.761..44982.203] | 41427.945/50969.602/60467.568 | 23.7 | 8423.5 | 20.683 | 56.5 |
| `join_ordinary` | `ordinary_join` | 6 / 600 | 6768.378 [6375.698..7675.770] | 6748.211/7769.992/8299.215 | 147.8 | 8606.5 | 35.701 | 49.1 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | `pool_16_reply` | 6 / 6000 | 3.642 [2.459..4.016] | 39.819/85.870/150.190 | 275141.8 | 8566.8 | 1.108 | 5813.6 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `pool_16_reply` | 6 / 6000 | 3.488 [2.599..4.928] | 36.228/88.590/147.351 | 287895.6 | 8263.6 | 1.388 | 5391.6 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `pool_four_reply` | 6 / 6000 | 20.832 [17.262..23.854] | 18.615/30.051/50.370 | 48209.0 | 7309.3 | 1.211 | 4659.2 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `pool_four_reply` | 6 / 6000 | 7.452 [6.037..7.718] | 24.731/45.516/70.482 | 134210.3 | 10054.9 | 0.887 | 5292.4 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `pool_four_reply` | 6 / 6000 | 6.090 [5.417..8.542] | 21.225/32.901/61.485 | 164244.1 | 9304.6 | 1.011 | 4785.3 |
| `mpmc_record_inflight16_cap16_4p4c` | `pool_16_reply` | 6 / 6000 | 3.473 [2.711..5.141] | 36.894/121.146/187.897 | 287934.0 | 9504.5 | 1.174 | 4604.7 |
| `mpmc_record_inflight16_cap2_4p4c` | `pool_16_reply` | 6 / 6000 | 3.533 [3.171..4.518] | 35.666/140.522/210.874 | 284594.2 | 8073.5 | 0.909 | 4359.5 |
| `mpmc_record_inflight1_cap1_2p2c` | `pool_four_reply` | 6 / 6000 | 18.843 [14.233..21.439] | 17.168/23.058/41.197 | 53071.6 | 9053.4 | 0.985 | 4407.2 |
| `mpmc_record_inflight4_cap1_2p2c` | `pool_four_reply` | 6 / 6000 | 6.095 [4.794..7.476] | 19.421/40.511/63.544 | 164854.7 | 8886.5 | 0.875 | 4428.2 |
| `mpmc_record_inflight4_cap4_2p2c` | `pool_four_reply` | 6 / 6000 | 5.440 [4.311..6.382] | 18.444/28.854/48.757 | 183864.3 | 8281.9 | 0.804 | 3973.6 |
| `overhead_control` | `same_state` | 6 / 60000 | 0.066 [0.065..0.068] | 0.040/0.041/0.050 | 15209871.9 | 10264.2 | 0.041 | 0.5 |
| `queue_opaque_hook8` | `same_state_queue` | 6 / 30000 | 3.649 [2.701..4.099] | 2.229/4.178/44.319 | 274878.3 | 8307.0 | 0.296 | 80.1 |
| `queue_packed_hook8` | `same_state_queue` | 6 / 30000 | 3.765 [3.688..4.605] | 2.415/5.269/43.526 | 265612.6 | 7554.0 | 0.184 | 65.0 |
| `queue_plain_bytes8` | `same_state_queue` | 6 / 30000 | 2.152 [1.968..2.696] | 1.397/2.775/12.378 | 464814.5 | 8572.9 | 0.234 | 47.1 |
| `queue_real_receiver` | `same_state_queue` | 6 / 30000 | 4.253 [4.020..4.974] | 2.675/9.167/46.437 | 235125.8 | 8548.7 | 0.204 | 72.6 |
| `queue_real_sender` | `same_state_queue` | 6 / 30000 | 4.320 [4.208..8.285] | 2.695/9.453/50.144 | 231515.9 | 8397.8 | 0.225 | 85.2 |
| `sender_clone` | `same_state_queue` | 6 / 30000 | 0.203 [0.182..0.300] | 0.161/0.235/0.787 | 4928347.9 | 7775.6 | 0.160 | 31.8 |
| `spsc_endpoint_carried_persistent` | `persistent_reply` | 6 / 6000 | 21.610 [15.434..30.946] | 17.858/43.792/101.930 | 46274.2 | 8466.1 | 2.022 | 1353.0 |
| `spsc_endpoint_fresh_reply` | `fresh_reply` | 6 / 3000 | 14.289 [11.936..22.645] | 11.191/23.934/35.401 | 71183.0 | 8515.3 | 2.952 | 1308.1 |
| `spsc_endpoint_pool4_reply` | `pool_four_reply` | 6 / 6000 | 21.001 [20.049..26.649] | 16.155/48.295/105.762 | 47645.1 | 8326.8 | 1.615 | 1191.9 |
| `spsc_large64k_endpoint_pool4` | `pool_four_reply` | 6 / 1536 | 28.110 [21.861..40.970] | 23.019/61.049/106.194 | 36293.1 | 8966.3 | 5.117 | 862.1 |
| `spsc_large64k_persistent` | `persistent_reply` | 6 / 1536 | 24.363 [20.826..44.392] | 19.297/46.943/108.312 | 41249.1 | 8240.3 | 4.521 | 944.4 |
| `spsc_opaque_persistent` | `persistent_reply` | 6 / 6000 | 20.170 [14.650..25.651] | 15.594/42.930/101.315 | 50066.5 | 8418.3 | 1.390 | 1115.4 |
| `spsc_record_persistent` | `persistent_reply` | 6 / 6000 | 17.987 [11.666..21.915] | 15.444/28.974/76.382 | 55970.0 | 9352.6 | 1.605 | 1950.6 |
| `spsc_record_pool4_control` | `pool_four_reply` | 6 / 6000 | 16.060 [11.453..22.301] | 13.605/29.395/74.669 | 62436.5 | 8797.5 | 1.851 | 1627.8 |
| `spsc_scalar_persistent` | `persistent_reply` | 6 / 6000 | 5.781 [4.226..9.332] | 5.511/9.959/18.149 | 172966.3 | 7972.9 | 1.304 | 1255.2 |
| `wait_empty_receiver_endpoint` | `directed_empty_wait` | 6 / 3000 | 33.906 [26.579..40.987] | 24.275/62.321/199.613 | 29503.1 | 8163.9 | 5.624 | 1653.9 |
| `wait_empty_receiver_record` | `directed_empty_wait` | 6 / 3000 | 33.536 [23.506..39.484] | 19.913/60.849/183.603 | 30128.1 | 8253.5 | 2.825 | 1387.5 |
| `wait_full_sender_endpoint` | `directed_full_wait` | 6 / 3000 | 35.000 [32.697..44.919] | 24.576/76.107/201.933 | 28617.8 | 8743.8 | 7.477 | 1807.3 |
| `wait_full_sender_record` | `directed_full_wait` | 6 / 3000 | 31.392 [28.826..34.573] | 18.730/65.507/177.061 | 31879.0 | 7986.0 | 3.563 | 1499.9 |

RTT columns are medians of per-round percentiles, not pooled percentiles. Directed full-sender samples are admission/previous-packet release acknowledgements, not processing RTTs for the newly admitted request. Churn includes fresh resource/state creation.

### Exact native branch counts (representative instrumented round)

Counters/per-op traffic select the actual upper-median body-time round; all instrumented rounds remain in the summary JSON. Counts are branch events within the body window, including worker request receives and protocol-control channels. A wait can begin before the window. Fast successes are successful first readiness checks, not post-suspension retry successes. Closed outcomes are never counted as successful fast paths/rechecks. Slow attempts are failed ready checks entering registration; native suspensions, successful registration rechecks, selected waiter notification attempts and nominal CancellationReason errors are separate events.

| Case | Fast | Slow | Recheck OK | Suspends | Ordinary / cleanup join suspends | Notify | Cancel | Async init / public close requests |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `call_control` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `churn_cancel_parked_waiters` | 500 | 1000 | 0 | 1000 | 0 / 0 | 0 | 1000 | 1000 / 1000 |
| `churn_close_parked_receivers` | 0 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 1000 / 1000 |
| `churn_close_parked_senders` | 500 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 1000 / 1000 |
| `closure_roundtrip_cap0` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `closure_roundtrip_cap1` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `closure_roundtrip_cap64` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `closure_roundtrip_cap8` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `closure_roundtrip_complex_sig` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_large64k_decode` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_large64k_encode` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_large64k_transfer_roundtrip` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_scalar_roundtrip` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_small_decode` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_small_encode` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_small_transfer_roundtrip` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_wide16_decode` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_wide16_encode` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_wide16_transfer_roundtrip` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `inspect_function` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `inspect_record` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `join_cleanup_cancelled_task` | 300 | 600 | 0 | 600 | 100 / 100 | 400 | 200 | 800 / 700 |
| `join_ordinary` | 200 | 300 | 0 | 300 | 100 / 0 | 300 | 0 | 500 / 400 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 4363 | 2711 | 269 | 2442 | 0 / 0 | 2502 | 0 | 2711 / 2771 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 4340 | 2718 | 304 | 2414 | 0 / 0 | 2474 | 0 | 2718 / 2778 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 4003 | 2502 | 1 | 2501 | 0 / 0 | 2501 | 0 | 2502 / 2502 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 4090 | 2693 | 368 | 2325 | 0 / 0 | 2331 | 0 | 2693 / 2699 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 4327 | 2312 | 201 | 2111 | 0 / 0 | 2117 | 0 | 2312 / 2318 |
| `mpmc_record_inflight16_cap16_4p4c` | 4806 | 2026 | 91 | 1935 | 0 / 0 | 1995 | 0 | 2026 / 2086 |
| `mpmc_record_inflight16_cap2_4p4c` | 4446 | 2576 | 265 | 2311 | 0 / 0 | 2371 | 0 | 2576 / 2636 |
| `mpmc_record_inflight1_cap1_2p2c` | 4002 | 2604 | 0 | 2604 | 0 / 0 | 2604 | 0 | 2604 / 2604 |
| `mpmc_record_inflight4_cap1_2p2c` | 4106 | 2602 | 417 | 2185 | 0 / 0 | 2191 | 0 | 2602 / 2608 |
| `mpmc_record_inflight4_cap4_2p2c` | 4252 | 2397 | 180 | 2217 | 0 / 0 | 2223 | 0 | 2397 / 2403 |
| `overhead_control` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_opaque_hook8` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_packed_hook8` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_plain_bytes8` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_real_receiver` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_real_sender` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `sender_clone` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `spsc_endpoint_carried_persistent` | 2000 | 2000 | 24 | 1976 | 0 / 0 | 1976 | 0 | 2000 / 2000 |
| `spsc_endpoint_fresh_reply` | 1000 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 1000 / 1000 |
| `spsc_endpoint_pool4_reply` | 2000 | 2000 | 23 | 1977 | 0 / 0 | 1977 | 0 | 2000 / 2000 |
| `spsc_large64k_endpoint_pool4` | 512 | 512 | 0 | 512 | 0 / 0 | 512 | 0 | 512 / 512 |
| `spsc_large64k_persistent` | 512 | 512 | 0 | 512 | 0 / 0 | 512 | 0 | 512 / 512 |
| `spsc_opaque_persistent` | 2000 | 2000 | 25 | 1975 | 0 / 0 | 1975 | 0 | 2000 / 2000 |
| `spsc_record_persistent` | 2000 | 2000 | 0 | 2000 | 0 / 0 | 2000 | 0 | 2000 / 2000 |
| `spsc_record_pool4_control` | 2000 | 2000 | 5 | 1995 | 0 / 0 | 1995 | 0 | 2000 / 2000 |
| `spsc_scalar_persistent` | 2000 | 2000 | 270 | 1729 | 0 / 0 | 1730 | 0 | 2000 / 2000 |
| `wait_empty_receiver_endpoint` | 1000 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 1000 / 1000 |
| `wait_empty_receiver_record` | 1000 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 1000 / 1000 |
| `wait_full_sender_endpoint` | 1533 | 1467 | 123 | 1344 | 0 / 0 | 1344 | 0 | 1467 / 1467 |
| `wait_full_sender_record` | 1826 | 1174 | 105 | 1069 | 0 / 0 | 1069 | 0 | 1174 / 1174 |

### Native async handle retirement (representative instrumented round)

| Case | Whole-case async init | Public close requests | Terminal close callbacks | Async retirements at successful loop close | Successful / attempted loop closes |
|---|---:|---:|---:|---:|---:|
| `call_control` | 0 | 0 | 0 | 0 | 0 / 0 |
| `churn_cancel_parked_waiters` | 1065 | 1064 | 1064 | 1 | 1 / 1 |
| `churn_close_parked_receivers` | 1065 | 1064 | 1064 | 1 | 1 / 1 |
| `churn_close_parked_senders` | 1065 | 1064 | 1064 | 1 | 1 / 1 |
| `closure_roundtrip_cap0` | 0 | 0 | 0 | 0 | 0 / 0 |
| `closure_roundtrip_cap1` | 0 | 0 | 0 | 0 | 0 / 0 |
| `closure_roundtrip_cap64` | 0 | 0 | 0 | 0 | 0 / 0 |
| `closure_roundtrip_cap8` | 0 | 0 | 0 | 0 | 0 / 0 |
| `closure_roundtrip_complex_sig` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_large64k_decode` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_large64k_encode` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_large64k_transfer_roundtrip` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_scalar_roundtrip` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_small_decode` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_small_encode` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_small_transfer_roundtrip` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_wide16_decode` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_wide16_encode` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_wide16_transfer_roundtrip` | 0 | 0 | 0 | 0 | 0 / 0 |
| `inspect_function` | 0 | 0 | 0 | 0 | 0 / 0 |
| `inspect_record` | 0 | 0 | 0 | 0 | 0 / 0 |
| `join_cleanup_cancelled_task` | 865 | 756 | 756 | 109 | 109 / 109 |
| `join_ordinary` | 541 | 432 | 432 | 109 | 109 / 109 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 14143 | 14134 | 14134 | 9 | 9 / 9 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 14548 | 14539 | 14539 | 9 | 9 / 9 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 2842 | 2837 | 2837 | 5 | 5 / 5 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 4071 | 4066 | 4066 | 5 | 5 / 5 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 3536 | 3531 | 3531 | 5 | 5 / 5 |
| `mpmc_record_inflight16_cap16_4p4c` | 13472 | 13463 | 13463 | 9 | 9 / 9 |
| `mpmc_record_inflight16_cap2_4p4c` | 14052 | 14043 | 14043 | 9 | 9 / 9 |
| `mpmc_record_inflight1_cap1_2p2c` | 2930 | 2925 | 2925 | 5 | 5 / 5 |
| `mpmc_record_inflight4_cap1_2p2c` | 3901 | 3896 | 3896 | 5 | 5 / 5 |
| `mpmc_record_inflight4_cap4_2p2c` | 3689 | 3684 | 3684 | 5 | 5 / 5 |
| `overhead_control` | 0 | 0 | 0 | 0 | 0 / 0 |
| `queue_opaque_hook8` | 1 | 0 | 0 | 1 | 1 / 1 |
| `queue_packed_hook8` | 1 | 0 | 0 | 1 | 1 / 1 |
| `queue_plain_bytes8` | 1 | 0 | 0 | 1 | 1 / 1 |
| `queue_real_receiver` | 1 | 0 | 0 | 1 | 1 / 1 |
| `queue_real_sender` | 1 | 0 | 0 | 1 | 1 / 1 |
| `sender_clone` | 1 | 0 | 0 | 1 | 1 / 1 |
| `spsc_endpoint_carried_persistent` | 2134 | 2132 | 2132 | 2 | 2 / 2 |
| `spsc_endpoint_fresh_reply` | 1070 | 1068 | 1068 | 2 | 2 / 2 |
| `spsc_endpoint_pool4_reply` | 2134 | 2132 | 2132 | 2 | 2 / 2 |
| `spsc_large64k_endpoint_pool4` | 550 | 548 | 548 | 2 | 2 / 2 |
| `spsc_large64k_persistent` | 550 | 548 | 548 | 2 | 2 / 2 |
| `spsc_opaque_persistent` | 2134 | 2132 | 2132 | 2 | 2 / 2 |
| `spsc_record_persistent` | 2134 | 2132 | 2132 | 2 | 2 / 2 |
| `spsc_record_pool4_control` | 2134 | 2132 | 2132 | 2 | 2 / 2 |
| `spsc_scalar_persistent` | 2134 | 2132 | 2132 | 2 | 2 / 2 |
| `wait_empty_receiver_endpoint` | 1070 | 1068 | 1068 | 2 | 2 / 2 |
| `wait_empty_receiver_record` | 1070 | 1068 | 1068 | 2 | 2 / 2 |
| `wait_full_sender_endpoint` | 1569 | 1567 | 1567 | 2 | 2 / 2 |
| `wait_full_sender_record` | 1276 | 1274 | 1274 | 2 | 2 / 2 |

Whole-case counters start at the setup snapshot after cold first use; identities are tracked from process birth, including cold loops. Libuv initializes loop-internal async handles through uv_async_init but retires them directly during successful uv_loop_close. Those retirements are not fabricated public close requests or callbacks. A busy/failed loop close retires no identity; active_async_handles remains the actual unretired registry count and must be zero. Real UV allocation traffic is not suppressed.


### Allocation and observed copy traffic

| Case | Lua allocs / requested B per op | Native allocs / requested B per op | Interposed copy B/op (outside / inside Lua allocator) | Analytical reference B/op (not wire/copy bytes) |
|---|---:|---:|---:|---:|
| `call_control` | 0.00 / 0.0 | 0.00 / 0.0 | 0.0 (0.0 / 0.0) | 0 |
| `churn_cancel_parked_waiters` | 104.62 / 26251.5 | 8.00 / 512.0 | 9967.0 (9967.0 / 0.0) | 0 |
| `churn_close_parked_receivers` | 84.72 / 18483.7 | 3.00 / 152.0 | 47.6 (47.6 / 0.0) | 0 |
| `churn_close_parked_senders` | 88.28 / 19697.2 | 6.00 / 464.0 | 2411.2 (2411.2 / 0.0) | 0 |
| `closure_roundtrip_cap0` | 100.01 / 5011.6 | 1.00 / 128.0 | 212.0 (212.0 / 0.0) | 0 |
| `closure_roundtrip_cap1` | 153.02 / 7916.8 | 2.00 / 384.0 | 373.1 (373.1 / 0.0) | 0 |
| `closure_roundtrip_cap64` | 3148.12 / 194027.0 | 4.00 / 1920.0 | 12147.4 (12147.4 / 0.0) | 0 |
| `closure_roundtrip_cap8` | 498.03 / 28580.6 | 2.00 / 384.0 | 1612.4 (1612.4 / 0.0) | 0 |
| `closure_roundtrip_complex_sig` | 168.02 / 9797.0 | 2.00 / 384.0 | 556.2 (556.2 / 0.0) | 0 |
| `codec_large64k_decode` | 16.02 / 66349.6 | 0.00 / 0.0 | 65562.0 (65562.0 / 0.0) | 65540 |
| `codec_large64k_encode` | 7.02 / 65953.6 | 2.00 / 131136.0 | 131076.0 (131076.0 / 0.0) | 65540 |
| `codec_large64k_transfer_roundtrip` | 25.02 / 66969.7 | 2.00 / 131200.0 | 131113.0 (131113.0 / 0.0) | 65540 |
| `codec_scalar_roundtrip` | 1.00 / 48.0 | 1.00 / 104.0 | 0.0 (0.0 / 0.0) | 8 |
| `codec_small_decode` | 21.00 / 1049.0 | 0.00 / 0.0 | 83.0 (83.0 / 0.0) | 11 |
| `codec_small_encode` | 6.00 / 380.0 | 1.00 / 64.0 | 7.0 (7.0 / 0.0) | 11 |
| `codec_small_transfer_roundtrip` | 30.00 / 1669.0 | 2.00 / 384.0 | 106.0 (106.0 / 0.0) | 11 |
| `codec_wide16_decode` | 44.00 / 3805.0 | 0.00 / 0.0 | 749.0 (749.0 / 0.0) | 33 |
| `codec_wide16_encode` | 6.00 / 380.0 | 1.00 / 64.0 | 0.0 (0.0 / 0.0) | 33 |
| `codec_wide16_transfer_roundtrip` | 53.00 / 4425.0 | 2.00 / 384.0 | 764.0 (764.0 / 0.0) | 33 |
| `inspect_function` | 50.01 / 2376.4 | 0.00 / 0.0 | 80.0 (80.0 / 0.0) | 0 |
| `inspect_record` | 2.00 / 172.0 | 0.00 / 0.0 | 0.0 (0.0 / 0.0) | 0 |
| `join_cleanup_cancelled_task` | 25091.59 / 4042419.3 | 26.00 / 3560.0 | 4964340.4 (4964340.4 / 0.0) | 0 |
| `join_ordinary` | 24612.47 / 3990403.3 | 19.00 / 2640.0 | 1645086.7 (1645086.7 / 0.0) | 0 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 138.61 / 9642.5 | 5.07 / 879.1 | 325.4 (325.4 / 0.0) | 0 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 138.56 / 9653.2 | 5.07 / 879.1 | 325.3 (325.3 / 0.0) | 0 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 135.39 / 9306.5 | 5.00 / 872.4 | 325.0 (325.0 / 0.0) | 0 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 137.40 / 9552.9 | 5.01 / 873.0 | 325.0 (325.0 / 0.0) | 0 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 132.63 / 9047.6 | 5.01 / 873.0 | 325.1 (325.1 / 0.0) | 0 |
| `mpmc_record_inflight16_cap16_4p4c` | 99.10 / 6858.5 | 5.07 / 879.1 | 265.4 (265.4 / 0.0) | 0 |
| `mpmc_record_inflight16_cap2_4p4c` | 105.78 / 7587.1 | 5.07 / 879.1 | 265.2 (265.2 / 0.0) | 0 |
| `mpmc_record_inflight1_cap1_2p2c` | 106.81 / 7619.7 | 5.00 / 872.4 | 265.0 (265.0 / 0.0) | 0 |
| `mpmc_record_inflight4_cap1_2p2c` | 106.05 / 7598.6 | 5.01 / 873.0 | 265.1 (265.1 / 0.0) | 0 |
| `mpmc_record_inflight4_cap4_2p2c` | 103.84 / 7341.7 | 5.01 / 873.0 | 265.1 (265.1 / 0.0) | 0 |
| `overhead_control` | 0.00 / 0.0 | 0.00 / 0.0 | 0.0 (0.0 / 0.0) | 0 |
| `queue_opaque_hook8` | 42.00 / 2525.0 | 2.00 / 384.0 | 139.0 (139.0 / 0.0) | 21 |
| `queue_packed_hook8` | 63.00 / 3633.0 | 2.00 / 384.0 | 196.0 (196.0 / 0.0) | 21 |
| `queue_plain_bytes8` | 34.00 / 1933.0 | 2.00 / 384.0 | 139.0 (139.0 / 0.0) | 21 |
| `queue_real_receiver` | 64.00 / 3761.1 | 2.00 / 384.0 | 198.0 (198.0 / 0.0) | 21 |
| `queue_real_sender` | 64.00 / 3761.1 | 2.00 / 384.0 | 196.0 (196.0 / 0.0) | 21 |
| `sender_clone` | 2.00 / 168.0 | 0.00 / 0.0 | 0.0 (0.0 / 0.0) | 21 |
| `spsc_endpoint_carried_persistent` | 126.40 / 8507.1 | 4.00 / 768.0 | 325.0 (325.0 / 0.0) | 29 |
| `spsc_endpoint_fresh_reply` | 132.50 / 8917.8 | 7.00 / 920.0 | 325.0 (325.0 / 0.0) | 29 |
| `spsc_endpoint_pool4_reply` | 126.42 / 8507.8 | 4.00 / 768.0 | 325.0 (325.0 / 0.0) | 29 |
| `spsc_large64k_endpoint_pool4` | 127.53 / 74080.9 | 4.00 / 131584.0 | 131392.0 (131392.0 / 0.0) | 65565 |
| `spsc_large64k_persistent` | 97.39 / 72243.9 | 4.00 / 131584.0 | 131330.0 (131330.0 / 0.0) | 65565 |
| `spsc_opaque_persistent` | 104.38 / 7269.3 | 4.00 / 768.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_record_persistent` | 96.47 / 6685.2 | 4.00 / 768.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_record_pool4_control` | 96.47 / 6684.8 | 4.00 / 768.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_scalar_persistent` | 32.12 / 2988.3 | 2.00 / 208.0 | 0.0 (0.0 / 0.0) | 16 |
| `wait_empty_receiver_endpoint` | 125.17 / 18053.4 | 3.00 / 488.0 | 229.3 (229.3 / 0.0) | 29 |
| `wait_empty_receiver_record` | 93.14 / 12811.2 | 3.00 / 488.0 | 169.3 (169.3 / 0.0) | 29 |
| `wait_full_sender_endpoint` | 170.93 / 21183.9 | 5.00 / 872.0 | 355.3 (355.3 / 0.0) | 29 |
| `wait_full_sender_record` | 130.17 / 15109.7 | 5.00 / 872.0 | 295.3 (295.3 / 0.0) | 29 |

Lua allocator requests include state birth and terminal close. Only allocations made inside the underlying Lua allocator are excluded from native traffic; real UV allocations are not suppressed. Copy counts cover interposed memcpy **and memmove** calls, not inlined copies, scalar stores or libc-internal copying. Actual total wire bytes are unavailable; the analytical reference can use a different payload/ID and is not presented as measured transfer traffic.

### Lifecycle and post-retirement evidence (all instrumented rounds)

| Case | Rounds | Channels delta range | Controls delta range | Active worker range | Lua state delta / active async handles / pending wait probes | Observed native block / usable B net ranges | Host Lua net B range | Checksums / lifecycle |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| `call_control` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `churn_cancel_parked_waiters` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 137.0..137.0 | valid |
| `churn_close_parked_receivers` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 36.0..36.0 | valid |
| `churn_close_parked_senders` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 137.0..137.0 | valid |
| `closure_roundtrip_cap0` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `closure_roundtrip_cap1` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `closure_roundtrip_cap64` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `closure_roundtrip_cap8` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `closure_roundtrip_complex_sig` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `codec_large64k_decode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `codec_large64k_encode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `codec_large64k_transfer_roundtrip` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8809.0..8809.0 | valid |
| `codec_scalar_roundtrip` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `codec_small_decode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `codec_small_encode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `codec_small_transfer_roundtrip` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8809.0..8809.0 | valid |
| `codec_wide16_decode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `codec_wide16_encode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `codec_wide16_transfer_roundtrip` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8809.0..8809.0 | valid |
| `inspect_function` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `inspect_record` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `join_cleanup_cancelled_task` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 3399.0..3399.0 | valid |
| `join_ordinary` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 36.0..36.0 | valid |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8664.0..8664.0 | valid |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8664.0..8664.0 | valid |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7800.0..7800.0 | valid |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7800.0..7800.0 | valid |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7800.0..7800.0 | valid |
| `mpmc_record_inflight16_cap16_4p4c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 10879.0..10879.0 | valid |
| `mpmc_record_inflight16_cap2_4p4c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 10879.0..10879.0 | valid |
| `mpmc_record_inflight1_cap1_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 10015.0..10015.0 | valid |
| `mpmc_record_inflight4_cap1_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 10015.0..10015.0 | valid |
| `mpmc_record_inflight4_cap4_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 10015.0..10015.0 | valid |
| `overhead_control` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `queue_opaque_hook8` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 5638.0..5638.0 | valid |
| `queue_packed_hook8` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 5638.0..5638.0 | valid |
| `queue_plain_bytes8` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 45.0..45.0 | valid |
| `queue_real_receiver` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2422.0..2422.0 | valid |
| `queue_real_sender` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2422.0..2422.0 | valid |
| `sender_clone` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | -71.0..-71.0 | valid |
| `spsc_endpoint_carried_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2413.0..2413.0 | valid |
| `spsc_endpoint_fresh_reply` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2395.0..2395.0 | valid |
| `spsc_endpoint_pool4_reply` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2395.0..2395.0 | valid |
| `spsc_large64k_endpoint_pool4` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2395.0..2395.0 | valid |
| `spsc_large64k_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2105.0..2105.0 | valid |
| `spsc_opaque_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 5629.0..5629.0 | valid |
| `spsc_record_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | -12.0..-12.0 | valid |
| `spsc_record_pool4_control` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2251.0..2251.0 | valid |
| `spsc_scalar_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | -12.0..-12.0 | valid |
| `wait_empty_receiver_endpoint` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2473.0..2473.0 | valid |
| `wait_empty_receiver_record` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 180.0..180.0 | valid |
| `wait_full_sender_endpoint` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2446.0..2446.0 | valid |
| `wait_full_sender_record` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 39.0..39.0 | valid |

Channel/control counts are actual native birth/destruction probes. Worker quiescence waits for the native end-of-worker release, not a fixed number of loop turns or public join alone; it is native domain-ownership retirement evidence, not an OS-join proof. The pre-wake resource-ownership correctness checkpoint intentionally retains known legacy detached-thread/proxy-early-terminal behavior and is not final Thread approval. The separate final corrected wake/join candidate requires actual OS join before every proxy terminal and full platform correctness evidence. Explicit residual collections occur outside body timing. The allocator's signed net delta is an observed ledger, **not** a complete retained-native-memory oracle; lifecycle counts are reported separately. Failed calibration, missing/truncated samples, checksum errors and unretired native domains reject a campaign.

### Overlapping source-scoped stage intervals

| Case | Wake attribution | Sender entry through encode | Queue lock + branch | Registration after failed check | Notify to continuation | Post-dequeue decode + return | Reply processing |
|---|---|---:|---:|---:|---:|---:|---:|
| `call_control` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `churn_cancel_parked_waiters` | `unavailable_cancelled_or_nonunique_notification` | 0.982/68.398 (1000 total; 500..500/round) | 0.030/0.281 (5000 total; 2500..2500/round) | 0.861/16.120 (2000 total; 1000..1000/round) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `churn_close_parked_receivers` | `exact_waiter_notification_to_continuation` | unavailable (0 samples) | 0.030/0.236 (6000 total; 3000..3000/round) | 0.851/20.514 (2000 total; 1000..1000/round) | 1.978/5.385 (2000 total; 1000..1000/round) | unavailable (0 samples) | unavailable (0 samples) |
| `churn_close_parked_senders` | `exact_waiter_notification_to_continuation` | 0.886/16.496 (2000 total; 1000..1000/round) | 0.030/0.276 (7000 total; 3500..3500/round) | 0.667/2.990 (2000 total; 1000..1000/round) | 7.098/34.615 (2000 total; 1000..1000/round) | unavailable (0 samples) | unavailable (0 samples) |
| `closure_roundtrip_cap0` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `closure_roundtrip_cap1` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `closure_roundtrip_cap64` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `closure_roundtrip_cap8` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `closure_roundtrip_complex_sig` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_large64k_decode` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_large64k_encode` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_large64k_transfer_roundtrip` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_scalar_roundtrip` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_small_decode` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_small_encode` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_small_transfer_roundtrip` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_wide16_decode` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_wide16_encode` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_wide16_transfer_roundtrip` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `inspect_function` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `inspect_record` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `join_cleanup_cancelled_task` | `partial_exact_only` | unavailable (0 samples) | 0.321/7.930 (3200 total; 1600..1600/round) | unavailable (0 samples) | 18.254/50.755 (800 total; 400..400/round) | unavailable (0 samples) | unavailable (0 samples) |
| `join_ordinary` | `exact_waiter_notification_to_continuation` | unavailable (0 samples) | 0.396/6.617 (1800 total; 900..900/round) | unavailable (0 samples) | 15.774/44.233 (600 total; 300..300/round) | unavailable (0 samples) | unavailable (0 samples) |
| `mpmc_endpoint_inflight16_cap16_4p4c` | `exact_waiter_notification_to_continuation` | 3.847/14.863 (4000 total; 2000..2000/round) | 0.341/12.223 (22346 total; 11057..11289/round) | 3.212/7.624 (1998 total; 998..1000/round) | 57.047/204.898 (4882 total; 2380..2502/round) | 6.272/13.390 (2000 total; 1000..1000/round) | 0.040/0.095 (2000 total; 1000..1000/round) |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `exact_waiter_notification_to_continuation` | 3.346/10.560 (4000 total; 2000..2000/round) | 0.315/8.896 (22643 total; 11268..11375/round) | 2.850/7.334 (2083 total; 1041..1042/round) | 49.738/148.237 (4999 total; 2474..2525/round) | 5.410/11.892 (2000 total; 1000..1000/round) | 0.026/0.061 (2000 total; 1000..1000/round) |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `exact_waiter_notification_to_continuation` | 2.870/7.464 (4000 total; 2000..2000/round) | 0.101/1.142 (22025 total; 11011..11014/round) | 1.728/6.492 (2000 total; 1000..1000/round) | 3.512/12.123 (5004 total; 2501..2503/round) | 2.740/8.797 (2000 total; 1000..1000/round) | 0.035/0.050 (2000 total; 1000..1000/round) |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `exact_waiter_notification_to_continuation` | 3.837/9.823 (4000 total; 2000..2000/round) | 0.185/3.907 (21834 total; 10796..11038/round) | 2.344/7.760 (2337 total; 1135..1202/round) | 13.050/43.676 (4536 total; 2205..2331/round) | 4.749/14.026 (2000 total; 1000..1000/round) | 0.035/0.061 (2000 total; 1000..1000/round) |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `exact_waiter_notification_to_continuation` | 3.376/10.039 (4000 total; 2000..2000/round) | 0.155/3.772 (21064 total; 10443..10621/round) | 1.954/6.222 (2000 total; 1000..1000/round) | 11.075/40.886 (4304 total; 2117..2187/round) | 4.208/12.964 (2000 total; 1000..1000/round) | 0.035/0.060 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight16_cap16_4p4c` | `exact_waiter_notification_to_continuation` | 2.960/10.119 (4000 total; 2000..2000/round) | 0.266/7.509 (21144 total; 10097..11047/round) | 4.018/8.511 (1999 total; 999..1000/round) | 47.243/171.841 (4374 total; 1995..2379/round) | 7.249/17.152 (2000 total; 1000..1000/round) | 0.040/0.066 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight16_cap2_4p4c` | `exact_waiter_notification_to_continuation` | 2.600/24.491 (4000 total; 2000..2000/round) | 0.251/6.908 (22376 total; 11023..11353/round) | 3.472/8.951 (2609 total; 1208..1401/round) | 35.606/139.681 (4880 total; 2371..2509/round) | 6.127/12.845 (2000 total; 1000..1000/round) | 0.035/0.066 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight1_cap1_2p2c` | `exact_waiter_notification_to_continuation` | 1.518/10.174 (4000 total; 2000..2000/round) | 0.160/2.049 (22045 total; 10829..11216/round) | 1.653/6.351 (2000 total; 1000..1000/round) | 3.902/18.114 (5011 total; 2407..2604/round) | 2.630/13.505 (2000 total; 1000..1000/round) | 0.030/0.075 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight4_cap1_2p2c` | `exact_waiter_notification_to_continuation` | 1.758/5.997 (4000 total; 2000..2000/round) | 0.160/3.812 (21642 total; 10807..10835/round) | 1.969/6.512 (2424 total; 1200..1224/round) | 9.187/30.678 (4419 total; 2191..2228/round) | 3.768/12.378 (2000 total; 1000..1000/round) | 0.035/0.066 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight4_cap4_2p2c` | `exact_waiter_notification_to_continuation` | 1.718/6.397 (4000 total; 2000..2000/round) | 0.155/3.592 (21186 total; 10552..10634/round) | 1.883/6.136 (2000 total; 1000..1000/round) | 10.450/36.733 (4366 total; 2143..2223/round) | 3.812/12.649 (2000 total; 1000..1000/round) | 0.030/0.045 (2000 total; 1000..1000/round) |
| `overhead_control` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `queue_opaque_hook8` | `no_suspensions` | 1.022/4.378 (10000 total; 5000..5000/round) | 0.030/0.095 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 1.373/8.210 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `queue_packed_hook8` | `no_suspensions` | 2.319/68.568 (10000 total; 5000..5000/round) | 0.040/0.165 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 2.645/30.081 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `queue_plain_bytes8` | `no_suspensions` | 0.702/3.101 (10000 total; 5000..5000/round) | 0.030/0.041 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 1.157/7.960 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `queue_real_receiver` | `no_suspensions` | 2.409/29.460 (10000 total; 5000..5000/round) | 0.045/0.136 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 2.856/82.885 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `queue_real_sender` | `no_suspensions` | 1.583/20.378 (10000 total; 5000..5000/round) | 0.030/0.130 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 1.869/43.586 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `sender_clone` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `spsc_endpoint_carried_persistent` | `exact_waiter_notification_to_continuation` | 2.599/23.032 (4000 total; 2000..2000/round) | 0.261/1.522 (15951 total; 7975..7976/round) | 1.483/21.220 (2000 total; 1000..1000/round) | 3.927/12.698 (3951 total; 1975..1976/round) | 2.816/23.469 (2000 total; 1000..1000/round) | 0.151/2.123 (2000 total; 1000..1000/round) |
| `spsc_endpoint_fresh_reply` | `exact_waiter_notification_to_continuation` | 2.695/6.212 (2000 total; 1000..1000/round) | 0.265/1.292 (8000 total; 4000..4000/round) | 1.237/3.852 (1000 total; 500..500/round) | 3.802/6.728 (2000 total; 1000..1000/round) | 2.575/8.651 (1000 total; 500..500/round) | 0.140/1.237 (1000 total; 500..500/round) |
| `spsc_endpoint_pool4_reply` | `exact_waiter_notification_to_continuation` | 1.643/13.872 (4000 total; 2000..2000/round) | 0.160/2.219 (15950 total; 7973..7977/round) | 0.952/21.209 (2000 total; 1000..1000/round) | 2.189/12.463 (3950 total; 1973..1977/round) | 1.673/25.648 (2000 total; 1000..1000/round) | 0.065/1.096 (2000 total; 1000..1000/round) |
| `spsc_large64k_endpoint_pool4` | `exact_waiter_notification_to_continuation` | 2.770/15.349 (1024 total; 512..512/round) | 0.170/1.754 (4095 total; 2047..2048/round) | 0.973/4.303 (512 total; 256..256/round) | 2.384/12.273 (1023 total; 511..512/round) | 1.909/7.679 (512 total; 256..256/round) | 0.070/0.271 (512 total; 256..256/round) |
| `spsc_large64k_persistent` | `exact_waiter_notification_to_continuation` | 4.688/11.591 (1024 total; 512..512/round) | 0.260/2.130 (4096 total; 2048..2048/round) | 1.308/5.470 (512 total; 256..256/round) | 3.947/8.721 (1024 total; 512..512/round) | 2.579/7.649 (512 total; 256..256/round) | 0.141/0.385 (512 total; 256..256/round) |
| `spsc_opaque_persistent` | `exact_waiter_notification_to_continuation` | 1.699/11.096 (4000 total; 2000..2000/round) | 0.225/0.967 (15948 total; 7973..7975/round) | 1.157/24.901 (2000 total; 1000..1000/round) | 2.880/10.880 (3948 total; 1973..1975/round) | 2.119/33.733 (2000 total; 1000..1000/round) | 0.101/1.172 (2000 total; 1000..1000/round) |
| `spsc_record_persistent` | `exact_waiter_notification_to_continuation` | 1.442/18.039 (4000 total; 2000..2000/round) | 0.270/16.642 (15994 total; 7994..8000/round) | 1.373/20.293 (2000 total; 1000..1000/round) | 2.990/24.055 (3994 total; 1994..2000/round) | 2.309/13.835 (2000 total; 1000..1000/round) | 0.096/1.734 (2000 total; 1000..1000/round) |
| `spsc_record_pool4_control` | `exact_waiter_notification_to_continuation` | 1.288/5.590 (4000 total; 2000..2000/round) | 0.235/0.931 (15990 total; 7995..7995/round) | 1.308/4.543 (2000 total; 1000..1000/round) | 3.071/12.759 (3990 total; 1995..1995/round) | 2.269/25.938 (2000 total; 1000..1000/round) | 0.095/1.528 (2000 total; 1000..1000/round) |
| `spsc_scalar_persistent` | `exact_waiter_notification_to_continuation` | 0.161/1.072 (4000 total; 2000..2000/round) | 0.060/2.083 (15300 total; 7571..7729/round) | 0.962/4.784 (2000 total; 1000..1000/round) | 1.317/4.769 (3301 total; 1571..1730/round) | 0.111/0.762 (2000 total; 1000..1000/round) | 0.020/0.026 (2000 total; 1000..1000/round) |
| `wait_empty_receiver_endpoint` | `exact_waiter_notification_to_continuation` | unavailable (0 samples) | 0.261/1.619 (8000 total; 4000..4000/round) | 1.859/97.642 (1000 total; 500..500/round) | 4.258/8.716 (2000 total; 1000..1000/round) | 5.460/53.705 (1000 total; 500..500/round) | unavailable (0 samples) |
| `wait_empty_receiver_record` | `exact_waiter_notification_to_continuation` | unavailable (0 samples) | 0.245/1.853 (8000 total; 4000..4000/round) | 2.014/43.697 (1000 total; 500..500/round) | 3.030/14.893 (2000 total; 1000..1000/round) | 2.275/14.907 (1000 total; 500..500/round) | unavailable (0 samples) |
| `wait_full_sender_endpoint` | `exact_waiter_notification_to_continuation` | 5.780/95.299 (1000 total; 500..500/round) | 0.215/1.874 (11621 total; 5810..5811/round) | 1.723/6.162 (1924 total; 957..967/round) | 3.667/19.151 (2697 total; 1344..1353/round) | 2.900/21.365 (1000 total; 500..500/round) | unavailable (0 samples) |
| `wait_full_sender_record` | `exact_waiter_notification_to_continuation` | 2.981/36.788 (1000 total; 500..500/round) | 0.125/1.323 (10371 total; 5128..5243/round) | 1.367/14.863 (1290 total; 616..674/round) | 3.126/11.596 (2081 total; 1012..1069/round) | 2.665/12.955 (1000 total; 500..500/round) | unavailable (0 samples) |

Cells are medians of per-round p50/p99 microseconds, with total sample count and per-round count range. Wake modes list all observed round modes, not only the representative counter round. Encode/decode subintervals cover selected benchmark call brackets, not every worker's codec. Queue intervals include lock acquisition and readiness/closed branches, ending before unlock. Native wake correlates the exact selected waiter with its notification and successful continuation; cancelled/failed/nonunique notifications are unavailable, never attributed to a global last signal. It is not isolated kernel wake latency. Stages overlap across OS threads: do not add medians or subtract independently measured RTTs to manufacture a component time.

### Instrumentation overhead

| Case | Original SDK us/op | Private instrumented us/op | Difference us/op | Ratio |
|---|---:|---:|---:|---:|
| `call_control` | 0.053 | 0.053 | -0.001 | 0.991 |
| `churn_cancel_parked_waiters` | 73.467 | 76.224 | +2.757 | 1.038 |
| `churn_close_parked_receivers` | 23.243 | 25.282 | +2.039 | 1.088 |
| `churn_close_parked_senders` | 38.728 | 42.549 | +3.820 | 1.099 |
| `closure_roundtrip_cap0` | 5.633 | 12.117 | +6.483 | 2.151 |
| `closure_roundtrip_cap1` | 9.232 | 12.313 | +3.081 | 1.334 |
| `closure_roundtrip_cap64` | 152.208 | 224.624 | +72.417 | 1.476 |
| `closure_roundtrip_cap8` | 27.664 | 39.624 | +11.960 | 1.432 |
| `closure_roundtrip_complex_sig` | 10.259 | 13.057 | +2.798 | 1.273 |
| `codec_large64k_decode` | 6.985 | 10.904 | +3.920 | 1.561 |
| `codec_large64k_encode` | 11.538 | 11.786 | +0.248 | 1.021 |
| `codec_large64k_transfer_roundtrip` | 9.685 | 10.015 | +0.330 | 1.034 |
| `codec_scalar_roundtrip` | 0.163 | 0.190 | +0.027 | 1.165 |
| `codec_small_decode` | 1.082 | 1.454 | +0.372 | 1.344 |
| `codec_small_encode` | 0.568 | 0.872 | +0.304 | 1.536 |
| `codec_small_transfer_roundtrip` | 2.401 | 2.768 | +0.368 | 1.153 |
| `codec_wide16_decode` | 2.573 | 3.732 | +1.159 | 1.450 |
| `codec_wide16_encode` | 1.333 | 1.182 | -0.151 | 0.887 |
| `codec_wide16_transfer_roundtrip` | 4.051 | 5.346 | +1.295 | 1.320 |
| `inspect_function` | 1.979 | 2.738 | +0.759 | 1.384 |
| `inspect_record` | 0.198 | 0.183 | -0.015 | 0.924 |
| `join_cleanup_cancelled_task` | 42153.113 | 40936.701 | -1216.412 | 0.971 |
| `join_ordinary` | 6768.378 | 7110.953 | +342.575 | 1.051 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 3.642 | 8.712 | +5.071 | 2.392 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 3.488 | 7.720 | +4.232 | 2.213 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 20.832 | 24.625 | +3.793 | 1.182 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 7.452 | 12.178 | +4.726 | 1.634 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 6.090 | 10.665 | +4.575 | 1.751 |
| `mpmc_record_inflight16_cap16_4p4c` | 3.473 | 8.385 | +4.912 | 2.414 |
| `mpmc_record_inflight16_cap2_4p4c` | 3.533 | 8.773 | +5.240 | 2.483 |
| `mpmc_record_inflight1_cap1_2p2c` | 18.843 | 23.352 | +4.510 | 1.239 |
| `mpmc_record_inflight4_cap1_2p2c` | 6.095 | 8.900 | +2.806 | 1.460 |
| `mpmc_record_inflight4_cap4_2p2c` | 5.440 | 8.970 | +3.529 | 1.649 |
| `overhead_control` | 0.066 | 0.088 | +0.022 | 1.335 |
| `queue_opaque_hook8` | 3.649 | 3.705 | +0.056 | 1.015 |
| `queue_packed_hook8` | 3.765 | 8.374 | +4.609 | 2.224 |
| `queue_plain_bytes8` | 2.152 | 3.055 | +0.904 | 1.420 |
| `queue_real_receiver` | 4.253 | 9.000 | +4.747 | 2.116 |
| `queue_real_sender` | 4.320 | 6.172 | +1.852 | 1.429 |
| `sender_clone` | 0.203 | 0.253 | +0.049 | 1.241 |
| `spsc_endpoint_carried_persistent` | 21.610 | 32.197 | +10.587 | 1.490 |
| `spsc_endpoint_fresh_reply` | 14.289 | 23.774 | +9.485 | 1.664 |
| `spsc_endpoint_pool4_reply` | 21.001 | 20.566 | -0.435 | 0.979 |
| `spsc_large64k_endpoint_pool4` | 28.110 | 36.800 | +8.690 | 1.309 |
| `spsc_large64k_persistent` | 24.363 | 44.430 | +20.067 | 1.824 |
| `spsc_opaque_persistent` | 20.170 | 23.065 | +2.895 | 1.144 |
| `spsc_record_persistent` | 17.987 | 45.368 | +27.381 | 2.522 |
| `spsc_record_pool4_control` | 16.060 | 18.765 | +2.705 | 1.168 |
| `spsc_scalar_persistent` | 5.781 | 4.633 | -1.148 | 0.801 |
| `wait_empty_receiver_endpoint` | 33.906 | 40.154 | +6.248 | 1.184 |
| `wait_empty_receiver_record` | 33.536 | 36.353 | +2.817 | 1.084 |
| `wait_full_sender_endpoint` | 35.000 | 47.856 | +12.856 | 1.367 |
| `wait_full_sender_record` | 31.392 | 36.732 | +5.340 | 1.170 |

### Matched protocol/shape endpoint component contrasts

| Case | Control | Case us/op | Control us/op | Difference us/op |
|---|---|---:|---:|---:|
| `mpmc_endpoint_inflight16_cap16_4p4c` | `mpmc_record_inflight16_cap16_4p4c` | 3.642 | 3.473 | +0.168 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `mpmc_record_inflight16_cap2_4p4c` | 3.488 | 3.533 | -0.045 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `mpmc_record_inflight1_cap1_2p2c` | 20.832 | 18.843 | +1.989 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `mpmc_record_inflight4_cap1_2p2c` | 7.452 | 6.095 | +1.357 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `mpmc_record_inflight4_cap4_2p2c` | 6.090 | 5.440 | +0.649 |
| `queue_real_receiver` | `queue_plain_bytes8` | 4.253 | 2.152 | +2.101 |
| `queue_real_sender` | `queue_plain_bytes8` | 4.320 | 2.152 | +2.168 |
| `spsc_endpoint_carried_persistent` | `spsc_record_persistent` | 21.610 | 17.987 | +3.624 |
| `spsc_endpoint_pool4_reply` | `spsc_record_pool4_control` | 21.001 | 16.060 | +4.941 |
| `wait_empty_receiver_endpoint` | `wait_empty_receiver_record` | 33.906 | 33.536 | +0.371 |
| `wait_full_sender_endpoint` | `wait_full_sender_record` | 35.000 | 31.392 | +3.607 |

### Payload-policy controls (not isolated endpoint costs)

| Case | Control | Case us/op | Control us/op | Difference us/op |
|---|---|---:|---:|---:|
| `queue_opaque_hook8` | `queue_plain_bytes8` | 3.649 | 2.152 | +1.498 |
| `queue_packed_hook8` | `queue_plain_bytes8` | 3.765 | 2.152 | +1.613 |
| `spsc_opaque_persistent` | `spsc_record_persistent` | 20.170 | 17.987 | +2.184 |

### Application-protocol contrasts (not matched endpoint components)

| Case | Control | Case us/op | Control us/op | Difference us/op |
|---|---|---:|---:|---:|
| `spsc_endpoint_fresh_reply` | `spsc_endpoint_pool4_reply` | 14.289 | 21.001 | -6.712 |
| `spsc_large64k_endpoint_pool4` | `spsc_large64k_persistent` | 28.110 | 24.363 | +3.747 |

Matched endpoint contrasts retain common field count, capacity, OS producer/consumer counts, in-flight budget and validation/protocol; payload representation, hooks, wrapper allocation and ownership differ together. They do not isolate only retain/release cost. Fresh/pool-four and large pool-four/persistent comparisons change application protocol and are kept in the separate protocol table.

### candidate provenance

| Input | Recorded evidence |
|---|---|
| ABI / SDK / language-server API | `2 / 0.6 / 1 (compile guard)` |
| Claimed source revision (builder-attested, not inferred) | `resource-ownership-r3-74a02edbec731159` |
| SDK profile | `production` |
| Complete generated-C flags (including optimization / LTO / debug) | `--std=c99 -O3 -Wall -Wno-unused-but-set-variable -Wno-unused-function -fPIC -g1 -flto=auto -ffat-lto-objects -fno-strict-aliasing` |
| Generated-C source-line directives | `True` |
| Full SDK content manifest SHA-256 | `69d618aed7e0fad78000f736bb8a3e0f8173fbf24565d394d7a7bc4e6ff6859b` |
| Source hash-map SHA-256 | `e89472ca428687be3d28f813ce493da1e5ced2d4846015cea63106570265f749` |
| Source probe recipe SHA-256 | `7cd2b6f7cc79a39b255bc5b1d9cb0db7db20b44ff23ca8ad4ae73ab0a229710d` |
| Original builder receipt SHA-256 | `7be82223bc57d44c67873735e33020ce171fcc0448b701c50a1f9d7141215876` |
| Preserved native payload archive SHA-256 | `0ce37201de9cf630f147292d593eab4c3c9facab3654adc464535caffbe60a66` |
| Generated consumer SHA-256 | `6f8cc79895202213298c74e6596bbab0b188e3d19629c8e451497c940e3fa906` |
| Raw codec calling contract | `native_consuming_slot` |

<details><summary>Exact provider/source/tool/link evidence</summary>

```json
{
  "executable_sha256": {
    "instrumented": "684c96a14f5bb35a512d3bcb8f2f99a20f903798d0094b713fe0e472e1abd930",
    "uninstrumented": "2ac2d71547ed573cbb061b6f1cc1ed3343645d796670d0dbf9ee3b3a64546c32"
  },
  "link_evidence": {
    "instrumented": "/tmp/titan-issue252-rtt-ownership-v4/logs/1792292493662960769-link-dependencies-instrumented.json",
    "uninstrumented": "/tmp/titan-issue252-rtt-ownership-v4/logs/1792292493657916601-link-dependencies-uninstrumented.json"
  },
  "lua_sha256": {
    "bin/lua": "4ff90fc0bccfffb89db1198b3807b2731b1f95686967a42d13f9b78f6f5561ee",
    "lib/liblua.a": "7decdb6e81469ca27cd6f8bc9f2eef0830c77dd6c5bc15cefc8a89fe1258f721"
  },
  "native_compile_argv": {
    "consumer_instrumented": [
      [
        "/usr/bin/gcc",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=bench",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/instrumented/bench.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/instrumented/bench.o.compile.tmp.lua_F2Ogrv"
      ],
      [
        "/usr/bin/gcc",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/instrumented/.titan-temporary.tmp.lua_XOBBPS.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/instrumented/.titan-temporary.tmp.lua_XOBBPS.o"
      ],
      [
        "/usr/bin/gcc",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/instrumented/bench__entrypoint.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/instrumented/bench__entrypoint.o"
      ]
    ],
    "consumer_uninstrumented": [
      [
        "/usr/bin/gcc",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=bench",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/uninstrumented/bench.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/uninstrumented/bench.o.compile.tmp.lua_8qMGqw"
      ],
      [
        "/usr/bin/gcc",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/uninstrumented/.titan-temporary.tmp.lua_bizc0a.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/uninstrumented/.titan-temporary.tmp.lua_bizc0a.o"
      ],
      [
        "/usr/bin/gcc",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/uninstrumented/bench__entrypoint.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/uninstrumented/bench__entrypoint.o"
      ]
    ],
    "private_provider": [
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.async",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/async.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/async.o.compile.tmp.lua_QQOXvF"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.coroutine",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/coroutine.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/coroutine.o.compile.tmp.lua_znj1Bg"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.fs",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/fs.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/fs.o.compile.tmp.lua_0P01mN"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.gc",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/gc.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/gc.o.compile.tmp.lua_TfmsrG"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.http",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/http/http.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/http/http.o.compile.tmp.lua_HuMAGo"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.io",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/io.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/io.o.compile.tmp.lua_DDH0ud"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.iteration",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/iteration.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/iteration.o.compile.tmp.lua_b8biKl"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.json",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/json/json.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/json/json.o.compile.tmp.lua_uoh2Rb"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.lua",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/lua/lua.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/lua/lua.o.compile.tmp.lua_oLYeFN"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.math",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/math.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/math.o.compile.tmp.lua_lRCGCf"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.net",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/net.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/net.o.compile.tmp.lua_tCP0Kw"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.os",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/os.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/os.o.compile.tmp.lua_UcUZ4Q"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.path",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/path.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/path.o.compile.tmp.lua_1d5NEr"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.peg",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/peg/peg.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/peg/peg.o.compile.tmp.lua_7chgs3"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.protobuf",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/protobuf/protobuf.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/protobuf/protobuf.o.compile.tmp.lua_2h77Dp"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.reflect",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/reflect.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/reflect.o.compile.tmp.lua_gYftgA"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.sqlite3",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/sqlite3/sqlite3.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/sqlite3/sqlite3.o.compile.tmp.lua_ZDLHAs"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.ssl",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/ssl.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/ssl.o.compile.tmp.lua_8R6lDm"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.string",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/string/string.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/string/string.o.compile.tmp.lua_DvkPdZ"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.test",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/test.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/test.o.compile.tmp.lua_8tTX0j"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.thread",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/thread/thread.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/thread/thread.o.compile.tmp.lua_SW1AlW"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.timer",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/timer.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/timer.o.compile.tmp.lua_mhwoQI"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.transfer",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/transfer.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/transfer.o.compile.tmp.lua_yjidSE"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.url",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/url.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/url.o.compile.tmp.lua_Ot66zB"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.uv",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/uv/uv.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/uv/uv.o.compile.tmp.lua_gPNXP7"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-ownership-v4/work",
        "-DOPENSSL_API_COMPAT=30000",
        "-D_GNU_SOURCE",
        "--std=c99",
        "-O3",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-function",
        "-fPIC",
        "-g1",
        "-flto=auto",
        "-ffat-lto-objects",
        "-fno-strict-aliasing",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/include",
        "-I",
        "/tmp/titan-issue252-ownership-attested/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.websocket",
        "-c",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/websocket/websocket.c",
        "-o",
        "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan/websocket/websocket.o.compile.tmp.lua_OUvgCp"
      ]
    ]
  },
  "native_policy": {
    "ar": "/usr/bin/ar",
    "cc": "/usr/bin/gcc",
    "cc_version": "gcc (GCC) 16.2.1 20260819 (Red Hat 16.2.1-2)",
    "emit_line_directives": true,
    "libbacktrace_cflags": "-fPIC -g -O2",
    "lua_archive_sha256": "7decdb6e81469ca27cd6f8bc9f2eef0830c77dd6c5bc15cefc8a89fe1258f721",
    "lua_binary_sha256": "4ff90fc0bccfffb89db1198b3807b2731b1f95686967a42d13f9b78f6f5561ee",
    "lua_source_commit": "025bfc35df0885656de347fb7a7c377e90042a75",
    "native_dependency_versions": {
      "libuv": "1.53.0+spawn-close-v1",
      "llhttp": "9.4.3",
      "lpeglabel": "1.6.2-1@912b0b9e8641074408ffc2259e069b188e0c717b",
      "sqlite3": "3.53.4"
    },
    "openssl_mode": "system",
    "openssl_pkg_config": "/usr/bin/pkg-config",
    "openssl_version": "3.5.9",
    "ranlib": "/usr/bin/ranlib",
    "rock_host_cflags": "-O2 -fPIC",
    "runtime_cflags": "--std=c99 -O3 -flto=auto -ffat-lto-objects -Wall -Wno-unused-but-set-variable -Wno-unused-function -fPIC -g1",
    "sdk_header_replay": {
      "include/llhttp.h": {
        "sha256": "5bc82fa51b19aa8bee7d921038393fbfc74e8cc9bae0844c2d82c102fb8cfd68",
        "source": "llhttp-release-v9.4.3/include/llhttp.h"
      },
      "include/sqlite3.h": {
        "sha256": "919e7f2e8ed1d8f56ac17b412b8971c76aa5d1a879752cc6058f75e7d5910e1d",
        "source": "sqlite-autoconf-3530400/sqlite3.h"
      },
      "include/uv.h": {
        "sha256": "565b25538707aa7244eb197af397e566be591b26cb66b5742ed095063946a558",
        "source": "libuv-v1.53.0/include/uv.h"
      },
      "include/uv/aix.h": {
        "sha256": "bed77e4cf6c06f1224e681cbe607eff04713ca0c1e1f4a102e6a6565ee3f02aa",
        "source": "libuv-v1.53.0/include/uv/aix.h"
      },
      "include/uv/bsd.h": {
        "sha256": "963533ff4b16f72a204a8c760896a857c54d0ac50570f1793e3bef1f2ae8b35f",
        "source": "libuv-v1.53.0/include/uv/bsd.h"
      },
      "include/uv/darwin.h": {
        "sha256": "222b6dd3ce67cfbb735b14b1662f065fc23570d6969acf463b39d946b7590d8c",
        "source": "libuv-v1.53.0/include/uv/darwin.h"
      },
      "include/uv/errno.h": {
        "sha256": "4242edf790e4569ef349026ab4c6e31093334ee5fc02b16ed7a0d9fbacdffd16",
        "source": "libuv-v1.53.0/include/uv/errno.h"
      },
      "include/uv/linux.h": {
        "sha256": "adce0ed0821c8466a87a0a4c9e0df9ea7e4a4b24d099c7d7ed196f72a13f669d",
        "source": "libuv-v1.53.0/include/uv/linux.h"
      },
      "include/uv/os390.h": {
        "sha256": "98388ae32ce2c4390b82c3529539d2a476c44f590e960ed30a79f72b807ecd02",
        "source": "libuv-v1.53.0/include/uv/os390.h"
      },
      "include/uv/posix.h": {
        "sha256": "e9d7218b34e6e89b7b412891b7e2aa8b3a561c5ce9714c1f4def6c8a8593a6a6",
        "source": "libuv-v1.53.0/include/uv/posix.h"
      },
      "include/uv/sunos.h": {
        "sha256": "29d4b4ef48dc3c3ab32d75e0a85bcb80e084d42b32aae40d67fc1d882b93298a",
        "source": "libuv-v1.53.0/include/uv/sunos.h"
      },
      "include/uv/threadpool.h": {
        "sha256": "09ae41099af710289155be012df45c2fce04da6a02e813278b4558935e645938",
        "source": "libuv-v1.53.0/include/uv/threadpool.h"
      },
      "include/uv/tree.h": {
        "sha256": "34393c74082c71ddd5bd9ec4afe30ef03df7fa7bb64be5a50ae070cdfebb5c43",
        "source": "libuv-v1.53.0/include/uv/tree.h"
      },
      "include/uv/unix.h": {
        "sha256": "bfa9e31bccf6991f795074316d323eaeef5dcdf6b1b6b8b9d1093e871e6484db",
        "source": "libuv-v1.53.0/include/uv/unix.h"
      },
      "include/uv/version.h": {
        "sha256": "8e216f0998cae52664f5a9889a2ec921e43c7abf7970c4780ab4e1bb6262932c",
        "source": "libuv-v1.53.0/include/uv/version.h"
      },
      "include/uv/win.h": {
        "sha256": "414f87cfec6fe111b893c71894bb3bf4afd1ae8e9fc601aa6cf7fb54dc3a1ca7",
        "source": "libuv-v1.53.0/include/uv/win.h"
      }
    },
    "titan_build_profile": "production",
    "titan_cppflags": "-DOPENSSL_API_COMPAT=30000 -D_GNU_SOURCE",
    "titan_extra_cflags": "-fno-strict-aliasing",
    "titan_ldflags": "-lpthread -lrt -lssl -lcrypto"
  },
  "private_provider_files": {
    "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan.a": "36e95055ebb4b34387b47e431e6a0c642e5086e064317db48da92cb7c4260d81",
    "/tmp/titan-issue252-rtt-ownership-v4/work/provider/titan.so": "2f19083180278650e452503043b471c5efe81721472ca876b64d243b41edc962"
  },
  "private_source_sha256": {
    "titan/async.titan": "799d9e47a4f35102135c7acbc909e93f78fce779a19bf21d87dd9644cff83258",
    "titan/async_receiver_native.h": "11442ad0cde9f2386fc1fdec5fa8e6478a83c9af6ea53c1268f6fa9939dd6b81",
    "titan/async_signal_platform.h": "3a413448397988560fe12a07e288be7bab73124964c44bac749497b61b069296",
    "titan/coroutine.titan": "be5fd08a6fd6d3b0b2f6b798f4e3ad42c10d1fb5e88aced6209faa59b9e2144b",
    "titan/fs.titan": "a327d9b30d8f680bfb9faa24f514eec2812fede877ab46e3f9531c822e3b99f9",
    "titan/fs_platform.h": "00da49bdf0851c3a4e2f44ed74243ba40a7b41e3d528f41e50b953503b11d879",
    "titan/gc.titan": "03cabaf0a6e2a48be14280d898236fce5334d3cfa769abc4b7c7a4b1632bb638",
    "titan/http/client.titan": "deed2100ec9da07aa4796f90b05d2491846d04accaa9491805548bc8180855b2",
    "titan/http/headers.titan": "8827e4cd9ae5a18cf660289fee5acb0bd774daa97f7c10cc1e220e724c70557d",
    "titan/http/http.titan": "ff6cc19963ed720c9cc3db435cba78fd7b4457260dd49674d983a0c21f725ae2",
    "titan/http/native.titan": "c6dc067689edb2b9cfd7c012e2497806b7c405a500a024aecedcd1b0695f8390",
    "titan/http/pool.titan": "04e290cd0f8f50b120541339ed15b1aa573a49afd145c0d9e8b6d4cae1987646",
    "titan/http/server.titan": "0032dc51c27b386d06ee912f62e27e7fb122c45e84fc58bf1b1f1f2db1066cec",
    "titan/http/transfer.titan": "fbc27658c9752325e48e748f4fa60c148e6cd56e794254df8cfc42fc830411f4",
    "titan/http/upgrade.titan": "82660410330005aca4c3846eea3b3b46cd4196ac280684f14658d1f4b92884c8",
    "titan/io.titan": "a85aea6ee8d66da0d8fc594426b9e9da812c8701916cd37703548513f7c8b57a",
    "titan/iteration.titan": "c5d33ca7f159aef0e9c07163ae8871920f46ce73ad8a6c9565265ec5e636e3d7",
    "titan/json/decoder.titan": "d4def8fce5de08c7c87508ce0a411a1bafe4b9ac5dd6e318ab4062fd99f4a144",
    "titan/json/json.titan": "1fd824d91d9bee28e2093bebc3598fabdcec594d00aafad6d00a991f4643050a",
    "titan/json/numbers.titan": "88f8a136d374276e98d05e047ed32aaa03efd63e56f4a83c516d48d513f3b13a",
    "titan/json/parser.titan": "7f12a7ba9c72bcc3103f2f84939e23a968fd8c4619fa10e8d8495c5f89dffeb2",
    "titan/json/writer.titan": "6667abde3d9f08e1e5711a30ff1ab636288c5c286c9c6916d98e088c52732703",
    "titan/lua/lua.titan": "fe0b752e006c2d8eda5d16a1b4a93f8ff0328b41a30993ef8f53ed2f63ad362e",
    "titan/lua/native.h": "9b5cdc28cab74588ec8ac44085886300d900d7d547c467b171888e2094660d8a",
    "titan/lua/worker.titan": "595dff5ce86a975be1426e1cb80a845bee21d7f1c7469ffce52c1cd97d86f793",
    "titan/math.titan": "15005d85308ffd3e42a79e548f55c5e5d59cd33e8bb7d4cb2608fe1e0d593f3e",
    "titan/net.titan": "e0c586a511979ac7150b2308ef8581740b481cec13441ac3c1196ba1323c19dd",
    "titan/os.titan": "da276574dec7c8a4dee575782ab22a61184baf083d0739be5569597aa6031835",
    "titan/os_environment.h": "e6b805d75104076751c555af08c4ea80881dd93df104dec8ebefd6b12aca982b",
    "titan/os_platform.h": "2ca67def9f3c87a409a9a80c6458aa9d53d7bbc227c0b3a6c07cabafd226770c",
    "titan/path.titan": "43c194cf9b3b4b79c37f652e74b20f20ab77996bbd326ba188b1e4ee2c601086",
    "titan/path_platform.h": "c56729270bb299092c6ac7dd88ae117c97a874393520ce810ef1c8af03e6ecc8",
    "titan/peg/combinators.titan": "e630451865326ab2ccc9b4078f17c12412e6af19155539a28868df7f34751f11",
    "titan/peg/native.titan": "768cb146b1e578521fb97c2318053ff5fc80a7d5b1765d997518002f083e8fd0",
    "titan/peg/peg.titan": "f3771893b9b648af80027ab839ca27e9165a95b94b28ec1d6637b3fa40ece24a",
    "titan/peg/relabel.titan": "3b6bcccd8da929aa1d56da040bc53df9cd24413361536ac9b66d39a3ec186d0f",
    "titan/peg/relabel_parser.titan": "22df8b78c74e0e596d642f60be244f9f17ee20860a52e8d67d90c3cc14eef1d8",
    "titan/protobuf/decoder.titan": "a864fd7450aa83d286ec173a1928b2f6b07f310d484497b0d8ab6e373802be7f",
    "titan/protobuf/encoder.titan": "3c4cc2b49ca8ff3b45334af70ba72a0f5c84c7cd3639d72aafefcd2f040714b9",
    "titan/protobuf/native.h": "256dd809670f6f1a20a2951ff3783f96ce93341cff0408bd55d89af6fcb40d52",
    "titan/protobuf/protobuf.titan": "8133509295fb8b91a0bbb871f7ebf6eb393a9137228af3c9f291a3e6b8f71cfd",
    "titan/protobuf/schema.titan": "924b9d92ad0b2f82f61e82ef18cd0be5fbad1dcbbb53dccc929ea569c8294c8f",
    "titan/reflect.titan": "a611557c47f100f7b3f44badbd47dda0bf11b4d7869df7aa7c0d73214ba2fef9",
    "titan/sqlite3/bindings.titan": "17a46365e8c8cb93e329676d35a9e74d151cc9590489a8591c0fd7b6c04a103d",
    "titan/sqlite3/native.h": "ac82a1b9730c6e6692b9e08e3fd8b3d83337df66a6a2c6264a366040d9e992ef",
    "titan/sqlite3/row.titan": "58f91cec279562e60559ab66937a80d01fdd30532a2cff4622da1171b9181618",
    "titan/sqlite3/sqlite3.titan": "bae3cb85db17d0fd48ed4f0b9f3479ecda6842c3994bf25f7b8f2a67d597bc45",
    "titan/sqlite3/worker.titan": "421db60859260a0ed96ca325e0def109b8dbd661a0619870790140668fb23092",
    "titan/ssl.titan": "79b741432798a3f2b73ec85fa33851b1bd3cc3e43fd7a4315a8ea74213ca1fd0",
    "titan/string/bytes.titan": "9448b332fd42bf409b453158305890c8c12eb5eb18df1be9bc92342bcc9c8b3e",
    "titan/string/format.titan": "ff8794649730b36d0185cdecb28cbb9eb0a76ffd0b122e67864de3715b02ae34",
    "titan/string/format_native.h": "f3f97457a9296ea6e32e72e036b05e945f15eb8ef02cccdca8ea816a3ac76b75",
    "titan/string/pack.titan": "20bc7a5a3d4f8b499ae27246559040124886b9925cdf6f05b13167690d2a99c2",
    "titan/string/regex_api.titan": "281d06298980e53cdd2e133bbf5ae1ffbbd5e2dc49974979a17b1970362c6160",
    "titan/string/regex_compile.titan": "8aa476969a2854cdd921e112a5c6d6bf860a9c655261851f8f6cebe7bd0dd786",
    "titan/string/regex_parser.titan": "8402206160bceefe85d38abceb52588357afcf5991d753da4ec4a56c4b84b969",
    "titan/string/string.titan": "e1015dcb814d4c2173e8f14dbe506e3a9d5b96e814a58e818306960e0d2b72ea",
    "titan/test.titan": "1098b360eb4e1312cc3e41fb2c6bc258a68a9d9aba47da5fe7dbbc3a3843edcf",
    "titan/thread/channel.titan": "eafea619426e0df6a029ceda3335dac602f3871140bbfdf5a88a306c7dc4d52d",
    "titan/thread/group.titan": "4fe8c6b4d535ea88a5d9e0ab92c2a570c78576e95682ca97ec10de44f9d7bf40",
    "titan/thread/native.h": "011ce3dd894dd3847f71a71f4ccc4b797da72903d0b64586dd0721478903ddbe",
    "titan/thread/spawn.titan": "f49d130363f4fc20daba6c1aa385ef79ac4878f609bbc6c087ef7886fed33e8b",
    "titan/thread/thread.titan": "68494f6b78ef84a54b18e7df0112709314bf17347706d2ad086ab11d1b3820e1",
    "titan/timer.titan": "bcbbaf7ca0a83e6305b7c436523bbe938454254b1967a1e2c717417d44e69d1b",
    "titan/transfer.titan": "78a6c65d76fe9078d7112abbae5665be186afc862d1d8513efc5e97c48714017",
    "titan/transfer_native.h": "b604451567989657ef94feb374b80a55c79024e7cd5fa4cd900f0773549b3097",
    "titan/url.titan": "c130c7e2736759cceed9f0c9955e457d9253c94cbe0784adb74d990b2891f9ab",
    "titan/uv/address-native.h": "a77fc869a5ddefee6dd053c0f1df552e6bb96a320a1f8bf0e2a5b3c28ac61525",
    "titan/uv/address.titan": "67d85cfbf9382484c49dd7e3b396963db5ef337508d2cbafc2dc50d9ea4f3c84",
    "titan/uv/callback.h": "de7a15347fe4586ffe9dd7a7f3dfc9931ed488a8babde23f81dfc53bd1d89bee",
    "titan/uv/callbacks.titan": "d605d2cd36704a1c1cd19eb5b988045865141738b94dd1d9c92c85b507b0832f",
    "titan/uv/capabilities.titan": "b79d72cb392a74828f1aa0a82a781b2d83ab09d7803c17a85986c899a4ad9b5f",
    "titan/uv/constants.titan": "58042ab8d85fe014a4dd3c940b0594710fdc76cf35f4e6eb64bc8eecc8bed330",
    "titan/uv/data.titan": "565de88997eba8034f5431ead7a80a2ed37aff12a8932aedf85a225d0474fb8a",
    "titan/uv/data_native.h": "68cf454e225b200572d5de46ada8b091d774a661ebe39b7160c18bf4c5d195c1",
    "titan/uv/dll.titan": "51aae662b051bb5fcd4bc61fd41e36e032c5ce95f45822f6e81fec347a214800",
    "titan/uv/dns.titan": "d79ae8118ee8d2d17e29ac050370d967f7096d4c56efdc5c7e4eef281f93d868",
    "titan/uv/external-wake-native.h": "081510f2954d1139d86a4745ddb26950c6f6cbbd8fa8877ac9d4b28590059e0d",
    "titan/uv/external_wake.titan": "3eddca945b8d3c9b810b178bb61b9e55a94c94bc075aaab1227b0b15659a8493",
    "titan/uv/fd-native.h": "310b9f22163030d72ae29bf32f06b63ac253db23ada7dce7ef5833ce3ef3dd9f",
    "titan/uv/fd.titan": "0d754b9e83e2d3506ae988d46bd160a3b9df867a751c43ba7ec6e8c8caff7953",
    "titan/uv/identifiers.titan": "a5b033d59b4593db7ed8512558468708b7cc55fe94555505ada36f32a3406d08",
    "titan/uv/network-native.h": "aa68b33b4533ccf0a9a21da5037c8a75d942b5cf0fcbfaf860501673ebb1b78d",
    "titan/uv/pipe_tty.titan": "c993616548c9e0957355ce7cfad76daef24b44353749c7af9f4648acd5c8b0c8",
    "titan/uv/platform-constants.h": "026ede031bc7ebb28ed0504d29a2a077175c152cf18d181120944bd43ac46a26",
    "titan/uv/platform_constants.titan": "c322cb9c80ffdb8406ab643ac935f8cc5ad7d7736e09711abb3e826e2d007255",
    "titan/uv/process.titan": "94145f180cc85848c118adec809c6e4efa153199053b874b5b035046f518e14d",
    "titan/uv/startup.titan": "31e0376df10ec0ef59257f59160b7e6958df301fb1e3d167544519dc35f2381f",
    "titan/uv/stream_ops.titan": "6ecb4e474f66c6507c8c7f29114e2c95cf84a0d6df62aa7b37f0ce1708037071",
    "titan/uv/stream_owners.titan": "8cc33b19287a8f4edd25e05e65270bda2f6bbefbc024da80187f6e3e5ba1de4e",
    "titan/uv/sync.titan": "8468e05c462e075a553fc71b45ccff22e06bfe51cfe292a58f02886e5f01b5cb",
    "titan/uv/sync_storage.h": "735846d522d0d8ac547b90b72c4104bd91bbf35ce77a9485ad57bd49f2eea579",
    "titan/uv/tcp.titan": "d60f9e62432719f0dd2f2387fb58ad185fef0861c7b1251923c085c36c4295e9",
    "titan/uv/thread-native.h": "3f21558b5d56f539bf293e25f21feaf20b13738d84591e6af7f26cc18762060a",
    "titan/uv/threading.titan": "b596f1ccb9f0535ab357e07bf2ae8ede05ffc1019b73b65da998bc732f789d21",
    "titan/uv/transfer-native.h": "cb758073064a42bc66d3ffe4829403d179c5ba943a5824e3a753544917c47335",
    "titan/uv/transfer.titan": "23a4475f92f4b65b99c8e1238bfbcf59a878a8badff6e476a4fffc77f02eed2f",
    "titan/uv/udp.titan": "dbdcca8e11d86e14e275462f2134dfe12b49a459ffcd5861541154c97df4bec5",
    "titan/uv/utilities.titan": "c04d0930ef4748efe2229e8f56e376f0422c332378f919faf8ac3874621f20aa",
    "titan/uv/utility_bits.h": "266f6acacbbe4789cf2d5a193290940d005a89fb472f1170bf5f4ad9ffe484fe",
    "titan/uv/uv.titan": "e1b9d3ee90fd9bb8988166179a873cfd1ebab30cacb092a80173048149cae055",
    "titan/uv/version-native.h": "f50904be5213e873f965a9c0df91fdd84e7bb81c64c754c644a4f01b243f7b13",
    "titan/uv/work-data.h": "6c5d07725136b16e44931d7063166521c3dd36b698669547cdfaae768624f131",
    "titan/websocket/connection.titan": "3b12bd5104ed1d8909f277705071a904aef6c7f0cfcde2ceaef40fe29b862087",
    "titan/websocket/frames.titan": "5f1186d677e4181c84a1ff88d7f03211ad7c594eddd89484637e5bc9843f9fb3",
    "titan/websocket/handshake.titan": "75687fd219930545303c1b6e89f6e1fe58f8c9b93990753f10202d4cc517315b",
    "titan/websocket/native.titan": "e5cb28322f7ef8ee33531482fca6e2bb6d6019cc0ab525d502045365677864d1",
    "titan/websocket/utf8.titan": "b0eda22bfbcd8cb0fb13d105ff49af15cee41316ae8acd5a1d1cd79fae51f26c",
    "titan/websocket/websocket.titan": "9e25d2affc279a4e6cb986b7e6c164d05e91e76c0ee2f0fcd3062c3e6c849b62",
    "vendor/lpeglabel/lplcap.h": "1114fe329cc34c7054938035e73e6bf25802e3b0b88e0f17ebe592587d405013",
    "vendor/lpeglabel/lplcode.h": "84dfbddbd78d4a0f6861dd8be065d5fd1c4c4aac8cd77cea3af4ad286d9be9ac",
    "vendor/lpeglabel/lplprint.h": "1b70e48cc3f8f1a57a3485f5125bda90f230b1c24e06e18adbf4e3c753af992e",
    "vendor/lpeglabel/lpltree.h": "e92d8d4676a7757a028052d0e05056575b3821ba577a63231f37902c0dd180eb",
    "vendor/lpeglabel/lpltypes.h": "d07a72b2470210de6ba82ae868bec93be6b15d15b060d8a8abc926de7d090b70",
    "vendor/lpeglabel/lplvm.h": "6eafc02d33ff9d11abf77b8eb49b086ed684d4394c7303972d46dda7f81c2fe7",
    "vendor/lpeglabel/titan_lpeglabel.h": "3384372e7ed10ca5a18bba7f16dbcf4859a740aff3a4f11ec379e79569eb4a22",
    "vendor/lpeglabel/titan_lpeglabel_namespace.h": "233f2208d0669204031c3475abe4ae3dc376f9381fa1ace36d2330e41554640f"
  },
  "provider_build_evidence": {
    "attestation": "/tmp/titan-issue252-ownership-attested/BUILD-ATTESTATION.json",
    "attestation_sha256": "32115a02d26c4a35c603f2d48c6329f8fdf1a6617abaf28c7c7364349df12080",
    "checkpoint": "resource-ownership pre-wake; legacy detached Thread/OSjoin and prestart defects remain. Uses original unpatched language compiler; new compiler-only consumer lowering fixes are not part of this immutable checkpoint.",
    "commands": "/tmp/titan-issue252-ownership-attested/BUILD-COMMANDS.json",
    "commands_sha256": "281461dfb426a89f308ee75a0809e3e471c7bc8b6ea91177c72d9787297a6206",
    "source_after": "/tmp/titan-issue252-ownership-attested/SOURCE-AFTER.json",
    "source_before": "/tmp/titan-issue252-ownership-attested/SOURCE-BEFORE.json"
  },
  "provider_files": {
    "/tmp/titan-issue252-ownership-attested/sdk/bin/lua": "4ff90fc0bccfffb89db1198b3807b2731b1f95686967a42d13f9b78f6f5561ee",
    "/tmp/titan-issue252-ownership-attested/sdk/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc": "567bdf8984e6631a199b3feae238483a632af62aa9239a5864a93fb074ce03b4",
    "/tmp/titan-issue252-ownership-attested/sdk/lib/titan/0.6/libtitan.a": "f8123ef431b4a854bc1473d1f35296a39a3159d85a25303e60c6dbb7d5f8152f",
    "/tmp/titan-issue252-ownership-attested/sdk/lib/titan/0.6/titan.a": "fc3b0716a1a86d200d2667135596e89210b6c14bf932ac59ed05fd69599d2485",
    "/tmp/titan-issue252-ownership-attested/sdk/lib/titan/0.6/titan.so": "fbef388a69a971129649f4e824fda1799dac74c682dbb13079d056575577157f"
  },
  "source_compile_policy": {
    "build_profile": "production",
    "emit_line_directives": true,
    "extra_cflags": [
      "-fno-strict-aliasing"
    ],
    "generated_cflags": [
      "--std=c99",
      "-O3",
      "-Wall",
      "-Wno-unused-but-set-variable",
      "-Wno-unused-function",
      "-fPIC",
      "-g1",
      "-flto=auto",
      "-ffat-lto-objects",
      "-fno-strict-aliasing"
    ],
    "module_random_seed": {
      "consumer_instrumented": [
        "bench"
      ],
      "consumer_uninstrumented": [
        "bench"
      ],
      "private_provider": [
        "titan.async",
        "titan.coroutine",
        "titan.fs",
        "titan.gc",
        "titan.http",
        "titan.io",
        "titan.iteration",
        "titan.json",
        "titan.lua",
        "titan.math",
        "titan.net",
        "titan.os",
        "titan.path",
        "titan.peg",
        "titan.protobuf",
        "titan.reflect",
        "titan.sqlite3",
        "titan.ssl",
        "titan.string",
        "titan.test",
        "titan.thread",
        "titan.timer",
        "titan.transfer",
        "titan.url",
        "titan.uv",
        "titan.websocket"
      ]
    },
    "private_provider_compile_receipt": "/tmp/titan-issue252-rtt-ownership-v4/logs/1792291788577047792-compile-private-full-provider.json",
    "probe_cflags": [
      "--std=c99",
      "-O3",
      "-Wall",
      "-Wno-unused-but-set-variable",
      "-Wno-unused-function",
      "-fPIC",
      "-g1",
      "-flto=auto",
      "-ffat-lto-objects",
      "-fno-strict-aliasing",
      "-std=c11",
      "-Wextra",
      "-Werror",
      "-fno-builtin",
      "-frandom-seed=rtt_probe"
    ],
    "probe_policy_difference": "C11, instrumentation diagnostics, no builtins, fixed probe-only random seed"
  },
  "source_sha256": {
    "titan/async.titan": "799d9e47a4f35102135c7acbc909e93f78fce779a19bf21d87dd9644cff83258",
    "titan/async_receiver_native.h": "11442ad0cde9f2386fc1fdec5fa8e6478a83c9af6ea53c1268f6fa9939dd6b81",
    "titan/async_signal_platform.h": "3a413448397988560fe12a07e288be7bab73124964c44bac749497b61b069296",
    "titan/coroutine.titan": "be5fd08a6fd6d3b0b2f6b798f4e3ad42c10d1fb5e88aced6209faa59b9e2144b",
    "titan/fs.titan": "a327d9b30d8f680bfb9faa24f514eec2812fede877ab46e3f9531c822e3b99f9",
    "titan/fs_platform.h": "00da49bdf0851c3a4e2f44ed74243ba40a7b41e3d528f41e50b953503b11d879",
    "titan/gc.titan": "03cabaf0a6e2a48be14280d898236fce5334d3cfa769abc4b7c7a4b1632bb638",
    "titan/http/client.titan": "deed2100ec9da07aa4796f90b05d2491846d04accaa9491805548bc8180855b2",
    "titan/http/headers.titan": "8827e4cd9ae5a18cf660289fee5acb0bd774daa97f7c10cc1e220e724c70557d",
    "titan/http/http.titan": "ff6cc19963ed720c9cc3db435cba78fd7b4457260dd49674d983a0c21f725ae2",
    "titan/http/native.titan": "c6dc067689edb2b9cfd7c012e2497806b7c405a500a024aecedcd1b0695f8390",
    "titan/http/pool.titan": "04e290cd0f8f50b120541339ed15b1aa573a49afd145c0d9e8b6d4cae1987646",
    "titan/http/server.titan": "0032dc51c27b386d06ee912f62e27e7fb122c45e84fc58bf1b1f1f2db1066cec",
    "titan/http/transfer.titan": "fbc27658c9752325e48e748f4fa60c148e6cd56e794254df8cfc42fc830411f4",
    "titan/http/upgrade.titan": "82660410330005aca4c3846eea3b3b46cd4196ac280684f14658d1f4b92884c8",
    "titan/io.titan": "a85aea6ee8d66da0d8fc594426b9e9da812c8701916cd37703548513f7c8b57a",
    "titan/iteration.titan": "c5d33ca7f159aef0e9c07163ae8871920f46ce73ad8a6c9565265ec5e636e3d7",
    "titan/json/decoder.titan": "d4def8fce5de08c7c87508ce0a411a1bafe4b9ac5dd6e318ab4062fd99f4a144",
    "titan/json/json.titan": "1fd824d91d9bee28e2093bebc3598fabdcec594d00aafad6d00a991f4643050a",
    "titan/json/numbers.titan": "88f8a136d374276e98d05e047ed32aaa03efd63e56f4a83c516d48d513f3b13a",
    "titan/json/parser.titan": "7f12a7ba9c72bcc3103f2f84939e23a968fd8c4619fa10e8d8495c5f89dffeb2",
    "titan/json/writer.titan": "6667abde3d9f08e1e5711a30ff1ab636288c5c286c9c6916d98e088c52732703",
    "titan/lua/lua.titan": "fe0b752e006c2d8eda5d16a1b4a93f8ff0328b41a30993ef8f53ed2f63ad362e",
    "titan/lua/native.h": "9b5cdc28cab74588ec8ac44085886300d900d7d547c467b171888e2094660d8a",
    "titan/lua/worker.titan": "595dff5ce86a975be1426e1cb80a845bee21d7f1c7469ffce52c1cd97d86f793",
    "titan/math.titan": "15005d85308ffd3e42a79e548f55c5e5d59cd33e8bb7d4cb2608fe1e0d593f3e",
    "titan/net.titan": "e0c586a511979ac7150b2308ef8581740b481cec13441ac3c1196ba1323c19dd",
    "titan/os.titan": "da276574dec7c8a4dee575782ab22a61184baf083d0739be5569597aa6031835",
    "titan/os_environment.h": "e6b805d75104076751c555af08c4ea80881dd93df104dec8ebefd6b12aca982b",
    "titan/os_platform.h": "2ca67def9f3c87a409a9a80c6458aa9d53d7bbc227c0b3a6c07cabafd226770c",
    "titan/path.titan": "43c194cf9b3b4b79c37f652e74b20f20ab77996bbd326ba188b1e4ee2c601086",
    "titan/path_platform.h": "c56729270bb299092c6ac7dd88ae117c97a874393520ce810ef1c8af03e6ecc8",
    "titan/peg/combinators.titan": "e630451865326ab2ccc9b4078f17c12412e6af19155539a28868df7f34751f11",
    "titan/peg/native.titan": "768cb146b1e578521fb97c2318053ff5fc80a7d5b1765d997518002f083e8fd0",
    "titan/peg/peg.titan": "f3771893b9b648af80027ab839ca27e9165a95b94b28ec1d6637b3fa40ece24a",
    "titan/peg/relabel.titan": "3b6bcccd8da929aa1d56da040bc53df9cd24413361536ac9b66d39a3ec186d0f",
    "titan/peg/relabel_parser.titan": "22df8b78c74e0e596d642f60be244f9f17ee20860a52e8d67d90c3cc14eef1d8",
    "titan/protobuf/decoder.titan": "a864fd7450aa83d286ec173a1928b2f6b07f310d484497b0d8ab6e373802be7f",
    "titan/protobuf/encoder.titan": "3c4cc2b49ca8ff3b45334af70ba72a0f5c84c7cd3639d72aafefcd2f040714b9",
    "titan/protobuf/native.h": "256dd809670f6f1a20a2951ff3783f96ce93341cff0408bd55d89af6fcb40d52",
    "titan/protobuf/protobuf.titan": "8133509295fb8b91a0bbb871f7ebf6eb393a9137228af3c9f291a3e6b8f71cfd",
    "titan/protobuf/schema.titan": "924b9d92ad0b2f82f61e82ef18cd0be5fbad1dcbbb53dccc929ea569c8294c8f",
    "titan/reflect.titan": "a611557c47f100f7b3f44badbd47dda0bf11b4d7869df7aa7c0d73214ba2fef9",
    "titan/sqlite3/bindings.titan": "17a46365e8c8cb93e329676d35a9e74d151cc9590489a8591c0fd7b6c04a103d",
    "titan/sqlite3/native.h": "ac82a1b9730c6e6692b9e08e3fd8b3d83337df66a6a2c6264a366040d9e992ef",
    "titan/sqlite3/row.titan": "58f91cec279562e60559ab66937a80d01fdd30532a2cff4622da1171b9181618",
    "titan/sqlite3/sqlite3.titan": "bae3cb85db17d0fd48ed4f0b9f3479ecda6842c3994bf25f7b8f2a67d597bc45",
    "titan/sqlite3/worker.titan": "421db60859260a0ed96ca325e0def109b8dbd661a0619870790140668fb23092",
    "titan/ssl.titan": "79b741432798a3f2b73ec85fa33851b1bd3cc3e43fd7a4315a8ea74213ca1fd0",
    "titan/string/bytes.titan": "9448b332fd42bf409b453158305890c8c12eb5eb18df1be9bc92342bcc9c8b3e",
    "titan/string/format.titan": "ff8794649730b36d0185cdecb28cbb9eb0a76ffd0b122e67864de3715b02ae34",
    "titan/string/format_native.h": "f3f97457a9296ea6e32e72e036b05e945f15eb8ef02cccdca8ea816a3ac76b75",
    "titan/string/pack.titan": "20bc7a5a3d4f8b499ae27246559040124886b9925cdf6f05b13167690d2a99c2",
    "titan/string/regex_api.titan": "281d06298980e53cdd2e133bbf5ae1ffbbd5e2dc49974979a17b1970362c6160",
    "titan/string/regex_compile.titan": "8aa476969a2854cdd921e112a5c6d6bf860a9c655261851f8f6cebe7bd0dd786",
    "titan/string/regex_parser.titan": "8402206160bceefe85d38abceb52588357afcf5991d753da4ec4a56c4b84b969",
    "titan/string/string.titan": "e1015dcb814d4c2173e8f14dbe506e3a9d5b96e814a58e818306960e0d2b72ea",
    "titan/test.titan": "1098b360eb4e1312cc3e41fb2c6bc258a68a9d9aba47da5fe7dbbc3a3843edcf",
    "titan/thread/channel.titan": "d861f4d14ebb5443ef43b7ab5efd1ced0f4565dfeec5ce6c8aba59c4981d76ee",
    "titan/thread/group.titan": "4fe8c6b4d535ea88a5d9e0ab92c2a570c78576e95682ca97ec10de44f9d7bf40",
    "titan/thread/native.h": "011ce3dd894dd3847f71a71f4ccc4b797da72903d0b64586dd0721478903ddbe",
    "titan/thread/spawn.titan": "bcbea92aee98c70ddc90247e281c8c17aa51fe9f1afe9ec8c9f40016eca26d75",
    "titan/thread/thread.titan": "fd28d76bf25965aa81812d3da185bd9b70e1b46c4be10885711c5d6764012eec",
    "titan/timer.titan": "bcbbaf7ca0a83e6305b7c436523bbe938454254b1967a1e2c717417d44e69d1b",
    "titan/transfer.titan": "78a6c65d76fe9078d7112abbae5665be186afc862d1d8513efc5e97c48714017",
    "titan/transfer_native.h": "b604451567989657ef94feb374b80a55c79024e7cd5fa4cd900f0773549b3097",
    "titan/url.titan": "c130c7e2736759cceed9f0c9955e457d9253c94cbe0784adb74d990b2891f9ab",
    "titan/uv/address-native.h": "a77fc869a5ddefee6dd053c0f1df552e6bb96a320a1f8bf0e2a5b3c28ac61525",
    "titan/uv/address.titan": "67d85cfbf9382484c49dd7e3b396963db5ef337508d2cbafc2dc50d9ea4f3c84",
    "titan/uv/callback.h": "de7a15347fe4586ffe9dd7a7f3dfc9931ed488a8babde23f81dfc53bd1d89bee",
    "titan/uv/callbacks.titan": "d605d2cd36704a1c1cd19eb5b988045865141738b94dd1d9c92c85b507b0832f",
    "titan/uv/capabilities.titan": "b79d72cb392a74828f1aa0a82a781b2d83ab09d7803c17a85986c899a4ad9b5f",
    "titan/uv/constants.titan": "58042ab8d85fe014a4dd3c940b0594710fdc76cf35f4e6eb64bc8eecc8bed330",
    "titan/uv/data.titan": "565de88997eba8034f5431ead7a80a2ed37aff12a8932aedf85a225d0474fb8a",
    "titan/uv/data_native.h": "68cf454e225b200572d5de46ada8b091d774a661ebe39b7160c18bf4c5d195c1",
    "titan/uv/dll.titan": "51aae662b051bb5fcd4bc61fd41e36e032c5ce95f45822f6e81fec347a214800",
    "titan/uv/dns.titan": "d79ae8118ee8d2d17e29ac050370d967f7096d4c56efdc5c7e4eef281f93d868",
    "titan/uv/external-wake-native.h": "081510f2954d1139d86a4745ddb26950c6f6cbbd8fa8877ac9d4b28590059e0d",
    "titan/uv/external_wake.titan": "3eddca945b8d3c9b810b178bb61b9e55a94c94bc075aaab1227b0b15659a8493",
    "titan/uv/fd-native.h": "310b9f22163030d72ae29bf32f06b63ac253db23ada7dce7ef5833ce3ef3dd9f",
    "titan/uv/fd.titan": "0d754b9e83e2d3506ae988d46bd160a3b9df867a751c43ba7ec6e8c8caff7953",
    "titan/uv/identifiers.titan": "a5b033d59b4593db7ed8512558468708b7cc55fe94555505ada36f32a3406d08",
    "titan/uv/network-native.h": "aa68b33b4533ccf0a9a21da5037c8a75d942b5cf0fcbfaf860501673ebb1b78d",
    "titan/uv/pipe_tty.titan": "c993616548c9e0957355ce7cfad76daef24b44353749c7af9f4648acd5c8b0c8",
    "titan/uv/platform-constants.h": "026ede031bc7ebb28ed0504d29a2a077175c152cf18d181120944bd43ac46a26",
    "titan/uv/platform_constants.titan": "c322cb9c80ffdb8406ab643ac935f8cc5ad7d7736e09711abb3e826e2d007255",
    "titan/uv/process.titan": "94145f180cc85848c118adec809c6e4efa153199053b874b5b035046f518e14d",
    "titan/uv/startup.titan": "31e0376df10ec0ef59257f59160b7e6958df301fb1e3d167544519dc35f2381f",
    "titan/uv/stream_ops.titan": "6ecb4e474f66c6507c8c7f29114e2c95cf84a0d6df62aa7b37f0ce1708037071",
    "titan/uv/stream_owners.titan": "8cc33b19287a8f4edd25e05e65270bda2f6bbefbc024da80187f6e3e5ba1de4e",
    "titan/uv/sync.titan": "8468e05c462e075a553fc71b45ccff22e06bfe51cfe292a58f02886e5f01b5cb",
    "titan/uv/sync_storage.h": "735846d522d0d8ac547b90b72c4104bd91bbf35ce77a9485ad57bd49f2eea579",
    "titan/uv/tcp.titan": "d60f9e62432719f0dd2f2387fb58ad185fef0861c7b1251923c085c36c4295e9",
    "titan/uv/thread-native.h": "3f21558b5d56f539bf293e25f21feaf20b13738d84591e6af7f26cc18762060a",
    "titan/uv/threading.titan": "b596f1ccb9f0535ab357e07bf2ae8ede05ffc1019b73b65da998bc732f789d21",
    "titan/uv/transfer-native.h": "cb758073064a42bc66d3ffe4829403d179c5ba943a5824e3a753544917c47335",
    "titan/uv/transfer.titan": "23a4475f92f4b65b99c8e1238bfbcf59a878a8badff6e476a4fffc77f02eed2f",
    "titan/uv/udp.titan": "dbdcca8e11d86e14e275462f2134dfe12b49a459ffcd5861541154c97df4bec5",
    "titan/uv/utilities.titan": "c04d0930ef4748efe2229e8f56e376f0422c332378f919faf8ac3874621f20aa",
    "titan/uv/utility_bits.h": "266f6acacbbe4789cf2d5a193290940d005a89fb472f1170bf5f4ad9ffe484fe",
    "titan/uv/uv.titan": "e1b9d3ee90fd9bb8988166179a873cfd1ebab30cacb092a80173048149cae055",
    "titan/uv/version-native.h": "f50904be5213e873f965a9c0df91fdd84e7bb81c64c754c644a4f01b243f7b13",
    "titan/uv/work-data.h": "6c5d07725136b16e44931d7063166521c3dd36b698669547cdfaae768624f131",
    "titan/websocket/connection.titan": "3b12bd5104ed1d8909f277705071a904aef6c7f0cfcde2ceaef40fe29b862087",
    "titan/websocket/frames.titan": "5f1186d677e4181c84a1ff88d7f03211ad7c594eddd89484637e5bc9843f9fb3",
    "titan/websocket/handshake.titan": "75687fd219930545303c1b6e89f6e1fe58f8c9b93990753f10202d4cc517315b",
    "titan/websocket/native.titan": "e5cb28322f7ef8ee33531482fca6e2bb6d6019cc0ab525d502045365677864d1",
    "titan/websocket/utf8.titan": "b0eda22bfbcd8cb0fb13d105ff49af15cee41316ae8acd5a1d1cd79fae51f26c",
    "titan/websocket/websocket.titan": "9e25d2affc279a4e6cb986b7e6c164d05e91e76c0ee2f0fcd3062c3e6c849b62",
    "vendor/lpeglabel/lplcap.h": "1114fe329cc34c7054938035e73e6bf25802e3b0b88e0f17ebe592587d405013",
    "vendor/lpeglabel/lplcode.h": "84dfbddbd78d4a0f6861dd8be065d5fd1c4c4aac8cd77cea3af4ad286d9be9ac",
    "vendor/lpeglabel/lplprint.h": "1b70e48cc3f8f1a57a3485f5125bda90f230b1c24e06e18adbf4e3c753af992e",
    "vendor/lpeglabel/lpltree.h": "e92d8d4676a7757a028052d0e05056575b3821ba577a63231f37902c0dd180eb",
    "vendor/lpeglabel/lpltypes.h": "d07a72b2470210de6ba82ae868bec93be6b15d15b060d8a8abc926de7d090b70",
    "vendor/lpeglabel/lplvm.h": "6eafc02d33ff9d11abf77b8eb49b086ed684d4394c7303972d46dda7f81c2fe7",
    "vendor/lpeglabel/titan_lpeglabel.h": "3384372e7ed10ca5a18bba7f16dbcf4859a740aff3a4f11ec379e79569eb4a22",
    "vendor/lpeglabel/titan_lpeglabel_namespace.h": "233f2208d0669204031c3475abe4ae3dc376f9381fa1ace36d2330e41554640f"
  },
  "tools": {
    "ar": {
      "argv": [
        "/usr/bin/ar"
      ],
      "executable_sha256": "97910d3148c2a6bbaf899821e6f6c07c602fcd1ef00f081ec7a58a348288b7c5"
    },
    "cc": {
      "argv": [
        "/usr/bin/gcc"
      ],
      "executable_sha256": "153e46b4657620f2baef1b4a70b4b4f275772faa5b0fb9e415697e87ebcb7fea"
    },
    "ranlib": {
      "argv": [
        "/usr/bin/ranlib"
      ],
      "executable_sha256": "dc7e8f99cf5956e5ba2540f61f213cc4bbfa08ba2d40a33fe2adbfe726f2948d"
    }
  }
}
```

</details>

## candidate marginal results

Catalog: 53 cases; this report contains 53 measured cases.

Uninstrumented timing uses the original immutable SDK. Instrumented timing uses a private full-provider rebuild with source-scoped semantic probes and the original native payload. The difference below is instrumentation overhead, not a production speedup.

### Uninstrumented end-to-end timing

| Case | Protocol | Rounds / samples | us/op median [range] | RTT p50/p95/p99 us | ops/s | Cold first use us | Residual GC us/op | Retire us |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `call_control` | `same_state` | 6 / 60000 | 0.054 [0.053..0.085] | 0.030/0.030/0.031 | 18404765.6 | 8751.7 | 0.048 | 0.6 |
| `churn_cancel_parked_waiters` | `cancel_churn` | 6 / 3000 | 78.863 [76.111..98.207] | 53.069/212.077/625.494 | 12680.3 | 11055.1 | 3.588 | 56.8 |
| `churn_close_parked_receivers` | `close_churn` | 6 / 3000 | 25.694 [23.952..32.708] | 15.474/46.903/240.329 | 38941.6 | 8837.0 | 7.117 | 57.1 |
| `churn_close_parked_senders` | `close_churn` | 6 / 3000 | 38.488 [36.830..41.153] | 26.990/66.835/361.831 | 25983.9 | 8566.9 | 9.483 | 59.7 |
| `closure_roundtrip_cap0` | `same_state` | 6 / 6000 | 2.931 [2.863..3.863] | 2.831/3.642/7.554 | 341200.2 | 9648.8 | 1.381 | 1.3 |
| `closure_roundtrip_cap1` | `same_state` | 6 / 6000 | 5.980 [5.457..11.529] | 4.303/10.489/51.376 | 167873.8 | 7824.7 | 1.119 | 2.1 |
| `closure_roundtrip_cap64` | `same_state` | 6 / 6000 | 147.201 [140.741..154.865] | 82.750/617.098/852.488 | 6793.6 | 7834.6 | 0.704 | 2.4 |
| `closure_roundtrip_cap8` | `same_state` | 6 / 6000 | 21.681 [21.058..24.979] | 12.623/100.888/148.733 | 46124.4 | 9759.9 | 0.594 | 2.4 |
| `closure_roundtrip_complex_sig` | `same_state` | 6 / 6000 | 6.290 [5.712..7.317] | 4.423/12.698/50.695 | 158992.9 | 9435.5 | 1.174 | 2.1 |
| `codec_large64k_decode` | `same_state` | 6 / 1536 | 7.764 [7.092..14.686] | 2.465/20.158/68.298 | 128984.6 | 10205.7 | 2.494 | 2.0 |
| `codec_large64k_encode` | `same_state` | 6 / 1536 | 7.674 [7.323..10.540] | 2.900/19.100/38.292 | 130312.7 | 9472.7 | 2.446 | 1.9 |
| `codec_large64k_transfer_roundtrip` | `same_state` | 6 / 1536 | 10.290 [8.968..14.417] | 7.580/21.079/81.047 | 97209.4 | 9320.1 | 2.561 | 2.0 |
| `codec_scalar_roundtrip` | `same_state` | 6 / 30000 | 0.532 [0.488..0.692] | 0.356/1.087/1.859 | 1881025.1 | 9423.4 | 0.356 | 1.9 |
| `codec_small_decode` | `same_state` | 6 / 30000 | 1.177 [0.978..1.955] | 0.627/1.693/5.024 | 856494.0 | 8633.5 | 0.180 | 1.9 |
| `codec_small_encode` | `same_state` | 6 / 30000 | 0.530 [0.477..0.957] | 0.406/1.077/1.764 | 1896458.9 | 7547.3 | 0.212 | 1.2 |
| `codec_small_transfer_roundtrip` | `same_state` | 6 / 30000 | 2.610 [2.328..3.172] | 1.679/3.061/13.916 | 383305.5 | 8636.4 | 0.275 | 2.1 |
| `codec_wide16_decode` | `same_state` | 6 / 30000 | 2.618 [2.546..3.718] | 1.618/4.258/28.117 | 382021.0 | 8776.5 | 0.168 | 2.4 |
| `codec_wide16_encode` | `same_state` | 6 / 30000 | 1.239 [1.038..1.939] | 0.952/1.929/3.341 | 823185.9 | 8894.5 | 0.203 | 1.5 |
| `codec_wide16_transfer_roundtrip` | `same_state` | 6 / 30000 | 5.076 [4.763..10.732] | 3.291/10.806/48.040 | 197030.6 | 8999.3 | 0.189 | 2.7 |
| `inspect_function` | `same_state` | 6 / 6000 | 2.029 [1.991..3.226] | 1.793/2.565/4.398 | 492911.2 | 9859.9 | 0.996 | 1.4 |
| `inspect_record` | `same_state` | 6 / 30000 | 0.165 [0.150..0.237] | 0.110/0.215/0.717 | 6079346.2 | 9617.4 | 0.116 | 1.0 |
| `join_cleanup_cancelled_task` | `cleanup_join` | 6 / 600 | 45503.579 [40694.626..45943.794] | 47547.473/49230.026/55474.107 | 22.0 | 8585.7 | 38.579 | 55.0 |
| `join_ordinary` | `ordinary_join` | 6 / 600 | 6741.122 [6578.917..7444.721] | 6736.220/7487.949/7782.505 | 148.4 | 8613.1 | 28.710 | 55.7 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | `pool_16_reply` | 6 / 6000 | 3.660 [2.587..4.451] | 45.620/78.411/133.389 | 274020.5 | 8590.1 | 1.324 | 6678.6 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `pool_16_reply` | 6 / 6000 | 3.542 [3.052..3.806] | 38.362/82.133/186.138 | 282311.3 | 8354.8 | 1.672 | 6081.2 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `pool_four_reply` | 6 / 6000 | 21.791 [17.192..26.137] | 18.605/25.828/40.651 | 46569.5 | 8838.7 | 1.404 | 5599.2 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `pool_four_reply` | 6 / 6000 | 6.981 [5.825..8.374] | 23.855/42.294/56.275 | 144121.7 | 8056.8 | 1.321 | 5677.8 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `pool_four_reply` | 6 / 6000 | 6.926 [5.716..8.432] | 21.806/35.822/55.650 | 144445.2 | 8461.5 | 1.150 | 5502.8 |
| `mpmc_record_inflight16_cap16_4p4c` | `pool_16_reply` | 6 / 6000 | 3.235 [2.352..4.475] | 36.784/84.328/160.925 | 309470.9 | 7432.8 | 1.711 | 5606.4 |
| `mpmc_record_inflight16_cap2_4p4c` | `pool_16_reply` | 6 / 6000 | 3.400 [2.868..3.605] | 42.219/72.390/135.333 | 294225.0 | 7686.8 | 1.681 | 5490.1 |
| `mpmc_record_inflight1_cap1_2p2c` | `pool_four_reply` | 6 / 6000 | 22.498 [16.570..24.930] | 19.612/26.710/51.496 | 44457.2 | 9917.3 | 1.394 | 4851.4 |
| `mpmc_record_inflight4_cap1_2p2c` | `pool_four_reply` | 6 / 6000 | 6.333 [5.903..8.130] | 19.386/41.953/65.953 | 157915.5 | 8487.8 | 0.971 | 4738.5 |
| `mpmc_record_inflight4_cap4_2p2c` | `pool_four_reply` | 6 / 6000 | 6.853 [4.992..7.027] | 23.068/33.998/49.533 | 145924.8 | 8423.6 | 1.373 | 5274.6 |
| `overhead_control` | `same_state` | 6 / 60000 | 0.067 [0.065..0.100] | 0.040/0.041/0.045 | 14818643.6 | 9728.4 | 0.041 | 0.8 |
| `queue_opaque_hook8` | `same_state_queue` | 6 / 30000 | 3.743 [3.286..7.365] | 2.439/5.235/43.156 | 267164.8 | 8833.0 | 0.406 | 93.7 |
| `queue_packed_hook8` | `same_state_queue` | 6 / 30000 | 4.608 [4.492..5.043] | 3.026/9.017/47.940 | 217022.5 | 9360.7 | 0.210 | 80.8 |
| `queue_plain_bytes8` | `same_state_queue` | 6 / 30000 | 2.697 [2.645..3.192] | 1.824/3.322/20.483 | 370761.2 | 10378.2 | 0.289 | 61.1 |
| `queue_real_receiver` | `same_state_queue` | 6 / 30000 | 3.707 [3.615..5.314] | 2.625/4.524/42.259 | 269790.1 | 8462.4 | 0.376 | 72.0 |
| `queue_real_sender` | `same_state_queue` | 6 / 30000 | 3.944 [3.718..4.734] | 2.615/7.389/43.186 | 253577.6 | 9017.6 | 0.369 | 62.0 |
| `sender_clone` | `same_state_queue` | 6 / 30000 | 0.197 [0.184..0.306] | 0.160/0.220/0.346 | 5065588.7 | 8334.2 | 0.162 | 34.0 |
| `spsc_endpoint_carried_persistent` | `persistent_reply` | 6 / 6000 | 23.541 [14.131..28.641] | 18.053/48.776/133.640 | 43105.4 | 7947.2 | 1.677 | 1645.9 |
| `spsc_endpoint_fresh_reply` | `fresh_reply` | 6 / 3000 | 18.960 [15.560..21.938] | 17.974/28.453/40.627 | 52942.0 | 8625.6 | 4.263 | 2066.4 |
| `spsc_endpoint_pool4_reply` | `pool_four_reply` | 6 / 6000 | 19.740 [13.651..24.729] | 13.405/38.903/103.880 | 50689.8 | 8901.0 | 1.318 | 1300.9 |
| `spsc_large64k_endpoint_pool4` | `pool_four_reply` | 6 / 1536 | 46.371 [23.953..56.383] | 36.674/86.597/212.041 | 21586.3 | 7589.9 | 5.296 | 1365.3 |
| `spsc_large64k_persistent` | `persistent_reply` | 6 / 1536 | 43.289 [21.172..46.152] | 34.965/82.775/183.298 | 23108.9 | 8632.9 | 7.545 | 1313.8 |
| `spsc_opaque_persistent` | `persistent_reply` | 6 / 6000 | 18.734 [13.469..26.245] | 14.436/40.531/100.819 | 56207.3 | 9905.7 | 1.477 | 1158.0 |
| `spsc_record_persistent` | `persistent_reply` | 6 / 6000 | 21.278 [12.630..25.300] | 16.726/43.451/103.609 | 47142.3 | 7875.8 | 1.514 | 1177.4 |
| `spsc_record_pool4_control` | `pool_four_reply` | 6 / 6000 | 22.215 [13.766..25.963] | 16.441/49.568/100.773 | 45341.5 | 10044.6 | 1.479 | 1332.9 |
| `spsc_scalar_persistent` | `persistent_reply` | 6 / 6000 | 8.535 [6.347..11.179] | 7.895/12.859/22.286 | 118851.3 | 10585.9 | 2.359 | 1774.9 |
| `wait_empty_receiver_endpoint` | `directed_empty_wait` | 6 / 3000 | 33.279 [22.984..41.485] | 23.189/57.769/305.060 | 30050.7 | 9249.7 | 5.649 | 1613.4 |
| `wait_empty_receiver_record` | `directed_empty_wait` | 6 / 3000 | 34.458 [27.863..40.904] | 22.577/64.350/353.966 | 29037.7 | 8533.1 | 5.041 | 1615.8 |
| `wait_full_sender_endpoint` | `directed_full_wait` | 6 / 3000 | 35.959 [24.166..42.194] | 25.614/66.514/238.756 | 27809.9 | 9282.8 | 5.892 | 2122.8 |
| `wait_full_sender_record` | `directed_full_wait` | 6 / 3000 | 32.701 [29.137..34.654] | 22.397/58.675/307.534 | 30662.0 | 8951.0 | 6.030 | 1834.4 |

RTT columns are medians of per-round percentiles, not pooled percentiles. Directed full-sender samples are admission/previous-packet release acknowledgements, not processing RTTs for the newly admitted request. Churn includes fresh resource/state creation.

### Exact native branch counts (representative instrumented round)

Counters/per-op traffic select the actual upper-median body-time round; all instrumented rounds remain in the summary JSON. Counts are branch events within the body window, including worker request receives and protocol-control channels. A wait can begin before the window. Fast successes are successful first readiness checks, not post-suspension retry successes. Closed outcomes are never counted as successful fast paths/rechecks. Slow attempts are failed ready checks entering registration; native suspensions, successful registration rechecks, selected waiter notification attempts and nominal CancellationReason errors are separate events.

| Case | Fast | Slow | Recheck OK | Suspends | Ordinary / cleanup join suspends | Notify | Cancel | Async init / public close requests |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `call_control` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `churn_cancel_parked_waiters` | 500 | 1000 | 0 | 1000 | 0 / 0 | 0 | 1000 | 1000 / 1000 |
| `churn_close_parked_receivers` | 0 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 1000 / 1000 |
| `churn_close_parked_senders` | 500 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 1000 / 1000 |
| `closure_roundtrip_cap0` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `closure_roundtrip_cap1` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `closure_roundtrip_cap64` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `closure_roundtrip_cap8` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `closure_roundtrip_complex_sig` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_large64k_decode` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_large64k_encode` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_large64k_transfer_roundtrip` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_scalar_roundtrip` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_small_decode` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_small_encode` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_small_transfer_roundtrip` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_wide16_decode` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_wide16_encode` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `codec_wide16_transfer_roundtrip` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `inspect_function` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `inspect_record` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `join_cleanup_cancelled_task` | 300 | 600 | 0 | 600 | 100 / 100 | 400 | 200 | 800 / 700 |
| `join_ordinary` | 200 | 300 | 0 | 300 | 100 / 0 | 300 | 0 | 500 / 400 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 4342 | 2763 | 271 | 2492 | 0 / 0 | 2552 | 0 | 2763 / 2823 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 4291 | 2862 | 339 | 2523 | 0 / 0 | 2583 | 0 | 2862 / 2922 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 4003 | 2504 | 0 | 2504 | 0 / 0 | 2504 | 0 | 2504 / 2504 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 4145 | 2520 | 240 | 2280 | 0 / 0 | 2286 | 0 | 2520 / 2526 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 4212 | 2487 | 221 | 2265 | 0 / 0 | 2272 | 0 | 2486 / 2493 |
| `mpmc_record_inflight16_cap16_4p4c` | 4345 | 2791 | 305 | 2486 | 0 / 0 | 2546 | 0 | 2791 / 2851 |
| `mpmc_record_inflight16_cap2_4p4c` | 4274 | 2842 | 334 | 2508 | 0 / 0 | 2568 | 0 | 2842 / 2902 |
| `mpmc_record_inflight1_cap1_2p2c` | 3999 | 2619 | 3 | 2616 | 0 / 0 | 2616 | 0 | 2619 / 2619 |
| `mpmc_record_inflight4_cap1_2p2c` | 4142 | 2614 | 369 | 2245 | 0 / 0 | 2251 | 0 | 2614 / 2620 |
| `mpmc_record_inflight4_cap4_2p2c` | 4223 | 2446 | 255 | 2191 | 0 / 0 | 2197 | 0 | 2446 / 2452 |
| `overhead_control` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_opaque_hook8` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_packed_hook8` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_plain_bytes8` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_real_receiver` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_real_sender` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `sender_clone` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `spsc_endpoint_carried_persistent` | 2000 | 2000 | 24 | 1976 | 0 / 0 | 1976 | 0 | 2000 / 2000 |
| `spsc_endpoint_fresh_reply` | 1000 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 1000 / 1000 |
| `spsc_endpoint_pool4_reply` | 2000 | 2000 | 37 | 1963 | 0 / 0 | 1963 | 0 | 2000 / 2000 |
| `spsc_large64k_endpoint_pool4` | 512 | 512 | 0 | 512 | 0 / 0 | 512 | 0 | 512 / 512 |
| `spsc_large64k_persistent` | 512 | 512 | 0 | 512 | 0 / 0 | 512 | 0 | 512 / 512 |
| `spsc_opaque_persistent` | 2001 | 1999 | 14 | 1985 | 0 / 0 | 1985 | 0 | 1999 / 1999 |
| `spsc_record_persistent` | 2000 | 2000 | 0 | 2000 | 0 / 0 | 2000 | 0 | 2000 / 2000 |
| `spsc_record_pool4_control` | 2000 | 2000 | 36 | 1964 | 0 / 0 | 1964 | 0 | 2000 / 2000 |
| `spsc_scalar_persistent` | 2001 | 1999 | 40 | 1959 | 0 / 0 | 1959 | 0 | 1999 / 1999 |
| `wait_empty_receiver_endpoint` | 1000 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 1000 / 1000 |
| `wait_empty_receiver_record` | 1000 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 1000 / 1000 |
| `wait_full_sender_endpoint` | 1657 | 1343 | 159 | 1184 | 0 / 0 | 1184 | 0 | 1343 / 1343 |
| `wait_full_sender_record` | 1758 | 1242 | 184 | 1058 | 0 / 0 | 1058 | 0 | 1242 / 1242 |

### Native async handle retirement (representative instrumented round)

| Case | Whole-case async init | Public close requests | Terminal close callbacks | Async retirements at successful loop close | Successful / attempted loop closes |
|---|---:|---:|---:|---:|---:|
| `call_control` | 0 | 0 | 0 | 0 | 0 / 0 |
| `churn_cancel_parked_waiters` | 1065 | 1064 | 1064 | 1 | 1 / 1 |
| `churn_close_parked_receivers` | 1065 | 1064 | 1064 | 1 | 1 / 1 |
| `churn_close_parked_senders` | 1065 | 1064 | 1064 | 1 | 1 / 1 |
| `closure_roundtrip_cap0` | 0 | 0 | 0 | 0 | 0 / 0 |
| `closure_roundtrip_cap1` | 0 | 0 | 0 | 0 | 0 / 0 |
| `closure_roundtrip_cap64` | 0 | 0 | 0 | 0 | 0 / 0 |
| `closure_roundtrip_cap8` | 0 | 0 | 0 | 0 | 0 / 0 |
| `closure_roundtrip_complex_sig` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_large64k_decode` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_large64k_encode` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_large64k_transfer_roundtrip` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_scalar_roundtrip` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_small_decode` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_small_encode` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_small_transfer_roundtrip` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_wide16_decode` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_wide16_encode` | 0 | 0 | 0 | 0 | 0 / 0 |
| `codec_wide16_transfer_roundtrip` | 0 | 0 | 0 | 0 | 0 / 0 |
| `inspect_function` | 0 | 0 | 0 | 0 | 0 / 0 |
| `inspect_record` | 0 | 0 | 0 | 0 | 0 / 0 |
| `join_cleanup_cancelled_task` | 865 | 756 | 756 | 109 | 109 / 109 |
| `join_ordinary` | 541 | 432 | 432 | 109 | 109 / 109 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 13837 | 13828 | 13828 | 9 | 9 / 9 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 14402 | 14393 | 14393 | 9 | 9 / 9 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 2846 | 2841 | 2841 | 5 | 5 / 5 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 3823 | 3818 | 3818 | 5 | 5 / 5 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 3726 | 3721 | 3721 | 5 | 5 / 5 |
| `mpmc_record_inflight16_cap16_4p4c` | 13795 | 13786 | 13786 | 9 | 9 / 9 |
| `mpmc_record_inflight16_cap2_4p4c` | 14474 | 14465 | 14465 | 9 | 9 / 9 |
| `mpmc_record_inflight1_cap1_2p2c` | 2965 | 2960 | 2960 | 5 | 5 / 5 |
| `mpmc_record_inflight4_cap1_2p2c` | 3953 | 3948 | 3948 | 5 | 5 / 5 |
| `mpmc_record_inflight4_cap4_2p2c` | 3724 | 3719 | 3719 | 5 | 5 / 5 |
| `overhead_control` | 0 | 0 | 0 | 0 | 0 / 0 |
| `queue_opaque_hook8` | 1 | 0 | 0 | 1 | 1 / 1 |
| `queue_packed_hook8` | 1 | 0 | 0 | 1 | 1 / 1 |
| `queue_plain_bytes8` | 1 | 0 | 0 | 1 | 1 / 1 |
| `queue_real_receiver` | 1 | 0 | 0 | 1 | 1 / 1 |
| `queue_real_sender` | 1 | 0 | 0 | 1 | 1 / 1 |
| `sender_clone` | 1 | 0 | 0 | 1 | 1 / 1 |
| `spsc_endpoint_carried_persistent` | 2134 | 2132 | 2132 | 2 | 2 / 2 |
| `spsc_endpoint_fresh_reply` | 1070 | 1068 | 1068 | 2 | 2 / 2 |
| `spsc_endpoint_pool4_reply` | 2134 | 2132 | 2132 | 2 | 2 / 2 |
| `spsc_large64k_endpoint_pool4` | 550 | 548 | 548 | 2 | 2 / 2 |
| `spsc_large64k_persistent` | 550 | 548 | 548 | 2 | 2 / 2 |
| `spsc_opaque_persistent` | 2133 | 2131 | 2131 | 2 | 2 / 2 |
| `spsc_record_persistent` | 2134 | 2132 | 2132 | 2 | 2 / 2 |
| `spsc_record_pool4_control` | 2134 | 2132 | 2132 | 2 | 2 / 2 |
| `spsc_scalar_persistent` | 2133 | 2131 | 2131 | 2 | 2 / 2 |
| `wait_empty_receiver_endpoint` | 1070 | 1068 | 1068 | 2 | 2 / 2 |
| `wait_empty_receiver_record` | 1070 | 1068 | 1068 | 2 | 2 / 2 |
| `wait_full_sender_endpoint` | 1445 | 1443 | 1443 | 2 | 2 / 2 |
| `wait_full_sender_record` | 1344 | 1342 | 1342 | 2 | 2 / 2 |

Whole-case counters start at the setup snapshot after cold first use; identities are tracked from process birth, including cold loops. Libuv initializes loop-internal async handles through uv_async_init but retires them directly during successful uv_loop_close. Those retirements are not fabricated public close requests or callbacks. A busy/failed loop close retires no identity; active_async_handles remains the actual unretired registry count and must be zero. Real UV allocation traffic is not suppressed.


### Allocation and observed copy traffic

| Case | Lua allocs / requested B per op | Native allocs / requested B per op | Interposed copy B/op (outside / inside Lua allocator) | Analytical reference B/op (not wire/copy bytes) |
|---|---:|---:|---:|---:|
| `call_control` | 0.00 / 0.0 | 0.00 / 0.0 | 0.0 (0.0 / 0.0) | 0 |
| `churn_cancel_parked_waiters` | 99.40 / 26434.4 | 8.00 / 560.0 | 9924.7 (9924.7 / 0.0) | 0 |
| `churn_close_parked_receivers` | 80.23 / 24922.7 | 3.00 / 152.0 | 47.6 (47.6 / 0.0) | 0 |
| `churn_close_parked_senders` | 85.70 / 20214.9 | 6.00 / 536.0 | 2417.0 (2417.0 / 0.0) | 0 |
| `closure_roundtrip_cap0` | 54.01 / 3147.4 | 2.00 / 384.0 | 132.0 (132.0 / 0.0) | 0 |
| `closure_roundtrip_cap1` | 106.01 / 6004.5 | 2.00 / 384.0 | 293.0 (293.0 / 0.0) | 0 |
| `closure_roundtrip_cap64` | 3038.07 / 189087.5 | 4.00 / 1920.0 | 12065.0 (12065.0 / 0.0) | 0 |
| `closure_roundtrip_cap8` | 444.02 / 26332.0 | 2.00 / 384.0 | 1532.0 (1532.0 / 0.0) | 0 |
| `closure_roundtrip_complex_sig` | 106.02 / 6004.7 | 2.00 / 384.0 | 293.0 (293.0 / 0.0) | 0 |
| `codec_large64k_decode` | 16.02 / 66349.6 | 0.00 / 0.0 | 65562.0 (65562.0 / 0.0) | 65540 |
| `codec_large64k_encode` | 7.02 / 65953.6 | 2.00 / 131136.0 | 131076.0 (131076.0 / 0.0) | 65540 |
| `codec_large64k_transfer_roundtrip` | 27.04 / 67311.0 | 3.00 / 131456.0 | 131113.0 (131113.0 / 0.0) | 65540 |
| `codec_scalar_roundtrip` | 4.00 / 512.0 | 1.00 / 128.0 | 0.0 (0.0 / 0.0) | 8 |
| `codec_small_decode` | 21.00 / 1049.0 | 0.00 / 0.0 | 83.0 (83.0 / 0.0) | 11 |
| `codec_small_encode` | 6.00 / 380.0 | 1.00 / 64.0 | 7.0 (7.0 / 0.0) | 11 |
| `codec_small_transfer_roundtrip` | 32.00 / 2009.1 | 2.00 / 384.0 | 106.0 (106.0 / 0.0) | 11 |
| `codec_wide16_decode` | 44.00 / 3805.2 | 0.00 / 0.0 | 749.0 (749.0 / 0.0) | 33 |
| `codec_wide16_encode` | 6.00 / 380.0 | 1.00 / 64.0 | 0.0 (0.0 / 0.0) | 33 |
| `codec_wide16_transfer_roundtrip` | 55.00 / 4765.1 | 2.00 / 384.0 | 764.0 (764.0 / 0.0) | 33 |
| `inspect_function` | 50.01 / 2376.4 | 0.00 / 0.0 | 80.0 (80.0 / 0.0) | 0 |
| `inspect_record` | 2.00 / 172.0 | 0.00 / 0.0 | 0.0 (0.0 / 0.0) | 0 |
| `join_cleanup_cancelled_task` | 25100.72 / 4056704.5 | 27.00 / 3752.0 | 5204318.8 (5204318.8 / 0.0) | 0 |
| `join_ordinary` | 24668.94 / 4001228.7 | 20.00 / 2832.0 | 1647848.2 (1647848.2 / 0.0) | 0 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 125.41 / 9756.9 | 6.07 / 1000.7 | 265.4 (265.4 / 0.0) | 0 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 126.61 / 9887.8 | 6.07 / 1000.7 | 265.3 (265.3 / 0.0) | 0 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 121.40 / 9317.2 | 6.00 / 992.5 | 265.0 (265.0 / 0.0) | 0 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 121.16 / 9343.2 | 6.01 / 993.3 | 265.1 (265.1 / 0.0) | 0 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 121.14 / 9319.9 | 6.01 / 993.3 | 265.1 (265.1 / 0.0) | 0 |
| `mpmc_record_inflight16_cap16_4p4c` | 116.74 / 9102.4 | 5.07 / 904.7 | 265.3 (265.3 / 0.0) | 0 |
| `mpmc_record_inflight16_cap2_4p4c` | 117.34 / 9160.9 | 5.07 / 904.7 | 265.3 (265.3 / 0.0) | 0 |
| `mpmc_record_inflight1_cap1_2p2c` | 114.04 / 8788.3 | 5.00 / 896.5 | 265.0 (265.0 / 0.0) | 0 |
| `mpmc_record_inflight4_cap1_2p2c` | 113.38 / 8772.5 | 5.01 / 897.3 | 265.0 (265.0 / 0.0) | 0 |
| `mpmc_record_inflight4_cap4_2p2c` | 111.44 / 8546.4 | 5.01 / 897.3 | 265.1 (265.1 / 0.0) | 0 |
| `overhead_control` | 0.00 / 0.0 | 0.00 / 0.0 | 0.0 (0.0 / 0.0) | 0 |
| `queue_opaque_hook8` | 44.00 / 2865.1 | 2.00 / 384.0 | 139.0 (139.0 / 0.0) | 21 |
| `queue_packed_hook8` | 65.00 / 3973.2 | 2.00 / 384.0 | 196.0 (196.0 / 0.0) | 21 |
| `queue_plain_bytes8` | 36.00 / 2273.1 | 2.00 / 384.0 | 139.0 (139.0 / 0.0) | 21 |
| `queue_real_receiver` | 45.00 / 2969.2 | 3.00 / 480.0 | 138.0 (138.0 / 0.0) | 21 |
| `queue_real_sender` | 45.00 / 2969.1 | 3.00 / 480.0 | 136.0 (136.0 / 0.0) | 21 |
| `sender_clone` | 2.00 / 168.0 | 0.00 / 0.0 | 0.0 (0.0 / 0.0) | 21 |
| `spsc_endpoint_carried_persistent` | 109.46 / 8059.9 | 5.00 / 864.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_endpoint_fresh_reply` | 113.23 / 8372.9 | 8.00 / 1016.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_endpoint_pool4_reply` | 109.43 / 8057.8 | 5.00 / 864.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_large64k_endpoint_pool4` | 110.51 / 73630.2 | 6.00 / 131936.0 | 131332.0 (131332.0 / 0.0) | 65565 |
| `spsc_large64k_persistent` | 101.41 / 72924.8 | 5.00 / 131840.0 | 131330.0 (131330.0 / 0.0) | 65565 |
| `spsc_opaque_persistent` | 108.39 / 7950.2 | 4.00 / 768.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_record_persistent` | 100.45 / 7362.6 | 4.00 / 768.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_record_pool4_control` | 100.41 / 7361.1 | 4.00 / 768.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_scalar_persistent` | 38.40 / 3934.3 | 2.00 / 256.0 | 0.0 (0.0 / 0.0) | 16 |
| `wait_empty_receiver_endpoint` | 108.17 / 17702.9 | 4.00 / 608.0 | 169.3 (169.3 / 0.0) | 29 |
| `wait_empty_receiver_record` | 98.16 / 16942.5 | 3.00 / 512.0 | 169.3 (169.3 / 0.0) | 29 |
| `wait_full_sender_endpoint` | 150.15 / 20768.1 | 6.00 / 992.0 | 295.3 (295.3 / 0.0) | 29 |
| `wait_full_sender_record` | 136.04 / 16365.7 | 5.00 / 896.0 | 295.3 (295.3 / 0.0) | 29 |

Lua allocator requests include state birth and terminal close. Only allocations made inside the underlying Lua allocator are excluded from native traffic; real UV allocations are not suppressed. Copy counts cover interposed memcpy **and memmove** calls, not inlined copies, scalar stores or libc-internal copying. Actual total wire bytes are unavailable; the analytical reference can use a different payload/ID and is not presented as measured transfer traffic.

### Lifecycle and post-retirement evidence (all instrumented rounds)

| Case | Rounds | Channels delta range | Controls delta range | Active worker range | Lua state delta / active async handles / pending wait probes | Observed native block / usable B net ranges | Host Lua net B range | Checksums / lifecycle |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| `call_control` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8609.0 | valid |
| `churn_cancel_parked_waiters` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 137.0..137.0 | valid |
| `churn_close_parked_receivers` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | -28.0..36.0 | valid |
| `churn_close_parked_senders` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 73.0..137.0 | valid |
| `closure_roundtrip_cap0` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `closure_roundtrip_cap1` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `closure_roundtrip_cap64` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `closure_roundtrip_cap8` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8609.0 | valid |
| `closure_roundtrip_complex_sig` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8545.0 | valid |
| `codec_large64k_decode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8609.0 | valid |
| `codec_large64k_encode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `codec_large64k_transfer_roundtrip` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8809.0..8809.0 | valid |
| `codec_scalar_roundtrip` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8545.0 | valid |
| `codec_small_decode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8609.0 | valid |
| `codec_small_encode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `codec_small_transfer_roundtrip` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8745.0..8809.0 | valid |
| `codec_wide16_decode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `codec_wide16_encode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8609.0 | valid |
| `codec_wide16_transfer_roundtrip` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8745.0..8809.0 | valid |
| `inspect_function` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `inspect_record` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `join_cleanup_cancelled_task` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 3265.0..3265.0 | valid |
| `join_ordinary` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 36.0..36.0 | valid |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7484.0..7548.0 | valid |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7484.0..7548.0 | valid |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7484.0..7548.0 | valid |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7548.0..7548.0 | valid |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7484.0..7484.0 | valid |
| `mpmc_record_inflight16_cap16_4p4c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 9763.0..9763.0 | valid |
| `mpmc_record_inflight16_cap2_4p4c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 9699.0..9699.0 | valid |
| `mpmc_record_inflight1_cap1_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 9699.0..9763.0 | valid |
| `mpmc_record_inflight4_cap1_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 9699.0..9763.0 | valid |
| `mpmc_record_inflight4_cap4_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 9763.0..9763.0 | valid |
| `overhead_control` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8609.0 | valid |
| `queue_opaque_hook8` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 5638.0..5638.0 | valid |
| `queue_packed_hook8` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 5574.0..5638.0 | valid |
| `queue_plain_bytes8` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 45.0..45.0 | valid |
| `queue_real_receiver` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2358.0..2358.0 | valid |
| `queue_real_sender` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2422.0..2422.0 | valid |
| `sender_clone` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | -135.0..-135.0 | valid |
| `spsc_endpoint_carried_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2331.0..2395.0 | valid |
| `spsc_endpoint_fresh_reply` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2331.0..2395.0 | valid |
| `spsc_endpoint_pool4_reply` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2395.0..2395.0 | valid |
| `spsc_large64k_endpoint_pool4` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2395.0..2395.0 | valid |
| `spsc_large64k_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2087.0..2087.0 | valid |
| `spsc_opaque_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 5611.0..5611.0 | valid |
| `spsc_record_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | -94.0..-30.0 | valid |
| `spsc_record_pool4_control` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2197.0..2197.0 | valid |
| `spsc_scalar_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | -94.0..-30.0 | valid |
| `wait_empty_receiver_endpoint` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2391.0..2455.0 | valid |
| `wait_empty_receiver_record` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 98.0..162.0 | valid |
| `wait_full_sender_endpoint` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2364.0..2428.0 | valid |
| `wait_full_sender_record` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 3.0..3.0 | valid |

Channel/control counts are actual native birth/destruction probes. Worker quiescence waits for the native end-of-worker release, not a fixed number of loop turns or public join alone; it is native domain-ownership retirement evidence, not an OS-join proof. The pre-wake resource-ownership correctness checkpoint intentionally retains known legacy detached-thread/proxy-early-terminal behavior and is not final Thread approval. The separate final corrected wake/join candidate requires actual OS join before every proxy terminal and full platform correctness evidence. Explicit residual collections occur outside body timing. The allocator's signed net delta is an observed ledger, **not** a complete retained-native-memory oracle; lifecycle counts are reported separately. Failed calibration, missing/truncated samples, checksum errors and unretired native domains reject a campaign.

### Overlapping source-scoped stage intervals

| Case | Wake attribution | Sender entry through encode | Queue lock + branch | Registration after failed check | Notify to continuation | Post-dequeue decode + return | Reply processing |
|---|---|---:|---:|---:|---:|---:|---:|
| `call_control` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `churn_cancel_parked_waiters` | `unavailable_cancelled_or_nonunique_notification` | 0.531/67.206 (1000 total; 500..500/round) | 0.030/0.241 (5000 total; 2500..2500/round) | 1.087/23.104 (2000 total; 1000..1000/round) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `churn_close_parked_receivers` | `exact_waiter_notification_to_continuation` | unavailable (0 samples) | 0.040/0.411 (6000 total; 3000..3000/round) | 1.753/18.584 (2000 total; 1000..1000/round) | 3.031/7.188 (2000 total; 1000..1000/round) | unavailable (0 samples) | unavailable (0 samples) |
| `churn_close_parked_senders` | `exact_waiter_notification_to_continuation` | 1.292/10.409 (2000 total; 1000..1000/round) | 0.035/0.280 (7000 total; 3500..3500/round) | 0.871/5.210 (2000 total; 1000..1000/round) | 7.870/30.287 (2000 total; 1000..1000/round) | unavailable (0 samples) | unavailable (0 samples) |
| `closure_roundtrip_cap0` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `closure_roundtrip_cap1` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `closure_roundtrip_cap64` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `closure_roundtrip_cap8` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `closure_roundtrip_complex_sig` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_large64k_decode` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_large64k_encode` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_large64k_transfer_roundtrip` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_scalar_roundtrip` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_small_decode` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_small_encode` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_small_transfer_roundtrip` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_wide16_decode` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_wide16_encode` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `codec_wide16_transfer_roundtrip` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `inspect_function` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `inspect_record` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `join_cleanup_cancelled_task` | `partial_exact_only` | unavailable (0 samples) | 0.326/7.749 (3200 total; 1600..1600/round) | unavailable (0 samples) | 20.007/55.930 (800 total; 400..400/round) | unavailable (0 samples) | unavailable (0 samples) |
| `join_ordinary` | `exact_waiter_notification_to_continuation` | unavailable (0 samples) | 0.361/6.822 (1800 total; 900..900/round) | unavailable (0 samples) | 15.319/40.055 (600 total; 300..300/round) | unavailable (0 samples) | unavailable (0 samples) |
| `mpmc_endpoint_inflight16_cap16_4p4c` | `exact_waiter_notification_to_continuation` | 3.321/11.762 (4000 total; 2000..2000/round) | 0.261/9.041 (22330 total; 10939..11391/round) | 3.066/6.572 (2000 total; 1000..1000/round) | 52.793/172.267 (4878 total; 2326..2552/round) | 6.236/15.730 (2000 total; 1000..1000/round) | 0.030/0.096 (2000 total; 1000..1000/round) |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `exact_waiter_notification_to_continuation` | 3.391/11.827 (4000 total; 2000..2000/round) | 0.396/10.670 (22934 total; 11413..11521/round) | 3.537/8.972 (2088 total; 1038..1050/round) | 59.602/211.214 (5108 total; 2525..2583/round) | 7.038/15.479 (2000 total; 1000..1000/round) | 0.030/0.085 (2000 total; 1000..1000/round) |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `exact_waiter_notification_to_continuation` | 1.914/7.739 (4000 total; 2000..2000/round) | 0.145/1.608 (22025 total; 11009..11016/round) | 1.373/6.517 (2000 total; 1000..1000/round) | 3.436/9.253 (5004 total; 2500..2504/round) | 2.910/9.628 (2000 total; 1000..1000/round) | 0.035/0.060 (2000 total; 1000..1000/round) |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `exact_waiter_notification_to_continuation` | 2.800/10.540 (4000 total; 2000..2000/round) | 0.170/3.772 (21692 total; 10820..10872/round) | 2.194/7.710 (2337 total; 1145..1192/round) | 11.982/53.445 (4545 total; 2259..2286/round) | 5.059/15.113 (2000 total; 1000..1000/round) | 0.030/0.060 (2000 total; 1000..1000/round) |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `exact_waiter_notification_to_continuation` | 2.485/6.782 (4000 total; 2000..2000/round) | 0.121/3.412 (21412 total; 10640..10772/round) | 1.883/5.019 (2000 total; 1000..1000/round) | 10.279/38.111 (4474 total; 2202..2272/round) | 4.574/13.640 (2000 total; 1000..1000/round) | 0.035/0.065 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight16_cap16_4p4c` | `exact_waiter_notification_to_continuation` | 2.955/11.482 (4000 total; 2000..2000/round) | 0.321/9.678 (22132 total; 10719..11413/round) | 3.381/7.434 (2000 total; 1000..1000/round) | 52.914/154.173 (4778 total; 2232..2546/round) | 6.993/14.873 (2000 total; 1000..1000/round) | 0.040/0.080 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight16_cap2_4p4c` | `exact_waiter_notification_to_continuation` | 2.194/5.761 (4000 total; 2000..2000/round) | 0.221/7.745 (22626 total; 11140..11486/round) | 2.570/8.576 (2098 total; 1047..1051/round) | 41.808/174.916 (4943 total; 2375..2568/round) | 5.245/11.311 (2000 total; 1000..1000/round) | 0.025/0.056 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight1_cap1_2p2c` | `exact_waiter_notification_to_continuation` | 1.748/11.136 (4000 total; 2000..2000/round) | 0.175/3.111 (22251 total; 11008..11243/round) | 1.804/10.194 (2000 total; 1000..1000/round) | 3.947/19.060 (5116 total; 2500..2616/round) | 3.716/19.246 (2000 total; 1000..1000/round) | 0.040/0.075 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight4_cap1_2p2c` | `exact_waiter_notification_to_continuation` | 1.833/6.347 (4000 total; 2000..2000/round) | 0.206/4.012 (21962 total; 10879..11083/round) | 2.074/6.428 (2368 total; 1179..1189/round) | 10.280/47.599 (4648 total; 2251..2397/round) | 4.694/13.360 (2000 total; 1000..1000/round) | 0.030/0.065 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight4_cap4_2p2c` | `exact_waiter_notification_to_continuation` | 1.934/6.748 (4000 total; 2000..2000/round) | 0.160/4.117 (20802 total; 10145..10657/round) | 1.783/5.700 (2000 total; 1000..1000/round) | 11.226/30.737 (4122 total; 1925..2197/round) | 4.835/13.691 (2000 total; 1000..1000/round) | 0.035/0.060 (2000 total; 1000..1000/round) |
| `overhead_control` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `queue_opaque_hook8` | `no_suspensions` | 1.127/7.214 (10000 total; 5000..5000/round) | 0.030/0.110 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 1.613/9.583 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `queue_packed_hook8` | `no_suspensions` | 1.653/27.832 (10000 total; 5000..5000/round) | 0.030/0.190 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 2.003/67.857 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `queue_plain_bytes8` | `no_suspensions` | 0.766/3.897 (10000 total; 5000..5000/round) | 0.030/0.155 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 1.358/17.338 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `queue_real_receiver` | `no_suspensions` | 1.292/8.877 (10000 total; 5000..5000/round) | 0.030/0.141 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 1.959/20.788 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `queue_real_sender` | `no_suspensions` | 1.462/5.951 (10000 total; 5000..5000/round) | 0.030/0.125 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 2.114/19.001 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `sender_clone` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `spsc_endpoint_carried_persistent` | `exact_waiter_notification_to_continuation` | 1.533/13.075 (4000 total; 2000..2000/round) | 0.196/1.678 (15946 total; 7970..7976/round) | 0.967/16.797 (2000 total; 1000..1000/round) | 3.477/10.329 (3946 total; 1970..1976/round) | 2.314/25.176 (2000 total; 1000..1000/round) | 0.130/1.683 (2000 total; 1000..1000/round) |
| `spsc_endpoint_fresh_reply` | `exact_waiter_notification_to_continuation` | 2.284/5.480 (2000 total; 1000..1000/round) | 0.215/1.738 (8000 total; 4000..4000/round) | 1.302/5.100 (1000 total; 500..500/round) | 4.168/9.238 (2000 total; 1000..1000/round) | 3.461/11.146 (1000 total; 500..500/round) | 0.145/1.553 (1000 total; 500..500/round) |
| `spsc_endpoint_pool4_reply` | `exact_waiter_notification_to_continuation` | 1.283/12.543 (4000 total; 2000..2000/round) | 0.155/1.478 (15935 total; 7963..7972/round) | 0.877/18.299 (1999 total; 999..1000/round) | 2.075/10.184 (3936 total; 1963..1973/round) | 1.889/25.523 (2000 total; 1000..1000/round) | 0.065/1.062 (2000 total; 1000..1000/round) |
| `spsc_large64k_endpoint_pool4` | `exact_waiter_notification_to_continuation` | 2.275/7.419 (1024 total; 512..512/round) | 0.120/1.859 (4096 total; 2048..2048/round) | 0.882/2.234 (512 total; 256..256/round) | 2.405/8.631 (1024 total; 512..512/round) | 1.929/4.569 (512 total; 256..256/round) | 0.096/0.305 (512 total; 256..256/round) |
| `spsc_large64k_persistent` | `exact_waiter_notification_to_continuation` | 3.016/12.844 (1024 total; 512..512/round) | 0.175/1.473 (4096 total; 2048..2048/round) | 0.956/3.016 (512 total; 256..256/round) | 2.705/13.190 (1024 total; 512..512/round) | 2.249/9.693 (512 total; 256..256/round) | 0.100/0.266 (512 total; 256..256/round) |
| `spsc_opaque_persistent` | `exact_waiter_notification_to_continuation` | 1.849/27.486 (4000 total; 2000..2000/round) | 0.201/1.647 (15966 total; 7982..7984/round) | 1.212/23.749 (1998 total; 999..999/round) | 2.931/9.698 (3968 total; 1983..1985/round) | 2.625/25.868 (2000 total; 1000..1000/round) | 0.100/1.448 (2000 total; 1000..1000/round) |
| `spsc_record_persistent` | `exact_waiter_notification_to_continuation` | 1.438/10.454 (4000 total; 2000..2000/round) | 0.225/12.418 (15961 total; 7961..8000/round) | 1.277/39.734 (2000 total; 1000..1000/round) | 3.356/9.021 (3961 total; 1961..2000/round) | 3.246/23.273 (2000 total; 1000..1000/round) | 0.105/0.992 (2000 total; 1000..1000/round) |
| `spsc_record_pool4_control` | `exact_waiter_notification_to_continuation` | 1.327/9.593 (4000 total; 2000..2000/round) | 0.185/1.884 (15942 total; 7964..7978/round) | 0.807/21.119 (1999 total; 999..1000/round) | 3.201/9.598 (3943 total; 1964..1979/round) | 2.214/13.380 (2000 total; 1000..1000/round) | 0.126/1.724 (2000 total; 1000..1000/round) |
| `spsc_scalar_persistent` | `exact_waiter_notification_to_continuation` | 0.446/2.370 (4000 total; 2000..2000/round) | 0.215/2.269 (15932 total; 7958..7974/round) | 1.142/5.881 (1999 total; 999..1000/round) | 3.326/8.476 (3933 total; 1959..1974/round) | 0.621/3.482 (2000 total; 1000..1000/round) | 0.035/0.036 (2000 total; 1000..1000/round) |
| `wait_empty_receiver_endpoint` | `exact_waiter_notification_to_continuation` | unavailable (0 samples) | 0.150/1.413 (8000 total; 4000..4000/round) | 1.808/13.992 (1000 total; 500..500/round) | 2.114/11.221 (2000 total; 1000..1000/round) | 3.506/113.778 (1000 total; 500..500/round) | unavailable (0 samples) |
| `wait_empty_receiver_record` | `exact_waiter_notification_to_continuation` | unavailable (0 samples) | 0.205/1.342 (8000 total; 4000..4000/round) | 2.134/99.351 (1000 total; 500..500/round) | 3.106/9.613 (2000 total; 1000..1000/round) | 3.587/34.315 (1000 total; 500..500/round) | unavailable (0 samples) |
| `wait_full_sender_endpoint` | `exact_waiter_notification_to_continuation` | 4.353/230.581 (1000 total; 500..500/round) | 0.110/1.227 (11256 total; 5527..5729/round) | 1.252/4.237 (1798 total; 843..955/round) | 2.925/9.267 (2458 total; 1184..1274/round) | 2.881/18.244 (1000 total; 500..500/round) | unavailable (0 samples) |
| `wait_full_sender_record` | `exact_waiter_notification_to_continuation` | 3.191/15.013 (1000 total; 500..500/round) | 0.115/1.147 (10763 total; 5300..5463/round) | 1.548/92.472 (1581 total; 742..839/round) | 3.085/9.052 (2182 total; 1058..1124/round) | 3.457/7.710 (1000 total; 500..500/round) | unavailable (0 samples) |

Cells are medians of per-round p50/p99 microseconds, with total sample count and per-round count range. Wake modes list all observed round modes, not only the representative counter round. Encode/decode subintervals cover selected benchmark call brackets, not every worker's codec. Queue intervals include lock acquisition and readiness/closed branches, ending before unlock. Native wake correlates the exact selected waiter with its notification and successful continuation; cancelled/failed/nonunique notifications are unavailable, never attributed to a global last signal. It is not isolated kernel wake latency. Stages overlap across OS threads: do not add medians or subtract independently measured RTTs to manufacture a component time.

### Instrumentation overhead

| Case | Original SDK us/op | Private instrumented us/op | Difference us/op | Ratio |
|---|---:|---:|---:|---:|
| `call_control` | 0.054 | 0.055 | +0.001 | 1.011 |
| `churn_cancel_parked_waiters` | 78.863 | 76.462 | -2.402 | 0.970 |
| `churn_close_parked_receivers` | 25.694 | 38.611 | +12.917 | 1.503 |
| `churn_close_parked_senders` | 38.488 | 50.460 | +11.973 | 1.311 |
| `closure_roundtrip_cap0` | 2.931 | 5.157 | +2.226 | 1.759 |
| `closure_roundtrip_cap1` | 5.980 | 7.945 | +1.964 | 1.328 |
| `closure_roundtrip_cap64` | 147.201 | 210.771 | +63.570 | 1.432 |
| `closure_roundtrip_cap8` | 21.681 | 33.394 | +11.712 | 1.540 |
| `closure_roundtrip_complex_sig` | 6.290 | 11.912 | +5.622 | 1.894 |
| `codec_large64k_decode` | 7.764 | 7.306 | -0.458 | 0.941 |
| `codec_large64k_encode` | 7.674 | 7.280 | -0.394 | 0.949 |
| `codec_large64k_transfer_roundtrip` | 10.290 | 10.413 | +0.122 | 1.012 |
| `codec_scalar_roundtrip` | 0.532 | 0.641 | +0.109 | 1.205 |
| `codec_small_decode` | 1.177 | 1.495 | +0.318 | 1.271 |
| `codec_small_encode` | 0.530 | 0.552 | +0.022 | 1.041 |
| `codec_small_transfer_roundtrip` | 2.610 | 3.967 | +1.357 | 1.520 |
| `codec_wide16_decode` | 2.618 | 3.798 | +1.180 | 1.450 |
| `codec_wide16_encode` | 1.239 | 1.252 | +0.012 | 1.010 |
| `codec_wide16_transfer_roundtrip` | 5.076 | 6.344 | +1.268 | 1.250 |
| `inspect_function` | 2.029 | 3.143 | +1.114 | 1.549 |
| `inspect_record` | 0.165 | 0.249 | +0.084 | 1.506 |
| `join_cleanup_cancelled_task` | 45503.579 | 44397.773 | -1105.806 | 0.976 |
| `join_ordinary` | 6741.122 | 7725.965 | +984.843 | 1.146 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 3.660 | 7.550 | +3.890 | 2.063 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 3.542 | 8.916 | +5.374 | 2.517 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 21.791 | 25.263 | +3.472 | 1.159 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 6.981 | 12.492 | +5.512 | 1.790 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 6.926 | 10.139 | +3.212 | 1.464 |
| `mpmc_record_inflight16_cap16_4p4c` | 3.235 | 7.772 | +4.538 | 2.403 |
| `mpmc_record_inflight16_cap2_4p4c` | 3.400 | 6.558 | +3.157 | 1.929 |
| `mpmc_record_inflight1_cap1_2p2c` | 22.498 | 29.312 | +6.814 | 1.303 |
| `mpmc_record_inflight4_cap1_2p2c` | 6.333 | 11.163 | +4.830 | 1.763 |
| `mpmc_record_inflight4_cap4_2p2c` | 6.853 | 9.364 | +2.511 | 1.366 |
| `overhead_control` | 0.067 | 0.089 | +0.021 | 1.316 |
| `queue_opaque_hook8` | 3.743 | 4.119 | +0.375 | 1.100 |
| `queue_packed_hook8` | 4.608 | 6.965 | +2.357 | 1.512 |
| `queue_plain_bytes8` | 2.697 | 3.687 | +0.989 | 1.367 |
| `queue_real_receiver` | 3.707 | 5.810 | +2.103 | 1.567 |
| `queue_real_sender` | 3.944 | 5.664 | +1.720 | 1.436 |
| `sender_clone` | 0.197 | 0.281 | +0.084 | 1.424 |
| `spsc_endpoint_carried_persistent` | 23.541 | 24.906 | +1.365 | 1.058 |
| `spsc_endpoint_fresh_reply` | 18.960 | 23.978 | +5.018 | 1.265 |
| `spsc_endpoint_pool4_reply` | 19.740 | 19.286 | -0.455 | 0.977 |
| `spsc_large64k_endpoint_pool4` | 46.371 | 30.769 | -15.601 | 0.664 |
| `spsc_large64k_persistent` | 43.289 | 31.875 | -11.414 | 0.736 |
| `spsc_opaque_persistent` | 18.734 | 24.771 | +6.037 | 1.322 |
| `spsc_record_persistent` | 21.278 | 44.503 | +23.225 | 2.092 |
| `spsc_record_pool4_control` | 22.215 | 22.739 | +0.524 | 1.024 |
| `spsc_scalar_persistent` | 8.535 | 12.205 | +3.670 | 1.430 |
| `wait_empty_receiver_endpoint` | 33.279 | 28.720 | -4.559 | 0.863 |
| `wait_empty_receiver_record` | 34.458 | 33.697 | -0.762 | 0.978 |
| `wait_full_sender_endpoint` | 35.959 | 38.252 | +2.293 | 1.064 |
| `wait_full_sender_record` | 32.701 | 39.968 | +7.266 | 1.222 |

### Matched protocol/shape endpoint component contrasts

| Case | Control | Case us/op | Control us/op | Difference us/op |
|---|---|---:|---:|---:|
| `mpmc_endpoint_inflight16_cap16_4p4c` | `mpmc_record_inflight16_cap16_4p4c` | 3.660 | 3.235 | +0.426 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `mpmc_record_inflight16_cap2_4p4c` | 3.542 | 3.400 | +0.142 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `mpmc_record_inflight1_cap1_2p2c` | 21.791 | 22.498 | -0.708 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `mpmc_record_inflight4_cap1_2p2c` | 6.981 | 6.333 | +0.648 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `mpmc_record_inflight4_cap4_2p2c` | 6.926 | 6.853 | +0.073 |
| `queue_real_receiver` | `queue_plain_bytes8` | 3.707 | 2.697 | +1.009 |
| `queue_real_sender` | `queue_plain_bytes8` | 3.944 | 2.697 | +1.247 |
| `spsc_endpoint_carried_persistent` | `spsc_record_persistent` | 23.541 | 21.278 | +2.263 |
| `spsc_endpoint_pool4_reply` | `spsc_record_pool4_control` | 19.740 | 22.215 | -2.475 |
| `wait_empty_receiver_endpoint` | `wait_empty_receiver_record` | 33.279 | 34.458 | -1.179 |
| `wait_full_sender_endpoint` | `wait_full_sender_record` | 35.959 | 32.701 | +3.258 |

### Payload-policy controls (not isolated endpoint costs)

| Case | Control | Case us/op | Control us/op | Difference us/op |
|---|---|---:|---:|---:|
| `queue_opaque_hook8` | `queue_plain_bytes8` | 3.743 | 2.697 | +1.046 |
| `queue_packed_hook8` | `queue_plain_bytes8` | 4.608 | 2.697 | +1.911 |
| `spsc_opaque_persistent` | `spsc_record_persistent` | 18.734 | 21.278 | -2.544 |

### Application-protocol contrasts (not matched endpoint components)

| Case | Control | Case us/op | Control us/op | Difference us/op |
|---|---|---:|---:|---:|
| `spsc_endpoint_fresh_reply` | `spsc_endpoint_pool4_reply` | 18.960 | 19.740 | -0.780 |
| `spsc_large64k_endpoint_pool4` | `spsc_large64k_persistent` | 46.371 | 43.289 | +3.082 |

Matched endpoint contrasts retain common field count, capacity, OS producer/consumer counts, in-flight budget and validation/protocol; payload representation, hooks, wrapper allocation and ownership differ together. They do not isolate only retain/release cost. Fresh/pool-four and large pool-four/persistent comparisons change application protocol and are kept in the separate protocol table.

