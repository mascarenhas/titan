# Native Titan source coverage

Compile native tests with `--coverage`, then run the resulting test executable:

```sh
export CC=gcc-14 GCOV=gcov-14
titanc -o out --test --coverage calc_tests
./out/calc_tests
```

A successful run prints a Titan executable-line summary and writes combined
annotated output to `out/.coverage/report/coverage.gcov`. Basic collection and reporting need
neither Python nor gcovr. Coverage measures executable lines in the original
`.titan` files; generated C branch and function percentages are not Titan
metrics. The compiler's LuaCov report remains separate. Final coverage links require a test
or standalone executable; library-only provider links are unsupported. Use
`--coverage -c` for separate object compilation before an executable link.

## Source selection

By default, `--coverage` instruments every module imported from source in this
build's dependency graph that has no top-level function whose name starts with
`test_`. A module containing such a function is excluded as a whole, including
production functions colocated with tests. A folder module includes all its
contributors. Prebuilt modules and native dependencies are unmeasured.

Selection follows imports; it does not scan the repository or force additional
modules into the build. To include an unused production module in the coverage
denominator, import it from a test root even if no test calls it. Its retained
executable lines then appear with zero hits.

Repeated `--coverage-module` options replace automatic selection with a union
of logical-module globs:

```sh
titanc -o out --test --coverage \
  --coverage-module 'app.*' --coverage-module 'shared.pars?r' app_tests
./out/app_tests
```

A glob matches the complete logical name. `*` matches zero or more characters
and `?` matches exactly one; both can match dots. Other characters are literal
logical-name characters, and bracket classes or escaping are unsupported. Quote
globs so the shell does not expand them. Explicit selection still skips prebuilt
modules and every source module containing `test_` functions. An empty selection
is an error. It never makes an otherwise absent module a source root.

## Artifacts and repeated runs

Coverage-generated C, headers and objects live in `.coverage` subdirectories
within their normal output tree. With `-o out`, `app/calc.titan` uses
`out/app/.coverage/calc.c` and `out/app/.coverage/calc.o`; a folder module uses its normal
owning directory with the same extra `.coverage` component. Coverage incremental
lookup searches those objects. Ordinary builds search their ordinary locations,
so a later optimized build cannot reuse coverage objects and needs no cleaning
or artifact swap. The default report directory is `out/.coverage/report` with
`-o out`; omitting `--output` retains source-adjacent artifacts and the original
`.coverage/report` default. See [Output directories](output-directory.md).

A large selected module may be
[split](build-profiles.md#compilation-jobs-and-split-modules) into several C
translation units in coverage builds too. Each part has its own generated C,
object, and `.gcno`/`.gcda` files beside the primary ones, such as
`out/app/.coverage/calc.part1.c` and `calc.part1.gcda`. Every part belongs to
the module's coverage inventory, so counter resets and reports include all of
them.

`--incremental` works in coverage mode. Each compiled object carries its partial
coverage file list; linking reconstructs the complete executable inventory from
new and reused objects. Selected objects use O0/no LTO and atomic gcov-compatible
instrumentation. Keep source line directives enabled.

At startup, a coverage test executable deletes the `.gcda` counters corresponding
to its embedded inventory, retaining `.gcno` notes. After successful tests and
their normal cleanup, it explicitly dumps counters and runs the reporter. Each
execution therefore reports fresh coverage. Selected but unexecuted code stays
visible as zero coverage. Test failures keep their failure status; automatic
reporting runs after a successful test run.

Join test-owned children before tests finish, as with an ordinary native test
run. Separate executions, binaries or platforms can be combined using external
tools. Builds sharing the same counter paths cannot run independent coverage
sessions concurrently: use separate output directories. Embedded file paths are
absolute, so keep the build artifacts at those paths while running tests.

## Backend tools

The GCC backend requires GCC 14 or newer and the matching gcov version. Set
`CC` and `GCOV`, or pass `--coverage-gcov COMMAND` explicitly. On macOS, a
prepared GCC SDK can use `CC=gcc-14 GCOV=gcov-14`.

Clang uses its gcov-compatible backend with the matching `llvm-cov gcov` reader:

```sh
CC=clang titanc -o out --test --coverage --coverage-backend llvm-gcov \
  --coverage-gcov 'llvm-cov gcov' calc_tests
./out/calc_tests
```

This uses `.gcno`/`.gcda` files and preserves Titan `#line` attribution. It does
not use LLVM source-based coverage. Native Windows CLANG64/UCRT selects the
`llvm-gcov` backend by default; its validated toolchain is Clang/LLVM 22.1.8.
Run the generated `bin/<logical-module>.exe` launcher normally. The provider DLL
dumps its own profile runtime before reporting, so collection does not depend
on assuming the launcher's runtime can dump another DLL.

## Optional HTML, LCOV and Cobertura

Only richer reports require gcovr and its Python dependency. Install gcovr 8.4
in an environment of your choice, then request one or more formats when compiling:

```sh
titanc -o out --test --coverage --coverage-format html --coverage-format lcov \
  --coverage-format cobertura --coverage-gcovr /path/to/gcovr \
  --coverage-output out/.coverage/report calc_tests
./out/calc_tests
```

`--coverage-output` changes the report directory; `--coverage-root` sets the
source root used for report paths, defaulting to the compilation working
directory. Rich reports are `coverage.html`, `coverage.info`, and `coverage.xml`.
The Lua adapter retains only selected Titan sources and executable source lines
before gcovr renders them. Raw backend artifacts remain available for diagnosis.
Local reporting needs no Codecov credentials or network access. CI uploads and
cross-run combination belong to external tools.

## Titan repository coverage

With a prepared SDK, the coverage targets use the ordinary native test aggregate
and select production source imports from its graph with
`--coverage-module 'titan.*'`. Test-containing modules remain excluded:

```sh
make titan-native-coverage PREFIX=/tmp/titan-sdk CC=gcc-14 \
  TITAN_COVERAGE_GCOV=gcov-14
```

Use `titan-native-coverage-build` to compile separately and
`titan-native-coverage-run` to run the built executable and report without
recompiling. `TITAN_FILTER` selects tests as usual. Rich reports are optional:

```sh
make titan-native-coverage PREFIX=/tmp/titan-sdk CC=gcc-14 \
  TITAN_COVERAGE_GCOV=gcov-14 TITAN_COVERAGE_FORMATS='html lcov cobertura' \
  TITAN_COVERAGE_GCOVR=/path/to/gcovr
```

On Windows, use the same targets through `make -f Makefile.win`. The ordinary
native harness copies the prepared SDK to its private local NTFS workspace and
source-links production code into the test provider. Child fixture programs
that consume prebuilt providers remain unmeasured. Their behavior still runs in
the ordinary aggregate; measuring a separate binary requires its own source
coverage build, with combination handled externally.

Run unfiltered for a baseline, then add cases for uncovered behavior in its
native test owner. Keep ordinary optimized and platform validation as separate
gates. [Implementation details](../implementation/native-coverage.md) explain
source attribution, object inventories and reporting ownership.
