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
and manual pages into a dedicated `out/windows/` tree, then delegates
compilation to the fork's `mingw` target and installation to its `install`
target. Both receive `TITAN_LIBRARY_VERSION` and `PREFIX`. The fork installer
also supports native Windows GNU Make with `cmd.exe` and no Unix utilities.
The source bytes stay unchanged. All Titan changes are already in the fork;
Lua's platform guards select the implementation at compilation. All Windows
definitions live in this one Makefile: its default build target is `all`, and
LuaRocks uses that default and the `install` target. Native GNU Make
(including `mingw-w64-x86_64-make`) needs drive-letter paths; MSYS Make uses MSYS
paths. The Makefile converts `PREFIX`, `ROCKS_TREE`, and `WINDOWS_BUILD_ROOT`
for the selected Make implementation. The native Make executable supplied by
`mingw-w64-x86_64-make` can drive the CLANG64 compiler; selecting Make does not
select the compiler or change its UCRT target.

`WINDOWS_BUILD_ROOT` defaults to checkout-relative `out/windows` in production
and `out/windows-validation` in validation. It owns the private Lua/native
builds and the standard provider's generated stage at
`<WINDOWS_BUILD_ROOT>/out`. SDK prefixes remain separate installation
destinations. While `titanc --incremental` certifies compiler, flag, profile,
and header changes for Titan objects and final links within an output tree,
private Make/CMake build directories require separate build roots and SDK
prefixes for incompatible native configurations. See [output-directory
routing](output-directory.md).

```sh
git submodule update --init --recursive
mingw32-make -f Makefile.win lua PREFIX=/c/Titan/sdk
mingw32-make -f Makefile.win lua-check PREFIX=/c/Titan/sdk-validation
```

Then, from ordinary Windows PowerShell, run the separate native-launch gate
where local script execution policy permits it:

```powershell
powershell.exe -NoProfile -File spec/support/check_windows_lua.ps1 -BuildRoot C:\path\to\checkout\out\windows-validation
```

`-File` is subject to PowerShell execution policy. The gate does not change that
policy or request a bypass; a scripts-disabled environment requires an
authorized ordinary-command invocation of the explicit checks instead.

Windows build scripts use `TITAN_BUILD_PROFILE=production` by default;
component checks and the shared test scripts default to `validation`. The
profile policy is in [build profiles](../language/build-profiles.md). The
Windows deltas are the variable names and the production default: override
`LUA_CFLAGS`/`LUA_LDFLAGS`, `COMPILER_DEPS_CFLAGS`/`COMPILER_DEPS_LDFLAGS`, and
`LPEGLABEL_BUILD_CFLAGS` for host components; dynamic LPegLabel uses the
compiler-dependency flags configured in LuaRocks; and the Titan driver keeps
its O3 Windows production default. Host-domain flags follow generic flags, so a
test `TITAN_EXTRA_CFLAGS=-O0` does not deoptimize compiler dependencies. Build
each profile in a separate SDK prefix and Windows build root, and clean the
selected private build directory when changing tools, flags, SDK inputs, or
profile. Ordinary builds rely on source/header timestamps and the tools' own
build state; they do not reconcile saved configuration or repair modified
artifacts. Lua bootstrap checks only for `PREFIX/bin/lua.exe`; remove that
file and clean the private Lua objects before rebuilding with different
sources or flags.

The component targets have separate explicit checks under `spec/support`;
ordinary build and install recipes do not run artifact inspection.
`toolchain-check` checks the CLANG64/UCRT compiler selection. The other
component targets have separate checks. Successful Lua tests do not imply
that the complete compiler, standard library or language server works.
The Windows Titan backend publishes DLLs and does not implement Titan
static-provider emission or selection. Native dependency import libraries and the embedded runtime
archive remain SDK build inputs. The standalone LuaRocks 3.13.0 executable
installs compiler dependencies and the Titan source rock into the Lua prefix.
On all three platforms, LuaRocks installs `luv` for the compiler's worker and
subprocess transport; its ordinary LuaRocks build uses CMake and a bundled
libuv independently of Titan's stdlib libuv.

