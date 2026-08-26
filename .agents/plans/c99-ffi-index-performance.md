# C99 and FFI indexing performance

Status: all four workstreams and the fresh trace-level Titan-repository profile
are complete. Both complete local gates are green; publication and CI evidence
remain.

This plan records the compiler-side work discovered while profiling cold Titan
language-server indexing. It complements the language-server cache and
invalidation work: parser improvements reduce ordinary compiler and cold-index
cost, while safe reuse of unchanged C-header results avoids repeating that cost
across resolver contexts and compiler passes.

## Measured baseline and suspected causes

An instrumented cold index of the Titan repository performed two equivalent
compiler passes over the same unchanged project state. Across those passes the
compiler called `cdriver.process_file` 342 times (171 per pass). Representative
single-header phase measurements were:

| input | preprocessed bytes | preprocessing | C translation-unit PEG | C type conversion | macro definitions |
|---|---:|---:|---:|---:|---:|
| `lua.h` | 12,431 | 0.151s | 0.003s | 0.002s | 0.026s |
| `uv.h` | 97,394 | 0.757s | 0.018s | 0.022s | 0.079s |
| `openssl/ssl.h` | 512,123 | 3.303s | 0.094s | 0.112s | 0.925s |

The complete C translation-unit PEG is approximately linear on these real
inputs and is not the dominant header phase. Five narrower paths needed work:

- The C assignment-expression production retries an entire recursive unary
  expression before falling back to a conditional expression. Parenthesized
  non-assignment expressions can therefore multiply the repeated prefix at
  each nesting level.
- Typed macro-expression parsing currently copies the complete typedef-name
  set for every macro. `openssl/ssl.h` triggered about 11,952 typed expression
  parses with about 856 typedef names, or roughly 10.2 million table visits,
  before parsing the expressions themselves.
- Top-level recovery retries `externalDeclaration` after every skipped token.
  A long failed leading declaration-specifier run is therefore reparsed at
  every suffix: 160, 320, 640, and 1,280 repeated `int` tokens took 4.3ms,
  16.9ms, 69.2ms, and 269.6ms, respectively.
- `parameterTypeList` first parses the complete parameter list as a possible
  vararg list, then reparses it as an ordinary list. Nested callback parameters
  therefore double the complete inner declarator traversal at every level.
- `structDeclaration` first parses an inline union as a possible anonymous
  member, then reparses the complete body when a field declarator follows.
  Nested named inline-union members therefore have the same doubling defect.

Header preprocessing, repeated header identities, and reuse boundaries remain
a separate coordinated workstream so a parser fix does not hide redundant
calls.

Within either 171-call pass, the trace contained only 96 distinct complete
ordered dependency/search-input identities and 31 distinct `(header spelling,
resolved header)` pairs (26 successful). The second pass repeated the first
pass's complete 171-call sequence exactly. A cache retaining the current
workload's successful semantic header contexts can therefore avoid both
same-pass duplication and all unchanged second-pass parses after restatting
their precise observed inputs.

## Invariants

- Preserve the public `c99` parser entry points and all non-assignment
  C-expression AST shapes. Publish a proper right-folded assignment tree where
  the old recursive production consumed but discarded the operator and RHS.
- Preserve C operator precedence and associativity. Assignment operators are
  right-associative and must be parsed as an operand/tail repetition with a
  right fold, without recursively retrying the left prefix. Retain C's
  syntactic requirement that every assignment left-hand side be recognized as
  a unary expression; semantic lvalue validity remains the C compiler's job.
- Treat typedef-name maps as borrowed, immutable input during the synchronous
  typed-expression match. Restore parser-global state on success and failure;
  do not retain the caller's table afterward.
- Keep parser state deliberately non-reentrant unless a separate change
  redesigns the existing module-global state.
- Keep Titan's semantic/package version at `0.6.0`, the derived library/search
  path version at `0.6`, and the ABI at `2`. This unreleased work does not
  introduce an API- or ABI-version bump.
- Do not change accepted Titan syntax or language-server protocol behavior as
  part of these compiler optimizations.

## Workstream A: C99 PEG and macro parsing

- [x] Establish deterministic scaling baselines for nested parenthesized
  expressions, assignment chains, malformed translation-unit recovery, and
  typed expressions across increasing typedef-set sizes.
