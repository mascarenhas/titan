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
for other imports, so a static test link retains the standard archive without
any source overlap. Actual authored source overlaps retain the general
whole-provider composition checks; test mode does not weaken those checks.

The CLI's `source_overrides` supplies only generated `titan.test.runner`
contents. Its descriptor carries `files`, an in-memory `contents` map, and the
usual `program_output`; parsing and checking use the ordinary source pipeline.
The runner imports `titan.test` publicly. Its discovered test owners use
explicit `.titan` imports, preserving the already-checked source provenance and
inheriting the real C headers needed to reconstruct their exported native
fields. Discovery never supplies binary owners to this source-only path.
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
flags. Generated source-object metadata records `test_runner.function_names`
as `test_functions`, so an object-backed source entry supports the same
discovery traversal without an AST. Binary providers are never discovered,
even when a static provider physically carries other logical keys.

## Synthetic source and native outputs

`titan-compiler/test_runner.lua` renders a thin module with:

* an ordinary public import of `titan.test`;
* one explicit `.titan` import alias per distinct source-backed test owner;
* one exact `function (test.Context): ()` wrapper per case, discarding results;
* private registration helpers, each appending at most 64 public
  `test.Case.new(full_name, owner_module, body)` descriptors to one Array; and
* `main(args)`, which returns `test.run(args, cases)`.

`main` owns the descriptor Array and calls the registration helpers in case
order before entering `test.run`. Bounding each registration function keeps
native compiler temporary and root state small, especially under sanitizers.
The helpers reuse the exact callback wrappers and return before execution;
discovery, case order, and the public test API are unchanged. Empty suites
need no registration helper.

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

With `--output`, program stems and generated companions are mapped below the
selected directory; source identity and test discovery remain unchanged.
Without it, the original placement rules still apply. See
[output-directory routing](output-directory.md).

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
`titanc` passes `test_runner.TEST_COMPILE_FLAGS`
(`-fno-optimize-sibling-calls`) only for discovery-owner modules. The standard
provider, runner, entrypoint, production dependencies, and probes retain their
normal flags. There is no invocation-wide test codegen mode.

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