Plain `luarocks test` builds and runs the complete native stdlib suite first,
then every retained runtime/packaging, stdlib-dependent compiler, and
compiler/language spec file once, per file, in private NTFS checkout copies.
Windows defaults to four concurrent Busted workers under native Job Objects;
see [test ownership and keep-going](#test-ownership-and-keep-going) and [Busted
partitions](test-runner.md#busted-partitions).

## Native build parallelism

The compiler honors `titanc --jobs N` and `TITAN_JOBS=N`. Module-frontend
workers (`titan-compiler.build_worker`) and native compiler commands launch
through the stock LuaRocks `luv` dependency under a single coordinator-owned
slot ledger (`titan-compiler/build.lua`, `titan-compiler/process.lua`); see
[driver process transports](driver.md#experimental-windows-process-transports).
Before its first child launch, each coordinator and worker assigns itself to
a non-breakaway `KILL_ON_JOB_CLOSE` Job Object through
`titan._native_process_tree_guard()`. Every descendant inherits that strict
ancestor job before it runs, even inside libuv's own breakaway-permitting
job, so workers, native compilers, and anything a compiler wrapper starts
terminate when the coordinator's process ends, including abruptly. This
bounds their lifetime but does not order their exit before the release of the
coordinator's output lock after a forced termination
([orphan lifetime](build-coordinator.md#planned-worker-resolution-and-orphan-lifetime)).
The containment requires Windows 8 or later; if it cannot be established,
no child is launched.

`TITAN_JOBS` (default four, exported by `Makefile.win`) is the only native
build-parallelism setting on Windows; raise it to the CPU count on a larger
machine. It bounds the native dependency CMake build
(`scripts/build_windows_native.sh`), incremental compilation of the standard
provider (`scripts/build_windows_stdlib.sh`), and the shared native test and
coverage builds (`spec/support/windows_stdlib_tests.sh`). `MAKEFLAGS=-jN` has no
effect: `Makefile.win` is `.NOTPARALLEL`, and LuaRocks starts its nested Make
without the jobserver. The outer graph delegates native parallelism to `titanc`
and these scripts, while marking its compiler and test wrapper recipes
(`stdlib`, `titan-stdlib-test-build`, `titan-stdlib-test`,
`titan-native-coverage-build`, `rock-test`) with `+` and
`RECURSIVE_WRAPPER_GUARD` so `make -n`, `-q`, and `-t` do not launch compilers
or tests. The Lua, libbacktrace, and bundled OpenSSL builds stay at `-j1`.
Busted compiler workers set their own bounds; see [Busted
partitions](test-runner.md#busted-partitions).

Splitting a large generated module into several translation units is opt-in on
Windows: `driver.default_c_parts` returns 1 there, so the standard provider
and other builds stay unsplit unless `titanc --c-parts N` or `TITAN_C_PARTS=N`
asks for more. With a split, `TITAN_MODULE_PRIVATE` expands to nothing under
`_WIN32`, so the parts share ordinary external symbols that PE does not
export automatically
([storage and visibility](codegen-overview.md#storage-and-visibility)).

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

## Windows loader boundary

`titan-runtime/titan_winloader.h` (`titan_win_load_library`) converts a UTF-8
provider path to an absolute UTF-16 path and opens it with the zero-flag
`LoadLibraryExW` call described above; it never changes the process DLL
directories or `PATH`. Executables, the controlled Lua DLL, and native
dependency DLLs share `bin`; Titan DLLs resolve from `lib/titan/0.6`. The
default distribution root is the executable's parent directory, and wide
environment access (`titan_win_push_environment`) preserves Unicode Titan path
overrides and the distinction between an absent and an empty override. This
covers explicit dynamic module loads only, not initial EXE imports; Windows'
already-loaded-module, KnownDLL, and API-set rules still apply.

Each private per-state handle cache is keyed by the absolute path actually
opened. The caches only avoid repeated loader calls; they do not establish
logical module identity. Successful OS references are never released, even
after Lua state teardown, because provider code may still back descriptors,
callbacks, and finalizers. Each provider embeds its own Titan helpers while all
providers use the same controlled Lua DLL. Titan dependency entries resolve
through the selected handle or canonical descriptor, without Titan import
libraries or a process-wide native-symbol search.

The Windows `titan_check_module_abi` adapts the `_abi` symbol argument to
`_abi_value` and invokes it as `const char *(*)(void)` before any provider Lua
entry; see [Generated exports and runtime
verification](binary-compatibility.md#generated-exports-and-runtime-verification).
The support module's Windows-only `_abivalue(path, symbol)`
(`titan-runtime/ltitanlib.c`) exposes the same query to the compiler: success
returns a copied Lua string; failure returns `nil, diagnostic, stage`, with
stage `open`, `init` (missing export), or `abi` (invalid result). A missing
query may prompt symbol-only membership checks, but a provider that claims the
logical module cannot proceed to Lua metadata without a matching native query.
Unix probes call `_abi`.

Windows shims pass their logical name as a third `_loadlibglobal` argument. The
helper first checks the canonical registry userdata and returns a closure
holding that same userdata, without opening or ABI-checking the replacement
pathname. Otherwise it maps the selected image, checks the native query, then
returns the Lua opener. The shim's preceding `package.searchpath` step is the
same as on Unix; direct helper calls cover canonical reuse with a missing
pathname. Neither helper calls a plain-C query through a `lua_CFunction`.

Provider loads invalidate the cached backtrace module snapshot (trace merging
is summarized under [Experimental boundaries](#experimental-boundaries)); builds
that disable libbacktrace fall back to native addresses.
`spec/support/check_windows_runtime_loader.sh` is a native CLANG64/UCRT gate
using the real controlled Lua headers and import library. It builds separate
provider DLLs and checks ABI-before-initialization, canonical identity, callback
lifetime, Unicode paths, dependency resolution from the executable directory
and `PATH`, and imports without additional toolchain runtime DLLs. Passing it
does not establish full compiler or standard-library support.

## Windows application launchers

The Windows program link produces a Titan application DLL plus a small console
EXE. The DLL receives all selected source modules and native payload; the EXE
links only its entrypoint, manifest resource, embedded Titan runtime, and the
controlled Lua import library. Neither output links a Titan module import
library. The SDK runtime archive is `libtitan.a`; Windows links the matching
`lib/liblua55.a` plus the separate SDK `lib/libbacktrace.a` for PE/COFF source
attribution, omits Unix `dl` and `m`, and selects static unwind linkage with
`-static-libgcc` so no additional toolchain runtime DLL is needed.

Without `--exe`, `driver.windows_program_paths` derives
`bin/<logical-module>.exe` and `lib/titan/0.6/<logical/module>.dll` under the
selected `--output` root (or the current directory when `--output` is omitted).
With `--exe PATH`, `PATH` is an exact executable destination relative to the
invocation working directory (with `.exe` appended case-insensitively when
absent), while the companion provider DLL stays at
`<output>/lib/titan/0.6/<logical/module>.dll`. `driver.windows_program_paths`
computes `relative_provider` as the path from `<exe-dir>/../lib/titan/0.6` to
that provider DLL and rejects destinations on a different volume (`--exe
'<exe>' is on another volume than its provider '<provider>'`). For tests, the
first requested logical root (`requested_modules[1]`) owns the provider path and
default launcher name, while the embedded entry identity is the generated test
runner (`titan.test.runner`). `driver.windows_launcher_name` validates the
launcher basename—the logical module name by default, or the `--exe`
basename—rejecting directory separators, alternate streams, control
characters, reserved DOS device names (including `COM¹`/`²`/`³` and
`LPT¹`/`²`/`³`), invalid UTF-8, trailing dots/spaces, and components exceeding
255 UTF-16 code units, with `--exe`-prefixed diagnostics. The CLI rejects
`--exe` for `--compile-only` and library-only invocations, and locks both the
output root and `dirname(--exe)`.
Program output preflight includes the provider, `.def`, manifest, resource
source, and compiled resource.

PE links disable automatic exports. `driver.windows_provider_exports` writes a
producer-owned `.def` from every logical module physically carried into the
DLL: `_abi_value`, `_abi`, `_types`, `_layouts`, `_compatibility`, `_init`, and
`luaopen_*`, plus public raw foreign entries recovered from module interfaces.
The list depends only on logical module names and their interfaces, which only
part 0 of a split module carries. Part objects and module-private symbols never
enter the `.def`, and `-Wl,--exclude-all-symbols` keeps them unexported.
Hidden raw-address binding slots are never exported; canonical descriptor
callbacks resolve later native function and slot addresses, and collision
inventories are not export inventories. The support-only `luaopen_titan` keeps
its explicit Lua-module export annotation. Missing module inventories fail
before an existing output is removed. Private `.def` files are removed after
link success or failure. Private archive-validation DLLs receive the same
complete inventory, and fresh-process validation checks the plain-C ABI before
invoking Lua metadata. Windows CLI invocations reject `--static` and selected
Titan archive providers, so all logical Titan modules use DLL providers. The
internal standalone link helper keeps defensive archive metadata checks, but
that is not a supported Windows static-provider mode.

The entrypoint (`driver.entrypoint_contents`) embeds the logical identity and
`relative_provider`, never an EXE basename. Its Windows-only `package.preload`
callback resolves that provider relative to `<exe-dir>/../lib/titan/0.6`,
checks the native ABI, and invokes its exact Lua opener inside the protected
entrypoint. Argument reconstruction, bootstrap hook selection, error handling,
Lua-state closure, and exit status are shared with Unix; see [Linking a
standalone program](driver.md#linking-a-standalone-program-drivercompile_program).
`llvm-rc` (or the parsed `RC` command) embeds an `asInvoker`, UTF-8,
long-path-aware manifest; no machine setting or global DLL search path changes.
The manifest, resource source, and compiled resource are named after the
generated entrypoint C file (`<entrypoint>.c.manifest`, `.c.rc`, and `.c.res`,
among the paths returned by `driver.windows_program_auxiliary_paths`; coverage
builds also emit `<entrypoint>__coverage_dump.c` and `.o` for the provider DLL)
and live beside it under `<output>/.titan-links/<key>/synthetic/` on certified
CLI builds (or at the mapped entrypoint stem for direct `driver.compile_program`
callers).

`compile_windows_program` stages the provider DLL and launcher EXE in sibling
`<final-basename>.stage.tmp.<unique>` directories beside their destinations,
then commits both images as one recoverable set through
`windows_publication.publish_program` ([Windows DLL
publication](#windows-dll-publication)). The staged provider is validated in a
fresh child Lua process, the same controlled runner the library branch uses,
which runs the unchanged `validate_library_image` checks (ABI acceptance,
type and layout decoding, and resolution of each logical module's init and
`luaopen_*` entries without calling them). The coordinator never maps the
staged DLL itself, so no process-lifetime loader handle can pin the stage.

`spec/support/generate_windows_launcher_fixture.lua` emits the actual driver C,
`.def`, manifest, and resource text for the native
`spec/support/check_windows_launcher.sh` gate. It verifies exact PE protocol
exports, allowed imports, a separate Titan dependency, Unicode arguments and
resource paths, default/overridden/renamed launchers, bootstrap opt-out, and
fresh incompatible-provider rejection. This generated-C gate does not
establish a complete native `titanc` or standard-library build.

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
source preparation (`scripts/prepare_windows_native.pl`) verifies the pinned
archives, applies the libuv write-reentry patch, and adds the llhttp and SQLite
DLL header annotations before marking each source complete.

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
`out/windows-validation/native-check/native-probe-path.txt` from ordinary PowerShell
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
library with the in-tree compiler and private bootstrap. The copy-only install
pass and `post_install` payload publication are the same as on Unix; see
[build and installation
responsibilities](build-script-audit.md#installation-and-publication). Windows
binary rocks also carry the native dependency DLLs, import libraries, and
headers.

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
runtime/native SDK to compile every root in `Makefile.win` `STDLIB_MODULES`
(the same list as the [standard-library
image](multi-module-libraries.md#reserved-titan-and-the-standard-library-image))
into one `titan.dll`.
`scripts/build_windows_stdlib.sh` passes `--output <WINDOWS_BUILD_ROOT>/out
--source-first --incremental -j "$TITAN_JOBS" --tree "$winsource"` with the 26
`STDLIB_ROOTS` and `-X "$winbuild/runtime/ltitanlib.o"
"$winbuild/runtime/libtitan-lpeglabel.a"`, keeping generated C, objects,
headers, the provider DLL, Lua shims, and the final-link certificate
(`<WINDOWS_BUILD_ROOT>/out/.titan-links/<key>/record`) below that stage.
`publish-stdlib` copies `<WINDOWS_BUILD_ROOT>/out/titan.dll` and the shims
under its `titan/` directory into the canonical SDK locations; it does not read
source-adjacent outputs. `TITAN_JOBS` bounds concurrent module-frontend workers,
generated-C compilation, and C validation probe batches under the coordinator's
slot ledger. The target neither reinstalls the compiler nor prepares those
native inputs. `install-stdlib` builds that provider and then copies it;
`publish-stdlib` copies an existing provider and its shims without rebuilding
or validating them. The source rock instead builds the provider in
its default `all` target with the unpacked compiler sources, the controlled Lua
program and the private bootstrap, as described in [build and installation
responsibilities](build-script-audit.md#installation-and-publication).

`mingw32-make -f Makefile.win binary-rock` uses the shared
`scripts/install_compiler.mk` rule with the SDK's LuaRocks configuration,
including its module-based ZIP backend. Plain LuaRocks 3.13 packing retains the
native payload but labels it `.all.rock`, so use the Make target rather than the
one-step `--pack-binary-rock` path. `titan-uninstall` follows the shared
contract; on Windows the shared native dependency DLLs, import libraries, and
headers also remain. There is no per-version cleanup, because canonical paths
are shared across rock versions. Windows source and binary rock installations
require the same physical Lua SDK and rocks prefix.
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

The installed files are `lib/titan/0.6/titan.dll` and one shim per root under
`share/lua/5.5/titan`. Native tests use the DLL's ordinary `titan.test`
implementation; no test-source payload is installed. No Titan `.a`
provider or Titan import library is published. `--static` is unsupported on
Windows. Removed logical modules do not trigger automatic stale-shim cleanup;
build such a changed provider in a fresh output directory. A DLL mapped by
another process blocks replacement, so close it before copying a new provider.
Ordinary stdlib installation does not back up or roll back files.

## Windows DLL publication

This is the compiler's no-main Windows branch, distinct from the copy-only
`publish-stdlib` above. It validates the generated source-object inventory
against the linked DLL's callable ABI/types/layouts in a fresh Lua child,
checking the plain-C ABI before any Lua metadata call. Only after that child
exits does `driver.publish_windows_provider` publish the DLL and its exact
physical-provider shims. Unix uses the paired archive/DSO path in [Publication
and installation](static-compiled-modules.md#publication-and-installation).

`titan-compiler/windows_publication.lua` has no native-loader or driver
dependency; its caller supplies native filesystem operations. `publish`
prepares destination-local copies, copies predecessor bytes into sibling
backups, invokes any `before_commit` hook (used by `titanc` to invalidate
`<output>/.titan-links/<key>/record` before the first public mutation), and
replaces companions before the DLL. `publish_program` applies the same
recoverable transaction to a standalone or test `{ provider, executable }`
pair (even when `--exe` places the launcher outside `--output`), committing any
companions, then the provider DLL, and finally the launcher EXE. Neither path
moves an existing DLL or EXE aside: Windows can rename a mapped image but then
refuse its deletion. Replacing the still-existing mapped image fails before
changing its public pathname; caught failures restore only already committed
files in reverse order. Failed restoration keeps its backup and reports the
path's error. This is byte recovery, not metadata preservation, process-crash
atomicity, or protection against concurrent publishers.

After publication, both program staging directories (or the library's) are
removed by one strategy-backed recursive helper that does not follow links and
reports the exact path that failed. A cleanup failure after a successful
publication is reported as such: the public images stay committed and are not
rolled back, but the invocation fails and records no final-link certificate.
A failed validation or publication keeps its own diagnostic and also reports
any cleanup failure.

On the next linking invocation, while it still holds the output locks,
`titanc` retires leftover stage directories for its known final outputs
(`driver.cleanup_stale_staging`). It does so after `linkcertificate.prepare`
has resolved the final link's inputs and before generated headers are
restored, the final-link certificate is checked, or a final-link hit returns.
Only non-link directories named exactly
`<final-basename>.stage.tmp.<nonempty>` qualify; unrelated names, other
temporary namespaces, and matching files or links are left alone. Each final
output must lie in a held lock domain: either its parent is lexically inside a
held lock directory, or the parent or one of its ancestors contains a regular
`.titan-build.lock` with the same volume serial number and file ID as a held
lock file. An `--output` or `--exe` spelled through a junction of a held
directory is therefore covered, because lock acquisition deduplicates the two
spellings to one physical lock file. A lock file without a native file ID or
a linked lock file never proves coverage. This requires Windows
to let the process follow that junction: Redirection Guard can refuse a junction
created by a non-administrator with `ERROR_UNTRUSTED_MOUNT_POINT` (448), and
Titan does not bypass that policy. The real-junction CLI regression reports
error 448 on its own junction as a pending capability, never as a pass.

Before removing anything, cleanup lists every candidate's complete tree
without following links. When the native inventory is complete, it checks
those trees through `perf.new_output_path_index` against everything the
invocation accepted or reserved: the preflight's `plan.reservations` and
`plan.inputs` ([Pre-dispatch output
preflight](build-coordinator.md#pre-dispatch-output-preflight)), the source
files and non-`search` C headers that the build recorded for each module in
`plan.order`, each `--c-source` file with every dependency its one
preprocessing run recorded (the `nativeinputs.compile` result's
`dependencies`), the final link's explicit inputs (objects, compiled C
objects, `-X` payloads, providers, archives, and runtime inputs), the files
that the prepared link's
[native library policy](build-coordinator.md#recipe-file-digests-and-native-library-policy)
resolved from the linker arguments (`native_policy.files`, such as a raw
`--ldflag` archive or an `-L`/`-l` library), and the native tools identified
by path. Those tools are the certified compiler with any ccache, sccache, or
distcc delegate and its `cc1`/`as` stages (`compiler_tools` on the output-tool
request), and every selected output tool: the linker, resource compiler,
archiver, link driver, LTO wrapper and compiler, and each LTO plugin. Exact,
case-folded, component-hierarchy, and physical-identity matches all count, so
an input reached through another spelling of a staged file is caught, and a
stage file hard-linked to an input is refused as well. A link inside a stage
is unlinked, never followed, so its target does not block retirement. Any
match or observation error fails the invocation with `refusing to retire stale
Windows staging: <conflict>` and retains every candidate, including unrelated
abandoned ones; the user must move the input. When no candidate exists, no
protected path is observed. A call without the preflighted plan, the native C
results with their `source` and `dependencies`, the final-link inputs, the
prepared native link policy, or the output-tool selection fails closed before
scanning; an absent `compiler_tools` is valid and marks an uncertified
toolchain.

The inventory is incomplete when the native library policy produced no
resolved-file list (`native_policy.files` is absent because the final link is
uncertified, or its linker arguments or `--c-source` compile flags use a
mechanism the policy does not recognize; a resolved but empty list is
complete), when the toolchain is uncertified, or when the output-tool
selection is uncertified. A candidate could then hold an input or tool that no
evidence names, so if any candidate exists, cleanup fails the invocation with
`refusing to retire stale Windows staging '<first candidate>': the native link
and tool inventory is incomplete (<reason>)` before the protected-path check
or any removal. Every candidate and its contents are kept, and no final-link
hit or certificate follows. Without a candidate, such a build continues
unchanged. To let `titanc` reclaim stages automatically, use a certifiable
toolchain and linker arguments that the native library policy recognizes;
otherwise inspect the stage directories, move any data you need, and delete
the abandoned ones yourself. There is no flag to force or skip retirement.

Stale-shim retirement is not implemented on Windows: the prior DLL does not
carry the old physical membership inventory, and a matching banner or
logical-name prefix is not proof of ownership. `driver.publish_windows_provider`
therefore retires no shims for removed logical modules.

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
allowlist: `--test-dir` discovers the same 30 owners under `spec/stdlib/titan`
on all three platforms, with `test.tests` passed explicitly first and verified
against `spec/support/stdlib_test_modules.mk`, including filesystem, SQLite,
and local watchers (see [repository
dogfooding](test-runner.md#repository-dogfooding)).

`spec/support/windows_stdlib_tests.sh` requires a local fixed NTFS workspace
marked with `.titan-test-owner` (`titan-windows-stdlib-tests-v1`), with no
directory reparse points and no overlap with the supplied SDK prefix. The
harness and its native-executable helper use only Bash 3.2 features:
NUL-delimited `read -r -d ''` loops rather than `mapfile`, `find -print0`
rather than `globstar`, and a small Perl filter rather than associative arrays
for manifest set differences:

1. **Incremental input refresh on `build`:** the harness removes only
   `build.complete` and `build.log`, preserving `sdk/`, `source/`, `cwd/`,
   `native/`, and `coverage/` so certified objects, providers, link records,
   and `.gcno` notes survive across builds. It inventories the supplied SDK
   with `find`, stages test and native fixture sources plus private
   collaboration headers (`titan/transfer_native.h` and
   `titan/protobuf/native.h`), stages runtime fixtures under
   `cwd/spec/fixtures/`, and stages native fixture headers under
   `cwd/.titan-tests/` using NUL-delimited manifests (`sdk.inputs`,
   `source.inputs`, `fixtures.inputs`, `native-headers.inputs`). Each
   destination is checked to lie inside the workspace with no symlinked
   ancestors (`owned_destination`). Files with equal bytes (`cmp -s`) are left
   untouched; paths present in the previous manifest but absent from the new
   inventory are removed (along with empty parent directories) before new
   or changed files are copied. Generated files in `sdk/` are never listed in
   `sdk.inputs` and are preserved across refreshes.
2. **Pure-C native executables (`Makefile.win` `windows-stdlib-test-native`):**
   the harness writes `work/native-flags.config` (recording
   `TITAN_BUILD_PROFILE`, `CC`, `cppflags`, `cflags`, `ldflags`, and `CC
   --version`) via copy-if-different and invokes `make -f Makefile.win
   windows-stdlib-test-native TITAN_TEST_BUILD_DIR=<work>`. That phony target
   depends on the authored `os_process_host_child.c`,
   `os_process_host_child_windows.h`, and `windows_test_supervisor.c`,
   `native-flags.config`, and the recipe script, and runs
   `spec/support/build_windows_stdlib_native.sh <work>` in UTF-8 MSYS Bash.
   Native Make's ANSI recipes and file checks never see the Unicode output
   name. The script, which runs only under `CLANG64` in an owner-marked
   workspace, reads the NUL-delimited compiler, preprocessor, compile, and link
   argv files and builds `sdk/bin/process child ação 東京.exe` and
   `sdk/bin/windows-test-supervisor.exe` with `-municode` and `cygpath -m`
   paths. Each output is rebuilt only when it is missing or older than one of
   its authored sources, `native-flags.config`, or the script itself, so an
   unchanged workspace runs no compiler; a failed compile removes its partial
   output. Neither executable depends on the Titan compiler or provider.
3. **Fixed C fixture objects:** for each of `uv_stdio_probe` (also an
   aggregate `--c-source` helper), `sqlite3_worker_fixture`,
   `ssl_allocator_fixture`, `ssl_error_strings`, and `os_descriptor_limit`, the
   harness runs the workspace's `sdk/bin/lua.exe` and retained `titanc` script
   with `-c --incremental --print-c-objects -j "$TITAN_JOBS" --output
   "$work/native/$fixture"`, `--cflag=-std=c99 --cflag=-Wall --cflag=-Wextra
   --cflag=-Werror -I "$winprefix/src/lua-5.5.1"`, one `--cflag` per token of
   `cppflags` and `cflags` (with `TITAN_EXTRA_*FLAGS` cleared in the
   environment so flags are not applied twice), and `--c-source
   "$work/source/spec/fixtures/stdlib/native/$fixture.c"`. It strips a
   trailing carriage return from the single reported path, requires it to name
   a regular file, and copies it to `work/cwd/.titan-tests/$fixture.o` only
   when `cmp -s` reports a change. Stale `.native` nodes from another checkout
   location are never selected.
4. **Aggregate compilation:** from `work/sdk`, the harness invokes `titanc`
   with `--output "$output" --test --incremental --no-uv-bootstrap -j
   "$TITAN_JOBS" --exe "$winprefix/bin/titan-stdlib-tests.exe" --tree
   "$test_tree" --test-dir "$test_tree"`, the three aggregate C helpers
   (`async_foreign_work.c`, `fs_fixture.c`, `uv_stdio_probe.c`) via
   `--c-source`, and explicit first root `test.tests`. Ordinary builds use
   `output="$work/sdk"`.
5. **Runtime scratch reset on `run`:** the runner verifies `build.complete` and
   `sdk/bin/titan-stdlib-tests.exe`, loads `work/compiler.env`, and refuses to
   run if `TITAN_BUILD_PROFILE` or `TITAN_TEST_COVERAGE` differs from the build
   that prepared the workspace. It then resets only `work/scratch` and
   `stdout.log`/`stderr.log`, leaving all compiler and coverage outputs intact,
   and executes the aggregate under the bounded Job Object supervisor while
   draining both output streams.

`TITAN_TEST_TIMEOUT` defaults to 1800 seconds (600 for the coverage goals) to
accommodate the full suite's fresh-process compiler and launcher cases. The
PowerShell wrapper reports the complete native exit status and maps any
nonzero status to 1; see [platform
portability](test-runner.md#platform-portability-and-complete-execution).
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

### Test ownership and keep-going

`luarocks test` reaches `mingw32-make -f Makefile.win rock-test` through
`spec/support/run_rock_tests.sh`. Windows keeps its native-build-first
ownership: `rock-test` first builds and runs the complete native aggregate
(`titan-stdlib-test`) in its private NTFS workspace, then runs the Busted phase
through `run_rock_tests.sh` and the native Job Object supervisor. It does not
mix the Unix Make jobserver into either phase. A failed native build or run
does not suppress the Busted phase. Each phase that fails prints its status,
and the target fails when either phase failed.

The native aggregate runs as one serial process here; the Unix parallel owner
groups are not used, because this workspace owns one supervisor, log, SDK copy,
and scratch tree. Its build still compiles up to `TITAN_JOBS` (default four)
generated-C objects at once. The Busted phase plans every classified spec file
per file with the shared timing dataset, like Unix: the exclusive files run
first and alone, then `TITAN_ROCK_TEST_JOBS` ordinary workers (default four)
share the FIFO scheduler, so the exclusive files' explicit native job bounds
never multiply with another active worker. Each worker records one result per
file and continues after a failed file, and the supervisor preserves the
worker's complete native exit status; see [Busted
partitions](test-runner.md#busted-partitions).

## Native line coverage

The prepared SDK supports `titanc --test --coverage` with matching Clang/LLVM
and its gcov-compatible reader; Windows selects the `llvm-gcov` backend by
default, and the validated toolchain is LLVM 22.1.8.
`mingw32-make -f Makefile.win titan-native-coverage` (or its separate `-build`
and `-run` targets, via `scripts/windows_native_coverage.sh`) sets
`TITAN_TEST_COVERAGE=1` and source-links production imports into the private
NTFS workspace (`$(WINDOWS_BUILD_ROOT)/native-coverage`). It passes `--output
"$work/coverage"` and `--exe "$winprefix/bin/titan-stdlib-tests.exe"`, keeping
coverage objects, `.gcno` notes, `.native` helpers, and `.titan-links`
certificates in `work/coverage` while the launcher in `work/sdk/bin` embeds the
relative path to `work/coverage/lib/titan/0.6/test/tests.dll`. Backend checks,
provider-local counter dumping, reports, and target variables are in [native
coverage](native-coverage.md#repository-integration-and-verification).

## Experimental boundaries

Windows error traces use libbacktrace and generated DWARF to
interleave Lua frames with native Titan filenames, lines, and function names.
The separate static libbacktrace archive and static unwind linkage avoid an
additional runtime DLL. `titan.os.popen`
uses the system `cmd.exe` with `/d /s /c`, writable stdin, and merged output.
Its command string must use native Windows shell syntax; see
[shell commands](../language/standard-library-os.md#shell-commands). Use
`titan.os.spawn` for direct executable and argument control. Both retain the
existing process ownership rules, without a descendant-termination guarantee.
Socket-backed parent stdio is unsupported on Windows. Before its named-pipe or
unknown-handle path, `titan.os` asks Winsock whether a standard handle is a
socket. It rejects any socket with `stdio.parent.kind: ENOTSUP` before
duplicating or adopting the handle
([parent standard streams](../language/standard-library-os.md#parent-standard-streams)).
Connected TCP stdio (`kind() == "tcp"`) is a Linux and macOS feature.

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
