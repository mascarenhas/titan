# Testing Titan code

Titan ships a small native test library, `titan.test`, and a compiler mode that
turns ordinary Titan modules into a standalone test executable. Test files are
not a distinct source kind: a test is a public top-level function discovered in
an ordinary flat or [folder module](folder-modules.md).

```lua
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

`titanc --test M...` typechecks each requested source root and its source
import closure. It discovers every declaration that is all of the following:

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

Test mode deliberately resolves dependencies **source first**, falling back to
the normal compiled-provider order only when no source exists. This is one
invocation-wide policy, so a coherent source closure is selected regardless of
root order. It lets a test directly source-import and use local declarations of
the module under test under the rules in
[Visibility through source imports](source-import-visibility.md). Ordinary
compilation remains binary first, and `--static` still only swaps `.a` and
`.so` preference during the compiled fallback.

The compiler generates an ordinary source module with the reserved identity
`titan.test.runner`. It imports every test owner directly and provides the sole
`main`; a `main` in an input module is ignored in test mode. The first requested
root owns the executable path, including the usual folder-root `__main` rule,
so unrelated roots can form one test executable. No provider pair or Lua shim
is emitted. Adjacent generated artifacts use the executable stem:
`__test_support.c/.o`, `__test_runner.c/.o`, and
`__test_entrypoint.c/.o`; ordinary test and dependency translation units keep
their normal source-adjacent paths.

Only translation units that own a discovered test receive
`-fno-optimize-sibling-calls`, preserving useful native frames for
[`location`](#location-and-failure-traces). Production source dependencies,
`titan.test`, the generated runner, and the entrypoint retain normal flags.

## The `titan.test` API

The canonical module name is `titan.test`; `import "test"` is parser shorthand.
It imports no other Titan standard module, so it can test the standard library
itself.

### Runner state

```lua
function testing(): boolean
function verbose(): boolean
```

`testing()` is true while the generated `main` is executing tests and cleanup.
`verbose()` is true in that interval when the executable received `-v` or
`--verbose`. Both are false in ordinary programs, while command-line options
are being parsed, and during imported module initializers: imported modules
initialize before the generated `main` can activate the runner.

### Assertions and skips

```lua
function assert(check: boolean, message: string?)
function skip(reason: string?)
```

`assert` returns when `check` is true and raises `message` or
`"assertion failed"` otherwise. `skip` raises the runner's private nominal skip
marker. A body skip marks that test skipped and prevents its registered
children from running. A program may catch either raise itself; a caught value
has been handled, so execution continues normally.

Outside a runner, `assert` still raises a readable ordinary error and `skip`
raises `"test skipped"` (with an optional `: reason` suffix), rather than
exposing the private marker.

### Contexts, subtests, and cleanup

```lua
record Context
end

function Context:name(): string
function Context:log(message: string)
function Context:run(name: string, subtest: (Context) -> ())
function Context:cleanup(f: () -> ())
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

```lua
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
calls the runner's `main(args)` directly even though `titan.uv` still initializes
and leaves its bootstrap hook installed. A test that needs asynchronous work
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

## Initial boundaries

The runner is intentionally synchronous and recursive. It supplies no suite
objects, fixtures, timing, parallel scheduling, coverage collection, or
`before_each`/`after_each` syntax. Ordinary functions plus `defer`, subtests,
and cleanup cover the initial fixture needs. Deeply nested trusted subtests use
the native call stack.
