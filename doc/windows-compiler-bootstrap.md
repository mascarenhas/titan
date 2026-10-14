# Native Windows compiler installation with LuaRocks

Use MSYS2 CLANG64 with native GNU Make (`mingw32-make`) on PATH, the Titan
Lua 5.5.1 fork, and its matching SDK. The official standalone LuaRocks binary
uses its bundled filesystem and archive modules with the configuration below.
The Lua installation must contain `bin/lua.exe`, `bin/lua55.dll`, `lib/liblua55.a`, public
headers under `include/`, and the compiler's internal headers and source files
under `src/lua-5.5.1/`. Initialize the Lua submodule before building that SDK:

```sh
git submodule update --init --recursive
mingw32-make -f Makefile.win lua PREFIX=/c/Titan/sdk
mingw32-make -f Makefile.win luarocks PREFIX=/c/Titan/sdk
```

OpenSSL defaults to an installed binary SDK, normally MSYS2's
`mingw-w64-clang-x86_64-openssl` package under `/clang64`. Set `OPENSSL_PREFIX`
to another matching SDK, or select `OPENSSL_MODE=bundled` to build the pinned
source with upstream's `mingw64` configuration and MSYS GNU Make (`pacman -S make`).
System mode stages matching DLLs, import libraries, and headers without
downloading or compiling OpenSSL.

The `luarocks` target installs the official standalone LuaRocks 3.13.0 Windows
x64 executable and writes `etc/luarocks/config-5.5.lua` under that prefix. The
configuration selects the Lua SDK as the rock tree, its `liblua55.a` import
library, and the CLANG64 `clang.exe` compiler and archive tools. The executable
spelling avoids LuaRocks 3.13.0's incorrect Clang-specific MinGW export option.
It also enables `fs_use_modules`, so LuaRocks uses its bundled LuaFileSystem
for recursive copies. Its default MSYS2 command backend passes a quoted Windows
wildcard to MSYS `cp`, which fails for directory installs such as Penlight.
The configuration selects CMake's Ninja generator for native rock dependencies;
install CMake and Ninja in the CLANG64 environment.
The target checks only for `bin/luarocks.exe`; an existing installation is the user's responsibility.
The `compiler` target selects that configuration and invokes ordinary
`luarocks make`:

```sh
mingw32-make -f Makefile.win compiler PREFIX=/c/Titan/sdk
```

Users who already have compatible Lua and LuaRocks can build the source rock
directly, with their own LuaRocks configuration. Select the Lua SDK prefix as
the rock tree; Windows source and binary rock installations require the same
physical Lua and rocks prefix. For the configuration installed
by the target above, set `LUAROCKS_CONFIG` in the shell before running the
standalone executable. Moving that executable into `PREFIX/bin` does not make
it discover `PREFIX/etc/luarocks` automatically:

```sh
export LUAROCKS_CONFIG="$(cygpath -m /c/Titan/sdk/etc/luarocks/config-5.5.lua)"
/c/Titan/sdk/bin/luarocks.exe make titan-0.6.0-1.rockspec
```

The same setting in PowerShell is
`$env:LUAROCKS_CONFIG = "C:/Titan/sdk/etc/luarocks/config-5.5.lua"`.
The configuration supplies Lua 5.5 and the SDK tree, so ordinary standalone
commands need no repeated Lua-version or tree options.

The rockspec installs LPegLabel, LuaFileSystem, inspect, argparse, and Windows
subprocess support through `luv` using LuaRocks. Their own rockspecs build the
native modules; Titan keeps its private
namespaced PEG payload separate. LuaRocks records and manages the compiler and
these dependencies through its ordinary rock manifests. There is no separate
Titan compiler-dependency receipt or duplicate compiler module inventory.