Profile selection, prefixes and command ownership are in [repository
workflow](repository-workflow.md#choose-the-matching-profile-and-command); the
per-component optimization policy is in [build
profiles](../language/build-profiles.md). The test harness adds these flag
rules:

- The native aggregate and its fresh child compilers receive the profile's
  native flags followed by `TITAN_EXTRA_*FLAGS` when set, otherwise
  `TITAN_TEST_EXTRA_*FLAGS` (`Makefile` `TITAN_TEST_CFLAGS` and
  `TITAN_TEST_COMPILER_ENV`). The same environment reaches Busted workers.
- When no `TITAN_BUILD_PROFILE` is set, `spec/support/helpers.lua` prepends
  `-O0 -fno-lto` to the driver's extra compile and link flags for direct coder
  fixtures.
- `spec/coder/lto_spec.lua` clears the inherited profile and cheap overrides for
  its subprocess, compiling and running cross-module providers and source-free
  consumers with the unset production defaults (O3, with fat LTO on Linux).
- The fat-object metadata reader, foreign-prototype diagnostics, nominal
  array-boundary diagnostics and `setjmp`/`longjmp` value-survival fixtures
  keep explicit optimization levels because optimization is part of their
  oracle. Make's flag regression separately checks production/validation,
  platform defaults and explicit flags. Benchmark scripts keep the profiles
  recorded by their measurements.

## Regression placement

Choose a test layer according to the behavior it proves. A large compiler
feature gets a topical spec rather than expanding the generic checker/coder
spec. All commands run from the repository root; the shared harness is
`spec/support/helpers.lua`.

| Behavior under test | Owning suite |
| --- | --- |
| Pure lexer/parser/location/symbol/type/preprocessor behavior and driver/metadata algorithms | Root `spec/*_spec.lua`; `cpp_spec.lua` drives preprocessing without the toolchain and bounds macro recursion with an instruction-count hook. |
| Typechecking, plan construction, visibility, or rejection without executing generated code | `spec/checker/`. |
| C generation, compilation, real native execution, or compiler boundary parity | `spec/coder/`. |
| Public standard-library API/runtime behavior, including fresh-process host behavior | Module-owned Titan sources in `spec/stdlib/titan/`, through the aggregate executable; no Busted wrappers or Lua library suites. |
| Native dependency builds and canonical standard-provider ownership | `spec/libuv_build_spec.lua` and `spec/rockspec_spec.lua`. |
| Production bundled/system OpenSSL static consumers | `spec/support/ci_dependency_mode_smoke.sh`. |

Keep library behavior outside LuaCov. Compilation alone does not make a
library integration a compiler test; add a small independent compiler case
when it exposes a compiler coverage gap. Fresh-process behavior belongs to
the native owner: a compiled parent can invoke a standalone fixture with
argv-aware `support.command`, receive an explicit temporary result file, and
remove it with `defer`. Authored C/H fixtures live in
`spec/fixtures/stdlib/native/`, authored Titan children in
`spec/fixtures/stdlib/titan/`. The remaining Lua async/process support is
build/production-smoke infrastructure, not a library assertion suite.

The following existing splits avoid duplicated provider/build scaffolding:

| Contract | Existing regression homes |
| --- | --- |
| Type-relation laws / checker plans / generated boundary parity | `spec/types_spec.lua`, then the topical checker/coder `type_relations_soundness_spec.lua`. |
| Union syntax / checker frontiers / generated representation / hostile metadata | Lexer/parser specs, checker/coder `unions_spec.lua`, and `spec/union_interface_spec.lua`; extend compiled-module suites for source/DSO/archive composition. |
| Folder resolution and diagnostics / public artifacts and mixed-file traces | Filesystem cases in `spec/driver_spec.lua`, then `spec/coder/folder_modules_spec.lua`. |
| Root-major metadata claims and provider lookup | `spec/driver_spec.lua`. |
| Prefix-container compilation, generated shims, promotion, paired publication, rollback, real macOS universal archives | `spec/coder/multi_module_libraries_spec.lua`, with packaging in `rockspec_spec.lua`. |
| Bounded archive/ELF/Mach-O/COFF and synthetic universal parsing | `spec/staticmetadata_spec.lua`. |
| Static format preference, occupied paths, claims, cache, source fallback | `spec/driver_spec.lua`. |
| Direct/dynamic nominal-owner constraints | `spec/checker/static_compiled_modules_spec.lua`. |
| Target derivation, `-X` classification, archive tools/construction, native archive validation | `spec/coder/static_compiled_modules_spec.lua`. |
| DSO-selected imports and serialized rehydration | `spec/coder/so_import_spec.lua` and `spec/checker/so_rehydration_spec.lua`; omit dependency source and paired archives and assert dynamic selection. |
| Dense Array capacity/hash/GC representation | `spec/dense_array_runtime_spec.lua`; language and checker behavior stays in topical compiler specs. |

Regex dogfood stays under `spec/stdlib/titan/string/regex_test.titan` outside
LuaCov. Standard-library tests must not rewrite production source, recreate
retired callback transformers or reentrant loops, inspect generated objects
to re-prove codegen, or invalidate shared Make-owned runtime/provider outputs.
Public async tests observe outcomes, cancellation, listener delivery, buffering,
and resource retirement through the current production modules. The canonical
[async runtime chapter](libuv-runtime.md) specifies the token/FIFO protocol;
HTTP deadline tests retain reader-cancel-and-join before connection/parser
teardown when the deadline wins, and timer-only cancellation when the reader wins.

## Repository dogfooding

The shared `spec/support/stdlib_test_modules.mk` manifest names 30
module-owned roots under `spec/stdlib/titan/` (`TITAN_STDLIB_TEST_ROOTS`), used
by Linux, macOS, and native Windows. The same inventory names their
test/helper compilation units, folder contributors, and direct source imports.
On Unix, Make schedules per-module `-c --test --incremental` commands after
their source dependencies. Every command runs from `TITAN_TEST_BUILD_DIR`
(default `out/tests`) with `--output .`, uses the same absolute source tree and
flags, and depends on the installed standard provider. No separate
`titan.test` support object is compiled.

One final Unix `--output . --test --incremental --no-uv-bootstrap` invocation
keeps all roots explicit and discovers the complete source/object closure. The
designated first root, `test.tests`, owns `out/tests/test/tests`; the current
synthetic runner, entrypoint, and Darwin dSYM are also owned there. Module C,
objects, and headers reproduce the test source hierarchy below `out/tests`,
leaving the source tree untouched. Make owns their source-import,
private-header, installed-provider, compiler/SDK, and configuration
prerequisites. Native fixture objects and the host child executable are
separate targets. A no-op `titan-stdlib-test-build` invokes neither the
compiler nor the linker.

`make titan-stdlib-test-run` returns to the repository root before executing,
because several fixtures use repository-relative paths. `TITAN_FILTER` supplies
one Lua pattern to this already built executable; it never changes the
compiled root set. `make titan-stdlib-test` composes build and run, while the
split leaf targets let sanitizer and focused development runs reuse one build
in multiple fresh processes. `BUSTED_FILTER` is independent and belongs to
`busted-test`; `rock-test` enters both domains without inventing native group
names. Running edited compiler Lua through Busted without reinstalling uses the
explicit [checkout profile](repository-workflow.md#run-checkout-compiler-lua-with-busted).

`run_with_timeout.sh` uses Bash monitor mode to give the executable its own
process group and polls it at a coarse interval. Make's default
`TITAN_TEST_TIMEOUT=600` covers the whole aggregate, including repeated fresh
child-fixture compilation under the selected profile. Explicit overrides,
including the 15-second CI shutdown check, are independent of that default. At
the deadline it sends `TERM`, then `KILL` after a short grace period, maps the
timeout to status 124, and otherwise preserves the child's status. Make
streams combined stdout/stderr through a pipe rather than redirecting either
stream to a regular file, preserving the parent-pipe boundary tested by
OS/stdio cases. Expected uncaught Task diagnostics are owned by their Titan
tests: a case emits flushed `Context:log` messages containing `BEGIN expected
uncaught async Task diagnostics` and `END expected uncaught async Task
diagnostics` around the operation. Those prefixed brackets make a successful
aggregate log readable and keep the expectation owned by the case that
produces it.

### Concurrent filtered runs

The Unix `Makefile` `titan-stdlib-test-run` tees the merged output to
`TITAN_TEST_RUN_LOG` (default `$(TITAN_TEST_BUILD_DIR)/stdout.log`, with
`TITAN_TEST_BUILD_DIR` defaulting to `out/tests`) and writes the root inventory
that `check_stdlib_test_output.lua` audits it against (default
`$(TITAN_TEST_BUILD_DIR)/roots.txt`; `<log>.roots` beside an explicitly
selected log). The built executable and fixture objects are only read, so
several filtered runs can share one build at once when each selects its own
log and `TMPDIR`:

```sh
mkdir -p /tmp/run-a /tmp/run-b
TMPDIR=/tmp/run-a make titan-stdlib-test-run TITAN_FILTER='^uv[.]' \
  TITAN_TEST_RUN_LOG=/tmp/run-a/stdout.log & uv_run=$!
TMPDIR=/tmp/run-b make titan-stdlib-test-run TITAN_FILTER='^protobuf[.]' \
  TITAN_TEST_RUN_LOG=/tmp/run-b/stdout.log & protobuf_run=$!
wait "$uv_run"; uv_status=$?
wait "$protobuf_run"; protobuf_status=$?
```

Each run audits only its own log and keeps its own exit status. Cases still
share the host, so timing-bound cases see more load and loopback port scans
more contention. The CI sanitizer gates stay serial
([continuous integration](continuous-integration.md#sanitizer-ownership-and-failure-diagnostics)).
`Makefile.win` does not take `TITAN_TEST_RUN_LOG`: its runner writes fixed
logs, root lists, and scratch paths inside the one workspace, so Windows runs
of one workspace must stay sequential.

### Busted partitions

`make busted-test`, `luarocks test` (the rockspec `test` command) and Windows
`rock-test` all enter `spec/support/run_rock_tests.sh`. An exact unfiltered
run, with no `BUSTED_FILTER` and no appended Busted arguments, hands every
classified spec file to `spec/support/run_parallel_compiler_tests.sh`. A Busted
filter or appended Busted argument selects the ordinary single-process route; a
Titan-only filter leaves the partitioned run enabled.

`spec/support/ci_compiler_test_groups.txt` (schema `titan-busted-timings-v2`) is
the timing dataset. Its header records host, profile, date, and compiler; each
row names one discovered `spec/**/*_spec.lua` file, its domain, its measured
local validation seconds, and optional Linux CI covered seconds (`-` falls back
to the local value). The `retained` domain is the runtime/packaging set
(`Makefile` `STDLIB_BUSTED_TESTS`, `Makefile.win`
`TITAN_ROCK_TEST_STDLIB_SPECS`), `stdlib` is
`spec/support/ci_stdlib_compiler_test_files.txt`, and everything else is
`compiler`. `spec/support/compiler_test_groups.lua` validates the complete
classified union: a missing, stale, duplicate, or cross-domain row, or an
unlisted `#stress` file, fails before any test starts. It plans any positive
worker count with deterministic longest-processing-time assignment (heaviest
file first, ties by path, to the least-loaded worker); each worker runs its
files in path order. No shard identity is stored. Add a measured row with every
new spec file and remeasure rows when costs change materially.

`EXCLUSIVE_SPECS` names the genuinely exclusive files:
`spec/coder/parallel_compilation_spec.lua` and `spec/coder/jobserver_spec.lua`
count overlapping real compiler processes against their own caps, drive real
parent Make jobservers, or install process-global signal guards. They run
alone in their own checkout copy after every ordinary worker and any
overlapped native build have finished, with `MAKEFLAGS`, `MFLAGS`,
`MAKELEVEL`, and `TITAN_JOBS` unset so each test sets its own caps; `titanc`
would read an inherited `-j1` as a serial Make job policy. Every other file,
including the retained and stdlib-compiler specs, is scheduled per file; there
is no serial prefix. Those files write only their own checkout (for example
`libuv-build/` or checkout-root fixtures) or private temporary SDK and staging
trees, so all workers share the installed SDK read-only.

`TITAN_ROCK_TEST_JOBS` (any positive integer) sets the number of ordinary
workers, capped at the number of ordinary files. It defaults to four, or to
three when the native build shares the pool (Unix `rock-test`): a fourth
worker would wait for a slot while the build holds one. Measured on a 24-thread
Linux host with a cold native build, `rock-test` took 492 s with three workers
and 560 s with four, while `busted-test` alone took 300 s with four and 324 s
with three. Each worker owns a private copy of the prepared checkout,
`TMPDIR`, ccache scratch, and tagged log. It runs one Busted process per file
with `MAKEFLAGS=-j1` and
`TITAN_JOBS=1`, removes checkout-root generated artifacts between files,
records one PASS or FAIL row per file, and continues after a failed file.
`TITAN_SOURCE_GIT_ROOT` lets `rockspec_spec.lua` read the real checkout's Git
inventory from its `.git`-less copy. The copies come from one snapshot of the
prepared checkout that omits `.git`, `libbacktrace/.git`, `.lua`, and the
selected `PREFIX` when that directory resolves inside the checkout. Tar reads
exclusions as patterns, so a prefix whose checkout-relative name contains `*`,
`?`, `[`, or a backslash is copied instead. Unix workers base their scratch on
the caller's `TMPDIR`; Windows workers also get private TEMP/TMP below MSYS2's
short `/tmp`, so nested fixture paths fit ordinary Win32 filename limits, and
run under the native Job Object supervisor.

On Unix the ordinary workers are the targets of an ephemeral GNU Make
3.81-compatible work graph with ASCII phony names, run with `-k` so every
worker drains after a failure. The workers share one job pool with the
optional native-aggregate build target. The launcher joins an inherited usable
jobserver; otherwise it keeps an explicit `-j` word from `MAKEFLAGS`, including
`-j1`; otherwise it seeds a fresh pool of `TITAN_JOBS` slots. The Makefile
passes its four-slot default, except on GNU Make before 4.2, which cannot show
`make -j1` ([Make job pool](build-script-audit.md#make-job-pool-and-titanc-recipes)):
there it passes no `TITAN_JOBS` unless the user set one, and the launcher
sizes the pool with one slot per worker plus one for the native build.
Each Busted worker holds one slot. The native build target is ordered first;
its `titan-stdlib-test-build` sub-make and `titanc` processes borrow the
remaining slots. A four-slot budget therefore runs four units in total, not
four Busted workers plus four compilers, and `TITAN_JOBS=8` alone never widens
an inherited four-slot pool. On Windows the launcher keeps its FIFO scheduler:
the exclusive shard runs first and alone, then the ordinary shards share
`TITAN_ROCK_TEST_JOBS` slots, so the exclusive files' explicit native job
bounds never multiply with another active shard.

At the end the launcher requires exactly one result row for every planned
file, prints `Per-file Busted summary: passed=... failed=... total=...` and one
`FAILED spec file:` line per failure, and exits nonzero if any file, worker, or
required row failed. HUP, INT, and TERM terminate the work graph, the native
build, and every worker's process group, killing TERM-ignoring descendants
after a short grace period, then remove the scratch tree. Local workers collect
no LuaCov and never upload coverage.

On Unix `rock-test` runs that partitioned Busted phase with the native
aggregate build overlapped inside its pool, then the native phase:
`titan-stdlib-test-run-parallel`, or the focused `titan-stdlib-test-run` leaf
when `TITAN_FILTER` is set. The native run starts only after every Busted
worker and the build have finished. A Busted failure does not suppress the
native phase, a failed native build skips only the native run, and the target
fails when either phase failed. A focused Busted run builds the aggregate
afterwards instead. On Windows `rock-test` builds and runs the native aggregate
first, then the Busted phase, and likewise reports both statuses. Both Windows
Busted launchers (`run_rock_tests.sh` and the worker launcher in
`run_parallel_compiler_tests.sh`) preload `luv` before Busted's per-file
isolation. The library owns its native loop through its first module table, so
that table must stay loaded while Busted restores `package.loaded` between
files.

### Parallel native aggregate runs

`make titan-stdlib-test-run-parallel` runs one complete prebuilt aggregate as
owner groups through `spec/support/run_parallel_stdlib_tests.sh`. The plan
derives from `TITAN_STDLIB_TEST_ROOTS` through `make -f
spec/support/stdlib_test_modules.mk print-stdlib-test-owner-schedule`. That
manifest annotates owners with measured validation durations
(`TITAN_STDLIB_TEST_SECONDS_<owner>`; an unlisted owner counts one second) and
timing guards (`TITAN_STDLIB_TEST_GUARD_<owner> := 1`). Ordinary owners are
assigned by the same longest-processing-time rule to `TITAN_TEST_JOBS` groups
(default four, any positive integer; one is serial). Each group executes the
same binary from the repository root with one `--filter=^<owner>[.]test_` per
owner (Lua patterns, never regex alternation), its own `TMPDIR` and
`TITAN_TEST_ROOT`, its own log and process group, and the `TITAN_TEST_TIMEOUT`
supervisor. A failing group does not stop the others. A group's status is the
supervised executable's exit status (124 after a timeout), never that of the
log pipeline, so a nonzero exit after a complete passing report still fails
the run. The `fs.tests` workspaces and `uv.public_tests` filesystem scratch
live below `TITAN_TEST_ROOT`, or the platform temporary directory when a run
sets none, so the launcher's removal of its scratch tree also covers them.

The guarded owners then run alone in one group, with no other group, Busted
worker, or native build running. They are `timer.tests` (millisecond ticker
cadence), `net.tests` (short transfer windows), `ssl.tests` (bounded
backpressure turns), `http.tests` (30–200 ms TLS and idle deadlines),
`websocket.tests` (continuous backpressure duration and read-step deadlines),
and `os.tests` (wall-clock comparisons). `async.tests`, `thread.tests`, and
`uv.runtime_tests` use phase barriers or multi-second safety deadlines and stay
ordinary; the 15-second runtime-shutdown oracle keeps its explicit filtered CI
step. Deadlines, retries, and case selection are unchanged.

`check_stdlib_test_output.lua --union` audits every group's log as an
unfiltered run of its planned owners, then the union: every root planned
exactly once, no case reported by two groups, all selected cases terminal,
classified skips only, and consistent totals. The concatenated group logs
become `TITAN_TEST_RUN_LOG` and the root inventory `TITAN_TEST_RUN_ROOTS`. The
target rejects `TITAN_FILTER`; `titan-stdlib-test-run` remains the focused
single-invocation leaf, and `make titan-stdlib-test` builds and then runs the
parallel target unless `TITAN_FILTER` is set. Native coverage
(`titan-native-coverage-run`), the CI sanitizer gates, and Windows keep serial
aggregate runs because they share coverage counters, timing ownership, or one
workspace.

### Platform portability and complete execution

`Makefile.win` provides the same build/run leaf targets through
`spec/support/windows_stdlib_tests.sh`. It compiles every root, with up to
`TITAN_JOBS` (default four) concurrent generated-C object compilations, using the
native CLANG64/UCRT SDK in a marked, disposable local NTFS workspace. The
workspace contains a private SDK copy, test sources, authored child fixtures,
generated objects, logs, and scratch paths. Test sources retain their
`source/spec/stdlib/titan/` paths. The authoritative transfer and protobuf native
headers are copied under `source/titan/`, preserving authored relative imports
without exporting private collaboration headers through the SDK.
Windows retains its Job Object
supervisor: descendants enter the private job before execution and are killed
when supervision ends. PowerShell drains both output pipes concurrently and
reads the complete Windows exit status, which can exceed 255. It prints that
status and exits 1 for any nonzero value, because Bash keeps only eight exit
bits and a native status such as 256 would otherwise read as success. The
aggregate still uses `--no-uv-bootstrap`; fresh child tests select their own
bootstrap normally.

The same width difference applies inside the suite. A POSIX process exit
status carries only eight bits, so `os.process_tests` skips its above-255 exit
cases off Windows with a `platform:` reason, while `support.command` keeps the
complete 32-bit Windows status (`code & 0xffffffff`) rather than treating high
bits as POSIX signals.

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

Builds retain their reusable outputs; explicit `make clean` removes the
selected `TITAN_OUTPUT_DIR` (default `out/`) as a Make-owned tree. The test
cleanup helper (`spec/support/clean_generated_test_artifacts.sh`) prunes `out/`
while inspecting synthetic fixtures and, unless `--keep-output` is selected,
removes the owned `out/tests` and legacy `.titan-tests` directories
recursively. Under `spec/`, legacy compiler outputs still use the bounded
cleanup rules: remove every generated `.o`, and a primary `.c` only when a
same-stem `.titan` source exists. Split-module outputs, below `spec/` and at
the repository root, are removed only through a `<stem>.parts` companion whose
every line matches `driver.render_parts_companion` exactly; the helper builds
each deleted path from the companion's own stem, never from its contents, and
a malformed companion deletes nothing. A failed split compile removes its
companion but keeps the part C files and private header, so for a
`.titan`-backed stem below `spec/` with no companion the helper removes only
`<stem>.part<k>.c`/`.o` with a positive decimal `k` and a `<stem>.priv.h` whose
first line is `coder.PRIVATE_HEADER_MARKER`. Generated headers require their
exact compiler banner; synthetic test suffixes and root `test_runner_*`
identify other owned fixtures. This does not consult Git, so it also works in
a source rock while preserving author-written C/header fixtures and the
ordinary `out/` provider stage. Outside `spec/`, `make clean` removes every C
file, object, `.parts` companion, `.priv.h` header, and nonzero part C file
and object that a compilation without `--output` leaves beside root, `titan/`,
and `titan/uv/` modules or beside a standard folder module's main stem
(`TITAN_LEGACY_SOURCE_OUTPUTS`), keeping authored sources and headers.

CI runs this aggregate twice: once source-linked with native coverage in the
`native-coverage` job, and once as an independent ASan+UBSan build in the
`sanitizer` job, which selects focused cases with the run target. See
[continuous integration](continuous-integration.md) for the lanes.

## Packaging and compatibility

`titan.test` is an ordinary logical module in the combined
`titan.so`/`titan.a` pair (see the [standard-library
image](multi-module-libraries.md#reserved-titan-and-the-standard-library-image)).
The same compiled `titan.test` implementation serves ordinary programs and
generated test executables. Standard installation publishes the provider pair
and shims; it does not install a private test-source payload. Packaging tests
check those artifacts, while compiler regressions verify static-provider
retention and production-object reuse across application and test links.

The public `Case`, `Skip`, and `run` declarations use the existing native
calling conventions and metadata schema. Reinstall the compiler and standard
provider together when changing this API. Use a fresh installation after ABI
changes; earlier Titan installations are not migration sources.
