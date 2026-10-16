# Continuous integration and platform validation

The executable definitions are `.github/workflows/ci.yml`,
`.github/workflows/macos.yml`, and `spec/support/ci_*.sh`. This chapter explains
their ownership and ordering contracts. Local setup and command selection are
in [repository workflow](repository-workflow.md); test implementation and native
coverage are in [test runner](test-runner.md) and
[native coverage](native-coverage.md).

Repository builds stage generated Titan artifacts under `TITAN_OUTPUT_DIR`
(default `out`), with native tests in `out/tests` and native coverage in
`out/coverage`. Coverage reports upload from `out/coverage/report`; the ordinary
installed provider remains a separate packaging/runtime input. Authored runtime
objects, native dependency builds, and probe caches keep their existing owners.
See [output-directory routing](output-directory.md) for configuration isolation.

## Linux job graph and concurrency

Linux runs on pushes. Four job definitions produce five runner executions:
`build-compiler` and `sanitizer` start independently; after `build-compiler`,
two `test-linux-compiler` shard pairs and `native-coverage` start in parallel.
Preparation has a 30-minute timeout, compiler pairs and native coverage 45
minutes, and the independent cold sanitizer build 75 minutes.

Linux sets `MAKEFLAGS=-j2` and `TITAN_JOBS=2` for its two-CPU runners. Native
Make prerequisites may overlap; each compiler process overlaps only generated-C
objects. Compiler shards override nested Make/Titan work to one slot and run
at most two workers per runner. Dedicated parallelism regressions retain their
explicit bounds. Recursive LuaRocks/CMake recipes preserve the Make jobserver;
`ltitanlib.o` waits for the selected Lua installation's public headers.