- [x] Replace the recursive-prefix assignment choice in
  `c-parser/c99.lua` with a flat capture and right fold, preserving AST nodes
  and operator spellings.
- [x] Borrow the caller's typedef-name set for the duration of
  `match_typed_language_expression_grammar` instead of copying every truthy
  entry for every macro expression.
- [x] Audit nearby operator, list, declarator, and recovery productions for the
  same recursive ordered-choice shape. Fix only demonstrated unbounded
  recurrences; record bounded constant-factor choices rather than broadening
  the grammar rewrite.
- [x] Add focused C parser/cdefines regressions, including right-associative
  assignment structure, a non-wall-clock nested-expression traversal guard,
  typedef-map non-traversal, parser-state restoration after failure, linear
  failed-specifier recovery, and resynchronization after unsupported prefixes.
- [x] Re-run the synthetic scaling probes and the representative real-header
  phase profile, retaining before/after counts and CPU measurements.

The assignment factor reduced the Lua instruction count for 18 nested ordinary
parentheses from 81,678,400 to about 2,800; depths 4 through 18 previously
multiplied by almost exactly four every two levels and now grow linearly. A
2,000-operator assignment chain now parses and right-folds in about 7.7ms
rather than exhausting LPeg's backtrack stack around 200 operators. The same
fix reduced combined typed and ordinary macro-expression CPU for `titan/ffi.h`
from about 0.30s to 0.014s.

Factoring the optional vararg tail reduced a 16-level nested callback
declaration from about 4,967,000 Lua instructions and 0.36s to about 500
instructions and 0.3ms. A 20-level baseline required about 79,471,000
instructions and 5.0s, while the factored grammar remained around 600
instructions and 0.1ms. Ordinary and vararg callback ASTs remain deep-equal.

Factoring the inline-union body from its optional field-declarator suffix
reduced a 16-level named inline-union fixture from over three million Lua
instructions to about 400; depths 1 through 28 now grow linearly. Anonymous and
named inline-union ASTs remain deep-equal to the old grammar.

Borrowing the typedef map made a single representative typed-cast parse flat at
roughly 6-8 microseconds from zero through 10,000 typedef names. Beforeward it
rose from about 18 microseconds with no extra names to 760 microseconds at
10,000. Progress-aware recovery now records the end of a failed top-level
specifier prefix and advances over that already-explored run once; 160, 320,
640, 1,280, 2,560, and 5,120 repeated specifiers took approximately 0.11ms,
0.16ms, 0.27ms, 0.53ms, 1.39ms, and 2.14ms. At 640 tokens the deterministic
instruction count fell from 2,594,300 to 16,800.

The optimized grammar produced deep-equal declaration ASTs for the exact
flattened `lua.h` (12,431 bytes, 209 declarations), `uv.h` (97,394 bytes,
1,270 declarations), and `openssl/ssl.h` (512,123 bytes, 5,826 declarations)
inputs. `uv.h` recovery reports 71 rather than 72 units because one failed
specifier run is now advanced as one unit; its declaration AST is unchanged.

## Workstream B: repeated-header reuse

The cache lives in `c-parser/cdriver.lua`, weakly scoped to the compiler I/O
strategy shared by a long-lived language-server compiler instance. Production
retains every successful completed header graph for that provider's lifetime:
the entry and weight limits are `math.maxinteger`, and production skips the
recursive graph-weight walk entirely. This deliberately favors lower repeated
developer-tool latency over a small resident-memory bound. A focused test hook
still installs finite count and approximate retained-graph limits, exercises
LRU/oversized behavior, and charges table/slot storage, every string occurrence,
and the preprocessor's weak-side-table token spelling/spacing metadata. A replay
of the exact 342-request trace had projected 201, 232, and 270 hits at entry
bounds 8, 12, and 16, versus 302 when all 26 successful headers remain; that
initial bounded policy is retained below only as a measured comparison.

`c-parser/cpp.lua` publishes its existing exact ordered compiler-argv/forced-
header configuration key, extended with the explicit language mode and a
deterministic digest of the authoritative include roots and predefined macro
world reported by that compiler. `cdriver` combines
that context with the provider's current working directory, requested spelling,
and selected absolute header, reduces the complete tuple to a fixed-size
SHA-256 cache key, and, under a finite test budget, charges that key, the actual
entry table, and its cache hash slot together. It deliberately does not key on
`source_dir`:
the current caller resolves and observes its own top-level candidates first,
while the reusable entry owns only the dependency/search tail observed from
the selected header.

