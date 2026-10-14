# Native test runner implementation

Opt-in [native source coverage](native-coverage.md) uses this same discovery,
build/run split, and executable. Production object instrumentation, source
attribution, counters, and reporting belong to the compiler and host tool;
the generated runner does not depend on gcovr or perform collection itself.

Titan's test infrastructure has three ordinary pieces:

1. `titan/test.titan`, the ordinary standard module containing the public
   test API and its execution, filtering, and reporting implementation;
2. `titan-compiler/test_runner.lua`, which discovers checked test functions and
   renders a synthetic Titan module; and
3. the `titanc --test` orchestration in `titanc` and `driver.lua`.

There is no test AST node, special code-generator lowering, runner C runtime,
registry identity trick, or second compiler pipeline. The synthetic runner is
checked, generated, compiled, linked, and initialized as an ordinary logical
module.

## Resolution and the ordinary standard provider

A test invocation creates a resolver context with `source_first = true`.
For every ordinary non-root dependency, `defaultloader` first asks the tagged
folder/flat source resolver. A found source or blocked constituent is terminal;
only a clean miss enters the existing complete `.so`/`.a` format passes, in the
order selected by `prefer_static`. Explicit roots remain source-required.
Ordinary resolver contexts retain their binary-first behavior. This preference
changes selection only: a written `.titan` import remains the only dependency
edge that is source-required and collaboration-capable.

`titan.test` follows this ordinary resolution policy. The compiler neither
substitutes its source nor creates a separate support translation unit. An
installed SDK provides it through the same compiled standard provider selected
for other imports. A static test link therefore retains the standard archive
without the artificial source overlap formerly created by a support override.
Actual authored source overlaps retain the general whole-provider composition
checks; test mode does not weaken those checks.

The CLI's `source_overrides` supplies only generated `titan.test.runner`
contents. Its descriptor carries `files`, an in-memory `contents` map, and the
usual `program_output`; parsing and checking use the ordinary source pipeline.
The runner imports `titan.test` publicly, so it has no source-private privilege.
No test-support source is installed with the SDK or copied into a test build.

Ordinary production module code generation is independent of `--test`.
Production objects can be shared by application and test executables when flags
and resolved providers match. Direct private imports from tests affect consumer
visibility, while the producer already contains its source collaboration
surface. Make still owns dependency and configuration invalidation; coverage,
optimization, or provider changes can require separate objects.

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

`titan-compiler/test_runner.lua` renders a thin module with:

* an ordinary public import of `titan.test`;
* one ordinary import alias per distinct test owner;
* one exact `function (test.Context): ()` wrapper per case, discarding results;
* an Array of public `test.Case.new(full_name, owner_module, body)` descriptors;
  and
* `main(args)`, which returns `test.run(args, cases)`.

The reserved logical name `titan.test.runner` is absent from the standard
provider. Test owners remain subject to ordinary import and native-symbol
naming. A bare owner rewritten by standard-library shorthand is rejected
because generated source has no exact import spelling for it; a bare name such
as `math` would instead collide with Lua's `luaopen_math`. The documented
`*_test`/`*_spec` convention avoids those existing module constraints.

The generated descriptor is named `<first-program-output>__test_runner.titan`;
the ordinary coder produces the adjacent `.c/.o`. `compile_program` receives
an explicit `__test_entrypoint.c` path and links the same standalone objects,
selected standard providers, runtime archive, and `-X` payload order as any
other main. The first requested root's `program_output` owns the executable,
including the folder `__main` convention. Input application mains do not
participate in main selection under `--test`.

`-c --test` performs discovery so actual test-owner objects retain their C
flags, then stops before generating the runner or linking. An incremental final
test invocation discovers current cases from source or object metadata,
generates a fresh runner and entrypoint, and reuses eligible source objects.
Make owns invalidation when cases, imports, compiler settings, or headers change.

Before emitting C, `validate_program_output_paths` checks every source,
runner, entrypoint, executable, and Darwin dSYM destination in both normalized
and physical-parent form. It rejects aliases, ancestor/descendant conflicts,
symlink leaves, and leaves of the wrong kind. Generated-parent creation never
replaces an occupied path.

