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
For every ordinary non-root dependency, `defaultloader` first asks the tagged folder/flat
source resolver. A found source or blocked constituent is terminal; only a
clean miss enters the existing complete `.so`/`.a` format passes, in the order
selected by `prefer_static`. Explicit roots remain source-required. Ordinary
resolver contexts retain their binary-first behavior byte-for-byte. This
source-first policy changes selection only: it does not turn an ordinary import
into permission to use locals. A written `.titan` import remains the only
dependency edge that is both source-required and collaboration-capable.

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
`<root>/share/titan/0.6/src/titan/test.titan`; a missing/nonregular file is an
explicit test-mode diagnostic. The generated runner writes
`import "titan.test.titan"`; that written opt-in plus this trusted source result
grants access to private declarations. Binary metadata and ordinary source
imports remain public-only.

Generated descriptors carry `files`, an in-memory `contents` map, the usual
`program_output`, and optionally a separate `native_output`. `parse_source`
still parses every listed filename independently and calls the checker once.
`native_output` changes only the generated C/object destination; logical
identity, diagnostic locations, and source provenance remain untouched. The
support translation unit is therefore emitted as
`<program>__test_support.c/.o` rather than modifying the installed or checkout
source tree.

In separate (`-c --test`) or incremental test mode, the CLI assigns
`titan/test__test_support.titan` as the support's `native_output` before loading
any roots. Commands in the same build directory therefore share one support
object regardless of requested-root order. Its canonical source filename and
source-private provider identity remain unchanged. Default `--test` keeps the
historical per-program output above.

## Source discovery

After requested roots and their source closures check, `test_runner.discover`
walks only source-backed entries in the union of those closures. A candidate is
a surviving nonlocal `Ast.TopLevelFunc`, begins with `test_`, has one fixed
parameter and no `varargtype`, and normalizes that parameter with
`types.normalize` to `Type.Nominal("titan.test.Context")`. Results are not
restricted because the generated wrapper calls the function as a statement.

Source module names and then full case names are sorted with
`util.bytewise_less`; discovery never depends on `pairs` order. It returns both
the case descriptors and the exact owner-module set used for compilation
flags. Generated source-object metadata retains the `function_names` result;
an object-backed source entry exposes it as `test_functions` for the same
discovery traversal without an AST. Binary providers are never discovered,
even when a static provider physically carries other logical keys.

## Synthetic source and native outputs

`titan-compiler/test_runner.lua` hydrates fixed source text with:

* one deterministic ordinary import alias per distinct owner;
* one explicit `import "titan.test.titan"` alias for the private protocol;
* one exact `function (test.Context): ()` wrapper per case, which discards any result;
* `TestCase` registration statements; and
* the fixed runner implementation and `main`.

The logical name `titan.test.runner` is reserved in test mode and never appears
in the standard provider. Test owners remain subject to ordinary import and
native-symbol naming. A bare owner rewritten by standard-library shorthand is
rejected before runner checking because generated source has no exact import
spelling for it; a bare name such as `math` would instead collide with Lua's
`luaopen_math`. The documented `*_test`/`*_spec` convention avoids those
pre-existing module constraints. The runner ordinarily imports every accepted
test owner because discovered test functions are public, and explicitly imports
`titan.test.titan` for its private protocol. The source descriptor is
named `<first-program-output>__test_runner.titan`; the ordinary coder produces
the adjacent `.c/.o`. `compile_program` receives an explicit
`__test_entrypoint.c` path and links the same standalone objects, selected
static providers, runtime archive, and `-X` payload order as any other main.
The first requested root's `program_output` owns the executable, including the
folder `__main` convention. Input application mains do not participate in main
selection under `--test`.

`-c --test` performs discovery so owner objects retain their test-only C flags,
but stops before creating the synthetic runner, selecting the executable, or
linking. An incremental final test invocation discovers all current cases and
always generates a fresh runner and entrypoint; source/support object hits skip
their normal compiler phases. Make owns invalidation when cases, imports,
compiler settings, or headers change.


For executable test builds, before emitting any C,
`validate_program_output_paths` checks every source,
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
are local. The explicit-source runner uses:

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

## Validation profile and isolated SDKs

`TITAN_BUILD_PROFILE` is selected before Make expands configuration stamps or
installed SDK paths. Ordinary targets and unset compiler invocations use
`production`; repository test entry points and the Busted/CI wrappers default
to `validation`. An implicit validation installation uses `.lua-validation`,
separate from the discovered active-PATH prefix. Existing ordinary prefix
discovery remains caller-owned; use matching profile/prefix settings rather
than republishing another profile into an active SDK. `make test` prepares and
reinstalls the selected installation; a cold `rock-test` re-enters through that
complete preparation so runtime/header paths are expanded after installation.
Leaf native targets require a prepared matching prefix.