Before a hit, `cdriver` recomputes and compares every cached direct/transitive
file identity (content SHA-256 plus followed stat identity) and every cached
include-search identity (lstat, followed stat, and readability). It then joins
that stable parse tail to the current caller's already observed forced-header
and top-level-search prefix. A changed byte, replaced file, retargeted symlink,
new shadowing candidate, forced-header context, ordered flag/include root,
language mode, compiler argv, or I/O provider therefore misses or invalidates.
Only successful completed results are retained. Because identity validation can
yield, a prospective hit verifies that the same entry is still current after
validation; if another task replaced it meanwhile, the caller retries against
the replacement rather than returning a detached stale graph.

Cached raw C types and their attached macro graph are stored as one private
graph and cloned again for every hit with `cpp`'s sidecar-aware graph copier.
This preserves internal aliases, cycles, and stringification/token-pasting
spelling while preventing checker conversion or caller mutation from changing
the retained entry, the preprocessor probe baseline, or a later resolver's
result. The small public context is reconstructed per call from that macro
graph and the caller's input observations; flattened preprocessor
output/origins, directory/include state, strategy, and observer closures are
never retained.

- [x] Measure complete repeated header identities and same-pass/cross-pass
  duplication in the Titan cold-index workload.
- [x] Identify header work by complete ordered preprocessing configuration,
  selected header, and restattable transitive inputs rather than pathname alone.
- [x] Reuse completed results across resolver contexts without sharing mutable
  parser, cdefines, macro, or CType graphs.
- [x] Invalidate exact bytes, transitive includes, search shadowing,
  macro/config inputs, compiler context, and provider identity; exclude failures.
- [x] Add focused hit, caller-search reconstruction, graph-isolation,
  transitive-byte invalidation, provider-scope, yielded same-key completion,
  yielded hit replacement, macro-token sidecar preservation, probe-baseline
  isolation, provider-lifetime retention beyond the former production bound,
  finite hit-refreshed LRU, weight eviction, oversized rejection, and
  failure-exclusion tests.
- [x] Re-run the cold-index trace after both workstreams land and record cache
  hits, residual parses, CPU/wall time, and peak memory.
- [x] Refresh the cache trace's exact weight/counter measurements after the
  final fixed-key and entry-overhead accounting refinement.

The final provider-lifetime controlled trace retained at
`/tmp/titan-cache-final-unbounded.kL4lgP.tsv` made the same 342 requests and
produced the same 3,783 diagnostics and 89 snapshots in each of two deliberately
preserved fixed-point passes. Its SHA-256 is
`df249037100810d0a2777fdb8c30c7edeaf52d915c0a55f221ed2d60bf8a385c`.
It recorded 302 hits, 40 misses (26 successful real parses and 14 expected
failures), 26 stores, zero evictions, zero oversized rejections, and 26 retained
entries. Header processing consumed 53.769s CPU (31.601s validating/cloning
hits, 22.095s successful misses, and 0.073s failed misses), 25.29% below the
71.970s bounded-cache result and 68.21% below the uncached 169.150s result.
End-to-end controlled indexing took 190.372s wall and 160.387s compiler-attempt
CPU, 6.38% / 7.28% below the bounded result and 42.05% / 41.65% below the
uncached baseline. Peak server RSS was 1,517,000 KiB (1.447 GiB), 23.73% above
the bounded run; sampled process-tree peak was 1,570,944 KiB (1.498 GiB) and
includes transient compiler children. An immediately preceding measurement-
only run of the same 26 retained graphs estimated 294,384,594 bytes of graph
weight; final production stats intentionally report `tracks_weight=false` and
do not pay that traversal cost.

With the language server's redundant cold fixed-point analysis removed, the
final clean-build actual-usage run indexed the Titan checkout in one compiler
analysis: 117.966s wall, 88.683s compiler-attempt CPU, 69 root attempts, 89
project snapshots, and the same 3,783 diagnostics. It built the semantic index
for the same 43 files and 8,530 occurrences. Peak server RSS was 1,495,236 KiB
(1.426 GiB), and the sampled process-tree peak was 1,549,384 KiB (1.478 GiB).
Relative to the earlier bounded-cache one-pass run at 130.209s / 92.242s, the
provider-lifetime policy reduced wall time by 9.40% and attempt CPU by 3.86%
while increasing peak server RSS by 20.44%. Relative to the original uncached/
two-pass 328.526s wall and 274.873s attempt-CPU baseline, the combined parser,
cache, and language-server work reduced wall time by 64.09% and compiler-
attempt CPU by 67.74%. The controlled 342-request trace above remains the
cache-specific comparison because it intentionally preserves both identical
passes; the integrated run verifies the shipped one-pass path.

