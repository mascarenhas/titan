# Native source coverage implementation

Coverage is an ordinary source build and native test execution mode. The
compiler selects source modules, stores coverage outputs in `.coverage`
directories, and embeds the file inventory needed by the test executable. Lua
owns counter cleanup and reporting, with a small native counter-dump binding.
No separate host command, sealing protocol or run manifest is involved.

## Source attribution

Coverage code generation retains the explicit source-region markers introduced
for issue #210. Reserved standalone `// TITAN_COVERAGE_*` comments describe
nested Titan source, authored-C and generated regions. Filenames are hex encoded
so quotes, spaces and Windows separators cannot alter their grammar.

Statements, expression lowering that emits statements, authored function bodies,
foreign bodies, closures and user initializers own source regions. Wrappers,
prologues, epilogues, metadata and synthesized constructors use generated
attribution. Source-defined foreign functions in every coverage-tree module are
outlined before header planning. This keeps reused callers stable when the
instrumentation selection changes, and prevents bodies from executing only in
unmeasured importing objects or disappearing from notes-only coverage. Ordinary
generation restores its usual inline policy.

`driver.format_generated_file` reserves marker comments when formatting.
Coverage preserves authored-C line progression instead of applying the ordinary
blank-line normalization after `#line`. Finally `coverage_lines.convert` turns
markers into standard `#line` directives; no layout pass follows it.

The converter maintains a stack of owners. Safe lines in a Titan expansion keep
one source anchor, while authored-C regions preserve intentional line
progression. Ending a nested region restores its parent; ending the outermost
source region restores the generated filename and physical line. The scanner
recognizes comments, strings, characters, escapes, line splicing and
preprocessor logical lines. It never inserts directives inside those constructs.
Malformed or unbalanced markers fail compilation. Saved source anchors support
Titan-only executable-line filtering during optional rich reporting.

Foreign `elseif` conditions and a repeat loop's `until` condition have their own
regions. A synthesized constant C backedge remains generated scaffolding, so a
body `break` does not falsely cover an unevaluated `until`. Statement anchors
provide executable-line coverage, not expression-level proof.

## Selection and object ownership

`coverage.lua` owns backend configuration, source selection and output paths.
Resolution redirects coverage-mode generated C, headers and objects into a
`.coverage` subdirectory of their ordinary owning output directory before
incremental lookup. Ordinary object discovery never searches those directories;
coverage discovery never accepts ordinary objects. This structural separation
protects subsequent release builds without settings stamps or artifact swapping.
Final programs retain their normal executable locations. Coverage final links
require a test or standalone executable; library-only provider links are
rejected. Compile-only coverage remains available for incremental object DAGs.

After resolving the requested source graph, automatic selection includes source
modules with no top-level `test_` functions. An entire module containing tests
is excluded. Explicit repeated `--coverage-module` globs restrict the same graph;
`*` and `?` match logical-name characters including dots. Neither mode imports
additional roots or instruments prebuilt providers. The generated test runner is
unmeasured. No matches produce a useful compiler error.

Each generated object records its partial coverage inventory in the existing
object metadata: absolute generated C paths and the source attribution needed
for reporting. Incremental reuse reads that metadata. Final linking combines
partials and serializes the complete Lua table into the test executable. This
uses compiler-known outputs and does not hash or attest the build.

Selected objects receive O0/no-LTO, `--coverage`, atomic profile updates and
retention of uncalled Titan bodies. GCC uses `-fkeep-static-functions` and stable
notes naming despite sibling temporary object publication. LLVM retains selected
source-owned native lambdas without emitting every unrelated inline header
body. Unselected source objects use O0/no-LTO without instrumentation. Native
dependencies remain unmeasured. Final image links receive the matching profile
runtime. Ordinary failed-object publication behavior is unchanged.

The GCC backend requires GCC 14 or newer with matching gcov. Clang uses its
existing gcov-compatible instrumentation and matching `llvm-cov gcov`, preserving
Titan `#line` attribution. LLVM source-based coverage reports physical generated
C and is not used here. Windows CLANG64/UCRT uses the LLVM backend and its normal
EXE/DLL loading model.

## Direct execution and reports

The generated test executable loads the Lua coverage adapter with its embedded
inventory. Before tests run, the adapter removes only the corresponding `.gcda`
files. It keeps `.gcno` notes, allowing unexecuted objects and bodies to remain
visible as zero hits. A successful normal test run and cleanup is followed by
an explicit runtime dump and report generation. Failed tests preserve their
status. The ordinary test runner continues to own test and child lifetimes.

The native binding calls `__gcov_dump` for the profile runtime linked into the
owning image. On Windows that binding lives in the provider DLL: dumping only
an EXE cannot be assumed to reach another DLL's separately linked runtime.
LLVM may dump again during normal exit; positive hit counts and executable-line
coverage are unchanged, and the next run resets those counters. Exact raw hit
counts are not a cross-backend contract.

The basic adapter invokes matching gcov or `llvm-cov gcov` against the known
notes and generated C with the compilation working directory. The adapter prints a Titan executable-line summary
and saves combined annotated output as `coverage.gcov`, needing neither Python
nor gcovr. Tool diagnostics remain
visible. Absolute embedded paths require the corresponding build artifacts to
remain available.

When rich formats are requested, the Lua adapter reads the common annotated
`gcov -t -p` output from either backend, retains selected Titan executable lines,
and supplies gcovr's report data. gcovr renders HTML, LCOV or Cobertura only then. Generated-C
branches and functions are not advertised as Titan metrics. Local reporting
never uploads. Combining runs, binaries or platforms remains external tooling.

Two independent runs cannot share counter paths because startup cleanup resets
them. Separate source/build trees provide independent sessions; no coverage
coordinator or relocatable-bundle protocol is needed.

## Repository integration and verification

Unix and Windows coverage targets source-link production imports into the
ordinary native aggregate. They reuse its fixtures, filters, timeout harness and
output validator. Windows retains the normal private local NTFS SDK copy.
Children that import the prebuilt SDK stay unmeasured. The targets no longer
build and seal a separate measured standard provider, or depend on a Python
host program. A successful aggregate execution also generates its report.

`spec/coverage_lines_spec.lua` owns the lexical converter; coder attribution
specs own real Titan source anchors, nested lowering, foreign outlining,
contributors and zero-hit bodies. Compiler coverage regressions own automatic
and glob selection, coverage/ordinary object separation, incremental partial
inventories, repeated direct execution and backend reporting. Focused native
Windows coverage checks prove provider-local dumping through a real EXE/DLL
pair. Shipping behavior is also checked through ordinary Linux, macOS and
Windows gates.

The [initial validation record](native-coverage-validation.md) preserves the
historical issue #210/PR #214 implementation experiments. Its old seal/run
commands describe that superseded workflow, not the current user interface.
