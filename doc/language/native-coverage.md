# Native Titan source coverage

`titanc --coverage DIRECTORY` builds an isolated **executable-line coverage**
image for an explicit inventory of production Titan modules. It uses GCC's
gcov instrumentation and maps the results to the original `.titan` files.
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
Flag acceptance alone is insufficient. Clang coverage is not supported by
this backend. The experimental Windows CLANG64 SDK rejects `--coverage`
before creating coverage artifacts; normal Windows testing remains available.

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
`python3 titan-coverage`. Compilation needs Python for its capability probe,
but gcovr is required only for rendering. `seal` validates the compiler's
source/object/notes/image hashes and records exact compiler, profiler, target,
and runtime identities. It rejects changes between compilation and sealing.
When a test consumer is built separately from a measured provider, repeat
`seal --unmeasured-input PATH` for its executable and source/fixture inputs.
Their hashes bind the run to that consumer without adding its code to the
coverage denominator; edits make subsequent runs and reports fail validation.

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
`GCOV_PREFIX_STRIP=0` only for that process tree, after build/provider probes
finish. Repository builds relocate any counters from compiler metadata probes
into a separate `preparation-counters` directory. Reports never consume those
preparation counters. Old build-time counters cannot become test hits. Joined children inherit
that run's prefix; the parent must wait for them to finish. Different concurrent
shards require different run directories. Retain all run receipts and raw
counters until reporting finishes.

Collection happens after process exit. The host preserves the test's exit
status even if a valid partial report can be generated. Crashes, timeouts,
missing expected object counters, or counters changed after the receipt mark
collection incomplete or fail validation. `--allow-incomplete` explicitly allows
an incomplete diagnostic report, but does not convert a failing test into
success. A process that deliberately loads only some declared providers can
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
and provenance, and raw gcov JSON for diagnosis. A source contributor containing
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

See [implementation](../implementation/native-coverage.md) for region ownership,
lexical conversion, inventory receipts, and regression layers.
