# WebSocket timing and fairness observations

The finite Linux run completed 16 paired timing profiles and 16 buffered fairness profiles in 610.90 seconds, with 556 successful consumer/peer rows. These are **background-qualified fixture observations**: `quiet_host_proven=false` and `host_quiet_claim=false`. VMs remained running with CPU affinities spanning all 24 host CPUs, and were never paused. No overlapping compiler/native/test job was observed by the wrapper guards; this does not establish host isolation.

Exactly 2/16 paired timing profiles had all seven intervals in both lanes at least 250 ms; 16/32 lanes contain shorter intervals. All short lanes are marked insufficient for robust comparisons. Fairness sufficiency is 16/16 profiles under the finite duration/sample/capacity checks below. The approved count caps and original unsuccessful zero-row attempts were preserved; no automatic repeat was performed.

The companion [allocation results](websocket-allocation-results.md) use independently instrumented runs. Their accepted combined 397 SHA remains `95c9e7817a8cfc2f760b3b9de60ee5003206e1880ff24578d2354282a3343c9d`, with 272 strict-tail rows plus 125 unaffected original rows and differing per-row provenance.

## Paired body intervals

Each lane was calibrated toward at least 250 ms, warmed once, then measured seven times with alternating pair order. The 32-byte cap is 100,000 operations; the 64-KiB cap is 2,048 operations/128 MiB per lane. Each cell gives body-wall median [minimum, maximum] in milliseconds. A pair marked insufficient has at least one measured interval below 250 ms. Full per-repeat wall and Titan process CPU clocks, with exact configurations, remain in the [small measurement summary](https://github.com/mascarenhas/titan/releases/download/issue-193-benchmark-archive/websocket-benchmark-issue193.zip) (`spec/bench/websocket/background-summary-final5.json` in [archived issue benchmarks](benchmark-archives.md)).

| Endpoint / operation / bytes | Count | WS/WSS wall ms | Raw TCP/TLS wall ms | Both lanes ≥250ms |
| --- | ---: | ---: | ---: | --- |
| WS client read / 32 | 100000 | 2986.410 [2904.780, 3315.852] | 67.229 [61.585, 110.659] | insufficient |
| WS client read / 65536 | 2048 | 143.088 [139.410, 192.338] | 38.171 [27.327, 56.463] | insufficient |
| WS client write / 32 | 100000 | 2706.393 [2563.929, 4253.039] | 234.983 [121.487, 252.059] | insufficient |
| WS client write / 65536 | 2048 | 6061.465 [6016.531, 6161.743] | 15.083 [13.821, 26.901] | insufficient |
| WS server read / 32 | 100000 | 3189.869 [2774.870, 3371.374] | 88.242 [61.534, 131.334] | insufficient |
| WS server read / 65536 | 2048 | 6185.995 [6070.696, 6361.555] | 29.868 [20.117, 44.636] | insufficient |
| WS server write / 32 | 100000 | 2633.362 [2597.291, 3860.290] | 197.116 [115.320, 243.475] | insufficient |
| WS server write / 65536 | 2048 | 196.269 [125.862, 240.629] | 18.935 [14.116, 27.260] | insufficient |
| WSS client read / 32 | 25600 | 891.086 [805.657, 983.053] | 342.726 [325.371, 561.288] | yes |
| WSS client read / 65536 | 1600 | 318.722 [285.428, 431.930] | 275.649 [181.185, 287.187] | insufficient |
| WSS client write / 32 | 12800 | 391.041 [362.585, 654.150] | 237.434 [220.616, 309.150] | insufficient |
| WSS client write / 65536 | 2048 | 6073.219 [6010.688, 6344.249] | 118.534 [101.752, 193.990] | insufficient |
| WSS server read / 32 | 25600 | 972.390 [846.709, 1274.813] | 495.702 [334.653, 544.456] | yes |
| WSS server read / 65536 | 1600 | 4842.282 [4772.845, 5132.829] | 264.873 [188.357, 277.055] | insufficient |
| WSS server write / 32 | 12800 | 439.870 [429.552, 581.409] | 254.834 [216.698, 390.908] | insufficient |
| WSS server write / 65536 | 2048 | 431.685 [300.367, 575.417] | 174.584 [105.957, 188.169] | insufficient |

The body boundary excludes setup/handshake, teardown and forced GC. It still measures the full fixture's progress: the external Python peer generates/masks/validates frames and advances the transport. In particular, reads can wait on Python frame production or masking. Raw controls match payload bytes and topology, while omitting WebSocket message framing. Titan process CPU excludes Python peer CPU and cannot isolate codec CPU. No speed ratio or quiet-host throughput conclusion is derived from these intervals.

## Finite buffered fairness

The peer submits a finite flood of 32-byte binary messages and then writes a submission marker. The consumer reads without a caller-inserted yield while 1/16/64/256 independent sampler Tasks yield and a 1 ms libuv timer fires. The marker proves submission completion, not the location or size of buffered queues. Each sampler profile calibrates independently; sufficiency requires a sampled interval ≥250 ms, at least 100 timer intervals and no sampling truncation. Bounded storage admits at most 1,000,000 yield intervals for one sampler or 4,000,000 for larger groups, and 1,000,000 timer intervals. Actual return counts, including child/parent scheduling, govern capacity accounting.

Sampler Tasks, native sample calls, Lua counter callbacks, timer startup and terminal drain add fixture overhead. The native arrays are preallocated before sampled Tasks/timers start; those arrays also contribute to process RSS. This is an observed scheduling workload with that overhead, not an untraced scheduler benchmark.

Yield figures below are pooled across sampler Tasks in microseconds; timer figures are interarrival intervals in milliseconds, **not deadline lateness**. These distributions describe this finite background-qualified fixture only.

| Endpoint | Samplers | Reads | Sampled ms | Yield samples | Yield p99 / max µs | Timer samples | Timer p99 / max ms | Sufficient |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| WS client | 1 | 32000 | 709.186 | 64001 | 20.458 / 17388.398 | 509 | 4.827 / 18.342 | yes |
| WS client | 16 | 8000 | 340.535 | 256016 | 37.600 / 1255.897 | 338 | 1.833 / 2.087 | yes |
| WS client | 64 | 8000 | 725.796 | 1024064 | 88.255 / 1159.547 | 724 | 1.629 / 1.920 | yes |
| WS client | 256 | 1000 | 329.965 | 512256 | 213.679 / 1141.644 | 328 | 1.360 / 1.932 | yes |
| WS server | 1 | 16000 | 375.543 | 32001 | 24.115 / 1176.699 | 371 | 1.802 / 2.077 | yes |
| WS server | 16 | 16000 | 625.594 | 512016 | 63.168 / 1363.519 | 623 | 1.818 / 2.033 | yes |
| WS server | 64 | 4000 | 343.973 | 512064 | 99.616 / 883.491 | 341 | 1.518 / 1.595 | yes |
| WS server | 256 | 1000 | 337.436 | 512256 | 305.461 / 1282.587 | 333 | 1.365 / 1.583 | yes |
| WSS client | 1 | 8000 | 283.173 | 32001 | 154.168 / 1151.332 | 282 | 1.362 / 1.604 | yes |
| WSS client | 16 | 8000 | 399.642 | 512016 | 154.870 / 698.906 | 398 | 1.268 / 1.655 | yes |
| WSS client | 64 | 2000 | 257.945 | 512064 | 198.641 / 485.888 | 257 | 1.260 / 1.311 | yes |
| WSS client | 256 | 1000 | 838.111 | 1024256 | 645.527 / 2079.857 | 835 | 1.308 / 2.106 | yes |
| WSS server | 1 | 16000 | 504.326 | 64001 | 62.708 / 2500.113 | 496 | 1.428 / 3.224 | yes |
| WSS server | 16 | 8000 | 426.796 | 512016 | 166.542 / 766.933 | 422 | 1.219 / 1.601 | yes |
| WSS server | 64 | 2000 | 259.994 | 512064 | 167.413 / 904.321 | 255 | 1.156 / 1.978 | yes |
| WSS server | 256 | 1000 | 741.651 | 1024256 | 531.203 / 1002.293 | 674 | 2.020 / 2.351 | yes |

Across these profiles, pooled yield p99 ranged from 20.458 to 645.527 µs; the largest observed yield interval was 17.388 ms. Timer p99 ranged from 1.156 to 4.827 ms, with an observed maximum of 18.342 ms. These are finite sample extremes on a background host, not bounds.

No generic buffered-work fairness bound or starvation guarantee follows from these profiles. The complete summary preserves observed/recorded/dropped counts, capacities, stop reasons and any truncation. Uninstrumented allocator counters and peak-heap placeholders are excluded from memory claims; the instrumented allocation report supplies that evidence separately.

## Identity, background activity and reproduction

All runtime rows used the already-built final-R1 optimized consumer. Build SHA `5fbe0e82285a9a14c78f222ee660a008710c5a88069dec26a677ae7f09e3a15a`; private coordination wrapper SHA `b78d770fe9bf4b2dd362b08ac8e874a1eafb1c46626ece4b42a08f5aeec55f2e`. Provider DSO SHA `ba0e5cdfcb6124dcbdd88ff40d18d26b6153311763b7a63999d3d4d98ceea4c1` and archive SHA `78e462767fe6af88f614b31c9aa3a037b601749e66661a4217105c32bac85c71` match final5. Production commit `2bf8aae5cdb599173cfd67a640209840a7a81e1f` and actual provider-build commit `b56e0688e9cde4be375b4c563006b828749bb855` remain distinct. Per-row source/provider identities, full prefix inventories at group boundaries, strict framing, consumer exit0, peer exit0 and log digests were checked. No runtime payload, frozen issue196 probe, provider or VM state was changed.

The run started `2026-10-04T10:03:04.743215+00:00`, released `2026-10-04T10:13:15.640929+00:00`, and used effective expiry `2026-10-04T10:39:53+00:00` with a 225-second no-new-row reserve. Completion SHA `f49a2b8126e40a02e44fd72fd0b526bf78ade8789f978bf37a83f8df23dc63a6`; complete row export SHA `eb99f64f8973c7c7910fa7cbff0d25a044dd19ae803602ec4a98555eac574260`. The selected summary records exact hashes for all four runtime sources and reused probes; full local receipts remain outside the repository.

The original full 1,618-entry prefix manifest SHA `4b5de2721737d2b2125c2020507ee6f64e0f723925b657b51f21d2ede091007b` remained the audit baseline; completion records its final unchanged audit. The separate closing audit checked all 164 recorded production-source/generated-unit/frozen-native/prefix-key identities and the owner provider receipt. Its SHA `f8ab0fb2f53525d3994369a43bcd6a460d6c1853fd720b4ce63157a0952eec48` is bound alongside the actual completion and row export in the summary. These copied native inputs retain their original receipt's diagnostic-versus-accepted fixture distinctions.

The original quiet attempt stopped before any rows on observed QEMU CPU activity. The first background attempt stopped before any rows when nine cache records had been added to the otherwise unchanged prefix. The owner preserved and removed exactly those nine additions, independently proved the entire original 1618-entry fingerprint matched again, and authorized one fresh attempt. Restoration receipt SHA `0e51b08af236bccdd614a37f51aba623f3787b1a1226bc282a8e4bef5f0e9e9d`. No acceptance baseline was rebased.

QEMU CPU was recorded between guards and in one-second boundary samples. Between-guard intervals include setup/body/drain/audit/host time and cannot be attributed to a measured body alone. Recorded activity remains a limitation:

| VM process PID | Recorded CPU seconds / observed wall seconds | Maximum boundary CPU seconds in 1 s |
| --- | ---: | ---: |
| 135331 (qemu-system-x86) | 133.410 / 609.564 | 0.250 |

Reproduce only with a freshly verified immutable provider/build receipt and an owner-approved finite activity window, using a fresh private SSD output. The committed harness accepts the owner/time note through `--quiet-note`; that historical argument name does not prove quietness. This execution used the receipt-bound private wrapper above to retain explicit background qualifiers, record VM CPU, reject overlapping build/test jobs and enforce the expiry/reserve. Equivalent coordination must preserve those checks. Example single-profile commands after the documented build/audit:

```sh
python3 spec/bench/websocket/measure.py timing --repo . --output "$PRIVATE_OUTPUT" \
  --quiet-note "$OWNER_WINDOW_JSON" --transport ws --role client \
  --operation read --size 32 --max-count 100000
python3 spec/bench/websocket/measure.py fairness --repo . --output "$PRIVATE_OUTPUT" \
  --quiet-note "$OWNER_WINDOW_JSON" --transport ws --role client
```

The receipt-bound wrapper expands the full 16-profile selection and preserves paired repeats. These results are Linux observations and do not validate macOS or Windows performance.
