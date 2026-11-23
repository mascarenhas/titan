# Installing Titan on Linux and macOS

The default installation puts three components under one absolute `PREFIX`
directory chosen for your project:

- **Lua 5.5.1 from Titan's fork** ([release `v5.5.1-1`](https://github.com/mascarenhas/lua-5.5.1/releases/tag/v5.5.1-1)),
  which installs `liblua.a` built with `-fPIC` alongside matching internal and
  public headers.
- **Stock LuaRocks 3.13.0**, configured for that Lua and prefix.
- **Titan**, built and installed via `luarocks install titan`.

For Windows, see [Installing and using Titan on Windows](windows-build.md).

## The default installation

Install the packages in [Requirements](#requirements) first, then build Lua
and LuaRocks into your prefix and install Titan. On macOS, replace
`linux-readline` with `macosx` (see [Readline on macOS](#readline-on-macos)):

```sh
export PREFIX="$HOME/.local/titan/my-project"

# 1. Lua 5.5.1 from Titan's fork
curl -fL -o lua-titan.tar.gz https://github.com/mascarenhas/lua-5.5.1/archive/refs/tags/v5.5.1-1.tar.gz
tar zxf lua-titan.tar.gz
(cd lua-5.5.1-5.5.1-1 &&
  make linux-readline PREFIX="$PREFIX" &&
  make install PREFIX="$PREFIX")

# 2. Stock LuaRocks 3.13.0
curl -fLO https://luarocks.github.io/luarocks/releases/luarocks-3.13.0.tar.gz
tar zxf luarocks-3.13.0.tar.gz
(cd luarocks-3.13.0 &&
  ./configure --prefix="$PREFIX" --rocks-tree="$PREFIX" --with-lua="$PREFIX" --force-config &&
  make && make install)

# 3. Titan from LuaRocks
export PATH="$PREFIX/bin:$PATH"
luarocks install titan
titanc --print-root
```

Keep `$PREFIX/bin` first on `PATH` so `lua`, `luarocks`, and `titanc` all come
from the same installation. `titanc --print-root` prints `$PREFIX` when the
installation is ready.

### Why Titan uses a Lua fork

Generated Titan C includes Lua's internal headers and links against
`liblua.a`. Titan's fork of Lua 5.5.1 makes two packaging changes:

1. **Installed internals and `-fPIC`:** `make install` installs the matching
   `.c`/`.h` sources in `$PREFIX/src/lua-5.5.1/` alongside `liblua.a`, and
   compiles with `-fPIC` on Unix even when `MYCFLAGS` is set so `liblua.a` can
   link into shared objects.
2. **Executable-relative `!` paths on Unix:** As stock Lua does on Windows,
   the fork expands `!` in Lua module paths to the running executable's
   directory (resolved via `/proc/self/exe` on Linux or `_NSGetExecutablePath`
   on macOS) and roots defaults at `!/../`. `<root>/bin/lua` therefore finds
   its modules under `<root>/share/lua/5.5` and `<root>/lib/lua/5.5` even
   through symlinks.

LuaRocks itself is unmodified.

### Requirements

| Requirement | Needed for |
| --- | --- |
| C compiler, `ar`, `ranlib`, `make` | Everything. |
| `git` | Cloning libbacktrace, applying Titan's libuv patch, and cloning checkouts. |
| CMake | Building bundled libuv. |
| `curl` or `wget`, `tar`, `sha256sum` or `shasum` | Downloading, verifying, and unpacking sources. |
| Readline development files | Lua's `linux-readline` and `macosx` targets. |
| OpenSSL 3.0+ development files and `pkg-config` | Default system-OpenSSL mode for `titan.ssl`. |
| Perl | Only for `OPENSSL_MODE=bundled`. |
| `clang-format` | Only for `titanc --pretty-print` (`CLANG_FORMAT` overrides). |
| Emscripten 6.0.13 | Only for `--target browser` and [the browser Lua and SDK](#the-browser-lua-and-sdk). |
| Node 26+ with WebAssembly JSPI | Only for browser SDK publication, linking, and CLI execution (`TITAN_NODE` or `PATH`; not emsdk's bundled Node 24). |
| JSPI-capable Chrome or Chromium headless shell | Only for browser-engine runs via `titan-browser-run`. |

Package-manager commands for the core prerequisites:

```sh
# Ubuntu/Debian
sudo apt-get install build-essential cmake curl git libreadline-dev libssl-dev pkg-config

# Fedora
sudo dnf install gcc make cmake curl git readline-devel openssl-devel pkgconf-pkg-config

# macOS (curl, tar, shasum, and git come with Xcode Command Line Tools)
xcode-select --install
brew install cmake readline openssl@3 pkgconf
```

During `luarocks install titan`, the build downloads and verifies its pinned
native dependencies—libuv 1.53.0, llhttp 9.4.3, SQLite 3.53.4, libbacktrace
(from `LIBBT_URL`), and OpenSSL 3.5.7 when `OPENSSL_MODE=bundled`—plus four
Lua rocks (`lpeglabel`, `inspect`, `argparse`, `luafilesystem`).

## Choosing the prefix

`PREFIX` must be an absolute, writable path. Use a separate prefix per project
or build configuration, and keep `PREFIX` (Lua and LuaRocks) equal to
`ROCKS_TREE` (Titan's rock, SDK, and standard library) for the standard
layout.

- **Moving a prefix:** Executable-relative `!` paths follow a moved directory
  for module lookup, but LuaRocks's Unix `bin/titanc` wrapper embeds the
  original interpreter path. After copying or moving a Unix prefix, reinstall
  Titan in the copy or set `TITAN_ROOT` to the new directory.
- **Versions:** Titan `0.6.1` uses library version `0.6` in paths such as
  `lib/titan/0.6` and `TITAN_PATH_0_6`. Patch releases in the same series share
  that namespace and keep compiled native providers compatible when the ABI
  does not change, while release-matched artifacts—browser semantic companions
  and saved language-server project caches—require the exact Titan release and
  must be regenerated, and `--incremental` objects compiled from source normally
  miss and rebuild against the updated compiler and SDK headers. Always install
  into a fresh prefix when upgrading across breaking prereleases.

## Other installation types

### From a Git checkout

A Git checkout provides Makefile targets for Lua, LuaRocks, and installing
Titan directly from the working tree:

<!-- doc-check: setup=checkout -->
```sh
git clone --recurse-submodules https://github.com/mascarenhas/titan
cd titan
export PREFIX="$HOME/.local/titan/my-project"
make lua PREFIX="$PREFIX"
export PATH="$PREFIX/bin:$PATH"
make luarocks
luarocks make
```

- If you cloned without `--recurse-submodules`, initialize the pinned
  `lua-5.5.1` submodule with `git submodule update --init --recursive`.
- `make lua` selects `linux-readline` on Linux, `macosx` on macOS, and `linux`
  elsewhere (`LUA_PLATFORM` overrides). Pass custom Lua build flags via
  `LUA_MYCFLAGS`, `LUA_MYLDFLAGS`, `LUA_MYLIBS`, `LUA_CC`, `LUA_AR`, and
  `LUA_RANLIB`.
- `make lua` and `make luarocks` skip rebuilding if `$PREFIX/bin/lua` or
  `$PREFIX/bin/luarocks` already exists. Clean Lua's objects and remove the
  installed binary before rebuilding Lua with different flags or tools.
- When `PREFIX` is omitted, Make derives it from the active Lua 5.5 on `PATH`,
  falling back to `/usr/local`. Pass `PREFIX` explicitly to `make lua`.

### Bundled OpenSSL

By default, `titan.ssl` links against system OpenSSL 3.0+ discovered through
`pkg-config`. To download, verify, and statically bundle pinned OpenSSL 3.5.7
instead (requires Perl), set `OPENSSL_MODE=bundled`:

```sh
OPENSSL_MODE=bundled luarocks install titan
```

With no CA override, TLS clients use OpenSSL's compiled default certificate
paths; see [TLS standard library](standard-library-ssl.md) for explicit CA
files.

### Readline on macOS

Homebrew's `readline` formula is keg-only. Supply its include and library
paths when building Lua (the fork adds `-fPIC` automatically):

```sh
(cd lua-5.5.1-5.5.1-1 &&
  make macosx PREFIX="$PREFIX" \
    MYCFLAGS="-I$(brew --prefix readline)/include" \
    MYLDFLAGS="-L$(brew --prefix readline)/lib" &&
  make install PREFIX="$PREFIX")
```

In a Git checkout, pass the same flags to `make lua` as `LUA_MYCFLAGS` and
`LUA_MYLDFLAGS`.

### Without Readline

On Linux, build Lua's `linux` target instead of `linux-readline` (or pass
`LUA_PLATFORM=linux` to `make lua` in a checkout).

### A stock Lua tree

Titan links `liblua.a` into shared objects, so a stock Lua 5.5.1 tree passed
to a checkout compiler with `titanc --lua` must be compiled with
`MYCFLAGS=-fPIC` (use `macosx` on macOS):

```sh
(cd lua-5.5.1 && make linux-readline MYCFLAGS=-fPIC)
```

Titan's fork adds `-fPIC` automatically and never needs this flag.

### Your own compiler and flags

Set `CC`, `AR`, and `RANLIB` consistently across Lua, LuaRocks, Titan, and
your projects. Add extra flags with `TITAN_EXTRA_CPPFLAGS`,
`TITAN_EXTRA_CFLAGS`, and `TITAN_EXTRA_LDFLAGS` (see
[Environment variables](toolchain.md#environment-variables) and
[Build profiles](toolchain.md#build-profiles)).

`TITAN_JOBS` (or `titanc -j N`, default `4`) bounds concurrent workers and
native compiles. On macOS, stock GNU Make 3.81 cannot share a jobserver pool;
installing Homebrew GNU Make 4.4+ (`brew install make`, with
`$(brew --prefix)/opt/make/libexec/gnubin` first on `PATH`) enables shared
jobserver pools automatically, or set `TITAN_JOBS=4` explicitly.

### A separate rocks tree

On Unix, you can install Titan into a separate `ROCKS_TREE` while keeping Lua
and LuaRocks in `PREFIX`:

```sh
luarocks --tree "$HOME/titan-tree" install titan
```

Because Lua's default paths point to `PREFIX`, configure the environment as
shown in [How Titan finds its installation](#how-titan-finds-its-installation).
In a checkout, pass `ROCKS_TREE=...` to Make publishing targets as well.
Windows requires `PREFIX` and `ROCKS_TREE` to be identical.

### A binary rock

After installing Titan into a prefix, pack a binary rock from a checkout with
`make binary-rock` (do not use `luarocks pack --pack-binary-rock`, and note
that plain `luarocks pack titan` mislabels native files as `.all.rock`).
Install the resulting `titan-0.6.1-1.<arch>.rock` with `luarocks install` to
deploy without compiling.

### A debug (validation) installation

The `validation` profile compiles generated code, Titan's runtime, and native
payloads with `-O0 -fno-lto -g`. Always give it its own prefix:

```sh
TITAN_BUILD_PROFILE=validation make lua luarocks PREFIX="$PWD/.lua-validation"
TITAN_BUILD_PROFILE=validation .lua-validation/bin/luarocks make --force
```

An installation records its profile in `etc/titan/build-profile`. See
[Build profiles](toolchain.md#build-profiles).

### Building the standard library from a checkout

After installing Titan, rebuild or reinstall standard-library edits from a
checkout without reinstalling the compiler:

```sh
make stdlib          # incremental rebuild of changed modules and providers
make install-stdlib  # build if needed and publish to the selected tree
make clean-stdlib    # remove standard-library build outputs
```

Both build targets invoke `titanc --incremental`. When changing native tools,
flags, build profile, or `OPENSSL_MODE`, clean authored runtime and native
dependency outputs (`make clean`, or `make clean-llhttp`, `clean-sqlite3`,
`clean-openssl`). Pass `STDLIB_USE_INSTALLED_RUNTIME=0` to test uncommitted
compiler or runtime edits without running `luarocks make`. For the full test
workflow, see [Repository workflow](../implementation/repository-workflow.md).

### The browser Lua and SDK

Targeting WebAssembly (`titanc --target browser`) requires Emscripten 6.0.13,
Node 26+ with JSPI, the browser Lua archive, and the browser SDK in the same
prefix as Titan (plus headless Chrome/Chromium for browser-engine runs with
`titan-browser-run`). Plain `luarocks install titan` and `luarocks make` never
require Emscripten.

After installing Titan from a checkout and activating Emscripten 6.0.13
(`source <emsdk>/emsdk_env.sh`), install the browser Lua and browser SDK:

<!-- doc-check: run -->
```sh
make lua-browser PREFIX="$PREFIX"
make browser-sdk PREFIX="$PREFIX"
```

On Windows, run `make -f Makefile.win lua-browser` and
`make -f Makefile.win browser-sdk` from MSYS2 CLANG64 (see
[Build for the browser](windows-build.md#build-for-the-browser)).

- `titanc` locates `emcc` (along with `emar` and `emranlib`) under
  `$EMSDK/upstream/emscripten` when `EMSDK` is set, or via `PATH`, and
  requires exact Emscripten **6.0.13**.
- `make lua-browser` builds the fork's `browser` target into
  `$PREFIX/lib/browser/` using Emscripten's legacy Wasm exception contract
  (`-sSUPPORT_LONGJMP=wasm -sWASM_LEGACY_EXCEPTIONS=1`) without touching
  native Lua. Existing installations are reused only when the fork commit,
  Emscripten version, compile settings, and file digests all match.
- `make browser-sdk` builds the browser runtime, loader, runner, and standard
  library into `lib/titan-browser/0.6/` under the active `TITAN_BUILD_PROFILE`
  (recorded in `build-profile`; links under the other profile are refused). It
  validates the standard library with `TITAN_NODE` (or `node` on `PATH`,
  requiring Node 26+ with JSPI; emsdk's bundled Node is ignored). In a
  [separate rocks tree](#a-separate-rocks-tree), pass both `PREFIX` and
  `ROCKS_TREE`.
- To install the browser Lua directly from a standalone source archive of the
  pinned fork commit, pass `FORK_REVISION=<40-hex commit>` to
  `make install-browser PREFIX="$PREFIX"`.
- Re-run both targets after updating Emscripten, the Lua fork, or Titan. Use
  `make uninstall-browser-sdk PREFIX="$PREFIX"` to remove only the browser
  SDK.

## What gets installed

All paths live under `ROCKS_TREE` (`PREFIX` in the default layout):

| Path | Contents |
| --- | --- |
| `bin/titanc`, `bin/titan-install`, `bin/titan-uninstall` | Compiler, module rock publisher, and uninstaller. |
| `share/lua/5.5/titan-compiler/`, `share/lua/5.5/c-parser/` | Compiler Lua modules. |
| `src/lua-5.5.1/`, `lib/liblua.a`, `include/` | Matching Lua 5.5.1 sources, static archive, and public headers. |
| `lib/titan/0.6/libtitan.a` | Runtime archive (`titan`, `minicoro`, module path/searcher, support module). |
| `lib/libbacktrace.a` | Native stack unwinder and symbolizer. |
| `include/minicoro.h`, `titan.h`, `transfer.h`, `titan/ffi.h` | Titan SDK and FFI headers. |
| `include/uv.h`, `include/uv/`, `include/llhttp.h`, `include/sqlite3.h` | Headers for bundled libuv, llhttp, and SQLite (plus `include/openssl/` in bundled OpenSSL mode). |
| `lib/titan/0.6/titan.so`, `lib/titan/0.6/titan.a` | Dynamic and static standard-library providers holding all 26 native standard modules and their private native payloads (plus `titan.so.dSYM` on macOS). |
| `lib/titan/0.6/sdk-digests` | Precomputed SDK file digests for fast incremental builds. |
| `lib/lua/5.5/titan.so` | Lua support module loaded by `require "titan"` (installs Titan's package searcher). |
| `etc/titan/build-profile` | Installed build profile (`production` or `validation`). |
| `share/titan/LICENSE`, `THIRD_PARTY_NOTICES.md`, `LICENSES/` | Titan and third-party license notices. |

Optional browser installs add `lib/browser/` (`liblua.a`, headers, build
record) and `lib/titan-browser/0.6/` (browser runtime, loader, runner, and
21-module browser standard library), kept separate from `lib/titan/0.6/`.

## How Titan finds its installation

For an interpreter at `$PREFIX/bin/lua`, Lua expands `!` to `$PREFIX/bin`:

- `package.path` searches `$PREFIX/share/lua/5.5`.
- `package.cpath` searches `$PREFIX/lib/lua/5.5`, where `require "titan"`
  loads Titan's support module and installs Titan's package searcher.
- Titan's runtime default path (`!;!/../lib/titan/0.6`) searches
  `$PREFIX/lib/titan/0.6`, so standard modules load immediately:

```sh
lua -e 'require "titan"; assert(require("titan.string"))'
```

`titanc` selects its SDK root from `TITAN_ROOT` when non-empty, otherwise from
the parent directory of its Lua interpreter (or `titanc.exe` on Windows).
Compiled programs search `!;!/../lib/titan/0.6` and then fall back once per
Lua state to `TITAN_ROOT` or `titanc --print-root`; see
[The Titan path](toolchain.md#the-titan-path).

When using a [separate rocks tree](#a-separate-rocks-tree), point Lua and
Titan at `ROCKS_TREE` without putting `lib/titan/0.6` on `LUA_CPATH_5_5`:

```sh
export TITAN_ROOT="$ROCKS_TREE"
export LUA_PATH_5_5="$ROCKS_TREE/share/lua/5.5/?.lua;$ROCKS_TREE/share/lua/5.5/?/init.lua;;"
export LUA_CPATH_5_5="$ROCKS_TREE/lib/lua/5.5/?.so;;"
```

See [Running with a stock Lua](toolchain.md#running-with-a-stock-lua) for
unmodified Lua 5.5.1 interpreters, and
[Environment variables](toolchain.md#environment-variables) for `TITAN_ROOT`,
`TITAN_PATH_0_6`, `TITANC`, `TITAN_NO_LINE_DIRECTIVES`, and
`TITAN_PROBE_CACHE_DISABLE`.

## Native dependencies

### libuv

Titan builds a pinned, patched static PIC libuv 1.53.0 and carries it inside
`titan.so` and `titan.a` (system libuv is unsupported; leave `LIBUV_MODE`
unset). To customize CMake toolchain flags for libuv in a checkout, set
`LIBUV_CMAKE_FLAGS`; run `make libuv-config` to inspect its flags.

A compiled Titan extension that uses `foreign import "uv.h"` must import
`"uv"` and leave `uv_*` symbols unresolved—never link `-luv` or embed a second
copy of `libuv.a`:

```text
local uv = import "uv"
foreign import "uv.h"

function libuv_version(): integer
  return ffi.uv_version()
end
```

On Linux, `titanc` compiles C in `--std=c99` mode, so extensions that directly
include `<uv.h>` need `-D _POSIX_C_SOURCE=200809L` (or `-D _GNU_SOURCE`) on
the `titanc` command line.

Titan opens compiled providers with `RTLD_LAZY | RTLD_GLOBAL`, so the module
initializer loads `titan.so` globally before any Titan call executes `uv_*`.
If Lua loads such an extension directly, preload `titan.uv` first:

```lua
require "titan"
local uv = require "titan.uv"
local extension = require "my.libuv_extension"
```

### llhttp, SQLite, and OpenSSL

`titan.http` and `titan.sqlite3` always bundle pinned private builds of llhttp
9.4.3 and SQLite 3.53.4 inside `titan.so` and `titan.a`. OpenSSL defaults to
system OpenSSL 3.0+ and supports [Bundled OpenSSL](#bundled-openssl).

## Uninstalling

Run `titan-uninstall` with no arguments from the installation to remove Titan
itself (plain `luarocks remove titan` leaves external SDK and provider files
behind). It asks LuaRocks to remove all installed Titan rock versions in the
tree and, on success, deletes Titan's SDK headers, providers, runtime archive,
notices, build-profile marker, and `make browser-sdk` files—leaving Lua,
LuaRocks, dependency rocks, user archives, and `lib/browser/` intact. Pass
`--luarocks PATH` to select a specific LuaRocks executable.

To remove a Titan module rock installed through `titan-install`, pass its rock
name (and optional full rock version) as `titan-uninstall ROCK [VERSION]`; see
[Uninstalling modules](modules.md#uninstalling).

Run `make uninstall-browser-sdk PREFIX="$PREFIX"` from a checkout to remove
only the browser SDK files in `lib/titan-browser/0.6/`.

## Cleaning a checkout

Use `make clean` and `make distclean` (summarized below), or clean one
dependency at a time with `clean-luarocks`, `clean-libbacktrace`,
`clean-libuv`, `clean-llhttp`, `clean-sqlite3`, `clean-openssl`, and
`clean-lua`. None of these targets touches external installed prefixes.

## What each command removes

| Command | Removes |
| --- | --- |
| `titan-uninstall` | Titan rock, native SDK/provider files, and `make browser-sdk` files in `lib/titan-browser/<ver>/`. |
| `titan-uninstall ROCK [VERSION]` | Selected Titan module rock and its `titan-install`-published files under `lib/titan/<ver>/`, `include/`, and `lib/` ([Uninstalling modules](modules.md#uninstalling)). |
| `make uninstall-browser-sdk` | `make browser-sdk` files in `lib/titan-browser/0.6/` (and the directory when empty). |
| `make clean` | Checkout `out/` tree (including browser SDK/stdlib builds) and generated build artifacts. |
| `make distclean` | Everything `make clean` removes, plus downloaded dependency trees and checkout-local `.lua`. |
| *(manual)* | Browser Lua in `lib/browser/` stays with `PREFIX`'s Lua installation until deleted manually. |
