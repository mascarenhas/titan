# Build and installation responsibilities

`Makefile` is the Linux/macOS entry point. `Makefile.win` is the Windows entry
point for direct builds and for LuaRocks' make backend, which the rockspec
selects on Windows. LuaRocks owns the compiler's Lua dependencies and
source-rock deployment on all three platforms. `scripts/install_compiler.mk`
holds the compiler, rock-tool and `binary-rock` rules shared by both Makefiles.

This chapter is the canonical home for Lua preparation, the standard-library
Make object graph, the private bootstrap, and LuaRocks installation,
`post_install`, binary rocks and uninstall. The standard-library root list and
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
uses the checkout's `.lua-validation`, and a production invocation discovers a
Titan Lua prefix from `PATH` (`scripts/detect_lua_prefix.sh`), falling back to
`/usr/local`. `TITAN_INSTALL_TREE`, the destination of the Titan SDK and
providers, is `ROCKS_TREE` when that is set and `PREFIX` otherwise in the Unix
`Makefile`; `Makefile.win` always uses `PREFIX`.

Ordinary native archives use source/header prerequisites and `ar`/`ranlib`.
Failed output recipes remove unfinished artifacts before an ordinary retry.
CMake owns libuv incrementality; upstream configure/make owns libbacktrace and
bundled OpenSSL. Both Makefiles default to `OPENSSL_MODE=system`, which uses an
installed OpenSSL SDK. The Windows runtime build compiles its eight inputs
directly. Versioned source acquisition retains checksums and the required
upstream corrections.

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
conservatively lists the archive rebuilds, as it does for the native test
configuration stamp.

## Standard-library object graph

