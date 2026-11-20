# Installing and using Titan on Windows

The native x64 Windows port is experimental. Build from an MSYS2 **CLANG64**
shell with UCRT Clang, native GNU Make 4.3+ (`mingw32-make`), CMake, Ninja,
Perl, Git, Bash, `tar`, `curl`, and `unzip`. Keep Windows outputs separate
from Unix outputs. For build-system internals and validation gates, see
[Windows build](../implementation/windows-build.md).

## Install from source

Choose an absolute SDK prefix. On Windows, the Lua SDK and LuaRocks tree must
be the same physical directory:

```sh
git submodule update --init --recursive
mingw32-make -f Makefile.win lua PREFIX=/c/Titan/sdk
mingw32-make -f Makefile.win luarocks PREFIX=/c/Titan/sdk
mingw32-make -f Makefile.win compiler PREFIX=/c/Titan/sdk
```

- **OpenSSL:** Defaults to an installed binary OpenSSL 3 SDK, normally MSYS2's
  `pacman -S mingw-w64-clang-x86_64-openssl` under `/clang64` (override with
  `OPENSSL_PREFIX`). Pass `OPENSSL_MODE=bundled` to build pinned OpenSSL from
  source (also requires MSYS GNU Make: `pacman -S make`).
- **Build profiles:** Default is `production` (`WINDOWS_BUILD_ROOT` defaults
  to `out/windows` for `production` and `out/windows-validation` for
  `validation`). Use separate prefixes and build roots for each profile.
- **Rebuilds:** `lua` and `luarocks` targets skip rebuilding if the installed
  executable already exists; remove it and clean its build outputs when
  changing flags or tools. Close running Titan programs before replacing a
  mapped provider DLL.

## Invoke standalone LuaRocks

Make targets pass the SDK's LuaRocks configuration automatically. For direct
`luarocks.exe` commands, set `LUAROCKS_CONFIG`:

```sh
# MSYS2 Bash
export LUAROCKS_CONFIG="$(cygpath -m /c/Titan/sdk/etc/luarocks/config-5.5.lua)"
/c/Titan/sdk/bin/luarocks.exe make titan-0.6.0-1.rockspec
```

```powershell
# PowerShell
$env:LUAROCKS_CONFIG = "C:/Titan/sdk/etc/luarocks/config-5.5.lua"
```

## The Lua DLL and C helpers

Titan builds `lua55.dll` from unmodified Lua 5.5.1 sources with
`-DLUA_BUILD_AS_DLL` and `-Wl,--export-all-symbols` so generated Titan code
can import both public and internal Lua symbols. Any Lua 5.5.1 DLL built the
same way with default numeric settings is compatible.

Titan's own generated code, probes, and runtime compile with explicit
`__declspec(dllimport)` definitions for `LUAI_FUNC` and `LUAI_DDEC`. Your
`--c-source` C helpers do **not** receive those definitions and compile under
stock Lua conventions:

- Public `lua_*` / `luaL_*` calls work out of the box.
- To export a `luaopen_*` or other `LUALIB_API` symbol from a `--c-source`
  helper, define `LUA_LIB` or mark it `__declspec(dllexport)` (without
  `LUA_LIB`, stock `LUAMOD_API` expands to `dllimport`).

## Compile and distribute programs

The installed compiler is `bin/titanc.exe`. It always runs the compiler inside
its own SDK, ignoring `LUA_INIT`, `LUA_PATH`, and `LUA_CPATH`, so a moved SDK
reports its new root from `titanc --print-root` when `TITAN_ROOT` is unset.

```sh
titanc --incremental -o out/app --exe out/app/bin/app.exe app.main
```

Windows output layout and limits:

| Build kind | Outputs under `-o out` |
| --- | --- |
| Library (`titanc -o out a.b`) | Single DLL provider `out/a/b.dll` (no `.a` provider; `--static` is unsupported; external installed-source dependencies are checked without being embedded). |
| Standalone or `--test` program | Launcher `out/bin/<logical-module>.exe` + application DLL `out/lib/titan/0.6/<module>.dll` (which also carries any source-only dependencies materialized for prebuilt library DLLs, shared lazily as one initialized instance across loaded DLLs without changing process-wide DLL search order). |
| Program with `--exe PATH` | Launcher at `PATH` (`.exe` appended if missing); provider stays at `out/lib/titan/0.6/<module>.dll` on the same volume (named after the logical root module, not the `--exe` basename). |

