# Native Titan source coverage

`titanc --coverage DIRECTORY` builds an isolated **executable-line coverage**
image for an explicit inventory of production Titan modules. GCC/gcov is the
default backend; native Windows CLANG64 has an explicit experimental LLVM/gcov
backend. Both map the results to the original `.titan` files.
Ordinary compilation and the native test runner keep their existing behavior.
The Lua-written compiler's LuaCov report remains a separate component.

## Toolchain and scope

The initial backend requires GCC 14 or newer, the matching `gcov`, Python 3,
and `gcovr==8.4` for rendering reports. Install the report dependency in a
private environment:

```sh
python3 -m venv /tmp/titan-coverage-tools
/tmp/titan-coverage-tools/bin/pip install -r scripts/titan-coverage-requirements.txt
export CC=gcc-14 GCOV=gcov-14
export GCOVR=/tmp/titan-coverage-tools/bin/gcovr
```

On macOS, Homebrew `gcc@14` supplies `gcc-14` and `gcov-14`. The compiler
performs a real backend probe before emitting coverage objects: multi-file
Titan attribution, an untaken line, an uncalled function, notes without
counters, fresh counter directories, and shared-provider/threaded collection.
Flag acceptance alone is insufficient. Clang requires the separate
`--coverage-backend llvm-gcov` option on native Windows; it is not substituted
automatically for GCC. Windows rejects the default GCC backend before creating
coverage artifacts. See [Windows coverage](#experimental-windows-coverage) for
its tools and commands.

Repeat `--coverage-module NAME` for **every production module in the desired
denominator**, including modules the current tests never import. These names
are logical module names, not filenames or patterns. Each selected module must
be available from source. The compiler includes the complete folder module,
including all contributors, and builds its notes even when no test calls it.
Other prebuilt dependencies are listed as **unmeasured** in the build manifest.
Their code does not contribute to this report.

Test owners, helper modules, `titan.test`, the synthetic runner, Lua, and native
dependencies stay outside the production inventory. Discovery rejects selected
modules that contain native `test_*` functions. Split mixed production/test
modules before measuring; the compiler does not silently discard their
production functions. Helper modules cannot be classified from function names,
so the explicit inventory must omit them.

## Build, run, and report

For a project containing production modules `app.calc` and `app.unused` and
test root `app.calc_tests`:

```sh
titanc --test --coverage /tmp/app-coverage/build \
  --coverage-module app.calc --coverage-module app.unused \
  app.calc_tests

titan-coverage seal --manifest /tmp/app-coverage/build/build.json \
  --cc "$CC" --gcov "$GCOV"
titan-coverage run --manifest /tmp/app-coverage/build/build.json \
  --run /tmp/app-coverage/run-1 --timeout 120 -- \
  /tmp/app-coverage/build/bin/app/calc_tests
titan-coverage report --manifest /tmp/app-coverage/build/build.json \
  --run /tmp/app-coverage/run-1 --output /tmp/app-coverage/report-1 \
  --gcovr "$GCOVR"
```

`titan-coverage` is installed alongside `titanc`. From a checkout, invoke it as
`python3 titan-coverage`. `--coverage-python COMMAND` selects the native Python
command used by compilation, defaulting to `python3`.
Compilation needs Python for its capability probe,
but gcovr is required only for rendering. `seal` validates the compiler's
source/object/notes/image hashes and records exact compiler, profiler, target,
and runtime identities. It rejects changes between compilation and sealing.
When a test consumer is built separately from a measured provider, repeat
`seal --unmeasured-input PATH` for its executable and source/fixture inputs.
Their hashes bind the run to that consumer without adding its code to the
coverage denominator; edits make subsequent runs and reports fail validation.
For a large consumer inventory, `--unmeasured-input-file FILE` accepts a UTF-8
JSON array of explicit file paths. The list and every listed file are hashed;
duplicate physical paths within the list, missing files and malformed input
fail. This avoids command-line length limits without discovering inputs
implicitly.

Selected objects use `-O0 -fno-lto --coverage -fprofile-update=atomic`.
Nonselected Titan objects use O0/no LTO without instrumentation. Coverage
objects, headers, executables, providers, notes, and configuration receipts live
under the coverage directory. A changed compiler, toolchain, scope, formatter,
flags, source mapping, or replaced SDK requires a fresh directory. Reinstalling
an SDK can replace native header identities even when their bytes are unchanged.
`--incremental` reuses
only coverage-owned objects with matching source/object/notes/attribution receipts;
callers must also invalidate every dependent when imported source or inline
helpers change. These receipts do not replace a complete dependency build graph.
The repository coverage Make target rebuilds its objects rather than opting
into incremental compilation without such a graph.
`-c --test` supports separate object generation, followed by the ordinary
`--test --incremental` final link with the same coverage settings. An ordinary
application `main` can be measured using the same options without `--test`.
Shared library builds emit an instrumented provider and shims inside the build
directory; consumers must load that provider explicitly.

`--no-line-directives` and `TITAN_NO_LINE_DIRECTIVES=1` conflict with Titan
source coverage. Ambient coverage compiler flags are also rejected: the mode
owns their object scope. Coverage outlining keeps selected source-defined foreign
function bodies in their production object, so calls from uninstrumented tests
still measure the body. Normal builds retain their usual inlining policy.

## Counters and process ownership

Each `run` directory must be new. The host command sets `GCOV_PREFIX` and
`GCOV_PREFIX_STRIP=0` for GCC, or `1` for Windows LLVM, only for that process tree, after build/provider probes
finish. Repository builds relocate any counters from compiler metadata probes
into a separate `preparation-counters` directory. Reports never consume those
preparation counters. Old build-time counters cannot become test hits. Joined children inherit
that run's prefix; the parent must wait for them to finish. Different concurrent
shards require different run directories. Retain all run receipts and raw
counters until reporting finishes.

On POSIX, the command runs in a private process group. Collection requires
both leader exit and confirmed group emptiness. After a natural leader exit,
an unjoined process remaining in that group makes the run incomplete: the host
retires the group, returns 125, and records the leader's original status
separately. Timeout and interrupt cleanup also retire that group and retain
statuses 124 and 130 respectively. A descendant that deliberately creates a new
session or process group is outside this ownership boundary; measured programs
must join their children and keep counter writers within the owned group.

For normally joined runs, the host preserves the test's exit status even if a
valid partial report can be generated. Crashes, timeouts,
missing expected object counters, or counters changed after the receipt mark
collection incomplete or fail validation. `--allow-incomplete` explicitly allows
an incomplete diagnostic report, but does not convert a failing test into
success. If group emptiness cannot be confirmed, counters are not collected
and reporting is refused even with this option. Run receipts use version 2;
older receipts require a fresh capture, while sealed build manifests remain
version 1. A process that deliberately loads only some declared providers can
select expected objects with repeated `run --expect-object /absolute/module.o`;
other objects retain their notes-only zero denominator.

Report matching shards by repeating `--run`. Reports retain exact build/run
provenance and refuse duplicate runs, stale counters, changed source/notes or
images, and incompatible toolchains. Different test/server images must retain
their own build manifests and run receipts; see the report command's help for
explicit compatible multi-manifest merging.

## Paths and outputs

`--coverage-root ROOT` defaults to the working directory and defines the report
repository. For copied build sources, repeat
`--coverage-source-map STAGED_DIRECTORY=TRACKED_DIRECTORY`. The longest matching
directory mapping wins. Sealing verifies that each compiled source has exactly
the same bytes as its tracked original. Folder contributors retain separate
filenames. Sources outside the report root fail instead of being silently
excluded.

Selected sources must use LF or CRLF line endings. A literal bare carriage
return, including one inside a long string, is rejected when sealing: Titan's
source locations count LF bytes, while the HTML renderer would treat that CR
as an extra line and show incorrect source rows. Escaped `\r` strings work
normally.

Reports include `coverage.info` (LCOV, root-relative Titan paths),
`coverage.xml` (Cobertura), `coverage.html`, normalized `lines.json`, summary
and provenance, and raw reader evidence for diagnosis. A source contributor containing
only declarations can have no executable lines; explicit compiler attribution
records distinguish that from a missing source inventory. Notes-only executable
modules and functions appear at zero. Never treat every physical Titan line as
executable.

Line coverage says whether generated code associated with that source line ran.
It does not establish expression, behavior, branch, or function coverage. C
control-flow arcs and generated wrappers are retained only in raw evidence;
public reports do not advertise them as Titan branch/function percentages.
HTML source highlighting uses the tracked source bytes.

## Titan repository baseline

With a prepared validation SDK and GCC/matching gcov, the repository targets
build an isolated standard provider containing all 23 stdlib roots, with the
22 production roots measured and test support uninstrumented. An ordinary
28-root native test consumer uses that provider. Runtime/native dependencies
remain uninstrumented:

```sh
make titan-native-coverage-build PREFIX=/tmp/titan-sdk CC=gcc-14 \
  TITAN_COVERAGE_GCOV=gcov-14
make titan-native-coverage-run PREFIX=/tmp/titan-sdk \
  TITAN_COVERAGE_RUN_DIR=/tmp/stdlib-coverage-run-1
make titan-native-coverage-report PREFIX=/tmp/titan-sdk \
  TITAN_COVERAGE_RUN_DIR=/tmp/stdlib-coverage-run-1 \
  TITAN_COVERAGE_GCOVR=/tmp/titan-coverage-tools/bin/gcovr
```

The build/run/report split supports focused runtime filters without rebuilding.
Coverage owns the provider, staged consumer sources/outputs, and native test
fixtures. The run selects that provider through `TITAN_PATH_0_6` and provider-first
Lua paths, so joined child programs contribute their existing stdlib tests to
the same fresh counters. The repository's `lua -E` test helper explicitly selects
the covered provider when this workflow requests it. Static child consumers
receive the coverage runtime as a final-link input; their source stays unmeasured.
The sealed inventory also hashes the consumer and its original/staged test inputs.
Use an unfiltered run to establish the complete baseline; a focused run has a
different purpose. Keep ordinary optimized and platform validation as separate
gates. Upload `coverage.info` to Codecov in a separate CI action with a native
stdlib flag; local coverage does not require Codecov, credentials, or network
access. Initial baselines describe useful gaps rather than imposing an
arbitrary percentage threshold.

For reporter-only changes, invoke `report` with a separately retained updated
`titan-coverage` script, the existing sealed manifest and run, and a fresh report
output directory. Keep the sealed SDK and input files unchanged, and use the
same Python and coverage tools. This needs no compilation, resealing or test
rerun; the updated script must still accept the sealed schema and Windows runner
identity. When bypassing the repository report wrapper, retain `native-audit.exit`
with the report and propagate any nonzero audit status as well as report failures.

## Experimental Windows coverage

Windows coverage requires the native x64 CLANG64/UCRT toolchain with matching
Clang and LLVM **22.1.8**, a native Windows x64 Python, and gcovr **8.4** in that
Python environment. MSYS Python and source-based LLVM coverage are separate
formats and are not supported here. Configure absolute tool paths when several
Python or LLVM installations are available. Install the report requirements
with the normal package installer for the chosen Python; the workflow does not
install packages into the SDK or upload reports.

Use a direct Python installation or the embeddable distribution, with its
implementation DLLs beside `python.exe`. Windows virtual-environment redirectors
are not supported: the identity check must bind the running interpreter and
its implementation, rather than a launcher that locates another installation.

For an application, add these options to the build example above:

```sh
--coverage-backend llvm-gcov \
--coverage-python 'C:/coverage-tools/python.exe -I -B' \
--coverage-gcov 'C:/msys64/clang64/bin/llvm-cov.exe gcov'
```

Invoke the installed `titan-coverage` script with the same Python command for
`seal`, `run`, and `report`. A Windows program's build manifest records its
actual DLL and EXE launcher. The measured DLL, generated shims, and unmeasured
consumer must select the same provider; an EXE launcher alone contains no
production Titan coverage.

With a prepared Windows SDK, run the repository leaf targets from CLANG64:

```sh
make -f Makefile.win titan-native-coverage-build PREFIX=C:/titan-sdk \
  TITAN_COVERAGE_PYTHON='C:/coverage-tools/python.exe -I -B' \
  TITAN_COVERAGE_GCOV='C:/msys64/clang64/bin/llvm-cov.exe gcov' \
  TITAN_COVERAGE_GCOVR='C:/coverage-tools/python.exe -I -B -m gcovr'
make -f Makefile.win titan-native-coverage-run PREFIX=C:/titan-sdk \
  TITAN_COVERAGE_PYTHON='C:/coverage-tools/python.exe -I -B'
make -f Makefile.win titan-native-coverage-report PREFIX=C:/titan-sdk \
  TITAN_COVERAGE_PYTHON='C:/coverage-tools/python.exe -I -B' \
  TITAN_COVERAGE_GCOVR='C:/coverage-tools/python.exe -I -B -m gcovr'
```

The defaults place build, run and report directories under
`WINDOWS_BUILD_ROOT/native-coverage`. Override `TITAN_COVERAGE_BUILD_DIR`,
`TITAN_COVERAGE_RUN_DIR`, and `TITAN_COVERAGE_REPORT_DIR` to use private locations.
The build directory must be new, on local NTFS, disjoint from the input SDK,
and free of directory links or mount points. The workflow copies the SDK,
measures all 22 production roots, builds the ordinary 28-root test consumer,
and seals their explicit inputs. It leaves the prepared input SDK unchanged.
Use a fresh run directory for each invocation. `TITAN_FILTER` supports focused
diagnostics; an unfiltered run establishes the baseline. Relative build, run and
report directories are resolved from the invoking directory. A failed test or
native output audit can still produce a diagnostic report; the command remains
nonzero and copies `native-audit.exit` into that report. A complete baseline
requires a successful native output audit as well as successful collection.

The capability probe builds a private process supervisor inside the coverage
build directory. Runs validate and reuse that exact image; they never compile
or repair it. A failed LLVM probe prints the retained diagnostic directory under
the build's `tools` directory. It contains the failed stage, probe sources and
available expected/observed counts, counters and native status receipts. Compiler
and native output is retained up to 64 KiB per stream, with observed sizes and
hashes. Successful probes remove their temporary fixture.
The supervisor atomically assigns the process tree to a Windows
Job Object and requires confirmed emptiness before collection. An unjoined
child makes a naturally exiting run incomplete with status 125; timeout and
Python interruption retain statuses 124 and 130. The native leader's full
Windows exit status is recorded separately. Cancellation uses a private control
pipe. The supervisor verifies that it owns a private headless console, then
lets the measured leader and its children inherit that console. The calling
Python host retains its console and standard input. Missing cleanup confirmation or a
forced supervisor backstop prevents counter collection and reporting.

LLVM's gcov-compatible notes/data use a pinned binary format. The host validates
their headers, checksums and complete metadata inventory before asking the
matching LLVM tool for line counts. Reader diagnostics fail even when the tool
returns zero. Notes without counters still contribute zero-count lines. GCC
and LLVM receipts remain separate and cannot be merged into one baseline.

See [implementation](../implementation/native-coverage.md) for region ownership,
lexical conversion, inventory receipts, and regression layers.
