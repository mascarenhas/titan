# WebSocket Lua allocation and lifetime results

Measured on 2026-10-04. The accepted final5 matrix contains **397/397** rows with exact agreement between the Lua allocator ledger and independently sampled heap bytes. Independent review found abort-tail oracle gap B1 and extended-control-header gap R1; **272/272** affected WebSocket rows subsequently passed the tightened peer. The combined export uses those new rows plus **125 unaffected originals**, with each row’s actual source/build provenance preserved. Every ordinary WS/WSS 0/100/1000 group uses the new harness; raw controls retain their original runtime-body group. There is no source-uniformity claim. Common fairness wrapper definitions change startup heap overhead, which remains each row’s actual baseline. A separate held-endpoint diagnostic passed **8/8**. Separate [timing and buffered fairness observations](websocket-benchmark-results.md) subsequently completed 556 uninstrumented rows in 610.90 seconds: 16 paired timing profiles and 16 finite sampler profiles. Those observations are background-qualified, with `quiet_host_proven=false` and `host_quiet_claim=false`; VMs remained running. Only 2/16 timing pairs kept every repeat in both lanes at least 250 ms, and no ratios are claimed for insufficient pairs. Original zero-row quiet/QEMU and cache-audit failures plus exact cache restoration remain preserved. The successful activity window is released.

## Scope and accounting

The matrix contains 347 steady rows, 13 setup rows, 13 teardown rows and 24 repeated-session rows. Ordinary steady work has 113 distinct 0/100/1000 groups: WS/WSS and raw TCP/TLS, both roles, reads/writes, 0/32/4096/65536 bytes, binary/ASCII text, incoming fragmentation and controls. Eight additional GC-stopped binary 64-KiB reads hold the closed endpoint at counts 0/1000. Sessions use 0/10/100 complete connections. Connected zero-work rows and five no-connection phase controls preserve bootstrap costs.

Titan clients write masked/read unmasked frames; servers read masked/write unmasked frames. Incoming fragmentation is 64 bytes at 4 KiB and 16 KiB at 64 KiB; automatic Pong and application Ping are selected separately. Outgoing 64-KiB messages split into four 16-KiB frames. Payload construction and module loading precede the hook. Setup includes readiness/handshake; steady ends after declared operations; teardown measures retirement. Accounting continues through Runtime/listener drain and the first forced GC. Server setup includes HTTP topology; raw controls count identical byte budgets through arbitrary transport chunks.

Lua requested-byte traffic counts successful allocations/resizes, rather than resident memory. Userdata/function counts are transitive runtime costs. Native coroutine stacks, OpenSSL and libuv allocations are outside this ledger. Whole-process lifetime peak RSS ranged from 27,048 to 844,820 KiB on a busy host; it cannot be decomposed into native-only memory. Instrumented clocks are excluded from timing claims.

## Actual operation slopes

Each cell is **userdata / functions / requested Lua bytes per operation**, from `(100−0)/100` or `(1000−100)/900`. Binary payloads, no incoming fragmentation; numbers are rounded here and preserved at full precision in the selected [measurement summary](../../spec/bench/websocket/allocation-summary-final5.json). Different read chunking, string interning and task progress can alter the intervals. Raw controls are topology comparisons, not an isolated codec decomposition.

| 32-byte workload | 0→100 | 100→1000 |
| --- | ---: | ---: |
| WS client read | 23.11/7.00/7337.83 | 23.00/7.00/7248.69 |
| TCP client read | 0.15/0.02/704.01 | 0.12/0.02/43.82 |
| WS client write | 21.03/7.00/7494.90 | 21.00/7.00/7425.90 |
| TCP client write | 3.00/0.00/596.96 | 3.00/0.00/596.00 |
| WS server read | 29.12/7.00/8060.17 | 29.00/7.00/7954.17 |
| TCP server read | 0.15/0.02/704.01 | 0.31/0.04/61.41 |
| WS server write | 19.04/7.00/7152.30 | 19.00/7.00/7081.53 |
| TCP server write | 3.00/0.00/596.96 | 3.00/0.00/596.00 |
| WSS client read | 39.13/14.00/34089.76 | 39.01/14.00/34148.23 |
| TLS client read | 15.14/7.01/21062.08 | 15.02/7.00/21044.24 |
| WSS client write | 37.03/14.00/21659.41 | 37.00/14.00/21603.19 |
| TLS client write | 19.06/7.00/9216.82 | 19.00/7.00/9199.22 |
| WSS server read | 45.14/14.00/34904.59 | 45.00/14.00/34781.88 |
| TLS server read | 15.14/7.01/21094.58 | 15.02/7.00/21045.85 |
| WSS server write | 35.04/14.00/21307.55 | 35.00/14.00/21248.80 |
| TLS server write | 19.00/7.00/9206.66 | 19.00/7.00/9199.08 |

