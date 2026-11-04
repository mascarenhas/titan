# Testing Titan code

Titan ships a small native test library, `titan.test`, and a compiler mode that
turns ordinary Titan modules into a standalone test executable. Test files are
not a distinct source kind: a test is a public top-level function discovered in
an ordinary flat or [folder module](folder-modules.md).

For opt-in coverage against original Titan production sources, see
[native source coverage](native-coverage.md). It uses the same runner with
isolated GCC/gcov objects and host-side collection after process exit.

```titan
-- calc_test.titan
local test = import "test"       -- shorthand for titan.test
local calc = import "app.calc"

function test_twice(context: test.Context)
    test.assert(calc.twice(21) == 42, "twice returned the wrong value")

    context:run("zero", function(child: test.Context)
        test.assert(child:name() == "calc_test.test_twice.zero")
        test.assert(calc.twice(0) == 0)
    end)
end
```

Build and run it with:

```sh
titanc --test --tree . calc_test
./calc_test
```

Test filename suffixes and locations are conventions only. Projects may use
`*_test.titan`, `*_spec.titan`, neighboring test files, or a separate source
tree, provided `--tree` makes the logical modules visible. Logical module names
still obey Titan's ordinary import and standalone-symbol rules. In particular,
a bare name reserved by standard-library import shorthand (such as `url`,
`timer`, `string`, or `test`) cannot own a discovered test: there is no Titan
import spelling by which the generated runner could name that exact owner.
Other bare Lua-library names can collide at the native boundary; for example,
`math` would export `luaopen_math` and collide with Lua's own standard-library
opener in a standalone. Use names such as `url_test`, `math_spec`, or
`tests.math` to avoid both ordinary constraints.

## Discovery and compilation

`titanc --test` typechecks each selected source root and its source-backed
import closure. With `--incremental`, certified source objects supply their saved
discovered declarations without reparsing or rechecking unchanged modules. A
test case is every declaration in the source-backed closure that is all of the
following:

* a public, non-`local` top-level function whose name starts with `test_`;
* not an ignored duplicate declaration;
* has exactly one fixed parameter, no variadic parameter; and
* that parameter normalizes to exactly `titan.test.Context` (a transparent
  alias is allowed).

The result type is unrestricted and any returned values are discarded. Local
functions and lookalike parameter types are not tests. Cases are ordered by
their complete bytewise name, `<logical-module>.<function-name>`, independent
of import traversal order. Folder contributors participate through their one
combined logical module.

### Automatic test-root discovery

Instead of listing every test root on the command line, pass repeatable
`--test-dir DIR` (and optional repeatable `--test-exclude MODULE`) with
`--test`:

```sh
titanc --test --incremental -o out --exe out/suite \
  --tree . --test-dir tests --test-exclude tests.windows_only_test
./out/suite
```

* **Directory scope and namespace.** Each `DIR` must be an existing directory
  inside a configured `--tree` source root (resolved relative to the current
  working directory when not absolute). `titanc` derives logical module prefixes
  from the **first** configured `--tree` root that contains `DIR`; it does not
  strip the directory's own name or add an implicit `--tree` entry. For example,
  `--tree . --test-dir tests` discovers modules under `tests.*`, whereas
  `--tree tests --test-dir tests` discovers top-level names inside `tests/`.
