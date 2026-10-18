# Paired baseline/candidate cross-thread evidence

Raw evidence: `/tmp/titan-issue252-rtt-final-cpp2-v1/paired-wake/PAIRED-RAW.json` (SHA-256 `d1a65e07d077901a67c49c60e832de144b5d54f1cd2ee88a3724a95728c3ad40`).

## Operator quiescence evidence

Recorded at 2026-10-18T22:26:50.008975+00:00 on Linux 7.2.8-ogc5.1.fc44.x86_64 x86_64 before starting the matched 2-batch (3 uninstrumented repeats, 2 instrumented repeats, seed=252) paired campaign across all 53 catalog cases.
- All local Linux GCC/Clang-ASAN builds and test suites are finished (0 active background jobs).
- Both Windows NTFS VM and local macOS VM validation runs are finished and idle.
- Host /proc/loadavg before campaign start: 22.48 14.39 9.28 3/6024 3396924.
- Baseline lane (/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource) and candidate lane (/tmp/titan-issue252-rtt-final-cpp2-v1/wake) share identical compiler/runtime/Lua/native archives (CPP2 common compiler patchset; post-CPP2 v3 borrowed-pointer spill fix verified 100% identical across all 121,249 lines of bench.c and all 26 stdlib modules except cosmetic 'volatile int' vs 'int volatile' on one local in os.c).


Note SHA-256: `acd0cda2e94ef8ca5578b2b5c6a76e9fb14f2da6c84a3419b7c0665930aa7114`.

## Actual within-pair differences

| Case | Pairs | Median candidate - baseline us/op | Difference range | Median within-pair ratio | Independent batch median differences |
|---|---:|---:|---:|---:|---|
| `call_control` | 6 | +0.002 | -0.004..+0.027 | 1.033 | 0: +0.002, 1: +0.001 |
| `churn_cancel_parked_waiters` | 6 | +0.069 | -19.062..+13.092 | 1.002 | 0: -3.367, 1: +3.504 |
| `churn_close_parked_receivers` | 6 | +2.399 | -6.449..+6.383 | 1.096 | 0: +3.311, 1: -1.399 |
| `churn_close_parked_senders` | 6 | +1.595 | -4.846..+5.942 | 1.040 | 0: +2.170, 1: +1.020 |
| `closure_roundtrip_cap0` | 6 | +0.018 | -0.914..+1.182 | 1.006 | 0: -0.106, 1: +0.684 |
| `closure_roundtrip_cap1` | 6 | -0.761 | -3.455..-0.142 | 0.888 | 0: -3.403, 1: -0.338 |
| `closure_roundtrip_cap64` | 6 | +0.358 | -6.165..+14.774 | 1.002 | 0: +2.573, 1: +0.089 |
| `closure_roundtrip_cap8` | 6 | +0.728 | -11.037..+19.819 | 1.028 | 0: +3.065, 1: +0.638 |
| `closure_roundtrip_complex_sig` | 6 | +0.199 | -3.303..+0.452 | 1.029 | 0: -0.903, 1: +0.428 |
| `codec_large64k_decode` | 6 | +0.011 | -5.352..+0.379 | 1.000 | 0: -3.857, 1: +0.332 |
| `codec_large64k_encode` | 6 | -0.225 | -8.124..+6.920 | 0.971 | 0: +0.228, 1: -0.750 |
| `codec_large64k_transfer_roundtrip` | 6 | +1.045 | +0.013..+3.349 | 1.111 | 0: +2.881, 1: +0.175 |
| `codec_scalar_roundtrip` | 6 | +0.004 | -0.240..+0.211 | 1.008 | 0: -0.007, 1: +0.016 |
| `codec_small_decode` | 6 | +0.019 | -0.022..+0.275 | 1.019 | 0: -0.008, 1: +0.046 |
| `codec_small_encode` | 6 | -0.004 | -0.260..+0.113 | 0.993 | 0: -0.003, 1: -0.005 |
| `codec_small_transfer_roundtrip` | 6 | +0.391 | -1.875..+1.070 | 1.163 | 0: +0.293, 1: +0.489 |
| `codec_wide16_decode` | 6 | -0.076 | -1.835..+1.584 | 0.971 | 0: -0.117, 1: -0.035 |
| `codec_wide16_encode` | 6 | -0.123 | -0.399..+0.322 | 0.903 | 0: -0.215, 1: -0.032 |
| `codec_wide16_transfer_roundtrip` | 6 | +0.044 | -3.415..+1.970 | 1.009 | 0: -0.054, 1: +0.142 |
| `inspect_function` | 6 | +0.057 | -0.492..+1.198 | 1.030 | 0: +0.877, 1: -0.423 |
| `inspect_record` | 6 | +0.029 | -0.079..+0.082 | 1.179 | 0: +0.055, 1: +0.003 |
| `join_cleanup_cancelled_task` | 6 | +104.153 | -6085.579..+6306.886 | 1.003 | 0: +2141.976, 1: -5504.769 |
| `join_ordinary` | 6 | -70.354 | -808.088..+419.614 | 0.990 | 0: -552.899, 1: +134.358 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 6 | +0.003 | -0.301..+1.298 | 1.000 | 0: +0.536, 1: -0.033 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 6 | +0.346 | +0.003..+2.806 | 1.101 | 0: +0.279, 1: +0.414 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 6 | +1.984 | -4.874..+2.569 | 1.105 | 0: +0.573, 1: +2.410 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 6 | +0.164 | -0.026..+1.837 | 1.027 | 0: +0.738, 1: +0.130 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 6 | +0.125 | -0.260..+0.956 | 1.019 | 0: +0.587, 1: -0.247 |
| `mpmc_record_inflight16_cap16_4p4c` | 6 | +0.704 | -0.567..+2.389 | 1.187 | 0: +0.929, 1: -0.290 |
| `mpmc_record_inflight16_cap2_4p4c` | 6 | +1.453 | +0.488..+3.052 | 1.418 | 0: +0.699, 1: +1.813 |
| `mpmc_record_inflight1_cap1_2p2c` | 6 | +0.136 | -2.099..+1.245 | 1.008 | 0: -1.613, 1: +0.447 |
| `mpmc_record_inflight4_cap1_2p2c` | 6 | -0.740 | -1.393..-0.027 | 0.892 | 0: -0.380, 1: -0.873 |
| `mpmc_record_inflight4_cap4_2p2c` | 6 | -0.130 | -1.842..+0.592 | 0.978 | 0: +0.042, 1: -0.302 |
| `overhead_control` | 6 | -0.003 | -0.030..+0.033 | 0.960 | 0: -0.001, 1: -0.005 |
| `queue_opaque_hook8` | 6 | +0.110 | -2.201..+2.434 | 1.029 | 0: +0.023, 1: +0.196 |
| `queue_packed_hook8` | 6 | +1.515 | -0.195..+5.101 | 1.258 | 0: +2.384, 1: +0.646 |
| `queue_plain_bytes8` | 6 | +0.186 | -1.692..+1.229 | 1.069 | 0: +0.170, 1: +0.202 |
| `queue_real_receiver` | 6 | +0.388 | -0.240..+1.585 | 1.102 | 0: +0.677, 1: +0.099 |
| `queue_real_sender` | 6 | -0.174 | -0.664..+0.860 | 0.959 | 0: -0.508, 1: +0.046 |
| `sender_clone` | 6 | +0.004 | -0.094..+0.340 | 1.022 | 0: -0.003, 1: +0.098 |
| `spsc_endpoint_carried_persistent` | 6 | +1.400 | +0.072..+6.700 | 1.066 | 0: +2.206, 1: +0.260 |
| `spsc_endpoint_fresh_reply` | 6 | -0.278 | -8.744..+1.757 | 0.984 | 0: +0.884, 1: -4.002 |
| `spsc_endpoint_pool4_reply` | 6 | -0.765 | -6.291..+0.990 | 0.967 | 0: +0.008, 1: -1.537 |
| `spsc_large64k_endpoint_pool4` | 6 | +4.026 | -9.154..+13.978 | 1.107 | 0: +5.607, 1: -6.443 |
| `spsc_large64k_persistent` | 6 | -2.056 | -10.435..+8.402 | 0.946 | 0: -9.222, 1: -1.612 |
| `spsc_opaque_persistent` | 6 | -1.408 | -4.686..+1.505 | 0.934 | 0: +0.032, 1: -1.595 |
| `spsc_record_persistent` | 6 | -4.042 | -5.512..+2.787 | 0.779 | 0: -3.602, 1: -4.569 |
| `spsc_record_pool4_control` | 6 | -0.938 | -4.520..+0.712 | 0.933 | 0: -2.098, 1: +0.222 |
| `spsc_scalar_persistent` | 6 | +0.128 | -0.616..+3.180 | 1.017 | 0: +0.233, 1: +0.022 |
| `wait_empty_receiver_endpoint` | 6 | -0.587 | -12.221..+10.622 | 0.980 | 0: +3.599, 1: -4.774 |
| `wait_empty_receiver_record` | 6 | +0.026 | -6.307..+11.191 | 0.998 | 0: +3.534, 1: -5.840 |
| `wait_full_sender_endpoint` | 6 | +1.536 | -3.713..+5.495 | 1.043 | 0: +0.225, 1: +2.014 |
| `wait_full_sender_record` | 6 | +4.168 | -4.356..+7.830 | 1.124 | 0: +4.913, 1: +1.463 |

These are statistics of actual alternating-order matched observations, not differences of marginal medians. Raw per-pair observations/order and lane marginal summaries are retained. Ranges and batch differences expose observed variation; this renderer does not assert statistical significance or attribute a resource-ownership checkpoint change to a later final corrected wake/join cutover.

## Actual within-pair finite MPMC fairness differences

Candidate minus baseline microseconds; these compare each paired run's worst-lane statistic, not a difference of pooled request percentiles. Zero contributing samples means unavailable.

| Case | Metric | Pairs | Median delta [range] us | Independent batch median deltas us |
|---|---|---:|---:|---|
| `mpmc_endpoint_inflight16_cap16_4p4c` | `first_start_spread_ns` | 6 | +33.032 [-47.238..+83.477] | 0: 66.203, 1: 27.471 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | `last_completion_skew_ns` | 6 | +153.567 [-330.829..+1064.800] | 0: 362.869, 1: -13.936 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | `max_intercompletion_gap_ns` | 6 | +21.961 [-48.912..+486.170] | 0: 3.507, 1: 40.415 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | `worst_lane_end_to_end_p99_ns` | 6 | +10.575 [-49.342..+475.468] | 0: 3.597, 1: 17.553 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | `worst_lane_permit_wait_p99_ns` | 6 | +0.602 [-1.152..+22.052] | 0: 0.131, 1: 0.692 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `first_start_spread_ns` | 6 | -11.477 [-43.081..+234.369] | 0: -17.533, 1: -5.421 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `last_completion_skew_ns` | 6 | +393.827 [-5.791..+2840.710] | 0: 292.567, 1: 495.086 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `max_intercompletion_gap_ns` | 6 | +101.816 [-139.681..+312.594] | 0: 95.288, 1: 108.343 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `worst_lane_end_to_end_p99_ns` | 6 | +78.231 [-139.911..+256.920] | 0: 63.830, 1: 92.633 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `worst_lane_permit_wait_p99_ns` | 6 | -0.222 [-10.750..+6.681] | 0: 3.196, 1: -3.727 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `first_start_spread_ns` | 6 | -1.192 [-13.445..+18.725] | 0: -3.797, 1: -1.101 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `last_completion_skew_ns` | 6 | +333.139 [-7801.833..+1714.365] | 0: -319.807, 1: 830.392 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `max_intercompletion_gap_ns` | 6 | +154.124 [-15.670..+9648.234] | 0: 9015.180, 1: -5.660 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `worst_lane_end_to_end_p99_ns` | 6 | +8.951 [-47.098..+16.921] | 0: 3.517, 1: 11.703 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `worst_lane_permit_wait_p99_ns` | 6 | -0.226 [-1.292..+1.282] | 0: -0.682, 1: -0.010 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `first_start_spread_ns` | 6 | +0.922 [-42.699..+57.227] | 0: -3.616, 1: 7.283 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `last_completion_skew_ns` | 6 | +117.465 [-259.947..+2901.362] | 0: 573.061, 1: -50.103 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `max_intercompletion_gap_ns` | 6 | -28.038 [-97.071..+87.905] | 0: -9.888, 1: -46.397 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `worst_lane_end_to_end_p99_ns` | 6 | +3.292 [-30.016..+69.981] | 0: 3.256, 1: 3.327 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `worst_lane_permit_wait_p99_ns` | 6 | +0.286 [-0.832..+0.892] | 0: 0.371, 1: 0.201 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `first_start_spread_ns` | 6 | +7.023 [-34.465..+35.837] | 0: 21.540, 1: -7.494 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `last_completion_skew_ns` | 6 | -57.949 [-766.452..+1045.033] | 0: -16.501, 1: -99.397 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `max_intercompletion_gap_ns` | 6 | -19.046 [-37.750..+44.402] | 0: -25.648, 1: -12.443 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `worst_lane_end_to_end_p99_ns` | 6 | +8.490 [-38.402..+52.748] | 0: 13.685, 1: -0.682 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `worst_lane_permit_wait_p99_ns` | 6 | -0.416 [-1.874..+0.220] | 0: -0.411, 1: -1.333 |
| `mpmc_record_inflight16_cap16_4p4c` | `first_start_spread_ns` | 6 | -34.098 [-233.807..+82.574] | 0: -58.108, 1: -10.088 |
| `mpmc_record_inflight16_cap16_4p4c` | `last_completion_skew_ns` | 6 | +212.893 [-477.402..+1691.922] | 0: 408.354, 1: -468.024 |
| `mpmc_record_inflight16_cap16_4p4c` | `max_intercompletion_gap_ns` | 6 | +66.870 [-595.152..+350.295] | 0: 114.454, 1: 19.286 |
| `mpmc_record_inflight16_cap16_4p4c` | `worst_lane_end_to_end_p99_ns` | 6 | +90.103 [-31.539..+374.020] | 0: 13.044, 1: 167.163 |
| `mpmc_record_inflight16_cap16_4p4c` | `worst_lane_permit_wait_p99_ns` | 6 | +0.626 [-20.599..+12.764] | 0: 6.081, 1: 0.381 |
| `mpmc_record_inflight16_cap2_4p4c` | `first_start_spread_ns` | 6 | -19.216 [-64.590..+107.481] | 0: -57.808, 1: 7.294 |
| `mpmc_record_inflight16_cap2_4p4c` | `last_completion_skew_ns` | 6 | +1168.184 [+546.301..+2558.903] | 0: 736.848, 1: 1794.003 |
| `mpmc_record_inflight16_cap2_4p4c` | `max_intercompletion_gap_ns` | 6 | +260.613 [+60.684..+657.849] | 0: 144.490, 1: 347.089 |
| `mpmc_record_inflight16_cap2_4p4c` | `worst_lane_end_to_end_p99_ns` | 6 | +104.275 [-157.755..+658.650] | 0: 94.968, 1: 216.075 |
| `mpmc_record_inflight16_cap2_4p4c` | `worst_lane_permit_wait_p99_ns` | 6 | +4.003 [+0.640..+29.485] | 0: 5.410, 1: 2.985 |
| `mpmc_record_inflight1_cap1_2p2c` | `first_start_spread_ns` | 6 | +0.546 [-7.765..+3.397] | 0: -7.134, 1: 0.702 |
| `mpmc_record_inflight1_cap1_2p2c` | `last_completion_skew_ns` | 6 | -843.843 [-2744.279..+1512.868] | 0: -910.573, 1: -777.113 |
| `mpmc_record_inflight1_cap1_2p2c` | `max_intercompletion_gap_ns` | 6 | -432.853 [-8401.904..+8440.006] | 0: -591.535, 1: -274.172 |
| `mpmc_record_inflight1_cap1_2p2c` | `worst_lane_end_to_end_p99_ns` | 6 | +2.099 [-23.143..+32.711] | 0: -2.716, 1: 6.913 |
| `mpmc_record_inflight1_cap1_2p2c` | `worst_lane_permit_wait_p99_ns` | 6 | -0.420 [-2.274..+0.631] | 0: -1.252, 1: -0.060 |
| `mpmc_record_inflight4_cap1_2p2c` | `first_start_spread_ns` | 6 | +7.028 [-5.089..+52.969] | 0: 8.275, 1: 5.781 |
| `mpmc_record_inflight4_cap1_2p2c` | `last_completion_skew_ns` | 6 | -493.822 [-1481.129..-214.341] | 0: -518.900, 1: -468.745 |
| `mpmc_record_inflight4_cap1_2p2c` | `max_intercompletion_gap_ns` | 6 | -41.303 [-97.231..-2.244] | 0: -57.337, 1: -25.268 |
| `mpmc_record_inflight4_cap1_2p2c` | `worst_lane_end_to_end_p99_ns` | 6 | -18.951 [-78.256..+62.326] | 0: -28.223, 1: -9.678 |
| `mpmc_record_inflight4_cap1_2p2c` | `worst_lane_permit_wait_p99_ns` | 6 | -0.466 [-2.385..+0.400] | 0: -0.321, 1: -0.611 |
| `mpmc_record_inflight4_cap4_2p2c` | `first_start_spread_ns` | 6 | -8.791 [-66.444..+37.821] | 0: -14.648, 1: -2.935 |
| `mpmc_record_inflight4_cap4_2p2c` | `last_completion_skew_ns` | 6 | -192.365 [-1248.633..+397.663] | 0: -84.238, 1: -300.492 |
| `mpmc_record_inflight4_cap4_2p2c` | `max_intercompletion_gap_ns` | 6 | -16.546 [-496.979..+217.826] | 0: 19.377, 1: -51.046 |
| `mpmc_record_inflight4_cap4_2p2c` | `worst_lane_end_to_end_p99_ns` | 6 | -5.901 [-41.658..+29.525] | 0: -5.260, 1: -11.761 |
| `mpmc_record_inflight4_cap4_2p2c` | `worst_lane_permit_wait_p99_ns` | 6 | -0.706 [-1.874..+2.374] | 0: -0.831, 1: -0.581 |

Retain actual per-pair deltas/order, per-lane progress distributions and consumer counts in raw evidence; no no-regression or statistical-significance claim is generated here.

### baseline provenance

| Input | Recorded evidence |
|---|---|
| ABI / SDK / language-server API | `2 / 0.6 / 1 (compile guard)` |
| Claimed source revision (builder-attested, not inferred) | `resource-prewake-cpp2-a40babf3ad2b33cf (content-attested snapshot label, NOT a Git commit)` |
| SDK profile | `production` |
| Complete generated-C flags (including optimization / LTO / debug) | `--std=c99 -O3 -Wall -Wno-unused-but-set-variable -Wno-unused-function -fPIC -g1 -flto=auto -ffat-lto-objects -fno-strict-aliasing` |
| Generated-C source-line directives | `True` |
| Full SDK content manifest SHA-256 | `49c792e165dc84545ba1a865e60c7dfc9dafbaaaff1b60223b159490ae4e21c0` |
| Source hash-map SHA-256 | `e89472ca428687be3d28f813ce493da1e5ced2d4846015cea63106570265f749` |
| Source probe recipe SHA-256 | `b30c3955aacd540c889e4d8abd8c90a43120fad4a96097937e479a91715ff9ca` |
| Audited native wait contract | `legacy_register_before_yield` |
| Native-wake successful continuation endpoint | `native-await return including helper cleanup` |
| Original builder receipt SHA-256 | `a40babf3ad2b33cf5a614b47df3426e6fd9296516298137426f45276d0d5dbd1` |
| Preserved native payload archive SHA-256 | `72e5da2181c176c64eb38d6573416bb2657b3f7eebda6420fb8c45e64c12c628` |
| Generated consumer SHA-256 | `5a9e13bbed374169451611b064461c6312e69724328fa8f968140beacbe2a00b` |
| Raw codec calling contract | `native_consuming_slot` |

<details><summary>Exact provider/source/tool/link evidence</summary>