`driver.compile` accepts an invocation-local `extra_compile_flags` list.
`titanc` adds `-fno-optimize-sibling-calls` only for discovery-owner modules.
The standard provider, runner, entrypoint, production dependencies, and probes
retain their normal flags. There is no invocation-wide test codegen mode.

## `titan.test` execution API and private state

The public module serializes `testing`, `verbose`, `location`, `skip`, `assert`,
`run`, the nominal `Case` and `Case.new`, the nominal `Skip` with readonly
`reason`, and `Context` with its four methods. `Case` fields, `Context` fields,
`RegisteredTest`, callback aliases, execution state, and all `runner_*` helpers
remain local. The standard module's own execution code uses:

* `runner_begin` / `runner_end` for module-local active and verbose state and
  the standard module's reporting callback;
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
attempted without retaining a completed closure. `runner_begin` installs the
standard module's reporting callback. `Context:log` supplies the context's full
name and message for a decorated, flushed line. Public `run` parses its arguments
before activating the state, rejects an already active run, and defers state
reset around execution. The generated `main` calls it after module
initialization, so `testing()` stays false in imported initializers.

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

`titan.test` imports `lua.h`, `lauxlib.h`, `titan/ffi.h`, `stdio.h`, and
`string.h`, and no Titan standard modules. A guarded
final initializer compiles one fixed Lua chunk with callable `luaL_loadstring`
and `lua_pcallk`; the function-like `luaL_dostring` macro is intentionally not
available through the FFI. In a normal standalone, `luaL_openlibs` has already
run, so this snapshots the helpers before any test-owner initializer. A bare
validation state may not have opened the standard libraries; the initializer
first checks for the required Lua callables and defers loading when they are
absent. The first later trace or pattern operation then loads the helpers.
The chunk snapshots the required base/string callables into locals before it
returns two traced closures:

* a raw-trace scanner using the captured `string.gmatch`/`string.match`; and
* a Lua-pattern predicate using the captured `string.find`.

Capturing at `titan.test` initialization keeps those helpers valid even when a
test owner has a logical name such as `math` and replaces the corresponding Lua
global during standalone initialization. The helper saves the Lua top, reserves
stack space, converts returned closures to traced Titan function values, and
restores the stack through `defer`.
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

`TITAN_BUILD_PROFILE` is selected before Make expands native flags or
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
libtitan, libbacktrace and bundled libuv/llhttp/SQLite/OpenSSL. Lua and
its native compiler dependencies (LPegLabel and Lua filesystem), plus private
LPegLabel, stay at O2/no LTO so compiler and test execution remains optimized.
Sanitizer Lua/parser dependencies use O1/no LTO with complete instrumentation;
Titan payloads retain O0/no LTO. The Titan rock receives separate O0 runtime
flags while ordinary Lua dependencies use stock LuaRocks defaults. Sanitizer CI
explicitly installs LPegLabel and Lua filesystem with instrumented host flags
before the Titan rock. Lua/LuaRocks bootstrap targets check installed program
existence only; their source/configuration rebuilds remain caller-owned.
Parser-specific flags follow generic Titan extras. The SDK records its profile
in `etc/titan/build-profile`. Ordinary native builds use source/header
prerequisites; callers clean their output directories after changing build flags
or toolchains. `make clean-stdlib` clears the paired provider and module outputs.

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

The shared `spec/support/stdlib_test_modules.mk` manifest names 28 module-owned
roots under `spec/stdlib/titan/`, used by Linux, macOS, and native Windows.
The same reviewed inventory names their test/helper compilation units, folder
contributors, and direct source imports. On Unix, Make schedules per-module
`-c --test --incremental` commands after their source dependencies. Every
command runs from `.titan-tests/` with the same absolute source tree and flags,
and depends on the installed standard provider. No separate `titan.test`
support object is compiled.

