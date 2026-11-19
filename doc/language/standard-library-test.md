# Testing standard library

`titan.test` provides Titan's native test runner, paired with `titanc --test` to
compile ordinary flat or [folder modules](modules.md) into a standalone test
executable. For opt-in line coverage against Titan production sources
(`titanc --test --coverage`), see [Appendix B: Toolchain and Coverage](toolchain.md).

- **Import:** `local test = import "test"` (Titan) · `require "titan.test"` (Lua)
- **Targets:** Native & Browser (complete; imports no other standard module so it can test the standard library itself)

## Quick examples

Write public `test_*` functions taking a single `test.Context` parameter. Use
`context:run` for named subtests and `context:cleanup` for fixtures that must
outlive subtests:

```titan
local test = import "test"

local function clamp_nonnegative(n: integer): integer
  if n < 0 then return 0 end
  return n
end

local function twice(n: integer): integer
  return clamp_nonnegative(n) * 2
end

local record ScratchLog
  entries: {string}
  closed: boolean
end

function test_twice(context: test.Context)
  local log = ScratchLog({}, false)
  context:cleanup(function()
    log.closed = true
  end)

  context:run("positive", function(child)
    log.entries[#log.entries + 1] = child:name()
    test.assert(twice(21) == 42, "positive input must double")
  end)

  context:run("negative_clamps", function(child)
    log.entries[#log.entries + 1] = child:name()
    test.assert(twice(-4) == 0, "negative input must clamp to zero")
  end)
end
```

Build and run the test executable:

```sh
titanc --test -o out --tree . calc_test
./out/calc_test
```

When a test suite imports `async` (or any async standard module), the default
standalone bootstrap runs the whole test suite inside one async Task so test
bodies, subtests, and cleanup callbacks can suspend directly:

```titan
local test = import "test"
local async = import "async"
local timer = import "timer"

function test_async_worker(_context: test.Context)
  local worker = async.run(function(): string
    timer.sleep(5)
    return "ready"
  end)
  local status = async.join(worker)
  local ok, result? = status:has_succeeded()
  test.assert(ok and result == "ready", "worker did not succeed")
end
```

## Discovery and compilation

`titanc --test` checks each selected source root and its source-backed import
closure (with `--incremental`, unchanged modules reuse cached discovered
declarations without reparsing). A declaration is discovered as a test case when
it satisfies all of:

- public (non-`local`) top-level `function` whose name begins with `test_`;
- not an ignored duplicate declaration;
- exactly one fixed parameter, with no variadic tail; and
- a parameter type that normalizes to nominal `titan.test.Context` (transparent
  aliases are accepted; lookalike records are ignored).

Return types are unrestricted and returned values are discarded. Cases execute
in bytewise order of `<logical-module>.<function-name>`. Folder contributors
belong to their single logical folder module.

Test filename suffixes (`*_test.titan`, `*_spec.titan`) are conventions. Avoid
giving a test module a bare standard-library shorthand name (such as `url`,
`timer`, `string`, or `test`) or a bare Lua standard-library name (`math`); use
qualified or suffixed names such as `url_test`, `math_spec`, or `tests.math`.

### Automatic test-root discovery

Pass repeatable `--test-dir DIR` (and optional `--test-exclude MODULE`) with
`--test` to discover test roots automatically:

```sh
titanc --test --incremental -o out --exe out/suite \
  --tree . --test-dir tests --test-exclude tests.windows_only_test
./out/suite
```

- **Directory scope and namespace:** Each `DIR` must exist inside a configured
  `--tree` root. `titanc` derives logical module prefixes from the first
  containing `--tree` root (`--tree . --test-dir tests` produces `tests.*`,
  while `--tree tests --test-dir tests` produces top-level names).
- **Naming convention:** `titanc` scans `DIR` recursively and selects a flat
  file or folder main whose final logical component is `test`, `tests`, `spec`,
  `specs`, or ends with `_test`, `_tests`, `_spec`, or `_specs`. Folder
  contributors are never separate roots. Hidden directories (`.` prefix) and
  nested directory symlinks are skipped, though a symlinked directory passed
  directly to `--test-dir` is traversed.