```json
{
  "executable_sha256": {
    "instrumented": "1c0d85b48ac53ab341115ce30226bc99e73eb71fa1835517fe2ec0abbfaac67a",
    "uninstrumented": "165707faa63a973eaf175c0417dc007e65456312d9c7b42e999f727166d5a7d1"
  },
  "link_evidence": {
    "instrumented": "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/logs/1792296967035676047-link-dependencies-instrumented.json",
    "uninstrumented": "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/logs/1792296967030366073-link-dependencies-uninstrumented.json"
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=bench",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/instrumented/bench.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/instrumented/bench.o.compile.tmp.lua_Ht8nEP"
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/instrumented/.titan-temporary.tmp.lua_BCvXjj.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/instrumented/.titan-temporary.tmp.lua_BCvXjj.o"
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/instrumented/bench__entrypoint.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/instrumented/bench__entrypoint.o"
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=bench",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/uninstrumented/bench.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/uninstrumented/bench.o.compile.tmp.lua_lePu90"
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/uninstrumented/.titan-temporary.tmp.lua_lwyIGz.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/uninstrumented/.titan-temporary.tmp.lua_lwyIGz.o"
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/uninstrumented/bench__entrypoint.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/uninstrumented/bench__entrypoint.o"
      ]
    ],
    "private_provider": [
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.async",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/async.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/async.o.compile.tmp.lua_N9SSgc"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.coroutine",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/coroutine.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/coroutine.o.compile.tmp.lua_jEmrZe"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.fs",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/fs.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/fs.o.compile.tmp.lua_DOg2HA"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.gc",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/gc.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/gc.o.compile.tmp.lua_nMqZ9I"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.http",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/http/http.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/http/http.o.compile.tmp.lua_pRt74K"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.io",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/io.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/io.o.compile.tmp.lua_htCDrm"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.iteration",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/iteration.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/iteration.o.compile.tmp.lua_kNj5hN"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.json",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/json/json.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/json/json.o.compile.tmp.lua_zXDyhZ"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.lua",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/lua/lua.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/lua/lua.o.compile.tmp.lua_IrOFzM"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.math",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/math.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/math.o.compile.tmp.lua_olXtcB"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.net",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/net.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/net.o.compile.tmp.lua_Vmd5f5"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.os",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/os.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/os.o.compile.tmp.lua_0tj5gw"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.path",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/path.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/path.o.compile.tmp.lua_aWYcxo"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.peg",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/peg/peg.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/peg/peg.o.compile.tmp.lua_I3AQIg"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.protobuf",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/protobuf/protobuf.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/protobuf/protobuf.o.compile.tmp.lua_HeYFAE"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.reflect",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/reflect.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/reflect.o.compile.tmp.lua_gtcqyv"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.sqlite3",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/sqlite3/sqlite3.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/sqlite3/sqlite3.o.compile.tmp.lua_Zm75bV"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.ssl",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/ssl.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/ssl.o.compile.tmp.lua_cyiPxy"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.string",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/string/string.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/string/string.o.compile.tmp.lua_OUQGFm"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.test",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/test.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/test.o.compile.tmp.lua_JA8oVx"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.thread",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/thread/thread.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/thread/thread.o.compile.tmp.lua_c4uweH"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.timer",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/timer.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/timer.o.compile.tmp.lua_LxtIVi"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.transfer",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/transfer.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/transfer.o.compile.tmp.lua_xTGc7a"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.url",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/url.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/url.o.compile.tmp.lua_2ZdsAb"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.uv",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/uv/uv.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/uv/uv.o.compile.tmp.lua_FNMZH4"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work",
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
        "/tmp/titan-issue252-prewake-cpp2/sdk/include",
        "-I",
        "/tmp/titan-issue252-prewake-cpp2/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.websocket",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/websocket/websocket.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan/websocket/websocket.o.compile.tmp.lua_D6riE8"
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
    "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan.a": "be10652a64eb0e5a4529e31004da2a832573747d68acb8864c3f3247e5631504",
    "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/work/provider/titan.so": "b61480d621fa894c53acaa17613d7281d006a12d01875afccca9fda6181ad473"
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
    "titan/thread/thread.titan": "664d34842f71fb2efef2963efcb419a376b253976cb88d8128cdda122f54feb2",
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
    "attestation": "/tmp/titan-issue252-prewake-cpp2/BUILD-ATTESTATION.json",
    "attestation_sha256": "9e9346addf7ab22333717d86a752600cd6f2fa33038309f15e54f3188493b622",
    "checkpoint": "Resource/pre-wake with common two compiler fixes, full26-root official rebuild. Legacy detached/per-wait wake and proxy-early-terminal contracts retained; Thread cancellation transport remains unchanged. Not final correctness/performance approval. Later candidate contains actual async/native-retirement and cancellation-transport corrections, not a pure wake-only intervention.",
    "commands": "/tmp/titan-issue252-prewake-cpp2/BUILD-COMMANDS.json",
    "commands_sha256": "86d6b07a17287d7db1e795ff775f5639c1633091a9e13d64344b0789572243a1",
    "compiler_patchset": {
      "titan-compiler/coder/module.lua": {
        "after": "c324ee5d2ab0862df7ac3eb5acf90a37da9097cf9764758a1e5bf4b03926201f",
        "before": "65e33d33a0e85b04042725d84b097880c6b16ed5beddabf1539bc72d330d361b"
      },
      "titan-compiler/coder/statements.lua": {
        "after": "d7d735e742116798a696e995455e8392055ea0d4b117fe4c4d2c435cde88b4e4",
        "before": "bd51a4cf5f1039d97fb5d1f6b9b980a871904501578faf9113b8b1d7dfea9a60"
      }
    },
    "input_provenance": "/tmp/titan-issue252-prewake-cpp2/INPUT-PROVENANCE.json",
    "input_provenance_sha256": "b642ac80a78b8a25f532b770274fac499a6dffc5abf8e6352a21acf4d62a0ff9",
    "installed_compiler_patch_sha256": {
      "share/lua/5.5/titan-compiler/coder/module.lua": "c324ee5d2ab0862df7ac3eb5acf90a37da9097cf9764758a1e5bf4b03926201f",
      "share/lua/5.5/titan-compiler/coder/statements.lua": "d7d735e742116798a696e995455e8392055ea0d4b117fe4c4d2c435cde88b4e4"
    },
    "native_archive_reuse_sha256": {
      "lib/libbacktrace.a": "e134dff116b6441f9171bb6182897a1b9ddd87caf644b3d3b6a125ec4920fe01",
      "lib/liblua.a": "7decdb6e81469ca27cd6f8bc9f2eef0830c77dd6c5bc15cefc8a89fe1258f721",
      "lib/luarocks/rocks-5.5/titan/0.6.0-1/titan-sdk/lib/libbacktrace.a": "e134dff116b6441f9171bb6182897a1b9ddd87caf644b3d3b6a125ec4920fe01",
      "lib/luarocks/rocks-5.5/titan/0.6.0-1/titan-sdk/lib/liblua.a": "7decdb6e81469ca27cd6f8bc9f2eef0830c77dd6c5bc15cefc8a89fe1258f721",
      "lib/luarocks/rocks-5.5/titan/0.6.0-1/titan-sdk/lib/titan/0.6/libtitan.a": "f8123ef431b4a854bc1473d1f35296a39a3159d85a25303e60c6dbb7d5f8152f",
      "lib/titan/0.6/libtitan.a": "f8123ef431b4a854bc1473d1f35296a39a3159d85a25303e60c6dbb7d5f8152f"
    },
    "source_after": "/tmp/titan-issue252-prewake-cpp2/SOURCE-AFTER.json",
    "source_before": "/tmp/titan-issue252-prewake-cpp2/SOURCE-BEFORE.json"
  },
  "provider_files": {
    "/tmp/titan-issue252-prewake-cpp2/sdk/bin/lua": "4ff90fc0bccfffb89db1198b3807b2731b1f95686967a42d13f9b78f6f5561ee",
    "/tmp/titan-issue252-prewake-cpp2/sdk/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc": "567bdf8984e6631a199b3feae238483a632af62aa9239a5864a93fb074ce03b4",
    "/tmp/titan-issue252-prewake-cpp2/sdk/lib/titan/0.6/libtitan.a": "f8123ef431b4a854bc1473d1f35296a39a3159d85a25303e60c6dbb7d5f8152f",
    "/tmp/titan-issue252-prewake-cpp2/sdk/lib/titan/0.6/titan.a": "ccb6892101bae22fa954c240b6cd060ad7900cebbba826904e02d4bbb8e83106",
    "/tmp/titan-issue252-prewake-cpp2/sdk/lib/titan/0.6/titan.so": "0031fe44035b0a58a4db918c4b68ff6a3d27f599290043ee8e1089c4a317e211"
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
    "private_provider_compile_receipt": "/tmp/titan-issue252-rtt-final-cpp2-v1/final-resource/logs/1792296387472333204-compile-private-full-provider.json",
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

## baseline marginal results

Catalog: 53 cases; this report contains 53 measured cases.

Uninstrumented timing uses the original immutable SDK. Instrumented timing uses a private full-provider rebuild with source-scoped semantic probes and the original native payload. The difference below is instrumentation overhead, not a production speedup.

### Uninstrumented end-to-end timing

| Case | Protocol | Rounds / samples | us/op median [range] | RTT p50/p95/p99 us | ops/s | Cold first use us | Residual GC us/op | Retire us |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `call_control` | `same_state` | 6 / 60000 | 0.054 [0.054..0.059] | 0.030/0.030/0.031 | 18567644.0 | 9711.4 | 0.040 | 0.5 |
| `churn_cancel_parked_waiters` | `cancel_churn` | 6 / 3000 | 81.399 [74.303..105.276] | 55.814/156.853/664.226 | 12286.6 | 9368.2 | 4.935 | 62.4 |
| `churn_close_parked_receivers` | `close_churn` | 6 / 3000 | 27.849 [23.322..33.758] | 17.142/43.721/277.954 | 35952.5 | 8809.4 | 6.822 | 56.8 |
| `churn_close_parked_senders` | `close_churn` | 6 / 3000 | 39.741 [38.315..51.687] | 28.152/69.850/347.440 | 25163.0 | 9508.9 | 10.241 | 62.4 |
| `closure_roundtrip_cap0` | `same_state` | 6 / 6000 | 3.118 [2.961..3.844] | 2.925/4.193/7.469 | 320904.0 | 7804.7 | 1.402 | 1.8 |
| `closure_roundtrip_cap1` | `same_state` | 6 / 6000 | 6.734 [5.646..9.113] | 4.715/10.129/67.025 | 149785.1 | 8639.0 | 1.218 | 2.1 |
| `closure_roundtrip_cap64` | `same_state` | 6 / 6000 | 152.163 [146.059..170.379] | 85.685/614.293/864.782 | 6571.9 | 8818.6 | 0.775 | 2.8 |
| `closure_roundtrip_cap8` | `same_state` | 6 / 6000 | 25.950 [23.538..34.562] | 13.215/112.430/198.135 | 38554.7 | 9410.1 | 0.652 | 2.7 |
| `closure_roundtrip_complex_sig` | `same_state` | 6 / 6000 | 6.517 [5.805..9.875] | 4.649/13.400/53.615 | 153815.9 | 9217.8 | 1.244 | 2.4 |
| `codec_large64k_decode` | `same_state` | 6 / 1536 | 7.826 [7.145..12.381] | 2.881/20.378/70.431 | 127870.6 | 9080.1 | 2.664 | 1.7 |
| `codec_large64k_encode` | `same_state` | 6 / 1536 | 8.020 [7.546..15.560] | 3.031/19.556/76.493 | 124767.9 | 8156.4 | 2.630 | 1.6 |
| `codec_large64k_transfer_roundtrip` | `same_state` | 6 / 1536 | 9.967 [9.156..17.509] | 6.502/21.926/68.082 | 100339.1 | 7680.9 | 2.885 | 1.6 |
| `codec_scalar_roundtrip` | `same_state` | 6 / 30000 | 0.560 [0.494..0.726] | 0.396/1.142/1.704 | 1793442.6 | 9090.5 | 0.455 | 1.4 |
| `codec_small_decode` | `same_state` | 6 / 30000 | 1.046 [0.990..1.266] | 0.621/1.388/4.143 | 956422.9 | 8556.2 | 0.188 | 2.2 |
| `codec_small_encode` | `same_state` | 6 / 30000 | 0.677 [0.473..0.742] | 0.541/1.343/1.643 | 1476353.6 | 9923.6 | 0.354 | 2.4 |
| `codec_small_transfer_roundtrip` | `same_state` | 6 / 30000 | 2.600 [2.347..4.377] | 1.733/3.115/15.465 | 385167.3 | 9422.8 | 0.347 | 2.4 |
| `codec_wide16_decode` | `same_state` | 6 / 30000 | 2.842 [2.504..4.306] | 1.663/3.296/31.869 | 354143.7 | 8254.7 | 0.182 | 2.4 |
| `codec_wide16_encode` | `same_state` | 6 / 30000 | 1.328 [1.068..1.520] | 1.373/1.744/2.564 | 753020.8 | 9310.0 | 0.276 | 1.7 |
| `codec_wide16_transfer_roundtrip` | `same_state` | 6 / 30000 | 4.952 [4.706..8.393] | 3.381/9.387/50.965 | 202217.1 | 9196.8 | 0.191 | 2.9 |
| `inspect_function` | `same_state` | 6 / 6000 | 2.183 [1.960..2.639] | 1.964/2.976/5.184 | 458481.3 | 9336.7 | 1.048 | 1.2 |
| `inspect_record` | `same_state` | 6 / 30000 | 0.165 [0.149..0.238] | 0.111/0.201/0.706 | 6068554.2 | 8575.8 | 0.115 | 1.1 |
| `join_cleanup_cancelled_task` | `cleanup_join` | 6 / 600 | 44861.278 [38173.581..48140.557] | 48000.946/51003.338/51755.178 | 22.3 | 8927.1 | 52.353 | 64.8 |
| `join_ordinary` | `ordinary_join` | 6 / 600 | 7034.756 [6987.456..7752.093] | 7026.264/8029.263/8624.882 | 142.2 | 8711.6 | 36.572 | 70.6 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | `pool_16_reply` | 6 / 6000 | 3.532 [2.973..3.984] | 41.007/80.550/134.160 | 283090.9 | 7957.6 | 1.963 | 7064.5 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `pool_16_reply` | 6 / 6000 | 3.603 [3.375..3.965] | 40.456/85.065/182.266 | 277558.8 | 9132.0 | 1.722 | 6740.3 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `pool_four_reply` | 6 / 6000 | 18.860 [17.668..24.749] | 15.920/22.466/42.804 | 53035.8 | 8897.5 | 1.815 | 5356.6 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `pool_four_reply` | 6 / 6000 | 6.240 [5.682..6.539] | 19.963/37.410/68.222 | 160280.1 | 9231.9 | 1.412 | 5895.9 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `pool_four_reply` | 6 / 6000 | 6.284 [5.671..6.621] | 20.438/31.123/51.281 | 159294.5 | 9213.0 | 1.245 | 5517.4 |
| `mpmc_record_inflight16_cap16_4p4c` | `pool_16_reply` | 6 / 6000 | 3.957 [2.843..4.202] | 41.252/90.394/196.798 | 252812.9 | 10117.0 | 2.137 | 5951.4 |
| `mpmc_record_inflight16_cap2_4p4c` | `pool_16_reply` | 6 / 6000 | 3.515 [2.869..3.785] | 36.709/98.825/204.091 | 284983.5 | 9526.3 | 1.763 | 5580.6 |
| `mpmc_record_inflight1_cap1_2p2c` | `pool_four_reply` | 6 / 6000 | 18.451 [16.550..19.428] | 14.983/22.678/43.341 | 54317.2 | 8711.5 | 1.763 | 4399.6 |
| `mpmc_record_inflight4_cap1_2p2c` | `pool_four_reply` | 6 / 6000 | 6.744 [5.770..7.075] | 20.914/43.120/63.218 | 148305.8 | 9539.3 | 1.509 | 5209.7 |
| `mpmc_record_inflight4_cap4_2p2c` | `pool_four_reply` | 6 / 6000 | 5.734 [5.315..8.338] | 18.961/32.075/55.043 | 174384.2 | 9192.6 | 1.215 | 4992.7 |
| `overhead_control` | `same_state` | 6 / 60000 | 0.074 [0.066..0.098] | 0.040/0.051/0.055 | 13592066.7 | 9190.6 | 0.049 | 0.7 |
| `queue_opaque_hook8` | `same_state_queue` | 6 / 30000 | 3.874 [3.514..6.233] | 2.544/4.654/46.802 | 258395.3 | 9175.4 | 0.358 | 96.2 |
| `queue_packed_hook8` | `same_state_queue` | 6 / 30000 | 5.019 [4.463..6.421] | 3.066/9.373/53.820 | 199337.2 | 7767.0 | 0.216 | 81.8 |
| `queue_plain_bytes8` | `same_state_queue` | 6 / 30000 | 2.917 [2.692..4.823] | 1.859/3.296/22.492 | 343847.9 | 9075.5 | 0.318 | 74.6 |
| `queue_real_receiver` | `same_state_queue` | 6 / 30000 | 4.328 [3.741..7.604] | 2.720/6.868/45.019 | 231049.8 | 9423.8 | 0.389 | 82.2 |
| `queue_real_sender` | `same_state_queue` | 6 / 30000 | 5.258 [3.660..6.238] | 3.116/6.341/53.445 | 190622.7 | 9393.4 | 0.579 | 94.8 |
| `sender_clone` | `same_state_queue` | 6 / 30000 | 0.200 [0.183..0.287] | 0.160/0.230/0.430 | 5011465.3 | 8334.7 | 0.157 | 33.4 |
| `spsc_endpoint_carried_persistent` | `persistent_reply` | 6 / 6000 | 21.872 [15.919..25.975] | 15.900/46.777/115.816 | 45721.6 | 8978.1 | 1.783 | 1545.5 |
| `spsc_endpoint_fresh_reply` | `fresh_reply` | 6 / 3000 | 17.615 [16.093..21.216] | 15.514/23.770/44.353 | 56771.2 | 8867.3 | 4.637 | 2056.3 |
| `spsc_endpoint_pool4_reply` | `pool_four_reply` | 6 / 6000 | 22.203 [21.035..27.427] | 16.331/51.481/141.034 | 45040.1 | 9051.3 | 1.726 | 1736.8 |
| `spsc_large64k_endpoint_pool4` | `pool_four_reply` | 6 / 1536 | 39.268 [25.684..47.170] | 31.974/76.338/146.303 | 25514.3 | 8691.9 | 6.154 | 1089.0 |
| `spsc_large64k_persistent` | `persistent_reply` | 6 / 1536 | 38.577 [31.603..42.012] | 28.874/77.916/192.945 | 25926.4 | 8884.1 | 7.069 | 1202.1 |
| `spsc_opaque_persistent` | `persistent_reply` | 6 / 6000 | 21.234 [18.549..22.602] | 15.944/47.198/111.453 | 47109.6 | 9464.8 | 1.678 | 1513.8 |
| `spsc_record_persistent` | `persistent_reply` | 6 / 6000 | 18.038 [13.693..21.385] | 12.378/44.923/107.061 | 56169.6 | 8682.8 | 0.835 | 1064.0 |
| `spsc_record_pool4_control` | `pool_four_reply` | 6 / 6000 | 16.844 [12.225..22.768] | 12.358/38.447/98.089 | 61319.1 | 9468.8 | 1.149 | 1030.5 |
| `spsc_scalar_persistent` | `persistent_reply` | 6 / 6000 | 7.281 [5.458..8.265] | 6.797/9.748/20.779 | 137372.2 | 8967.6 | 2.796 | 1780.8 |
| `wait_empty_receiver_endpoint` | `directed_empty_wait` | 6 / 3000 | 35.551 [26.539..38.068] | 21.215/80.135/305.236 | 28144.4 | 8866.4 | 6.115 | 1499.3 |
| `wait_empty_receiver_record` | `directed_empty_wait` | 6 / 3000 | 33.432 [26.175..37.824] | 22.707/63.299/409.741 | 29917.4 | 9050.6 | 5.995 | 1544.4 |
| `wait_full_sender_endpoint` | `directed_full_wait` | 6 / 3000 | 36.323 [35.109..41.116] | 24.846/72.916/333.945 | 27531.4 | 8747.0 | 8.334 | 2386.6 |
| `wait_full_sender_record` | `directed_full_wait` | 6 / 3000 | 34.072 [29.216..43.763] | 22.933/75.927/313.822 | 29354.8 | 9233.3 | 7.463 | 2038.0 |

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
| `join_ordinary` | 200 | 300 | 1 | 299 | 100 / 0 | 299 | 0 | 500 / 400 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 4411 | 2624 | 300 | 2324 | 0 / 0 | 2384 | 0 | 2624 / 2684 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 4310 | 2816 | 354 | 2462 | 0 / 0 | 2522 | 0 | 2816 / 2876 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 4003 | 2483 | 1 | 2482 | 0 / 0 | 2482 | 0 | 2483 / 2483 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 4170 | 2567 | 353 | 2214 | 0 / 0 | 2220 | 0 | 2567 / 2573 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 4237 | 2443 | 241 | 2202 | 0 / 0 | 2208 | 0 | 2443 / 2449 |
| `mpmc_record_inflight16_cap16_4p4c` | 4368 | 2750 | 255 | 2495 | 0 / 0 | 2555 | 0 | 2750 / 2810 |
| `mpmc_record_inflight16_cap2_4p4c` | 4326 | 2711 | 330 | 2381 | 0 / 0 | 2441 | 0 | 2711 / 2771 |
| `mpmc_record_inflight1_cap1_2p2c` | 4003 | 2504 | 2 | 2502 | 0 / 0 | 2502 | 0 | 2504 / 2504 |
| `mpmc_record_inflight4_cap1_2p2c` | 4111 | 2633 | 352 | 2281 | 0 / 0 | 2287 | 0 | 2633 / 2639 |
| `mpmc_record_inflight4_cap4_2p2c` | 4239 | 2430 | 213 | 2217 | 0 / 0 | 2223 | 0 | 2430 / 2436 |
| `overhead_control` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_opaque_hook8` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_packed_hook8` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_plain_bytes8` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_real_receiver` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_real_sender` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `sender_clone` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `spsc_endpoint_carried_persistent` | 2000 | 2000 | 27 | 1973 | 0 / 0 | 1973 | 0 | 2000 / 2000 |
| `spsc_endpoint_fresh_reply` | 1000 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 1000 / 1000 |
| `spsc_endpoint_pool4_reply` | 2000 | 2000 | 29 | 1971 | 0 / 0 | 1971 | 0 | 2000 / 2000 |
| `spsc_large64k_endpoint_pool4` | 512 | 512 | 0 | 512 | 0 / 0 | 512 | 0 | 512 / 512 |
| `spsc_large64k_persistent` | 512 | 512 | 0 | 512 | 0 / 0 | 512 | 0 | 512 / 512 |
| `spsc_opaque_persistent` | 2000 | 2000 | 20 | 1980 | 0 / 0 | 1980 | 0 | 2000 / 2000 |
| `spsc_record_persistent` | 2000 | 2000 | 41 | 1959 | 0 / 0 | 1959 | 0 | 2000 / 2000 |
| `spsc_record_pool4_control` | 2001 | 1999 | 39 | 1960 | 0 / 0 | 1960 | 0 | 1999 / 1999 |
| `spsc_scalar_persistent` | 2001 | 1999 | 70 | 1929 | 0 / 0 | 1929 | 0 | 1999 / 1999 |
| `wait_empty_receiver_endpoint` | 1000 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 1000 / 1000 |
| `wait_empty_receiver_record` | 1000 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 1000 / 1000 |
| `wait_full_sender_endpoint` | 1530 | 1470 | 192 | 1278 | 0 / 0 | 1278 | 0 | 1470 / 1470 |
| `wait_full_sender_record` | 1746 | 1254 | 176 | 1078 | 0 / 0 | 1078 | 0 | 1254 / 1254 |

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
| `mpmc_endpoint_inflight16_cap16_4p4c` | 13572 | 13563 | 13563 | 9 | 9 / 9 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 14323 | 14314 | 14314 | 9 | 9 / 9 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 2822 | 2817 | 2817 | 5 | 5 / 5 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 3904 | 3899 | 3899 | 5 | 5 / 5 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 3695 | 3690 | 3690 | 5 | 5 / 5 |
| `mpmc_record_inflight16_cap16_4p4c` | 13984 | 13975 | 13975 | 9 | 9 / 9 |
| `mpmc_record_inflight16_cap2_4p4c` | 14333 | 14324 | 14324 | 9 | 9 / 9 |
| `mpmc_record_inflight1_cap1_2p2c` | 2847 | 2842 | 2842 | 5 | 5 / 5 |
| `mpmc_record_inflight4_cap1_2p2c` | 3987 | 3982 | 3982 | 5 | 5 / 5 |
| `mpmc_record_inflight4_cap4_2p2c` | 3723 | 3718 | 3718 | 5 | 5 / 5 |
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
| `spsc_record_pool4_control` | 2133 | 2131 | 2131 | 2 | 2 / 2 |
| `spsc_scalar_persistent` | 2133 | 2131 | 2131 | 2 | 2 / 2 |
| `wait_empty_receiver_endpoint` | 1070 | 1068 | 1068 | 2 | 2 / 2 |
| `wait_empty_receiver_record` | 1070 | 1068 | 1068 | 2 | 2 / 2 |
| `wait_full_sender_endpoint` | 1572 | 1570 | 1570 | 2 | 2 / 2 |
| `wait_full_sender_record` | 1356 | 1354 | 1354 | 2 | 2 / 2 |

