# Archived issue benchmarks

Benchmark harnesses, native probes, raw measurement tables, and historical
evidence bundles are archived as GitHub pre-release ZIP assets and linked from
their tracking issues rather than kept under `spec/bench/` in the repository
tree. Each archive preserves its original repository-relative paths and
includes a top-level `README.issue<N>.md` and `SHA256SUMS` manifest.

## Index of archived benchmarks

| Issue | Area | Pre-release tag | Archive asset & SHA-256 | Issue summary comment | Retained implementation chapters |
|---|---|---|---|---|---|
| [#193](https://github.com/mascarenhas/titan/issues/193) | `titan.websocket` allocation slopes, paired body timing, and buffered fairness | [`issue-193-benchmark-archive`](https://github.com/mascarenhas/titan/releases/tag/issue-193-benchmark-archive) | [`websocket-benchmark-issue193.zip`](https://github.com/mascarenhas/titan/releases/download/issue-193-benchmark-archive/websocket-benchmark-issue193.zip) (`70,474` bytes, `744124c55a55c4be0e6a861f9fbcc2f30c23b93fb93acc4b5620927074e8ffa9`) | [Issue #193 comment](https://github.com/mascarenhas/titan/issues/193#issuecomment-6256764058) | [WebSocket allocation and lifetime results](websocket-allocation-results.md), [WebSocket timing and fairness observations](websocket-benchmark-results.md) |
| [#196](https://github.com/mascarenhas/titan/issues/196) | `titan.async` / `titan.uv` Completion allocation, retention, and yield/timer latency | [`issue-196-benchmark-archive`](https://github.com/mascarenhas/titan/releases/tag/issue-196-benchmark-archive) | [`async-allocations-benchmark-issue196.zip`](https://github.com/mascarenhas/titan/releases/download/issue-196-benchmark-archive/async-allocations-benchmark-issue196.zip) (`74,220` bytes, `cc54cef08657f23ab5e96fa4459d65b3cefa60c2ae3eea687874577e7d68e3c2`) | [Issue #196 comment](https://github.com/mascarenhas/titan/issues/196#issuecomment-6256763917) | [Async and I/O allocation results](async-allocation-results.md) |
| [#242](https://github.com/mascarenhas/titan/issues/242) | `titan.protobuf` reflection/allocation attribution and lazy field-index decoder comparison | [`issue-242-benchmark-archive`](https://github.com/mascarenhas/titan/releases/tag/issue-242-benchmark-archive) | [`protobuf-benchmark-issue242.zip`](https://github.com/mascarenhas/titan/releases/download/issue-242-benchmark-archive/protobuf-benchmark-issue242.zip) (`58,255` bytes, `3dfb271d33c583265e5e60a09881332221ad5cca00aa8f49312ad351027c845d`) | [Issue #242 comment](https://github.com/mascarenhas/titan/issues/242#issuecomment-6208073173) | [Protocol Buffers-library implementation](protobuf-library.md) |
| [#252](https://github.com/mascarenhas/titan/issues/252) | `titan.thread` / `titan.transfer` / `titan.async` cross-thread RTT, MPMC fairness, packet-scoped resource ownership, and shared external-wake / OS-join retirement | [`issue-252-benchmark-archive`](https://github.com/mascarenhas/titan/releases/tag/issue-252-benchmark-archive) | [`thread-rtt-benchmark-issue252.zip`](https://github.com/mascarenhas/titan/releases/download/issue-252-benchmark-archive/thread-rtt-benchmark-issue252.zip) (`68,591,123` bytes, `80ef1001dab48528655a7815d02b1fc93ae35d2974c7df2f4ae94b8d54c8773e`) | [Issue #252 comment](https://github.com/mascarenhas/titan/issues/252#issuecomment-6256763768) | [Thread-library implementation](thread-library.md), [Transfer-policy implementation](transfer-library.md), [Async runtime and public libuv ownership](libuv-runtime.md) |

## Verification and extraction

After downloading an archive from its pre-release page, verify its outer digest
against the table above and check its internal file inventory with:

```sh
unzip <archive-name>.zip -d <target-dir>
cd <target-dir>
sha256sum -c SHA256SUMS
```
