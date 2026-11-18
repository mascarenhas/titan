# Installing and using Titan on Windows

The native x64 Windows port is experimental. Build from an MSYS2 **CLANG64**
shell with the UCRT Clang toolchain, native GNU Make 4.3 or newer
(`mingw32-make`), CMake, Ninja, Perl, Git, Bash, tar, curl, unzip, and ordinary
Unix utilities. Keep Windows build outputs separate from Unix outputs. The
[implementation guide](../implementation/windows-build.md) describes the
controlled Lua DLL, dependency SDK, build targets, and native validation gates.

## Install from source

Choose an absolute SDK prefix. Windows source and binary rock installations
require the Lua SDK and rocks tree to be the same physical directory. The
following commands install the pinned Titan Lua 5.5.1 fork, standalone LuaRocks
3.13.0, and the Titan compiler, its Lua support module, and the standard
library:

```sh
git submodule update --init --recursive
mingw32-make -f Makefile.win lua PREFIX=/c/Titan/sdk
mingw32-make -f Makefile.win luarocks PREFIX=/c/Titan/sdk
mingw32-make -f Makefile.win compiler PREFIX=/c/Titan/sdk
```

OpenSSL defaults to an installed binary SDK, normally the MSYS2
`mingw-w64-clang-x86_64-openssl` package under `/clang64`. Install it with
`pacman -S mingw-w64-clang-x86_64-openssl`, or supply `OPENSSL_PREFIX` for
another compatible x64 UCRT/GNU OpenSSL 3 SDK. `OPENSSL_MODE=bundled` instead
builds the pinned source and also needs MSYS GNU Make (`pacman -S make`). Pass
these selections to the `compiler` command. The other native dependencies are
prepared by the source-rock build.

The default [build profile](build-profiles.md) is `production`. Use separate
SDK prefixes and `WINDOWS_BUILD_ROOT` directories for different profiles.
The Windows build root defaults to `out/windows` for production and
`out/windows-validation` for validation, beneath the checkout. The standard
provider's generated files go into that root's `out/` subdirectory; installation
publishes the provider DLL into the selected SDK's `lib/titan/0.6`, and
compiler installation places the support module at `lib/lua/5.5/titan.dll`.
Lua and LuaRocks targets reuse an existing program under `PREFIX/bin`; clean
the corresponding private build outputs and remove or replace the installed
program when changing native inputs. Close consumers before replacing a mapped
provider DLL.

## Invoke standalone LuaRocks

The Make targets select the generated LuaRocks configuration automatically.
For direct commands, set `LUAROCKS_CONFIG`; placing the executable in `bin`
does not make it discover the adjacent SDK configuration:

```sh
export LUAROCKS_CONFIG="$(cygpath -m /c/Titan/sdk/etc/luarocks/config-5.5.lua)"
/c/Titan/sdk/bin/luarocks.exe make titan-0.6.0-1.rockspec
```

The equivalent setting in PowerShell is:

```powershell
$env:LUAROCKS_CONFIG = "C:/Titan/sdk/etc/luarocks/config-5.5.lua"
```

The generated configuration supplies Lua 5.5, the SDK rock tree, its
`liblua55.a` import library, and the CLANG64 native tools. Compatible existing
Lua and LuaRocks installations can build the source rock with their own
configuration, using the same physical Lua and rocks prefix. LuaRocks owns the
compiler, its dependencies, and the `titan.dll` support module in
`lib/lua/5.5`; the rock's copy-only installation helper publishes the retained
native SDK/provider payload to canonical SDK paths.

## The Lua DLL and C helpers

The Windows Lua DLL `lua55.dll` is built from unmodified upstream Lua 5.5.1
sources with `-DLUA_BUILD_AS_DLL` and linked with `-Wl,--export-all-symbols`,
so it exports the internal Lua functions and data that generated Titan code
uses, not only the public API. A Lua 5.5.1 DLL built the same way, with the
default numeric configuration, is compatible.

Code that Titan compiles itself (generated modules, entrypoints and launchers,
C probes, and the runtime) imports those internals explicitly with
`-DLUA_BUILD_AS_DLL "-DLUAI_FUNC=__declspec(dllimport) extern"
"-DLUAI_DDEC(dec)=__declspec(dllimport) extern dec" -DLUAI_DDEF=`. Your own
`--c-source` helpers do not receive these definitions: they compile with stock
Lua conventions, like any third-party Lua C module. Public `lua_*`/`luaL_*`
functions work as usual. To export a `luaopen_*` function or other
`LUALIB_API` definition from a helper, define `LUA_LIB` or mark it
`__declspec(dllexport)`: under `LUA_BUILD_AS_DLL` without `LUA_LIB`, stock
`LUAMOD_API` declares an import and an opener defined with it does not
compile. A helper that touches Lua internals relies on MinGW auto-import or
supplies the `LUAI_*` import definitions itself, and may reuse `LUAI_FUNC` for
its own private symbols.

