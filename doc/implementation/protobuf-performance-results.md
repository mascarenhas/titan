# Protocol Buffers performance results

This production-build measurement finds that direct reflection APIs and generated
projection/construction account for about **0–11% of exclusive CPU samples** in
these workloads. Descriptor resolution adds roughly **0.4–1.5%**. Shared
allocator/collector work is much larger, **45–71%**, and the 64-field decoder
spends **21%** of samples rescanning parsed fields. These are useful priorities
for experiments; they do not establish how much total allocation reflection
caused or how much faster a compiler-specialized codec would be.

The results describe the protobuf implementation at `88e54cd8`, measured on
2026-10-16 UTC before record transfer hooks were added. The reproducible
[harness](../../spec/bench/protobuf/README.md) and compact
[machine-readable results](../../spec/bench/protobuf/results-issue242.json)
retain both timing windows, repetitions, sample counts, categories, and hashes.
No codec optimization was applied for this study.

## Production build and timing boundary

The source copy, native build outputs, and SDK prefix were isolated from the
validation build. The consumer linked statically to the immutable production
SDK, with no asynchronous bootstrap or worker. GCC 16.2.1 compiled the generated C
with `-O3 -g1 -flto=auto -ffat-lto-objects`; the platform was Linux x86-64 with
glibc 2.43. The host was an AMD Ryzen AI 9 HX 370 (12 physical cores, 24 logical
CPUs). Only benchmark children were pinned to logical CPU 9, whose SMT sibling
is CPU 21. The host retained its `powersave` governor, `balance_performance`
preference, and 3,289,474 kHz scaling maximum. No unrelated process affinity or
system power setting was changed.

Input objects and independently generated Python wire fixtures are constructed
before timing. Each execution validates its final serialization, or reserializes
its final decoded value, against the exact fixture after timing. This catches
both dropped work and a codec/harness round-trip agreeing on incorrect bytes.
All eleven shapes passed cold and warm checks in both directions.

Warm measurements use 64 warmup operations and a cached, resolved root type;
internal nested resolution remains part of the codec. A full collection runs
before the batch. Collections during the batch are included, while validation,
process startup, module initialization, and teardown are excluded. First-call
samples instead retain an unresolved named type and include descriptor hydration.
They are a different GC regime: a single allocation-heavy call can finish before
the collections needed during a long steady-state batch, so “cold” is not always
slower for large Arrays.

## Warm latency

All figures are **microseconds per operation**, median with minimum–maximum in
parentheses, from five fresh-process unsampled batches targeting 500 ms of CPU
each. Wire size is the actual encoded fixture size. These are the second-window
results, after all task-created Windows/macOS validation and local builds had
finished. A pre-existing service in the Mac guest and normal desktop activity
remained; this is not an otherwise idle laboratory host.

| Workload | Wire bytes | Serialize µs | Deserialize µs |
| --- | ---: | ---: | ---: |
| 4 integer fields | 8 | 1.56 (1.54–2.23) | 2.29 (2.29–3.67) |
| 16 integer fields | 38 | 4.20 (4.17–4.30) | 8.54 (8.43–8.57) |
| 64 integer fields | 230 | 18.79 (18.68–19.50) | 51.53 (50.67–51.99) |
| 16-byte string + integer | 20 | 1.18 (1.17–1.50) | 1.45 (1.44–1.52) |
| 4,096-byte string + integer | 4,101 | 2.18 (2.16–2.24) | 2.64 (2.64–2.72) |
| Two nested 4-field records + string | 28 | 4.58 (4.53–5.57) | 8.03 (7.86–8.28) |
| Active union with integer + record | 14 | 3.33 (3.30–3.37) | 5.67 (5.63–5.96) |
| Array of 8 integers | 36 | 7.48 (7.35–7.57) | 12.01 (10.93–14.15) |
| Array of 256 integers | 1,274 | 199.46 (192.12–202.22) | 304.71 (304.52–316.82) |
| Array of 8 four-field records | 100 | 20.52 (20.42–20.96) | 36.03 (35.73–36.39) |
| Array of 128 four-field records | 1,803 | 330.54 (328.99–333.79) | 638.29 (624.81–702.48) |

The initial matrix used five 250 ms batches while VM validation was active.
Repeating every row after that work finished changed most medians modestly,
but the active-union serializer fell from 5.82 to 3.33 µs. The repeated matrix
above is therefore the headline, and the JSON retains the initial matrix rather
than averaging unlike conditions. Most rows are stable within the reported
range; the smallest records and 8-integer decoder still have outliers.
Median wall/CPU ratios in the repeat were 1.004–1.008. That rules out substantial
descheduling in those batches, but does not remove frequency, cache, allocator,
or background-interference effects.

The five initial first-call samples had medians of 60/62 µs for the four-field
record and 162/167 µs for the 64-field record (serialize/deserialize). They include
first descriptor hydration and were collected during the earlier VM activity.
Full first-call data is retained for each shape; those numbers should not be
used as a clean cold-versus-warm speedup ratio.

## Exclusive sampled attribution