Whole-case counters start at the setup snapshot after cold first use; identities are tracked from process birth, including cold loops. Libuv initializes loop-internal async handles through uv_async_init but retires them directly during successful uv_loop_close. Those retirements are not fabricated public close requests or callbacks. A busy/failed loop close retires no identity; active_async_handles remains the actual unretired registry count and must be zero. Real UV allocation traffic is not suppressed.


### Allocation and observed copy traffic

| Case | Lua allocs / requested B per op | Native allocs / requested B per op | Interposed copy B/op (outside / inside Lua allocator) | Analytical reference B/op (not wire/copy bytes) |
|---|---:|---:|---:|---:|
| `call_control` | 0.00 / 0.0 | 0.00 / 0.0 | 0.0 (0.0 / 0.0) | 0 |
| `churn_cancel_parked_waiters` | 99.84 / 26555.0 | 8.00 / 560.0 | 10033.1 (10033.1 / 0.0) | 0 |
| `churn_close_parked_receivers` | 80.23 / 24923.3 | 3.00 / 152.0 | 47.6 (47.6 / 0.0) | 0 |
| `churn_close_parked_senders` | 85.21 / 20210.1 | 6.00 / 536.0 | 2480.6 (2480.6 / 0.0) | 0 |
| `closure_roundtrip_cap0` | 54.01 / 3147.4 | 2.00 / 384.0 | 132.0 (132.0 / 0.0) | 0 |
| `closure_roundtrip_cap1` | 106.01 / 6004.5 | 2.00 / 384.0 | 293.0 (293.0 / 0.0) | 0 |
| `closure_roundtrip_cap64` | 3038.06 / 189086.6 | 4.00 / 1920.0 | 12065.0 (12065.0 / 0.0) | 0 |
| `closure_roundtrip_cap8` | 444.02 / 26331.9 | 2.00 / 384.0 | 1532.0 (1532.0 / 0.0) | 0 |
| `closure_roundtrip_complex_sig` | 106.01 / 6004.7 | 2.00 / 384.0 | 293.0 (293.0 / 0.0) | 0 |
| `codec_large64k_decode` | 16.02 / 66349.6 | 0.00 / 0.0 | 65562.0 (65562.0 / 0.0) | 65540 |
| `codec_large64k_encode` | 7.02 / 65953.6 | 2.00 / 131136.0 | 131076.0 (131076.0 / 0.0) | 65540 |
| `codec_large64k_transfer_roundtrip` | 27.04 / 67311.0 | 3.00 / 131456.0 | 131113.0 (131113.0 / 0.0) | 65540 |
| `codec_scalar_roundtrip` | 4.00 / 512.0 | 1.00 / 128.0 | 0.0 (0.0 / 0.0) | 8 |
| `codec_small_decode` | 21.00 / 1049.0 | 0.00 / 0.0 | 83.0 (83.0 / 0.0) | 11 |
| `codec_small_encode` | 6.00 / 380.0 | 1.00 / 64.0 | 7.0 (7.0 / 0.0) | 11 |
| `codec_small_transfer_roundtrip` | 32.00 / 2009.1 | 2.00 / 384.0 | 106.0 (106.0 / 0.0) | 11 |
| `codec_wide16_decode` | 44.00 / 3805.1 | 0.00 / 0.0 | 749.0 (749.0 / 0.0) | 33 |
| `codec_wide16_encode` | 6.00 / 380.0 | 1.00 / 64.0 | 0.0 (0.0 / 0.0) | 33 |
| `codec_wide16_transfer_roundtrip` | 55.00 / 4765.2 | 2.00 / 384.0 | 764.0 (764.0 / 0.0) | 33 |
| `inspect_function` | 50.01 / 2376.4 | 0.00 / 0.0 | 80.0 (80.0 / 0.0) | 0 |
| `inspect_record` | 2.00 / 172.0 | 0.00 / 0.0 | 0.0 (0.0 / 0.0) | 0 |
| `join_cleanup_cancelled_task` | 25107.95 / 4062701.8 | 27.00 / 3752.0 | 5210749.3 (5210749.3 / 0.0) | 0 |
| `join_ordinary` | 24674.33 / 4004943.1 | 20.00 / 2832.0 | 1653350.6 (1653350.6 / 0.0) | 0 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 123.41 / 9564.6 | 6.07 / 1000.7 | 265.3 (265.3 / 0.0) | 0 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 125.92 / 9822.8 | 6.07 / 1000.7 | 265.2 (265.2 / 0.0) | 0 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 121.11 / 9288.9 | 6.00 / 992.5 | 265.0 (265.0 / 0.0) | 0 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 121.82 / 9412.1 | 6.01 / 993.3 | 265.1 (265.1 / 0.0) | 0 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 120.52 / 9258.7 | 6.01 / 993.3 | 265.1 (265.1 / 0.0) | 0 |
| `mpmc_record_inflight16_cap16_4p4c` | 116.22 / 9037.7 | 5.07 / 904.7 | 265.3 (265.3 / 0.0) | 0 |
| `mpmc_record_inflight16_cap2_4p4c` | 115.40 / 8966.1 | 5.07 / 904.7 | 265.2 (265.2 / 0.0) | 0 |
| `mpmc_record_inflight1_cap1_2p2c` | 112.42 / 8625.7 | 5.00 / 896.5 | 265.0 (265.0 / 0.0) | 0 |
| `mpmc_record_inflight4_cap1_2p2c` | 113.61 / 8793.1 | 5.01 / 897.3 | 265.1 (265.1 / 0.0) | 0 |
| `mpmc_record_inflight4_cap4_2p2c` | 111.37 / 8547.6 | 5.01 / 897.3 | 265.1 (265.1 / 0.0) | 0 |
| `overhead_control` | 0.00 / 0.0 | 0.00 / 0.0 | 0.0 (0.0 / 0.0) | 0 |
| `queue_opaque_hook8` | 44.00 / 2865.1 | 2.00 / 384.0 | 139.0 (139.0 / 0.0) | 21 |
| `queue_packed_hook8` | 65.00 / 3973.2 | 2.00 / 384.0 | 196.0 (196.0 / 0.0) | 21 |
| `queue_plain_bytes8` | 36.00 / 2273.1 | 2.00 / 384.0 | 139.0 (139.0 / 0.0) | 21 |
| `queue_real_receiver` | 45.00 / 2969.2 | 3.00 / 480.0 | 138.0 (138.0 / 0.0) | 21 |
| `queue_real_sender` | 45.00 / 2969.2 | 3.00 / 480.0 | 136.0 (136.0 / 0.0) | 21 |
| `sender_clone` | 2.00 / 168.0 | 0.00 / 0.0 | 0.0 (0.0 / 0.0) | 21 |
| `spsc_endpoint_carried_persistent` | 109.20 / 8036.2 | 5.00 / 864.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_endpoint_fresh_reply` | 113.20 / 8369.8 | 8.00 / 1016.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_endpoint_pool4_reply` | 109.19 / 8035.1 | 5.00 / 864.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_large64k_endpoint_pool4` | 110.53 / 73630.0 | 6.00 / 131936.0 | 131332.0 (131332.0 / 0.0) | 65565 |
| `spsc_large64k_persistent` | 101.43 / 72926.3 | 5.00 / 131840.0 | 131330.0 (131330.0 / 0.0) | 65565 |
| `spsc_opaque_persistent` | 108.48 / 7958.8 | 4.00 / 768.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_record_persistent` | 100.40 / 7359.6 | 4.00 / 768.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_record_pool4_control` | 100.41 / 7361.0 | 4.00 / 768.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_scalar_persistent` | 38.09 / 3904.3 | 2.00 / 256.0 | 0.0 (0.0 / 0.0) | 16 |
| `wait_empty_receiver_endpoint` | 108.17 / 17702.1 | 4.00 / 608.0 | 169.3 (169.3 / 0.0) | 29 |
| `wait_empty_receiver_record` | 98.17 / 16942.9 | 3.00 / 512.0 | 169.3 (169.3 / 0.0) | 29 |
| `wait_full_sender_endpoint` | 153.90 / 21127.9 | 6.00 / 992.0 | 295.3 (295.3 / 0.0) | 29 |
| `wait_full_sender_record` | 136.42 / 16402.5 | 5.00 / 896.0 | 295.3 (295.3 / 0.0) | 29 |

Lua allocator requests include state birth and terminal close. Only allocations made inside the underlying Lua allocator are excluded from native traffic; real UV allocations are not suppressed. Copy counts cover interposed memcpy **and memmove** calls, not inlined copies, scalar stores or libc-internal copying. Actual total wire bytes are unavailable; the analytical reference can use a different payload/ID and is not presented as measured transfer traffic.

### Lifecycle and post-retirement evidence (all instrumented rounds)

| Case | Rounds | Channels delta range | Controls delta range | Active worker range | Lua state delta / active async handles / pending wait probes | Observed native block / usable B net ranges | Host Lua net B range | Checksums / lifecycle |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| `call_control` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `churn_cancel_parked_waiters` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 104.0..104.0 | valid |
| `churn_close_parked_receivers` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 3.0..3.0 | valid |
| `churn_close_parked_senders` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 104.0..104.0 | valid |
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
| `join_cleanup_cancelled_task` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 3232.0..3232.0 | valid |
| `join_ordinary` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 3.0..3.0 | valid |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7548.0..7548.0 | valid |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7548.0..7548.0 | valid |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7548.0..7548.0 | valid |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7548.0..7548.0 | valid |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7548.0..7548.0 | valid |
| `mpmc_record_inflight16_cap16_4p4c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 9763.0..9763.0 | valid |
| `mpmc_record_inflight16_cap2_4p4c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 9763.0..9763.0 | valid |
| `mpmc_record_inflight1_cap1_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 9763.0..9763.0 | valid |
| `mpmc_record_inflight4_cap1_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 9763.0..9763.0 | valid |
| `mpmc_record_inflight4_cap4_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 9763.0..9763.0 | valid |
| `overhead_control` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `queue_opaque_hook8` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 5638.0..5638.0 | valid |
| `queue_packed_hook8` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 5638.0..5638.0 | valid |
| `queue_plain_bytes8` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 45.0..45.0 | valid |
| `queue_real_receiver` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2422.0..2422.0 | valid |
| `queue_real_sender` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2422.0..2422.0 | valid |
| `sender_clone` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | -71.0..-71.0 | valid |
| `spsc_endpoint_carried_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2395.0..2395.0 | valid |
| `spsc_endpoint_fresh_reply` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2395.0..2395.0 | valid |
| `spsc_endpoint_pool4_reply` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2395.0..2395.0 | valid |
| `spsc_large64k_endpoint_pool4` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2395.0..2395.0 | valid |
| `spsc_large64k_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2087.0..2087.0 | valid |
| `spsc_opaque_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 5611.0..5611.0 | valid |
| `spsc_record_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | -30.0..-30.0 | valid |
| `spsc_record_pool4_control` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2197.0..2197.0 | valid |
| `spsc_scalar_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | -30.0..-30.0 | valid |
| `wait_empty_receiver_endpoint` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2455.0..2455.0 | valid |
| `wait_empty_receiver_record` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 162.0..162.0 | valid |
| `wait_full_sender_endpoint` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2428.0..2428.0 | valid |
| `wait_full_sender_record` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 3.0..3.0 | valid |

Channel/control counts are actual native birth/destruction probes. Worker quiescence waits for the native end-of-worker release, not a fixed number of loop turns or public join alone; it is native domain-ownership retirement evidence, not an OS-join proof. The pre-wake resource-ownership correctness checkpoint intentionally retains known legacy detached-thread/proxy-early-terminal behavior and is not final Thread approval. The separate final corrected wake/join candidate requires actual OS join before every proxy terminal and full platform correctness evidence. Explicit residual collections occur outside body timing. The allocator's signed net delta is an observed ledger, **not** a complete retained-native-memory oracle; lifecycle counts are reported separately. Failed calibration, missing/truncated samples, checksum errors and unretired native domains reject a campaign.

### Overlapping source-scoped stage intervals