Make owns one object target per standard module, including one per folder
ensemble (`Makefile` `stdlib_object_rule`). Each stale target runs
`titanc --source-first --incremental -j$(TITAN_JOBS) -c titan.<module>` on its
own logical root and reuses the dependency objects Make already built. The
recipe shares Make's job pool; see [Make job pool and titanc
recipes](#make-job-pool-and-titanc-recipes). `make stdlib-objects` runs this
graph without linking. One final source-first incremental link, guarded by
`STDLIB_COMPLETION_STAMP`, then produces the provider pair and shims under
`TITAN_OUTPUT_DIR` (default `out/`). Only that link passes the `-X` native
payload, in the order fixed by the [standard-library
image](multi-module-libraries.md#reserved-titan-and-the-standard-library-image).
Every run of the link recipe also deletes exact per-module child DSOs
(`STDLIB_SOS`, `STDLIB_QUALIFIED_SOS`, and their `.dSYM` bundles) as stale
production outputs; the standard library ships only the combined pair.

Each object and the completion stamp depend on `FORCE`, which runs an
inexpensive completeness check: a missing or symlinked generated companion
makes the target stale, while unchanged outputs keep their timestamps. The
graph uses no grouped targets, so it also runs with the GNU Make that macOS
ships. Published providers and shims are outputs, not prerequisites.

The compiler publishes a `<stem>.parts` companion with every compiled module.
It exists for build tools: Make reads it, and the compiler's incremental loader
never does. Each module object's `FORCE` guard (`CHECK_TITAN_PARTS_COMPANION`)
requires the companion to be a regular, non-symlink file whose first line is
exactly `titan-parts-v1 K` with a positive `K`, followed by exactly the leaves
the compiler derives for `K` parts, in order: `<leaf>.priv.h` only when `K` is
at least two, `<leaf>.c`, `<leaf>.o`, then `<leaf>.partN.c` and
`<leaf>.partN.o` for each `N` from 1 to `K-1`. An unsplit module's companion is
therefore `titan-parts-v1 1`, `<leaf>.c`, `<leaf>.o`. Each listed leaf must be a
regular, non-symlink file beside the companion, and no line may follow. A
missing, symlinked, malformed, or incomplete companion, or a missing part,
makes the whole module stale: the recipe removes `<stem>.o` and `<stem>.parts`
before recompiling, and fails if the compiler did not publish a complete
companion. A direct object target such as `make out/titan/uv/uv.o` therefore
repairs a deleted part, private header, or companion by itself, without
depending on a later link. The companion only makes this Make check cheap;
compiler reuse trusts only the object's `.titan.source` record ([trusted source
record](incremental-compilation.md#trusted-source-record)). The native test
object rule (`titan_test_object_rule`) applies the same check under
`out/tests`.

`STDLIB_USE_INSTALLED_RUNTIME` defaults to `1` when
`$(TITAN_INSTALL_TREE)/bin/titanc` exists. That selects the installed compiler,
runtime archive and SDK; installed compiler Lua files, the compiler script and
SDK headers invalidate objects, and the runtime archive also invalidates the
final link. `all` and `STDLIB_USE_INSTALLED_RUNTIME=0` select the checkout
compiler, checkout runtime and private bootstrap instead.

`make clean-stdlib` clears the graph and provider outputs. Run it before
changing tools, flags, profile, or OpenSSL mode. Also clean the affected native
build directories other than libbacktrace and libuv, which follow their
[configuration stamps](#native-dependency-configuration-stamps), or use
separate source copies and SDKs.

## Make job pool and titanc recipes

`TITAN_JOBS` (Make default `TITAN_JOBS ?= 4`, or one on GNU Make before 4.2;
see below) is the local job cap that every recipe launching `titanc` passes as
`-j$(TITAN_JOBS)`: standard-library objects, the provider link, native test
objects, the native test executable, and the native coverage build.
`TITAN_JOBS_CHECK` rejects a value that is not a positive integer before any
work starts. Each of these recipes is marked `+`, so `titanc` receives Make's
jobserver and can borrow job slots for further concurrent compilations or
links beyond its recipe's own slot; the protocol is owned by the
[driver](driver.md). The `+` marker also keeps a pipe jobserver's
descriptors open through the wrapper layers, which GCC's `-flto=auto` link
steps need as well. Before launching anything, the object recipes run the
`.parts` completeness guard described in the [standard-library object
graph](#standard-library-object-graph).

`+` makes Make run a recipe even under `make -n`, `-q`, or `-t`, so each of
these recipes starts with `RECURSIVE_WRAPPER_GUARD`, before any other command
such as the coverage build's `cd` into an output directory that a dry run has
not created. The guard scans `MAKEFLAGS` up to a standalone `--`: under `q` it
exits 1 (out of date), under `n` or `t` it exits 0, and in both cases nothing
is launched. The mode letters
appear in GNU Make 4's leading flag word (`kn`) and, when a long option is
present, in GNU Make 3.81's dash words (`-nk`). Only words consisting entirely
of Make's no-argument flag letters count. GNU Make 3.81 passes command-line
`NAME=value` overrides without a preceding `--` when no flag is set, and option
arguments such as `-Onone` or `-I/tmp/include` may contain `n`, `q`, or `t`;
neither is mistaken for a mode.

The graph entries `stdlib`, `stdlib-objects`, `titan-stdlib-test-objects`, and
`titan-stdlib-test-build` each build an internal `<entry>-graph` target and
enter at most one job pool for the whole graph:

1. When GNU Make before 4.2 keeps its serial `TITAN_JOBS` default (below), or
   the `MAKEFLAGS` visible while Make parses the file already show a job
   policy (`-jN`, unlimited `-j`, `--jobserver-auth=`, or `--jobserver-fds=`)
   or a dry-run, query, or touch mode, the entry depends on its graph directly
   (`TITAN_MAKE_GRAPH_RECURSE` is empty).
2. Otherwise the entry's recipe recurses once, with `+`, into
   `$(MAKE) --no-print-directory -f Makefile <entry>-graph` and decides the
   pool from the recipe's `MAKEFLAGS` (`TITAN_MAKE_POOL`). An inherited
   jobserver or an explicit `-j` word, including GNU Make 3.81's unlimited
   `j` flag letter, keeps the caller's policy. Otherwise the recursion seeds
   one pool with `-j$(TITAN_JOBS)`.

The second step exists because GNU Make 3.81 exposes neither `-jN` nor its
jobserver while parsing: its recipes see ` --jobserver-fds=R,W -j` under
`make -jN`, and nothing under `make -j1`. GNU Make 4 shows `-jN` while parsing
and adds `--jobserver-auth=` in recipes.

GNU Make before 4.2, including macOS's stock 3.81, never shows a job count in
`MAKEFLAGS`, so even a recipe cannot tell `make -j1` from plain `make`. The
Makefile recognizes these versions from `MAKE_VERSION`
(`TITAN_MAKE_HIDES_JOBS`). When `TITAN_JOBS` there comes only from the
Makefile default, that is, its `$(origin)` is `file`
(`TITAN_JOBS_SERIAL_DEFAULT`), the Makefile sets it to one: no graph entry
seeds a pool, and every `titanc` recipe compiles one C unit at a time, so
`make` and `make -j1` both build serially. A `TITAN_JOBS` from the
environment or the command line seeds its pool exactly as on newer Make,
including under `make -j1`, which this Make cannot show. An explicit
`make -jN` keeps the caller's pool either way.

The resulting policy:

| Invocation | Pool |
| --- | --- |
| `make stdlib`, `make titan-stdlib-test-build` | GNU Make 4.2 or later: one seeded pool of `TITAN_JOBS` (four) slots. Earlier GNU Make: serial, with one job per `titanc`, unless `TITAN_JOBS` is set. |
| `luarocks make`, `luarocks install` from source | The rock's `all` target runs `$(MAKE) stdlib` without `-j`, so the same policy as `make stdlib`. |
| `make -j8 stdlib` | The caller's eight slots; each `titanc` remains capped at `TITAN_JOBS`. |
| A recipe of a parent `make -jN` | The parent's pool; nested graph entries never seed or reset a pool, so budgets do not multiply. |
| GNU Make 4.2 or later, `make -j1 stdlib` | Serial: one recipe at a time, and `titanc` sees `-j1` without a jobserver and compiles serially. |
| GNU Make before 4.2, `make stdlib` or `make -j1 stdlib` | Serial: no pool, one recipe at a time, and each `titanc` runs with `-j1`. |
| GNU Make before 4.2, `TITAN_JOBS=4 make stdlib` | One seeded pool of four slots, with or without `-j1`. |
| `make -n`, `-q`, or `-t` | No recursion, no pool, and no `titanc` launch. |
| `make out/titan/uv/uv.o` | That object's recipe alone, with no graph entry; with no jobserver, `titanc` uses its own `TITAN_JOBS` cap. |

macOS users therefore get the four-job default either with GNU Make 4.2 or
later first on `PATH` (Homebrew's `make` formula installs it as `gmake`, and
as `make` in the formula's `libexec/gnubin` directory) or by setting
`TITAN_JOBS`. Under a macOS pipe jobserver (GNU Make before 4.4), `titanc`
cannot reopen the pipe and compiles each module with one job, but Make still
runs independent module recipes concurrently from the pool. GNU Make 4.4 or
later provides parallel parts inside a module as well.

The Busted launcher applies the same rule to its workers and the native build
it overlaps. On GNU Make before 4.2 with the serial default, `rock-test` and
`busted-test` pass the launcher no `TITAN_JOBS`; it then seeds a private pool
with one slot per Busted worker plus one for the native build (four at the
defaults), so the workers never wait for each other, while the native build's
`titanc` recipes stay at one job. The parallel native run that follows uses
its own `TITAN_TEST_JOBS` processes; see [Busted
partitions](test-runner.md#busted-partitions). CI keeps explicit caps
(`MAKEFLAGS=-j2` and `TITAN_JOBS=2` on two-vCPU Linux runners, four on the
four-vCPU lanes, three on hosted macOS); see [continuous
integration](continuous-integration.md#linux-job-graph-and-concurrency).
`Makefile.win` stays `.NOTPARALLEL` and delegates native parallelism to
`titanc` and its build scripts, whose `TITAN_JOBS` default is also four; see
[Windows native build parallelism](windows-build.md#native-build-parallelism).

## Installation and publication

| Target | Effect |
| --- | --- |
| `install-compiler-sdk` | Compiler, runtime archive, headers and bare bootstrap support, with no standard library; records the profile in `etc/titan/build-profile`. |
| `install-titan-sdk` / `publish-titan-sdk` | Build then copy / copy only the native SDK: runtime, libuv, llhttp and SQLite headers, and OpenSSL headers in bundled mode. |
| `stdlib` / `stdlib-objects` | Build the provider pair and shims / compile objects only. |
| `install-stdlib` / `publish-stdlib` | Build then copy / copy an already built `STDLIB_INSTALL_STAGE` (default `TITAN_OUTPUT_DIR`) without rebuilding or validating it. |
| `install` (no `INST_PREFIX`) | `install-compiler`, `publish-titan-sdk`, `publish-stdlib`. |
| `install` (LuaRocks pass) | `install-compiler`, `install-rock-tools`, `stage-rock-payload`. |
| `binary-rock` | `luarocks pack titan`, renaming the `.all.rock` result to the suffix from `luarocks config arch`. |

Standard-library installation copies the built provider, shims, licenses, and
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

`stage-titan-bootstrap` copies the private runtime bootstrap into the
canonical provider path only when no provider exists there, preserving an
installed full standard library. The SDK targets depend on it. The source-rock
`all` target builds the standard library with the private bootstrap and never
publishes the bootstrap.

LuaRocks runs the install pass (`install` with `INST_PREFIX` set, and the
matching `Makefile.win` target) in the same source directory as the build
pass; it copies without compiling. Compiler Lua modules and generated
standard-library shims go to `INST_LUADIR`; `titanc` and `titan-uninstall` go to
`INST_BINDIR` (`install-rock-tools`). `stage-rock-payload` keeps the built SDK
and provider pair under `<rock-prefix>/titan-sdk`. The rockspec's
`post_install` hook runs `<rock-prefix>/installer/titan_install.lua` by
absolute path to copy that payload into the canonical SDK locations; it needs no
source directory, Makefile or compiler. Binary rocks carry the same payload and
copier. The canonical SDK and providers therefore stay outside LuaRocks'
manifest. The rockspec uses `build.type = "make"` and declares no `modules`, so
there is no LuaRocks-manifest C module named `titan`.

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
