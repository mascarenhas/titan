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
3.13.0, and the Titan compiler and standard library:

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
still publishes the DLL and shims into the selected SDK.
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
compiler, its dependencies, and the standard-library Lua shims; the rock's
copy-only installation helper publishes the retained native SDK/provider
payload to canonical SDK paths.

## Compile and distribute programs

LuaRocks installs `bin/titanc.bat`. With the SDK's `bin` on `PATH`, use `titanc`
for the ordinary [module and program commands](modules.md#experimental-windows-compilation).
Libraries emit one DLL provider and generated Lua shims. Programs emit a small
`bin/<logical-module>.exe` launcher and an application DLL; `--launcher-name`
can select another EXE name without changing provider identity. Windows Titan
archive providers and `--static` are unsupported.

Use [an output directory](output-directory.md) to separate generated files from
sources and keep configurations independent:

```sh
titanc --output out/app app.main
```

For a standalone `app.main`, this places the launcher at
`out/app/bin/app.main.exe` and its provider at
`out/app/lib/titan/0.6/app/main.dll`. Without `--output`, those final paths remain
relative to the compiler's working directory. Library consumers must select
their output directory through the usual provider/Lua search paths;
`--output` changes write locations without changing lookup.

Deliver the matching `lua55.dll` and native dependency DLLs beside the
executables. Lua's Windows `!` path expansion means the running executable's
directory. See [Windows loading and launchers](binary-compatibility.md#experimental-windows-loading-and-launchers)
for the provider layout and [native library loading](../implementation/windows-build.md#relocation-and-native-library-loading)
for dependency search behavior. LuaRocks batch wrappers can contain
installation-specific paths; the compiler relocation check invokes the
retained Lua script with the relocated interpreter.

`mingw32-make -f Makefile.win binary-rock PREFIX=/c/Titan/sdk` packages the
installed rock with its native platform suffix. Use this target instead of
LuaRocks' one-step `--pack-binary-rock` path. Run the installation's
`titan-uninstall` to remove all its Titan rock versions and then its exact
external Titan files. It preserves Lua, LuaRocks, compiler dependency modules,
and shared native dependency SDK files. `titan-uninstall --luarocks PATH`
selects an external standalone LuaRocks executable. Close Titan consumers
first; after a locked-file cleanup failure, close them, reinstall the rock to
restore the command, and run it again.

## Validate an installation

Use a separate validation SDK and local NTFS workspace. The test entrypoint
selects the `validation` profile and reinstalls the source rock before testing:

```sh
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

`TITAN_JOBS` (default four) bounds native and generated-C compilation for these
runs; `MAKEFLAGS` is ignored. Raise it to the number of CPUs on a larger machine.
See [native build parallelism](../implementation/windows-build.md#native-build-parallelism)
and [test ownership](../implementation/windows-build.md#test-ownership-and-keep-going).

For the shared suite's separate build/run targets, filtering, and evidence
requirements, see [native Windows tests](../implementation/windows-build.md#shared-native-standard-library-tests).
Component checks and a VM boot do not establish a complete Windows port test.
Shared-folder watcher notifications are best effort; keep filesystem, SQLite,
and local watcher validation on NTFS. Consult the
[experimental boundaries](../implementation/windows-build.md#experimental-boundaries)
for current platform gaps and the OpenSSL trust-root policy.