## Workstream C: one-analysis validation and graph reuse

Issue #107 follows the provider-lifetime cache rather than replacing it. The
normal one-pass Titan-repository index still spent 12.635s CPU validating and
cloning completed-cache hits: `lua.h` accounted for 49 hits and 4.205s,
`titan/ffi.h` for 27 hits and 4.260s, `lauxlib.h` for 11 hits and 1.403s, and
`uv.h` for three hits and 0.907s. Those repeated calls belong to fresh resolver
contexts created for roots within one compatible compiler analysis.

The language-server bridge creates one explicit C-header analysis object for
each `analyze_incremental` call and passes it through every resolver context,
target-profile acquisition, probe service, and cdriver request in that call.
The process cache remains provider-owned and authoritative. A completed entry
must pass its exact dependency/search validation once before the analysis may
remember it; after any yielding validation, the caller must still prove that
the same cache entry is current. A later analysis receives a fresh object and
therefore revalidates. Ordinary cdriver callers that supply no analysis object
retain the existing clone-per-hit isolation contract.

Within one analysis, the first compatible retained-cache hit receives one
private clone and later root resolvers share that analysis-owned graph. A miss
continues returning its caller-owned graph while retaining a separate private
process-cache clone; if that miss successfully publishes the cache entry, the
same live graph may become the analysis-owned view. Separate analyses and
ordinary callers never share mutable graphs. The project service's existing
just-before-publication restat of both prior and newly observed complete header
closures remains unchanged and authoritative if files move while an analysis
is in flight.

- [x] Emit trace-level per-root/per-header phase events for cache-hit
  validation, graph cloning/reuse, preprocessing, C parsing, CType/macro
  conversion, and downstream Titan FFI conversion.
- [x] Capture a fresh normal one-pass Titan-repository baseline from those
  events, including aggregate/per-header hit CPU, attempt CPU/wall, and RSS.
- [x] Plumb one explicit analysis object through the driver and cprobe without
  changing preprocessing configuration keys or the released compiler API/ABI
  versions.
- [x] Reuse successful validation and one analysis-owned graph only for the
  exact still-current process-cache entry; preserve yielded same-key
  replacement retries, prefix compatibility, failure exclusion, and complete
  dependency/search provenance.
- [x] Add deterministic regressions for identity-read counts, clone counts,
  separate-analysis isolation, exact header/search/config/provider changes,
  and replacement during yielding validation.
- [x] Rebuild vscode-titan's isolated compiler, run both complete gates, and
  benchmark cold plus representative saved-edit reindex CPU/wall/RSS.
- [x] Keep Titan `0.6.0`, library path `0.6`, ABI `2`, and the unreleased
  language-server API marker unchanged.

The fresh pre-reuse trace is `/tmp/titan-107-baseline.json`, SHA-256
`e2700de0bc0501ce2931623a4412558722fa126b54fd10770dca6ff70eb85e5a`.
It captured one normal 69-root analysis with 89 snapshots, 3,783 diagnostics,
92.629s compiler-attempt CPU, 92.648s analysis CPU, and 1,580,328 KiB direct
peak RSS. Its 138 completed-cache hits spent 10.324s validating dependency and
search identities plus 2.030s cloning graphs, or 12.354s combined. Downstream
Titan FFI conversion accounted for another 26.974s. The original harness
subsequently started a hover-triggered cancelled chain, so its process elapsed
and terminal-chain wall fields are deliberately not used as the cold-chain
wall baseline.