| Case | Wake attribution | Sender entry through encode | Queue lock + branch | Registration after failed check | Notify to continuation | Post-dequeue decode + return | Reply processing |
|---|---|---:|---:|---:|---:|---:|---:|
| `call_control` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `churn_cancel_parked_waiters` | `unavailable_unawaited_cancelled_failed_or_nonunique_notification` | 0.641/3.220 (1000 total; 500..500/round) | 0.036/0.326 (5000 total; 2500..2500/round) | 1.393/139.190 (2000 total; 1000..1000/round) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `churn_close_parked_receivers` | `exact_waiter_notification_to_continuation` | unavailable (0 samples) | 0.030/0.275 (6000 total; 3000..3000/round) | 1.273/13.174 (2000 total; 1000..1000/round) | 2.099/7.464 (2000 total; 1000..1000/round) | unavailable (0 samples) | unavailable (0 samples) |
| `churn_close_parked_senders` | `exact_waiter_notification_to_continuation` | 1.142/5.139 (2000 total; 1000..1000/round) | 0.030/0.275 (7000 total; 3500..3500/round) | 0.686/2.926 (2000 total; 1000..1000/round) | 6.748/21.195 (2000 total; 1000..1000/round) | unavailable (0 samples) | unavailable (0 samples) |
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
| `join_cleanup_cancelled_task` | `partial_exact_only` | unavailable (0 samples) | 0.370/8.140 (3200 total; 1600..1600/round) | unavailable (0 samples) | 22.547/62.367 (800 total; 400..400/round) | unavailable (0 samples) | unavailable (0 samples) |
| `join_ordinary` | `exact_waiter_notification_to_continuation` | unavailable (0 samples) | 0.466/8.631 (1799 total; 899..900/round) | unavailable (0 samples) | 15.574/62.317 (599 total; 299..300/round) | unavailable (0 samples) | unavailable (0 samples) |
| `mpmc_endpoint_inflight16_cap16_4p4c` | `exact_waiter_notification_to_continuation` | 3.026/10.339 (4000 total; 2000..2000/round) | 0.290/8.902 (22325 total; 11084..11241/round) | 2.901/6.958 (1999 total; 999..1000/round) | 51.456/188.312 (4848 total; 2384..2464/round) | 5.901/13.756 (2000 total; 1000..1000/round) | 0.030/0.070 (2000 total; 1000..1000/round) |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `exact_waiter_notification_to_continuation` | 3.101/7.614 (4000 total; 2000..2000/round) | 0.225/6.607 (22379 total; 10965..11414/round) | 2.760/7.905 (2097 total; 1045..1052/round) | 45.595/174.912 (4832 total; 2310..2522/round) | 5.470/11.396 (2000 total; 1000..1000/round) | 0.030/0.100 (2000 total; 1000..1000/round) |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `exact_waiter_notification_to_continuation` | 1.933/9.393 (4000 total; 2000..2000/round) | 0.166/1.718 (21989 total; 10973..11016/round) | 1.402/6.433 (2000 total; 1000..1000/round) | 4.037/15.976 (4986 total; 2482..2504/round) | 2.870/15.735 (2000 total; 1000..1000/round) | 0.025/0.050 (2000 total; 1000..1000/round) |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `exact_waiter_notification_to_continuation` | 2.154/11.326 (4000 total; 2000..2000/round) | 0.116/3.296 (21690 total; 10801..10889/round) | 1.743/6.296 (2305 total; 1152..1153/round) | 9.964/54.377 (4496 total; 2220..2276/round) | 3.832/14.046 (2000 total; 1000..1000/round) | 0.030/0.065 (2000 total; 1000..1000/round) |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `exact_waiter_notification_to_continuation` | 2.054/5.700 (4000 total; 2000..2000/round) | 0.090/2.931 (21351 total; 10665..10686/round) | 1.543/4.880 (2000 total; 1000..1000/round) | 9.738/29.515 (4433 total; 2208..2225/round) | 3.652/10.564 (2000 total; 1000..1000/round) | 0.030/0.055 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight16_cap16_4p4c` | `exact_waiter_notification_to_continuation` | 2.500/11.517 (4000 total; 2000..2000/round) | 0.280/8.601 (22104 total; 10723..11381/round) | 2.900/7.950 (2000 total; 1000..1000/round) | 45.260/181.845 (4796 total; 2241..2555/round) | 5.941/15.174 (2000 total; 1000..1000/round) | 0.030/0.086 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight16_cap2_4p4c` | `exact_waiter_notification_to_continuation` | 2.460/8.546 (4000 total; 2000..2000/round) | 0.316/10.745 (22265 total; 11037..11228/round) | 3.156/9.583 (2110 total; 1053..1057/round) | 51.736/202.663 (4791 total; 2350..2441/round) | 5.896/14.572 (2000 total; 1000..1000/round) | 0.030/0.085 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight1_cap1_2p2c` | `exact_waiter_notification_to_continuation` | 1.298/7.164 (4000 total; 2000..2000/round) | 0.090/1.633 (22059 total; 11014..11045/round) | 1.323/5.395 (2000 total; 1000..1000/round) | 3.331/14.732 (5020 total; 2502..2518/round) | 2.705/11.436 (2000 total; 1000..1000/round) | 0.030/0.060 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight4_cap1_2p2c` | `exact_waiter_notification_to_continuation` | 1.463/6.572 (4000 total; 2000..2000/round) | 0.100/3.075 (21916 total; 10934..10982/round) | 1.588/6.292 (2386 total; 1188..1198/round) | 9.102/35.492 (4602 total; 2287..2315/round) | 3.622/18.084 (2000 total; 1000..1000/round) | 0.030/0.051 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight4_cap4_2p2c` | `exact_waiter_notification_to_continuation` | 1.568/6.492 (4000 total; 2000..2000/round) | 0.150/3.616 (20787 total; 10120..10667/round) | 1.473/4.633 (2000 total; 1000..1000/round) | 8.622/35.160 (4164 total; 1941..2223/round) | 3.802/11.191 (2000 total; 1000..1000/round) | 0.025/0.070 (2000 total; 1000..1000/round) |
| `overhead_control` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `queue_opaque_hook8` | `no_suspensions` | 1.188/9.308 (10000 total; 5000..5000/round) | 0.030/0.165 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 1.718/19.111 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `queue_packed_hook8` | `no_suspensions` | 1.688/22.892 (10000 total; 5000..5000/round) | 0.030/0.150 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 2.029/69.840 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `queue_plain_bytes8` | `no_suspensions` | 1.152/5.685 (10000 total; 5000..5000/round) | 0.040/0.185 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 2.139/60.058 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `queue_real_receiver` | `no_suspensions` | 1.563/6.512 (10000 total; 5000..5000/round) | 0.030/0.145 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 2.340/35.697 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `queue_real_sender` | `no_suspensions` | 1.368/8.997 (10000 total; 5000..5000/round) | 0.030/0.150 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 2.024/24.916 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `sender_clone` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `spsc_endpoint_carried_persistent` | `exact_waiter_notification_to_continuation` | 1.573/14.051 (4000 total; 2000..2000/round) | 0.190/2.409 (15946 total; 7973..7973/round) | 1.188/33.328 (2000 total; 1000..1000/round) | 3.226/14.552 (3946 total; 1973..1973/round) | 2.585/28.474 (2000 total; 1000..1000/round) | 0.110/1.433 (2000 total; 1000..1000/round) |
| `spsc_endpoint_fresh_reply` | `exact_waiter_notification_to_continuation` | 1.913/6.382 (2000 total; 1000..1000/round) | 0.230/1.047 (8000 total; 4000..4000/round) | 1.198/3.421 (1000 total; 500..500/round) | 3.086/8.421 (2000 total; 1000..1000/round) | 2.735/6.803 (1000 total; 500..500/round) | 0.096/1.428 (1000 total; 500..500/round) |
| `spsc_endpoint_pool4_reply` | `exact_waiter_notification_to_continuation` | 1.948/15.198 (4000 total; 2000..2000/round) | 0.185/1.268 (15936 total; 7965..7971/round) | 1.222/27.717 (2000 total; 1000..1000/round) | 3.111/9.428 (3936 total; 1965..1971/round) | 2.679/44.743 (2000 total; 1000..1000/round) | 0.100/1.493 (2000 total; 1000..1000/round) |
| `spsc_large64k_endpoint_pool4` | `exact_waiter_notification_to_continuation` | 2.705/19.702 (1024 total; 512..512/round) | 0.170/2.149 (4096 total; 2048..2048/round) | 1.037/4.979 (512 total; 256..256/round) | 2.625/13.640 (1024 total; 512..512/round) | 2.094/10.269 (512 total; 256..256/round) | 0.075/0.326 (512 total; 256..256/round) |
| `spsc_large64k_persistent` | `exact_waiter_notification_to_continuation` | 2.619/12.033 (1024 total; 512..512/round) | 0.200/1.518 (4096 total; 2048..2048/round) | 1.012/4.925 (512 total; 256..256/round) | 2.631/11.412 (1024 total; 512..512/round) | 2.143/9.924 (512 total; 256..256/round) | 0.085/0.436 (512 total; 256..256/round) |
| `spsc_opaque_persistent` | `exact_waiter_notification_to_continuation` | 1.512/23.383 (4000 total; 2000..2000/round) | 0.185/1.131 (15964 total; 7980..7984/round) | 1.062/26.945 (1999 total; 999..1000/round) | 2.605/10.995 (3965 total; 1980..1985/round) | 2.309/39.068 (2000 total; 1000..1000/round) | 0.085/1.297 (2000 total; 1000..1000/round) |
| `spsc_record_persistent` | `exact_waiter_notification_to_continuation` | 1.107/14.617 (4000 total; 2000..2000/round) | 0.141/1.137 (15920 total; 7959..7961/round) | 0.992/83.261 (2000 total; 1000..1000/round) | 2.590/9.238 (3920 total; 1959..1961/round) | 2.094/16.581 (2000 total; 1000..1000/round) | 0.085/1.393 (2000 total; 1000..1000/round) |
| `spsc_record_pool4_control` | `exact_waiter_notification_to_continuation` | 0.977/10.495 (4000 total; 2000..2000/round) | 0.165/1.583 (15924 total; 7959..7965/round) | 0.937/49.769 (1999 total; 999..1000/round) | 2.259/11.090 (3925 total; 1960..1965/round) | 2.014/16.421 (2000 total; 1000..1000/round) | 0.070/0.977 (2000 total; 1000..1000/round) |
| `spsc_scalar_persistent` | `exact_waiter_notification_to_continuation` | 0.441/2.405 (4000 total; 2000..2000/round) | 0.105/1.442 (15879 total; 7928..7951/round) | 1.283/5.249 (1999 total; 999..1000/round) | 2.806/9.458 (3880 total; 1929..1951/round) | 0.616/2.425 (2000 total; 1000..1000/round) | 0.030/0.036 (2000 total; 1000..1000/round) |
| `wait_empty_receiver_endpoint` | `exact_waiter_notification_to_continuation` | unavailable (0 samples) | 0.231/1.143 (8000 total; 4000..4000/round) | 2.665/30.853 (1000 total; 500..500/round) | 3.096/13.655 (2000 total; 1000..1000/round) | 4.353/240.535 (1000 total; 500..500/round) | unavailable (0 samples) |
| `wait_empty_receiver_record` | `exact_waiter_notification_to_continuation` | unavailable (0 samples) | 0.195/0.947 (8000 total; 4000..4000/round) | 2.244/59.395 (1000 total; 500..500/round) | 2.931/11.056 (2000 total; 1000..1000/round) | 3.782/38.913 (1000 total; 500..500/round) | unavailable (0 samples) |
| `wait_full_sender_endpoint` | `exact_waiter_notification_to_continuation` | 3.412/123.746 (1000 total; 500..500/round) | 0.155/1.988 (11446 total; 5698..5748/round) | 1.087/5.841 (1896 total; 926..970/round) | 3.106/12.534 (2550 total; 1272..1278/round) | 2.540/13.671 (1000 total; 500..500/round) | unavailable (0 samples) |
| `wait_full_sender_record` | `exact_waiter_notification_to_continuation` | 2.905/26.625 (1000 total; 500..500/round) | 0.131/1.127 (10749 total; 5332..5417/round) | 1.363/16.245 (1547 total; 754..793/round) | 3.026/9.307 (2202 total; 1078..1124/round) | 2.991/26.334 (1000 total; 500..500/round) | unavailable (0 samples) |

Cells are medians of per-round p50/p99 microseconds, with total sample count and per-round count range. Wake modes list all observed round modes, not only the representative counter round. Encode/decode subintervals cover selected benchmark call brackets, not every worker's codec. Queue intervals include lock acquisition and readiness/closed branches, ending before unlock. Native wake correlates the exact selected waiter with its notification and successful continuation; cancelled/failed/nonunique or unawaited prearmed notifications are unavailable, never attributed to a global last signal. Both current matched lanes end the native-wake interval at the exact successful native-await return, including helper cleanup. Do not pool this with frozen-v4 raw coroutine-return samples. It is not isolated kernel wake latency. Stages overlap across OS threads: do not add medians or subtract independently measured RTTs to manufacture a component time.

### Instrumentation overhead

| Case | Original SDK us/op | Private instrumented us/op | Difference us/op | Ratio |
|---|---:|---:|---:|---:|
| `call_control` | 0.054 | 0.068 | +0.014 | 1.261 |
| `churn_cancel_parked_waiters` | 81.399 | 84.751 | +3.352 | 1.041 |
| `churn_close_parked_receivers` | 27.849 | 29.561 | +1.712 | 1.061 |
| `churn_close_parked_senders` | 39.741 | 43.552 | +3.811 | 1.096 |
| `closure_roundtrip_cap0` | 3.118 | 4.549 | +1.430 | 1.459 |
| `closure_roundtrip_cap1` | 6.734 | 10.636 | +3.903 | 1.580 |
| `closure_roundtrip_cap64` | 152.163 | 237.406 | +85.243 | 1.560 |
| `closure_roundtrip_cap8` | 25.950 | 33.451 | +7.501 | 1.289 |
| `closure_roundtrip_complex_sig` | 6.517 | 7.768 | +1.251 | 1.192 |
| `codec_large64k_decode` | 7.826 | 7.850 | +0.024 | 1.003 |
| `codec_large64k_encode` | 8.020 | 10.602 | +2.582 | 1.322 |
| `codec_large64k_transfer_roundtrip` | 9.967 | 14.232 | +4.265 | 1.428 |
| `codec_scalar_roundtrip` | 0.560 | 0.600 | +0.039 | 1.070 |
| `codec_small_decode` | 1.046 | 1.545 | +0.500 | 1.478 |
| `codec_small_encode` | 0.677 | 0.682 | +0.005 | 1.007 |
| `codec_small_transfer_roundtrip` | 2.600 | 3.360 | +0.760 | 1.292 |
| `codec_wide16_decode` | 2.842 | 4.696 | +1.854 | 1.653 |
| `codec_wide16_encode` | 1.328 | 1.543 | +0.215 | 1.162 |
| `codec_wide16_transfer_roundtrip` | 4.952 | 6.961 | +2.009 | 1.406 |
| `inspect_function` | 2.183 | 2.731 | +0.548 | 1.251 |
| `inspect_record` | 0.165 | 0.244 | +0.079 | 1.480 |
| `join_cleanup_cancelled_task` | 44861.278 | 42954.732 | -1906.546 | 0.958 |
| `join_ordinary` | 7034.756 | 7733.989 | +699.232 | 1.099 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 3.532 | 6.987 | +3.455 | 1.978 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 3.603 | 6.783 | +3.180 | 1.882 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 18.860 | 25.026 | +6.166 | 1.327 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 6.240 | 9.903 | +3.663 | 1.587 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 6.284 | 7.956 | +1.672 | 1.266 |
| `mpmc_record_inflight16_cap16_4p4c` | 3.957 | 7.640 | +3.684 | 1.931 |
| `mpmc_record_inflight16_cap2_4p4c` | 3.515 | 7.465 | +3.950 | 2.124 |
| `mpmc_record_inflight1_cap1_2p2c` | 18.451 | 22.544 | +4.093 | 1.222 |
| `mpmc_record_inflight4_cap1_2p2c` | 6.744 | 8.384 | +1.640 | 1.243 |
| `mpmc_record_inflight4_cap4_2p2c` | 5.734 | 8.053 | +2.319 | 1.404 |
| `overhead_control` | 0.074 | 0.098 | +0.024 | 1.331 |
| `queue_opaque_hook8` | 3.874 | 5.152 | +1.278 | 1.330 |
| `queue_packed_hook8` | 5.019 | 6.487 | +1.467 | 1.292 |
| `queue_plain_bytes8` | 2.917 | 6.063 | +3.146 | 2.079 |
| `queue_real_receiver` | 4.328 | 6.886 | +2.557 | 1.591 |
| `queue_real_sender` | 5.258 | 5.953 | +0.695 | 1.132 |
| `sender_clone` | 0.200 | 0.301 | +0.102 | 1.510 |
| `spsc_endpoint_carried_persistent` | 21.872 | 26.419 | +4.547 | 1.208 |
| `spsc_endpoint_fresh_reply` | 17.615 | 20.041 | +2.427 | 1.138 |
| `spsc_endpoint_pool4_reply` | 22.203 | 26.343 | +4.140 | 1.186 |
| `spsc_large64k_endpoint_pool4` | 39.268 | 38.796 | -0.473 | 0.988 |
| `spsc_large64k_persistent` | 38.577 | 33.982 | -4.595 | 0.881 |
| `spsc_opaque_persistent` | 21.234 | 21.948 | +0.714 | 1.034 |
| `spsc_record_persistent` | 18.038 | 20.584 | +2.546 | 1.141 |
| `spsc_record_pool4_control` | 16.844 | 19.146 | +2.301 | 1.137 |
| `spsc_scalar_persistent` | 7.281 | 9.576 | +2.295 | 1.315 |
| `wait_empty_receiver_endpoint` | 35.551 | 39.243 | +3.692 | 1.104 |
| `wait_empty_receiver_record` | 33.432 | 32.883 | -0.550 | 0.984 |
| `wait_full_sender_endpoint` | 36.323 | 37.819 | +1.496 | 1.041 |
| `wait_full_sender_record` | 34.072 | 37.857 | +3.785 | 1.111 |

### Finite MPMC credit wait and progress

These existing MPMC cases retain their original post-permit RTT boundary. Separate bounded request traces start before credit acquisition and retain actual producer/lane identity. Values below are medians [ranges] of per-round worst-lane statistics, in microseconds; availability is shown as contributing/total rounds. Per-lane sample counts/distributions and raw trace hashes remain in JSON. An empty lane or one-completion gap series is unavailable, not zero.

| Case | Mode | Rounds | Worst lane permit p99 | Worst lane including-permit p99 | Max intercompletion gap | First-start / last-completion skew | Consumer request counts by round |
|---|---|---:|---:|---:|---:|---|---|
| `mpmc_endpoint_inflight16_cap16_4p4c` | uninstrumented | 6 | 3.361 [2.114..7.824] (6/6) | 164.632 [114.715..221.895] (6/6) | 170.423 [115.927..246.500] (6/6) | 198.440 [162.714..307.755] (6/6) / 2604.874 [2192.669..2676.292] (6/6) | 334,196,238,232; 234,262,271,233; 290,236,233,241; 203,217,300,280; 249,263,224,264; 277,231,252,240 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | instrumented | 2 | 6.612 [5.420..7.804] (2/2) | 277.954 [205.755..350.154] (2/2) | 280.534 [208.800..352.268] (2/2) | 335.182 [254.736..415.627] (2/2) / 5074.666 [4643.760..5505.571] (2/2) | 249,249,244,258; 279,218,252,251 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | uninstrumented | 6 | 3.732 [2.225..15.048] (6/6) | 240.154 [130.344..340.907] (6/6) | 294.285 [132.838..372.587] (6/6) | 215.303 [179.275..240.680] (6/6) / 2647.684 [2489.373..3136.232] (6/6) | 272,123,305,300; 269,246,246,239; 245,269,259,227; 322,265,93,320; 252,265,256,227; 273,375,228,124 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | instrumented | 2 | 5.971 [4.298..7.644] (2/2) | 204.653 [202.799..206.506] (2/2) | 210.823 [204.181..217.466] (2/2) | 284.967 [249.376..320.559] (2/2) / 4935.780 [4542.110..5329.451] (2/2) | 241,284,236,239; 229,277,242,252 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | uninstrumented | 6 | 2.751 [2.014..4.909] (6/6) | 52.743 [33.483..111.318] (6/6) | 139.041 [70.361..288.529] (6/6) | 5.315 [0.831..19.787] (6/6) / 9423.879 [8521.117..13063.368] (6/6) | 500,500; 500,500; 500,500; 500,500; 500,500; 500,500 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | instrumented | 2 | 3.337 [2.835..3.838] (2/2) | 73.147 [66.805..79.488] (2/2) | 104.826 [88.285..121.367] (2/2) | 19.246 [17.072..21.420] (2/2) / 13434.020 [11915.862..14952.178] (2/2) | 500,500; 499,501 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | uninstrumented | 6 | 2.555 [2.364..3.917] (6/6) | 73.588 [49.142..93.915] (6/6) | 135.153 [63.318..185.627] (6/6) | 50.815 [20.187..88.024] (6/6) / 2897.736 [2754.829..3751.743] (6/6) | 523,477; 505,495; 451,549; 513,487; 522,478; 481,519 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | instrumented | 2 | 5.726 [3.637..7.815] (2/2) | 130.353 [103.824..156.883] (2/2) | 243.996 [146.284..341.709] (2/2) | 109.675 [89.788..129.562] (2/2) / 5084.413 [4963.488..5205.339] (2/2) | 513,487; 490,510 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | uninstrumented | 6 | 4.123 [3.477..5.551] (6/6) | 60.158 [45.095..86.953] (6/6) | 117.053 [58.350..156.282] (6/6) | 41.553 [25.768..63.088] (6/6) / 3240.357 [2652.067..3783.031] (6/6) | 518,482; 504,496; 503,497; 546,454; 488,512; 500,500 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | instrumented | 2 | 3.397 [2.996..3.797] (2/2) | 69.284 [62.186..76.383] (2/2) | 84.713 [70.792..98.634] (2/2) | 52.178 [50.825..53.530] (2/2) / 3785.676 [3635.796..3935.556] (2/2) | 496,504; 518,482 |
| `mpmc_record_inflight16_cap16_4p4c` | uninstrumented | 6 | 10.114 [1.473..30.427] (6/6) | 238.646 [182.521..590.734] (6/6) | 438.700 [206.907..929.577] (6/6) | 214.070 [182.300..462.835] (6/6) / 2854.070 [2128.499..3133.597] (6/6) | 228,381,278,113; 138,340,205,317; 362,336,152,150; 286,147,354,213; 126,208,227,439; 215,240,267,278 |
| `mpmc_record_inflight16_cap16_4p4c` | instrumented | 2 | 7.859 [4.107..11.611] (2/2) | 399.858 [310.992..488.723] (2/2) | 566.600 [317.654..815.545] (2/2) | 304.670 [273.411..335.928] (2/2) / 5413.223 [4618.433..6208.013] (2/2) | 273,241,256,230; 264,233,258,245 |
| `mpmc_record_inflight16_cap2_4p4c` | uninstrumented | 6 | 2.785 [2.514..6.653] (6/6) | 259.399 [157.675..441.185] (6/6) | 318.495 [159.298..442.998] (6/6) | 218.669 [168.374..306.242] (6/6) / 2417.649 [2086.380..2767.373] (6/6) | 286,251,193,270; 402,70,57,471; 322,95,303,280; 285,130,226,359; 219,92,458,231; 276,239,395,90 |
| `mpmc_record_inflight16_cap2_4p4c` | instrumented | 2 | 6.407 [6.111..6.702] (2/2) | 383.618 [370.623..396.612] (2/2) | 448.123 [392.173..504.073] (2/2) | 344.314 [273.782..414.846] (2/2) / 5327.894 [5166.898..5488.890] (2/2) | 264,238,238,260; 322,156,207,315 |
| `mpmc_record_inflight1_cap1_2p2c` | uninstrumented | 6 | 2.705 [2.084..4.378] (6/6) | 47.324 [44.243..85.590] (6/6) | 522.521 [85.850..9004.080] (6/6) | 4.829 [0.010..10.700] (6/6) / 8821.363 [6154.454..10071.295] (6/6) | 500,500; 500,500; 500,500; 500,500; 500,500; 500,500 |
| `mpmc_record_inflight1_cap1_2p2c` | instrumented | 2 | 4.162 [3.546..4.779] (2/2) | 60.879 [52.107..69.650] (2/2) | 5610.207 [746.916..10473.497] (2/2) | 11.261 [6.422..16.100] (2/2) / 11420.025 [9724.767..13115.284] (2/2) | 499,501; 500,500 |
| `mpmc_record_inflight4_cap1_2p2c` | uninstrumented | 6 | 3.993 [2.625..5.170] (6/6) | 93.309 [47.419..149.229] (6/6) | 191.398 [112.691..218.118] (6/6) | 31.709 [21.139..48.741] (6/6) / 3526.367 [3076.551..4212.564] (6/6) | 395,605; 521,479; 511,489; 510,490; 445,555; 464,536 |
| `mpmc_record_inflight4_cap1_2p2c` | instrumented | 2 | 4.604 [4.518..4.689] (2/2) | 90.109 [87.864..92.353] (2/2) | 164.849 [121.227..208.470] (2/2) | 43.041 [27.411..58.670] (2/2) / 4289.994 [4089.314..4490.674] (2/2) | 486,514; 495,505 |
| `mpmc_record_inflight4_cap4_2p2c` | uninstrumented | 6 | 4.107 [3.126..4.769] (6/6) | 64.936 [45.615..95.208] (6/6) | 104.942 [78.947..588.080] (6/6) | 36.068 [25.137..107.661] (6/6) / 3006.289 [2621.099..4467.981] (6/6) | 518,482; 489,511; 490,510; 500,500; 554,446; 551,449 |
| `mpmc_record_inflight4_cap4_2p2c` | instrumented | 2 | 4.288 [2.976..5.600] (2/2) | 72.726 [67.346..78.106] (2/2) | 135.173 [117.329..153.017] (2/2) | 37.675 [27.702..47.649] (2/2) / 3604.798 [3136.703..4072.893] (2/2) | 479,521; 516,484 |

Consumer counts are each actual worker's positive-request count, collected after join outside timing; they are not a uniform-share promise. Progress gaps include the finite fixture's credit contention/scheduling. Different lane operation counts and finite startup/finish affect skews. This is not strict FIFO completion, a starvation bound or a generic scheduler fairness proof. Instrumented fairness is diagnostic and can be perturbed by the private probe overhead.


### Matched protocol/shape endpoint component contrasts

| Case | Control | Case us/op | Control us/op | Difference us/op |
|---|---|---:|---:|---:|
| `mpmc_endpoint_inflight16_cap16_4p4c` | `mpmc_record_inflight16_cap16_4p4c` | 3.532 | 3.957 | -0.424 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `mpmc_record_inflight16_cap2_4p4c` | 3.603 | 3.515 | +0.088 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `mpmc_record_inflight1_cap1_2p2c` | 18.860 | 18.451 | +0.409 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `mpmc_record_inflight4_cap1_2p2c` | 6.240 | 6.744 | -0.504 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `mpmc_record_inflight4_cap4_2p2c` | 6.284 | 5.734 | +0.550 |
| `queue_real_receiver` | `queue_plain_bytes8` | 4.328 | 2.917 | +1.411 |
| `queue_real_sender` | `queue_plain_bytes8` | 5.258 | 2.917 | +2.341 |
| `spsc_endpoint_carried_persistent` | `spsc_record_persistent` | 21.872 | 18.038 | +3.833 |
| `spsc_endpoint_pool4_reply` | `spsc_record_pool4_control` | 22.203 | 16.844 | +5.358 |
| `wait_empty_receiver_endpoint` | `wait_empty_receiver_record` | 35.551 | 33.432 | +2.119 |
| `wait_full_sender_endpoint` | `wait_full_sender_record` | 36.323 | 34.072 | +2.251 |

### Payload-policy controls (not isolated endpoint costs)

| Case | Control | Case us/op | Control us/op | Difference us/op |
|---|---|---:|---:|---:|
| `queue_opaque_hook8` | `queue_plain_bytes8` | 3.874 | 2.917 | +0.957 |
| `queue_packed_hook8` | `queue_plain_bytes8` | 5.019 | 2.917 | +2.102 |
| `spsc_opaque_persistent` | `spsc_record_persistent` | 21.234 | 18.038 | +3.195 |

### Application-protocol contrasts (not matched endpoint components)

| Case | Control | Case us/op | Control us/op | Difference us/op |
|---|---|---:|---:|---:|
| `spsc_endpoint_fresh_reply` | `spsc_endpoint_pool4_reply` | 17.615 | 22.203 | -4.588 |
| `spsc_large64k_endpoint_pool4` | `spsc_large64k_persistent` | 39.268 | 38.577 | +0.692 |

Matched endpoint contrasts retain common field count, capacity, OS producer/consumer counts, in-flight budget and validation/protocol; payload representation, hooks, wrapper allocation and ownership differ together. They do not isolate only retain/release cost. Fresh/pool-four and large pool-four/persistent comparisons change application protocol and are kept in the separate protocol table.

### candidate provenance

| Input | Recorded evidence |
|---|---|
| ABI / SDK / language-server API | `2 / 0.6 / 1 (compile guard)` |
| Claimed source revision (builder-attested, not inferred) | `wake-final-cpp2-24a6a6e77dff36d9` |
| SDK profile | `production` |
| Complete generated-C flags (including optimization / LTO / debug) | `--std=c99 -O3 -Wall -Wno-unused-but-set-variable -Wno-unused-function -fPIC -g1 -flto=auto -ffat-lto-objects -fno-strict-aliasing` |
| Generated-C source-line directives | `True` |
| Full SDK content manifest SHA-256 | `e8b0bbe9d73e20d0272d2e0138bfe675e2215a9037b10ffaf89caf55f0a61eb7` |
| Source hash-map SHA-256 | `22c41ea66484c2f46f982de73e168a6cf39d66808a6d246decfbfffd217d389e` |
| Source probe recipe SHA-256 | `480423cce1d313714b23d59422b5eb6178529df61ae09b4ec57a3f2d5c557b5d` |
| Audited native wait contract | `shared_register_after_yield_prearmed_retirement` |
| Native-wake successful continuation endpoint | `native-await return including helper cleanup` |
| Original builder receipt SHA-256 | `24a6a6e77dff36d9570f76c82ad2a2b6d825eabb8c8456f924a0bea52552203d` |
| Preserved native payload archive SHA-256 | `822b7ebdb3890aaf700faf72e3cc8efa957f426a8fee481138c8fc6df1644f5c` |
| Generated consumer SHA-256 | `5a9e13bbed374169451611b064461c6312e69724328fa8f968140beacbe2a00b` |
| Raw codec calling contract | `native_consuming_slot` |

<details><summary>Exact provider/source/tool/link evidence</summary>

```json
{
  "executable_sha256": {
    "instrumented": "d2e720f74b2cb858bc52775b93aa438c1717426eb6fa758b184d99e64f34bb52",
    "uninstrumented": "5b947f9427c169680c4e70d66409035a4ce7310be920a09584aa0dbd058e9b41"
  },
  "link_evidence": {
    "instrumented": "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/logs/1792362388181640738-link-dependencies-instrumented.json",
    "uninstrumented": "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/logs/1792362388173781498-link-dependencies-uninstrumented.json"
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=bench",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/instrumented/bench.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/instrumented/bench.o.compile.tmp.lua_JqM82w"
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/instrumented/.titan-temporary.tmp.lua_NhvmOO.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/instrumented/.titan-temporary.tmp.lua_NhvmOO.o"
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/instrumented/bench__entrypoint.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/instrumented/bench__entrypoint.o"
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=bench",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/uninstrumented/bench.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/uninstrumented/bench.o.compile.tmp.lua_Unj9l3"
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/uninstrumented/.titan-temporary.tmp.lua_vNlbUP.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/uninstrumented/.titan-temporary.tmp.lua_vNlbUP.o"
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/uninstrumented/bench__entrypoint.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/uninstrumented/bench__entrypoint.o"
      ]
    ],
    "private_provider": [
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.async",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/async.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/async.o.compile.tmp.lua_wg1O1R"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.coroutine",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/coroutine.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/coroutine.o.compile.tmp.lua_I7bv8w"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.fs",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/fs.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/fs.o.compile.tmp.lua_3eJBSl"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.gc",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/gc.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/gc.o.compile.tmp.lua_ujY4He"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.http",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/http/http.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/http/http.o.compile.tmp.lua_M0igYH"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.io",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/io.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/io.o.compile.tmp.lua_xHTvZZ"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.iteration",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/iteration.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/iteration.o.compile.tmp.lua_r4HMyj"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.json",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/json/json.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/json/json.o.compile.tmp.lua_In4Qze"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.lua",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/lua/lua.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/lua/lua.o.compile.tmp.lua_TXE7qS"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.math",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/math.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/math.o.compile.tmp.lua_2a66Qg"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.net",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/net.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/net.o.compile.tmp.lua_y5M3Bh"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.os",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/os.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/os.o.compile.tmp.lua_AZfEv8"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.path",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/path.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/path.o.compile.tmp.lua_AqmqXz"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.peg",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/peg/peg.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/peg/peg.o.compile.tmp.lua_Svajlp"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.protobuf",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/protobuf/protobuf.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/protobuf/protobuf.o.compile.tmp.lua_Dm7xT2"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.reflect",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/reflect.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/reflect.o.compile.tmp.lua_5oVqAC"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.sqlite3",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/sqlite3/sqlite3.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/sqlite3/sqlite3.o.compile.tmp.lua_TC9x2V"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.ssl",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/ssl.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/ssl.o.compile.tmp.lua_iykEc3"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.string",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/string/string.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/string/string.o.compile.tmp.lua_STJ9Zk"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.test",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/test.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/test.o.compile.tmp.lua_XwUMtD"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.thread",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/thread/thread.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/thread/thread.o.compile.tmp.lua_wzyMsm"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.timer",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/timer.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/timer.o.compile.tmp.lua_lsPZvz"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.transfer",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/transfer.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/transfer.o.compile.tmp.lua_Anv81J"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.url",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/url.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/url.o.compile.tmp.lua_NTEVMl"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.uv",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/uv/uv.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/uv/uv.o.compile.tmp.lua_G8Xkbs"
      ],
      [
        "/usr/bin/gcc",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider-source/vendor/lpeglabel",
        "-I/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work",
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
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/include",
        "-I",
        "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/src/lua-5.5.1",
        "-frandom-seed=titan.websocket",
        "-c",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/websocket/websocket.c",
        "-o",
        "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan/websocket/websocket.o.compile.tmp.lua_Yp9CJG"
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
    "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan.a": "4134252b74bc63c27ddba1e5ec69f61dc23e7d40a0b046faaa4d85d7adc497f6",
    "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/work/provider/titan.so": "93e12795cfb6beee79d35e62ad42b684ec57b813d96bc57c8bb3077019ee7eb7"
  },
  "private_source_sha256": {
    "titan/async.titan": "97cc8291941066af373d0bb4952d6c113d8fe454c39126d592f804d3639d4d5e",
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
    "titan/thread/channel.titan": "2ee7a153bf0dcb9255a76394e002013fa1072f12091f05effff83b5143f9ca6a",
    "titan/thread/group.titan": "d0b1c126a3e11e08def25d1673ff8ef22d2a59227f21f44110e7d6af6eb050f0",
    "titan/thread/native.h": "c8a6ec95a0f46cbcd7a0214d17a6dfef3960bc5c4991bfd67f5823bfb37e4ae5",
    "titan/thread/spawn.titan": "1ed880f1273e6efa8c2f1f30a192ab7b9b9c90fa229f57e68f93a5700eeb6319",
    "titan/thread/thread.titan": "2f6a5a69db407379c738b6d1ffc71927c6c98137985cd17832f82651592defbb",
    "titan/timer.titan": "bcbbaf7ca0a83e6305b7c436523bbe938454254b1967a1e2c717417d44e69d1b",
    "titan/transfer.titan": "9560902120aa23dc8a38697b9453b012405652e404db2fb35e849e67778147de",
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
    "attestation": "/tmp/titan-issue252-wake-final-cpp2-v1/BUILD-ATTESTATION.json",
    "attestation_sha256": "2d8ad89ffe7ec45a1e9e4e54d83ed451dce95a4f7dd6264fdd5e068ee9861dd1",
    "checkpoint": "Final combined shared wake, actual OS joins/native retirement, direct cancellation payloads and pre-start Group admission; not a pure wake-only intervention. CPP2 checkpoint only: independent compiler P2 remains open; no claim this is the final delivered compiler or a measured campaign.",
    "commands": "/tmp/titan-issue252-wake-final-cpp2-v1/BUILD-COMMANDS.json",
    "commands_sha256": "36ef3aa2b7f6b700d8c6c198889c986a9f86b791771a18e8ebb057d8f892255d",
    "compiler_patchset": {
      "titan-compiler/coder/module.lua": {
        "after": "c324ee5d2ab0862df7ac3eb5acf90a37da9097cf9764758a1e5bf4b03926201f",
        "before": "65e33d33a0e85b04042725d84b097880c6b16ed5beddabf1539bc72d330d361b"
      },
      "titan-compiler/coder/statements.lua": {
        "after": "d7d735e742116798a696e995455e8392055ea0d4b117fe4c4d2c435cde88b4e4",
        "before": "bd51a4cf5f1039d97fb5d1f6b9b980a871904501578faf9113b8b1d7dfea9a60"
      }
    },
    "input_provenance": "/tmp/titan-issue252-wake-final-cpp2-v1/INPUT-PROVENANCE.json",
    "input_provenance_sha256": "ce13f89642b01deef738d4de50895ce59a9955e7a59f7beb17d9cfa2ec316fa9",
    "installed_compiler_patch_sha256": {
      "share/lua/5.5/titan-compiler/coder/module.lua": "c324ee5d2ab0862df7ac3eb5acf90a37da9097cf9764758a1e5bf4b03926201f",
      "share/lua/5.5/titan-compiler/coder/statements.lua": "d7d735e742116798a696e995455e8392055ea0d4b117fe4c4d2c435cde88b4e4"
    },
    "native_archive_reuse_sha256": {
      "lib/libbacktrace.a": "e134dff116b6441f9171bb6182897a1b9ddd87caf644b3d3b6a125ec4920fe01",
      "lib/liblua.a": "7decdb6e81469ca27cd6f8bc9f2eef0830c77dd6c5bc15cefc8a89fe1258f721",
      "lib/luarocks/rocks-5.5/titan/0.6.0-1/titan-sdk/lib/libbacktrace.a": "e134dff116b6441f9171bb6182897a1b9ddd87caf644b3d3b6a125ec4920fe01",
      "lib/luarocks/rocks-5.5/titan/0.6.0-1/titan-sdk/lib/liblua.a": "7decdb6e81469ca27cd6f8bc9f2eef0830c77dd6c5bc15cefc8a89fe1258f721",
      "lib/luarocks/rocks-5.5/titan/0.6.0-1/titan-sdk/lib/titan/0.6/libtitan.a": "f8123ef431b4a854bc1473d1f35296a39a3159d85a25303e60c6dbb7d5f8152f",
      "lib/titan/0.6/libtitan.a": "f8123ef431b4a854bc1473d1f35296a39a3159d85a25303e60c6dbb7d5f8152f"
    },
    "native_policy_provenance": "Prepared prewake CPP2 source/native-output/Lua SDK seed; same captured production/system OpenSSL /usr/bin GCC, ar, ranlib and pkg-config environment. Actual six archives and full SDK UV/llhttp/SQLite header replay reverified; no historical SDK or source modified.",
    "source_after": "/tmp/titan-issue252-wake-final-cpp2-v1/SOURCE-AFTER.json",
    "source_before": "/tmp/titan-issue252-wake-final-cpp2-v1/SOURCE-BEFORE.json"
  },
  "provider_files": {
    "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/bin/lua": "4ff90fc0bccfffb89db1198b3807b2731b1f95686967a42d13f9b78f6f5561ee",
    "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc": "567bdf8984e6631a199b3feae238483a632af62aa9239a5864a93fb074ce03b4",
    "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/lib/titan/0.6/libtitan.a": "f8123ef431b4a854bc1473d1f35296a39a3159d85a25303e60c6dbb7d5f8152f",
    "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/lib/titan/0.6/titan.a": "3e67b718e3b5a8b90aad99a7afa9986f3c0ab7fdb789c372bba67f2f4ac53894",
    "/tmp/titan-issue252-wake-final-cpp2-v1/sdk/lib/titan/0.6/titan.so": "c476b2fba29936e052f45f1bfd3b291ac2c173245fcca9d8e4f35085313935b1"
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
    "private_provider_compile_receipt": "/tmp/titan-issue252-rtt-final-cpp2-v1/wake/logs/1792361742836603640-compile-private-full-provider.json",
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
    "titan/async.titan": "5c2343c2f2209379e4e548527533abff04840c5c3f373982a5eb12e7e2e2dcdc",
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
    "titan/thread/channel.titan": "1ac5b7e1a5fd7dc5349eb8c4742bc1564d25100214dd7abf71118929f4ff8655",
    "titan/thread/group.titan": "d0b1c126a3e11e08def25d1673ff8ef22d2a59227f21f44110e7d6af6eb050f0",
    "titan/thread/native.h": "c8a6ec95a0f46cbcd7a0214d17a6dfef3960bc5c4991bfd67f5823bfb37e4ae5",
    "titan/thread/spawn.titan": "d06270201455d53cb292d85ebff8ca11de20f4a489e23f58303a2f5776d0e72a",
    "titan/thread/thread.titan": "9f281a29c1408adf93ce29b716d79b581c10e994205946d8afb5cfc2da5d3a2b",
    "titan/timer.titan": "bcbbaf7ca0a83e6305b7c436523bbe938454254b1967a1e2c717417d44e69d1b",
    "titan/transfer.titan": "9560902120aa23dc8a38697b9453b012405652e404db2fb35e849e67778147de",
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
| `call_control` | `same_state` | 6 / 60000 | 0.055 [0.054..0.080] | 0.030/0.030/0.031 | 18077701.7 | 9457.4 | 0.044 | 1.0 |
| `churn_cancel_parked_waiters` | `cancel_churn` | 6 / 3000 | 85.843 [76.812..87.394] | 56.606/159.383/655.656 | 11649.2 | 9207.5 | 3.286 | 72.7 |
| `churn_close_parked_receivers` | `close_churn` | 6 / 3000 | 27.701 [25.467..35.216] | 16.871/48.124/318.991 | 36106.4 | 9015.3 | 9.080 | 70.8 |
| `churn_close_parked_senders` | `close_churn` | 6 / 3000 | 42.008 [40.728..46.841] | 28.082/73.106/393.546 | 23806.3 | 8166.4 | 6.968 | 64.2 |
| `closure_roundtrip_cap0` | `same_state` | 6 / 6000 | 3.036 [2.856..4.407] | 2.901/4.213/6.658 | 329450.3 | 9007.8 | 1.627 | 1.4 |
| `closure_roundtrip_cap1` | `same_state` | 6 / 6000 | 5.644 [5.480..6.466] | 4.348/8.121/48.130 | 177182.6 | 9061.7 | 1.159 | 1.4 |
| `closure_roundtrip_cap64` | `same_state` | 6 / 6000 | 152.262 [146.687..166.827] | 86.332/640.297/885.816 | 6569.5 | 9515.3 | 0.713 | 2.4 |
| `closure_roundtrip_cap8` | `same_state` | 6 / 6000 | 27.183 [23.368..46.350] | 13.721/113.367/222.150 | 36865.1 | 9589.0 | 0.613 | 2.8 |
| `closure_roundtrip_complex_sig` | `same_state` | 6 / 6000 | 6.462 [5.931..9.896] | 4.799/10.665/58.659 | 154757.4 | 10095.2 | 1.383 | 2.7 |
| `codec_large64k_decode` | `same_state` | 6 / 1536 | 7.656 [7.029..8.327] | 3.316/19.226/43.386 | 130650.3 | 8833.0 | 2.454 | 1.9 |
| `codec_large64k_encode` | `same_state` | 6 / 1536 | 7.668 [7.008..14.729] | 3.417/18.700/48.516 | 130441.4 | 8308.7 | 2.368 | 1.9 |
| `codec_large64k_transfer_roundtrip` | `same_state` | 6 / 1536 | 10.497 [10.036..20.390] | 7.284/24.691/82.860 | 95275.2 | 10120.6 | 2.745 | 2.1 |
| `codec_scalar_roundtrip` | `same_state` | 6 / 30000 | 0.512 [0.477..0.717] | 0.376/1.092/1.397 | 1958134.9 | 9226.0 | 0.258 | 1.1 |
| `codec_small_decode` | `same_state` | 6 / 30000 | 1.061 [1.028..1.542] | 0.626/1.492/3.627 | 943139.9 | 8158.3 | 0.184 | 2.0 |
| `codec_small_encode` | `same_state` | 6 / 30000 | 0.551 [0.449..0.681] | 0.461/1.062/1.442 | 1837120.1 | 9528.7 | 0.238 | 1.5 |
| `codec_small_transfer_roundtrip` | `same_state` | 6 / 30000 | 2.814 [2.502..3.772] | 1.788/3.562/21.946 | 355415.6 | 9240.7 | 0.306 | 2.4 |
| `codec_wide16_decode` | `same_state` | 6 / 30000 | 2.517 [2.469..4.089] | 1.643/3.381/41.703 | 397359.1 | 9035.3 | 0.170 | 2.2 |
| `codec_wide16_encode` | `same_state` | 6 / 30000 | 1.111 [1.036..1.662] | 0.962/1.643/2.570 | 900425.7 | 9425.5 | 0.187 | 1.4 |
| `codec_wide16_transfer_roundtrip` | `same_state` | 6 / 30000 | 5.014 [4.652..8.569] | 3.371/8.205/51.382 | 199461.4 | 9009.2 | 0.186 | 2.6 |
| `inspect_function` | `same_state` | 6 / 6000 | 2.288 [2.010..3.158] | 2.094/3.026/6.532 | 438749.3 | 9367.4 | 1.249 | 1.5 |
| `inspect_record` | `same_state` | 6 / 30000 | 0.195 [0.159..0.238] | 0.136/0.215/0.712 | 5202707.6 | 8785.9 | 0.141 | 0.9 |
| `join_cleanup_cancelled_task` | `cleanup_join` | 6 / 600 | 43898.007 [38978.274..47381.487] | 47127.334/49544.121/50374.924 | 22.8 | 10171.1 | 46.633 | 72.1 |
| `join_ordinary` | `ordinary_join` | 6 / 600 | 6969.387 [6854.850..7423.617] | 6932.583/8001.882/8227.198 | 143.5 | 9181.8 | 29.246 | 60.0 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | `pool_16_reply` | 6 / 6000 | 3.763 [3.078..4.411] | 43.361/86.546/168.019 | 266966.2 | 9640.1 | 2.060 | 6793.7 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `pool_16_reply` | 6 / 6000 | 3.812 [3.608..6.640] | 39.474/107.126/221.339 | 262352.1 | 9560.5 | 1.998 | 6933.3 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `pool_four_reply` | 6 / 6000 | 20.544 [19.875..20.849] | 16.806/27.096/56.266 | 48679.6 | 8696.1 | 1.405 | 5208.4 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `pool_four_reply` | 6 / 6000 | 6.512 [5.812..8.157] | 21.099/39.779/53.851 | 153582.5 | 9046.2 | 1.158 | 5358.6 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `pool_four_reply` | 6 / 6000 | 6.488 [5.708..6.834] | 21.410/33.948/50.675 | 154211.9 | 9252.5 | 1.459 | 5589.7 |
| `mpmc_record_inflight16_cap16_4p4c` | `pool_16_reply` | 6 / 6000 | 4.364 [3.627..5.232] | 44.313/161.242/278.336 | 231617.4 | 9146.7 | 2.239 | 5465.9 |
| `mpmc_record_inflight16_cap2_4p4c` | `pool_16_reply` | 6 / 6000 | 4.848 [4.272..6.321] | 40.882/190.161/327.337 | 206338.7 | 8917.2 | 1.842 | 5736.6 |
| `mpmc_record_inflight1_cap1_2p2c` | `pool_four_reply` | 6 / 6000 | 17.868 [17.264..19.254] | 14.819/22.537/46.267 | 55970.8 | 8239.0 | 1.383 | 4485.3 |
| `mpmc_record_inflight4_cap1_2p2c` | `pool_four_reply` | 6 / 6000 | 5.805 [5.608..6.449] | 18.855/35.081/61.921 | 172294.4 | 7657.0 | 1.370 | 5809.4 |
| `mpmc_record_inflight4_cap4_2p2c` | `pool_four_reply` | 6 / 6000 | 5.822 [5.196..6.497] | 19.121/30.853/54.537 | 171781.4 | 9490.1 | 1.105 | 4909.5 |
| `overhead_control` | `same_state` | 6 / 60000 | 0.068 [0.067..0.100] | 0.040/0.050/0.055 | 14619204.2 | 8514.5 | 0.044 | 0.7 |
| `queue_opaque_hook8` | `same_state_queue` | 6 / 30000 | 4.540 [3.537..6.156] | 2.665/6.277/51.877 | 223069.7 | 9338.8 | 0.747 | 106.4 |
| `queue_packed_hook8` | `same_state_queue` | 6 / 30000 | 6.812 [4.727..9.878] | 3.912/13.765/87.954 | 156585.7 | 9373.6 | 0.356 | 96.2 |
| `queue_plain_bytes8` | `same_state_queue` | 6 / 30000 | 3.000 [2.717..4.443] | 1.869/3.352/26.424 | 333697.1 | 8863.6 | 0.309 | 82.6 |
| `queue_real_receiver` | `same_state_queue` | 6 / 30000 | 4.443 [3.779..9.014] | 2.835/7.003/46.617 | 225083.7 | 9409.4 | 0.447 | 89.3 |
| `queue_real_sender` | `same_state_queue` | 6 / 30000 | 4.672 [3.884..6.374] | 2.785/6.372/45.996 | 214350.5 | 9634.6 | 0.557 | 86.6 |
| `sender_clone` | `same_state_queue` | 6 / 30000 | 0.200 [0.190..0.540] | 0.161/0.220/0.381 | 4995149.4 | 9180.3 | 0.173 | 30.2 |
| `spsc_endpoint_carried_persistent` | `persistent_reply` | 6 / 6000 | 23.347 [20.026..27.532] | 16.606/49.022/133.319 | 42873.8 | 9370.7 | 1.989 | 1857.2 |
| `spsc_endpoint_fresh_reply` | `fresh_reply` | 6 / 3000 | 16.794 [12.091..19.361] | 15.979/20.223/30.261 | 59614.4 | 8592.4 | 4.698 | 1847.3 |
| `spsc_endpoint_pool4_reply` | `pool_four_reply` | 6 / 6000 | 21.808 [15.849..22.941] | 16.125/45.605/116.918 | 45858.7 | 9189.7 | 1.803 | 1571.6 |
| `spsc_large64k_endpoint_pool4` | `pool_four_reply` | 6 / 1536 | 37.974 [34.520..51.533] | 29.981/76.293/199.322 | 26333.5 | 9231.0 | 5.936 | 1216.4 |
| `spsc_large64k_persistent` | `persistent_reply` | 6 / 1536 | 35.857 [22.381..49.078] | 28.493/70.452/181.144 | 27898.8 | 8455.7 | 6.241 | 1067.5 |
| `spsc_opaque_persistent` | `persistent_reply` | 6 / 6000 | 19.826 [13.864..22.446] | 15.855/37.641/104.495 | 50444.1 | 9233.3 | 1.234 | 1290.9 |
| `spsc_record_persistent` | `persistent_reply` | 6 / 6000 | 15.862 [11.400..16.480] | 14.232/22.267/48.425 | 63044.3 | 8640.7 | 2.810 | 2083.7 |
| `spsc_record_pool4_control` | `pool_four_reply` | 6 / 6000 | 14.587 [11.741..23.480] | 12.353/24.376/55.569 | 69448.6 | 8696.9 | 2.561 | 1943.5 |
| `spsc_scalar_persistent` | `persistent_reply` | 6 / 6000 | 7.723 [6.723..8.638] | 7.153/10.254/17.678 | 129494.1 | 8955.9 | 2.448 | 1789.2 |
| `wait_empty_receiver_endpoint` | `directed_empty_wait` | 6 / 3000 | 32.138 [24.171..40.194] | 23.264/62.291/274.553 | 31262.9 | 8559.8 | 5.017 | 1547.8 |
| `wait_empty_receiver_record` | `directed_empty_wait` | 6 / 3000 | 34.675 [26.641..41.675] | 20.413/72.500/361.962 | 29014.3 | 8402.0 | 4.466 | 1517.5 |
| `wait_full_sender_endpoint` | `directed_full_wait` | 6 / 3000 | 37.592 [36.167..44.947] | 26.038/79.203/324.156 | 26616.8 | 8682.2 | 8.432 | 2421.8 |
| `wait_full_sender_record` | `directed_full_wait` | 6 / 3000 | 38.745 [37.046..39.425] | 24.185/93.835/374.289 | 25817.2 | 9111.6 | 7.351 | 2092.2 |

RTT columns are medians of per-round percentiles, not pooled percentiles. Directed full-sender samples are admission/previous-packet release acknowledgements, not processing RTTs for the newly admitted request. Churn includes fresh resource/state creation.

### Exact native branch counts (representative instrumented round)

Counters/per-op traffic select the actual upper-median body-time round; all instrumented rounds remain in the summary JSON. Counts are branch events within the body window, including worker request receives and protocol-control channels. A wait can begin before the window. Fast successes are successful first readiness checks, not post-suspension retry successes. Closed outcomes are never counted as successful fast paths/rechecks. Slow attempts are failed ready checks entering registration; native suspensions, successful registration rechecks, selected waiter notification attempts and nominal CancellationReason errors are separate events.

| Case | Fast | Slow | Recheck OK | Suspends | Ordinary / cleanup join suspends | Notify | Cancel | Async init / public close requests |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `call_control` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `churn_cancel_parked_waiters` | 500 | 1000 | 0 | 1000 | 0 / 0 | 0 | 1000 | 0 / 0 |
| `churn_close_parked_receivers` | 0 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 0 / 0 |
| `churn_close_parked_senders` | 500 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 0 / 0 |
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
| `join_cleanup_cancelled_task` | 300 | 600 | 0 | 600 | 100 / 100 | 400 | 200 | 300 / 200 |
| `join_ordinary` | 200 | 300 | 1 | 299 | 100 / 0 | 299 | 0 | 300 / 200 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 4381 | 2670 | 303 | 2367 | 0 / 0 | 2427 | 0 | 0 / 0 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 4294 | 2766 | 369 | 2397 | 0 / 0 | 2457 | 0 | 0 / 0 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 4002 | 2913 | 3 | 2910 | 0 / 0 | 2910 | 0 | 0 / 0 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 4128 | 2630 | 410 | 2220 | 0 / 0 | 2226 | 0 | 0 / 0 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 4248 | 2436 | 248 | 2188 | 0 / 0 | 2194 | 0 | 0 / 0 |
| `mpmc_record_inflight16_cap16_4p4c` | 4964 | 1833 | 21 | 1812 | 0 / 0 | 1872 | 0 | 0 / 0 |
| `mpmc_record_inflight16_cap2_4p4c` | 4474 | 2562 | 278 | 2283 | 0 / 0 | 2344 | 0 | 0 / 0 |
| `mpmc_record_inflight1_cap1_2p2c` | 4002 | 2975 | 0 | 2975 | 0 / 0 | 2975 | 0 | 0 / 0 |
| `mpmc_record_inflight4_cap1_2p2c` | 4123 | 2649 | 374 | 2275 | 0 / 0 | 2281 | 0 | 0 / 0 |
| `mpmc_record_inflight4_cap4_2p2c` | 4289 | 2419 | 279 | 2140 | 0 / 0 | 2146 | 0 | 0 / 0 |
| `overhead_control` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_opaque_hook8` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_packed_hook8` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_plain_bytes8` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_real_receiver` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `queue_real_sender` | 10000 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `sender_clone` | 0 | 0 | 0 | 0 | 0 / 0 | 0 | 0 | 0 / 0 |
| `spsc_endpoint_carried_persistent` | 2000 | 2000 | 23 | 1977 | 0 / 0 | 1977 | 0 | 0 / 0 |
| `spsc_endpoint_fresh_reply` | 1000 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 0 / 0 |
| `spsc_endpoint_pool4_reply` | 2000 | 2000 | 25 | 1975 | 0 / 0 | 1975 | 0 | 0 / 0 |
| `spsc_large64k_endpoint_pool4` | 512 | 512 | 0 | 512 | 0 / 0 | 512 | 0 | 0 / 0 |
| `spsc_large64k_persistent` | 512 | 512 | 0 | 512 | 0 / 0 | 512 | 0 | 0 / 0 |
| `spsc_opaque_persistent` | 2000 | 2000 | 23 | 1977 | 0 / 0 | 1977 | 0 | 0 / 0 |
| `spsc_record_persistent` | 2000 | 2000 | 6 | 1994 | 0 / 0 | 1994 | 0 | 0 / 0 |
| `spsc_record_pool4_control` | 2000 | 2000 | 8 | 1992 | 0 / 0 | 1992 | 0 | 0 / 0 |
| `spsc_scalar_persistent` | 2000 | 2000 | 53 | 1947 | 0 / 0 | 1947 | 0 | 0 / 0 |
| `wait_empty_receiver_endpoint` | 1000 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 0 / 0 |
| `wait_empty_receiver_record` | 1000 | 1000 | 0 | 1000 | 0 / 0 | 1000 | 0 | 0 / 0 |
| `wait_full_sender_endpoint` | 1607 | 1393 | 234 | 1159 | 0 / 0 | 1159 | 0 | 0 / 0 |
| `wait_full_sender_record` | 1776 | 1224 | 184 | 1040 | 0 / 0 | 1040 | 0 | 0 / 0 |

### Native async handle retirement (representative instrumented round)

| Case | Whole-case async init | Public close requests | Terminal close callbacks | Async retirements at successful loop close | Successful / attempted loop closes |
|---|---:|---:|---:|---:|---:|
| `call_control` | 0 | 0 | 0 | 0 | 0 / 0 |
| `churn_cancel_parked_waiters` | 2 | 1 | 1 | 1 | 1 / 1 |
| `churn_close_parked_receivers` | 2 | 1 | 1 | 1 | 1 / 1 |
| `churn_close_parked_senders` | 2 | 1 | 1 | 1 | 1 / 1 |
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
| `join_cleanup_cancelled_task` | 326 | 217 | 217 | 109 | 109 / 109 |
| `join_ordinary` | 326 | 217 | 217 | 109 | 109 / 109 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 26 | 17 | 17 | 9 | 9 / 9 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 26 | 17 | 17 | 9 | 9 / 9 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 14 | 9 | 9 | 5 | 5 / 5 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 14 | 9 | 9 | 5 | 5 / 5 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 14 | 9 | 9 | 5 | 5 / 5 |
| `mpmc_record_inflight16_cap16_4p4c` | 26 | 17 | 17 | 9 | 9 / 9 |
| `mpmc_record_inflight16_cap2_4p4c` | 26 | 17 | 17 | 9 | 9 / 9 |
| `mpmc_record_inflight1_cap1_2p2c` | 14 | 9 | 9 | 5 | 5 / 5 |
| `mpmc_record_inflight4_cap1_2p2c` | 14 | 9 | 9 | 5 | 5 / 5 |
| `mpmc_record_inflight4_cap4_2p2c` | 14 | 9 | 9 | 5 | 5 / 5 |
| `overhead_control` | 0 | 0 | 0 | 0 | 0 / 0 |
| `queue_opaque_hook8` | 1 | 0 | 0 | 1 | 1 / 1 |
| `queue_packed_hook8` | 1 | 0 | 0 | 1 | 1 / 1 |
| `queue_plain_bytes8` | 1 | 0 | 0 | 1 | 1 / 1 |
| `queue_real_receiver` | 1 | 0 | 0 | 1 | 1 / 1 |
| `queue_real_sender` | 1 | 0 | 0 | 1 | 1 / 1 |
| `sender_clone` | 1 | 0 | 0 | 1 | 1 / 1 |
| `spsc_endpoint_carried_persistent` | 5 | 3 | 3 | 2 | 2 / 2 |
| `spsc_endpoint_fresh_reply` | 5 | 3 | 3 | 2 | 2 / 2 |
| `spsc_endpoint_pool4_reply` | 5 | 3 | 3 | 2 | 2 / 2 |
| `spsc_large64k_endpoint_pool4` | 5 | 3 | 3 | 2 | 2 / 2 |
| `spsc_large64k_persistent` | 5 | 3 | 3 | 2 | 2 / 2 |
| `spsc_opaque_persistent` | 5 | 3 | 3 | 2 | 2 / 2 |
| `spsc_record_persistent` | 5 | 3 | 3 | 2 | 2 / 2 |
| `spsc_record_pool4_control` | 5 | 3 | 3 | 2 | 2 / 2 |
| `spsc_scalar_persistent` | 5 | 3 | 3 | 2 | 2 / 2 |
| `wait_empty_receiver_endpoint` | 5 | 3 | 3 | 2 | 2 / 2 |
| `wait_empty_receiver_record` | 5 | 3 | 3 | 2 | 2 / 2 |
| `wait_full_sender_endpoint` | 5 | 3 | 3 | 2 | 2 / 2 |
| `wait_full_sender_record` | 5 | 3 | 3 | 2 | 2 / 2 |

Whole-case counters start at the setup snapshot after cold first use; identities are tracked from process birth, including cold loops. Libuv initializes loop-internal async handles through uv_async_init but retires them directly during successful uv_loop_close. Those retirements are not fabricated public close requests or callbacks. A busy/failed loop close retires no identity; active_async_handles remains the actual unretired registry count and must be zero. Real UV allocation traffic is not suppressed.


### Allocation and observed copy traffic

| Case | Lua allocs / requested B per op | Native allocs / requested B per op | Interposed copy B/op (outside / inside Lua allocator) | Analytical reference B/op (not wire/copy bytes) |
|---|---:|---:|---:|---:|
| `call_control` | 0.00 / 0.0 | 0.00 / 0.0 | 0.0 (0.0 / 0.0) | 0 |
| `churn_cancel_parked_waiters` | 92.04 / 26080.1 | 10.00 / 688.0 | 10446.3 (10446.3 / 0.0) | 0 |
| `churn_close_parked_receivers` | 69.05 / 17529.0 | 5.00 / 280.0 | 47.6 (47.6 / 0.0) | 0 |
| `churn_close_parked_senders` | 76.01 / 19405.0 | 8.00 / 664.0 | 2440.7 (2440.7 / 0.0) | 0 |
| `closure_roundtrip_cap0` | 54.01 / 3147.4 | 2.00 / 384.0 | 132.0 (132.0 / 0.0) | 0 |
| `closure_roundtrip_cap1` | 106.01 / 6004.5 | 2.00 / 384.0 | 293.0 (293.0 / 0.0) | 0 |
| `closure_roundtrip_cap64` | 3038.06 / 189086.8 | 4.00 / 1920.0 | 12065.0 (12065.0 / 0.0) | 0 |
| `closure_roundtrip_cap8` | 444.02 / 26332.0 | 2.00 / 384.0 | 1532.0 (1532.0 / 0.0) | 0 |
| `closure_roundtrip_complex_sig` | 106.01 / 6004.7 | 2.00 / 384.0 | 293.0 (293.0 / 0.0) | 0 |
| `codec_large64k_decode` | 16.02 / 66349.6 | 0.00 / 0.0 | 65562.0 (65562.0 / 0.0) | 65540 |
| `codec_large64k_encode` | 7.02 / 65953.6 | 2.00 / 131136.0 | 131076.0 (131076.0 / 0.0) | 65540 |
| `codec_large64k_transfer_roundtrip` | 27.04 / 67311.0 | 3.00 / 131456.0 | 131113.0 (131113.0 / 0.0) | 65540 |
| `codec_scalar_roundtrip` | 4.00 / 512.0 | 1.00 / 128.0 | 0.0 (0.0 / 0.0) | 8 |
| `codec_small_decode` | 21.00 / 1049.0 | 0.00 / 0.0 | 83.0 (83.0 / 0.0) | 11 |
| `codec_small_encode` | 6.00 / 380.0 | 1.00 / 64.0 | 7.0 (7.0 / 0.0) | 11 |
| `codec_small_transfer_roundtrip` | 32.00 / 2009.1 | 2.00 / 384.0 | 106.0 (106.0 / 0.0) | 11 |
| `codec_wide16_decode` | 44.00 / 3805.0 | 0.00 / 0.0 | 749.0 (749.0 / 0.0) | 33 |
| `codec_wide16_encode` | 6.00 / 380.0 | 1.00 / 64.0 | 0.0 (0.0 / 0.0) | 33 |
| `codec_wide16_transfer_roundtrip` | 55.00 / 4765.2 | 2.00 / 384.0 | 764.0 (764.0 / 0.0) | 33 |
| `inspect_function` | 50.01 / 2376.4 | 0.00 / 0.0 | 80.0 (80.0 / 0.0) | 0 |
| `inspect_record` | 2.00 / 172.0 | 0.00 / 0.0 | 0.0 (0.0 / 0.0) | 0 |
| `join_cleanup_cancelled_task` | 24847.77 / 4031021.9 | 33.00 / 3762.0 | 4966232.7 (4966232.7 / 0.0) | 0 |
| `join_ordinary` | 24672.71 / 4003511.5 | 25.00 / 3144.0 | 1650435.6 (1650435.6 / 0.0) | 0 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 110.73 / 8458.6 | 8.74 / 1171.6 | 265.2 (265.2 / 0.0) | 0 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 111.53 / 8559.5 | 8.83 / 1177.7 | 265.3 (265.3 / 0.0) | 0 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 112.27 / 8636.3 | 8.92 / 1178.9 | 265.0 (265.0 / 0.0) | 0 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 109.46 / 8353.1 | 8.64 / 1161.6 | 265.1 (265.1 / 0.0) | 0 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 108.06 / 8176.9 | 8.45 / 1149.2 | 265.1 (265.1 / 0.0) | 0 |
| `mpmc_record_inflight16_cap16_4p4c` | 94.33 / 6984.5 | 6.90 / 1022.0 | 265.3 (265.3 / 0.0) | 0 |
| `mpmc_record_inflight16_cap2_4p4c` | 100.03 / 7704.6 | 7.63 / 1068.6 | 265.3 (265.3 / 0.0) | 0 |
| `mpmc_record_inflight1_cap1_2p2c` | 103.82 / 8000.8 | 7.98 / 1086.9 | 265.0 (265.0 / 0.0) | 0 |
| `mpmc_record_inflight4_cap1_2p2c` | 100.83 / 7684.5 | 7.66 / 1066.8 | 265.0 (265.0 / 0.0) | 0 |
| `mpmc_record_inflight4_cap4_2p2c` | 98.88 / 7461.6 | 7.43 / 1052.1 | 265.0 (265.0 / 0.0) | 0 |
| `overhead_control` | 0.00 / 0.0 | 0.00 / 0.0 | 0.0 (0.0 / 0.0) | 0 |
| `queue_opaque_hook8` | 44.00 / 2865.1 | 2.00 / 384.0 | 139.0 (139.0 / 0.0) | 21 |
| `queue_packed_hook8` | 65.00 / 3973.2 | 2.00 / 384.0 | 196.0 (196.0 / 0.0) | 21 |
| `queue_plain_bytes8` | 36.00 / 2273.1 | 2.00 / 384.0 | 139.0 (139.0 / 0.0) | 21 |
| `queue_real_receiver` | 45.00 / 2969.1 | 3.00 / 480.0 | 138.0 (138.0 / 0.0) | 21 |
| `queue_real_sender` | 45.00 / 2969.1 | 3.00 / 480.0 | 136.0 (136.0 / 0.0) | 21 |
| `sender_clone` | 2.00 / 168.0 | 0.00 / 0.0 | 0.0 (0.0 / 0.0) | 21 |
| `spsc_endpoint_carried_persistent` | 99.02 / 7186.9 | 7.00 / 992.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_endpoint_fresh_reply` | 103.03 / 7523.5 | 10.00 / 1144.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_endpoint_pool4_reply` | 99.02 / 7186.9 | 7.00 / 992.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_large64k_endpoint_pool4` | 100.08 / 72758.6 | 8.00 / 132064.0 | 131332.0 (131332.0 / 0.0) | 65565 |
| `spsc_large64k_persistent` | 91.06 / 72061.9 | 7.00 / 131968.0 | 131330.0 (131330.0 / 0.0) | 65565 |
| `spsc_opaque_persistent` | 98.02 / 7082.9 | 6.00 / 896.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_record_persistent` | 90.01 / 6490.5 | 6.00 / 896.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_record_pool4_control` | 90.01 / 6490.5 | 6.00 / 896.0 | 265.0 (265.0 / 0.0) | 29 |
| `spsc_scalar_persistent` | 28.01 / 3064.5 | 4.00 / 384.0 | 0.0 (0.0 / 0.0) | 16 |
| `wait_empty_receiver_endpoint` | 97.04 / 16812.1 | 6.00 / 736.0 | 169.3 (169.3 / 0.0) | 29 |
| `wait_empty_receiver_record` | 87.04 / 16052.5 | 5.00 / 640.0 | 169.3 (169.3 / 0.0) | 29 |
| `wait_full_sender_endpoint` | 136.13 / 19684.3 | 8.79 / 1170.3 | 295.3 (295.3 / 0.0) | 29 |
| `wait_full_sender_record` | 122.08 / 15248.5 | 7.45 / 1052.7 | 295.3 (295.3 / 0.0) | 29 |

Lua allocator requests include state birth and terminal close. Only allocations made inside the underlying Lua allocator are excluded from native traffic; real UV allocations are not suppressed. Copy counts cover interposed memcpy **and memmove** calls, not inlined copies, scalar stores or libc-internal copying. Actual total wire bytes are unavailable; the analytical reference can use a different payload/ID and is not presented as measured transfer traffic.

### Lifecycle and post-retirement evidence (all instrumented rounds)

| Case | Rounds | Channels delta range | Controls delta range | Active worker range | Lua state delta / active async handles / pending wait probes | Observed native block / usable B net ranges | Host Lua net B range | Checksums / lifecycle |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| `call_control` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `churn_cancel_parked_waiters` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 104.0..104.0 | valid |
| `churn_close_parked_receivers` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 3.0..3.0 | valid |
| `churn_close_parked_senders` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 104.0..104.0 | valid |
| `closure_roundtrip_cap0` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8545.0 | valid |
| `closure_roundtrip_cap1` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8609.0 | valid |
| `closure_roundtrip_cap64` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8545.0 | valid |
| `closure_roundtrip_cap8` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `closure_roundtrip_complex_sig` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `codec_large64k_decode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `codec_large64k_encode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `codec_large64k_transfer_roundtrip` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8745.0..8809.0 | valid |
| `codec_scalar_roundtrip` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8545.0 | valid |
| `codec_small_decode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `codec_small_encode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8545.0 | valid |
| `codec_small_transfer_roundtrip` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8809.0..8809.0 | valid |
| `codec_wide16_decode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8609.0 | valid |
| `codec_wide16_encode` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8609.0 | valid |
| `codec_wide16_transfer_roundtrip` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8809.0..8809.0 | valid |
| `inspect_function` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8609.0 | valid |
| `inspect_record` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8545.0..8609.0 | valid |
| `join_cleanup_cancelled_task` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 104.0..104.0 | valid |
| `join_ordinary` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | -61.0..-61.0 | valid |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7484.0..7548.0 | valid |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7484.0..7548.0 | valid |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7548.0..7548.0 | valid |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7548.0..7548.0 | valid |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 7484.0..7548.0 | valid |
| `mpmc_record_inflight16_cap16_4p4c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 9699.0..9763.0 | valid |
| `mpmc_record_inflight16_cap2_4p4c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 9763.0..9763.0 | valid |
| `mpmc_record_inflight1_cap1_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 9763.0..9763.0 | valid |
| `mpmc_record_inflight4_cap1_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 9699.0..9763.0 | valid |
| `mpmc_record_inflight4_cap4_2p2c` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 9699.0..9699.0 | valid |
| `overhead_control` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 8609.0..8609.0 | valid |
| `queue_opaque_hook8` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 5574.0..5574.0 | valid |
| `queue_packed_hook8` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 5574.0..5638.0 | valid |
| `queue_plain_bytes8` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | -19.0..45.0 | valid |
| `queue_real_receiver` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2358.0..2422.0 | valid |
| `queue_real_sender` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2422.0..2422.0 | valid |
| `sender_clone` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | -71.0..-71.0 | valid |
| `spsc_endpoint_carried_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2395.0..2395.0 | valid |
| `spsc_endpoint_fresh_reply` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2331.0..2395.0 | valid |
| `spsc_endpoint_pool4_reply` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2331.0..2395.0 | valid |
| `spsc_large64k_endpoint_pool4` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2331.0..2395.0 | valid |
| `spsc_large64k_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2023.0..2087.0 | valid |
| `spsc_opaque_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 5547.0..5611.0 | valid |
| `spsc_record_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | -94.0..-30.0 | valid |
| `spsc_record_pool4_control` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2197.0..2197.0 | valid |
| `spsc_scalar_persistent` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | -30.0..-30.0 | valid |
| `wait_empty_receiver_endpoint` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2391.0..2455.0 | valid |
| `wait_empty_receiver_record` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 98.0..162.0 | valid |
| `wait_full_sender_endpoint` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | 2428.0..2428.0 | valid |
| `wait_full_sender_record` | 2 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 | 0.0..0.0 / 0.0..0.0 / 0.0..0.0 | 0.0..0.0 / 0.0..0.0 | -61.0..3.0 | valid |

Channel/control counts are actual native birth/destruction probes. Worker quiescence waits for the native end-of-worker release, not a fixed number of loop turns or public join alone; it is native domain-ownership retirement evidence, not an OS-join proof. The pre-wake resource-ownership correctness checkpoint intentionally retains known legacy detached-thread/proxy-early-terminal behavior and is not final Thread approval. The separate final corrected wake/join candidate requires actual OS join before every proxy terminal and full platform correctness evidence. Explicit residual collections occur outside body timing. The allocator's signed net delta is an observed ledger, **not** a complete retained-native-memory oracle; lifecycle counts are reported separately. Failed calibration, missing/truncated samples, checksum errors and unretired native domains reject a campaign.

### Overlapping source-scoped stage intervals

| Case | Wake attribution | Sender entry through encode | Queue lock + branch | Registration after failed check | Notify to continuation | Post-dequeue decode + return | Reply processing |
|---|---|---:|---:|---:|---:|---:|---:|
| `call_control` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `churn_cancel_parked_waiters` | `unavailable_unawaited_cancelled_failed_or_nonunique_notification` | 0.586/63.073 (1000 total; 500..500/round) | 0.035/0.126 (5000 total; 2500..2500/round) | 1.944/66.133 (2000 total; 1000..1000/round) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `churn_close_parked_receivers` | `exact_waiter_notification_to_continuation` | unavailable (0 samples) | 0.035/0.066 (6000 total; 3000..3000/round) | 2.670/22.076 (2000 total; 1000..1000/round) | 2.796/7.764 (2000 total; 1000..1000/round) | unavailable (0 samples) | unavailable (0 samples) |
| `churn_close_parked_senders` | `exact_waiter_notification_to_continuation` | 1.177/4.904 (2000 total; 1000..1000/round) | 0.030/0.096 (7000 total; 3500..3500/round) | 1.498/21.008 (2000 total; 1000..1000/round) | 7.464/23.214 (2000 total; 1000..1000/round) | unavailable (0 samples) | unavailable (0 samples) |
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
| `join_cleanup_cancelled_task` | `partial_exact_only` | unavailable (0 samples) | 0.236/9.303 (3000 total; 1500..1500/round) | unavailable (0 samples) | 32.511/156.107 (800 total; 400..400/round) | unavailable (0 samples) | unavailable (0 samples) |
| `join_ordinary` | `exact_waiter_notification_to_continuation` | unavailable (0 samples) | 0.250/7.809 (1799 total; 899..900/round) | unavailable (0 samples) | 17.642/63.403 (599 total; 299..300/round) | unavailable (0 samples) | unavailable (0 samples) |
| `mpmc_endpoint_inflight16_cap16_4p4c` | `exact_waiter_notification_to_continuation` | 2.860/10.625 (4000 total; 2000..2000/round) | 0.130/5.941 (22052 total; 10879..11173/round) | 2.745/7.724 (2000 total; 1000..1000/round) | 57.367/177.447 (4702 total; 2275..2427/round) | 5.470/14.672 (2000 total; 1000..1000/round) | 0.030/0.066 (2000 total; 1000..1000/round) |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `exact_waiter_notification_to_continuation` | 3.080/8.966 (4000 total; 2000..2000/round) | 0.151/6.562 (22278 total; 10979..11299/round) | 2.966/8.335 (2101 total; 1044..1057/round) | 60.769/191.743 (4738 total; 2281..2457/round) | 5.696/12.749 (2000 total; 1000..1000/round) | 0.030/0.111 (2000 total; 1000..1000/round) |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `exact_waiter_notification_to_continuation` | 1.949/10.460 (4000 total; 2000..2000/round) | 0.075/2.414 (23440 total; 11609..11831/round) | 1.538/6.046 (2000 total; 1000..1000/round) | 3.406/16.421 (5710 total; 2800..2910/round) | 2.675/11.912 (2000 total; 1000..1000/round) | 0.030/0.070 (2000 total; 1000..1000/round) |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `exact_waiter_notification_to_continuation` | 2.034/6.893 (4000 total; 2000..2000/round) | 0.081/2.564 (21688 total; 10818..10870/round) | 1.693/5.706 (2362 total; 1179..1183/round) | 9.492/42.189 (4442 total; 2216..2226/round) | 3.572/11.285 (2000 total; 1000..1000/round) | 0.030/0.056 (2000 total; 1000..1000/round) |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `exact_waiter_notification_to_continuation` | 2.139/6.623 (4000 total; 2000..2000/round) | 0.110/3.187 (21299 total; 10644..10655/round) | 1.754/5.660 (2000 total; 1000..1000/round) | 10.550/42.404 (4376 total; 2182..2194/round) | 4.107/13.235 (2000 total; 1000..1000/round) | 0.025/0.050 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight16_cap16_4p4c` | `exact_waiter_notification_to_continuation` | 2.545/9.883 (4000 total; 2000..2000/round) | 0.105/3.597 (20303 total; 9781..10522/round) | 2.881/6.968 (2000 total; 1000..1000/round) | 27.397/157.951 (4016 total; 1872..2144/round) | 6.512/15.514 (2000 total; 1000..1000/round) | 0.030/0.080 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight16_cap2_4p4c` | `exact_waiter_notification_to_continuation` | 2.380/22.181 (4000 total; 2000..2000/round) | 0.100/4.348 (22105 total; 10981..11124/round) | 2.841/7.729 (2761 total; 1269..1492/round) | 36.443/136.435 (4719 total; 2344..2375/round) | 5.736/12.509 (2000 total; 1000..1000/round) | 0.030/0.065 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight1_cap1_2p2c` | `exact_waiter_notification_to_continuation` | 1.377/8.035 (4000 total; 2000..2000/round) | 0.075/1.849 (22968 total; 11010..11958/round) | 1.678/6.091 (2000 total; 1000..1000/round) | 3.511/16.215 (5474 total; 2499..2975/round) | 2.610/11.091 (2000 total; 1000..1000/round) | 0.030/0.111 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight4_cap1_2p2c` | `exact_waiter_notification_to_continuation` | 1.563/8.741 (4000 total; 2000..2000/round) | 0.095/3.717 (21824 total; 10880..10944/round) | 1.768/10.094 (2335 total; 1127..1208/round) | 9.663/75.762 (4514 total; 2233..2281/round) | 3.817/19.657 (2000 total; 1000..1000/round) | 0.030/0.050 (2000 total; 1000..1000/round) |
| `mpmc_record_inflight4_cap4_2p2c` | `exact_waiter_notification_to_continuation` | 1.824/8.000 (4000 total; 2000..2000/round) | 0.110/4.424 (21188 total; 10579..10609/round) | 1.959/7.303 (2000 total; 1000..1000/round) | 11.902/45.335 (4313 total; 2146..2167/round) | 4.628/13.716 (2000 total; 1000..1000/round) | 0.030/0.060 (2000 total; 1000..1000/round) |
| `overhead_control` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `queue_opaque_hook8` | `no_suspensions` | 1.202/8.150 (10000 total; 5000..5000/round) | 0.030/0.121 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 1.758/14.803 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `queue_packed_hook8` | `no_suspensions` | 1.683/20.689 (10000 total; 5000..5000/round) | 0.030/0.150 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 2.038/68.508 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `queue_plain_bytes8` | `no_suspensions` | 1.008/2.756 (10000 total; 5000..5000/round) | 0.035/0.165 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 1.873/45.636 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `queue_real_receiver` | `no_suspensions` | 1.247/6.061 (10000 total; 5000..5000/round) | 0.030/0.136 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 1.819/18.735 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `queue_real_sender` | `no_suspensions` | 1.448/8.316 (10000 total; 5000..5000/round) | 0.030/0.141 (20000 total; 10000..10000/round) | unavailable (0 samples) | unavailable (0 samples) | 2.155/28.629 (10000 total; 5000..5000/round) | unavailable (0 samples) |
| `sender_clone` | `no_suspensions` | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) | unavailable (0 samples) |
| `spsc_endpoint_carried_persistent` | `exact_waiter_notification_to_continuation` | 1.633/13.786 (4000 total; 2000..2000/round) | 0.065/0.872 (15954 total; 7977..7977/round) | 1.147/15.534 (2000 total; 1000..1000/round) | 2.725/7.514 (3954 total; 1977..1977/round) | 2.179/17.993 (2000 total; 1000..1000/round) | 0.085/1.297 (2000 total; 1000..1000/round) |
| `spsc_endpoint_fresh_reply` | `exact_waiter_notification_to_continuation` | 1.648/5.420 (2000 total; 1000..1000/round) | 0.105/1.744 (7997 total; 3997..4000/round) | 1.177/4.293 (1000 total; 500..500/round) | 3.987/9.011 (1997 total; 997..1000/round) | 2.605/10.455 (1000 total; 500..500/round) | 0.130/1.248 (1000 total; 500..500/round) |
| `spsc_endpoint_pool4_reply` | `exact_waiter_notification_to_continuation` | 1.719/18.900 (4000 total; 2000..2000/round) | 0.065/2.275 (15914 total; 7939..7975/round) | 1.383/17.848 (2000 total; 1000..1000/round) | 3.086/16.421 (3914 total; 1939..1975/round) | 2.439/24.746 (2000 total; 1000..1000/round) | 0.085/1.413 (2000 total; 1000..1000/round) |
| `spsc_large64k_endpoint_pool4` | `exact_waiter_notification_to_continuation` | 2.179/13.566 (1024 total; 512..512/round) | 0.065/1.638 (4095 total; 2047..2048/round) | 1.362/3.827 (512 total; 256..256/round) | 3.096/16.276 (1023 total; 511..512/round) | 2.300/8.521 (512 total; 256..256/round) | 0.090/0.376 (512 total; 256..256/round) |
| `spsc_large64k_persistent` | `exact_waiter_notification_to_continuation` | 2.529/12.127 (1024 total; 512..512/round) | 0.065/1.528 (4095 total; 2047..2048/round) | 1.237/5.325 (512 total; 256..256/round) | 2.785/12.584 (1023 total; 511..512/round) | 2.379/12.628 (512 total; 256..256/round) | 0.086/0.290 (512 total; 256..256/round) |
| `spsc_opaque_persistent` | `exact_waiter_notification_to_continuation` | 1.493/13.410 (4000 total; 2000..2000/round) | 0.065/1.393 (15943 total; 7966..7977/round) | 1.257/12.188 (2000 total; 1000..1000/round) | 2.775/11.441 (3943 total; 1966..1977/round) | 2.244/20.363 (2000 total; 1000..1000/round) | 0.085/1.277 (2000 total; 1000..1000/round) |
| `spsc_record_persistent` | `exact_waiter_notification_to_continuation` | 1.082/7.324 (4000 total; 2000..2000/round) | 0.065/2.103 (15840 total; 7846..7994/round) | 1.278/7.770 (2000 total; 1000..1000/round) | 2.841/12.053 (3840 total; 1846..1994/round) | 2.415/12.259 (2000 total; 1000..1000/round) | 0.085/1.247 (2000 total; 1000..1000/round) |
| `spsc_record_pool4_control` | `exact_waiter_notification_to_continuation` | 1.272/4.583 (4000 total; 2000..2000/round) | 0.071/1.082 (15989 total; 7992..7997/round) | 1.348/4.252 (2000 total; 1000..1000/round) | 3.201/7.213 (3989 total; 1992..1997/round) | 2.535/11.216 (2000 total; 1000..1000/round) | 0.096/1.453 (2000 total; 1000..1000/round) |
| `spsc_scalar_persistent` | `exact_waiter_notification_to_continuation` | 0.426/2.560 (4000 total; 2000..2000/round) | 0.070/1.097 (15909 total; 7947..7962/round) | 1.528/6.473 (2000 total; 1000..1000/round) | 2.895/6.302 (3909 total; 1947..1962/round) | 0.591/4.013 (2000 total; 1000..1000/round) | 0.030/0.045 (2000 total; 1000..1000/round) |
| `wait_empty_receiver_endpoint` | `exact_waiter_notification_to_continuation` | unavailable (0 samples) | 0.085/1.548 (8000 total; 4000..4000/round) | 2.495/44.072 (1000 total; 500..500/round) | 3.817/13.986 (2000 total; 1000..1000/round) | 4.183/135.048 (1000 total; 500..500/round) | unavailable (0 samples) |
| `wait_empty_receiver_record` | `exact_waiter_notification_to_continuation` | unavailable (0 samples) | 0.075/1.498 (8000 total; 4000..4000/round) | 2.760/90.870 (1000 total; 500..500/round) | 3.763/11.656 (2000 total; 1000..1000/round) | 3.862/113.363 (1000 total; 500..500/round) | unavailable (0 samples) |
| `wait_full_sender_endpoint` | `exact_waiter_notification_to_continuation` | 3.697/146.053 (1000 total; 500..500/round) | 0.071/1.553 (11141 total; 5552..5589/round) | 1.343/17.628 (1809 total; 893..916/round) | 3.280/23.082 (2332 total; 1159..1173/round) | 2.910/7.444 (1000 total; 500..500/round) | unavailable (0 samples) |
| `wait_full_sender_record` | `exact_waiter_notification_to_continuation` | 2.599/57.508 (1000 total; 500..500/round) | 0.131/1.553 (10653 total; 5264..5389/round) | 1.377/5.170 (1493 total; 724..769/round) | 3.928/15.243 (2160 total; 1040..1120/round) | 2.885/53.019 (1000 total; 500..500/round) | unavailable (0 samples) |

