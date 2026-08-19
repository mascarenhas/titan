# Native test runner implementation

Titan's test infrastructure has three ordinary pieces:

1. `titan/test.titan`, the public `titan.test` standard module and its
   source-private runner protocol;
2. `titan-compiler/test_runner.lua`, which discovers checked test functions and
   renders a synthetic Titan module; and
3. the `titanc --test` orchestration in `titanc` and `driver.lua`.

There is no test AST node, special code-generator lowering, runner C runtime,
registry identity trick, or second compiler pipeline. The synthetic runner is
checked, generated, compiled, linked, and initialized as an ordinary logical
module.

## Resolution and the canonical support source

A test invocation creates a resolver context with `source_first = true`.
For every non-root dependency, `defaultloader` first asks the tagged folder/flat
source resolver. A found source or blocked constituent is terminal; only a
clean miss enters the existing complete `.so`/`.a` format passes, in the order
selected by `prefer_static`. Explicit roots remain source-required. Ordinary
resolver contexts retain their binary-first behavior byte-for-byte.

Checker-time static preference is provisional until resolver finalization. If a
selected archive is later found to carry a source-selected identity, the loader
rebinds every already selected key from that archive to a DSO before codegen,
but only when each fallback is ABI-valid and has exactly the same serialized
interface. Missing or different fallback is a composition error; source is
never rebound, archive membership is never partially linked, and no rebinding
occurs after finalization.

`source_overrides` is a narrow descriptor map used for two trusted modules.
The compiler overrides exactly `titan.test` with its canonical source and later
adds generated `titan.test.runner` contents. It does not add the standard
library checkout to the user's source path. Checkout mode locates
`<checkout>/titan/test.titan` from `driver.lua`'s own provenance. Installed
mode uses the transactionally published
`<root>/share/titan/0.26/src/titan/test.titan`; a missing/nonregular file is an
explicit test-mode diagnostic. This real direct source edge is what grants the
runner access to private declarations. Binary metadata remains public-only.

Generated descriptors carry `files`, an in-memory `contents` map, the usual
`program_output`, and optionally a separate `native_output`. `parse_source`
still parses every listed filename independently and calls the checker once.
`native_output` changes only the generated C/object destination; logical
identity, diagnostic locations, and source provenance remain untouched. The
support translation unit is therefore emitted as
`<program>__test_support.c/.o` rather than modifying the installed or checkout
source tree.

## Checked-AST discovery

After requested roots and their source closures check, `test_runner.discover`
walks only source-backed entries in the union of those closures. A candidate is
a surviving nonlocal `Ast.TopLevelFunc`, begins with `test_`, has one fixed
parameter and no `varargtype`, and normalizes that parameter with
`types.normalize` to `Type.Nominal("titan.test.Context")`. Results are not
restricted because the generated wrapper calls the function as a statement.

Source module names and then full case names are sorted with
`util.bytewise_less`; discovery never depends on `pairs` order. It returns both
the case descriptors and the exact owner-module set used for compilation
flags. Binary modules have no AST and are never discovered, even when a static
provider physically carries other logical keys.

## Synthetic source and native outputs

`titan-compiler/test_runner.lua` hydrates fixed source text with:

* one deterministic direct import alias per distinct owner;
* one exact `(test.Context) -> ()` wrapper per case, which discards any result;
* `TestCase` registration statements; and
* the fixed runner implementation and `main`.

The logical name `titan.test.runner` is reserved in test mode and never appears
in the standard provider. Test owners remain subject to ordinary import and
native-symbol naming. A bare owner rewritten by standard-library shorthand is
rejected before runner checking because generated source has no exact import
spelling for it; a bare name such as `math` would instead collide with Lua's
`luaopen_math`. The documented `*_test`/`*_spec` convention avoids those
pre-existing module constraints. The runner directly imports every accepted
test owner and `titan.test`, preserving private-source identity. The source descriptor is
named `<first-program-output>__test_runner.titan`; the ordinary coder produces
the adjacent `.c/.o`. `compile_program` receives an explicit
`__test_entrypoint.c` path and links the same standalone objects, selected
static providers, runtime archive, and `-X` payload order as any other main.
The first requested root's `program_output` owns the executable, including the
folder `__main` convention. Input application mains do not participate in main
selection under `--test`.


Before emitting any C, `validate_program_output_paths` checks every source,
support, runner, entrypoint, executable, and Darwin dSYM destination in both
normalized and physical-parent form. It rejects output/output and output/input
aliases, ancestor/descendant conflicts, symlink leaves, and an existing leaf of
the wrong regular-file/directory kind; generated-parent creation never replaces
an occupied path.