Validation sets generated-C and link defaults to `-O0 -fno-lto`, including
libtitan, libbacktrace and bundled Readline/libuv/llhttp/SQLite/OpenSSL. Lua and
its native compiler dependencies (LPegLabel and Lua filesystem), plus private
LPegLabel, stay at O2/no LTO so compiler and test execution remains optimized.
Sanitizer Lua/parser dependencies use O1/no LTO with complete instrumentation;
Titan payloads retain O0/no LTO. Generic LuaRocks CFLAGS remain O0, while
`make luarocks` separately reconciles compiler dependencies with scoped host
compile/link flags. Its receipt hashes installed modules, versions and Lua/tool
inputs, replacing stale same-version modules and preserving warm builds.
Parser-specific flags follow generic Titan extras. The SDK records its profile
in `etc/titan/build-profile`, and configuration stamps include effective flags.

The test environment reaches Busted workers, the aggregate executable and its
fresh child compilers. Direct coder Busted fixtures also prepend cheap C/link
flags through `spec.support.helpers` when no profile was explicitly selected.
The small `spec/coder/lto_spec.lua` smoke clears the inherited profile and all
cheap overrides, compiling and running cross-module providers and source-free
consumers with the ordinary unset O3/fat-LTO defaults. Make's flag regression
separately checks production/validation, platform defaults and explicit flags.
The small fat-object metadata reader, foreign prototype diagnostics, nominal
array-boundary diagnostics and `setjmp`/`longjmp` value-survival fixtures retain
their explicit optimization levels because optimization is part of their oracle.
Benchmark scripts keep the profiles recorded by their measurements.

Production and validation prefixes are independent; source-adjacent generated
objects still belong to one checkout. Serialize profile rebuilds or use private
source copies. Linux and manually dispatched macOS CI prepare validation trees,
include the profile in native/rock/probe cache keys, and share only their
selected read-only SDK with isolated compiler workers. These internal test
artifacts do not change normal installed production defaults.

## Repository dogfooding

The shared `spec/support/stdlib_test_modules.mk` manifest names 27 module-owned
roots under `spec/stdlib/titan/`, used by Linux, macOS, and native Windows.
The same reviewed inventory names their test/helper compilation units, folder
contributors, and direct source imports. On Unix, Make compiles shared
`titan.test` support once with
`-c --test --incremental titan.test`, then schedules per-module
`-c --test --incremental` commands after their source dependencies. Every
command runs from `.titan-tests/` with the same absolute source tree and flags.
The shared support output is `titan/test__test_support.o` within that directory.

One final Unix `--test --incremental --no-uv-bootstrap` invocation keeps all 27
roots explicit and discovers the complete source/object closure. The designated
first root, `test.tests`, owns `.titan-tests/test/tests`; the current synthetic
runner, entrypoint, and Darwin dSYM are also owned there. Ordinary module
objects/C/headers remain beside their sources. Make owns their source-import,
private-header, installed-provider, compiler/SDK, and configuration prerequisites.
Native fixture objects and the host child executable are separate targets.
A no-op `titan-stdlib-test-build` invokes neither the compiler nor the linker.

`make titan-stdlib-test-run` returns to the repository root before executing,
because several fixtures use repository-relative paths. `TITAN_FILTER` supplies
one Lua pattern to this already built executable; it never changes the 27-root
compile. `make titan-stdlib-test` composes build and run, while the split leaf
targets let sanitizer and focused development runs reuse one build in multiple
fresh processes. `BUSTED_FILTER` is independent and belongs to
`busted-test`; `rock-test` enters both domains without inventing native group
names.

The explicit repository-root command
`TITAN_ROCKS_ROOT="$PREFIX" TITAN_PROBE_CACHE_DISABLE=1 busted --run=checkout`
uses the `.busted` `checkout` profile to prepend `./?.lua;./?/init.lua` after
the LuaRocks launcher initializes its paths. It loads edited checkout Lua
compiler modules without reinstalling them; an ambient `LUA_PATH` override
alone does not have that precedence. The profile leaves the C module path
unchanged. The existing `TITAN_ROCKS_ROOT` option separately preserves installed
driver layout, headers, and runtime-library inputs. Keep that root override
scoped to the focused invocation.

The profile runs Busted's standard helper
`spec/support/checkout_busted.lua` before loading specs. It requires the root
option, creates one existing resolver context to initialize driver layout,
calls `driver.configure_foreign_c` so direct checker FFI imports use the same
installed SDK, and closes the context. It changes no compiler loader or
source-identity mechanism.

The real-launcher regression in `spec/libuv_build_spec.lua` compares a
deliberate checkout compiler edit with the unchanged installed module. It
proves default Busted stays installed even with `.busted` present, compares
active native dependency/SDK paths in a recognizable source checkout, and
checks an installed `lua.h` import through the direct checker with no checkout
Lua headers. It also requires a missing root option and a broken local module
to fail rather than silently change layout or fall back to the install.