Cells are medians of per-round p50/p99 microseconds, with total sample count and per-round count range. Wake modes list all observed round modes, not only the representative counter round. Encode/decode subintervals cover selected benchmark call brackets, not every worker's codec. Queue intervals include lock acquisition and readiness/closed branches, ending before unlock. Native wake correlates the exact selected waiter with its notification and successful continuation; cancelled/failed/nonunique or unawaited prearmed notifications are unavailable, never attributed to a global last signal. Both current matched lanes end the native-wake interval at the exact successful native-await return, including helper cleanup. Do not pool this with frozen-v4 raw coroutine-return samples. It is not isolated kernel wake latency. Stages overlap across OS threads: do not add medians or subtract independently measured RTTs to manufacture a component time.

### Instrumentation overhead

| Case | Original SDK us/op | Private instrumented us/op | Difference us/op | Ratio |
|---|---:|---:|---:|---:|
| `call_control` | 0.055 | 0.073 | +0.018 | 1.322 |
| `churn_cancel_parked_waiters` | 85.843 | 83.880 | -1.963 | 0.977 |
| `churn_close_parked_receivers` | 27.701 | 34.298 | +6.597 | 1.238 |
| `churn_close_parked_senders` | 42.008 | 44.758 | +2.750 | 1.065 |
| `closure_roundtrip_cap0` | 3.036 | 4.085 | +1.049 | 1.346 |
| `closure_roundtrip_cap1` | 5.644 | 8.179 | +2.535 | 1.449 |
| `closure_roundtrip_cap64` | 152.262 | 229.369 | +77.108 | 1.506 |
| `closure_roundtrip_cap8` | 27.183 | 37.963 | +10.780 | 1.397 |
| `closure_roundtrip_complex_sig` | 6.462 | 9.935 | +3.473 | 1.538 |
| `codec_large64k_decode` | 7.656 | 7.690 | +0.034 | 1.004 |
| `codec_large64k_encode` | 7.668 | 10.009 | +2.341 | 1.305 |
| `codec_large64k_transfer_roundtrip` | 10.497 | 9.780 | -0.717 | 0.932 |
| `codec_scalar_roundtrip` | 0.512 | 0.751 | +0.239 | 1.466 |
| `codec_small_decode` | 1.061 | 1.541 | +0.480 | 1.453 |
| `codec_small_encode` | 0.551 | 0.712 | +0.160 | 1.291 |
| `codec_small_transfer_roundtrip` | 2.814 | 4.514 | +1.701 | 1.604 |
| `codec_wide16_decode` | 2.517 | 4.093 | +1.577 | 1.626 |
| `codec_wide16_encode` | 1.111 | 1.175 | +0.065 | 1.058 |
| `codec_wide16_transfer_roundtrip` | 5.014 | 8.293 | +3.280 | 1.654 |
| `inspect_function` | 2.288 | 3.299 | +1.011 | 1.442 |
| `inspect_record` | 0.195 | 0.226 | +0.031 | 1.159 |
| `join_cleanup_cancelled_task` | 43898.007 | 40950.644 | -2947.363 | 0.933 |
| `join_ordinary` | 6969.387 | 7452.087 | +482.700 | 1.069 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | 3.763 | 6.520 | +2.757 | 1.733 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | 3.812 | 6.559 | +2.747 | 1.721 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | 20.544 | 26.951 | +6.407 | 1.312 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | 6.512 | 8.519 | +2.008 | 1.308 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | 6.488 | 8.808 | +2.321 | 1.358 |
| `mpmc_record_inflight16_cap16_4p4c` | 4.364 | 7.700 | +3.335 | 1.764 |
| `mpmc_record_inflight16_cap2_4p4c` | 4.848 | 7.185 | +2.337 | 1.482 |
| `mpmc_record_inflight1_cap1_2p2c` | 17.868 | 23.991 | +6.123 | 1.343 |
| `mpmc_record_inflight4_cap1_2p2c` | 5.805 | 9.983 | +4.178 | 1.720 |
| `mpmc_record_inflight4_cap4_2p2c` | 5.822 | 10.023 | +4.201 | 1.722 |
| `overhead_control` | 0.068 | 0.117 | +0.049 | 1.715 |
| `queue_opaque_hook8` | 4.540 | 4.649 | +0.109 | 1.024 |
| `queue_packed_hook8` | 6.812 | 6.483 | -0.329 | 0.952 |
| `queue_plain_bytes8` | 3.000 | 5.208 | +2.207 | 1.736 |
| `queue_real_receiver` | 4.443 | 4.989 | +0.547 | 1.123 |
| `queue_real_sender` | 4.672 | 6.163 | +1.491 | 1.319 |
| `sender_clone` | 0.200 | 0.298 | +0.098 | 1.490 |
| `spsc_endpoint_carried_persistent` | 23.347 | 21.009 | -2.338 | 0.900 |
| `spsc_endpoint_fresh_reply` | 16.794 | 22.704 | +5.911 | 1.352 |
| `spsc_endpoint_pool4_reply` | 21.808 | 26.763 | +4.956 | 1.227 |
| `spsc_large64k_endpoint_pool4` | 37.974 | 38.403 | +0.428 | 1.011 |
| `spsc_large64k_persistent` | 35.857 | 34.706 | -1.152 | 0.968 |
| `spsc_opaque_persistent` | 19.826 | 21.880 | +2.054 | 1.104 |
| `spsc_record_persistent` | 15.862 | 18.869 | +3.008 | 1.190 |
| `spsc_record_pool4_control` | 14.587 | 18.630 | +4.043 | 1.277 |
| `spsc_scalar_persistent` | 7.723 | 10.405 | +2.682 | 1.347 |
| `wait_empty_receiver_endpoint` | 32.138 | 39.065 | +6.927 | 1.216 |
| `wait_empty_receiver_record` | 34.675 | 37.890 | +3.216 | 1.093 |
| `wait_full_sender_endpoint` | 37.592 | 37.176 | -0.415 | 0.989 |
| `wait_full_sender_record` | 38.745 | 38.104 | -0.641 | 0.983 |