Generated-C scheduling launches larger units first and receives actual child
completion through a private POSIX FIFO, refilling free slots immediately.
Diagnostics replay in request order. Launch-order `pclose` is not an equivalent
replacement: a completed child can otherwise continue occupying a logical slot.
The [driver](driver.md#compiling-one-module-drivercompile) owns that protocol.

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
contains `lib/titan/0.6/?.so`. Pre-reset installations are not migration inputs.

`test-linux-compiler` runs groups 1–2 and 3–4 on separate runners. Each worker
owns a checkout extraction, `TMPDIR`, ccache scratch, and LuaCov stats, and
shares the compiler prefix read-only. The manifests
`ci_compiler_test_groups.txt` and `ci_stdlib_compiler_test_files.txt` classify
compiler-only and stdlib-dependent integration files together, rejecting
missing, stale, or overlapping entries. Compiler-only workers need no
canonical-provider snapshot because no later job consumes their outputs.
Disposable generated fixtures use `TITAN_EXTRA_CFLAGS=-O0 -fno-lto`.

Each covered shard excludes explicit `#stress` cases, then runs its listed
stress oracles separately without LuaCov. Keep a small covered companion over
the same compiler paths. A shard pair merges stats only after both workers
pass, generates its own report, and uploads directly with the `compiler`
Codecov flag. The stdlib integration upload uses that same flag, so there is
no full-tree merger job.

Local exact, unfiltered `rock-test` runs the eight retained runtime/packaging
specs and eight stdlib-dependent compiler integrations serially, then partitions
the other compiler/language specs into four measured longest-first groups in
private checkout copies. `TITAN_ROCK_TEST_JOBS=1` through `4` selects workers,
defaulting to four on Unix; each gets one nested native slot. Busted 2.3 has no
native sharding feature. A Busted filter or appended Busted argument preserves
the ordinary single-process path; a Titan-only filter leaves compiler sharding
enabled. Local shards collect no LuaCov and never upload coverage.

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

Build the source-linked native coverage aggregate with matching GCC/gcov 14 and
pinned gcovr 8.4, then run the complete unfiltered behavior suite once. Each
execution resets counters and replaces reports; save that complete report for
upload. An extra ordinary uncovered aggregate in this lane adds no behavior
coverage. Packaging still consumes the ordinary installed provider. Preserve
both bundled/system OpenSSL production smokes and focused system-SDK/promotion
checks; the system reinstall is a distinct canary.

LuaCov measures the Lua compiler, not Titan/C library implementations. Keep
standard-library API/runtime behavior outside LuaCov; a library-discovered
compiler gap gets a small compiler-focused regression. `.luacov` restricts
collection to compiler and CLI paths. Preserve original `luacov.report.out`
and upload separate `luacov.codecov.out`. `prepare_codecov_report.lua` rewrites
only the extensionless `titanc` section heading to `titanc.lua`, and
`.codecov.yml` maps that alias back to the tracked executable. Without this
reporting conversion, Codecov's LuaCov parser merges CLI lines into the preceding
file. Do not rename the executable. The integration report must include CLI
coverage; a partial compiler shard need not.

Upload LuaCov as `compiler` and native LCOV as `native-stdlib` through separate
failing-on-error OIDC uploads. Retain native reports as artifacts. Local
reporting never uploads.

## Cache ownership

Native dependency caches belong to their consuming stdlib/sanitizer lane, not
the compiler producer. Prefix-owned `var/cache/titan-probes/2` is restored and
saved independently in stdlib coverage, sanitizer, and macOS lanes. Compiler
workers remain probe-cache-free because fixtures reuse header pathnames.
Never restore probe evidence from a less-trusted writer.

Regular probe keys retain the `test-linux-stdlib` namespace and include
OS/architecture/profile, an immutable commit key, and stable restore prefix.
Save after bundled tests/smoke and before the system-OpenSSL canary. Every
profile-bearing native/configuration cache includes profile identity.

## Sanitizer ownership and failure diagnostics

The sanitizer owns an independent ASan+UBSan Lua, libbacktrace, libuv, llhttp,
OpenSSL, and Titan tree; it never consumes the ordinary compiler artifact.
Before LuaRocks/Titan installation, restore native dependencies keyed by pinned
identities, libbacktrace revision, sanitizer flags, Readline/toolchain identity,
OS/architecture, and recipe schema. Always rerun the native targets as one
two-slot jobserver DAG to validate or repair restored outputs, then save a miss
at the clean boundary. That cache contains neither LuaRocks/Titan state nor
C-probe records.

Build the aggregate native executable once, then select focused lifetime gates
through repeated `make titan-stdlib-test-run TITAN_FILTER=...` processes.
Filters never recompile or select native groups. Retain owner/callback,
observable coroutine-GC, TLS/HTTP, WebSocket ownership, dense-Array, PEG/string,
and production net/OS gates; full library behavior belongs to native coverage.
The already built sanitizer aggregate also owns the focused 15-second Runtime
shutdown check, without coverage-reporting overhead.

Keep ordinary `#line` attribution: traceback gates require exact user and
standard-provider frames. `TITAN_NO_LINE_DIRECTIVES=1` is only for isolated
reproduction. Before later publication replaces outputs, the shared stdlib
publication recipe saves sanitized `titan.so`, its exact generated `.c`/`.o`
pairs from the selected stage (`out/titan` by default), and a NUL-delimited
generated-C compile-prefix argv.

Each gate captures its original combined output. Only the failure diagnostic
step reads those logs; never rerun the failed program/provider to obtain a
different failure. The mapper takes the original ASan canonical-provider offset
and BuildId, locates the unique owning translation unit, and compiles one shadow
with `#line` directives blanked and the saved compile prefix. Physical C context
is available only after saved/shadow function bytes, names, sizes, addresses,
and `.text` membership agree. Symbolization uses section-relative `.text`
addresses and the exact private shadow path. Any mismatch leaves context
unavailable. Host Lua/parser dependencies use instrumented O1; libbacktrace,
libuv, generated images, and disposable fixtures use instrumented O0; LTO stays
disabled throughout.

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

The hosted job sets both concurrency bounds to three. It retries only
dependency acquisition within the same prefix; build and complete test execution
remain single-shot. Run all uncovered stdlib/runtime/packaging work and the
aggregate before `ci_test_groups.sh compiler-uncovered`. Before compiler
fixtures, use `ci_stdlib_snapshot.sh` to preserve the runtime archive,
canonical pair, conditional dSYM, and all twenty-five shims, then restore them
before bundled/system production smokes. Retain the real x86_64/arm64 universal
Mach-O archive lookup/repackaging proof; a host-only synthetic check is not a
replacement. Compiler/language specs must not delete shared runtime state to
force recompilation; any isolated coroutine fixture exception owns its exact
restoration boundary.
