# Experimental Windows build

`Makefile.win` builds the experimental native x64 Windows SDK, including
controlled Lua, native dependency DLLs, the compiler and embedded runtime.
For the installation and usage workflow, see
[Installing and using Titan on Windows](../language/windows-build.md).
Run it in the MSYS2 **CLANG64** environment with its
UCRT Clang, LLVM resource tools, Bash, native GNU Make 4.3 or newer
(`mingw32-make`), CMake, Ninja, Perl, Git, tar,
curl, unzip, and ordinary Unix file utilities. The [Titan Lua fork](https://github.com/mascarenhas/lua-5.5.1)
is a Git submodule at `lua-5.5.1/`, pinned by the Titan checkout's submodule
commit. Initialize it after cloning or updating the checkout. The Unix build
compiles directly in that submodule. Windows copies the source and installation Makefiles, `.c`, `.h`, `lua.hpp`,
and manual pages into a dedicated `windows-build/` tree, then delegates
compilation to the fork's `mingw` target and installation to its `install`
target. Both receive `TITAN_LIBRARY_VERSION` and `PREFIX`. The fork installer
also supports native Windows GNU Make with `cmd.exe` and no Unix utilities.
The source bytes stay unchanged. All Titan changes are already in the fork;
Lua's platform guards select the implementation at compilation. Generated-C
compilation honors `titanc --jobs` and `TITAN_JOBS`; its default is one. All Windows definitions live in this one Makefile: its default build target
is `all`, and LuaRocks uses that default and the `install` target. Native GNU Make
(including `mingw-w64-x86_64-make`) needs drive-letter paths; MSYS Make uses MSYS
paths. The Makefile converts `PREFIX`, `ROCKS_TREE`, and `WINDOWS_BUILD_ROOT`
for the selected Make implementation. The native Make executable supplied by
`mingw-w64-x86_64-make` can drive the CLANG64 compiler; selecting Make does not
select the compiler or change its UCRT target.

```sh
git submodule update --init --recursive
mingw32-make -f Makefile.win lua PREFIX=/c/Titan/sdk
mingw32-make -f Makefile.win lua-check PREFIX=/c/Titan/sdk-validation
```

Then, from ordinary Windows PowerShell, run the separate native-launch gate
where local script execution policy permits it:

```powershell
powershell.exe -NoProfile -File spec/support/check_windows_lua.ps1 -BuildRoot C:\path\to\checkout\windows-build-validation
```

`-File` is subject to PowerShell execution policy. The gate does not change that
policy or request a bypass; a scripts-disabled environment requires an
authorized ordinary-command invocation of the explicit checks instead.

Windows build scripts use `TITAN_BUILD_PROFILE=production` by default;
component checks and the shared test scripts default to `validation`. Validation
uses `-O0 -fno-lto` for Titan runtime, providers, native test helpers and final
links. Lua and compiler dependencies (LuaFileSystem and LPegLabel), plus the
private static LPegLabel payload, use `-O2 -fno-lto` to keep compilation fast.
Ordinary production native helpers/dependencies retain their existing O2
defaults; the Titan driver keeps its O3 Windows production default. Explicit
native and `TITAN_EXTRA_*` flags follow the Titan profile defaults. Host-domain
flags follow generic flags so a test `TITAN_EXTRA_CFLAGS=-O0` does not deoptimize
compiler dependencies. Override `LUA_CFLAGS`/`LUA_LDFLAGS`,
`COMPILER_DEPS_CFLAGS`/`COMPILER_DEPS_LDFLAGS`,
and `LPEGLABEL_BUILD_CFLAGS` for host components. Dynamic LPegLabel uses the compiler-dependency flags configured in LuaRocks. Sanitizer builds use O1/no LTO with full instrumentation
in the Lua, compiler-dependency and private-parser domains while keeping Titan
at O0. Build each profile in a separate SDK prefix and Windows build root; the
selected profile is recorded in `etc/titan/build-profile`. Clean the selected
private build directory when changing tools, flags, SDK inputs, or profile.
Ordinary builds rely on source/header timestamps and the tools' own build state;
they do not reconcile saved configuration or repair modified artifacts. Lua
bootstrap checks only for `PREFIX/bin/lua.exe`; remove that file and clean the
private Lua objects before rebuilding with different sources or flags.

The component targets have separate explicit checks under `spec/support`;
ordinary build and install recipes do not run artifact inspection.
`toolchain-check` checks the CLANG64/UCRT compiler selection. The other
component targets have separate checks. Successful Lua tests do not imply
that the complete compiler, standard library or language server works.
The Windows Titan backend publishes DLLs and does not implement Titan
static-provider emission or selection. Native dependency import libraries and the embedded runtime
archive remain SDK build inputs. The standalone LuaRocks 3.13.0 executable
installs compiler dependencies and the Titan source rock into the Lua prefix.
Windows also installs `luv` for compiler subprocesses; its ordinary LuaRocks
build uses CMake and a bundled libuv independently of Titan's stdlib libuv.

Plain `luarocks test` runs the complete native stdlib suite, the seven retained
runtime/packaging specs, and all compiler/language specs in four private NTFS
checkout copies. Windows defaults to two concurrent compiler-test workers;
`TITAN_ROCK_TEST_JOBS=1` through `4` selects the bound. Each worker uses the
installed SDK read-only and has private source outputs, TEMP and TMP under
MSYS2's short `/tmp` scratch base. The shard
containing explicit parallel-compilation tests runs alone so its chosen native
job bound does not overlap another shard. Ordinary Busted filters or appended
arguments retain the single-process route. Native Job Objects contain and clean
worker descendants.

The compiler itself honors `titanc --jobs N` and `TITAN_JOBS=N`. Parallel object
commands launch through the stock LuaRocks `luv` dependency; its exit callbacks
report actual completion to the common scheduler. Larger units start first, a completed
child frees its slot immediately, and diagnostics replay in request order. See
[driver process transports](driver.md#experimental-windows-process-transports).

## One controlled Lua DLL and its SDK

The recipe uses the pinned Lua 5.5.1 submodule and installs matching sources
without applying patches or transforming their contents. Its separate Windows
copy keeps objects out of the submodule's Unix build tree. The Windows
`loadlib.c` backend remains upstream Lua's implementation. Lua owns its
Windows object and link rules, including the paired DLL and GNU import-library
outputs. Titan compiles its process manifest as an interpreter-only resource,
passes the native flags, and delegates SDK installation to Lua. Existing
installed interpreters are reused without configuration or build receipts.
The recipe produces and installs:

| Path below `PREFIX` | Content |
| --- | --- |
| `bin/lua.exe` | Interpreter with a UTF-8 process manifest |
| `bin/luac.exe` | Lua bytecode compiler |
| `bin/lua55.dll` | One shared Lua runtime, including pinned internals and the standard Lua DLL name |
| `lib/liblua55.a` | Import library for that DLL |
| `include/` | Matching configured public headers |
| `src/lua-5.5.1/` | All matching configured C sources and headers |

Compiler SDK installations retain headers and matching source directories;
language-server installations retain the headers required for analysis.
Standalone application payloads can omit those SDK-only files. This initial
recipe installs the complete Lua SDK; it is not an application packager.

Only the DLL's translation units define `TITAN_LUA_BUILD_DLL`. `LUA_CORE` and
`LUA_LIB` still describe source roles and cannot select DLL ownership. Public
functions, internal functions, and the four internal/public arrays explicitly
export from the producer and import through consumers' IATs. `LUAMOD_API`
independently exports a third-party module's opener, with C linkage in C++;
Lua's built-in openers and auxiliary API declare `LUA_API`, so external
libraries import them too. External libraries built with `LUA_LIB` use
`LUALIB_API` to export their own functions while their `LUA_API` calls still
import from Lua.
Automatic export of other global symbols is disabled at DLL link time.
Titan's embedded helper functions remain a separate runtime contract.

The supplied build uses Lua's default 64-bit integers and double-precision
numbers. Lua and its consumers must use the same numeric configuration and
internal layouts, as with upstream Lua.
The consumer gate calls `luaL_checkversion` as well as exercising internal
functions and comparing all four imported data addresses with the loaded DLL.

`spec/fixtures/windows/lua-5.5.1-exports.txt` is the exact default-release export
oracle: 156 public functions (98 `lua_*`, 48 `luaL_*`, 10 `luaopen_*`), 205
internal functions, and `lua_ident`, `luai_ctype_`, `luaP_opmodes`, and
`luaT_typenames_`. It was derived independently from the pinned headers'
`LUA_API`, `LUALIB_API`, `LUAMOD_API`, and `LUAI_FUNC` declarations, plus those
four data declarations, and cross-checked against the same version's native
archive. `luaH_mainposition` is excluded because upstream guards it with
`LUA_DEBUG`. This is an expected inventory, not evidence of a Windows build.

## Relocation and native library loading

Windows `!` retains upstream's **running executable directory** meaning.
The fork retains upstream Windows Lua-source search paths and adds
`!\\..\\share\\lua\\5.5` for LuaRocks modules. Native module searches retain the
executable directory and add `!\\..\\lib\\lua\\5.5` and
`!\\..\\lib\\titan\\0.6`.
Lua retains its upstream executable-directory expansion. The shipped
executables declare a UTF-8 process code page for their Windows ANSI APIs;
Titan's own provider-path handling uses the wide Windows APIs.

Generated launcher diagnostics and provider paths preserve their supplied bytes
in C string literals, including Unicode and literal `$` sequences. These values
are escaped before recursive template expansion; they cannot become compiler
template substitutions.

Lua's `package.cpath` selects the module file, and `package.loadlib` uses
upstream `LoadLibraryExA` with its default zero flags. Titan's explicit module
loader resolves its provider path and calls `LoadLibraryExW` with zero flags.
Native dependencies follow the ordinary Windows DLL search order, including
the executable directory, system locations, current directory, and the process
`PATH`. The provider-search paths remain separate from native dependency
resolution, and neither loader changes the process DLL search directories.

Titan's `lua.exe` and application launchers import `lua55.dll`
before runtime initialization. The distribution retains that shared Lua runtime
beside its executables. The standard DLL name lets Lua 5.5 binary modules use
the same runtime when their architecture and Lua configuration match. Arbitrary
long-path support is not promised.

The executable embeds per-process UTF-8 `activeCodePage` and `longPathAware`
manifest declarations for Windows 11. This build does not change machine code
pages or the OS long-path policy. The latter declaration is only the application
opt-in: usable path lengths still depend on OS policy and each API in the path.
See [Microsoft's long-path requirements](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation).
Real Unicode command-line,
filesystem, module, and process behavior must be tested with CLANG64/UCRT.
See [Microsoft's UTF-8 process guidance](https://learn.microsoft.com/en-us/windows/apps/design/globalizing/use-utf8-code-page)
and [Windows DLL search order](https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-search-order).

## Verification boundaries

`bash spec/support/check_windows_build_profile.sh` checks profile selection, quoted
flag arguments, override ordering, and invalid configurations without a Windows
SDK or VM.

`make -f Makefile.win lua-source-check` can run on Linux with Clang and
`llvm-readobj`. It compiles real x64 COFF header consumers in four source-role
combinations, checks C++ opener linkage and producer annotations, and compiles
an actual Lua data definition. It neither substitutes Windows SDK headers nor
builds a Windows DLL.

On native CLANG64, `lua-check` verifies the exact DLL export inventory, imports,
installed source/header bytes, and a real SDK consumer. It then relocates the
runtime into a path containing spaces and non-ASCII characters, runs from a
different CWD without toolchain PATH entries, and loads Lua and native modules.
A separate canary fails when its dependency is absent from the native search
locations. Fresh processes then load it with that dependency only on the
process `PATH`, and only beside `lua.exe`. The canary exercises ordinary
`package.cpath`, `require`, and `package.loadlib`, including a relative explicit
provider path. The separate PowerShell gate repeats those checks using native
Windows paths and a temporary process-local `PATH`; it does not depend on MSYS
argument conversion. The Titan runtime loader gate checks the same missing,
`PATH`, and executable-directory dependency cases while retaining its provider
identity and `TITAN_PATH` checks.

The import allowlist checks regular and delay imports of the EXE, its sole
private Lua DLL, and the SDK consumer. It permits only the named Windows
Kernel32/UCRT dependencies and controlled Lua DLL; extra compiler-support DLLs
fail the gate. Lua export forwarders also fail, so this slice cannot hide
another provider behind its reviewed export names. Build tools may
have MSYS/LLVM dependencies, but shipped programs may not acquire them through
this choice of toolchain. Future native dependencies require recursive import
inspection of the complete application-private payload and a clean PowerShell
run. Host-only checks cannot establish that closure or replace the Windows
runtime gates.


## Private native dependency SDK

The experimental `native` target uses the same CLANG64/UCRT compiler to build
libuv 1.53.0, llhttp 9.4.3, and SQLite 3.53.4 with CMake/Ninja from the pinned,
checksum-verified sources recorded in `vendor/windows-native/dependencies.tsv`.
Those pins match the ordinary Makefile. OpenSSL defaults to
`OPENSSL_MODE=system`, using an already installed binary SDK. Install
[`mingw-w64-clang-x86_64-openssl`](https://packages.msys2.org/packages/mingw-w64-clang-x86_64-openssl)
with `pacman -S mingw-w64-clang-x86_64-openssl`, or set `OPENSSL_PREFIX` to a
compatible x64 UCRT/GNU OpenSSL 3 SDK. The default prefix is CLANG64's
`MINGW_PREFIX` (normally `/clang64`). The native installer copies its two DLLs,
matching GNU import libraries, and configured public headers into the Titan
SDK. It does not download or compile OpenSSL in this mode.

`OPENSSL_MODE=bundled` selects the pinned OpenSSL 3.5.7 source build with its
upstream `mingw64` configuration, Perl, MSYS GNU Make (`pacman -S make`), and
`llvm-windres`. This optional upstream build invokes `make` from the CLANG64
shell; the Titan Makefile and LuaRocks use the selected native GNU Make. Both modes
deliver the same runtime and import-library names below. Changing OpenSSL mode
or system prefix does not rebuild the other native dependencies. Clean the
private OpenSSL build directory before changing its configured flags or prefix.
Verified acquisition completion remains separate from build configuration: cold
source preparation verifies the pinned archives and applies the libuv write
reentry patch and DLL header annotations before marking each source complete.

```sh
mingw32-make -f Makefile.win native-source-check
mingw32-make -f Makefile.win native-check PREFIX=/c/Titan/sdk-validation
# An alternative installed binary SDK:
mingw32-make -f Makefile.win native OPENSSL_PREFIX=/c/OpenSSL-UCRT
# Compile the pinned source instead:
mingw32-make -f Makefile.win native OPENSSL_MODE=bundled
```

| Runtime in `bin/` | Import library in `lib/` |
| --- | --- |
| `libuv-1.dll` | `libuv.dll.a` |
| `libllhttp-9.4.dll` | `libllhttp.dll.a` |
| `libsqlite3-0.dll` | `libsqlite3.dll.a` |
| `libcrypto-3-x64.dll` | `libcrypto.dll.a` |
| `libssl-3-x64.dll` | `libssl.dll.a` |

The runtime names express the reviewed upstream ABI versions. OpenSSL's system
release is selected by the caller's installed SDK; the bundled releases and
configurations remain pinned separately. Names are selected
before linking, so import libraries refer to the installed DLL names. Matching
public headers, including OpenSSL's configured generated headers, are staged
under `include/`. The runtime gate checks that OpenSSL's headers and runtime
report the same version. Bundled mode also checks its reported configuration
directory against the Titan prefix's native Windows path spelling. System
mode retains the binary provider's configuration, module, and certificate
paths; copying the DLLs does not relocate those paths or install certificate
trust roots. Upstream native static archives may exist inside private
build directories but are never installed into this SDK.

The configured llhttp and SQLite Windows headers distinguish each DLL producer
from ordinary SDK consumers. Only their library targets define
`TITAN_LLHTTP_BUILD_DLL` or `TITAN_SQLITE_BUILD_DLL`; consumer functions and
SQLite's exported data use explicit imports. libuv retains upstream's
`BUILDING_UV_SHARED`/`USING_UV_SHARED` contract. These transformations are confined
to dedicated Windows source copies.

The bundled OpenSSL configuration disables automatic configuration, dynamic
providers/modules, DSO loading, the legacy provider, compression, QUIC, and its
command-line applications/tests. It keeps the built-in provider and native
threading. System mode retains the binary distribution's features and defaults.
The DLL is not literally inert at load time: upstream
`crypto/dllmain.c` performs CPU-capability setup on process attach and thread
cleanup on thread detach; ordinary CRT initialization also remains. The pinned
libuv, llhttp, and SQLite sources define no project DLL entrypoint. None of
these native dependencies runs a Titan/Lua module initializer, and their normal
startup does not replace the separate Titan ABI-before-initialization gate.
Generated-C and stdlib consumers define `USING_UV_SHARED` to import
libuv through the matching SDK header contract.

`native-source-check` compiles an actual x64 COFF header consumer on the host
and verifies those imports and producer declarations. `native-check` requires
Windows: it inspects regular/delay PE imports and export forwarders of every
private DLL, then links a consumer against the exact SDK import libraries. Its
runtime subset contains only the five selected DLLs and the test EXE. With no
toolchain PATH entries it exercises a libuv asynchronous callback, an llhttp
request, an in-memory SQLite query and shared data address, and OpenSSL SHA-256
and TLS-context creation. `SSL_CTX_new` success does not prove a TLS handshake
or that usable certificate trust roots were loaded. These checks do not establish
Titan stdlib behavior, network interoperability, or a Windows CA-store policy.

After that gate, run the exact EXE path recorded in
`windows-build-validation/native-check/native-probe-path.txt` from ordinary PowerShell
with the argument in `native-config-path.txt`, a restricted process PATH, and
another CWD as well. A native compile,
import-closure audit, and successful native behavior checks are required before
using this experimental SDK. Host COFF checks alone do not validate these DLLs.

## Runtime SDK and compiler bootstrap

`Makefile.win` installs the standalone LuaRocks executable and
configures the Lua prefix as its rock tree, with CLANG64 tools and the matching
`liblua55.a` import library. `compiler` runs the Titan rockspec through
`luarocks make`; the rockspec selects `Makefile.win` on Windows. Its build pass
prepares the native dependencies and runtime SDK, then builds the standard
library with the in-tree compiler and private bootstrap. Its copying-only
install pass stages the compiler modules, launchers, and stdlib shims for
LuaRocks deployment and retains the built native payload under the private
rock prefix. A copy-only `post_install` helper then publishes that payload
to canonical SDK locations by absolute path.

```sh
mingw32-make -f Makefile.win luarocks PREFIX=/c/Titan/sdk
export LUAROCKS_CONFIG=C:/Titan/sdk/etc/luarocks/config-5.5.lua
/c/Titan/sdk/bin/luarocks.exe --lua-version=5.5 \
  --tree=C:/Titan/sdk make titan-0.6.0-1.rockspec
```

Users who already have compatible Lua and LuaRocks installations can run the
last command with their own configured tree and native build tools.
The generated configuration defaults to `clang.exe`, enables
`fs_use_modules`, and selects CMake's Ninja generator. The executable spelling
avoids standalone LuaRocks 3.13.0's incorrect Clang-specific MinGW export
option; the module filesystem backend avoids its MSYS command backend's quoted
Windows wildcard during recursive copies. The `luarocks` target checks only
for `bin/luarocks.exe`, so callers own replacement or reconfiguration of an
existing installation. Direct standalone commands must set `LUAROCKS_CONFIG`;
the executable does not automatically find the SDK's `etc/luarocks` directory.

LuaRocks installs `bin/titanc.bat` and retains the Lua script at
`lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc`. Build and native test helpers
invoke that script with the selected `bin/lua.exe`, avoiding batch parsing.
`spec/support/check_windows_compiler.sh` verifies installed dependencies, their PE
imports, the compiler modules, and CLI loading from a different CWD in an SDK
copy whose path contains spaces and Unicode. That gate invokes the retained
script; LuaRocks' batch wrapper can contain installation-specific paths.

`Makefile.win` builds `libtitan.a` from exactly `titan.o` and
`minicoro.o`, plus the separate support-only `titan.dll` from `ltitanlib.o`.
The private, namespaced LPegLabel archive contains exactly its five upstream
translation units and remains build payload. All objects use the installed,
configured Lua source headers and matching `lua55.dll` import library. The
separate static libbacktrace archive is built with upstream configure/make and
staged at `lib/libbacktrace.a`, with `backtrace.h` and
`backtrace-supported.h` under `include/`. Generated provider and launcher links
select static LLVM unwind support through `-static-libgcc`. The
[Windows PE correction](../../vendor/libbacktrace/README.md) bounds symbol
lookup and uses actual relocated image addresses; Titan refreshes snapshots
after provider loads instead of using persistent loader notifications.
The runtime and libbacktrace archives, public runtime/FFI headers, and matching
backtrace headers are installed as SDK files. The private Windows loader
header and the PEG archive stay in the build tree. Third-party notices and license texts are staged under
`share/titan/` with the runtime SDK.

```sh
mingw32-make -f Makefile.win compiler-check runtime-check PREFIX=/c/Titan/sdk-validation
```

Runtime staging seeds `lib/titan/0.6/titan.dll` only when absent and preserves
any existing image, including a full standard library. It copies the runtime
archive, public headers, license texts, and profile record directly. Callers own
cleanup and SDK compatibility when changing native inputs.

The runtime build compiles three runtime and five private parser translation
units, archives the selected objects, and links the support DLL. Source/header
timestamps decide which outputs need rebuilding; tool or flag changes require
caller-managed cleanup. `runtime-check` links the complete runtime and private
PEG payload into a native consumer, checks permitted PE imports, and exercises
Lua/PEG and explicit-runtime coroutine yield/resume/destruction. It verifies
unchanged warm timestamps and proves that staging preserves an existing support
image with extra payload. These checks cover the SDK foundation; complete Titan
coroutine, standard-library, language-server, and extension behavior require
their own native tests.

## Standard-provider build and publication

`Makefile.win` uses the installed
native compiler and the controlled runtime/native SDK:

```sh
mingw32-make -f Makefile.win install-stdlib PREFIX=/c/Titan/sdk
```

The `stdlib` target uses the already installed compiler and prepared
runtime/native SDK to compile all 23 explicit roots into one `titan.dll`.
`TITAN_JOBS` bounds generated-C compilation; checking, generation and the final
link retain their normal order. It does not reinstall the compiler or prepare those native inputs.
`install-stdlib` builds that provider and then copies its artifacts.
The source rock instead builds the provider during its default `all` target using
the compiler Lua sources in the unpacked tree, the controlled Lua program,
and the private support bootstrap. Native SDK preparation still occurs during
that Windows build. LuaRocks then runs the copying-only `install` target:
compiler modules and stdlib shims go to `INST_LUADIR`, while `titanc` and
`titan-uninstall` go to `INST_BINDIR`. The built SDK/provider payload is
retained at `<rock-prefix>/titan-sdk`, with
`<rock-prefix>/installer/titan_install.lua`. The `post_install` hook invokes
that helper by absolute path to copy the payload into the canonical SDK
locations. It needs no source directory, Makefile, or compiler. Binary rocks
retain this same copier and payload, including the Windows native dependency
DLLs, import libraries, and headers. LuaRocks owns compiler files and shims;
canonical SDK/providers remain external copies. `publish-stdlib` copies an
existing provider and its 23 generated shims directly without rebuilding or
validating them.

`mingw32-make -f Makefile.win binary-rock` packs the installed Titan and gives
the result the native suffix from `luarocks config arch`. It selects the SDK's
LuaRocks configuration, including its module-based ZIP backend. Plain LuaRocks 3.13
packing retains the native payload but misleadingly labels it `.all.rock`.
Use the Make target rather than the one-step `--pack-binary-rock` path.
`titan-uninstall` removes all installed Titan rock versions in its selected
tree through LuaRocks, then cleans exact external Titan files only if removal
succeeds. Lua, LuaRocks, dependency Lua modules, and shared native dependency
DLLs, import libraries, and headers remain. There is no per-version cleanup;
canonical paths are shared across rock versions. Windows source and binary rock
installations require the same physical Lua SDK and rocks prefix.
Close programs using Titan before uninstalling. If LuaRocks removal succeeds
but a locked image prevents cleanup, close its consumers, reinstall the rock
to restore the cleanup command, then run `titan-uninstall` again.

The publisher preserves LuaRocks' generated cleanup-launcher headers and full
Lua invocation, but retires CMD's batch context before starting the Lua child.
The terminal command returns naturally with that child's status without
reopening the deleted batch file or skipping a parent batch's `CALL`
continuation. Native tests cover refusal, self-removal, and parent-batch
continuation from a path containing spaces. Uninstall and binary packing pass
`--lua-version 5.5 --lua-dir <sdk>` explicitly, so standalone LuaRocks defaults
cannot select another Lua installation. `titan-uninstall --luarocks PATH`
selects an external frontend; otherwise cleanup tries the recorded executable,
then `luarocks.exe` on `PATH`.

`stdlib-check` is the separate artifact gate. It uses an isolated copy and a
fresh Lua process to check exact PE exports, permitted imports, callable metadata
against source objects and generated shims. Compiler
provider publication retains its own ABI and transactional behavior;
`compiler-publication-check` exercises that contract independently of stdlib
installation.

The provider links the system Winsock import library `ws2_32` for the private
UV address helper's byte-order conversion. Its PE import audit permits
`WS2_32.dll` explicitly. Ordinary compiled Titan clients call the provider and
do not need this import library or private UV headers themselves.

The installed files are `lib/titan/0.6/titan.dll` and the 23 shims under
`share/lua/5.5/titan`. Native tests use the DLL's ordinary `titan.test`
implementation; no test-source payload is installed. No Titan `.a`
provider or Titan import library is published. `--static` is unsupported on
Windows. Removed logical modules do not trigger automatic stale-shim cleanup;
build such a changed provider in a fresh output directory. A DLL mapped by
another process blocks replacement, so close it before copying a new provider.
Ordinary stdlib installation does not back up or roll back files.

## Shared native standard-library tests

Build and publish a validation-profile provider into its separate SDK, then run
the complete common suite from CLANG64. Choose a disposable workspace on a local
NTFS volume:

```sh
TITAN_BUILD_PROFILE=validation mingw32-make -f Makefile.win install-stdlib \
  PREFIX=/c/Titan/sdk-validation
mingw32-make -f Makefile.win titan-stdlib-test-build \
  PREFIX=/c/Titan/sdk-validation TITAN_TEST_BUILD_DIR=/c/Titan/native-tests-validation
mingw32-make -f Makefile.win titan-stdlib-test-run \
  PREFIX=/c/Titan/sdk-validation TITAN_TEST_BUILD_DIR=/c/Titan/native-tests-validation
```

`titan-stdlib-test` composes both steps. `TITAN_FILTER` selects a runtime Lua
pattern without narrowing compilation; omit it for complete validation. The
compatibility entrypoint `spec/support/check_windows_stdlib_behavior.sh WORKSPACE SDK`
also builds and runs the full shared suite. There is no separate Windows case
allowlist: `spec/support/stdlib_test_modules.mk` supplies the same 28 explicit
roots to all three platforms, including filesystem, SQLite, and local watchers.

The build copies the supplied SDK and authored fixtures into its marked
workspace, preserving the published SDK. It records the test compilation
profile for later run commands; a run with a different selected test profile
requires rebuilding the workspace.
It rejects unrelated existing directories and nonlocal or non-NTFS workspaces.
Test outputs, scratch files, native child executables, and logs stay inside that
workspace. The runner uses the bounded Job Object supervisor and drains both output streams, including
when the aggregate fails or times out. `TITAN_TEST_TIMEOUT` defaults to 1800
seconds to accommodate the full suite's fresh-process compiler and launcher
cases. Keep the complete native exit status, including values above 255.
The test launcher reserves 8 MiB of stack so the common deep-recursion oracles
also run with `-O0` providers. Fresh-process fixtures copy the selected SDK's
runtime DLLs beside their child executables and preserve normal
executable-relative provider lookup. Both settings are private to the harness.

Standalone compiler fixtures link in a fresh Lua process, which releases the
DLL mappings created by validation before the next fixture rebuilds that
provider. They remove their own previous direct-module DLL so it cannot shadow
the standalone provider under `lib/titan/0.6`.

Compiler fixtures that create native symbolic links require permission from the
Windows process token. When creation is denied, the owning cases report a
capability skip with the creation error; the same assertions run when that
permission is available.

The output audit reports selected, passed, skipped, and failed cases, checks
that every owner executed, and requires each exclusion to name its semantic,
environment, or production-API reason. An unfinished fixture port fails the
gate. Native C fixtures are compiled on Windows even when an individual
platform-specific assertion is skipped. See the
[shared harness contract](test-runner.md#platform-portability-and-complete-execution).

A complete provider build and unfiltered behavior run remain required; runtime,
launcher, or publication canaries alone are insufficient. Record the source
revision, SDK identity, native OS/architecture, provider optimization, local
filesystem, and classified skip reasons. Repeat the shared suite with providers
from both `validation` and `production` build profiles when validating the
Windows port. Windows production recipes use their ordinary `-O2` defaults;
test objects retain validation flags when consuming a production SDK.

## Native line coverage

The prepared SDK supports `titanc --test --coverage` with matching Clang/LLVM
and its gcov-compatible reader. Native Windows CLANG64/UCRT selects
`llvm-gcov` by default; the validated toolchain is LLVM 22.1.8. A direct run of
the generated EXE resets counters, runs tests, dumps its provider DLL's counters
and writes a basic gcov report. Python and gcovr are needed only for optional
HTML, LCOV or Cobertura formats.

`make -f Makefile.win titan-native-coverage` uses the ordinary private local
NTFS test workspace and source-links production imports into its native test
provider. Separate `titan-native-coverage-build` and `-run` targets allow reruns
without recompilation; the run also reports. `TITAN_COVERAGE_FORMATS` requests
optional richer formats. The ordinary native supervisor and test runner retain
their existing test/child cleanup responsibilities. See
[native coverage](../language/native-coverage.md) for source selection, tools,
output paths and concurrency limits.

## Experimental boundaries

The initial stdlib target rebuilds its explicit roots. Compiler checking and C
generation run serially; independent generated-C object compilations honor the
requested job bound through the native completion transport described above.
Windows error traces use libbacktrace and generated DWARF to
interleave Lua frames with native Titan filenames, lines, and function names.
The separate static libbacktrace archive and static unwind linkage avoid an
additional runtime DLL. `titan.io.popen`
uses the system `cmd.exe` with `/d /s /c`, writable stdin, and merged output.
Its command string must use native Windows shell syntax; see
[shell commands](../language/standard-library-io.md#shell-commands). Use
`titan.os.spawn` for direct executable and argument control. Both retain the
existing process ownership rules, without a descendant-termination guarantee.

The shared tests still need Windows equivalents for the Unix file-descriptor
leak inventory, FIFO-based accepted-open cancellation, and USR1/USR2 delivery
fixtures. These are coverage gaps, not evidence that native file cancellation,
source loading, or all signal delivery is unavailable. Symbolic-link fixtures
probe their actual creation route; a LuaFileSystem failure does not establish
that Titan's native Windows symlink route is unavailable.

Bundled OpenSSL supplies no usable default CA roots and does not automatically
use the Windows ROOT certificate store. System mode inherits the installed
provider's certificate and configuration defaults. Moving the SDK does not
relocate either provider's compiled CA paths. Use the existing
`ssl.connect(host, port, ca_file)` PEM-file
argument, or configure `SSL_CERT_FILE` / `SSL_CERT_DIR` before starting a fresh
process that loads `titan.ssl`. The directory override requires OpenSSL's
subject-hash layout. These choices retain certificate and peer-name verification;
no trust anchors are selected or installed by the Windows build. See
[client trust selection](../language/standard-library-ssl.md#verified-client-connections).

Filesystem behavior depends on the backing filesystem. Validate native file
operations, SQLite locking and local notifications on NTFS. Shared-folder byte
visibility does not imply change notifications: virtiofs notifications are best
effort and are not a requirement for this experimental port. No shared-folder
notification workaround changes the local watcher contract.
