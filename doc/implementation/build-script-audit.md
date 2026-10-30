# Build and installation responsibilities

`Makefile` is the Linux/macOS entry point. `Makefile.win` is the Windows entry
point for direct builds and for LuaRocks' make backend, which the rockspec
selects on Windows. LuaRocks owns the compiler's Lua dependencies and
source-rock deployment on all three platforms. `scripts/install_compiler.mk`
holds the compiler, rock-tool and `binary-rock` rules shared by both Makefiles.

This chapter is the canonical home for Lua preparation, the standard-library
and native-test compiler recipes, the support module, and LuaRocks
installation, `post_install`, binary rocks and uninstall. The standard-library
root list and
physical image are in [multi-module
libraries](multi-module-libraries.md#reserved-titan-and-the-standard-library-image).
Developer commands are in [repository workflow](repository-workflow.md);
Windows-only deltas are in [Windows builds](windows-build.md).

## Lua and native dependencies

`make lua` and `make luarocks` check only for their installed programs in
`PREFIX/bin` and skip all work when the program exists. Callers own the
selected native toolchain, prerequisites, prefix, and cleanup when build inputs
change. Linux defaults to Lua's `linux-readline` target and macOS to `macosx`;
provide Readline development files or override `LUA_PLATFORM`.

An explicit `PREFIX` always wins. Otherwise a validation-profile invocation
uses the checkout's `.lua-validation`, and a production invocation takes the
parent of the realpath directory of the Lua 5.5 `lua` on `PATH`
(`scripts/detect_lua_prefix.sh`, which keeps an equivalent `PATH` spelling of
`<prefix>/bin/lua` and parses no `package.cpath`), falling back to
`/usr/local`. `TITAN_INSTALL_TREE`, the destination of the Titan SDK and
providers, is `ROCKS_TREE` when that is set and `PREFIX` otherwise in the Unix
`Makefile`; `Makefile.win` always uses `PREFIX`. `make lua` passes only
`PREFIX` (and the toolchain settings) to the Lua fork's build and install.

The toolchain settings are `LUA_CC`, `LUA_AR`, and `LUA_RANLIB`, and
`LUA_MYCFLAGS`, `LUA_MYLDFLAGS`, and `LUA_MYLIBS` as the fork's `MYCFLAGS`,
`MYLDFLAGS`, and `MYLIBS`. `LUA_MYCFLAGS` and `LUA_MYLDFLAGS` default to
`TITAN_PROFILE_HOST_FLAGS` (`-O2 -fno-lto` under validation, empty under
production). Neither default carries `-fPIC`. Titan links `liblua.a` into the
support module and every compiled DSO. The fork's `linux`, `linux-readline`,
`macosx`, `bsd`, and `freebsd` targets therefore put `-fPIC` in `SYSCFLAGS`,
separate from the caller-owned `MYCFLAGS`, so setting `MYCFLAGS`
does not drop it. The fork's `mingw` target is unchanged; `Makefile.win` builds
its own Lua DLL. A stock Lua tree that a checkout compiler links through
`--lua` has no such default
([A stock Lua tree](../language/installation.md#a-stock-lua-tree)).

Ordinary native archives use source/header prerequisites and `ar`/`ranlib`.
Failed output recipes remove unfinished artifacts before an ordinary retry.
CMake owns libuv incrementality; upstream configure/make owns libbacktrace and
bundled OpenSSL. Both Makefiles default to `OPENSSL_MODE=system`, which uses an
installed OpenSSL SDK. The Windows runtime build compiles its nine inputs
directly. Versioned source acquisition retains checksums and the required
upstream corrections. On all three platforms, LuaRocks installs `luv` for the
compiler's worker and subprocess transport; its LuaRocks build uses CMake and
its own bundled libuv independently of Titan's standard-library libuv archive.

### Native dependency configuration stamps

Without a configuration record, an existing archive is never rebuilt for new settings:
Make would not rerun either build, libbacktrace's configure does not rebuild
existing objects, and a reused libuv CMake cache keeps the earlier compiler
and, when `LIBUV_BUILD_CFLAGS` becomes empty, the earlier C flags. The Unix
`Makefile` therefore records each archive's configuration in a stamp that only
that archive depends on. `libbacktrace/.titan-build.config` holds
`TITAN_BUILD_PROFILE`, `CC`, `AR`, `RANLIB`, and `LIBBT_CFLAGS`;
`libuv-build/.titan-build.config` holds `CC`, `LIBUV_CMAKE_FLAGS` (with
`LIBUV_BUILD_TYPE`), and `LIBUV_BUILD_CFLAGS`. Each stamp depends on `FORCE`:
its recipe writes the current configuration to a temporary file and replaces
the stamp only when the content differs (`cmp`, then `mv`). An unchanged
configuration therefore keeps the stamp's timestamp, and a second `make`
rebuilds neither archive nor anything that depends on them: the runtime SDK,
the checkout-runtime standard-library objects (libbacktrace is in
`STDLIB_TOOL_PREREQS`), and the provider link (libuv is in
`STDLIB_NATIVE_PREREQS`). A changed configuration rebuilds exactly the affected
archive once, from a clean `make clean` libbacktrace tree or a discarded libuv
CMake cache, and then its ordinary dependents. A tree without a stamp, for
example a cache restored from an older recipe, rebuilds that archive once.
`make -n` cannot evaluate a stamp without running its recipe, so a dry run
conservatively lists the archive rebuilds, as it does for the pure-C test
host-child configuration stamp (`$(TITAN_TEST_BUILD_DIR)/native-flags.config`).

## Standard-library object graph

The phony `stdlib-objects` and `stdlib` targets always invoke `titanc`, which
discovers the module graph, certifies reusable source objects and final
artifacts, and schedules worker frontends and native compilations under
`-j$(TITAN_JOBS)`:

```sh
$(STDLIB_COMPILER_ENV) $(STDLIB_TITANC) --output $(TITAN_OUTPUT_DIR) \
  --source-first --incremental -j$(TITAN_JOBS) $(TITAN_VERBOSE_FLAG) \
  -c $(STDLIB_ROOTS)

$(STDLIB_COMPILER_ENV) $(STDLIB_TITANC) --output $(TITAN_OUTPUT_DIR) \
  --source-first --incremental -j$(TITAN_JOBS) $(TITAN_VERBOSE_FLAG) \
  $(STDLIB_ROOTS) -X $(STDLIB_EXTRA_OBJECTS)
```

`STDLIB_TITANC` is a complete compiler command (the installed `bin/titanc`,
or the checkout `titanc` run through `$(TITAN_LUA)` with
`SOURCE_COMPILER_SETUP` and `--lua`). It deliberately avoids the name `TITANC`:
the runtime reads `TITANC` as the single program its [SDK
fallback](driver.md#the-run-time-titan-path-and-sdk-fallback) starts, and GNU
Make exports a variable given on its command line into every recipe
environment, where any Lua host or compiled program a recipe runs would see it.

Make maintains no per-module Titan import rules, object or provider timestamp
prerequisites, completion stamps, or C-part split-policy stamps. Only `stdlib`
passes the `-X` native payload
(`libtitan-lpeglabel.a`, bundled `libuv.a`,
`libtitan-llhttp.a`, `libtitan-sqlite3.a`, and in bundled mode OpenSSL's
`libssl.a` and `libcrypto.a`), in the order fixed by the [standard-library
image](multi-module-libraries.md#reserved-titan-and-the-standard-library-image),
and produces the provider pair (`titan.so` and `titan.a`) under
`TITAN_OUTPUT_DIR` (default `out/`). The compiler's own source
record (`<stem>.o` `.titan.source`) certifies module sources, folder
membership, compiler and native flags, C-part split settings (`c_parts` and
`split_threshold`), split-part completeness, C headers, and dependency
interfaces, while `<output>/.titan-links/<key>/record` certifies the final
provider pair ([incremental
compilation](incremental-compilation.md)).

`STDLIB_USE_INSTALLED_RUNTIME` defaults to `1` when
`$(TITAN_INSTALL_TREE)/bin/titanc` exists. That selects the installed compiler,
runtime archives (`libtitan.a`, `libbacktrace.a`, `liblua.a`), and SDK headers;
`titanc` certifies those compiler, header, and archive contents directly.
`all` and `STDLIB_USE_INSTALLED_RUNTIME=0` select the checkout compiler and
checkout runtime instead; the checkout compiler loads the support module
`titan-runtime/bootstrap/titan.so` through the `package.cpath` entry that
`SOURCE_COMPILER_SETUP` prepends, and `all` clears `TITAN_ROOT` for that build.

`make clean-stdlib` removes `$(TITAN_OUTPUT_DIR)/titan`,
`$(TITAN_OUTPUT_DIR)/.titan-links`, `$(STDLIB_PROVIDER_OUTPUTS)`, and
`$(STDLIB_CONTAINER).dSYM`. Although `titanc --incremental` certifies compiler
and flag changes for Titan objects and links, authored runtime objects and
native dependency build directories other than libbacktrace and libuv (which
follow their [configuration stamps](#native-dependency-configuration-stamps))
still require `make clean` or separate source copies and SDKs when changing
tools, flags, profile, or OpenSSL mode.

### Native test aggregate and C fixture rules

`titan-stdlib-test-objects` and `titan-stdlib-test-build` are phony targets that
run from `$(TITAN_TEST_BUILD_DIR)` (default `out/tests`) after
`check-titan-test-sdk` verifies that `TEST_LUA` resolves an installed Titan SDK
with `titan.so` and creates the output directory:

```sh
TITAN_ROOT=$(TITAN_TEST_INSTALL_ROOT) \
$(TITAN_TEST_COMPILER_ENV) $(TEST_TITANC) --output . --test --incremental \
  -j$(TITAN_JOBS) $(TITAN_VERBOSE_FLAG) -c \
  --tree $(abspath spec/stdlib/titan) --test-dir $(abspath spec/stdlib/titan) \
  test.tests --c-source $(abspath spec/fixtures/stdlib/native/async_foreign_work.c) \
  --c-source $(abspath spec/fixtures/stdlib/native/fs_fixture.c) \
  --c-source $(abspath spec/fixtures/stdlib/native/uv_stdio_probe.c)

TITAN_ROOT=$(TITAN_TEST_INSTALL_ROOT) \
$(TITAN_TEST_COMPILER_ENV) $(TEST_TITANC) --output . --test --incremental \
  --no-uv-bootstrap -j$(TITAN_JOBS) $(TITAN_VERBOSE_FLAG) \
  --tree $(abspath spec/stdlib/titan) --test-dir $(abspath spec/stdlib/titan) \
  --exe $(abspath $(TITAN_TEST_EXECUTABLE)) test.tests \
  --c-source $(abspath spec/fixtures/stdlib/native/async_foreign_work.c) \
  --c-source $(abspath spec/fixtures/stdlib/native/fs_fixture.c) \
  --c-source $(abspath spec/fixtures/stdlib/native/uv_stdio_probe.c)
```

The compile-only recipe omits `--no-uv-bootstrap`: `titanc -c` rejects that
link-phase option, which belongs to the final link that generates the
entrypoint.

Both recipes, the fixed-fixture rule below, and the `titan-stdlib-test-run` and
`titan-stdlib-test-run-parallel` environments set `TITAN_ROOT` to
`TITAN_TEST_INSTALL_ROOT`, the installation that `TEST_LUA` resolves (shell
quoting omitted above). `TITAN_TEST_COMPILER_ENV` itself carries no root,
because it also reaches Busted. See [native SDK
selection](test-runner.md#native-sdk-selection).

`test.tests` is passed explicitly first so it remains the default executable
and provider owner (`out/tests/test/tests`); `--test-dir` discovers all 30
standard-library test roots under `spec/stdlib/titan` and deduplicates
`test.tests` ([automatic test-root
discovery](test-runner.md#automatic-test-root-discovery)). The 30-root list and
per-owner timing metadata in `spec/support/stdlib_test_modules.mk` serve
runtime scheduling and output auditing, not Make dependency rules. Only the
three aggregate C helpers (`async_foreign_work.c`, `fs_fixture.c`, and
`uv_stdio_probe.c`) are compiled into the aggregate via `--c-source` under
`out/tests/.native/`.

The fixed fixture objects (`uv_stdio_probe`, which is also an aggregate
`--c-source` helper, and the child-only `sqlite3_worker_fixture`,
`ssl_allocator_fixture`, `ssl_error_strings`, `os_descriptor_limit`, and on
Linux `transfer_alloc_fault`, `uv_sync_alloc_fault`, and
`thread_retirement_fault`) are linked by fresh child processes launched by
individual tests; the child-only helpers are excluded from the aggregate link.
Each `$(TITAN_TEST_BUILD_DIR)/<stem>.o` target (`titan_test_native_rule`)
depends on `spec/fixtures/stdlib/native/<stem>.c` and `FORCE`, invokes
`$(TEST_TITANC) -c --incremental --output
$(TITAN_TEST_BUILD_DIR)/native/<stem>.o -j$(TITAN_JOBS) $(TITAN_VERBOSE_FLAG)
--print-c-objects --cflag=-std=c99 --cflag=-Wall --cflag=-Wextra
--cflag=-Werror --cflag=-fPIC -I spec/fixtures/stdlib/native <per-helper
flags> --c-source <stem>.c` with `TITAN_ROOT=$(TITAN_TEST_INSTALL_ROOT)` and the
helper's `TITAN_EXTRA_CPPFLAGS`/`CFLAGS`/`LDFLAGS`, requires the single reported path to
be absolute and to name a file, and copies it to
`$(TITAN_TEST_BUILD_DIR)/<stem>.o` with `cp -p` only when `cmp -s` reports a
content difference. Native nodes are keyed by canonical source path, so a
moved checkout leaves nodes for its old location in the per-helper output
tree; only the compiler-reported path selects the fixed copy. The installed
compiler supplies its matching Lua and runtime SDK include directories
automatically, and a certified hit leaves the fixed `.o` path and timestamp
untouched.

The pure-C `$(TITAN_TEST_BUILD_DIR)/os_process_host_child` executable is a
direct `$(CC)` rule that depends only on
`spec/fixtures/stdlib/native/os_process_host_child.c` and
`$(TITAN_TEST_BUILD_DIR)/native-flags.config` (`TITAN_TEST_CONFIG_STAMP`,
recording `CC`, `CPPFLAGS`, `CFLAGS`, and `LDFLAGS` and replaced only when
`cmp -s` detects a change). Staging rules copy the authored fixture headers into
`$(TITAN_TEST_BUILD_DIR)/` for child compiler invocations. Neither the pure-C
child nor the fixture headers depend on installed compiler or provider
timestamps.

`titan-native-coverage-build` runs from `$(TITAN_COVERAGE_BUILD_DIR)` (default
`out/coverage`) and invokes `$(TEST_TITANC) --output . --test --incremental
--no-uv-bootstrap --coverage -j$(TITAN_JOBS)` with `--coverage-module
'titan.*'`, `--tree $(abspath spec/stdlib/titan);$(CURDIR)`, `--test-dir
$(abspath spec/stdlib/titan)`, `--exe $(TITAN_COVERAGE_EXECUTABLE) test.tests`,
the three aggregate `--c-source` helpers, and `-X $(STDLIB_EXTRA_OBJECTS)`
([native coverage](native-coverage.md#repository-integration-and-verification)).

## Make job pool and titanc recipes

`TITAN_JOBS` (Make default `TITAN_JOBS ?= 4`, or `1` on GNU Make before 4.2;
see below) is the local job cap that every recipe launching `titanc` passes as
`-j$(TITAN_JOBS)`: `stdlib-objects`, `stdlib`, `titan-stdlib-test-objects`,
`titan-stdlib-test-build`, `titan-native-coverage-build`, and each child-only
`titan_test_native_rule`. `TITAN_JOBS_CHECK` rejects a value that is not a
positive integer before any work starts, and each compiler recipe unsets
`LUA_PATH`, `LUA_CPATH`, `LUA_PATH_5_5`, and `LUA_CPATH_5_5`. Each of these
recipes (along with `busted-test`, `rock-test`, and `test`) is marked `+`, so
`titanc` receives Make's jobserver and can borrow job slots for concurrent
module-frontend workers and native compiler processes beyond its recipe's own
slot; the protocol is owned by the [driver](driver.md). The `+` marker also
keeps a pipe jobserver's descriptors open through the wrapper layers, which
GCC's `-flto=auto` link steps need as well.

`+` makes Make run a recipe even under `make -n`, `-q`, or `-t`, so each of
these recipes starts with `RECURSIVE_WRAPPER_GUARD` before any other command,
such as `mkdir` or `cd` into an output directory that a dry run has not
created. The guard scans `MAKEFLAGS` up to a standalone `--`: under `q` it
exits 1 (out of date), under `n` or `t` it exits 0, and in both cases nothing
is launched. The mode letters appear in GNU Make 4's leading flag word (`kn`)
and, when a long option is present, in GNU Make 3.81's dash words (`-nk`). Only
words consisting entirely of Make's no-argument flag letters count. GNU Make
3.81 passes command-line `NAME=value` overrides without a preceding `--` when
no flag is set, and option arguments such as `-Onone` or `-I/tmp/include` may
contain `n`, `q`, or `t`; neither is mistaken for a mode.

Because each Titan build target invokes a single `titanc` coordinator that owns
its module graph and `-j$(TITAN_JOBS)` slot ledger, `Makefile` does not recurse
into Make sub-graphs to seed a jobserver pool for standalone `stdlib` or
`titan-stdlib-test-build` invocations. Pool seeding in Make is used only by the
mixed Busted/native test launcher (`spec/support/run_parallel_compiler_tests.sh`).

GNU Make before 4.2, including macOS's stock 3.81, never shows a job count in
`MAKEFLAGS`, so a recipe cannot tell `make -j1` from plain `make`. The Makefile
recognizes these versions from `MAKE_VERSION` (`TITAN_MAKE_HIDES_JOBS`,
matching `3.%`, `4.0`, and `4.1`). When `TITAN_JOBS` there comes only from the
Makefile default, that is, its `$(origin)` is `file`
(`TITAN_JOBS_SERIAL_DEFAULT`), the Makefile sets `TITAN_JOBS := 1`, so `make`
and `make -j1` both invoke `titanc` with `-j1`. Setting `TITAN_JOBS` in the
environment or on the command line passes that explicit `-j$(TITAN_JOBS)` bound
to `titanc`.

Inside `titanc`, `jobs.open_slots` combines the local `--jobs`/`TITAN_JOBS` cap
with any inherited `MAKEFLAGS` policy:

- With no inherited jobserver, `titanc` runs up to `TITAN_JOBS` concurrent
  frontend workers and native compiler jobs in its own local ledger.
- Under `make -j1` on GNU Make 4.2 or later (`MAKEFLAGS` shows `-j1` without a
  jobserver), `titanc` caps concurrency at 1 regardless of `TITAN_JOBS`.
- With a shareable parent jobserver — GNU Make 4.4 or later's named FIFO
  (`--jobserver-auth=fifo:PATH`) on Linux and macOS, or a pipe jobserver on
  Linux where `/proc/self/fd/<fd>` can be reopened privately — `titanc` shares
  the parent pool up to its local `TITAN_JOBS` cap: the first active job uses
  the recipe's implicit slot and each additional active job holds one borrowed
  token byte.
- With a valid inherited pipe jobserver on a platform that cannot reopen the
  pipe privately (macOS with GNU Make before 4.4), `jobs.unshareable_pipe_limit`
  warns once on stderr and uses `titanc`'s own local `--jobs`/`TITAN_JOBS` cap
  outside the parent's pool, without modifying the parent's shared pipe
  descriptor flags or serializing to one job. Sharing a parent Make pool on
  macOS requires GNU Make 4.4 or later's FIFO jobserver.
- With an invalid or closed jobserver specification (such as a recipe missing
  `+`), `titanc` warns once and runs one job at a time.

The resulting policy:

| Invocation | Concurrency |
| --- | --- |
| `make stdlib`, `make titan-stdlib-test-build` | GNU Make 4.2 or later: `titanc` uses its local `TITAN_JOBS` (four) cap. Earlier GNU Make: `titanc` runs with `-j1` unless `TITAN_JOBS` is set explicitly. |
| `luarocks make`, `luarocks install` from source | The rock's `all` target runs `$(MAKE) stdlib` without `-j`, so the same policy as `make stdlib`. |
| `make -j8 stdlib` | On Linux or GNU Make 4.4+, `titanc` shares the caller's eight-slot pool, capped at `TITAN_JOBS` (raise `TITAN_JOBS=8` to use all eight inside one `titanc`). On macOS with GNU Make before 4.4 (pipe jobserver), `titanc` warns once and uses its local `TITAN_JOBS` cap (`1` on Make before 4.2 unless `TITAN_JOBS` is set). |
| A recipe of a parent `make -jN` | Shares the parent's FIFO or Linux pipe pool up to `TITAN_JOBS`; on macOS pipe Make, uses the local `TITAN_JOBS` cap. |
| GNU Make 4.2 or later, `make -j1 stdlib` | Serial: `titanc` sees `-j1` in `MAKEFLAGS` and runs one job at a time. |
| GNU Make before 4.2, `make stdlib` or `make -j1 stdlib` | Serial: `TITAN_JOBS` defaults to `1` and `titanc` runs with `-j1`. |
| GNU Make before 4.2, `TITAN_JOBS=4 make stdlib` | `titanc` uses its local four-slot cap, with or without `-j1`. |
| `make -n`, `-q`, or `-t` | `RECURSIVE_WRAPPER_GUARD` exits before any `titanc` or test wrapper launches (`-q` exits 1, `-n` and `-t` exit 0). |

macOS users get the four-job default either with GNU Make 4.2 or later first on
`PATH` (Homebrew's `make` formula installs GNU Make 4.4+ as `gmake`, and as
`make` in the formula's `libexec/gnubin` directory, which also supplies the
shareable FIFO jobserver) or by setting `TITAN_JOBS`.

The Busted launcher (`spec/support/run_parallel_compiler_tests.sh`) applies the
same rule to its workers and the native build it overlaps. On GNU Make before
4.2 with the serial default, `rock-test` and `busted-test` pass the launcher no
`TITAN_JOBS`; it then seeds a private pool with one slot per Busted worker plus
one for the native build (four at the defaults), so the workers never wait for
each other, while the native build's `titanc` invocation stays at one job. The
parallel native run that follows uses its own `TITAN_TEST_JOBS` processes; see
[Busted partitions](test-runner.md#busted-partitions). CI keeps explicit caps
(`MAKEFLAGS=-j2` and `TITAN_JOBS=2` on two-vCPU Linux runners, four on the
four-vCPU lanes, three on hosted macOS); see [continuous
integration](continuous-integration.md#linux-job-graph-and-concurrency).
`Makefile.win` stays `.NOTPARALLEL`, guards its compiler/test wrapper recipes
with `+` and `RECURSIVE_WRAPPER_GUARD`, and delegates native parallelism to
`titanc` and its build scripts, whose `TITAN_JOBS` default is also four; see
[Windows native build parallelism](windows-build.md#native-build-parallelism).

## Installation and publication

| Target | Effect |
| --- | --- |
| `install-compiler` | Compiler Lua modules (`INST_LUADIR`), `titanc` (`INST_BINDIR`), third-party notices (`INST_CONFDIR`), and the support module `titan.so` (`INST_LIBDIR`, default `<root>/lib/lua/5.5`). When the including Makefile sets `TITANC_NATIVE` (`Makefile.win`), it installs that native frontend as `bin/titanc.exe` and the `titanc` script as `INST_LUADIR/titan-compiler/titanc.lua` instead. A direct install builds the support module first; the LuaRocks install pass only copies it. |
| `install-compiler-sdk` | `install-compiler` plus the runtime archive, Lua SDK and Titan headers, with no standard library; records the profile in `etc/titan/build-profile`. |
| `install-titan-sdk` / `publish-titan-sdk` | Build then copy / copy only the native SDK: runtime, libuv, llhttp and SQLite headers, and OpenSSL headers in bundled mode. |
| `stdlib` / `stdlib-objects` | Build the provider pair / compile objects only. |
| `install-stdlib` / `publish-stdlib` | Build then copy / copy an already built `STDLIB_INSTALL_STAGE` (default `TITAN_OUTPUT_DIR`) without rebuilding or validating it. |
| `install` (no `INST_PREFIX`) | `install-compiler`, `publish-titan-sdk`, `publish-stdlib`. |
| `install` (LuaRocks pass) | `install-compiler`, `install-rock-tools`, `stage-rock-payload`. |
| `binary-rock` | `luarocks pack titan`, renaming the `.all.rock` result to the suffix from `luarocks config arch`. |

Standard-library installation copies the built provider pair, licenses, and
optional symbols. SDK installation also publishes Titan's own `LICENSE` at
`<root>/share/titan/LICENSE`. The SDK never contains `libuv.a`: the bundled
libuv archive is private payload of the standard provider. Installation keeps
no receipt and does no predecessor classification, metadata scan, or rollback.
When `TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT` is set, the shared
`install-stdlib`/`publish-stdlib` recipe first snapshots the staged provider and
its generated C/object pairs for sanitizer failure mapping; see [continuous
integration](continuous-integration.md#sanitizer-ownership-and-failure-diagnostics).
Compiler provider publication is a separate compiler contract with its own
regression tests; see [static compiled
modules](static-compiled-modules.md#publication-and-installation).

The support module (`TITAN_SUPPORT_MODULE`, `titan-runtime/bootstrap/titan.so`;
`<WINDOWS_BUILD_ROOT>/runtime/titan.dll` on Windows) links only `ltitanlib.o`
and `titan_path.o` with `$(ROCK_LD) $(ROCK_LIBFLAG)` and exports only
`luaopen_titan`. The Unix link enforces that with
`TITAN_SUPPORT_EXPORT_FLAGS`: the version script
`scripts/titan_support_exports.map` (`global: luaopen_titan; local: *;`) on
ELF platforms and `-Wl,-exported_symbol,_luaopen_titan` on macOS. Windows links
the DLL with `-Wl,--exclude-all-symbols` and an explicitly `dllexport` opener.
`titan_path.o`'s global functions therefore stay local to the support image, so
a process that also links `libtitan.a`, such as the language server, cannot
interpose them; `libtitan.a` itself keeps default visibility. The support
module is built before the compiler or standard library needs it;
no SDK target seeds it, or any provider, into `lib/titan/0.6`. Both objects are
also members of `libtitan.a` (`TITAN_RUNTIME_OBJECTS`, in the order `titan.o
minicoro.o titan_path.o ltitanlib.o`); the standard provider does not carry
`ltitanlib.o`.

LuaRocks runs the install pass (`install` with `INST_PREFIX` set, and the
matching `Makefile.win` target) in the same source directory as the build
pass; it copies without compiling. Compiler Lua modules go to `INST_LUADIR`,
the support module to `INST_LIBDIR`, and `titanc` and `titan-uninstall` to
`INST_BINDIR` (`install-rock-tools`); on Windows the compiler entry there is
`titanc.exe` and the script goes to `INST_LUADIR` as
`titan-compiler/titanc.lua`. The rockspec passes
`INST_LIBDIR = "$(LIBDIR)"`, so LuaRocks stages the support module in the rock's
`lib` directory, deploys it to `<tree>/lib/lua/5.5/titan.so`, records it in
`rock_manifest`, and removes it with the rock like any other native Lua module.
`scripts/install_compiler.mk` installs it under the last path component of
`TITAN_SUPPORT_MODULE`, so a build root containing spaces cannot split the
name. `stage-rock-payload` keeps the built SDK
and provider pair under `<rock-prefix>/titan-sdk`. The rockspec's
`post_install` hook runs `<rock-prefix>/installer/titan_install.lua` by
absolute path to copy that payload into the canonical SDK locations; it needs no
source directory, Makefile or compiler. Its installed-SDK digest bootstrap
(`publish_sdk_digests`) loads the support module with `package.cpath` set to
exactly `<tree>/lib/lua/5.5/?.so` (`?.dll` on Windows), which LuaRocks has
already deployed. On Windows, the copier also deletes the unrecorded
`bin/titanc.lua` package-path helper that LuaRocks writes beside a deployed
`.exe` (only that generated two-line form; see the [Windows compiler
bootstrap](windows-build.md#runtime-sdk-and-compiler-bootstrap)). Binary rocks
carry the same payload and copier. The canonical SDK and providers therefore
stay outside LuaRocks' manifest. The rockspec uses `build.type = "make"` and
declares no `modules`.

`titan-uninstall` (`scripts/titan_install.lua`) removes all installed Titan
rock versions through LuaRocks first. Only when that succeeds does it remove
the exact external Titan files; Lua, LuaRocks, dependency modules and shared
native dependencies remain. Windows callers must close processes that use a
destination DLL before replacing or removing it.

## Checks

Explicit PE, SDK, compiler, launcher, runtime, provider, and native-suite
checks live in `spec/support` and run through check/test targets; ordinary
build and install recipes inspect no artifacts. The operational Windows scripts
in `scripts/` cover LuaRocks acquisition, native source preparation and
building, libbacktrace and runtime compilation, stdlib compilation, and profile
selection.