## Compile and distribute programs

The compiler is the native program `bin/titanc.exe`. With the SDK's `bin` on
`PATH`, use `titanc` for the ordinary [module and program
commands](modules.md#experimental-windows-compilation). It always runs the
compiler installed in its own SDK, ignoring `LUA_INIT` and the
`LUA_PATH`/`LUA_CPATH` variables, so a copied or moved SDK runs its own
compiler and, without `TITAN_ROOT`, `titanc --print-root` reports the new
location.
Libraries emit one DLL provider. Programs emit a small
`bin/<logical-module>.exe` launcher and an application DLL; `--exe PATH` selects
an exact EXE destination relative to the current directory (appending `.exe`
when absent) while keeping the provider DLL under
`<output>/lib/titan/0.6/<module>.dll` (or `lib/titan/0.6/<module>.dll` without
`--output`) and embedding the relative path from `<exe-dir>/../lib/titan/0.6` to
that provider on the same volume. Cross-volume `--exe` destinations, Windows
Titan archive providers, and `--static` are unsupported.

Splitting large generated modules into several C translation units is opt-in
on Windows: `--c-parts` defaults to 1 there. Pass `--c-parts N` or set
`TITAN_C_PARTS=N` to enable it ([split
modules](build-profiles.md#split-modules)). All parts of a
module link into the same DLL, and the DLL still exports only each module's
fixed entry points and public raw foreign functions; helpers shared between
parts are never exported.

Use [an output directory](output-directory.md) to separate generated files from
sources and keep configurations independent:

```sh
titanc --incremental --output out/app --exe out/app/bin/app.exe app.main
```

For a standalone `app.main`, this places the launcher at `out/app/bin/app.exe`
(or `out/app/bin/app.main.exe` when `--exe` is omitted) and its provider at
`out/app/lib/titan/0.6/app/main.dll`. Without `--output`, those default paths
remain relative to the compiler's working directory. Library consumers
select their output directory through the Titan path (`TITAN_PATH_0_6`);
`--output` changes write locations without changing lookup.

While linking, `titanc` builds each launcher and provider in a sibling
`<file>.stage.tmp.<suffix>` directory beside its destination (for example
`bin/app.exe.stage.tmp.<suffix>`) and removes it after publishing. If an
interrupted build leaves one behind, the next link with the same outputs
removes it, including when `--exe` reaches the locked output directory through
a junction that Windows allows the process to follow (Redirection Guard can
refuse a junction created by a non-administrator with error 448, and Titan
does not bypass that policy). These directory names belong to the compiler: if
a leftover one contains a Titan source, C header, `--c-source` file, `-X`
object, linker input, compiler or linker tool, or output of the current build,
linking fails with `refusing to retire stale Windows staging` and deletes
nothing. Move that file elsewhere and build again. When `titanc` cannot
identify every file and tool the link uses (for example with an uncertified
compiler or linker flags it cannot interpret), any leftover stage directory
stops the link with the same message, followed by `the native link and tool
inventory is incomplete (<reason>)`. Inspect that directory, move anything you
need, delete it, and build again. Builds without leftover stage directories
are unaffected.

Deliver the matching `lua55.dll` and native dependency DLLs beside the
executables, and the program's other Titan provider DLLs, including the
standard `titan.dll`, in `lib/titan/0.6` next to `bin`: a program's run-time
[Titan path](modules.md#the-titan-path) defaults to its own directory and
`..\lib\titan\0.6`. Lua's Windows `!` path expansion means the running
executable's directory, as `!` does in Titan paths. See [Windows loading and launchers](binary-compatibility.md#experimental-windows-loading-and-launchers)
for the provider layout and [native library loading](../implementation/windows-build.md#relocation-and-native-library-loading)
for dependency search behavior. During development, a program that misses a
provider in those directories asks the installed SDK once, through
`TITAN_ROOT` or by running `titanc --print-root`. Windows looks for that
program (`titanc.exe`, or a `TITANC` name without a directory, with `.exe`
added when it has no extension) only in the `PATH` entries, never in the
current directory or the program's own directory; see [the Titan
path](modules.md#the-titan-path).

`mingw32-make -f Makefile.win binary-rock PREFIX=/c/Titan/sdk` packages the
installed rock with its native platform suffix. Use this target instead of
LuaRocks' one-step `--pack-binary-rock` path. Run the installation's
`titan-uninstall` to remove all its Titan rock versions and then its exact
external Titan files. It preserves Lua, LuaRocks, compiler dependency modules,
and shared native dependency SDK files. `titan-uninstall --luarocks PATH`
selects an external standalone LuaRocks executable. Close Titan consumers
first; after a locked-file cleanup failure, close them, reinstall the rock to
restore the command, and run it again.

## Build for the browser

Use the MSYS2 CLANG64 shell, not native `cmd` or PowerShell, for the browser
build. Activate [emsdk 6.0.13](browser-target.md#prerequisites), install
Node 26 or newer (separate from emsdk's bundled Node), and set `TITAN_NODE`
to that executable or put it first on `PATH`. Then, with the native
compiler already installed in `PREFIX`, run:

```sh
make -f Makefile.win lua-browser PREFIX="$PREFIX"
make -f Makefile.win browser-sdk PREFIX="$PREFIX"
titanc --target browser -o out-browser --exe out-browser/app.mjs app
sh "$PREFIX/lib/titan-browser/0.6/titan-browser-run" out-browser/app.mjs
```

The browser SDK installs separately from native Lua and the native provider.
Set the same `TITAN_BUILD_PROFILE` for `browser-sdk` and its consumers; the
`titan-stdlib-browser-test` target defaults to `validation`. For Chromium
tests also set `TITAN_CHROME` to the headless executable.
The shell launcher accepts either slash direction in its own path or an
explicit `TITAN_NODE`. See [the browser runner](browser-target.md#testing-from-the-command-line)
for the `chromium` engine and its transport options.

## Long double on worker threads

Windows starts every new thread with 53-bit x87 precision, while a Titan
program's main thread computes `long double` with 64-bit precision. Titan's
own worker code restores the main thread's precision before each work item:
[`Lua:run_async`](standard-library-lua.md#asynchronous-execution) jobs,
[`sqlite3`](standard-library-sqlite3.md) operations, and
[`thread`](standard-library-thread.md#standalone-os-threads) and `Group`
threads. A raw C function that you pass to `async.run_foreign`, or to the
public `uv.queue_work` and `uv.thread_create`, runs with the thread's current
state; call `_fpreset()` from `float.h` at its start if it needs the main
thread's precision.

## Symbolic links

Creating a symbolic link needs Developer Mode or the symbolic-link privilege.
Some Windows builds (26H2 build 26300, for example) also refuse to follow a
link that a non-administrator account created: every `fs` call that follows
it, such as `fs.stat`, `fs.realpath`, or opening a file through it, raises
`async.OperationError` with libuv's name `UNKNOWN` and message
`unknown error`, even for a dangling link. `fs.lstat` still describes the link
itself. Titan's own tests detect this policy and skip their symbolic-link
cases as a capability.

## Validate an installation

Use a separate validation SDK and local NTFS workspace. In the MSYS2 shell,
set `LC_ALL=C.UTF-8` so utilities such as `cygpath` preserve non-ASCII paths;
the plain `C` locale can truncate them. The test entrypoint selects the
`validation` profile and reinstalls the source rock before testing:

```sh
export LC_ALL=C.UTF-8
mingw32-make -f Makefile.win test PREFIX=/c/Titan/sdk-validation
```

With `LUAROCKS_CONFIG` selecting an already prepared SDK, plain
`luarocks.exe test titan-0.6.0-1.rockspec` tests that installed compiler/provider
without rebuilding the rock. The workflow builds and runs the complete shared
native standard-library suite first, then runs every retained runtime/packaging
and compiler/language spec file once in private checkout copies, with four
workers by default; `TITAN_ROCK_TEST_JOBS` sets any positive worker count. A
failure in the native phase does not skip the specs, and a failing spec file
does not stop the others; the run reports every failure and then fails.

`TITAN_JOBS` (default four) bounds module-frontend workers and native C
compilation for these runs; `MAKEFLAGS` is ignored. Raise it to the number of
CPUs on a larger machine. See
[native build parallelism](../implementation/windows-build.md#native-build-parallelism)
and [test ownership](../implementation/windows-build.md#test-ownership-and-keep-going).

For the shared suite's separate build/run targets, filtering, and evidence
requirements, see [native Windows tests](../implementation/windows-build.md#shared-native-standard-library-tests).
Component checks and a VM boot do not establish a complete Windows port test.
Shared-folder watcher notifications are best effort; keep filesystem, SQLite,
and local watcher validation on NTFS. Consult the
[experimental boundaries](../implementation/windows-build.md#experimental-boundaries)
for current platform gaps, such as unsupported socket-backed standard streams,
and the OpenSSL trust-root policy.