- **Split modules:** `--c-parts` defaults to `1` on Windows; pass `--c-parts N`
  or `TITAN_C_PARTS=N` to opt in.
- **Deployment:** Ship `lua55.dll` and native dependency DLLs in `bin/` beside
  executables, and Titan provider DLLs (including `titan.dll`) in
  `lib/titan/0.6/` next to `bin/` (matched by the default runtime
  [Titan path](toolchain.md#the-titan-path), `!;!/../lib/titan/0.6`). During
  development, the SDK fallback runs `titanc.exe` (or `TITANC`) resolved from
  `PATH` only, never the current directory.
- **Two test binaries in one `-o`:** A test executable's provider DLL is named
  after its first root, so test binaries sharing a first root need separate
  `-o` directories if both must stay current.
- **Staging directories:** Interrupted links may leave a sibling
  `<file>.stage.tmp.<suffix>` directory; the next link removes it automatically
  unless it contains a build input or tool.
- **Packaging and uninstalling:** Run `mingw32-make -f Makefile.win binary-rock
  PREFIX=/c/Titan/sdk` to package a Titan binary rock, and `titan-uninstall`
  (after closing Titan consumers) to remove Titan while preserving Lua and
  LuaRocks. Third-party Titan module rocks stage only provider DLLs under
  `dist/modules/` (no `.lib` Titan provider; optional native link inputs go
  under `dist/lib/`), invoke `titan-install.bat --path "$(PREFIX)"` in their
  Windows `post_install` hook, and remove cleanly with
  `titan-uninstall ROCK [VERSION]` after closing consumers holding mapped DLLs;
  see [Packaging and distributing modules with LuaRocks](modules.md#packaging-and-distributing-modules-with-luarocks).

## Build for the browser

Run browser builds from the MSYS2 CLANG64 shell (not `cmd` or PowerShell).
Activate Emscripten 6.0.13, install Node 26+ separately from emsdk's bundled
Node, and set `TITAN_NODE` (or put Node 26+ first on `PATH`):

```sh
make -f Makefile.win lua-browser PREFIX="$PREFIX"
make -f Makefile.win browser-sdk PREFIX="$PREFIX"
titanc --target browser -o out-browser --exe out-browser/app.mjs app
sh "$PREFIX/lib/titan-browser/0.6/titan-browser-run" out-browser/app.mjs
```

Keep `TITAN_BUILD_PROFILE` consistent between `make browser-sdk` and consumer
links. For Chromium runs, set `TITAN_CHROME` to the headless browser
executable. See [WebAssembly and the browser target](browser-target.md).

## Long double on worker threads

Windows initializes new OS threads with 53-bit x87 precision rather than the
main thread's 64-bit `long double` precision. Titan automatically restores
64-bit precision before each work item in
[`Lua:run_async`](standard-library-lua.md#asynchronous-execution),
[`sqlite3`](standard-library-sqlite3.md), and
[`thread`](standard-library-thread.md) / `Group` workers. A raw C callback
passed to `async.run_foreign`, `uv.queue_work`, or `uv.thread_create` runs
with the thread's native state; call `_fpreset()` from `<float.h>` at entry if
it relies on 64-bit `long double`.

## Symbolic links

Creating symbolic links on Windows requires Developer Mode or the symlink
privilege. Some Windows builds also block following links created by
non-administrator accounts: `fs.stat`, `fs.realpath`, and `fs.open` then raise
`async.OperationError` (`UNKNOWN`), while `fs.lstat` still inspects the link
itself.

## Validate an installation

Use a separate validation prefix on a local NTFS drive and set
`LC_ALL=C.UTF-8` so MSYS2 path utilities preserve non-ASCII paths:

```sh
export LC_ALL=C.UTF-8
mingw32-make -f Makefile.win test PREFIX=/c/Titan/sdk-validation
```

This builds and runs the native standard-library test suite and compiler specs
under the `validation` profile (`TITAN_JOBS` defaults to `4` and `MAKEFLAGS`
is ignored). For separate build/run targets, filtering, and known platform
boundaries, see [Windows build](../implementation/windows-build.md).