A separate pair of long batches used equal operation counts with sampling off
and on, alternating pair order across workloads. The sampler requested a 1 ms
`SIGPROF` interval and recorded only the interrupted instruction pointer into
preallocated lock-free storage. It did no allocation, symbol lookup, or output
inside the signal handler. Offline `addr2line` resolution retained LTO inline
chains. The classification uses the innermost resolved frame, which makes the
following percentages **exclusive**, not inclusive call-stack costs.

There were 112,717 samples across 22 profiles, with no drops and 0.2–0.7%
unresolved per profile. Profiles targeted five CPU seconds each and yielded
3,651–6,676 samples. These profiles belong to the initial window with concurrent
VM activity: sampled/control CPU ratios ranged from 0.834 to 1.273. A ratio below
one is timing variability, not negative profiling overhead. Treat the broad
categories as diagnostic evidence rather than precise comparative percentages.

“Direct reflection” below combines the reflection API and generated member
projection/default-construction callbacks. “Descriptors” is codec type
resolution. “Traversal” is generic codec dispatch, validation, recursion, and
loops. “Field scan” is `Message:last`/`merged`. Shared allocator/GC includes the
Lua allocator and collector and the C allocator; it remains shared because an
instruction-only sample cannot identify which higher-level operation caused it.
Remaining samples belong to wire parsing/writing, strings/buffers/copies, other
runtime work, or unresolved addresses; all categories are retained in JSON.

| Workload / operation | Direct reflection | Descriptors | Traversal | Field scan | Shared allocator/GC | Samples |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `flat4` serialize | 10.1% | 0.9% | 4.4% | 0.0% | 51.3% | 4,598 |
| `flat4` deserialize | 0.8% | 1.2% | 3.5% | 2.3% | 64.2% | 5,107 |
| `flat16` serialize | 10.9% | 1.5% | 4.1% | 0.0% | 45.2% | 5,295 |
| `flat16` deserialize | 0.3% | 1.0% | 3.4% | 8.8% | 59.4% | 5,052 |
| `flat64` serialize | 9.2% | 1.2% | 3.4% | 0.0% | 49.6% | 5,755 |
| `flat64` deserialize | 0.1% | 0.6% | 3.1% | 21.2% | 53.3% | 4,917 |
| `bytes4096` serialize | 4.4% | 0.4% | 3.0% | 0.0% | 65.8% | 5,193 |
| `bytes4096` deserialize | 0.7% | 0.5% | 2.5% | 0.9% | 71.2% | 4,507 |
| `nested` serialize | 9.7% | 1.4% | 4.2% | 0.0% | 54.2% | 5,689 |
| `nested` deserialize | 1.5% | 0.9% | 3.7% | 2.3% | 66.9% | 6,676 |
| `union` serialize | 7.7% | 0.9% | 5.0% | 0.0% | 57.3% | 3,651 |
| `union` deserialize | 1.5% | 0.9% | 2.8% | 1.7% | 67.3% | 4,387 |
| `ints256` serialize | 0.1% | 0.5% | 3.4% | 0.0% | 61.1% | 5,230 |
| `ints256` deserialize | 0.0% | 0.5% | 2.4% | 1.5% | 69.3% | 5,190 |
| `records128` serialize | 6.5% | 0.9% | 3.8% | 0.0% | 56.0% | 5,534 |
| `records128` deserialize | 1.1% | 0.8% | 3.2% | 2.0% | 66.0% | 6,246 |

Ordinary scalar projection returns through stack-rooted `TValue` storage; this
measurement does not support a claim that each reflected scalar field allocates
an object. Native construction also includes required destination-object work,
which compiler specialization would still need. Conversely, reflection-induced
allocation and GC appear in shared buckets. Adding the direct percentages and
applying Amdahl’s law would therefore give an unsupported speedup estimate.

## What to investigate next

The first promising experiments are narrower than a full compiler extension:

1. **Avoid repeated decoder scans.** `decode_record` asks `decode_field` for each
   declared field; `Message:last` scans all parsed fields each time, and embedded
   messages additionally use `merged`. This explains the width-sensitive field
   scan bucket and offers a codec-local indexing or single-pass experiment.
   Preserve last-value and embedded-message merge behavior.
2. **Reduce transient encoding/decoding objects.** `write_varint` calls
   `string.char` for each emitted byte; its implementation allocates temporary
   foreign storage. Array encoding creates a writer for each slot, while decoding
   allocates `WireField` records and intermediate message/slot Arrays. Allocation
   reduction is a source-grounded hypothesis consistent with the large shared
   allocator/GC bucket, not an attribution of that entire bucket to these sites.
3. **Prototype one typed encoder and decoder before generalizing.** Compare the
   same production build, fixtures, presence/merge checks, and warm timing
   boundary. A prototype can measure the combined reduction in dispatch,
   descriptor access, intermediates, and GC that instruction-only profiling
   cannot separate. Include small and wide records plus record Arrays, then
   measure code size and first-call cost as well as throughput.

The current evidence supports investigating intermediate allocation and field
lookup first. It neither rules out a useful compiler-specialized codec nor shows
that replacing direct reflected field access alone would deliver a large gain.