- **Target variants:** [Target variants](modules.md) (`socket_test.<label>.titan`)
  name `socket_test` when `<label>` matches the active target, and variants for
  other targets are skipped cleanly (so `socket_test.windows.titan` needs no
  `--test-exclude` on Linux or macOS). Stacked or mis-cased labels
  (`socket_test.linux.native.titan`, `socket_test.Linux.titan`) fail discovery.
- **Resolver consistency:** If an earlier `--tree` root shadows a candidate with
  a file outside `--test-dir`, or overlapping `--test-dir` trees map one logical
  name to different sources, `titanc` fails with an error.
- **Exclusions and explicit roots:** `--test-exclude MODULE` takes an exact
  logical module name (requiring `--test-dir`) and excludes it from automatic
  selection only. Explicit positional roots override `--test-exclude`, keep
  command-line order before bytewise-sorted automatic roots, and may use any
  module name. If no roots are selected, `titanc` fails with
  `no test modules found`.
- **Root selection versus case discovery:** The naming convention governs only
  `--test-dir` root selection. Cases inside any selected root or source
  dependency are discovered strictly by the `test_*` signature rule. A selected
  root with zero `test_*` functions is valid.

### Source-first resolution and runner generation

Test mode resolves dependencies **source-first**, falling back to compiled
providers only when no source exists. Source-first resolution does not expose
`local` declarations: a test needing private declarations from a module writes
`import "app.calc.titan"`, which requires source and grants direct visibility
(see [Modules and Program Structure](modules.md)).

`titanc --test` generates a synthetic runner module (`titan.test.runner`) that
imports `titan.test` and every test owner, constructs `test.Case` values, and
defines `main` calling `test.run(args, cases)` (any `main` in input modules is
ignored). The first root owns the default executable path unless `--exe PATH` is
supplied.

`titan.test` resolves through the ordinary installed standard provider. With
`--incremental`, unchanged module objects and the final test binary are reused;
`-c --test --incremental` compiles test objects without linking a runner. See
[Appendix B: Toolchain and Coverage](toolchain.md) for output routing,
`--incremental`, `--static`, and `--coverage`.