`driver.compile` accepts an invocation-local `extra_compile_flags` list.
`titanc` passes `{ "-fno-optimize-sibling-calls" }` after ordinary configured
C flags only for modules in the discovery owner set. Support, runner,
entrypoint, non-test source dependencies, probes, and provider objects are not
changed. This is deliberately object-scoped rather than global mutable driver
policy.

## `titan.test` private protocol

The public module serializes only `testing`, `verbose`, `location`, `skip`,
`assert`, the nominal `Context`, and its four methods. Its fields,
`RegisteredTest`, callback aliases, markers, state, and all `runner_*` helpers
are local. The direct-source runner uses:

* `runner_begin` / `runner_end` for module-local active and verbose state and
  the generated runner's logger callback;
* `runner_new_context` to construct the otherwise unconstructible public
  nominal record;
* `runner_take_subtests` to seal subtest registration and detach the ordered
  child Array while leaving parent cleanup registration open to descendants;
* `runner_take_cleanup` to pop the live cleanup Array in LIFO order;
* `runner_skip_reason` for nominal marker classification;
* `runner_trace_location`, `runner_error_text`, and `runner_matches` for the
  trusted Lua boundary.

A Context has separate `subtests_open` and `cleanups_open` state. The former
closes at the body-to-descendants transition; the latter closes when cleanup
starts, so a descendant may deliberately append cleanup to a captured parent.
Popping before invoking cleanup ensures every registered callback can be
attempted without retaining a completed closure. `runner_begin` also installs
the generated runner's logger callback. `Context:log` supplies that callback
with the context's full name and the message; the runner owns the decorated,
flushed output line. Runner activation occurs in synthetic `main`, after CLI
validation and after module initialization; this intentionally leaves
`testing()` false in initializers and avoids an entrypoint registry protocol.

## Execution state machine

`execute` applies filters before constructing a context. An entered case
increments `run`, invokes its body under `catch`, classifies only the nominal
skip marker as skipped, and otherwise stores the separately rendered error and
raw trace. It then detaches children:

* pass: recursively execute selected children in registration order;
* skip/failure: report each selected child skipped with a parent reason.

The parent does not inherit a descendant failure. All selected descendants
still contribute to the shared counters, so any failure reaches process status
1. Cleanup then pops under one catch per callback. The first cleanup error
replaces pass/skip but never replaces an existing body failure. A cleanup skip
is converted to a readable failure. Finally the case prints one terminal line;
failed names are retained for the final list.

CLI parsing happens before `runner_begin`. Repeated filter patterns are stored
in a dense Array, validated once, and ORed. Help returns 0, malformed input 2,
failed cases 1, and all other runs 0. Reporting uses C99 `putchar`, not
`titan.io`, and is byte-length-aware.

## Trusted Lua helpers and traces

`titan.test` imports only `lua.h`, `lauxlib.h`, and `titan/ffi.h`. A guarded
final initializer compiles one fixed Lua chunk with callable `luaL_loadstring`
and `lua_pcallk`; the function-like `luaL_dostring` macro is intentionally not
available through the FFI. In a normal standalone, `luaL_openlibs` has already
run, so this snapshots the helpers before any test-owner initializer. A bare
validation state may not have opened the standard libraries; that initializer
catches the load failure and the first later trace or pattern operation retries.
The chunk snapshots the required base/string callables into locals before it
returns two traced closures:

* a raw-trace scanner using the captured `string.gmatch`/`string.match`; and
* a Lua-pattern predicate using the captured `string.find`.

Capturing at `titan.test` initialization keeps those helpers valid even when a
test owner has a logical name such as `math` and replaces the corresponding Lua
global during standalone initialization. The helper saves the Lua top, reserves stack space, converts returned closures
to traced Titan function values, and restores the stack through `defer`.
`runner_error_text` uses the same ledger around `luaL_tolstring` and catches a
throwing `__tostring`, preserving a fixed fallback.

A native frame has the runtime form
`file.titan:LINE: in qualified.function`. The scanner skips exact support
functions/methods and the `titan.test.runner` namespace, but not unrelated user
modules whose names merely begin `titan.test.`. It remembers the first external
Titan frame and prefers one whose function belongs to the known test owner.
The raw trace stays unmodified for verbose output. Normal `#line` directives,
`-g`, and the test-owner sibling-call flag are therefore part of the useful
location contract.

## Standalone asynchronous bootstrap

The generated runner has an ordinary Titan `main`. It does not own a scheduler
or special-case asynchronous tests. Without another option, an imported
standard module may install the existing standalone async bootstrap, which
invokes the complete runner inside one Task and one Runtime.

