# Async allocation measurements

This developer harness measures Titan async workloads through Lua's allocator
and, separately, without the allocation hook. It requires Python 3.11+, a POSIX
C compiler, and an already installed Titan 0.6 / Lua 5.5 prefix. It builds only
private measurement consumers. It never prepares or installs a provider.
Linux is the validated platform. macOS command/RSS handling is included but
needs an actual macOS run; Windows is unsupported.

Keep output outside the source checkout. Use one fresh output directory for
each prefix, and an explicit shared fixture path when comparing providers.
For the Linux system-OpenSSL configuration used by issue 196:

```sh
python3 measure.py --prefix "$BASELINE_PREFIX" --output "$BASELINE_RESULTS" \
  --fixture "$SHARED_FIXTURE" --link-libraries pthread,rt,ssl,crypto build
python3 measure.py --prefix "$CANDIDATE_PREFIX" --output "$CANDIDATE_RESULTS" \
  --fixture "$SHARED_FIXTURE" --link-libraries pthread,rt,ssl,crypto build
python3 measure.py --output "$CANDIDATE_RESULTS" matrix
python3 measure.py --output "$CANDIDATE_RESULTS" audit
```

Set the shell variables to absolute paths first. The link inputs above belong
to that provider configuration; supply the appropriate `--link-libraries` for
another configuration. Tool command strings are configurable with `--cc`,
`--ar`, and `--ranlib` and are parsed into argv without a shell. Set
`--compiler-script` if the prefix has more than one installed compiler script.
The runner invokes the prefix's Lua plus the underlying compiler script, so
copied absolute-path launcher wrappers cannot select another installation.
The compile guard permits exactly the requested benchmark source and rejects
any `.titan` source fallback while importing installed modules.
`--source-manifest` attaches a frozen source manifest's hash to the build
receipt. It does not establish the provider/source correspondence itself.

The runner uses an explicit environment (PATH, C locale, UTC, configured tools,
private module/temporary paths and fixed one-job settings), disabling ccache
and persistent Titan probes. Ambient compiler include/library variables,
loader controls and allocator/thread-pool tuning are absent. It saves argv,
the complete subprocess environment, raw stdout/stderr, hashes, exit
status and timeouts per subprocess. Matrix rows point to their exact receipts.
`BUILD.json` binds the source payload, private consumers, native tool binaries,
compiler/provider files and explicit policy. Full prefix manifests before
build and subsequent `audit` calls detect additions, removals or changes in
file bytes, modes, mtimes or symlink targets. A single command verifies its
payload, private artifacts and selected provider files before execution;
matrix/comparison commands verify again after their complete batch. Keep native dependency and
provider build receipts alongside this output: the harness cannot reconstruct
how an existing provider was produced.
Output must be fresh and outside the prefix and harness source directory;
the fixture must also be outside the prefix. Paired comparisons require one
unchanged fixture path/content, identical Lua executable/archive bytes, tool
identity, payloads, helpers and consumer build policy. Each build archives its
source inputs, and recursively fingerprints all private artifacts.

## Allocation matrix

`matrix` runs exactly 122 processes: 18 workloads × 0/100/1,000 iterations ×
Lua and typed hosts, two whole-scope zero controls, and six 1,000-operation
GC-stopped workloads per host. Its payload sources are preserved from the
issue-196 baseline. New Completion-shape experiments belong in separate
fixtures, so they do not silently change this comparison.

The cases cover nil/false success and error, cleanup await, ordinary and
observed-status yield, FS stat/rejection/write/close, process-pipe write,
zero-duration sleep, subscription construction/next and queued/running Task
cancellation. Setup happens before the body boundary. Accounting continues
through teardown and one final forced GC. The result gives both body and
teardown snapshots, forced-GC wall/CPU cost, and whole-process RSS high-water
mark. Compare `(count1000 - count100)/900` steady slopes and show zero controls
separately. Preserve host, GC mode and scope labels.

The C hook handles Lua's `ptr == NULL` type tag correctly. Reallocation traffic
counts the successful new requested size, while live bytes change by the
new-minus-old size. The live ledger must exactly equal Lua's independent
post-GC heap count. The hook excludes allocations through other allocators,
including native library and coroutine-stack allocation. RSS includes setup,
mapped code and native state; it is not per-operation Lua allocation. On macOS
the raw probe's historic `process_peak_rss_kib` value is bytes, normalized to
KiB in the runner's parsed result; the untouched raw stdout remains evidence.

Post-GC heap totals include table/string/collector bookkeeping and finalizer
effects. They are not a proof that application contexts remain reachable.
Use explicit rooted-object/finalizer tests for retention. Likewise, cancellation
workloads are allocation scenarios, not semantic tests: sticky cancellation
can hide a sentinel raised after cancellation. The native correctness suite
owns cancellation, callback retirement and exception contracts.

## Quiet timing and latency

Build both harnesses before the quiet interval. Wait for all local native
builds and VM builds/tests to finish. Record that condition, date, machine,
VM state and relevant load evidence in a text file; the comparison requires
that note and stores it with process snapshots. It cannot detect activity
inside a VM from the host process table.

```sh
python3 compare.py --baseline "$BASELINE_RESULTS" \
  --candidate "$CANDIDATE_RESULTS" --output "$PAIRED_RESULTS" \
  --quiescence-note "$QUIESCENCE_NOTE"
```

The runner pilots both lanes and calibrates a common iteration count using
the shorter duration, bounded by `--max-count`. Calibration and warmup runs
are labeled and excluded from summaries. It then alternates baseline/candidate
order for seven paired repeats. Report median and range of wall and process
CPU time, with the workload count and short-sample flag. Do not infer speed
from instrumented matrix clocks or reuse development-time baseline timings.
Timing uses the original bodies with the allocation hook disabled; allocation
counters and peak-Lua fields in those rows are intentionally uninterpreted.

The separate latency probe measures per-Task yield-return intervals with
1/16/64/256 Tasks while a raw repeating 1 ms UV timer runs. It records
p50/p95/p99/max intervals and counts in native preallocated sample arrays.
The timer result is interarrival spacing, not timer-deadline lateness. Sampling
adds the same clock/call overhead to both lanes, so this is a fairness/latency
workload, not pure yield throughput. Calibration seeks at least 100 timer
intervals and 250 ms, bounded by the sample capacity; report insufficient
samples explicitly. Never report an empty timer sample set as zero latency.

The private output contains generated C for the benchmark consumers. A final
provider generated-C survey must additionally use the exact C compiled for
the canonical provider, tied to its source/compiler/compile-argv hashes.
Distinguish direct static allocation sites, branch execution frequency and
measured transitive totals; zero sites in one helper does not mean zero cost.