Translation units owning a discovered test compile with
`-fno-optimize-sibling-calls` to preserve call frames for
[`location`](#location-and-failure-traces); under the browser `production`
profile they also disable inlining and identical-function merging (see
[WebAssembly and the Browser Target](browser-target.md#build-profiles)).

## The `titan.test` API

### Assertions and skips

```text
record Skip
  const reason: string?
end

function assert(check: boolean, message: string?)
function skip(reason: string?)
```

`assert` returns when `check` is `true` and raises `message` (or
`"assertion failed"` when omitted) otherwise.

Inside an active runner, `skip` raises a nominal `test.Skip` record carrying
`reason`. An uncaught skip in a test body marks the case skipped and skips any
registered subtests. Catching an assertion failure or `test.Skip` handles it
normally. Outside a runner, `assert` raises the failure message and `skip`
raises `"test skipped"` (with `: <reason>` if given).

### Contexts, subtests, and cleanup

```text
record Context

function Context:name(): string
function Context:log(message: string)
function Context:run(name: string, subtest: function(Context))
function Context:cleanup(f: function())
```

The runner creates and supplies every `Context`.

- `name()` returns the case's full name (`<module>.<func>` or
  `<parent>.<subtest>`).
- `log(message)` writes and flushes a decorated informational line immediately.
- `run(name, subtest)` registers a child named `<parent>.<name>` in registration
  order. Children run after the parent body returns and may nest further
  children. Repeated child names are permitted and run separately.
- `cleanup(f)` registers a zero-argument callback that runs after all
  descendants finish, in LIFO order, whether the case passes, skips, or fails.

Cleanup rules:

- Every registered cleanup callback runs even if an earlier cleanup raises.
- The first cleanup error fails an otherwise passing or skipped case; an
  earlier body error stays the primary reported failure.
- Calling `skip` inside cleanup fails the case because descendants may already
  have run.
- Subtest registration closes when the body returns. Cleanup registration stays
  open while descendants execute and closes once cleanup starts (a cleanup
  callback cannot add another cleanup).
- Language `defer` runs when its enclosing block exits—**before** subtests
  start—whereas `Context:cleanup` runs **after** all subtests complete.
- If a parent body fails or skips, already-registered matching children are
  reported skipped without running. A child failure does not mark its parent
  failed; later siblings continue, and the process exits `1`.

### Runner state

```text
function testing(): boolean
function verbose(): boolean
```

`testing()` is `true` while `test.run` executes cases and cleanup. `verbose()`
is `true` in that interval when `-v` or `--verbose` was passed. Both are `false`
outside `test.run`, during option parsing, and inside module initializers
(which execute before `main`).

### Case registration and execution

```text
record Case

function Case.new(full_name: string, owner_module: string,
                  body: function(Context)): Case
function run(args: {string}, cases: {Case}): integer
```

`Case.new` builds a case descriptor with its full name, logical owner (used for
failure attribution), and body. `run` executes `cases` in Array order with the
CLI flags, filtering, subtests, cleanup, and reporting below (`args` excludes
the executable name). It returns `0` on success or `--help`, `1` on test
failures, and `2` on invalid options, resetting runner state on exit and
rejecting nested `run` calls.

## Location and failure traces

```text
function location(): (string, string, integer)
```

`location()` returns `(filename, qualified_function, line)` for the first
native Titan frame outside `titan.test` and `titan.test.runner`, or
`("<none>", "<none>", 0)` when unavailable.

Concise failure output prints the rendered error at the first frame owned by
the test's logical module (falling back to the first external Titan frame).
`-v`/`--verbose` appends the full raw traceback. Accurate frame attribution
relies on normal `#line` directives and debug information; avoid
`--no-line-directives` for test builds.

## Asynchronous tests

By default, a test suite that imports `async` (or any async module) executes
the entire runner inside one standalone async Task, so tests, subtests, and
cleanup callbacks can suspend directly without calling `async.loop()`.

Passing `--no-uv-bootstrap` runs `main` directly without a supervisor Task. Each
async test must then start its own `async.run` / `async.loop` session and
finish all Runtime-bound Tasks and handles before `async.loop()` returns;
`Context:cleanup` executes after that loop ends and is suitable only for
non-Runtime resources.

A parent may share an immutable fixture (such as a compiled helper executable)
across subtests and remove it in `Context:cleanup`, while each child owns its
own mutable files, processes, or descriptors.

## Running and filtering

```text
./suite [-h|--help] [-v|--verbose] [-f PATTERN|--filter=PATTERN]...
```

Repeatable `-f`/`--filter` flags use Lua pattern syntax combined with logical
OR; invalid patterns exit `2` before any case runs. A top-level test that does
not match is never entered, and each child's full name is matched independently.
Filtered-out cases are omitted from counts rather than marked skipped. Repeated
`-f` filters also let external runners partition one test executable across
parallel processes.

Output uses gtest-style formatting with monotonic wall-clock durations in
milliseconds (including waits, descendants, and cleanup):

```text
[==========] Running Titan tests.
[ RUN      ] calc_test.test_twice
[ RUN      ] calc_test.test_twice.positive
[       OK ] calc_test.test_twice.positive (0.02 ms)
[ RUN      ] calc_test.test_twice.negative_clamps
[       OK ] calc_test.test_twice.negative_clamps (0.01 ms)
[       OK ] calc_test.test_twice (0.08 ms)
[----------] calc_test (0.08 ms total)
[==========] 3 tests ran. (0.15 ms total)
[  PASSED  ] 3 tests.
```

Skip reasons precede the duration:
`[  SKIPPED ] suite.test_case (reason) (0.03 ms)`. Uninvoked children of a
failed or skipped parent report `0.00 ms`. Owner totals (`[----------]`) sum
only top-level intervals so subtests are not double-counted.

Exit statuses: `0` for all-pass, all-skip, zero-selected, zero-test, or
`--help`; `1` if any case or cleanup failed; `2` for invalid flags or filter
patterns. Native Unix, Windows, and browser runs under Node or Chromium use the
same formatting and accounting.