The validated post-reuse artifact is `/tmp/titan-107-post-analysis.json`,
SHA-256
`3f60c7943a83112107c15b28cab0c5c8dba9c5612015d5fcf92f8c427423cc55`.
Its exactly correlated cold pass took 121.717s wall and 94.288s pass CPU;
compiler attempts consumed 81.948s CPU and the compiler analysis consumed
81.975s. All 138 repeated calls used the analysis-owned entry: validation
bookkeeping took 7.539ms and graph-reuse bookkeeping took 0.150ms, 7.689ms
combined. That removes 12.346s, or 99.94%, of the repeated hit work and reduces
attempt CPU by 10.681s (11.53%) without changing the 89 snapshots, 3,783
diagnostics, 43 semantic files, or 8,530 occurrences. Direct peak RSS rose to
2,001,148 KiB, 420,820 KiB (26.63%) above the fresh baseline, because the
analysis deliberately owns one live graph for every successful header in
addition to the provider cache's isolated graph.

A saved line-comment edit to
`spec/stdlib/titan/fs/test_support.titan` then produced one clean, correlated
one-module publication. It took 29.498s status wall and 29.110s pass CPU. The
single compiler attempt used 1.546s CPU, while the fresh analysis deliberately
revalidated and cloned five process-cache graphs in 650.370ms and downstream
FFI conversion used 434.809ms. The complete analysis phase consumed 13.684s
and project refresh consumed 28.888s, showing that most remaining saved-edit
latency lies outside compiler/header work. Direct sampled peak RSS during the
edit was 2,190,700 KiB. The harness at
`/tmp/profile-titan-saved-edit.mjs`, SHA-256
`b02183306001f28f2048f56226a6140aee71893fd089c707c9bfde6ff1dea2d9`,
hash-verified all copied sources, correlated watcher/epoch/ready events, joined
its `/proc` sampler, restored the source unchanged, and removed its temporary
tree after a clean server exit.

## Workstream D: exclusive cold-index attribution

The earlier `compiler.module.complete` event is a progress checkpoint: its
clock starts at the root attempt, so a dependency's displayed time includes
everything visited before it. It cannot answer which physical module or header
actually consumed cold-start CPU.

Trace-level profiling now records one inclusive source-module duration around
each ordinary source check. A resolver-local stack subtracts the inclusive
duration of each directly nested source dependency. It also subtracts exactly
the non-overlapping C-header `process_total` and downstream Titan FFI conversion
durations from the source module which requested them. Component header phases
remain detail inside `process_total` and are never subtracted or summed a second
time. The language-server bridge separately times each nonrecursive
`snapshot_module` normalization and joins that cost to the same module in the
benchmark report.

`cdriver.process_file` appends a stable identity to its existing trace callback.
Ordinary imports default to the resolved physical header. Generated source-
foreign `.check.tmp.*` headers never enter `cdriver`, so they produce no header
parse row; their probe identity canonicalizes nested randomized spellings to
stable public paths and transitive generated identities. A header row's
attributed total is `process_total + downstream_ffi_conversion`; its
preprocessing, C PEG, CType, macro, cache-validation, and graph-clone figures
are retained only as a phase breakdown.

All values are explicitly process CPU milliseconds measured with `os.clock`.
They are not wall time and do not include native child-process CPU. Cooperative
I/O can suspend between clock reads, although the compiler scheduler serializes
compiler ownership and the production trace sink is non-reentrant. An invariant
or cancellation which raises rather than returning may omit terminal
best-effort telemetry because that complete analysis is discarded.

Persistent C-probe marker reuse has a separate scalar trace hook. The C-probe
service reports `(stage, hit, key, path)` once per enabled lookup without
enabling verbose evidence or retaining probe sources; the resolver adapts it to
`(module_name, stage, hit, key, path)` using the currently checked source
module. Both sinks are protected and never print to stdout. This distinguishes
compiler-validation cache misses from C-header parsing time in a language-
server profile.

- [x] Add returned-request `process_total` header telemetry and stable physical
  identities without changing existing five-argument trace consumers.
- [x] Attribute source parsing/checking to exclusive module self time and emit
  terminal timing before the cooperative module checkpoint.
- [x] Time bridge snapshot normalization per module and aggregate repeated
  roots by module/physical file with call counts.
- [x] Add focused header miss/hit/failure, sink-isolation, generated-identity,
  nested-module, and checkpoint-order regressions.
- [x] Trace persistent C-probe marker hits and misses with source-module
  attribution, scalar-only payloads, and sink-failure isolation.
- [x] Rebuild the isolated vscode-titan compiler/server and capture the complete
  Titan-repository trace-level cold-index breakdown.
