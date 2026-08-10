# Test infrastructure and runner

Test runner for Titan code, both for utility to future Titan programmers,
and also to reduce the dependency on Lua and `busted` for testing Titan
itself, specially the Titan stdlib, which is a collection of modules
written In Titan that should be testable in Titan, too.

## Test files are modules

Test files are just modules, with the `*_test.titan`/`*_spec.titan` naming
as convention, not a requirement. Their location is also not prescribed,
with possible project-specific conventions being the same folder as the
module(s) they are testing, a `test/spec` subfolder, or a completely
separate `test/spec` folder at the project root (like the Titan compiler)
uses. They import the module(s) that they are testing through source imports,
so test file location will only change what module search path the
programmer should pass to `titanc` when building the test suite.

A test module can be a folder module, this is one way of breaking up a test module
into multiple files.

## New `titanc --test`

Where they diverge from regular modules is that they should be compiled
with a new `--test` flag for `titanc` that does two things:

1. Prioritizes source imports ahead of binary imports when compiling each test module,
this lets these test modules view and use local members of the modules they are testing,
because of the direct source import local visibility rules.

2. Compiles a standalone executable from the test modules passed to `titanc`
even if none have a `main` public function. This is done through a synthetic
(generated at compile time) `titan.test.runner` module that provides the
`main` function together with support functions and state of the test
runner (as local functions and local module variables inside this) module,
and imports the modules that give the initial test case set as direct imports.

This synthetic module can be an embedded template in the Titan compiler source
that is hydrated with the initial set of test cases discovered from the test
modules being compiled with it. The `main` function parses test runner
command-line options and starts the test runner.

The result is a binary that will run and report on the tests (with optional
filtering).

## Test suite discovery

For the discovery of the initial test suite set, the compiler driver will
look for all top-level non-local functions in the compiled bundle (so not just the
direct modules added to `titanc` call, but their source import closure)
for functions called `test_*` that take a single `titan.test.Context` parameter,
and register these as the initial set of test cases for the test runner, with
`<modname>.<function_name>` as the test name for filtering purposes.

## `titan.test`

The `titan.test` module is a new stdlib module (so `titan.test` is its canonical name,
but it can be imported in Titan code with `import "test"`), it defines this interface:

```
-- returns true if we are running in the test runner, false otherwise
function testing(): boolean
-- returns true if the test runner is running with the `-v/--verbose` flag
function verbose(): boolean
-- returns the file name, function name, and line number of the
-- first native call frame that is not from the titan.test module
-- it does that by raising and catching an exception then processing
-- the traceback to extract this information, test modules
-- should be compiled with `-fno-optimize-sibling-calls` (but test modules
-- only, the non-test modules they import are compiled with normal flags)
-- if no native Titan call frame is found returns `"<none>", "<none>", 0`
function location(): (string, string, integer)
-- raises a marker exception that marks the current test and its subtests
-- as skipped, with an optional reason
function skip(reason: string?)
-- convenience to raise conditional on a check
function assert(check: boolean, message: string?)

record Context
end

-- schedule f to run after the current test and its subtests finishes
-- a simple test function without subtests may wish to use `defer` for this
-- cleanup can be called multiple times to register several functions, that are run
-- in LIFO order; the lack of a context argument is intentional, if the user
-- circumvents that to capture the context this context cannot be used to
-- add more subtests when cleanup functions are running
function Context:cleanup(f: () -> ())
-- return the name of the current test
function Context:name(): string
-- register a subtest of the current test to run
-- the name the subtest gets registered with is "<current_test_name>.<name>"
-- subtests run in the order they are registered, after the body of the test
-- that registered them finishes
-- they get their own context, and can have their own subtests
function Context:run(name: string, subtest: (context: Context) -> ())
```

## Test failures

If a test raises this is caught by the test runner loop and the test
is marked as failed, on non-verbose runs the traceback is processed to
extract just the error message and the location in the test module where
the error passes through, on verbose runs besides this information the
full traceback is also logged. If a test fails all of the subtests it registered
up to that point are marked and reported as skipped so they are not actually run.

The traceback information extraction can be done by a local function,
and reused by `location()` and by the part of the test runner that
handles failed tests (the test runner will already know the name of
the failed test). 

This is intentionally barebones, with `cleanup` a necessity because the
parent test has no way of knowing when its subtests have finished. The
common `before_each`/`after_each` hooks can be written by programmers
as explicit code in the tests/subtests that just calls a function
(using `defer` the for the `after_each` equivalent).

## No stdlib dependency

The `titan.test` and `titan.test.runner` modules should not depend on any
of the other stdlib modules, since it should be useful for testing the rest of the
stdlib itself. This means that any IO the test runner needs to be done can be
synchronous and done through the FFI, using the C99 standard library.
String manipulation should also be done through through this approach,
using `luaL_dostring(L, "return <lua_stdlib_function>")` for useful Lua
stdlib functions such as Lua's pattern matching functions from the `string`
package.

## Test runner executable options

The executable produced by `titanc --test` accepts these switches:

```
./foo_test [-h|-help] [-v|--verbose] {-f pattern|--filter=pattern}
```

- `-h`/`--help`: print a short usage message and exit
- `-v`/`--verbose`: run verbose, with full tracebacks of failing tests
- `-f pattern`/`--filter=pattern`: run only tests with a full name that matches
`pattern`, a test that gets filtered out also filters out its subtests, and a
test that gets included via the filter does not mean that its subtests will
be included, the filter will test them too; this switch can be passed multiple
times and it will include tests that pass any of the filters; the pattern uses
Lua pattern syntax, because the `test.runner` module can use the Lua pattern
matching functions through the FFI via tha `luaL_dostring` trick above.

You can model the test runner log on the `busted` log with the `gtest` reporter.

## Dogfooding

With the testing infrastructure in place (`titanc` and `driver.lua` changes, the
`titan.test` module, the generated `titan.test.runner` embedded in the test executables),
most (ideally all) of the stdlib tests should be moved to tests written in Titan using
this infrastructure. Their source files can still live alongside the `.lua` tests in `spec/`.

Like `titan.test` and `titan.test.runner` themselves, the stdlib tests should avoid the
rest of the stdlib in their code for loading/constructing test fixtures and checking
results. Instead they should make liberal use of C and Lua stdlib functions through the
FFI.

Code coverage is out of scope of this initial version of the test runner and test
infrastructure. There is no loss for the stdlib tests because we are running them
with coverage disabled in any case (since `busted` code coverage only covers the Titan
compiler Lua code, which for stdlib does not add anything, the compiler tests should be
the source of test coverage for the Titan compiler).