The Windows rockspec override selects `Makefile.win`. Its default `all` target prepares
the runtime and pinned native SDK, then uses the compiler Lua sources in the
unpacked source tree and the private support bootstrap to build the complete
Windows standard-library DLL and twenty-three shims. A fresh source-rock build
does not need an installed Titan compiler. LuaRocks then runs the copying-only
`install` target in that tree. Compiler Lua modules and stdlib shims go to
`INST_LUADIR`, while `titanc` and `titan-uninstall` go to `INST_BINDIR`, for
ordinary LuaRocks deployment and ownership. The built native payload is
retained at `<rock-prefix>/titan-sdk`, beside
`<rock-prefix>/installer/titan_install.lua`. A copy-only `post_install` hook
invokes that helper by absolute path to publish the SDK and standard-library
DLL at their canonical locations. It needs no source directory or Makefile.
Binary rocks retain the same helper and payload, including the native
dependency DLLs, import libraries, and headers. Canonical SDK/provider copies
remain outside LuaRocks' manifest.
`mingw32-make -f Makefile.win stdlib` uses the already installed compiler and prepared
runtime/native SDK to rebuild the provider directly. `install-stdlib` then copies
its DLL and shims. `publish-stdlib` copies an existing stage without rebuilding it.
Run `stdlib-check` separately to validate that stage.

Use `mingw32-make -f Makefile.win binary-rock` to pack the installed Titan.
The target selects the SDK's LuaRocks configuration for packing and gives
the result the native platform suffix from
`luarocks config arch`; plain LuaRocks 3.13 packing retains this payload but
misleadingly labels it `.all.rock`. Avoid the one-step `--pack-binary-rock`
path. Run `titan-uninstall` from the selected installation to remove all its
Titan rock versions through LuaRocks, then clean exact external Titan files
only if removal succeeds. Lua, LuaRocks, dependency Lua modules, and shared
native dependency SDK files remain. Cleanup covers the whole Titan
installation because its canonical paths are shared across rock versions.
Use `titan-uninstall --luarocks PATH` for a standalone executable outside the
SDK; otherwise cleanup tries the recorded frontend, then `luarocks.exe` on
`PATH`. It still selects this installation's Lua 5.5 SDK and rocks tree.
Close programs using Titan before uninstalling. If LuaRocks removal succeeds
but a locked image prevents cleanup, close its consumers, reinstall the rock
to restore the cleanup command, then run `titan-uninstall` again.

LuaRocks installs `bin/titanc.bat` and retains the actual Lua script in
`lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc`. Build and native test helpers
invoke that script with the selected `bin/lua.exe`, so they do not depend on
batch command parsing. Lua modules live under `share/lua/5.5` and native Lua
modules under `lib/lua/5.5`. The fork's normal executable-relative search paths
locate those files and the provider under `lib/titan/0.6`.

`compiler-check` inspects the installed Lua modules' Windows/UCRT imports and
public openers, copies the SDK into a separate path containing spaces and
Unicode, then loads the installed compiler and dependencies and runs the
compiler's help command from that copy. This tests invocation of the installed
Lua script; LuaRocks' batch wrapper itself contains installation-specific paths.
Actual standard-library compilation and the shared native runtime suite remain
the Windows port's integration gates.

From CLANG64, the same configuration can enter the test workflow:

```sh
/c/Titan/sdk/bin/luarocks.exe test titan-0.6.0-1.rockspec
```

LuaRocks installs the test dependencies and passes the selected Lua SDK prefix
to the command adapter. Windows dispatches to `Makefile.win rock-test`, which
builds and runs all 28 shared native roots, then the seven retained runtime and
packaging specs serially and the compiler/language specs in four private checkout
copies. Windows defaults to two concurrent compiler-test workers; the partition
containing parallel-compilation tests runs alone.
`mingw32-make -f Makefile.win test PREFIX=/c/Titan/sdk` reinstalls the source rock
first. Plain `luarocks test` tests the existing installed compiler/provider.
Test objects use the selected test profile; the installed provider can be a
production or prebuilt installation.

All Windows Make definitions live in `Makefile.win`. Direct entry and LuaRocks'
build pass both select `all`; LuaRocks then invokes `install`.
Native GNU Make (including `mingw-w64-x86_64-make`) uses Windows drive paths;
MSYS Make uses MSYS paths. The Makefile converts supplied prefixes for its Make
implementation before selecting installed programs.

Ordinary builds use source/header timestamps and the build tools' own state.
Clean the selected private build directory before changing native tools, flags,
SDK inputs, or build profile. Lua and LuaRocks targets reuse an existing program
under `PREFIX/bin`; remove or replace it when rebuilding. SDK staging preserves
an existing `titan.dll` and seeds the support DLL only when absent. Standard-library
installation copies its artifacts directly; close processes using the provider
before replacing a mapped DLL. Explicit component checks live under
`spec/support` and run only through their check targets.
