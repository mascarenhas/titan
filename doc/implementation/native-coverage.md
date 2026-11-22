# Native source coverage implementation

Coverage is an ordinary source build and native test execution mode. The
compiler selects source modules, stores coverage outputs in `.coverage`
directories, and embeds the file inventory needed by the test executable. Lua
code embedded in that executable resets counters and produces reports, with a
small native counter-dump binding; no separate host command or run manifest is
involved. User-facing commands are in [native
coverage](../language/toolchain.md#native-source-coverage); the test executable itself is
described in [test runner](test-runner.md).

| Code | Owns |
| --- | --- |
| `titan-compiler/coverage.lua` | Backend and tool checks (`coverage.prepare`), selection (`coverage.select`), output paths, compile flags, object inventories. |
| `titan-compiler/coverage_lines.lua` | Marker emission and the final marker-to-`#line` pass (`coverage_lines.convert`). |
| `titan-compiler/coverage_runtime.lua` | Counter reset and reporting inside the executable (`coverage.prepare`, `coverage.finish`). |
| `titan-compiler/coder/generate.lua` | Foreign-body outlining (`coder.prepare_coverage`) and LLVM lambda retention. |

## Source attribution

Coverage code generation emits explicit source-region markers: reserved
standalone `// TITAN_COVERAGE_*` comments that describe nested Titan source,
authored-C and generated regions (`coverage_lines.begin`/`finish`/`region`).
Filenames are hex encoded so quotes, spaces and Windows separators cannot alter
the marker grammar.

Statements, expression lowering that emits statements, authored function
bodies, foreign bodies, closures and user initializers own source regions.
Wrappers, prologues, epilogues, metadata and synthesized constructors use
generated attribution.

`coder.prepare_coverage` outlines every source-defined foreign function in every
coverage-tree module, selected or not, before native-header planning (the driver
calls it first; `coder.generate` repeats it for direct callers). This keeps
reused callers stable when the instrumentation selection changes, and prevents
bodies from executing only in unmeasured importing objects or disappearing from
notes-only coverage. Ordinary generation keeps its usual inline policy.

When `--pretty-print` formats generated C, `driver.format_generated_file` passes
clang-format `CommentPragmas: '^ TITAN_COVERAGE_'` so markers survive
unchanged. Coverage mode also skips the ordinary blank-line normalization after
`#line`, preserving authored-C line progression. Finally
`coverage_lines.convert` turns markers into standard `#line` directives; no
layout pass follows it. Their filenames use the same
[`util.c_line_filename`](codegen-overview.md#mixed-source-line-attribution)
spelling as ordinary generated line controls. Authored line controls are
decoded from octal, simple and universal-character-name escapes, so the
converter reads both authored GCC-style C and its own output; an escape that
names no byte (octal above 255, a surrogate or a code point above U+10FFFF)
leaves the directive without effect on source ownership.

The converter maintains a stack of owners. Lines in a Titan expansion keep one
source anchor, while authored-C regions preserve intentional line progression.
Ending a nested region restores its parent, including its authored-line cursor;
ending the outermost source region restores the generated filename and physical
line. The scanner recognizes comments, strings, characters, escapes, line
splicing and preprocessor logical lines, and never inserts directives inside
those constructs. Malformed or unbalanced markers fail compilation. Saved source
anchors also drive Titan-only executable-line filtering in reports.

Foreign `elseif` conditions and a repeat loop's `until` condition have their own
regions. A synthesized constant C backedge remains generated scaffolding, so a
body `break` does not falsely cover an unevaluated `until`. Statement anchors
provide executable-line coverage, not expression-level proof.

## Selection and object ownership

Resolution redirects coverage-mode generated C, headers and objects into a
`.coverage` subdirectory of their ordinary owning output directory before
incremental lookup (`coverage.output_path`, `coverage.source`). Ordinary object
discovery never searches those directories, and coverage discovery never
accepts ordinary objects. This structural separation protects later release
builds without settings stamps or artifact swapping. Final programs keep their
normal executable locations. Coverage final links require a test or standalone
executable; library-only provider links are rejected. Compile-only coverage
remains available for incremental object DAGs.

After the requested source graph resolves, automatic selection includes
authored source modules with no top-level `test_` functions; modules resolved
from source through the implicit SDK fallback (`<root>/lib/titan/0.6`) and
any module containing a test are excluded (a test-bearing module is excluded as
a whole). Repeated `--coverage-module` globs replace automatic selection over
the resolved source graph instead, opting a matching installed fallback source
into instrumentation; `*` and `?` match logical-name characters including dots.
Neither mode imports additional roots or instruments selected compiled
providers, and `test_`-bearing modules stay excluded in both modes. The
generated test runner is unmeasured. An empty selection is a compiler error.

Each generated object records `coverage_test_functions`
(`coverage.test_functions(ast)`) and its partial coverage inventory
(`coverage.partial`: `enabled`, `backend`, absolute generated C `files`,
`sources`, and `anchors`) in `.titan.source` object metadata, and records
`{ enabled = <boolean>, backend = <string> }` in the certificate's
`codegen.coverage` options. When `incremental.certify_local` checks a coverage
object, it verifies `codegen.coverage` and requires one recorded file per part
plus a regular `.c`, `.o`, and (when `coverage.enabled` is true) `.gcno` notes
file for every part ([split reuse
checks](incremental-compilation.md#split-modules)). At final link time,
`coverage.select` reads `coverage_test_functions` from certified object-backed
entries (`coverage.lua`), `coverage.inventory` combines their saved partials,
and `linkcertificate.prepare` records the complete `coverage_runtime` table in
the final-link recipe while snapshotting the immutable executable and provider
outputs. Runtime `.gcda` counter files and generated report files are mutable
execution outputs, not part of the final-link certificate, so running the
coverage executable does not invalidate a subsequent incremental build.

Coverage converts generated C part by part. `driver.compile` runs
`coverage_lines.convert` independently on each part's C file and always passes
`coverage.partial` the ordered list of `{ filename, anchors }` parts, one entry
for an unsplit module and one per part for a [split
module](codegen-overview.md#translation-unit-parts). `files` therefore holds
every part's absolute C path in part order and `anchors` is keyed by each of
those paths. The `.titan.source` record is appended to part 0 after
conversion. The shared `<stem>.priv.h` is retained for diagnostics but is not
converted and owns no source lines. Because every part is inventoried, the
runtime reset removes each part's `.gcda` and `coverage.finish` reads each
part's notes.

`coverage.compile_flags` gives every source object `-O0 -fno-lto`. Selected
objects add `--coverage -fprofile-update=atomic`. The GCC backend adds
`-fkeep-static-functions` and `-dumpbase`/`-dumpbase-ext` so the compiler's
temporary object name cannot rename the notes; the `-dumpbase` value is the
logical `<leaf>.c` from `source_selection.output_stem`, never a target
variant's name, and for a nonzero part the driver
replaces it with that part's C basename, so its notes are
`<leaf>.part<k>.gcno`. The LLVM backend adds `-dumpdir`
and marks selected source-owned native lambdas `__attribute__((used))`
(`coder._coverage_keep_native_lambdas`) without emitting every unrelated inline
header body. Native dependencies remain unmeasured. Final image links receive
the matching profile runtime.

`coverage.lua` `coverage.prepare` validates the toolchain before any build:

- source `#line` directives must be enabled, and `--print-ast` is rejected;
- the default backend is `gcc-gcov`, or `llvm-gcov` on Windows, where
  `gcc-gcov` is rejected;
- `gcc-gcov` requires GCC 14 or newer whose `--version` banner does not say
  clang (so Apple's `gcc` alias is rejected), plus a gcov reporting the same
  version;
- `llvm-gcov` requires Clang and an `llvm-cov gcov` with the same LLVM version.

Clang's gcov-compatible instrumentation preserves Titan `#line` attribution.
LLVM source-based coverage reports physical generated C and is not used. Windows
CLANG64/UCRT uses the LLVM backend and its normal EXE/DLL loading model. The
default report directory is `<output>/.coverage/report`; `--coverage-output`
and `--coverage-root` override it and the source display root.

## Direct execution and reports

The generated entrypoint embeds `coverage_runtime.lua` and the inventory.
Before tests run, `coverage_runtime.lua` `coverage.prepare` removes only the `.gcda` file paired with
each inventoried `.c`. It keeps `.gcno` notes, so unexecuted objects and bodies
remain visible as zero hits. A successful test run and cleanup is followed by
an explicit counter dump and `coverage.finish`. Failed tests keep their status.
The ordinary test runner continues to own test and child lifetimes.

On POSIX the entrypoint calls `__gcov_dump` directly. On Windows the provider
DLL exports `_titan_coverage_dump`, which calls the profile runtime linked into
that DLL: dumping only the EXE cannot be assumed to reach another DLL's
separately linked runtime. LLVM may dump again during normal exit; positive hit
counts and executable-line coverage are unchanged, and the next run resets
those counters. LLVM counts repeated line mappings separately, so exact raw hit
counts are not a cross-backend contract.

`coverage.finish` runs the selected gcov command with `-t -p` on every
inventoried notes file from the compilation working directory, writes the
combined annotated output to `coverage.gcov`, and prints a Titan
executable-line summary. This needs neither Python nor gcovr, and tool
diagnostics stay visible. Absolute embedded paths require the build artifacts
to remain in place. Only when `--coverage-format` requested formats does
`rich_report` pass the retained Titan executable lines to gcovr, which renders
HTML, LCOV or Cobertura.

The metric is Titan executable lines only. LCOV output carries no function or
branch records and Cobertura no methods; generated-C branches and functions are
never reported as Titan metrics. Nothing is excluded from the denominator:
platform-only, defensive and unreachable lines stay in it, and timing-sensitive
paths (for example TLS shutdown errors) can gain or lose hits between runs.
Local reporting never uploads. Combining runs, binaries or platforms is
external tooling; platform reports stay separate.

Two concurrent runs cannot share counter paths because startup cleanup resets
them. Separate source/build trees provide independent sessions.

## Repository integration and verification

The Unix and Windows `titan-native-coverage-build`/`-run` targets source-link
production imports into the native aggregate with `--incremental`,
`--coverage-module 'titan.*'`, `--test-dir` discovery over `spec/stdlib/titan`,
explicit first root `test.tests`, and the three aggregate C helpers
(`async_foreign_work.c`, `fs_fixture.c`, `uv_stdio_probe.c`) passed via
`--c-source`, reusing the suite's fixtures, filters, timeout harness, and output
validator. On Unix, `titan-native-coverage-build` runs from
`$(TITAN_COVERAGE_BUILD_DIR)` (`out/coverage`) with `--output .`, `--tree
$(abspath spec/stdlib/titan);$(CURDIR)`, `--exe $(TITAN_COVERAGE_EXECUTABLE)`,
and `-X $(STDLIB_EXTRA_OBJECTS)`. On Windows (`scripts/windows_native_coverage.sh`
and `spec/support/windows_stdlib_tests.sh` with `TITAN_TEST_COVERAGE=1`), the
harness refreshes the marked NTFS workspace and invokes `titanc` with `--output
"$work/coverage"` and `--exe "$winprefix/bin/titan-stdlib-tests.exe"`, keeping
coverage objects, `.gcno` notes, `.native` helpers, and `.titan-links`
certificates in `work/coverage` while the launcher in `work/sdk/bin` embeds the
relative path to `work/coverage/lib/titan/0.6/test/tests.dll`. The harness
records `TITAN_TEST_COVERAGE` in `work/compiler.env` and rejects a run requested
with a different coverage mode. A successful aggregate execution writes its
report. Children that import the prebuilt SDK stay unmeasured.

Coverage runs stay serial on both platforms. Unix `titan-native-coverage-run`
delegates to the focused `titan-stdlib-test-run` leaf, never to
`titan-stdlib-test-run-parallel`: the executable resets the counters of its
whole embedded inventory at startup and dumps them after its own run, so
concurrent owner groups of one coverage executable would erase and race on the
same `.gcda` files. The coverage build compiles with up to `TITAN_JOBS`
concurrent frontend workers and native compiler jobs and, as a `+` recipe
guarded by `RECURSIVE_WRAPPER_GUARD`, shares a supported parent Make's job pool
([Make job pool and titanc
recipes](build-script-audit.md#make-job-pool-and-titanc-recipes)).

| Variable | Unix `Makefile` default | Windows `Makefile.win` default |
| --- | --- | --- |
| `TITAN_COVERAGE_BUILD_DIR` | `out/coverage` | `$(WINDOWS_BUILD_ROOT)/native-coverage`, a private local NTFS workspace (`scripts/windows_native_coverage.sh`; compiler outputs under `coverage/`) |
| `TITAN_COVERAGE_REPORT_DIR` | `$(TITAN_COVERAGE_BUILD_DIR)/report` | `$(TITAN_COVERAGE_BUILD_DIR)/report` |
| `TITAN_COVERAGE_GCOV` | `gcov` | `llvm-cov.exe gcov` |
| `TITAN_COVERAGE_GCOVR` / `TITAN_COVERAGE_FORMATS` | `gcovr` / empty | `gcovr` / empty |
| `TITAN_TEST_TIMEOUT` | 600 s | 600 s for coverage goals, otherwise 1800 s |

On Linux the coverage link adds `-rdynamic`. The source-linked aggregate
contains the whole standard library, and the stock Lua C helper modules that
the suite loads resolve the host Lua API from the executable. In CI, the
coverage lane also verifies that an identical `luarocks make --force` reinstall
followed by `make titan-native-coverage-build TITAN_VERBOSE=1` hits all object,
native, and final-link certificates without recompiling or relinking.

`spec/coverage_lines_spec.lua` owns the lexical converter; coder attribution
specs own real Titan source anchors, nested lowering, foreign outlining,
contributors and zero-hit bodies. Compiler coverage regressions
(`spec/coder/native_coverage_spec.lua` and the coverage runtime/backend specs)
own automatic and glob selection, coverage/ordinary object separation,
incremental partial inventories, repeated direct execution and backend
reporting. Focused native Windows coverage checks prove provider-local dumping
through a real EXE/DLL pair. CI requirements for this lane are in [continuous
integration](continuous-integration.md#standard-library-packaging-and-coverage).
