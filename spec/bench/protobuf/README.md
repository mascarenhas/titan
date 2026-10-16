# Protobuf performance measurements

This Linux x86-64 harness measures an installed **production** Titan SDK. Build
that SDK in its own source copy and prefix using the ordinary
[repository workflow](../../../doc/implementation/repository-workflow.md).
Production and validation must not share native build outputs. The harness
creates only private consumers and never installs or modifies the selected SDK.

Python 3, GCC, GNU `addr2line`, and the matching Lua/Titan SDK are required.
The sampling helper uses Linux `SIGPROF` and x86-64 instruction pointers; it does
not require privileged performance counters or a kernel profiler. Run from any
directory with absolute paths:

```sh
python3 spec/bench/protobuf/measure.py build \
  --prefix /absolute/production-sdk --output /absolute/new-results
# Stop or wait for competing builds/tests, then record the actual quiet state.
python3 spec/bench/protobuf/measure.py run \
  --output /absolute/new-results --cpu 2 \
  --quiet-note /absolute/quiet-state.txt
python3 spec/bench/protobuf/analyze.py /absolute/new-results
# Optional: repeat every unsampled timing after competing work finishes.
python3 spec/bench/protobuf/measure.py recheck \
  --output /absolute/new-results --cpu 2 \
  --quiet-note /absolute/recheck-state.txt
# Build a second consumer with exactly the same benchmark source, then compare.
python3 spec/bench/protobuf/compare.py \
  --before /absolute/new-results --after /absolute/candidate-results \
  --output /absolute/new-comparison --cpu 2 \
  --quiet-note /absolute/comparison-state.txt
```

Choose an allowed CPU appropriate for the host. `build` requires a fresh output
directory and records source, executable, provider hashes, compiler commands,
and explicit environment. An optional `--source-manifest` attaches a frozen
provider source manifest; retain the normal SDK build logs beside it. `run`
records hardware, CPU affinity, process names/load, raw repetitions, and the
quiet-state note. It refuses to overwrite a previous measurement matrix.
`recheck` preserves the same executable and fixtures, records five fresh-process
500 ms batches by default, and saves a separate `recheck.json`.
`compare` requires the baseline's `summary.json` and two completed consumer
builds. It verifies executable and consumer-source hashes plus independent
fixture bytes, then runs five alternating fresh-process pairs with equal
operation counts. The baseline timings select counts targeting 500 ms of CPU;
candidate durations vary with its performance. It also samples four decoder
shapes in separate control/sampled pairs. Its fresh output directory retains
every pair, medians, ranges, ratios, and resolved profiles.

The eleven shapes cover 4/16/64 integer fields, 16/4,096-byte strings, nested
records, an active union payload, 8/256 integers, and 8/128 four-field records
inside Arrays. Python independently produces their exact wire bytes. Each
consumer execution checks serialized bytes or re-serializes the final decoded
value after the measurement boundary. No workers or asynchronous operations
run in the benchmark.

Each fresh process constructs inputs before timing. First-call samples then
include first nominal descriptor hydration but exclude process startup and
module initialization. The cold decoder receives an unresolved named type.
Warm batches use 64 warmup operations and a cached, resolved root descriptor;
internal nested type resolution remains part of the codec. A full collection
before each batch makes starting garbage consistent. Collections occurring
during the batch count; process teardown and validation of the result do not.

Headline timings have sampling disabled. Five fresh-process repetitions target
250 ms of process CPU each; the runner reports both wall and CPU time. A
separate pair of long batches compares the same operation count with sampling
off/on. Sampling targets five CPU seconds per shape and operation by default.
The requested timer interval is 1 ms; use the actual sample count and measured
CPU time, because kernel delivery granularity can differ. The handler only
stores instruction pointers in preallocated lock-free atomic storage and
updates `sig_atomic_t` counters. Symbol/line resolution happens after timing.

`summary.json` preserves medians/ranges, raw first-call times, sampling overhead,
counts, and exclusive categories. Every sampled address, inline chain, and
classification is retained in the `*.resolved.json` files. The categories keep
direct reflected APIs/generated projection and construction separate from
descriptor resolution, generic codec dispatch/traversal, wire-field
lookup, wire parsing/writing, buffers, and shared runtime/allocator/GC work.

Exclusive samples are **not** an inclusive attribution of all costs caused by
reflection. An allocator or collector interrupted inside a reflected call still
lands in the shared bucket; generated construction includes necessary target
object work. Likewise, generic traversal contains validation and loop work
which specialization would not eliminate completely. A percentage therefore
does not directly predict a specialization speedup. The baseline width sweep
exposed repeated linear `Message:last`/`merged` scans, independently of
reflected-field access. The paired follow-up compares that implementation with
a sparse field index built only when a multi-field message needs lookup.

The [issue 242 report](../../../doc/implementation/protobuf-performance-results.md)
records measured results and interpretation.
