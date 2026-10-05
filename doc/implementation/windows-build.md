# Experimental Windows build

`Makefile.windows` builds the experimental native x64 Windows SDK, including
controlled Lua, native dependency DLLs, the compiler and embedded runtime.
Run it in the MSYS2 **CLANG64** environment with its
UCRT Clang, LLVM resource tools, Bash, Make, Perl, tar, curl, and ordinary Unix
file utilities. It uses a dedicated `windows-build/` source/object tree and
never reuses the Unix `lua-5.5.1/` build tree. Compilation is initially serial.
The ordinary Makefile and Linux/macOS build remain separate.

```sh
make -f Makefile.windows lua PREFIX=/c/Titan/sdk
make -f Makefile.windows lua-check PREFIX=/c/Titan/sdk
```

Then, from ordinary Windows PowerShell, run the separate native-launch gate
where local script execution policy permits it:

```powershell
powershell.exe -NoProfile -File scripts/check_windows_lua.ps1 -BuildRoot C:\path\to\checkout\windows-build
```

`-File` is subject to PowerShell execution policy. The gate does not change that
policy or request a bypass; a scripts-disabled environment requires an
authorized ordinary-command invocation of the explicit checks instead.

The component targets have separate checks. Successful Lua tests do not imply
that the complete compiler, standard library or language server works.
Windows Titan providers use DLLs; static Titan-provider emission and linking
are unsupported. Native dependency import libraries and the embedded runtime
archive remain SDK build inputs. This workflow does not install LuaRocks.

## One controlled Lua DLL and its SDK

The pinned Lua 5.5.1 tarball is checksum-verified before extraction. A source
transformer creates a separate configured source tree; it rejects changed
upstream anchors. The recipe produces and installs:

| Path below `PREFIX` | Content |
| --- | --- |
| `bin/lua.exe` | Interpreter with a UTF-8 process manifest |
| `bin/lua-5.5.1.dll` | One shared Lua runtime, including pinned internals |
| `lib/liblua-5.5.1.dll.a` | Import library for that DLL |
| `include/` | Matching configured public headers |
| `src/lua-5.5.1/` | All matching configured C sources and headers |
| `etc/titan/lua-5.5.1-windows.config` | Source, toolchain, flags, and configuration identities |

Compiler SDK installations retain headers and matching source directories;
language-server installations retain the headers required for analysis.
Standalone application payloads can omit those SDK-only files. This initial
recipe installs the complete Lua SDK; it is not an application packager.

Only the DLL's translation units define `TITAN_LUA_BUILD_DLL`. `LUA_CORE` and
`LUA_LIB` still describe source roles and cannot select DLL ownership. Public
functions, internal functions, and the four internal/public arrays explicitly
export from the producer and import through consumers' IATs. `LUAMOD_API`
independently exports a third-party module's opener, with C linkage in C++;
Lua's own built-in opener declarations use `LUALIB_API` so consumers import
them. Automatic export of other global symbols is disabled at DLL link time.
Titan's embedded helper functions remain a separate runtime contract.

The controlled configuration uses 64-bit Lua integers and double-precision
numbers. Producer-only numeric overrides are rejected by the installed
configuration header. Build flags are for ordinary optimization, diagnostics,
and instrumentation; changing Lua configuration or internal layouts requires
a corresponding reviewed SDK source change, not a command-line-only variant.
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
Configured Lua defaults resolve `!..` to the SDK prefix and search
`share/lua/5.5` for Lua source, `lib/titan/0.6` then `lib/lua/5.5` for modules.
The ordinary explicit current-directory Lua module templates remain available.
The Windows resolver uses the wide executable-path API and converts to UTF-8;
it does not substitute the Lua DLL's own directory or the POSIX parent meaning.

Generated launcher diagnostics and provider paths preserve their supplied bytes
in C string literals, including Unicode and literal `$` sequences. These values
are escaped before recursive template expansion; they cannot become compiler
template substitutions.