### Finite MPMC credit wait and progress

These existing MPMC cases retain their original post-permit RTT boundary. Separate bounded request traces start before credit acquisition and retain actual producer/lane identity. Values below are medians [ranges] of per-round worst-lane statistics, in microseconds; availability is shown as contributing/total rounds. Per-lane sample counts/distributions and raw trace hashes remain in JSON. An empty lane or one-completion gap series is unavailable, not zero.

| Case | Mode | Rounds | Worst lane permit p99 | Worst lane including-permit p99 | Max intercompletion gap | First-start / last-completion skew | Consumer request counts by round |
|---|---|---:|---:|---:|---:|---|---|
| `mpmc_endpoint_inflight16_cap16_4p4c` | uninstrumented | 6 | 4.023 [1.663..29.876] (6/6) | 143.789 [110.306..645.085] (6/6) | 154.524 [111.217..732.670] (6/6) | 224.965 [162.484..335.226] (6/6) / 2662.818 [2262.298..3257.469] (6/6) | 245,204,278,273; 350,323,251,76; 272,244,221,263; 270,206,258,266; 355,256,202,187; 289,265,200,246 |
| `mpmc_endpoint_inflight16_cap16_4p4c` | instrumented | 2 | 4.399 [4.008..4.789] (2/2) | 276.192 [245.740..306.643] (2/2) | 331.279 [308.005..354.553] (2/2) | 373.163 [288.419..457.906] (2/2) / 4770.346 [4117.897..5422.796] (2/2) | 330,193,209,268; 262,227,256,255 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | uninstrumented | 6 | 4.874 [2.805..8.906] (6/6) | 371.309 [124.794..461.132] (6/6) | 417.060 [125.475..624.006] (6/6) | 207.778 [175.788..413.644] (6/6) / 2944.660 [2673.758..5784.853] (6/6) | 197,240,377,186; 279,217,233,271; 345,256,342,57; 501,116,250,133; 225,288,240,247; 372,314,67,247 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | instrumented | 2 | 10.084 [5.941..14.227] (2/2) | 245.023 [200.775..289.271] (2/2) | 279.928 [202.037..357.819] (2/2) | 317.419 [267.090..367.748] (2/2) / 4627.334 [3836.591..5418.077] (2/2) | 261,253,239,247; 262,242,235,261 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | uninstrumented | 6 | 2.885 [2.134..3.617] (6/6) | 62.532 [50.404..69.069] (6/6) | 365.774 [64.701..9781.534] (6/6) | 6.859 [1.092..19.556] (6/6) / 9667.124 [5261.535..11107.312] (6/6) | 500,500; 500,500; 501,499; 500,500; 499,501; 502,498 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | instrumented | 2 | 4.147 [3.857..4.438] (2/2) | 76.954 [72.065..81.843] (2/2) | 11832.837 [10575.367..13090.308] (2/2) | 9.678 [0.070..19.286] (2/2) / 3225.318 [1939.565..4511.072] (2/2) | 500,500; 500,500 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | uninstrumented | 6 | 3.050 [2.464..3.927] (6/6) | 72.906 [52.398..133.119] (6/6) | 90.289 [61.755..253.705] (6/6) | 47.890 [25.648..95.909] (6/6) / 3336.827 [2704.726..5782.127] (6/6) | 452,548; 503,497; 474,526; 481,519; 529,471; 482,518 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | instrumented | 2 | 3.457 [2.865..4.048] (2/2) | 94.121 [89.787..98.454] (2/2) | 111.499 [102.702..120.295] (2/2) | 52.980 [32.331..73.628] (2/2) / 4148.208 [3951.977..4344.440] (2/2) | 517,483; 504,496 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | uninstrumented | 6 | 3.446 [3.066..4.398] (6/6) | 66.519 [48.551..101.640] (6/6) | 104.756 [62.386..166.801] (6/6) | 47.514 [28.623..71.414] (6/6) / 3187.087 [2832.584..3697.100] (6/6) | 528,472; 523,477; 522,478; 516,484; 470,530; 524,476 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | instrumented | 2 | 3.502 [3.206..3.797] (2/2) | 70.246 [59.311..81.181] (2/2) | 128.105 [86.261..169.948] (2/2) | 86.892 [86.321..87.464] (2/2) / 3966.604 [3729.891..4203.316] (2/2) | 494,506; 489,511 |
| `mpmc_record_inflight16_cap16_4p4c` | uninstrumented | 6 | 10.129 [2.345..22.943] (6/6) | 462.209 [266.989..559.195] (6/6) | 475.424 [334.425..705.819] (6/6) | 204.642 [157.114..272.429] (6/6) / 2974.951 [2245.728..3820.421] (6/6) | 146,386,256,212; 337,134,365,164; 446,186,136,232; 349,156,153,342; 231,95,317,357; 336,187,251,226 |
| `mpmc_record_inflight16_cap16_4p4c` | instrumented | 2 | 5.691 [4.528..6.853] (2/2) | 509.127 [452.976..565.277] (2/2) | 716.119 [663.490..768.747] (2/2) | 297.356 [295.633..299.079] (2/2) / 5530.041 [4118.628..6941.454] (2/2) | 345,149,279,227; 686,96,101,117 |
| `mpmc_record_inflight16_cap2_4p4c` | uninstrumented | 6 | 7.699 [5.270..32.360] (6/6) | 380.406 [283.430..816.325] (6/6) | 579.107 [501.277..817.147] (6/6) | 236.352 [154.218..275.855] (6/6) / 3499.787 [3127.356..4959.841] (6/6) | 384,129,396,91; 469,78,119,334; 296,239,116,349; 149,206,540,105; 466,108,309,117; 280,197,180,343 |
| `mpmc_record_inflight16_cap2_4p4c` | instrumented | 2 | 4.228 [3.386..5.070] (2/2) | 585.375 [534.810..635.939] (2/2) | 991.373 [847.053..1135.693] (2/2) | 357.810 [335.017..380.602] (2/2) / 4842.647 [3748.267..5937.027] (2/2) | 302,286,215,197; 206,176,459,159 |
| `mpmc_record_inflight1_cap1_2p2c` | uninstrumented | 6 | 2.119 [2.074..2.715] (6/6) | 56.822 [38.863..82.874] (6/6) | 104.370 [80.340..8525.856] (6/6) | 3.205 [0.010..7.905] (6/6) / 8246.203 [3410.175..9123.904] (6/6) | 500,500; 499,501; 502,498; 500,500; 500,500; 500,500 |
| `mpmc_record_inflight1_cap1_2p2c` | instrumented | 2 | 4.062 [3.777..4.348] (2/2) | 74.064 [62.447..85.680] (2/2) | 6450.216 [812.528..12087.904] (2/2) | 13.956 [8.837..19.075] (2/2) / 6499.423 [433.820..12565.026] (2/2) | 500,500; 501,499 |
| `mpmc_record_inflight4_cap1_2p2c` | uninstrumented | 6 | 3.075 [2.785..4.218] (6/6) | 76.924 [53.590..109.745] (6/6) | 138.734 [87.423..187.741] (6/6) | 35.396 [19.126..101.710] (6/6) / 2956.341 [2709.896..3191.215] (6/6) | 499,501; 486,514; 506,494; 485,515; 494,506; 493,507 |
| `mpmc_record_inflight4_cap1_2p2c` | instrumented | 2 | 7.253 [3.437..11.070] (2/2) | 213.219 [93.655..332.782] (2/2) | 372.146 [334.936..409.355] (2/2) | 56.044 [47.949..64.140] (2/2) / 5336.706 [4675.640..5997.771] (2/2) | 479,521; 494,506 |
| `mpmc_record_inflight4_cap4_2p2c` | uninstrumented | 6 | 3.542 [2.895..5.981] (6/6) | 61.099 [48.221..77.705] (6/6) | 101.851 [71.855..316.571] (6/6) | 43.602 [21.480..62.958] (6/6) / 2834.903 [2530.310..3219.348] (6/6) | 486,514; 512,488; 413,587; 491,509; 478,522; 512,488 |
| `mpmc_record_inflight4_cap4_2p2c` | instrumented | 2 | 6.497 [6.332..6.662] (2/2) | 93.034 [90.039..96.029] (2/2) | 177.271 [161.802..192.740] (2/2) | 87.293 [56.616..117.970] (2/2) / 5072.121 [4762.242..5382.000] (2/2) | 490,510; 490,510 |