Default Busted, `make busted-test`, and `luarocks test` continue to use the
installed compiler; reinstall compiler edits before those commands or an
installed `titanc` invocation. Compiler workers still own private checkout and
temporary directories. The profile does not refresh installed tools, the
SDK/provider, or a compiled native aggregate. Reinstall after runtime or
standard-library changes as well. `make test` remains the canonical full gate
because it reinstalls the current compiler and provider before testing;
`luarocks test` does not.

`run_with_timeout.sh` uses Bash monitor mode to give the executable its own
process group and polls it at a coarse interval. Make's default
`TITAN_TEST_TIMEOUT=600` covers all 27 test roots, including repeated fresh
child-fixture compilation under the selected profile. Explicit overrides, including the
15-second CI shutdown check, remain independent of that default. At the deadline it sends
`TERM`, then `KILL` after a short grace period, maps the timeout to status 124,
and otherwise preserves the child's status. Make streams combined
stdout/stderr through a pipe rather than redirecting either stream to a regular
file, preserving the parent-pipe boundary tested by OS/stdio cases. Expected
uncaught Task diagnostics are owned by their Titan tests: a case emits flushed
`Context:log` messages containing `BEGIN expected uncaught async Task
diagnostics` and `END expected uncaught async Task diagnostics` around the
operation. Those prefixed brackets make a successful aggregate log readable
and keep the expectation owned by the case that produces it.

### Platform portability and complete execution

`Makefile.windows.stdlib` provides the same build/run leaf targets through
`scripts/windows_stdlib_tests.sh`. It compiles every root serially with the
native CLANG64/UCRT SDK in a marked, disposable local NTFS workspace. The
workspace contains a private SDK copy, test sources, authored child fixtures,
generated objects, logs, and scratch paths. Windows retains its Job Object
supervisor: descendants enter the private job before execution and are killed
when supervision ends. PowerShell drains both output pipes concurrently and
preserves the complete native exit status. The aggregate still uses
`--no-uv-bootstrap`; fresh child tests select their own bootstrap normally.

The platform runners audit named results with
`scripts/check_stdlib_test_output.lua`. An unfiltered run must execute every
manifest owner, and named terminal results must match the runner's summary.
Empty selections, duplicate results, unclassified skips, unfinished cases,
and unfinished fixture portability fail the gate. A filter affects execution
only and reports the number of owners it actually selected.

Repository skips use one of these reason prefixes (the public `test.skip` API
continues to accept arbitrary reasons):

- `platform: ` for semantics belonging to another operating system, such as
  POSIX user signals, Unix-domain stdio sockets, or Windows DWORD exit codes;
- `capability: ` for a probed environment limitation, such as an unavailable
  locale or Windows symbolic-link privilege;
- `unsupported: ` for a production API limitation, such as Windows native
  source-frame attribution;
- `portability: ` for an unfinished test fixture; this records the gap but
  deliberately fails a complete validation gate.

Keep the exclusion at the smallest independent assertion. An unsupported
symbolic traceback frame must not skip the surrounding bootstrap behavior.
Port compile-time and link-time dependencies before adding runtime conditions:
every root and its native fixtures must compile on every platform. The async
foreign-work and SQLite fixtures use Windows synchronization or POSIX
counterparts; print capture and inherited stdio retain binary pipes on Windows.
`support.command` invokes the compiler's existing argv-aware platform transport
for compiler/Lua children, environment overrides, capture, and cleanup. Shell
syntax appears only in cases testing the shell-command API itself.

Filesystem, SQLite, and local watcher cases run on local NTFS in Windows.
Shared-folder notification behavior cannot satisfy or replace those assertions.
Validation evidence records source identity, OS and architecture, SDK/compiler
and provider settings, selected/passed/skipped/failed counts, and every skip
reason. An Intel macOS run does not establish Apple Silicon behavior.

Builds retain their reusable outputs; explicit `make clean` performs generic
cleanup within a narrow ownership boundary. `.titan-tests/` is a
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

`titan.test` is an ordinary logical module in the combined
`titan.so`/`titan.a` pair, yielding twenty-three `luaopen_*` entries including bare
support. Its generated Lua shim is published with the other twenty-one. The
canonical private source is a compiler-data artifact, not another run-time
module and not a LuaRocks manifest C module. `stdlib_installer.lua` validates,
backs up, commits, and rolls it back in the same recoverable transaction before
renaming `titan.so` last.

The addition did not change an existing native calling convention, module
state layout, or serialized schema. The current publisher accepts only its
bootstrap or complete current state; earlier Titan installations are not
active-layout predecessors or migration sources.
