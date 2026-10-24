# Continuous integration and platform validation

The executable definitions are `.github/workflows/ci.yml`,
`.github/workflows/macos.yml`, and `spec/support/ci_*.sh`. This chapter explains
their ownership and ordering contracts and is the canonical description of the
CI lanes. Local setup and commands are in [repository
workflow](repository-workflow.md); test implementation, local Busted
partitions and native coverage are in [test runner](test-runner.md) and
[native coverage](native-coverage.md). Generated artifacts follow the
repository's [output routing](repository-workflow.md#route-generated-output-explicitly);
coverage reports upload from `out/coverage/report`.

## Linux job graph and concurrency

Linux runs on pushes. Four job definitions produce five runner executions:
`build-compiler` and `sanitizer` start independently; after `build-compiler`,
two `test-linux-compiler` shard pairs and `native-coverage` start in parallel.
Preparation has a 30-minute timeout, compiler pairs 45 minutes, native coverage
60 minutes, and the independent cold sanitizer build 75 minutes.

Linux defaults to `MAKEFLAGS=-j2` and `TITAN_JOBS=2` for its two-vCPU runners.
The native coverage and sanitizer jobs each use a four-vCPU runner with 16GB RAM
and override both limits to four. Large instrumented test units in the sanitizer
job exceed the smaller runner's 8GB RAM.
Under these caps, native Make prerequisites and the standard-library and
native-test module objects overlap in one Make pool: every `titanc` recipe is a
`+` recipe that shares it ([Make job pool and titanc
recipes](build-script-audit.md#make-job-pool-and-titanc-recipes)), and each
compiler process overlaps only its generated-C compilations inside it. The
explicit caps keep the Makefile's default four-slot pool from oversubscribing
the two-vCPU runners. Compiler shards override nested Make/Titan work to one
slot outside their exclusive phase and run at most two workers per runner.
Dedicated parallelism regressions retain their explicit bounds. Recursive
LuaRocks/CMake recipes preserve the Make jobserver; `ltitanlib.o` waits for the
selected Lua installation's public headers. The generated-C completion protocol
that keeps those slots full is owned by the
[driver](driver.md#compiling-one-module-drivercompile).

## Compiler producer and consumers

`build-compiler` prepares a clean ABI-2 Lua prefix, installs compiler/test
dependencies with `luarocks make --only-deps` and `luarocks test --prepare`,
then calls `make install-compiler-sdk`. It builds runtime, libbacktrace, bare
native compiler support, compiler Lua/CLI, the matching Lua SDK, and Titan
headers. Guarded `stage-titan-bootstrap` supplies bare `require "titan"`
support without logical stdlib metadata, shims, or `titan.a`. Libuv, llhttp,
SQLite, OpenSSL, and private LPegLabel do not belong to this producer.

Its archive is a full-tree tar preserving source/output mtimes, prepared Lua
files, and executable modes. It excludes standard-provider outputs, stdlib
native build trees, and prefix-owned C-probe caches. Producer and consumers
must agree on OS, architecture, and object target. The dependency cache key
includes the active ABI. Restore reruns Lua/LuaRocks preparation, replaces only
known active `0.6` Titan rock/direct-shim state, and verifies `package.cpath`
contains `lib/titan/0.6/?.so`.

`test-linux-compiler` runs shards 1–2 and 3–4 of one four-way covered plan on
separate runners (`spec/support/ci_parallel_compiler_tests.sh`).
`spec/support/compiler_test_groups.lua ci-select compiler-shard-N` derives that
plan from the timing dataset `ci_compiler_test_groups.txt` with the same
longest-processing-time rule as local runs, over the compiler domain and its
covered CI seconds (falling back to the local validation time); no shard
numbers are stored. The dataset and `ci_stdlib_compiler_test_files.txt`
classify compiler-only and stdlib-dependent integration files together,
rejecting missing, stale, or overlapping entries; see [Busted
partitions](test-runner.md#busted-partitions). Each worker owns a checkout
extraction, `TMPDIR`, and LuaCov stats, and shares the compiler prefix
read-only. A runner first runs the ordinary files of its two shards
concurrently, then each shard's exclusive files (`EXCLUSIVE_SPECS`, which count
real overlapping compiler processes or drive real Make jobservers) alone, one
shard after the other and without the nested `MAKEFLAGS=-j1`/`TITAN_JOBS=1`
caps; LuaCov stats accumulate in the owning shard's extraction across both
phases.
Compiler-only workers need no canonical-provider snapshot because no later job
consumes their outputs. Disposable generated fixtures use
`TITAN_EXTRA_CFLAGS=-O0 -fno-lto`. `TITAN_COVERAGE_TEST_REQUIRED=1` makes
`spec/coder/native_coverage_spec.lua` fail instead of pending when the pinned
GCC 14/gcov/gcovr tools are missing.

Each covered shard excludes explicit `#stress` cases, then runs its listed
stress oracles separately without LuaCov. Keep a small covered companion over
the same compiler paths. A shard pair merges stats only after both workers
pass, generates its own report, and uploads directly with the `compiler`
Codecov flag. The stdlib integration upload uses that same flag, so there is
no full-tree merger job.

Local `rock-test` uses the same timing dataset and partition rule, per file and
without LuaCov; see [Busted partitions](test-runner.md#busted-partitions).

## Standard library, packaging, and coverage

`native-coverage` restores the compiler tree, prepares/caches stdlib native
dependencies, and installs one ordinary bundled source rock for host/packaging
gates. Immediately before installation, remove only the restored unregistered
`bin/titanc`, `share/lua/5.5/titan-compiler/`, and
`share/lua/5.5/c-parser/` preparation copies. Otherwise LuaRocks preserves them
as `~` backups. Preserve dependencies and SDK/runtime files.

Run `make stdlib-busted-test`, then the eight integrations through
`ci_test_groups.sh stdlib-compiler` with LuaCov. Snapshot and restore the
canonical provider pair, shims, and checkout runtime around compiler fixtures.
The `rockspec_spec.lua` publication gate stages the already validated installed
pair/shims and passes the exact `STDLIB_INSTALL_STAGE` to `publish-stdlib`;
calling build-dependent `install-stdlib` here would rebuild all roots. Keep
packaging gates before legacy compiler fixtures that clean root outputs.

Then `make titan-native-coverage-build` builds the source-linked native
coverage aggregate with matching GCC/gcov 14 and pinned gcovr 8.4 (HTML, LCOV
and Cobertura), and `make titan-native-coverage-run` runs the complete
unfiltered behavior suite once. Each execution resets counters and replaces
reports, so the saved report is that complete run. An extra ordinary uncovered
aggregate in this lane would add no behavior coverage. Packaging still consumes
the ordinary installed provider. The bundled-OpenSSL production smoke
(`ci_dependency_mode_smoke.sh bundled`) follows; after the probe cache is saved,
`make clean-stdlib` and a forced reinstall with system OpenSSL run the distinct
`system` canary.

LuaCov measures the Lua compiler, not Titan/C library implementations. Keep
standard-library API/runtime behavior outside LuaCov; a library-discovered
compiler gap gets a small compiler-focused regression. `.luacov` restricts
collection to compiler and CLI paths. Preserve original `luacov.report.out`
and upload separate `luacov.codecov.out`. `prepare_codecov_report.lua` rewrites
only the extensionless `titanc` section heading to `titanc.lua`, and
`.codecov.yml` maps that alias back to the tracked executable. Without this
reporting conversion, Codecov's LuaCov parser merges CLI lines into the preceding
file. Do not rename the executable. The integration report must include CLI
coverage; a partial compiler shard need not. Compiler frontends that
`native_coverage_spec.lua` launches as children run from private copies;
`spec/support/luacov_children.lua` collects their LuaCov stats and merges them
into the parent run.

Upload LuaCov as `compiler` and native LCOV as `native-stdlib` through separate
failing-on-error OIDC uploads. The "Retain local reports" step uploads
`out/coverage` as an artifact with `include-hidden-files: true`, because the
compiler keeps generated coverage files in hidden `.coverage` directories.
Local reporting never uploads.

## Cache ownership

Native dependency caches belong to their consuming stdlib/sanitizer lane, not
the compiler producer. Prefix-owned `var/cache/titan-probes/2` is restored and
saved independently in stdlib coverage, sanitizer, and macOS lanes. Compiler
workers remain probe-cache-free because fixtures reuse header pathnames.
Never restore probe evidence from a less-trusted writer.

Regular probe keys retain the `test-linux-stdlib` namespace and include
OS/architecture/profile, an immutable commit key, and stable restore prefix.
Save after bundled tests/smoke and before the system-OpenSSL canary. Every
profile-bearing native/configuration cache includes profile identity. Cached
libbacktrace and libuv trees carry their [configuration
stamps](build-script-audit.md#native-dependency-configuration-stamps), so a
restored tree whose configuration matches is not rebuilt; change the cache key
(`LIBUV_BUILD_PROFILE`, `SANITIZER_NATIVE_CACHE_SCHEMA`) whenever a recipe
changes what the cached tree must contain.

## Sanitizer ownership and failure diagnostics

The disposable Linux sanitizer runner removes its unused preinstalled Android
SDK at `/usr/local/lib/android/sdk` before building, and reports disk space
before and after. Instrumented providers and static child fixtures need room
for their link outputs. Make-owned runtime/provider archives, generated code,
and diagnostic snapshots remain available throughout the gates.

The sanitizer owns an independent ASan+UBSan Lua, libbacktrace, libuv, llhttp,
OpenSSL, and Titan tree; it never consumes the ordinary compiler artifact.
Before LuaRocks/Titan installation, restore native dependencies keyed by pinned
identities, libbacktrace revision, sanitizer flags, Readline/toolchain identity,
OS/architecture, and recipe schema. Always rerun the native targets as one
four-slot jobserver DAG to validate or repair restored outputs, then save a miss
at the clean boundary. That cache contains neither LuaRocks/Titan state nor
C-probe records.

Build the aggregate native executable once, then select focused lifetime gates
through repeated `make titan-stdlib-test-run TITAN_FILTER=...` processes, each
wrapped by `spec/support/ci_sanitizer_capture.sh`. Filters never recompile or
select native groups. The `sanitizer` job's step list in `ci.yml` is the gate
inventory: Runtime shutdown, dense Array and value transfer, immediate
functions, nominal storage, coroutine GC, state-close teardown and coroutine
unwinding, async/libuv owners and callbacks, TLS/HTTP, WebSocket ownership,
SQLite, JSON, reflection, PEG/regex, and the net/OS production smokes. Full
library behavior belongs to native coverage. The 15-second Runtime shutdown
check runs here because this aggregate carries no coverage-reporting overhead.
The gates run serially through that focused leaf, never through
`titan-stdlib-test-run-parallel`: several carry timing oracles, such as that
shutdown check, which concurrent filtered runs would load. Host Lua/parser
dependencies use instrumented O1; libbacktrace, libuv, generated images, and
disposable fixtures use instrumented O0; LTO stays disabled throughout.

A gate whose filter could silently select nothing, for example after a case
rename, also greps each log for the runner's `[==========] N test(s) ran.`
summary with N at least one; the `ci.yml` steps show which gates do. The
teardown gate is one of them. It runs every `test_lua_close_` case
([Lua-state close of an unretired
Runtime](libuv-runtime.md#lua-state-close-of-an-unretired-runtime), parked
external waits, and thread endpoints) and every `test_unwind_` case
([abandoned-coroutine
unwinding](coroutines.md#unwinding-an-abandoned-coroutine)).

Keep ordinary per-node `#line` attribution during the run: traceback gates
require exact user and standard-provider frames. `TITAN_NO_LINE_DIRECTIVES=1`
is only an isolated reproduction aid. Physical generated-C lines for an ASan
failure are recovered afterwards, without rerunning or perturbing the failure.
The mapper is `spec/support/asan_generated_c_context.lua`, driven by
`spec/support/ci_asan_generated_c_context.lua`:

1. **Snapshot.** When `TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT` is set, the shared
   `install-stdlib`/`publish-stdlib` recipe calls `snapshot` (`M.snapshot`)
   after `titanc` finishes and before publication or later tests replace the
   outputs. It copies the sanitized stage `titan.so` and every generated
   `.c`/`.o` pair from the stage (`out/titan` by default), and records the
   canonical installed provider path, the source display root and the
   NUL-delimited `driver.generated_compile_prefix()` argv. The snapshot
   therefore describes the exact provider and objects that were linked, not a
   later rebuild.
2. **Logs.** `ci_sanitizer_capture.sh` tees each gate's combined output to its
   own log. Only the failure-only "Report generated C context" step reads the
   logs and the snapshot; it never reruns the failing test, regenerates the
   standard library, or executes a second provider.
3. **Frame selection.** For each numbered ASan frame, `map_frame` requires the
   relocation-safe `(<canonical-provider>+<module-offset>)` pair and, when the
   provider carries a BuildId, a matching frame BuildId. It finds the containing
   provider `.text` symbol, keeps the byte delta within that function, and
   requires exactly one saved object that defines the same nonempty symbol
   (`find_unit`).
4. **Shadow.** `prepare_shadow` replaces every `#line` directive in that unit's
   saved C with a blank line (`M.strip_line_directives`), preserving physical
   line numbers, and compiles it at an exact private pathname with the saved
   compile prefix. The shadow is never linked or executed.
5. **Proof.** `shadow_for` requires the original and shadow target functions'
   complete `.text` bytes to be identical, and checks provider, original and
   shadow function sizes, addresses, unique symbol ownership and `.text`
   membership. Other functions may differ in sanitizer source-location
   metadata without weakening this instruction-level proof.
6. **Context.** Only then does `addr2line` resolve the delta within the
   relocatable shadow object's `.text`, and it must return the exact private
   shadow path. The mapper prints numbered context from the saved generated C
   under its original pathname.

Missing module offsets, a required BuildId that is absent or different, symbol
mismatches, overlapping or aliased functions, changed target bytes, and any
other incomplete evidence make that frame's context unavailable rather than
producing a speculative mapping.

### Fake-stack probe

The job compiles with the runner's `cc` (GCC) and sets
`detect_stack_use_after_return=1`. GCC then places a frame that calls `setjmp`,
and its `jmp_buf`, on ASan's fake stack; Clang never does. The coroutine
crossing keys of [abandoned-coroutine
unwinding](coroutines.md#unwinding-an-abandoned-coroutine) normalize such
fake-stack addresses, and only a lane with that placement exercises the
normalization. Before the teardown gate, the job builds
`spec/support/asan_fake_stack_probe.c` with the job's `$CC` and
`$SANITIZER_FLAGS` and runs it under the job's `ASAN_OPTIONS`. The probe calls
`setjmp` on a local `jmp_buf` and exits nonzero unless
`__asan_addr_is_in_fake_stack` finds that buffer on the current thread's fake
stack, so a runner-image or compiler change that stops the placement fails the
job instead of silently removing that coverage from the `test_unwind_` gate.
Local Clang sanitizer lanes do not exercise the normalization.

## macOS pre-merge gate

Complete macOS validation is a pre-merge check. Prefer an equivalent complete
local VM run covering runtime, packaging, native/compiler suites, and both
OpenSSL production modes, with exact source and architecture evidence. Intel
evidence does not establish Apple Silicon runtime behavior. The complete run
uses the validation profile, including both dependency-mode smokes. For the
companion extension, put GNU Make 4.4.1 first on `PATH` ahead of Apple Make 3.81.

The hosted `macos.yml` fallback is manual-only. PR creation/update does not
authorize its cost; dispatch only with an explicit maintainer request:

```sh
gh workflow run macos.yml --ref <branch>
```

The hosted job sets all three concurrency bounds to three (`MAKEFLAGS=-j3`,
`TITAN_JOBS=3`, and `TITAN_TEST_JOBS=3`), so its `make stdlib-test` runs the
native aggregate as three ordinary owner groups followed by the timing-guarded
owners alone. Its `libuv_build_spec.lua` checks Apple Make 3.81's serial
default through `/usr/bin/make`; the GNU Make 4.2 pool-seeding case stays
pending there, and `TITAN_TEST_LEGACY_MAKE` names an older GNU Make for that
check on other hosts. It retries only dependency acquisition within the same prefix;
build and complete test execution remain single-shot. Run all uncovered
stdlib/runtime/packaging work and the aggregate before
`ci_test_groups.sh compiler-uncovered`. Before compiler
fixtures, use `ci_stdlib_snapshot.sh` to preserve the runtime archive,
canonical pair, conditional dSYM, and all shims, then restore them
before bundled/system production smokes. Retain the real x86_64/arm64 universal
Mach-O archive lookup/repackaging proof; a host-only synthetic check is not a
replacement. Compiler/language specs must not delete shared runtime state to
force recompilation.