* **Naming convention for automatic roots.** `titanc` enumerates `DIR`
  recursively on every invocation without reading or parsing unselected files. A
  source module (a flat `.titan` file or a folder module's canonical main) is
  selected as an automatic root when its **final logical name component** is
  `test`, `tests`, `spec`, `specs`, or ends with `_test`, `_tests`, `_spec`, or
  `_specs`. Immediate `.titan` contributors of a folder module belong to that
  folder owner and are never separate roots. Hidden descendant directories (names
  starting with `.`) are skipped, and directory symlinks are not descended
  implicitly, although a symlinked directory passed explicitly to `--test-dir`
  is traversed and a matching linked folder owner is resolved normally.
* **Target variants.** A [target variant](target-source-selection.md#test-roots)
  `foo_test.<label>.titan` names the root `foo_test` when its label applies to
  the compilation target, and ordinary selection decides which member of the
  family runs, so several variants of one root are one root. A variant for
  another target is skipped without an error: a platform-only test written as
  `foo_test.windows.titan` needs no `--test-exclude` on other hosts. A folder
  root with no main for the target is skipped like a plain directory. Other
  dotted names, such as `foo_test.extra.titan`, are not roots, and a stacked
  or mis-cased label (`foo_test.linux.native.titan`, `foo_test.Linux.titan`)
  fails discovery with the file's path.
* **Resolver consistency.** Each candidate is resolved through the ordinary
  tagged source resolver. If an earlier `--tree` root shadows a candidate with a
  source outside the requested `--test-dir` areas, or if overlapping discovery
  areas map one logical name to different sources, `titanc` fails with an error
  rather than running another subtree's tests.
* **Exclusions and explicit roots.** `--test-exclude MODULE` accepts an exact
  logical module name (no globs) and removes it from **automatic** root
  selection only; it requires `--test-dir`. An explicit positional root on the
  command line wins over `--test-exclude`, and an excluded module that is
  imported by a selected root still participates in the import closure.
  Explicit positional roots keep their command-line order (deduplicated) and
  precede the bytewise-sorted automatic roots. If no explicit roots are given
  and automatic discovery finds no matching modules, `titanc` fails with
  `no test modules found`.
* **Root selection versus case discovery.** The filename convention applies only
  to `--test-dir` root selection; arbitrarily named test modules remain valid as
  explicit positional roots, and actual test cases inside any selected root or
  imported source module are still discovered solely by the semantic `test_`
  signature rule above. A selected root with zero `test_` functions is allowed.
  Unselected files outside the requested import closure are ignored even if
  malformed, whereas a syntax or I/O error in a selected root or its
  contributors fails the build.

### Source-first resolution and runner generation

Test mode deliberately resolves dependencies **source first**, falling back to
the normal compiled-provider order only when no source exists. This is one
invocation-wide policy, so a coherent source closure is selected regardless of
root order. Lookup order does not grant local visibility: an ordinary
`import "app.calc"` remains public-only even when test mode selected its source.
A test that intentionally needs local declarations writes
`import "app.calc.titan"`; that explicit edge requires source and has no compiled
fallback under the rules in
[Visibility through explicit source imports](source-import-visibility.md). Ordinary
compilation remains binary first by default, and `--static` still only swaps `.a` and
`.so` preference during the compiled fallback of ordinary imports.

The compiler generates a thin ordinary source module with the reserved identity
`titan.test.runner`. It imports `titan.test` and every test owner through their
public interfaces, wraps discovered callbacks in `test.Case` descriptors, and
provides the sole `main`, which calls `test.run(args, cases)`. A `main` in an
input module is ignored in test mode. Unless `--exe PATH` specifies the
executable destination directly, the first resulting root (explicit roots first,
then bytewise automatic roots) owns the default executable path, including the
usual folder-root `__main` rule, so unrelated roots can form one test
executable. No provider pair is emitted. The generated runner
source (`<name>__test_runner.titan`, with its C and object) and entrypoint
(`<name>__test_entrypoint.c`) are isolated per target under
`<output>/.titan-links/<key>/synthetic/`, where `<name>` is the last component
of the first root. Ordinary test and dependency
translation units keep their normal generated-file locations: the selected
[output directory](output-directory.md), or beside the source when none is
selected.

`titan.test` follows ordinary source/provider resolution and uses the same
standard provider as other imports. Test mode neither copies its source nor
compiles a private support variant. A prepared SDK supplies its compiled
implementation; no installed Titan test source is required. With `--static`,
its selected archive remains selected unless an actual authored source import
independently creates a provider overlap under the normal composition rules.

With `--incremental`, `titanc --test` certifies module objects and the final
test executable link under `<output>/.titan-links/`: a warm build with no
source, header, flag, or case changes reuses the existing test binary without
parsing, rendering the runner, compiling C, or relinking. For compile-only
workflows, `-c --test --incremental` certifies or compiles source objects with
test-owner flags without synthesizing a runner or executable; see
[Separate native test executables](incremental-compilation.md#separate-native-test-executables).

Production modules can share unchanged objects between application and test
executables when compilation settings and resolved dependency providers match.
An explicit source import in a test grants visibility to that producer's
existing private declarations; it does not require a test-specific producer
object. Different optimization, coverage, toolchain, or provider settings still
require distinct objects or a rebuild. `--static` is a compiled-provider
preference, so verify standalone delivery with a relocated executable that
cannot find the compiler or Titan provider. See
[Static compiled modules](static-compiled-modules.md).

Only translation units that own a discovered test receive
`-fno-optimize-sibling-calls`, preserving useful native frames for
[`location`](#location-and-failure-traces). Production source dependencies,
`titan.test`, the generated runner, and the entrypoint retain normal flags.
A browser test image built under the `production` profile also compiles those
translation units with `-fno-inline` and links without the WebAssembly
optimizer's inlining and identical-function merging
([browser build profiles](browser-target.md#build-profiles)).

## The `titan.test` API

The canonical module name is `titan.test`; `import "test"` is parser shorthand.
It imports no other Titan standard module, so it can test the standard library
itself.

### Case registration and execution

```text
Case.new(full_name: string, owner_module: string,
         body: function(Context): ()): Case
run(args: {string}, cases: {Case}): integer
```

`Case.new` stores a fully qualified case name, the logical owner used for
failure attribution, and a callback. Its fields are private. `run` executes
cases in Array order with the standard filtering, reporting, subtest, and
cleanup behavior described below. Arguments exclude the executable name.
It returns 0 for a successful run or help, 1 for test failures, and 2 for
invalid command-line options. It rejects a nested active run and restores
inactive state when execution ends. The generated runner uses this public API;
custom runners may use it too.

### Runner state

```text
function testing(): boolean
function verbose(): boolean
```

`testing()` is true while `test.run` is executing tests and cleanup.
`verbose()` is true in that interval when the executable received `-v` or
`--verbose`. Both are false in ordinary programs, while command-line options
are being parsed, and during imported module initializers: imported modules
initialize before the generated `main` can activate the runner.

### Assertions and skips

```text
function assert(check: boolean, message: string?)
function skip(reason: string?)
```

`assert` returns when `check` is true and raises `message` or
`"assertion failed"` otherwise. While a runner is active, `skip` raises a
`titan.test.Skip` value with public readonly `reason: string?`. This lets
asynchronous test helpers recognize and preserve a skip without importing
private runner code. A body skip marks that test skipped and prevents its
registered children from running. A program may catch either raise itself; a
caught value has been handled, so execution continues normally.

Outside a runner, `assert` still raises a readable ordinary error and `skip`
raises `"test skipped"` (with an optional `: reason` suffix).

### Contexts, subtests, and cleanup

```text
record Context
end

function Context:name(): string
function Context:log(message: string)
function Context:run(name: string, subtest: function (Context): ())
function Context:cleanup(f: function (): ())
```

The runner supplies the contexts passed to tests; `Context` has no public
fields. `name()` returns the full name. `log` asks the runner to write and
flush an informational line decorated with the test's full name. Tests that
deliberately exercise code which
logs expected diagnostics should emit clear `BEGIN` and `END` messages around
that code, so the intervening output cannot be mistaken for an unasserted test
failure. `run` registers a child named
`<parent-name>.<name>` and preserves registration order. Children run only
after the parent body returns, and may recursively register their own
children. Repeated child names are allowed and run as separate cases.

`cleanup` registers a zero-argument callback. Cleanup runs after all children,
in last-in-first-out order, whether the body passes, skips, or fails. Every
registered cleanup is attempted even after one raises. The first cleanup error
fails an otherwise passing or skipped test; an earlier body failure remains the
primary reported error. Calling `skip` from cleanup is a failure because
children may already have run.

Subtest registration closes when the body returns or raises. Cleanup
registration remains open while descendants run, so a child that deliberately
captures its parent's context may still append parent cleanup. Once parent
cleanup begins, neither channel accepts more registrations; in particular, a
cleanup callback cannot extend its own stack. A language `defer` inside a test
body is different: it runs as the body returns, **before** subtests, whereas
`Context:cleanup` runs after the complete descendant schedule.

A body failure or skip reports every already-registered matching child as
skipped without invoking it. A child failure does not change its parent's own
status: the child is reported failed, later siblings continue, and the process
still exits unsuccessfully because at least one case failed.

## Location and failure traces

```text
function location(): (string, string, integer)
```

`location()` raises and catches a private probe and returns the first native
Titan call frame outside the exact `titan.test` support and generated runner
modules. The tuple is source filename, qualified function name, and line. It
returns `"<none>", "<none>", 0` when no suitable frame is available.

A non-verbose failure similarly prints its independently rendered error value
at the first frame owned by the test's logical module, falling back to the
first external Titan frame. `--verbose` additionally prints the complete raw
traceback. Error rendering accepts arbitrary Lua/Titan values and uses a fixed
fallback if an error's `__tostring` itself raises.

Logical frames depend on normal `#line` directives and debug information.
`--no-line-directives` is an isolated generated-C diagnostic mode and may make
`location()` return the sentinel or reduce failure attribution; do not use it
for normal test builds.

## Asynchronous tests

By default, a test executable uses the ordinary standalone bootstrap selected
by its imports. If the suite imports `async` or another module in that runtime
constellation, the complete generated runner executes as one Task inside one
Runtime. Test bodies, subtests, and cleanup callbacks may then suspend directly
and must not call `async.loop` recursively.

Passing `--no-uv-bootstrap` selects explicit ownership instead. The entrypoint
calls the runner's `main(args)` directly even though an imported `titan.async`
still initializes, performs its startup policy, and leaves its bootstrap hook
installed. A test that needs asynchronous work
must start a Task with `async.run`, call `async.loop`, and finish every
Runtime-bound Task and handle before that loop returns. Runner
`Context:cleanup` occurs later and is therefore suitable only for resources
that do not require the ended Runtime. Several explicit sessions may run
sequentially in one executable.

The repository's aggregate standard-library executable uses this explicit
mode. Its source-only test helper runs each async case under one supervisor Task
and performs registered Runtime cleanup in LIFO order inside that Task. Tests
whose oracle is the automatic bootstrap itself compile and supervise a separate
standalone child without `--no-uv-bootstrap`.

## Running and filtering

A generated executable accepts:

```text
./suite [-h|--help] [-v|--verbose] [-f PATTERN|--filter=PATTERN]...
```

`-f` may be repeated; filters use Lua pattern syntax and combine with OR.
Malformed patterns are rejected before any test starts. A root that does not
match is not entered and therefore cannot discover dynamic children. Entering
a parent does not automatically select a child: each complete child name is
filtered independently. Filtered cases are absent from counts, not skipped.

The timing-free output follows the gtest shape:

```text
[==========] Running Titan tests.
[ RUN      ] calc_test.test_twice
[ RUN      ] calc_test.test_twice.zero
[       OK ] calc_test.test_twice.zero
[       OK ] calc_test.test_twice
[==========] 2 tests ran.
[  PASSED  ] 2 tests.
```

Help exits with status 0. Invalid options or patterns exit 2. Any failed case
makes the executable exit 1; all-pass, all-skip, zero-selected, and zero-test
runs exit 0. Skipped and failed summaries are printed only when nonzero.

The Titan repository runs the same explicit standard-library test owners on
Linux, macOS, and native Windows. Its build gate adds stricter completeness
checks: an unfiltered run must execute every owner, an empty selection is an
error, and skips must explain a platform, environment-capability, or unsupported
API limitation. These are repository validation rules; they do not change the
public runner's exit-status or `skip` contract. See the
[repository test workflow](../implementation/test-runner.md#platform-portability-and-complete-execution)
and [native Windows commands](../implementation/windows-build.md#shared-native-standard-library-tests).

Repeated filters also let several processes share one built executable. On
Linux and macOS, the repository's `make titan-stdlib-test-run-parallel` target,
which `make titan-stdlib-test` uses when no `TITAN_FILTER` is given, runs the
same executable as `TITAN_TEST_JOBS` concurrent processes (default four, any
positive integer; `1` runs the groups one after another). Each process selects
a disjoint group of test owners with one anchored `--filter` per owner and gets
its own temporary directory and log. Owners whose tests measure short
deadlines or wall-clock behavior, such as the TLS, HTTP, WebSocket, timer, net,
and OS suites, run afterwards in one process of their own, with nothing else
running. The target then audits the combined output: every owner exactly once,
no case reported twice, and consistent totals. A failing group does not stop
the others. Deadlines, retries, and case selection are the same as in one
serial run. `make titan-stdlib-test-run` remains the focused single-process
command, and native coverage and Windows runs stay serial. See [parallel
native aggregate runs](../implementation/test-runner.md#parallel-native-aggregate-runs)
and [Build and test parallelism](build-profiles.md#build-and-test-parallelism).

## Initial boundaries

The runner is intentionally synchronous and recursive. It supplies no suite
objects, fixtures, timing, parallel scheduling, coverage collection, or
`before_each`/`after_each` syntax. Ordinary functions plus `defer`, subtests,
and cleanup cover the initial fixture needs. Deeply nested trusted subtests use
the native call stack.