One final Unix `--test --incremental --no-uv-bootstrap` invocation keeps all 28
roots explicit and discovers the complete source/object closure. The designated
first root, `test.tests`, owns `.titan-tests/test/tests`; the current synthetic
runner, entrypoint, and Darwin dSYM are also owned there. Ordinary module
objects/C/headers remain beside their sources. Make owns their source-import,
private-header, installed-provider, compiler/SDK, and configuration prerequisites.
Native fixture objects and the host child executable are separate targets.
A no-op `titan-stdlib-test-build` invokes neither the compiler nor the linker.

`make titan-stdlib-test-run` returns to the repository root before executing,
because several fixtures use repository-relative paths. `TITAN_FILTER` supplies
one Lua pattern to this already built executable; it never changes the 28-root
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
`TITAN_TEST_TIMEOUT=600` covers all 28 test roots, including repeated fresh
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

`Makefile.win` provides the same build/run leaf targets through
`spec/support/windows_stdlib_tests.sh`. It compiles every root serially with the
native CLANG64/UCRT SDK in a marked, disposable local NTFS workspace. The
workspace contains a private SDK copy, test sources, authored child fixtures,
generated objects, logs, and scratch paths. Windows retains its Job Object
supervisor: descendants enter the private job before execution and are killed
when supervision ends. PowerShell drains both output pipes concurrently and
preserves the complete native exit status. The aggregate still uses
`--no-uv-bootstrap`; fresh child tests select their own bootstrap normally.

The platform runners audit named results with
`spec/support/check_stdlib_test_output.lua`. An unfiltered run must execute every
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
- `unsupported: ` for a documented production API that Titan has not implemented
  on that platform; lack of test evidence alone does not justify this label;
- `portability: ` for an unfinished test fixture; this records the gap but
  deliberately fails a complete validation gate.

Keep the exclusion at the smallest independent assertion and cite the actual
platform or implementation limitation. Native source-frame assertions run on
Windows through libbacktrace; they must not be excluded merely because the
original port had not exercised them.
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
aggregate executable without LuaCov. Two compiler consumers partition the
complete compiler/language group with LuaCov; a separate merger publishes one
compiler report. The native coverage consumer source-links the production
stdlib into this aggregate and publishes a separate line report. The
sanitizer builds an independent ASan+UBSan aggregate once and selects focused
cases with the run target; it never restores the regular artifact. The complete
macOS pre-merge gate prefers the local VM; hosted manual dispatch is an
explicitly requested fallback.

## Packaging and compatibility

`titan.test` is an ordinary logical module in the combined
`titan.so`/`titan.a` pair. The current provider has twenty-four `luaopen_*`
entries including bare support and twenty-three generated logical-module shims.
The same compiled `titan.test` implementation serves ordinary programs and
generated test executables. Standard installation publishes the provider pair
and shims; it does not install a private test-source payload. Packaging tests
check those artifacts, while compiler regressions verify static-provider
retention and production-object reuse across application and test links.

The public `Case`, `Skip`, and `run` declarations use the existing native
calling conventions and metadata schema. Reinstall the compiler and standard
provider together when changing this API. Use a fresh installation after ABI
changes; earlier Titan installations are not migration sources.

The unfiltered Windows LuaRocks backend uses the same four compiler/language
partitions in private NTFS checkout copies after its seven retained serial specs
and native aggregate pass. It defaults to two workers and accepts
`TITAN_ROCK_TEST_JOBS=1` through `4`. The shard containing explicit compiler
parallelism tests runs without other shards active. Workers inherit private
TEMP/TMP, run installed Lua and Busted against the shared read-only SDK, and
are supervised by native Job Objects. Windows uses MSYS2's `/tmp` as a short
scratch base so nested fixture paths fit ordinary Win32 filename limits;
Unix workers retain the caller's `TMPDIR`. Busted filters or appended arguments
select the ordinary single-process route.

Both Windows Busted launchers preload `luv` before test-file isolation. The
library owns its native loop through its first module table, so that table must
stay loaded while Busted restores `package.loaded` between files. This retains
one loop for the complete invocation without changing ordinary compiler loading.