The controlled Windows Lua loader accepts UTF-8 module paths, rejects invalid
UTF-8 and embedded NUL arguments, resolves the requested provider with
`GetFullPathNameW`, and calls `LoadLibraryExW` with only
`LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32`.
Consequently a module may be explicitly selected from another directory, but
its dependencies must already be loaded or resolve through Windows' system
mechanisms, the EXE directory, or System32. The loader does not add the provider
directory, CWD, PATH, or user DLL directories to that dependency search, and
makes no process-wide DLL search mutation. Buffers use Lua allocation so error
unwinding cannot leak native allocations. Windows' loader still owns its
standard already-loaded-module/KnownDLL/API-set behavior.

This policy controls Lua's explicit dynamic loads; Titan's explicit module
loader uses the same dependency-search flags. Titan's `lua.exe`, `titanc.exe`,
and application launchers import `lua-5.5.1.dll` before runtime initialization.
These flags do **not** constrain initial EXE
import resolution when its adjacent Lua DLL is absent. The distribution must
retain the controlled Lua DLL beside each of these EXEs. Arbitrary long-path
support is not promised.

The executable embeds per-process UTF-8 `activeCodePage` and `longPathAware`
manifest declarations for Windows 11. This build does not change machine code
pages or the OS long-path policy. The latter declaration is only the application
opt-in: usable path lengths still depend on OS policy and each API in the path.
See [Microsoft's long-path requirements](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation).
Real Unicode command-line,
filesystem, module, and process behavior must be tested with CLANG64/UCRT.
See [Microsoft's UTF-8 process guidance](https://learn.microsoft.com/en-us/windows/apps/design/globalizing/use-utf8-code-page)
and [DLL search flags](https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-loadlibraryexw).

## Verification boundaries

`make -f Makefile.windows lua-source-check` can run on Linux with Clang and
`llvm-readobj`. It compiles real x64 COFF header consumers in four source-role
combinations, checks C++ opener linkage and producer annotations, and compiles
an actual Lua data definition. It neither substitutes Windows SDK headers nor
builds a Windows DLL.

On native CLANG64, `lua-check` verifies the exact DLL export inventory, imports,
installed source/header bytes, and a real SDK consumer. It then relocates the
runtime into a path containing spaces and non-ASCII characters, runs from a
different CWD without toolchain PATH entries, and loads Lua and native modules.
A separate canary fails when its dependency exists only in the provider
folder, CWD, and PATH; a fresh process succeeds after that dependency is placed
beside `lua.exe`. Relative explicit provider paths are checked too. The separate PowerShell
gate repeats those checks using native Windows paths and process-local PATH
restriction; it does not depend on MSYS argument conversion.

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
libuv 1.53.0, llhttp 9.4.3, SQLite 3.53.4, and OpenSSL 3.5.7 from the pinned,
checksum-verified sources recorded in `vendor/windows-native/dependencies.tsv`.
Those pins match the ordinary Makefile. CMake/Ninja build the first three;
OpenSSL uses its upstream `mingw64` configuration, Perl, Make, and
`llvm-windres`. No independently built MSYS2 native-library binaries are used.
This experimental Windows SDK keeps its separate pinned OpenSSL DLL build;
the Unix `OPENSSL_MODE=system` default does not select Windows dependencies.

```sh
make -f Makefile.windows native-source-check
make -f Makefile.windows native-check PREFIX=/c/Titan/sdk
```

| Runtime in `bin/` | Import library in `lib/` |
| --- | --- |
| `libuv-1.dll` | `libuv.dll.a` |
| `libllhttp-9.4.dll` | `libllhttp.dll.a` |
| `libsqlite3-0.dll` | `libsqlite3.dll.a` |
| `libcrypto-3-x64.dll` | `libcrypto.dll.a` |
| `libssl-3-x64.dll` | `libssl.dll.a` |

The runtime names express the reviewed upstream ABI versions; exact release
and configuration identities remain pinned separately. Names are selected
before linking, so import libraries refer to the installed DLL names. Matching
public headers, including OpenSSL's configured generated headers, are staged
under `include/`. The runtime gate checks OpenSSL's reported configuration
directory against its native Windows path spelling. Upstream native static archives may exist inside private
build directories but are never installed into this SDK.

The configured llhttp and SQLite Windows headers distinguish each DLL producer
from ordinary SDK consumers. Only their library targets define
`TITAN_LLHTTP_BUILD_DLL` or `TITAN_SQLITE_BUILD_DLL`; consumer functions and
SQLite's exported data use explicit imports. libuv retains upstream's
`BUILDING_UV_SHARED`/`USING_UV_SHARED` contract. These transformations are confined
to dedicated Windows source copies.

The reviewed configuration disables OpenSSL automatic configuration, dynamic
providers/modules, DSO loading, the legacy provider, compression, QUIC, and its
command-line applications/tests. It keeps the built-in provider and native
threading. The DLL is not literally inert at load time: upstream
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
`windows-build/native-check/native-probe-path.txt` from ordinary PowerShell
with the argument in `native-config-path.txt`, a restricted process PATH, and
another CWD as well. A native compile,
import-closure audit, and successful native behavior checks are required before
using this experimental SDK. Host COFF checks alone do not validate these DLLs.

## Runtime SDK and compiler bootstrap

`Makefile.windows.compiler` builds the native UTF-16 argument frontend,
`bin/titanc.exe`, its `bin/titanc.lua` companion, and the compiler's Lua/native
dependencies. It stages compiler modules from the rockspec's explicit module
inventory. See [the compiler bootstrap contract](../windows-compiler-bootstrap.md)
for its argument, relocation, initialization, and dependency checks.

`Makefile.windows.runtime` builds `libtitan.a` from exactly `titan.o` and
`minicoro.o`, plus the separate support-only `titan.dll` from `ltitanlib.o`.
The private, namespaced LPegLabel archive contains exactly its five upstream
translation units and remains build payload. All objects use the installed,
configured Lua source headers and matching `lua-5.5.1.dll` import library.
Only the runtime archive and public runtime/FFI headers are installed as SDK
files; private Windows loader/filesystem headers and the PEG archive stay in
the build tree. Third-party notices and license texts are staged under
`share/titan/` with the runtime SDK.

```sh
make -f Makefile.windows compiler-check runtime-check PREFIX=/c/Titan/sdk
```

Runtime staging seeds `lib/titan/0.6/titan.dll` only when absent. An existing
image must provide the current native support contract and is preserved,
including when it carries the complete standard library. Validation runs in
a separate Lua process that exits before publication, avoiding a mapped
destination DLL in the publisher. This serial installer does not promise
concurrent-writer or crash-atomic publication.

The build stamp records source/header bytes, tools, flags, and the controlled
Lua binary/import pair. Warm reuse also checks output hashes and exact archive
member inventories. `runtime-check` links the complete runtime and private PEG
payload into a native consumer, checks permitted PE imports, and exercises
Lua/PEG and explicit-runtime coroutine yield/resume/destruction. It verifies
unchanged warm timestamps, repairs deliberately corrupted private outputs,
and proves that staging preserves an existing valid support image with extra
payload. These checks cover the SDK foundation; complete Titan coroutine,
standard-library, language-server, and extension behavior require their own
native tests.

## Standard-provider build and publication

`Makefile.windows.stdlib`, included by `Makefile.windows`, uses the installed
native compiler and the controlled runtime/native SDK:

```sh
make -f Makefile.windows install-stdlib PREFIX=/c/Titan/sdk
```

The initial experimental `stdlib` target compiles all 22 explicit roots serially
from source into one `titan.dll`; it does not claim an incremental completion
stamp. `stdlib-check` validates an existing stage, and `publish-stdlib` validates
and installs without rebuilding it. Both use a fresh child to check exact PE
exports, permitted imports, callable metadata against source objects, generated
shims and `titan/test.titan`. Publication then runs separately with a copied
private bootstrap, leaving the destination provider unmapped by the publisher.
The accepted predecessor is absent, support-only, the exact pre-WebSocket
21-module provider, or the complete current 22-module provider; unfamiliar
files and incomplete inventories are rejected. The bounded 21-to-22 growth
requires no existing WebSocket shim; publication includes the new shim in the
same rollback transaction as every previous shim and the DLL.
The source-only `TITAN_INSTALL_FAIL_AT=after:dso` regression hook injects a
caught failure after the final DLL commit to verify restoration of the exact
predecessor, including removal of the new shim.

The provider links the system Winsock import library `ws2_32` for the private
UV address helper's byte-order conversion. Its PE import audit permits
`WS2_32.dll` explicitly. Ordinary compiled Titan clients call the provider and
do not need this import library or private UV headers themselves.

The installed files are `lib/titan/0.6/titan.dll`, the 22 shims under
`share/lua/5.5/titan`, and `share/titan/0.6/src/titan/test.titan`. No Titan `.a`
provider or Titan import library is published. `--static` is unsupported on
Windows. Removed logical modules do not trigger automatic stale-shim cleanup;
build such a changed provider in a fresh output directory. A DLL mapped by
another process blocks replacement; caught publication failures restore prior
file bytes, without promising crash atomicity or concurrent publication.
Publication currently requires an ordinary SDK directory and ordinary internal
parent directories; junction/symlink destinations fail validation.

## Shared native standard-library tests

After publishing the current provider, run the complete common suite from
CLANG64. Choose a disposable workspace on a local NTFS volume:

```sh
make -f Makefile.windows titan-stdlib-test-build \
  PREFIX=/c/Titan/sdk TITAN_TEST_BUILD_DIR=/c/Titan/native-tests
make -f Makefile.windows titan-stdlib-test-run \
  PREFIX=/c/Titan/sdk TITAN_TEST_BUILD_DIR=/c/Titan/native-tests
```

`titan-stdlib-test` composes both steps. `TITAN_FILTER` selects a runtime Lua
pattern without narrowing compilation; omit it for complete validation. The
compatibility entrypoint `scripts/check_windows_stdlib_behavior.sh WORKSPACE SDK`
also builds and runs the full shared suite. There is no separate Windows case
allowlist: `spec/support/stdlib_test_modules.mk` supplies the same 27 explicit
roots to all three platforms, including filesystem, SQLite, and local watchers.

The build copies the supplied SDK and authored fixtures into its marked
workspace, preserving the published SDK. It rejects unrelated existing
directories and nonlocal or non-NTFS workspaces. Test outputs, scratch files,
native child executables, and logs stay inside that workspace. The runner uses
the bounded Job Object supervisor and drains both output streams, including
when the aggregate fails or times out. `TITAN_TEST_TIMEOUT` defaults to 300
seconds. Keep the complete native exit status, including values above 255.
The test launcher reserves 8 MiB of stack so the common deep-recursion oracles
also run with `-O0` providers. Fresh-process fixtures copy the selected SDK's
runtime DLLs beside their child executables and preserve normal
executable-relative provider lookup. Both settings are private to the harness.

The output audit reports selected, passed, skipped, and failed cases, checks
that every owner executed, and requires each exclusion to name its semantic,
environment, or production-API reason. An unfinished fixture port fails the
gate. Native C fixtures are compiled on Windows even when an individual
platform-specific assertion is skipped. See the
[shared harness contract](test-runner.md#platform-portability-and-complete-execution).

A complete provider build and unfiltered behavior run remain required; runtime,
launcher, or publication canaries alone are insufficient. Record the source
revision, SDK identity, native OS/architecture, provider optimization, local
filesystem, and classified skip reasons. Repeat the shared suite with both
`-O0` and `-O3` providers when validating the Windows port.

## Experimental boundaries

Windows compilation is serial and the initial stdlib target rebuilds its
explicit roots. Windows error traces retain Lua frames and raw native addresses;
native Titan source-line attribution is not yet available. `titan.io.popen`
uses the system `cmd.exe` with `/d /s /c`, writable stdin, and merged output.
Its command string must use native Windows shell syntax; see
[shell commands](../language/standard-library-io.md#shell-commands). Use
`titan.os.spawn` for direct executable and argument control. Both retain the
existing process ownership rules, without a descendant-termination guarantee.

The packaged OpenSSL configuration supplies no usable default CA roots and does
not automatically use the Windows ROOT certificate store. Its compiled CA file
and directory paths refer to the original build prefix; moving the SDK does not
relocate them. Use the existing `ssl.connect(host, port, ca_file)` PEM-file
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
