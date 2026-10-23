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

Neither upstream build notices changed flags in an existing build tree, so the
Unix `Makefile` records each archive's configuration in a stamp that only that
archive depends on. `libbacktrace/.titan-build.config` holds
`TITAN_BUILD_PROFILE`, `CC`, `AR`, `RANLIB`, and `LIBBT_CFLAGS`;
`libuv-build/.titan-build.config` holds `CC`, `LIBUV_CMAKE_FLAGS` (with
`LIBUV_BUILD_TYPE`), and `LIBUV_BUILD_CFLAGS`. Each stamp depends on `FORCE`:
its recipe writes the current configuration to a temporary file and replaces
the stamp only when the content differs (`cmp`, then `mv`). An unchanged
configuration therefore keeps the stamp's timestamp, and a second `make`
rebuilds neither archive nor anything that depends on them, such as the runtime
SDK and the standard-library objects (`STDLIB_TOOL_PREREQS`). A changed
configuration rebuilds exactly the affected archive once, from a clean
`make clean` libbacktrace tree or a discarded libuv CMake cache, and then its
ordinary dependents. A tree built before these stamps existed rebuilds both
archives once. `make -n` cannot evaluate a stamp without running its recipe,
so a dry run conservatively lists the archive rebuilds, as it does for the
native test configuration stamp.

## Standard-library object graph

Make owns one object target per standard module, including one per folder
ensemble (`Makefile` `stdlib_object_rule`). Each stale target runs
`titanc --source-first --incremental -j1 -c titan.<module>` on its own logical
root and reuses the dependency objects Make already built. `make
stdlib-objects` runs this graph without linking. One final source-first
incremental link, guarded by `STDLIB_COMPLETION_STAMP`, then produces the
provider pair and shims under `TITAN_OUTPUT_DIR` (default `out/`). Only that
link passes the `-X` native payload, in the order fixed by the [standard-library
image](multi-module-libraries.md#reserved-titan-and-the-standard-library-image).
Every run of the link recipe also deletes exact per-module child DSOs
(`STDLIB_SOS`, `STDLIB_QUALIFIED_SOS`, and their `.dSYM` bundles) as stale
production outputs; the standard library ships only the combined pair.

Each object and the completion stamp depend on `FORCE`, which runs an
inexpensive completeness check: a missing or symlinked generated companion
makes the target stale, while unchanged outputs keep their timestamps. The
graph uses no grouped targets, so it also runs with the GNU Make that macOS
ships. Published providers and shims are outputs, not prerequisites.

`STDLIB_USE_INSTALLED_RUNTIME` defaults to `1` when
`$(TITAN_INSTALL_TREE)/bin/titanc` exists. That selects the installed compiler,
runtime archive and SDK; installed compiler Lua files, the compiler script and
SDK headers invalidate objects, and the runtime archive also invalidates the
final link. `all` and `STDLIB_USE_INSTALLED_RUNTIME=0` select the checkout
compiler, checkout runtime and private bootstrap instead.

`make clean-stdlib` clears the graph and provider outputs. Run it before
changing tools, flags, profile, or OpenSSL mode, clean the affected native build
directories other than libbacktrace and libuv (which follow their
[configuration stamps](#native-dependency-configuration-stamps)) too, or use
separate source copies and SDKs.

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