`--no-uv-bootstrap` changes only the generated entrypoint's choice after module
initialization: it takes the ordinary direct call to runner `main` even when the
registry hook is non-nil. It does not clear or identify the hook and does not
change `titan.uv`. The repository aggregate uses this option so its source-only
`support.runtime` helper can establish sequential sessions. `run(body)` creates
one supervisor Task, runs `async.loop`, and re-raises the body's original value
with its pinned traceback after all registered LIFO Runtime cleanup completes.
A Runtime-bound Task or handle must be registered there; later
`Context:cleanup` cannot suspend in a Runtime that already ended.

The runner remains Task-independent in both modes. Automatic-bootstrap behavior
is tested by separately compiled child programs that deliberately omit the
option, rather than by exposing private registry state or adding a runner
lifecycle protocol.

## Repository dogfooding

The Makefile's `TITAN_STDLIB_TEST_ROOTS` manifest names 22 module-owned roots
under `spec/stdlib/titan/`. `make titan-stdlib-test-build` makes every one an
explicit root in a single `titanc --test --no-uv-bootstrap` invocation: source
remains authoritative, discovery sees the complete checked closure, and no import-only
aggregator can be shadowed by a compiled provider. The command runs from
`.titan-tests/` with an absolute source tree. The designated first program
root, `test.tests`, owns the one `.titan-tests/test/tests` executable; synthetic
support, runner, entrypoint, and Darwin dSYM outputs are owned below the same directory. Ordinary
module translation units are temporarily generated beside their Titan sources.

`make titan-stdlib-test-run` returns to the repository root before executing,
because several fixtures use repository-relative paths. `TITAN_FILTER` supplies
one Lua pattern to this already built executable; it never changes the 22-root
compile. `make titan-stdlib-test` composes build and run, while the split leaf
targets let sanitizer and focused development runs reuse one build in multiple
fresh processes. `BUSTED_FILTER` is independent and belongs to
`busted-test`; `rock-test` enters both domains without inventing native group
names.

`run_with_timeout.sh` uses Bash monitor mode to give the executable its own
process group and polls it at a coarse interval. At the deadline it sends
`TERM`, then `KILL` after a short grace period, maps the timeout to status 124,
and otherwise preserves the child's status. Make streams combined
stdout/stderr through a pipe rather than redirecting either stream to a regular
file, preserving the parent-pipe boundary tested by OS/stdio cases. Expected
uncaught Task diagnostics are owned by their Titan tests: a case emits flushed
`Context:log` messages containing `BEGIN expected uncaught async Task
diagnostics` and `END expected uncaught async Task diagnostics` around the
operation. Those prefixed brackets make a successful aggregate log readable
and keep the expectation owned by the case that produces it.

Cleanup is generic within a narrow ownership boundary. `.titan-tests/` is a
Make-owned directory and may be removed recursively. Under `spec/`, the cleanup
helper removes all generated `.o` files and removes a `.c` only when a
same-stem `.titan` source exists. It does not consult Git, so it also works in a
source rock, while author-written C fixtures remain untouched. Root-level
compiler fixtures retain their existing exact cleanup rules.

The regular Linux stdlib producer runs the retained host boundaries and this
aggregate executable without LuaCov. The sole regular consumer runs the
complete compiler/language group with LuaCov and publishes one report. The
sanitizer builds an independent ASan+UBSan aggregate once and selects focused
cases with the run target; it never restores the regular artifact. The complete
macOS gate remains manually dispatched before merge.

## Packaging and compatibility

`titan.test` is the eighteenth ordinary logical module in the combined
`titan.so`/`titan.a` pair, yielding nineteen `luaopen_*` entries including bare
support. Its generated Lua shim is published with the other seventeen. The
canonical private source is a compiler-data artifact, not another run-time
module and not a LuaRocks manifest C module. `stdlib_installer.lua` validates,
backs up, commits, and rolls it back in the same recoverable transaction before
renaming `titan.so` last.

The addition did not change an existing native calling convention, module
state layout, or serialized schema, so it was published within ABI 0.22. During
that release only, the immediately preceding canonical seventeen-key 0.22 pair
was a bounded publication predecessor. ABI 0.23 started clean: its publisher
accepted only its bootstrap/current state and did not treat an ABI-0.22 pair as
an active-layout predecessor or migration source. ABI 0.24 was another clean
boundary and did not treat an ABI-0.23 pair as a predecessor or migration
source. ABI 0.25 likewise did not treat an ABI-0.24 pair as a predecessor or
migration source, and ABI 0.26 does not treat an ABI-0.25 pair as one.