| 64-KiB write | 0→100 | 100→1000 |
| --- | ---: | ---: |
| WS client | 42.03/7.00/338436.58 | 42.00/7.00/338397.28 |
| TCP client | 3.00/0.00/596.96 | 3.00/0.00/596.00 |
| WS server | 34.04/7.00/206360.28 | 34.00/7.00/206308.06 |
| TCP server | 3.00/0.00/596.96 | 3.00/0.00/596.00 |
| WSS client | 126.03/35.00/644089.38 | 126.00/35.00/643484.07 |
| TLS client | 34.06/7.00/273842.59 | 34.00/7.00/273831.63 |
| WSS server | 118.04/35.00/511786.80 | 118.00/35.00/511199.17 |
| TLS server | 34.00/7.00/273852.91 | 34.00/7.00/273797.16 |

## Setup and teardown

These zero-operation body totals include public API and fixture callback costs. Triples retain the same userdata/functions/requested-byte units. Graceful WebSocket teardown adds Close exchange/deadline work. No-connection setup is 8/3/10286; no-connection teardown is 0/0/0.

| Endpoint | Setup (abort configuration) | Abort teardown | Graceful teardown |
| --- | ---: | ---: | ---: |
| WS client | 15310.00/66.00/3019084.00 | 20.00/5.00/7447.00 | 75.00/16.00/32570.00 |
| WS server | 22477.00/68.00/4236680.00 | 21.00/5.00/7548.00 | 80.00/16.00/33046.00 |
| WSS client | 15420.00/99.00/3217920.00 | 21.00/5.00/9828.00 | 106.00/30.00/71683.00 |
| WSS server | 23371.00/104.00/4696173.00 | 22.00/5.00/9929.00 | 111.00/30.00/72155.00 |
| TCP client | 34.00/15.00/25784.00 | 7.00/0.00/685.00 | — |
| TCP server | 46.00/27.00/28993.00 | 14.00/0.00/1307.00 | — |
| TLS client | 115.00/45.00/258476.00 | 8.00/0.00/826.00 | — |
| TLS server | 145.00/56.00/402422.00 | 15.00/0.00/1448.00 | — |

## Closed endpoints and collector latency

Every row reports the weak slot empty after final release. Exactly 368 ordinary connection rows populate it; all 24 repeated-session rows and five no-connection controls pass nil, so their 29 flags do not establish nested endpoint reachability. This alone does not classify first-GC memory. In the original eight held rows, 1000 reads left first-GC growth of 69,335,085/70,751,913 bytes for WS client/server and 151,605,499/154,043,334 for WSS. Their zero-count counterparts had negative growth because collection freed objects present at the measurement baseline. The summary preserves all eight exact configurations, initial/body/peak/after-close/first-GC values.

The separate diagnostic copied only the Lua runner, retained each same endpoint strongly through three collections, and then dropped it before the original two settling collections. Below are actual Lua heap bytes, not growth. All endpoints were reachable and explicitly strongly held after the added collections, then weakly absent after release.

| Endpoint | Reads | First GC | Second GC | Third GC |
| --- | ---: | ---: | ---: | ---: |
| WS client | 0 | 1929305 | 1887143 | 1887079 |
| WS client | 1000 | 71676539 | 1896287 | 1896223 |
| WS server | 0 | 1943478 | 1887119 | 1887055 |
| WS server | 1000 | 72966072 | 1961799 | 1961735 |
| WSS client | 0 | 1930615 | 1888482 | 1888418 |
| WSS client | 1000 | 153677324 | 1962066 | 1962002 |
| WSS server | 0 | 1945002 | 1888562 | 1888498 |
| WSS server | 1000 | 156251604 | 2027682 | 2027618 |