Consumer counts are each actual worker's positive-request count, collected after join outside timing; they are not a uniform-share promise. Progress gaps include the finite fixture's credit contention/scheduling. Different lane operation counts and finite startup/finish affect skews. This is not strict FIFO completion, a starvation bound or a generic scheduler fairness proof. Instrumented fairness is diagnostic and can be perturbed by the private probe overhead.


### Matched protocol/shape endpoint component contrasts

| Case | Control | Case us/op | Control us/op | Difference us/op |
|---|---|---:|---:|---:|
| `mpmc_endpoint_inflight16_cap16_4p4c` | `mpmc_record_inflight16_cap16_4p4c` | 3.763 | 4.364 | -0.601 |
| `mpmc_endpoint_inflight16_cap2_4p4c` | `mpmc_record_inflight16_cap2_4p4c` | 3.812 | 4.848 | -1.036 |
| `mpmc_endpoint_inflight1_cap1_2p2c` | `mpmc_record_inflight1_cap1_2p2c` | 20.544 | 17.868 | +2.676 |
| `mpmc_endpoint_inflight4_cap1_2p2c` | `mpmc_record_inflight4_cap1_2p2c` | 6.512 | 5.805 | +0.707 |
| `mpmc_endpoint_inflight4_cap4_2p2c` | `mpmc_record_inflight4_cap4_2p2c` | 6.488 | 5.822 | +0.666 |
| `queue_real_receiver` | `queue_plain_bytes8` | 4.443 | 3.000 | +1.442 |
| `queue_real_sender` | `queue_plain_bytes8` | 4.672 | 3.000 | +1.671 |
| `spsc_endpoint_carried_persistent` | `spsc_record_persistent` | 23.347 | 15.862 | +7.485 |
| `spsc_endpoint_pool4_reply` | `spsc_record_pool4_control` | 21.808 | 14.587 | +7.221 |
| `wait_empty_receiver_endpoint` | `wait_empty_receiver_record` | 32.138 | 34.675 | -2.537 |
| `wait_full_sender_endpoint` | `wait_full_sender_record` | 37.592 | 38.745 | -1.153 |

### Payload-policy controls (not isolated endpoint costs)

| Case | Control | Case us/op | Control us/op | Difference us/op |
|---|---|---:|---:|---:|
| `queue_opaque_hook8` | `queue_plain_bytes8` | 4.540 | 3.000 | +1.539 |
| `queue_packed_hook8` | `queue_plain_bytes8` | 6.812 | 3.000 | +3.811 |
| `spsc_opaque_persistent` | `spsc_record_persistent` | 19.826 | 15.862 | +3.964 |

### Application-protocol contrasts (not matched endpoint components)

| Case | Control | Case us/op | Control us/op | Difference us/op |
|---|---|---:|---:|---:|
| `spsc_endpoint_fresh_reply` | `spsc_endpoint_pool4_reply` | 16.794 | 21.808 | -5.014 |
| `spsc_large64k_endpoint_pool4` | `spsc_large64k_persistent` | 37.974 | 35.857 | +2.117 |

Matched endpoint contrasts retain common field count, capacity, OS producer/consumer counts, in-flight budget and validation/protocol; payload representation, hooks, wrapper allocation and ownership differ together. They do not isolate only retain/release cost. Fresh/pool-four and large pool-four/persistent comparisons change application protocol and are kept in the separate protocol table.

