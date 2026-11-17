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

Linux runs on pushes. Seven job definitions produce fourteen runner
executions: `build-compiler` and `sanitizer` start independently; after
`build-compiler`, two `test-linux-compiler` shard pairs, `native-coverage`,
[`browser-toolchain`](#browser-toolchain-job), two
[`browser-stdlib`](#browser-stdlib-job) shards, and the six-cell
[`browser-playwright`](#browser-playwright-job) matrix (`validation` and
`production` profiles across `chromium`, `firefox`, and `webkit`) start in
parallel. Preparation has a 30-minute timeout, compiler pairs 45 minutes,
native coverage, the browser jobs, and the `browser-playwright` cells 60
minutes, and the independent cold sanitizer build 75 minutes.

Linux defaults to `MAKEFLAGS=-j2` and `TITAN_JOBS=2` for its two-vCPU runners.
The native coverage, sanitizer, and browser jobs each use a four-vCPU runner
with 16GB RAM and override both limits to four. Large instrumented test units
in the sanitizer job exceed the smaller runner's 8GB RAM.
Under these caps, native Make prerequisites and the standard-library and
native-test module objects overlap in one Make pool: every `titanc` recipe is a
`+` recipe that shares it ([Make job pool and titanc
recipes](build-script-audit.md#make-job-pool-and-titanc-recipes)), and each
compiler process overlaps only its generated-C compilations inside it. The
explicit caps keep the Makefile's default four-slot pool from oversubscribing
the two-vCPU runners. Compiler shards override nested Make/Titan work to one
slot outside their exclusive phase and run at most two workers per runner; the
native coverage job's two installed-stdlib integration workers take two slots
each.
Dedicated parallelism regressions retain their explicit bounds. Recursive
LuaRocks/CMake recipes preserve the Make jobserver; `ltitanlib.o` waits for the
selected Lua installation's public headers. The generated-C completion protocol
that keeps those slots full is owned by the
[driver](driver.md#compiling-one-module-drivercompile).

## Compiler producer and consumers

`build-compiler` prepares a clean ABI-2 Lua prefix, installs compiler/test
dependencies with `luarocks make --only-deps` and `luarocks test --prepare`,
then calls `make install-compiler-sdk`. It builds runtime, libbacktrace, the
native support module, compiler Lua/CLI, the matching Lua SDK, and Titan
headers, then checks that the support module is installed at
`lib/lua/5.5/titan.so` and that neither a `lib/titan/0.6/titan.so|a` provider
nor a `share/lua/5.5/titan` directory exists. Libuv, llhttp, SQLite, OpenSSL,
and private LPegLabel do not belong to this producer.

Its archive is a full-tree tar preserving source/output mtimes, prepared Lua
files, and executable modes. It excludes standard-provider outputs, stdlib
native build trees, and prefix-owned C-probe caches. Producer and consumers
must agree on OS, architecture, and object target. The dependency cache key
includes the active ABI. Preparation removes only known Titan-owned state from
the cached prefix (the rock registration, a manifest-external
`lib/lua/5.5/titan.so`, and the compiler and legacy `share/lua/5.5/titan`
directories) and verifies, with all Lua and Titan path variables unset, that
Lua's `package.cpath` contains `$PREFIX/bin/../lib/lua/5.5/?.so` and no
`/lib/titan/` entry.

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
read-only. Workers also share the host's `/tmp` temporary-file namespace,
because Lua's POSIX `os.tmpname()` ignores `TMPDIR` (same section). A runner
first runs the ordinary files of its two shards concurrently, then each
shard's exclusive files (`EXCLUSIVE_SPECS`, which count
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
Codecov flag. The stdlib integration, `browser-toolchain`, and both
`browser-stdlib` shard uploads use that same flag, so there is no full-tree
merger job.

Local `rock-test` uses the same timing dataset and partition rule, per file and
without LuaCov; see [Busted partitions](test-runner.md#busted-partitions).

## Standard library, packaging, and coverage

`native-coverage` restores the compiler tree, prepares/caches stdlib native
dependencies, and installs one ordinary bundled source rock for host/packaging
gates. Immediately before installation, remove only the restored unregistered
`bin/titanc`, `share/lua/5.5/titan-compiler/`, and
`share/lua/5.5/c-parser/` preparation copies. Otherwise LuaRocks preserves them
as `~` backups. Preserve dependencies and SDK/runtime files.

Run `make stdlib-busted-test`, then the installed-stdlib integrations listed in
`spec/support/ci_stdlib_compiler_test_files.txt` with LuaCov through
`ci_parallel_compiler_tests.sh stdlib`. As for a compiler shard pair, two
workers run `ci_test_groups.sh stdlib-compiler-shard-1` and `-2` concurrently
in private extractions of the prepared archive, each with
`MAKEFLAGS=-j2`/`TITAN_JOBS=2` so together they fill the runner's four CPUs.
The exclusive files then run alone without those caps, and both workers' stats
merge into the workspace's `luacov.stats.out`. `plan_ci_stdlib` in
`compiler_test_groups.lua` balances the ordinary files by LPT over the stdlib
rows' covered seconds, from a same-host serial four-CPU diagnostic run of this
step's files. Like compiler shard workers, these workers share the installed
prefix, which these specs read, and the host's `/tmp` temporary-file
namespace. Their stats name compiler
sources by prefix or checkout-relative paths, so the workspace report resolves
them after the extractions are removed. Compiler integrations that
import standard-library modules consume the installed provider rather than
source-compiling those dependencies in compiler-only shards. This includes
`spec/coder/split_units_spec.lua` (transfer, protobuf, and reflection) and
`spec/coder/unions_stdlib_spec.lua` (reflection); compiler-only union cases
remain in `spec/coder/unions_spec.lua`. The compiler SDK installs no standard
library, and source-compiling protobuf's dependency closure also requires
private LPegLabel headers that the SDK omits. Snapshot and restore the
canonical provider pair, runtime archive, and checkout runtime around compiler
fixtures. The `rockspec_spec.lua` publication gate stages the already
validated installed pair and passes the exact `STDLIB_INSTALL_STAGE` to
`publish-stdlib`; calling build-dependent `install-stdlib` here would rebuild
all roots. Keep packaging gates before legacy compiler fixtures that clean
root outputs.

Then `make titan-native-coverage-build` builds the source-linked native
coverage aggregate with matching GCC/gcov 14 and pinned gcovr 8.4 (HTML, LCOV
and Cobertura), and `make titan-native-coverage-run` runs the complete
unfiltered behavior suite once. Each execution resets counters and replaces
reports, so the saved report is that complete run. An extra ordinary uncovered
aggregate in this lane would add no behavior coverage. Packaging still consumes
the ordinary installed provider. After installing the rock, CI verifies the
loading layout in a plain Lua process with every Lua and Titan path variable
unset: `package.searchpath("titan", package.cpath)` must be the installed
`lib/lua/5.5/titan.so`, the standard provider must not export
`luaopen_titan`, and `require "titan"` followed by `require "titan.string"`
must reach the provider through the Titan searcher. The bundled-OpenSSL
production smoke (`ci_dependency_mode_smoke.sh bundled`) follows; its Lua
fixtures likewise `require "titan"` before any `titan.*` module, with path
variables unset. After the probe cache is saved, `make clean-stdlib` and a
forced reinstall with system OpenSSL run the distinct `system` canary.

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

## `browser-toolchain` job

The [browser target](browser-target.md)'s real-toolchain validation runs in
three parallel jobs, each on its own four-vCPU runner with a 60-minute timeout,
separately from the compiler shards and from the stdlib and sanitizer jobs.
`browser-toolchain` (`browser target real toolchain`) runs the toolchain,
trace-map, trace-entry, and budget gate files and the loader, runner, and trace
suites; the two [`browser-stdlib`](#browser-stdlib-job) shards run the browser
core stdlib suite and the SDK, provider, image, protocol, bridge, scheduler,
network, and stdlib gate files. The long-running budget fixtures stay with the
JavaScript suites. No browser job depends on another or shares its prefix.
Each needs `build-compiler` and consumes the same prepared
`titan-linux-prepared.tar.gz` artifact and `$GITHUB_PATH` setup as the compiler
shards, so its validation prefix starts as the compiler SDK installed from
this commit, with no native standard provider and no browser SDK. The checkout
includes submodules, because the fork's installer reads the gitlinked revision
to write the record; the workflow hardcodes no fork revision. Pins live in
`TITAN_`-prefixed variables (`TITAN_EMSDK_VERSION`, `TITAN_EMSDK_ROOT`,
`TITAN_CHROME_VERSION`, `TITAN_CHROME_SHA256`, `TITAN_CHROME_ROOT`), because
`emsdk_env.sh` unsets every `EMSDK_*` variable it does not set itself, and each
job sets `permissions.id-token: write` for its own Codecov upload. All three
jobs begin with the same seven steps:

1. **Emscripten.** `ubicloud/cache@v4` restores `.emsdk` under the key
   `ubuntu-24.04-<arch>-emsdk-6.0.13-v1`. A missing installation clones emsdk
   (the installer, not the pin); `emsdk install 6.0.13` and `emsdk activate
   6.0.13` are idempotent, so a restored installation only re-verifies. The
   step sources `emsdk_env.sh` and requires `emcc --version` to report exactly
   6.0.13.
2. **Node 26.** `actions/setup-node@v6` installs Node 26.13.0 independently
   of emsdk's bundled Node. The job checks that exact version and the unflagged
   `WebAssembly.promising` and `WebAssembly.Suspending` APIs, then exports its
   executable as `TITAN_NODE`. Browser commands use that path even after
   `emsdk_env.sh` changes `PATH`. `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` affects
   only action runtimes, not the runtime that executes Titan images.
3. **Chrome for Testing.** `ubicloud/cache@v4` restores the headless shell
   under `ubuntu-24.04-<arch>-chrome-headless-shell-156.0.8078.80-<sha256>-v1`
   (the ZIP digest is part of the cache key so re-pinning cannot restore an
   old binary). A miss downloads the pinned linux64 `chrome-headless-shell`
   ZIP, verifies its SHA-256 (Chrome for Testing publishes no digest file),
   and extracts it with `scripts/browser_extract_zip.py` so recorded Unix file
   modes (including `+x`) are preserved regardless of umask. The step installs
   the Ubuntu runtime libraries only when `ldd` reports a missing one, fails
   if any is still missing, and exports `TITAN_CHROME`. Local `act` runs have
   no browser, so provisioning belongs inside the job; there is no npm,
   Playwright, or Chromedriver.
4. **User-namespace sandbox (`Allow Chrome's user-namespace sandbox on the CI
   host`).** Hosted Ubuntu 24.04 enables
   `kernel.apparmor_restrict_unprivileged_userns=1`, which kills Chrome's
   user-namespace sandbox before CDP attaches (`CDP pipe closed before
   shutdown`). The step logs `df -h /dev/shm` and
   `/proc/sys/kernel/unprivileged_userns_clone` (value or `absent`) to
   `$RUNNER_TEMP/browser-chrome-sandbox.log`, reads `sysctl -n
   kernel.apparmor_restrict_unprivileged_userns` (recording `absent (host does
   not restrict unprivileged user namespaces)` on container and `act` hosts
   without the key), runs `sudo sysctl -w
   kernel.apparmor_restrict_unprivileged_userns=0` when the value is not `0`
   and requires the re-read value to be `0` (`cannot relax
   kernel.apparmor_restrict_unprivileged_userns; Chrome's sandbox cannot
   start`), and runs a sandboxed `$TITAN_CHROME --headless ... --dump-dom`
   check under a temporary `--user-data-dir` requiring `id="sandbox"`. Chrome
   keeps its sandbox; the job neither passes `--no-sandbox` nor sets
   `TITAN_BROWSER_ROOT_NO_SANDBOX`.
5. **Browser Lua.** `make lua-browser PREFIX="$PREFIX"` installs the archive,
   record, and headers; the step asserts `liblua.a`, `liblua-config.txt`, and
   core headers.
6. **Native install without Emscripten.** After removing the prepared tree's
   unregistered `bin/titanc`, `share/lua/5.5/titan-compiler`, and
   `share/lua/5.5/c-parser` copies (as `native-coverage` does),
   `"$PREFIX/bin/luarocks" make` runs with `EMSDK` unset and no `emcc` on
   `PATH`, proving that the native build never needs the browser toolchain.
7. **Browser SDK.** With emsdk sourced, the step asserts that
   `lib/titan-browser` is absent or empty, runs `make browser-sdk
   PREFIX="$PREFIX"`, asserts that every file in the [browser SDK file
   list](../language/browser-target.md#installing-the-browser-sdk) except the
   LPegLabel archive is installed, and that `build-profile` holds the job's
   `TITAN_BUILD_PROFILE`.

`browser-toolchain` then runs:

8. **Strict gate.** With `TITAN_ROOT=$PREFIX`,
   `TITAN_REQUIRE_BROWSER_TOOLCHAIN=1`, and `TITAN_PROBE_CACHE_DISABLE=1`, the
   prefix's installed `busted -c -o gtest -v` runs the five real-toolchain
   files `spec/wasm_toolchain_spec.lua`, `spec/coder/browser_toolchain_spec.lua`,
   `spec/browser_trace_map_spec.lua`,
   `spec/coder/browser_trace_entries_spec.lua`, and
   `spec/coder/browser_budgets_spec.lua` under LuaCov, with output copied to
   `$RUNNER_TEMP/browser-gate.log`. A missing gate file fails with `missing
   browser real-toolchain spec: <path>` before Busted starts. The budget spec
   builds its own assertion-on and assertion-off images and runs both engines.
9. **Browser compiler coverage.** `luacov "titan%-compiler/" "titanc$"` and
   `prepare_codecov_report.lua` produce `luacov.report.out` and
   `luacov.codecov.out`, and `codecov/codecov-action@v7` uploads
   `./luacov.codecov.out` with `flags: compiler`, `name: browser`,
   `use_oidc: true`, and `fail_ci_if_error: true`, so the real linking,
   trace-map, and budget paths that are pending in the emsdk-free shards are
   measured.
10. **Runner images.** The installed `titanc` builds `runner_image` (a
    `--test` image) and `runner_status` (a program) from `spec/browser` into
    `out/browser/runner` and asserts `.mjs`, `.wasm`, `.wasm.map`, and `.wasm.trace` for each.
    `scripts/check_browser_stdlib.lua imports entry` then checks both images
    against the [import manifest](browser-target.md#import-manifest).
11. **Loader images.** For assertions 2 and 0, the job sets
    `driver.browser_link_options` and builds `loader_app` and `fidelity`
    (programs with `--c-source spec/fixtures/browser_loader/loader.c`) with the
    `program` purpose and `loader_names` (a `--test` image) with the `test`
    purpose, because a contrary purpose is refused
    ([internal selection](browser-target.md#the-link-profile)), into
    `out/browser/loader`, asserting `.mjs`, `.wasm`, `.wasm.map`, and `.wasm.trace` for each.
    It also
    builds one `fidelity` image with the `baseline` profile at `O2` and
    assertions off, plus the harness-only `--ldflag=-Os` (the profile itself
    supplies the debug flags), because Emscripten 6.0.13 minifies export names
    only at `-O3` or a shrink level. The import check accepts the `entry` class
    for `loader_names` and `entry,fixture:loader,fixture:controls` for the
    `loader_app` and both `fidelity` images, which link the loader fixture.
12. **Loader suite.** The installed `titan-browser-run --timeout 300000
    --grace 2000 --js-test spec/browser/loader.test.mjs`, rooted at the
    workspace with relative image paths, runs under Node and then Chromium,
    with output copied to `$RUNNER_TEMP/browser-loader.log`. The first two
    image arguments are the two assertion modes' `loader_app`, which the
    suite also pairs crosswise to check that a module refuses another link's
    `.wasm`.
13. **Optimized guard.** `spec/fixtures/browser_loader/optimized-guard.mjs`
    runs against the minified image under both engines with the same timeout
    and grace and output copied to `$RUNNER_TEMP/browser-guard.log`.
14. **Runner suite.** `node --test spec/browser/runner.test.mjs` runs with
    `TITAN_BROWSER_RUNNER_IMAGE`, `TITAN_BROWSER_RUNNER_STATUS_IMAGE`,
    `TITAN_BROWSER_RUNNER` (the installed launcher), and
    `TITAN_BROWSER_LOADER_IMAGE` (the assertions-2 `fidelity` image), with
    output copied to `$RUNNER_TEMP/browser-runner.log`.
15. **Trace adapter and supervisor units.** For `assertions` in `2` and `0`,
    `emcc` compiles `spec/fixtures/browser_trace_adapter/lifecycle.c` and
    `spec/fixtures/browser_trace_adapter/filter.c` (with `titan-runtime/titan.c`
    and `$PREFIX/lib/browser/liblua.a`) into `out/browser/trace-adapter/`. The
    `filter.c` image takes its Lua macros from the installed record's
    `lua_defines` (an empty value fails the step), never from a local list,
    because the fork changes them (`LUAI_MAXCCALLS`). `node --test
    spec/browser/trace-adapter.test.mjs spec/browser/playwright-runner.test.mjs`
    then runs with both `TITAN_BROWSER_TRACE_LIFECYCLE_IMAGE` and
    `TITAN_BROWSER_TRACE_FILTER_IMAGE` set (so no adapter prerequisite skips
    occur), with output copied to `$RUNNER_TEMP/browser-trace-units.log`.
16. **Node trace gate.** `lua -E spec/browser/build-trace.lua
    "$GITHUB_WORKSPACE/out/browser/trace-node"` stages the trace gate for both
    assertion modes (`$RUNNER_TEMP/browser-trace-build.log`); the installed
    `titan-browser-run --engine node --timeout 300000 --grace 2000 --root
    "$output" --js-test "$output/trace.test.mjs"` runs the positive gate
    (`$RUNNER_TEMP/browser-trace-node.log`); a policy check runs every
    `manifest.degradedCases` image without `--allow-degraded-trace` and
    requires ordinary initialization failure, exit status 1, before Lua or main
    (`$RUNNER_TEMP/browser-trace-node-policy.log`); and
    `titan-browser-run --engine node --timeout 300000 --grace 2000
    --allow-degraded-trace --root "$output" --js-test "$output/trace.test.mjs"
    -- --degraded` exercises the degraded Lua-only fallback rows
    (`$RUNNER_TEMP/browser-trace-node-degraded.log`).
17. **Failure logs.** On failure, `actions/upload-artifact` uploads the
    `browser-*.log` files and `out/browser` as `browser-toolchain-failure` for
    seven days.

The browser target's spec files (`spec/browser_isolation_spec.lua`,
`spec/browser_target_spec.lua`, `spec/browser_sdk_spec.lua`,
`spec/browser_stdlib_spec.lua`, `spec/browser_trace_map_spec.lua`,
`spec/wasm_toolchain_spec.lua`, and the `spec/coder/browser_*_spec.lua`
files) are also ordinary rows of `spec/support/ci_compiler_test_groups.txt`
and run in the covered compiler shards against the SDK-only prefix. There,
without Emscripten, Node, Chrome, or a browser SDK, every real-toolchain case
is pending and the synthesized cases run (all of `spec/browser_stdlib_spec.lua`
is emsdk-free); compiler shards never become browser SDK consumers.

## `browser-stdlib` job

`browser-stdlib` (`browser SDK and core stdlib <shard>`) is a two-cell matrix.
Both `sdk` and `scheduler` repeat steps 1–7 of the
[`browser-toolchain` job](#browser-toolchain-job) on their own runner and
prefix, with `fail-fast: false`. They use the pinned Chrome for Testing
executable with its default renderer-memory limits and enabled sandbox; no
CI-only memory-limit wrapper or extra renderer-memory feature is applied.

After step 7, `browser-stdlib` runs:

8. **Complete browser core stdlib suite (`sdk` only).** With emsdk sourced and
   `set -euo pipefail`, `make titan-stdlib-browser-test PREFIX="$PREFIX"` runs
   once, unfiltered, its output copied to `$RUNNER_TEMP/browser-stdlib.log`. It
   builds all twenty-three browser-portable owners into one validation-profile
   `images/stdlib.mjs` image, subject to the compiler's general Wasm byte bounds,
   checks dependency closure and the image's `entry` imports against the
   [import manifest](browser-target.md#import-manifest), applies the [subset parity
   gate](browser-target.md#subset-parity-gate) to the fourteen shared
   modules, `async`, `timer`, `os`, `lua`, `http`, and `websocket`, then
   runs the image under Node and Chromium using the pinned `TITAN_NODE` and
   `TITAN_CHROME`. Each engine must execute every owner with complete nonzero
   status/count/timing accounting and pass every image test the status
   inventory names
   ([browser test owners](browser-target.md#test-owners-and-the-browser-suite)).
   Stdout and stderr stay separate in `out/browser-stdlib/stdlib.<engine>.log`
   and `stdlib.<engine>.stderr.log`.
9. **Strict gate.** With the same `TITAN_ROOT`,
   `TITAN_REQUIRE_BROWSER_TOOLCHAIN`, and `TITAN_PROBE_CACHE_DISABLE` settings
   as the `browser-toolchain` gate, each shard runs its matrix `gate-specs`
   list in one serial installed `busted -c -o gtest -v` invocation under
   LuaCov, with output copied to `$RUNNER_TEMP/browser-stdlib-gate.log`:

   | Shard | Spec files (`spec/`-relative) |
   | --- | --- |
   | `sdk` | `coder/browser_bridge_spec.lua`, `coder/browser_stdlib_gate_spec.lua`, `coder/browser_entry_gate_spec.lua`, `coder/browser_images_spec.lua`, `coder/browser_net_spec.lua`, `minicoro_spec.lua`, `coder/browser_fixtures_spec.lua`, `coder/browser_providers_spec.lua` |
   | `scheduler` | `coder/browser_scheduler_spec.lua`, `coder/browser_incremental_spec.lua`, `browser_sdk_spec.lua`, `coder/browser_stdlib_closure_spec.lua`, `coder/browser_protocol_spec.lua` |

   The CI-contract spec requires these lists to cover the full gate exactly
   once, without overlap, and the core suite to run only in `sdk`. A missing
   gate file fails with the same message before Busted starts. The
   entry-gate, bridge and scheduler specs build their own assertion-on and
   assertion-off images, and the entry, bridge, scheduler, stdlib gate,
   network, fixture, and minicoro specs run both engines. The network spec
   runs the [live browser network harness](browser-target.md#the-live-browser-network-harness),
   with verified TLS on both engines. The bridge uses its dedicated
   native Titan test owner with explicit JavaScript bindings, rather than
   adding it to the ordinary core aggregate; the scheduler spec drives the
   bridge's drive interface with a test-owned mini driver, runs the real
   `async` driver's scheduler gate and bootstrap program, and drives the
   embedding-sensitive `os.browser_tests` program with its separate
   stream/environment harness. The scheduler and network specs require every
   test of their owners that the status inventory names to have passed
   ([test evidence](browser-target.md#subset-parity-gate)).
10. **Browser SDK and stdlib compiler coverage.** Each shard runs the same
    report commands and uploads its own `luacov.codecov.out` with
    `name: browser-stdlib-${{ matrix.shard }}` and `flags: compiler`.
    Codecov merges both with the other compiler uploads, so the real provider,
    image, SDK, and executing-protocol paths that are pending in the emsdk-free
    shards are measured.
11. **Failure logs.** On failure, `actions/upload-artifact` uploads each
    shard's evidence as `browser-stdlib-${{ matrix.shard }}-failure` for seven
    days: the `browser-*.log` files and, when present, the browser core stdlib
    suite's evidence: `out/browser-stdlib/*.log` (the
    per-engine `stdlib.<engine>.log` stdout and `stdlib.<engine>.stderr.log`
    files), `out/browser-stdlib/images/*.{mjs,wasm,wasm.map,wasm.trace}`, `roots.txt`
    (through the `*roots.txt` pattern), `members.md`, and the live network
    harness's `out/browser-net/` tree.

## `browser-playwright` job

`browser-playwright` (`browser traces and bridge (${{ matrix.profile }}, ${{
matrix.engine }}, Playwright 1.64.1)`) runs the multi-engine trace, bridge,
live network and hosted deployment gates on Linux across a six-cell
`fail-fast: false` matrix (`profile: [validation, production]` × `engine:
[chromium, firefox, webkit]`), each on a four-vCPU runner with a 60-minute
timeout after `build-compiler`:

1. **Prefix preparation (`validation` versus `production`).** `validation`
   cells restore `titan-linux-prepared.tar.gz` into `$GITHUB_WORKSPACE/.lua`.
   Because the prepared compiler artifact holds validation-built runtime
   objects whose flags Make does not stamp, `production` cells instead require
   `.ci-prepared-workspace` and `$PREFIX` to be absent and bootstrap a cold
   production prefix (`make lua luarocks`, `luarocks make --only-deps`,
   `luarocks test --prepare`, and `make libbacktrace` with `CC=gcc-14` and
   `TITAN_BUILD_PROFILE=production`).
2. **Native and browser SDK installation.** Each cell runs `"$PREFIX/bin/luarocks"
   make` with `EMSDK` unset and no `emcc` on `PATH`, restores the cached
   `.emsdk` (`ubuntu-24.04-<arch>-emsdk-6.0.13-v1`), activates Emscripten 6.0.13,
   and separately installs and qualifies Node 26.13.0 as `TITAN_NODE`. It runs
   `make lua-browser PREFIX="$PREFIX"` and `make browser-sdk PREFIX="$PREFIX"`,
   asserting the installed `titan-browser-trace.js` and `titan-browser-bridge.js`
   and that `build-profile` holds the cell's profile.
3. **Playwright engine provisioning and supervisor check.** `ubicloud/cache@v4`
   restores `PLAYWRIGHT_BROWSERS_PATH` (`.playwright-browsers`) under
   `ubuntu-24.04-<arch>-playwright-1.64.1-<engine>-v1`; `npm install --prefix
   "$TITAN_PLAYWRIGHT_ROOT"` (`out/playwright-tools`) installs
   `playwright@1.64.1`, whose engines are Chromium 156.0.8078.4, Firefox 157.0,
   and WebKit 27.2. `playwright/cli.js install --with-deps
   "$TITAN_TRACE_ENGINE"` provisions the cell's browser and host libraries;
   `TITAN_PLAYWRIGHT_TEST_ENGINES="$TITAN_TRACE_ENGINE" "$TITAN_NODE" --test
   spec/browser/playwright-runner.test.mjs` verifies the supervisor against that
   managed engine (`$RUNNER_TEMP/browser-playwright-supervisor.log`).
4. **Staged trace gate (`assertions-2` and `assertions-0`).** `lua -E
   spec/browser/build-trace.lua "$TITAN_TRACE_OUTPUT"`
   (`out/browser/trace-<profile>-<engine>`, logged to
   `$RUNNER_TEMP/browser-playwright-build.log`) builds the test image and the
   uncaught and async-bootstrap program images for both assertion modes with
   the cell's installed `titanc` and stages the degraded-map variants,
   `trace.test.mjs`, and `manifest.json`. Like `build-bridge.lua`,
   `build-net.lua` and `build-delivery.lua` (steps 7 to 9), it checks each
   image it builds against the [import manifest](browser-target.md#import-manifest)
   classes of the fixtures that image links.
5. **Positive trace gate.** `"$TITAN_NODE" spec/browser/playwright-run.mjs --engine
   "$TITAN_TRACE_ENGINE" --timeout 300000 --grace 2000 --sdk
   "$PREFIX/lib/titan-browser/0.6" --root "$TITAN_TRACE_OUTPUT"
   "$TITAN_TRACE_OUTPUT/trace.test.mjs"`
   (`$RUNNER_TEMP/browser-playwright-trace.log`) runs the full file/line,
   contributor, wrapper-family, merge-order, descriptor-safety,
   pin/rethrow/clear, coroutine-append, post-suspension Task and entry
   (titan#334), SpiderMonkey saved-parent cutoff and 128-frame ceiling,
   held-storage nested capture, and merge-OOM guard-recovery checks on
   `chromium` and `firefox`, and the reduced-fidelity no-line counterpart with
   the same 512-record capacity on `webkit`. The gate reads the installation
   profile from `manifest.json`: every row is exact except a `production`
   cell's program rows (`uncaught` and `async_uncaught`), which use the
   [ordered-subsequence contract](browser-target.md#test-images) for inlined
   frames.
6. **Degraded-mode policy and fallback checks.** Every row in
   `manifest.degradedCases` is first run with `playwright-run.mjs ... --image
   <row.image>` without `--allow-degraded-trace` and must fail with exit status
   1, the ordinary pre-Lua initialization failure
   (`$RUNNER_TEMP/browser-playwright-policy.log`); then
   `playwright-run.mjs ... --allow-degraded-trace ... "$TITAN_TRACE_OUTPUT/trace.test.mjs"
   -- --degraded` (`$RUNNER_TEMP/browser-playwright-degraded.log`) verifies the
   single load warning, the `(native Titan frames unavailable: trace table not
   loaded)` marker, and original-error preservation.
7. **Persistent bridge gate (all six cells).** `lua -E
   spec/browser/build-bridge.lua "$TITAN_BRIDGE_OUTPUT"` builds the real
   `browser.tests` image with its independent-state C helper, the failed
   initializer image, the `browser.public_state_tests` image of public
   `lua.new` lifetimes (same C helper), the html5 click counter of
   synchronous C callbacks with its C helper, and the async driver's
   responsiveness program (`responsive.titan`), each with assertions 2 and 0.
   It stages those images and the portable JavaScript fixtures in
   `out/browser/bridge-<profile>-<engine>`. `integration.mjs` receives the
   first three images, and the negative scripts only the legacy bridge image.
   The cell's managed engine runs the full lifecycle, typed values, callbacks,
   notification, request, stdio, state-close and collection suite;
   `counter.mjs` clicks the counter's buttons on the page (`COUNTER
   {"verdict":"PASS"`), and `responsive.mjs` measures a 10 ms `setInterval`
   and `requestAnimationFrame` while Tasks wait (against a no-Titan baseline of
   the page's own timer cadence, D22), yield continuously, resume from requests
   that settle together, and while one call busy-waits
   (`RESPONSIVE {"verdict":"PASS"`; titan#334). Separate
   processes require unhandled-rejection status74 for opaque imported and
   reverse-call Promise values, and abort status70 for the poisoned-owner
   retirement case. Each negative case must also emit its expected marker;
   an early failure with the same status cannot satisfy it. The production
   Chromium cell repeats the same bridge cases on Node, except the two page
   tests, which need a page's DOM; validation Node is
   covered by `browser-stdlib`. Logs are
   `$RUNNER_TEMP/browser-playwright-bridge-build.log` and
   `$RUNNER_TEMP/browser-playwright-bridge.log`. The bridge images are built
   before the live network gate (step 8) and run after it.
8. **Live network gate (all six cells).** `lua -E spec/browser/build-net.lua
   "$TITAN_NET_OUTPUT"` (`out/browser-net`, logged to
   `$RUNNER_TEMP/browser-playwright-net-build.log`) builds the native network
   peers and the `http.browser_tests` and `websocket.browser_tests` images with
   the cell's installed `titanc`. Chromium cells then check `python3
   --version`, because the NSS trust setup needs it. `"$TITAN_NODE"
   spec/fixtures/browser_net/run.mjs --root "$TITAN_NET_OUTPUT" --engine
   "$TITAN_TRACE_ENGINE" --sdk "$PREFIX/lib/titan-browser/0.6" --runner
   "$PWD/spec/browser/playwright-run.mjs" --repository "$PWD"
   --persistent-webkit` (`$RUNNER_TEMP/browser-playwright-net.log`) runs them
   on the cell's engine against those peers
   ([live browser network harness](browser-target.md#the-live-browser-network-harness)).
   Verified `https://` and `wss://` run on Chromium, whose isolated NSS
   database trusts the test CA; Firefox and WebKit run the
   untrusted-certificate rejections, and WebKit runs in a persistent context
   so that its HTTP cache exists.
9. **The complete application (all six cells).** `lua -E
   spec/browser/build-delivery.lua "$TITAN_DELIVERY_OUTPUT"`
   (`out/browser-delivery`, logged to
   `$RUNNER_TEMP/browser-playwright-delivery-build.log`) builds the browser
   chapter's complete application by its section's commands, in the cell's
   profile, and the documented `http-dev-server` natively. `"$TITAN_NODE"
   spec/fixtures/browser_delivery/hosted.mjs --engine "$TITAN_TRACE_ENGINE"
   --root "$TITAN_DELIVERY_OUTPUT"`
   (`$RUNNER_TEMP/browser-playwright-delivery.log`) serves it to a page in the
   cell's engine and checks the documented output and trace, the page's exact
   requests, and their order against the first output and the caught error
   ([documentation checks](browser-target.md#documentation-checks)).
   `production` cells add `--records
   "$PWD/out/browser-records/playwright-$TITAN_TRACE_ENGINE.json"`: startup
   and responsiveness over five loads, which never fail the step. Chromium
   cells also run the image under Node with `titan-browser-run --engine node
   --timeout 120000 --root "$TITAN_DELIVERY_OUTPUT" --js-test
   "$TITAN_DELIVERY_OUTPUT/dod.test.mjs"`
   (`$RUNNER_TEMP/browser-playwright-delivery-node.log`).
10. **The browser chapter's examples (`chromium`, both profiles).** These two
   cells install `vite@8.3.6` into `TITAN_VITE_ROOT` (`out/vite-tools`) with
   the pinned Node runtime. With `TITAN_REQUIRE_BROWSER_TOOLCHAIN=1`,
   `TITAN_REQUIRE_BROWSER_DEPLOYMENT=1`, and `TITAN_PROBE_CACHE_DISABLE=1`,
   `busted -o gtest -v spec/coder/browser_docs_spec.lua` runs the marked
   blocks of the browser chapter's opening section through `scripts/doc_check.lua`
   ([documentation checks](browser-target.md#documentation-checks)): it
   builds the documented `hello` program and `http-dev-server`, runs the
   image under plain Node, and loads the documented page with the cell's
   managed Chromium from the folder, from its `locateFile` variant, and from
   the documented Vite build, each served by `http-dev-server`. Each page
   must show the chapter's expected text and fetch the Wasm (as
   `application/wasm`) and the trace table once each; no external Titan
   loader is served, and a copy without the trace table must fail through the
   page's `requireTrace: true`. Its output is
   `$RUNNER_TEMP/browser-playwright-docs.log`. Firefox and WebKit cells keep
   their own managed engine without installing another one for this gate.
11. **Production-only pins (`production` × `chromium` only).** With
   `TITAN_REQUIRE_BROWSER_TOOLCHAIN=1` and `TITAN_PROBE_CACHE_DISABLE=1`,
   `"$PREFIX/bin/busted" -o gtest -v spec/coder/browser_images_spec.lua
   --filter="keeps frame flags on test owners" --filter="checks the linked
   module"` runs the pin that observes the production object and link profile
   from a real production installation, and the [module
   check](browser-target.md#the-module-check) case on a real production image
   (`$RUNNER_TEMP/browser-production-pins.log`). A validation installation
   cannot stand in for the pin, so it is pending in every validation run,
   including the `browser-stdlib` job; the module check case runs there too,
   on a validation image.
12. **Production trace gate on Node (same cell).** Node is the binding engine
   for the [browser C-call limit](browser-target.md#the-browser-c-call-limit),
   and the `browser-toolchain` job's Node gate runs a validation installation
   only. The cell's installed `titan-browser-run --engine node --timeout 300000
   --grace 2000 --root "$TITAN_TRACE_OUTPUT" --js-test
   "$TITAN_TRACE_OUTPUT/trace.test.mjs"` therefore runs the positive gate
   against the production images
   (`$RUNNER_TEMP/browser-playwright-node-trace.log`). A policy check runs
   every `manifest.degradedCases` image without `--allow-degraded-trace` and
   requires ordinary initialization failure, exit status 1
   (`$RUNNER_TEMP/browser-playwright-node-policy.log`),
   and the `--allow-degraded-trace ... -- --degraded` run covers the degraded
   rows (`$RUNNER_TEMP/browser-playwright-node-degraded.log`).
13. **Receipts.** On `always()`, `actions/upload-artifact` uploads
    `${{ runner.temp }}/browser-playwright-*.log`,
    `${{ runner.temp }}/browser-production-pins.log`,
    `${{ env.TITAN_TRACE_OUTPUT }}`, `${{ env.TITAN_BRIDGE_OUTPUT }}`,
    `${{ env.TITAN_NET_OUTPUT }}`, and the complete application's
    `delivery.json` and staged `browser-app/site` as
    `browser-playwright-${{ matrix.profile }}-${{ matrix.engine }}` for seven
    days. `production` cells also upload `out/browser-records/` as
    `browser-records-playwright-${{ matrix.engine }}`.

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

Before the gates, the sanitizer job certifies an identical SDK reinstall. It
reruns `luarocks make --force` with `TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT` cleared,
so the diagnostic snapshot taken by the first sanitized install remains the
description of the linked provider, and checks with `cmp` that the snapshot's
`provider.so` still equals the installed `titan.so`. A following
`make titan-stdlib-test-build TITAN_VERBOSE=1` must report object, native, and
link hits and no `Titan ... miss` or `os_process_host_child.c` compilation.
The Linux native coverage lane (through `make titan-native-coverage-build`)
and the macOS lane run the same reinstall gate without the snapshot.

A gate whose filter could silently select nothing, for example after a case
rename, also greps each log for the runner's timed
`[==========] N test(s) ran. (N.NN ms total)` summary with N at least one,
accepting one CR before its line end; the `ci.yml` steps show which gates do.
The teardown gate is one of them. It runs every `test_lua_close_` case
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
fixtures, use `ci_stdlib_snapshot.sh` to preserve the runtime archive and the
canonical provider pair with its conditional dSYM, then restore them
before bundled/system production smokes. Retain the real x86_64/arm64 universal
Mach-O archive lookup/repackaging proof; a host-only synthetic check is not a
replacement. Compiler/language specs must not delete shared runtime state to
force recompilation.