At the third collection, the 1000-minus-zero residual is **9,144 / 74,680 / 73,584 / 139,120 bytes** for WS client/server and WSS client/server. The second-to-third decrease is 64 bytes in every row. Probe.finish restores the allocator before constructing its result tables: fixed result-table plus original flag overhead was 3,092 bytes, and diagnostic metadata added 440 bytes per row. There is **no allocator ledger for the second/third heap samples**.

The large first-cycle residual is consistent with finalization latency: coroutine owner userdata has `__gc` and roots its thread, callback and Coroutine record; callbacks capture Work/message or TLS Operation results. A collection finalizes owners while their referenced Lua graphs survive until another cycle. Source review found no completed-read history chain rooted by a closed endpoint. The endpoint can still retain its cached retirement Task, stream and last callback/operation contexts. This diagnostic covers two counts in one read profile; it does not establish zero retention, generic queue bounds or a growth bound for other workloads.

## Compiler/provider correspondence and direct sites

Production commit `2bf8aae5cdb599173cfd67a640209840a7a81e1f` and actual provider-build commit `b56e0688e9cde4be375b4c563006b828749bb855` are preserved separately. Final5 verifies five prefix keys, 98 production files, 46 generated C/object files (22 production units plus unused test support), 15 native inputs and exact NUL-separated compiler argv. The original receipt SHA is `e623486c33aee206454ddc1c047a8b74974c7748d06153aced7e8ff082c57792`; the amended diagnostic fixture receipt SHA is `45a454cee46112ef0b815112c1ae893c228a37eb9195b6b43c73fc506f2dd3c9`. It labels dd156 native fixtures diagnostic while preserving the original b56 receipt. The owner separately attests original b56 Linux native 959 pass/1 platform skip and Autobahn 602 pass; these are not benchmark-helper runs.

Provider DSO/archive, compiler/Lua identities, full source and generated-unit hashes, exact argv and per-process receipts remain archived privately. The small summary records the durable identifying hashes, both executed payload generations and unchanged reused probes. Consumer imports were compiled-public-provider only, optimized with `-O3`, caches disabled, explicit `pthread,rt` linkage; full build/batch and per-row audits passed unchanged.

Production-only generated-C audit, excluding unused test support: WebSocket `new_work` constructs Work plus two tokens (C 14578/14622/14696); Work.execute adds child/listener machinery (15098/15176/15235/15261). Masking constructs a userdata byte array then a copied string (23722/23914); frame encoding concatenates headers/masks/payload (24488/24575/24577/24636/24638). SSL supervision and async.run add Operation/Task/coroutine/listener roots. Raw TCP nonempty writes construct request/Operation; empty writes return early. Work release constructs a replacement works table. These are direct sites, not a complete per-operation count or a zero-copy claim; exact unit/source/object hashes and sites are in the summary.

## Reproduction and remaining work

Run from the repository with an owner-provided immutable readiness receipt and fresh private SSD output. Use the exact production receipt and provider pair above; do not reuse an unverified prefix or a historical source-fallback provider. Complete local build/process receipts stay outside the repository.

```sh
python3 spec/bench/websocket/measure.py plan
python3 spec/bench/websocket/measure.py build --repo . --output "$PRIVATE_OUTPUT" \
  --readiness "$OWNER_READY_JSON" --link-libraries pthread,rt
python3 spec/bench/websocket/measure.py audit --repo . --output "$PRIVATE_OUTPUT"
python3 spec/bench/websocket/measure.py allocations --repo . --output "$PRIVATE_OUTPUT"
python3 spec/bench/websocket/summarize.py "$ALLOCATION_JSON"
```

The preserved original artifact is `allocations-1791101775010029792.json`; supplemental `HELD8-MULTIGC.json` has SHA cb5150112d6633e55f79a69ee383abfb954604a974bc55366079cae548aefb9f. Its private runner diff and driver are receipt-bound. The strict-tail revalidation and accepted combined export retain both generations and all original artifacts. B2 bounds actual sampler returns and labels truncated samples insufficient; 16 host checks and two no-provider real-native-probe capacity boundary regressions passed. No production/provider change is requested. The separate uninstrumented timing/fairness report preserves background activity, short-lane and finite-sample qualifications. Linux diagnostics do not validate macOS or Windows.
