# C99 and FFI indexing performance

Status: both implementation workstreams, focused verification, full local
gates, and final cold-index profiling are complete; delivery and CI are pending.

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
strategy shared by a long-lived language-server compiler instance and bounded
by both a 16-entry LRU and a 64 MiB approximate retained-graph budget. A replay
of the exact 342-request trace projected 201, 232, and 270 hits at entry bounds
8, 12, and 16 respectively (versus 302 when all 26 successful headers remain),
so 16 preserves most reuse while limiting unrelated SDK growth. The byte bound
charges table/slot storage, every string occurrence, and the preprocessor's
weak-side-table token spelling/spacing metadata. It evicts before cloning a
miss, which also prevents a second large graph from being allocated beside
entries which cannot remain resident. `c-parser/cpp.lua` publishes its existing
exact ordered compiler-argv/forced-header configuration key, extended with the
explicit language mode and a deterministic digest of the authoritative include
roots and predefined macro world reported by that compiler. `cdriver` combines
that context with the provider's current working directory, requested spelling,
and selected absolute header, reduces the complete tuple to a fixed-size
SHA-256 cache key, and charges that key, the actual entry table, and its cache
hash slot to the same byte budget. It deliberately does not key on `source_dir`:
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
  isolation, hit-refreshed LRU, weight eviction, oversized rejection, and
  failure-exclusion tests.
- [x] Re-run the cold-index trace after both workstreams land and record cache
  hits, residual parses, CPU/wall time, and peak memory.
- [x] Refresh the cache trace's exact weight/counter measurements after the
  final fixed-key and entry-overhead accounting refinement.

The final fixed-key, entry-overhead, sidecar/string-aware controlled trace
retained at `/tmp/titan-cache-final-accounting.nKT56k.tsv` made the same 342
requests and produced the same 3,783 diagnostics and 89 snapshots in each of
two deliberately preserved fixed-point passes. Its SHA-256 is
`af613e884f3e6a6002c71d114df06fd783a2790c3a844918af1c50e447cb1a0e`.
The bounded cache recorded 260 hits, 82 misses (68 successful real parses and
14 expected failures), 64 stores, and 51 evictions. `openssl/x509v3.h` and
`openssl/ssl.h` each exceeded 64 MiB in both passes and accounted for the four
successful but deliberately unstored parses. Header processing consumed
71.970s CPU (25.556s validating/cloning hits, 46.359s successful misses, and
0.055s failed misses), down from the uncached 169.150s. The maximum retained
graph weight was 67,042,715 bytes (63.94 MiB) across at most 16 entries; every
sample remained within both configured bounds. End-to-end controlled indexing
took 203.341s wall and 172.985s compiler-attempt CPU, improving on the 328.526s
/ 274.873s baseline by 38.10% / 37.06%. Peak server RSS was 1,226,104 KiB
(1.169 GiB), and the sampled process-tree peak was 2,297,464 KiB (2.191 GiB).
The controlled process-tree peak includes transient compiler children and is
not a retained-cache bound.

With the language server's redundant cold fixed-point analysis removed, the
final integrated actual-usage run indexed the Titan checkout in one compiler
analysis: 130.209s wall, 92.242s compiler-attempt CPU, 69 root attempts, 89
project snapshots, and the same 3,783 diagnostics. Peak server RSS was
1,241,444 KiB and the sampled process-tree peak was 1,295,312 KiB. Relative to
the original uncached/two-pass 328.526s wall and 274.873s attempt-CPU baseline,
the combined parser, cache, and language-server work reduced wall time by
60.37% and compiler-attempt CPU by 66.44%. The controlled 342-request trace
above remains the cache-specific comparison because it intentionally preserves
both identical passes; the integrated run verifies the shipped one-pass path.

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

Final local verification passed `make test PREFIX=/tmp/titan-c99-final
CCACHE_DISABLE=1`: the 124-test root suite, all four isolated compiler shards,
and the 197-test native standard-library suite completed with zero failures.
The completed-header cache's focused suite passed all 14 cases, including the
yielded replacement race. A clean vscode-titan toolchain rebuilt from this
worktree reports semantic version `0.6.0`, library path version `0.6`, and ABI
`2`; its full `xvfb-run -a make -j1 verify` consumer gate also passed.

## Delivery

- Keep compiler work on `codex/c99-ffi-index-performance` and language-server
  work in its separate vscode-titan PR.
- Review and commit exact paths, push the Titan branch, and open one Titan PR
  describing both complementary workstreams and their measured effects.
- Link the relevant GitHub issues and update the project board when credentials
  permit. Report any items that cannot be added rather than silently dropping
  them.
- Run the ordinary Linux/Codecov CI required by the repository. Do not dispatch
  macOS-only work unless it is explicitly requested for this change.