- [x] Record the largest module/header rows, attributed totals, global residual,
  wall/CPU/RSS, and complete verification evidence here before publication.

The fresh clean-toolchain artifact is
`/tmp/vscode-titan-cold-profile-phases.json`, SHA-256
`5ac2b57223cb87483010a3d8156261ff94ff6f991ddcddac64d0dd2879dcae31`.
It captured exactly one generation-89 analysis over 143 saved Titan files:
314.637s wall, 185.590s server-process CPU, and 2,757,148 KiB peak RSS. The
trace attributed 162.984s CPU, leaving 22.606s outside the source/header/
normalization spans. Source modules accounted for 73.293s: 0.960s parsing,
65.897s checking and direct probe work, 2.110s other self work, and 4.326s
bridge normalization. Foreign headers accounted for 89.691s: 31.711s header
processing and 57.980s downstream Titan FFI conversion. Header processing
included 19.755s preprocessing, 2.941s macro conversion, 1.568s graph cloning,
0.698s C-type conversion, 0.448s C PEG parsing, and 0.014s hit validation.

The largest attributed source rows were `titan.uv` at 18.335s over 28 calls
(17.824s first call, 0.511s all 27 reuses), `titan.http` at 11.898s, and
`titan.ssl` at 7.057s. The largest header rows were `titan/ffi.h` at 19.879s,
`openssl/ssl.h` at 15.635s, `openssl/x509v3.h` at 12.827s,
`openssl/pem.h` at 12.057s, and `uv.h` at 8.924s. The freshly rebuilt success-
only persistent probe cache recorded 10 hits and 1,075 misses across 1,085
requests. That result exposed the deterministic negative-result cache work now
tracked separately as Titan issue #108. An unchanged hover/definition batch
after readiness took 14.600ms wall and 10ms server CPU and emitted zero
indexing-status notifications.

## Verification

1. Run focused C parser, ctypes, cdefines, cdriver/cprobe, and resolver specs
   against compiler modules loaded from this worktree rather than a stale
   installed snapshot.
2. Run the affected compiler shards and the complete Titan test gate, including
   the coverage configuration used by CI. Check `git diff --check`.
3. Re-profile `lua.h`, `uv.h`, and `openssl/ssl.h`; report preprocessed sizes,
   per-phase CPU, typed/preprocessing expression counts, recovery counts, and
   repeated identities.
4. Install the candidate compiler into vscode-titan's isolated toolchain,
   rebuild the server, and re-run a clean Titan-repository cold index. Compare
   compiler passes, header parses, CPU/wall time, peak memory, and readiness.
5. Confirm all version constants and installed search paths still resolve as
   `0.6.0` / `0.6` before publication.

Final local verification passed the canonical isolated
`TITAN_JOBS=4 make -j4 test` gate at `/tmp/titan-vscode-pr-test`: the 124-test
root suite, all four isolated compiler shards, and the 197-test native
standard-library suite completed with zero failures. A clean vscode-titan
toolchain rebuilt from this worktree reports semantic version `0.6.0`, library
path version `0.6`, and ABI `2`; its full `xvfb-run -a make -j1 verify`
consumer gate also passed the Titan/unit/protocol/Codex suites, all 12 Extension
Host scenarios, and the package/linkage/plugin/install/VSIX inspections.

The current Titan companion PR delivers the new compiler/project configuration,
source-import identity, and profiling APIs required by vscode-titan issues #29
and #31. Its required ordinary Ubuntu 24.04 evidence is the stdlib/runtime,
compiler/LuaCov, and ASan+UBSan jobs plus both Codecov project and patch gates;
the macOS-only job remains intentionally skipped. The companion vscode-titan PR
for issues #29 through #32 must pin the exact final compiler implementation
commit and run its Ubuntu 24.04 Ubicloud build/test/package gate.

## Delivery

- Keep compiler work on `codex/project-ffi-cppflags` and language-server
  work in its separate vscode-titan PR.
- Review and commit exact paths, push the Titan branch, and open its companion
  PR with the configuration, source-import, and profiling contracts plus their
  measured effects.
- Link the relevant GitHub issues and update the project board when credentials
  permit. Report any items that cannot be added rather than silently dropping
  them.
- Run the ordinary Linux/Codecov CI required by the repository. Do not dispatch
  macOS-only work unless it is explicitly requested for this change.
