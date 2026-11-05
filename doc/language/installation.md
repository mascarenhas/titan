# Installing Titan on Linux and macOS

The [README](../../README.md#install) gives the short, default installation.
This chapter explains what those commands do, what you need, and how to install
Titan in other ways. For Windows, see
[Installing and using Titan on Windows](windows-build.md).

The default installation puts three things under one absolute prefix that you
pick for the project:

- **Lua 5.5.1 from Titan's fork,** release
  [`v5.5.1-1` of mascarenhas/lua-5.5.1](https://github.com/mascarenhas/lua-5.5.1/releases/tag/v5.5.1-1).
- **Stock LuaRocks 3.13.0,** built from its release tarball with its own
  `configure`, `make`, and `make install`.
- **Titan,** installed by that LuaRocks with `luarocks install titan`. LuaRocks
  fetches Titan's source rock from the LuaRocks registry.

Afterward, build and run your projects with the Lua, LuaRocks, and `titanc` from
that prefix.

## The default installation

Install the packages in [Requirements](#requirements) first. Then build Lua and
LuaRocks into your prefix and install Titan. On macOS, use `macosx`
instead of `linux-readline`.

```sh
export PREFIX="$HOME/.local/titan/my-project"

# 1. Lua, from the fork's v5.5.1-1 release
curl -fL -o lua-titan.tar.gz https://github.com/mascarenhas/lua-5.5.1/archive/refs/tags/v5.5.1-1.tar.gz
tar zxf lua-titan.tar.gz
(cd lua-5.5.1-5.5.1-1 &&
  make linux-readline PREFIX="$PREFIX" &&
  make install PREFIX="$PREFIX")

# 2. Stock LuaRocks
curl -fLO https://luarocks.github.io/luarocks/releases/luarocks-3.13.0.tar.gz
tar zxf luarocks-3.13.0.tar.gz
(cd luarocks-3.13.0 &&
  ./configure --prefix="$PREFIX" --rocks-tree="$PREFIX" --with-lua="$PREFIX" --force-config &&
  make && make install)

# 3. Titan, from the LuaRocks registry
export PATH="$PREFIX/bin:$PATH"
luarocks install titan
```

These are the commands that `make lua` and `make luarocks` run in a Titan checkout
(see [From a Git checkout](#from-a-git-checkout)). What each step does:

1. **The Lua build.** The fork's `v5.5.1-1` release offers GitHub's automatic source
   archives, so the command downloads the `tar.gz` for the tag. It unpacks into
   `lua-5.5.1-5.5.1-1/`. The fork compiles with `-fPIC` by default, so the command
   passes no compiler flags (see [Why a Lua fork](#why-a-lua-fork-and-what-stock-luarocks-means-here)).
   The build installs Lua under `PREFIX`, including its `.c` and `.h` sources in
   `$PREFIX/src/lua-5.5.1/`. `make install` fails unless `PREFIX` is set.
2. **The LuaRocks build** installs LuaRocks under `PREFIX`, configured to use that
   Lua and to use `PREFIX` as its rocks tree.
3. **`luarocks install titan`** downloads Titan's source rock from the LuaRocks
   registry. A source rock holds the rockspec and the Titan source tree, and LuaRocks
   builds it directly. LuaRocks first fetches the rock's Lua dependencies. It
   then builds the rock with Make's default target, `all`: the Titan runtime, the
   native dependencies, and the whole standard library. Finally it installs the
   compiler, SDK, and standard library. The build needs no Lua sources, only the
   headers and library that step 1 installed.

Keep `$PREFIX/bin` first on `PATH` so that `lua`, `luarocks`, and `titanc` all come
from this installation. To check the result:

```sh
titanc --print-root    # prints the installation root
```

### Why a Lua fork, and what stock LuaRocks means here

Titan-generated C includes Lua's internal headers and links against Lua's static
library, so Titan needs the exact Lua build it was written for. The fork's install
puts the matching `liblua.a`, internal headers, and public headers in `PREFIX`
together, and Titan's native targets use those headers.

The fork changes one thing about how Lua finds modules on Linux and macOS. As
stock Lua already does on Windows, it expands `!` in module search paths to the
directory of the actual executable, and it roots the default paths at `!/../`. An
interpreter at `<root>/bin/lua` therefore finds its modules under
`<root>/share/lua/5.5` and `<root>/lib/lua/5.5`, including after you move the tree or
run it through a symlink. Linux reads `/proc/self/exe`. macOS calls
`_NSGetExecutablePath` and resolves the result with `realpath`. Windows keeps Lua's
stock executable-directory expansion and DLL loading. These paths do not change how
the operating system looks up dependent libraries. Lua's paths do not name Titan's
library directory: Titan finds compiled modules itself (see
[How Titan finds its installation](#how-titan-finds-its-installation)).

The fork's build also differs in one flag. Its Linux, macOS, and BSD targets compile
with `-fPIC`, even when you set `MYCFLAGS`, because Titan links `liblua.a` into shared
objects. Stock Lua leaves the flag to you ([A stock Lua tree](#a-stock-lua-tree)).

LuaRocks is not modified. Its `configure` options above set both `--prefix` and
`--rocks-tree` to `PREFIX` and point `--with-lua` at the same prefix. LuaRocks's
ordinary generated configuration still includes the user tree. To use a custom
compiler or other native tools, pass them explicitly to each LuaRocks command.

### Requirements

| You need | For |
| --- | --- |
| A C compiler, `ar`, `ranlib`, and `make` | Everything. |
| `git` | Cloning libbacktrace and applying Titan's libuv patch during the build (and cloning a checkout). |
| CMake | Building libuv. |
| `curl` or `wget`, `tar`, and `sha256sum` or `shasum` | Downloading, verifying, and unpacking Lua, LuaRocks, and the native dependencies. |
| Readline development files | Lua's `linux-readline` and `macosx` build targets. |
| OpenSSL 3.0 or newer with development files, and `pkg-config` | The default system-OpenSSL mode, used by `titan.ssl`. |
| Perl | Only with `OPENSSL_MODE=bundled`. |
| `clang-format` | Only for `titanc --pretty-print`. |
| Emscripten 6.0.13 | Only for `titanc --target browser`, its [browser Lua, and the browser SDK](#the-browser-lua-and-sdk). |
| Node 26+ with WebAssembly JSPI | Only for browser SDK/library publication and browser program linking/execution; use `TITAN_NODE` or `PATH`, not emsdk's bundled Node 24. |
| JSPI-capable Chrome, Chromium, or Chrome for Testing headless shell | Only for running programs through the browser engine in `titan-browser-run`. |

Install them with your package manager:

```sh
# Ubuntu/Debian
sudo apt-get install build-essential cmake curl git libreadline-dev libssl-dev pkg-config

# Fedora
sudo dnf install gcc make cmake curl git readline-devel openssl-devel pkgconf-pkg-config

# macOS (Apple's curl, tar, shasum, and git come with the command-line tools)
xcode-select --install
brew install cmake readline openssl@3 pkgconf
```

Homebrew's Readline is keg-only, so on macOS see
[Readline on macOS](#readline-on-macos) before building Lua. For `clang-format`,
install the `clang-format` package on Debian/Ubuntu, `clang-tools-extra` on Fedora,
or `brew install clang-format` on macOS. Set `CLANG_FORMAT` to use a different
compatible command.

### What the build downloads

The build needs network access:

- libuv 1.53.0, checked against a SHA-256 hash and then patched with `git apply`.
- llhttp 9.4.3 and SQLite 3.53.4, each checked against a SHA-256 hash.
- libbacktrace, cloned with `git clone` from `LIBBT_URL` (upstream's GitHub
  repository unless you set it).
- OpenSSL 3.5.7, checked against a SHA-256 hash, but only with
  `OPENSSL_MODE=bundled`.
- The rock's Lua dependencies, which LuaRocks fetches from its server:
  `lpeglabel`, `inspect`, `argparse`, and `luafilesystem`.

Downloads and build output go in the build directory and later builds reuse them.

## Choosing the prefix

`PREFIX` is where Lua, LuaRocks, and (in the default layout) Titan go. It must be an
absolute path that you can write to. Use a separate prefix for each project or
configuration, and a fresh prefix if you previously used `luarocks init` or a
user-tree LuaRocks configuration. Launchers such as `busted` embed the active Lua
paths when their rocks are installed, so reinstall them after changing LuaRocks
configuration.

### `PREFIX` and `ROCKS_TREE`

- `PREFIX` holds Lua and the LuaRocks program and configuration.
- `ROCKS_TREE` holds the Titan rock, SDK, and standard library.

The supported developer install and CI use one directory for both. During a rock
install, the rockspec sets `ROCKS_TREE` to the LuaRocks tree being installed into, so
you do not set it yourself. See [A separate rocks tree](#a-separate-rocks-tree) for
the other case.

### Moving a tree

The `!` expansion described above makes Lua's module paths follow a moved tree, and
Titan computes its default root and library directory from the running executable in
the same way. This covers module search only. LuaRocks configuration and installed
command wrappers can still contain absolute paths, so moving a tree does not make
every tool relocatable. In particular, LuaRocks' Unix `bin/titanc` wrapper embeds the
absolute path of the interpreter and of the tree's Lua modules: in a copied tree it
still runs the original installation's Lua, so `titanc` reports the original root.
Reinstall Titan in the copy, or set `TITAN_ROOT` to the copy. The Windows
`bin/titanc.exe` has no such paths: it runs the compiler of the SDK that contains it.

### Versions

`TITAN_VERSION` is the compiler and standard-library version, currently `0.6.0`. Its
major and minor parts give the library version, `0.6`, which names the installed
library and compiler-data paths. `TITAN_ABI_VERSION` is the separate marker for
compiled-module compatibility, currently `2`. Titan assumes a fresh installation: it
provides no migration from earlier installations and no compatibility aliases.
Install into a fresh tree after an ABI change.

### Upgrading from a pre-release build

Earlier development builds of Titan 0.6 wrote a generated Lua loader file (a "shim")
beside each library provider, such as `out/greeting.lua` beside `out/greeting.so` and
`share/lua/5.5/titan/*.lua` for the standard library, and Lua found providers through a
`lib/titan/0.6` entry in `package.cpath`. Titan now writes no such files: Lua's
`require` reaches compiled modules through Titan's package searcher, which
`require "titan"` installs (see
[Requiring a Titan module](lua-interop.md#requiring-a-titan-module)). When you upgrade:

- Delete the old generated `*.lua` loaders from your output trees. Lua's own searchers
  run before Titan's, so a stale loader would still be found first.
- Rebuild pre-release output trees and providers with the current compiler. Titan
  neither converts nor detects files from earlier builds.
- Recreate a direct installation in a fresh prefix with the commands above, including
  Lua. The earlier fork build puts `lib/titan/0.6` on `package.cpath`, where Lua's own
  C searchers can open a provider without Titan's checks, and installing over an old
  prefix leaves its `share/lua/5.5/titan` loaders in place.
- Rename `TITAN_ROCKS_ROOT` to `TITAN_ROOT`, and replace `LUA_CPATH` entries that name
  provider directories with `TITAN_PATH_0_6` entries (see
  [The Titan path](modules.md#the-titan-path)).

## Other installation types

### From a Git checkout

A checkout gives you Makefile targets that run the Lua and LuaRocks steps for you,
and lets you install the rock from the current directory instead of from the registry.

```sh
git clone --recurse-submodules https://github.com/mascarenhas/titan
cd titan
make lua PREFIX="$HOME/.local/titan/my-project"
export PATH="$HOME/.local/titan/my-project/bin:$PATH"
make luarocks
luarocks make
```

- The Lua fork is the `lua-5.5.1` submodule, which pins the fork revision that this
  Titan expects. For Titan 0.6.0 that is the revision tagged `v5.5.1-1`, the same one
  the default installation downloads. If you cloned without `--recurse-submodules`,
  run `git submodule update --init --recursive`.
- `make lua` builds the fork and installs it under `PREFIX`. It picks Lua's
  `linux-readline` target on Linux, `macosx` on macOS, and `linux` elsewhere.
  Override that with `LUA_PLATFORM`. It passes `MYCFLAGS`, `MYLDFLAGS`, and `MYLIBS`
  from `LUA_MYCFLAGS`, `LUA_MYLDFLAGS`, and `LUA_MYLIBS`, and selects the tools with
  `LUA_CC`, `LUA_AR`, and `LUA_RANLIB` (defaulting to `CC`, `AR rcu`, and `RANLIB`).
  `LUA_MYCFLAGS` and `LUA_MYLDFLAGS` default to the build profile's Lua flags: none
  for `production`, and `-O2 -fno-lto` for `validation` (see
  [Native build profiles](build-profiles.md)). The fork adds `-fPIC` on its own, so
  setting `LUA_MYCFLAGS` does not drop it.
- `make luarocks` downloads LuaRocks 3.13.0 and runs the same stock `configure`,
  `make`, and `make install` shown above. It runs `make lua` first.
- `luarocks make` builds and installs the rockspec in the current directory
  (`titan-0.6.0-1.rockspec`). It installs the same rock as
  `luarocks install titan`.

You can also use a checkout only for Lua and LuaRocks, and install Titan from the
registry: run `make lua` and `make luarocks` as above, then
`luarocks install titan`.

`make lua` and `make luarocks` each check for one program only (`$PREFIX/bin/lua`,
`$PREFIX/bin/luarocks`). If it exists, the target does nothing. To rebuild Lua with a
different source, platform, compiler, or flags, clean Lua's objects and remove or
replace `$PREFIX/bin/lua` yourself.

When you pass no `PREFIX`, Make picks one itself. It first looks for a Lua 5.5 `lua` on
`PATH` (ignoring Lua init code) and uses the parent of the directory that really
contains it, following symlinks, but keeping the spelling you launched it with when a
symlink such as `/home` names the same installation. If there is no Lua 5.5, it uses
`/usr/local`. So pass `PREFIX` to the first command, `make lua`; later commands can
leave it out. An explicit `PREFIX` always wins.

Titan's own Make targets use the headers in `$PREFIX/src/lua-5.5.1` and require the
matching `$PREFIX/lib/liblua.a`. If those headers are missing, they fall back to the
checkout's Lua build. If the headers are present but the archive is missing, the
build fails rather than mix the two.

### Bundled OpenSSL

By default `titan.ssl` uses the system OpenSSL, which must be 3.0 or newer and visible
to `pkg-config`. In a checkout, `make openssl` checks that, and the rock's `all`
target runs the same check.

To build the pinned OpenSSL 3.5.7 as a private static library instead, set
`OPENSSL_MODE=bundled`. It needs Perl as well, and the build downloads and verifies
the release. Set it when you install the rock:

```sh
OPENSSL_MODE=bundled luarocks install titan
```

Any other `OPENSSL_MODE` is an error. With no override, the TLS client uses OpenSSL's
compiled default certificate paths. It is not a wrapper around every platform's native
trust store. See the [TLS standard library](standard-library-ssl.md) for explicit
CA-file selection and the verification contract.

### Readline on macOS

Lua's `macosx` target needs Readline. Homebrew's Readline is keg-only, so give Lua its
paths. The fork adds `-fPIC` on its own, so `MYCFLAGS` carries only the include path:

```sh
(cd lua-5.5.1-5.5.1-1 &&
  make macosx PREFIX="$PREFIX" \
    MYCFLAGS="-I$(brew --prefix readline)/include" \
    MYLDFLAGS="-L$(brew --prefix readline)/lib" &&
  make install PREFIX="$PREFIX")
```

In a checkout, pass the same values to `make lua` as `LUA_MYCFLAGS` and
`LUA_MYLDFLAGS`.

### Without Readline

To leave Readline out on Linux, build Lua's plain `linux` target: use `linux` instead
of `linux-readline` in the default commands, or pass `LUA_PLATFORM=linux` to
`make lua` in a checkout.

### A stock Lua tree

Titan links `liblua.a` into the shared objects it builds, so that archive must be
position-independent. Titan's fork compiles it with `-fPIC` by default; stock Lua does
not. A **stock** Lua 5.5.1 tree whose `liblua.a` Titan links must therefore be built
with `MYCFLAGS=-fPIC`, for example (use `macosx` on macOS):

```sh
(cd lua-5.5.1 && make linux-readline MYCFLAGS=-fPIC)
```

Today that is a tree you pass to a checkout compiler with
[`titanc --lua`](#how-titan-finds-its-installation). On Linux, an archive built
without the flag makes the link fail with a relocation error that asks you to
recompile with `-fPIC`. No build of the fork needs the flag.

### Your own compiler and flags

`CC`, `AR`, and `RANLIB` select the tools. They can be command strings. Pass the same
values to every step: the Lua build, LuaRocks, and the consumer builds that use the
installation. Titan compiles with `-O3`, and with link-time optimization on Linux. See
[Native build profiles](build-profiles.md) for the profiles and for cheaper builds. Add
flags with:

- `TITAN_EXTRA_CPPFLAGS`: `-I` and `-D` arguments, shared by C-FFI checking and
  generated compilation.
- `TITAN_EXTRA_CFLAGS`: compilation only.
- `TITAN_EXTRA_LDFLAGS`: the final link only, in order.

Shell quoting in these variables is parsed once, so a path with spaces stays one
argument and malformed quoting is rejected. `titanc` certifies these settings
for every generated Titan object and final link, so changing them recompiles or
relinks exactly what they affect. The Make rules that build Titan's C runtime
and bundled native libraries track them only where
[Native build profiles](build-profiles.md) says so; clean the other native
build outputs after changing these variables.

`TITAN_JOBS` (or `titanc -j N`) caps the module-frontend workers and native
compiler processes active in one `titanc` run: generated-C object
compilations and C validation probe batches. It defaults to four; on Linux and
macOS values above one need the standard POSIX `mkfifo` utility. Inside a GNU
Make recipe `titanc` also shares Make's job slots when the jobserver allows it
([Compiler jobs and GNU Make](build-profiles.md#compiler-jobs-and-gnu-make)).
In a checkout, `make stdlib` and `luarocks make` share one Make job pool of `TITAN_JOBS`
slots unless you pass `make -jN`. GNU Make before 4.2, including macOS's stock 3.81,
builds serially unless `TITAN_JOBS` is set. On macOS, Homebrew's GNU Make gives the best
out-of-the-box experience: run `brew install make` and put
`$(brew --prefix)/opt/make/libexec/gnubin` first on `PATH` (otherwise the formula installs
it only as `gmake`). With GNU Make 4.4 or later every build gets the four-job pool, and
each `titanc` shares it, so a module split with `TITAN_C_PARTS` (opt-in on macOS)
compiles its parts in parallel. With the stock make, set `TITAN_JOBS=4` instead
([Build and test parallelism](build-profiles.md#build-and-test-parallelism)).

### A separate rocks tree

On Unix you can install Titan into a different LuaRocks tree from the one that holds
Lua. Lua and LuaRocks stay in `PREFIX`; the compiler, SDK, and standard library go into
the tree you name:

```sh
luarocks --tree "$HOME/titan-tree" install titan
```

The rockspec records that tree as `ROCKS_TREE`. Lua's default search paths, and the
Titan root that `titanc` derives from the interpreter, point at `PREFIX`. Set
`TITAN_ROOT` to the tree and tell Lua about it, as shown in
[How Titan finds its installation](#how-titan-finds-its-installation). In
a checkout, `ROCKS_TREE` is also a Make variable: when set, Make's publishing targets
(`install-stdlib`, for example) write the SDK and library there, copying the Lua
sources and `liblua.a` into the tree. This is not the default layout. Windows needs
both to be the same directory.

### A binary rock

After installing, run `make binary-rock` in a checkout (with the installed tree
selected) to pack the installed Titan. The result carries the private payload and gets
the platform name from `luarocks config arch`. Plain `luarocks pack titan` also keeps
the payload, but LuaRocks 3.13 labels it `.all.rock`, and that name does not make the
native files portable. LuaRocks 3.13's one-step `--pack-binary-rock` is not supported.
To install the result, run `luarocks install` on the packed
`titan-0.6.0-1.<arch>.rock`. That compiles nothing.

### A debug (validation) installation

The `validation` profile builds Titan and most native dependencies without
optimization and keeps full debug information. Use a separate prefix for it. In a
checkout:

```sh
TITAN_BUILD_PROFILE=validation make lua luarocks PREFIX="$PWD/.lua-validation"
TITAN_BUILD_PROFILE=validation .lua-validation/bin/luarocks make --force
```

The test targets (`make test` and the others listed in the
[repository workflow](../implementation/repository-workflow.md)) select this profile
for you. An installation records its profile in `etc/titan/build-profile`. See
[Native build profiles](build-profiles.md).

### Building the standard library from a checkout

After the rock is installed, you can rebuild the standard library from a checkout
without reinstalling the compiler:

```sh
make stdlib          # rebuild changed modules and affected consumers, then relink
make install-stdlib  # build if needed, then copy to the selected tree
make clean-stdlib    # remove standard-library outputs
```

Both build commands use the installed compiler and its SDK and always run
`titanc --incremental`, which certifies compiler and SDK updates, source imports,
C headers, flags, toolchain, and profile itself; changing any of them rebuilds
only the affected modules and relinks. Titan's authored runtime objects and the
bundled native dependencies are built by Make rules instead: clean them when
their tools, flags, profile, or OpenSSL mode change (`make clean`, or
`make clean-llhttp`, `clean-sqlite3`, and `clean-openssl` for those libraries),
or use a separate source copy and SDK prefix. Libbacktrace and libuv record their
profile, compiler, and flags and rebuild once when those change ([configuration
stamps](../implementation/build-script-audit.md#native-dependency-configuration-stamps)). To exercise edits to the checkout compiler,
reinstall with `luarocks make`, or select the checkout compiler and runtime with
`make stdlib STDLIB_USE_INSTALLED_RUNTIME=0`. `STDLIB_USE_INSTALLED_RUNTIME` defaults to
1 when `bin/titanc` is already installed in the selected tree, and to 0 otherwise. For
the test suite, see the [repository workflow](../implementation/repository-workflow.md).

### The browser Lua and SDK

The [browser target](browser-target.md) needs Emscripten 6.0.13, Node 26+, a
browser build of the Lua fork, and the browser SDK, all in the same prefix as
Titan; running programs and tests in headless Chrome with `titan-browser-run`
also needs Chrome or Chromium. The rock's installation needs none of them:
`luarocks install titan` and `luarocks make` never run Emscripten. Only Linux
and macOS hosts are supported.

With Emscripten active (`source <emsdk>/emsdk_env.sh`), after `luarocks make`
and from the checkout, install the browser Lua and then the browser SDK:

```sh
make lua-browser PREFIX="$PREFIX"
make browser-sdk PREFIX="$PREFIX"
```

`make lua-browser` builds the fork's `browser` target and installs it below
`$PREFIX/lib/browser/`, without touching the native Lua files. It reuses an
existing installation only when the fork commit, the Emscripten version, the
compile settings, and the digests of the installed archive and headers all
match; otherwise it rebuilds. It refuses a missing or different `emcc`, and
Lua settings that the record could not describe truthfully.

The browser compile and link contract is
`-sSUPPORT_LONGJMP=wasm -sWASM_LEGACY_EXCEPTIONS=1`: Emscripten 6.0.13's
legacy Wasm exception encoding. A previous JavaScript-SJLJ archive or a record
without the explicit encoding setting is not reused. Rebuild the browser SDK
after installing the matching Lua; native Lua and native providers are unchanged.

`make browser-sdk` uses the installed `titanc` to build the browser runtime,
loader, runner, and standard library into `lib/titan-browser/0.6/`, and writes
the SDK digest manifest last. It compiles them under the `TITAN_BUILD_PROFILE`
in effect (`production` unless set; see [browser build
profiles](browser-target.md#build-profiles)). It needs Node 26+ with JSPI to
check the standard library before publishing it. `make browser-sdk` uses
nonempty `TITAN_NODE`, otherwise `node` on `PATH`; emsdk's bundled Node is not
substituted. A refusal says `browser provider validation requires Node 26 or
newer: <reason>; set TITAN_NODE to a Node 26 or newer executable`. In a [separate
rocks tree](#a-separate-rocks-tree), pass both roots: `make browser-sdk
PREFIX="$PREFIX" ROCKS_TREE="$ROCKS_TREE"` copies the verified browser Lua from
`PREFIX` into `ROCKS_TREE` before it builds.

The fork's own `install-browser` target installs the browser Lua without the
reuse check. From the fork's release archive, which has no Git metadata, pass
the commit the `v5.5.1-1` tag names as well, because the build record states
the exact commit:

```sh
(cd lua-5.5.1-5.5.1-1 &&
  make install-browser PREFIX="$PREFIX" FORK_REVISION=<40-hex commit>)
```

Rerun both Make targets after changing Emscripten, the fork, or Titan. Every
browser compilation verifies the installed archive, headers, and record and
names the fork's install command when they disagree, and every browser link
names `make browser-sdk` when an SDK file is missing.

### Windows

Windows uses `Makefile.win`, MSYS2 CLANG64, and a different layout. Follow
[Installing and using Titan on Windows](windows-build.md).

## What gets installed

All paths are under `ROCKS_TREE` (the same as `PREFIX` in the default layout).

| Path | Contents |
| --- | --- |
| `bin/titanc`, `bin/titan-uninstall` | The compiler and the uninstaller. |
| `share/lua/5.5/titan-compiler/`, `share/lua/5.5/c-parser/` | The compiler's Lua modules. |
| `src/lua-5.5.1/`, `lib/liblua.a`, and the public Lua headers in `include/` | The matching Lua sources, static library, and headers. |
| `lib/titan/0.6/libtitan.a` | The runtime archive: `titan.o`, `minicoro.o`, `titan_path.o`, and `ltitanlib.o`. A link pulls only the members it references, so a static host can link the support module's `luaopen_titan` from here. |
| `lib/libbacktrace.a` | The native unwinder and symbolizer. |
| `include/minicoro.h`, `titan.h`, `transfer.h` | Top-level SDK headers that are not Lua's. |
| `include/titan/ffi.h` | The portable FFI header and the audited bridge to Lua internals. |
| `include/uv.h`, `include/uv/`, `include/llhttp.h`, `include/sqlite3.h` | Headers for the bundled libuv, llhttp, and SQLite. |
| `include/openssl/` | Headers for bundled OpenSSL, present only in bundled mode. |
| `lib/titan/0.6/titan.so` | The dynamic standard-library provider. It holds every logical standard module (listed below). |
| `lib/titan/0.6/titan.a` | The static form of the same modules, with their private native payload: LPegLabel, libuv, llhttp, SQLite, and OpenSSL in bundled mode. |
| `lib/titan/0.6/titan.so.dSYM` | Debug information, on macOS only. |
| `lib/titan/0.6/sdk-digests` | Content digests the installer recorded for Titan's own `titan.so`, `titan.a`, and `libtitan.a` in `lib/titan/0.6/`, for `lib/libbacktrace.a`, and for the `lib/liblua.a` that Titan links, so `titanc` can skip rehashing them while they are unchanged. When Lua shares the prefix, its existing `liblua.a` is recorded without Titan taking ownership of it. Removed by `titan-uninstall`. |
| `lib/lua/5.5/titan.so` | The support module that `require "titan"` loads: an ordinary Lua C module, owned by the rock, that installs Titan's package searcher and serves the compiler. It is not a provider. |
| `share/titan/LICENSE`, `share/titan/THIRD_PARTY_NOTICES.md`, `share/titan/LICENSES/` | Titan's license and the licenses of bundled code. |
| `etc/titan/build-profile` | The build profile (`production` or `validation`). |

The standard library has 26 logical modules, each with its own state and entry inside
both `titan.so` and `titan.a`:

`coroutine`, `uv`, `async`, `timer`, `io`, `fs`, `net`, `ssl`, `url`, `http`,
`websocket`, `os`, `path`, `peg`, `string`, `math`, `lua`, `iteration`, `gc`, `test`,
`reflect`, `sqlite3`, `json`, `protobuf`, `transfer`, and `thread`.

Installation copies no child DSOs and creates no symbolic or hard links to the
provider. The one `titan.so` supplies the process's single complete libuv. The private
archives (`libuv.a`, LPegLabel, llhttp, bundled OpenSSL) are carried into `titan.so`
and `titan.a` and are not installed as libraries, so applications need no separate LPeg
or LPegLabel module.

The rock installs nothing for the browser target. `make lua-browser`, described
in [The browser Lua and SDK](#the-browser-lua-and-sdk), adds
`lib/browser/liblua.a`, the Lua headers in `lib/browser/include/`, and the build
record `lib/browser/liblua-config.txt`. `make browser-sdk` adds
`lib/titan-browser/0.6/`: the browser runtime `libtitan.a`, the browser PEG
engine `libtitan-lpeglabel.a`, the browser standard library `titan.a` (the
[thirteen modules](browser-target.md#the-browser-standard-library) available to
browser programs, with the PEG engine linked in), the loader `titan-browser.mjs` and its
Emscripten libraries `titan-browser-library.js` and `titan-browser-trace.js`,
the runner `titan-browser-run` with its three `.mjs` modules, and `sdk-digests`. That
directory is never inside `lib/titan/0.6/`, and native builds never search
it. See [the browser SDK](browser-target.md#installing-the-browser-sdk).

### How the rock installs

The rock's `all` target builds everything in its source tree. A fresh tree needs no
installed Titan, because the library build uses the compiler Lua sources in the rock,
the support module built from the rock's runtime sources, and the matching Lua SDK.
Each logical module owns an object and its generated headers, and unchanged objects
are reused. One final incremental `titanc` invocation links all 26 roots, with the
private LPegLabel, libuv, llhttp, SQLite, and TLS/OpenSSL payload.

LuaRocks then runs the copy-only `install` target. It puts the compiler Lua modules in
the rock's Lua directory, the support module in its library directory (LuaRocks
deploys it to `lib/lua/5.5`), and `titanc` and `titan-uninstall` in its `bin`
directory. It keeps a mirrored native SDK and provider payload at
`<rock-prefix>/titan-sdk` and a copier at `<rock-prefix>/installer/titan_install.lua`.
The rock's `post_install` hook runs that copier to place the SDK, providers, licenses,
and (on macOS) the dSYM at their canonical locations. It compiles nothing and needs no
source directory or Makefile. The same copier handles source and binary rock installs.

## How Titan finds its installation

For the interpreter at `$PREFIX/bin/lua`, `!` in Lua's default paths is `$PREFIX/bin`:

- The default `package.path` searches `$PREFIX/bin/../share/lua/5.5`, which holds the
  compiler's Lua modules.
- The default `package.cpath` searches `$PREFIX/bin/../lib/lua/5.5`, which holds the
  support module `titan.so`. `require "titan"` loads it and installs Titan's package
  searcher.
- The searcher finds compiled modules along the [Titan path](modules.md#the-titan-path).
  Its run-time default, `!;!/../lib/titan/0.6`, includes `$PREFIX/lib/titan/0.6`, where
  the standard library is installed.

So a plain `lua` from the installation loads the standard library directly:

```sh
lua -e 'require "titan"; assert(require("titan.string"))'
```

For an installed `titanc`, the root is `TITAN_ROOT` when that is set and non-empty,
otherwise the parent of the directory that contains the Lua interpreter running
`titanc`, with symlinks resolved: `$PREFIX/bin/lua` gives `$PREFIX`. On Windows it is
the parent of the directory that contains `titanc.exe`.
`titanc --print-root` prints that root and compiles nothing. The compiler takes the
SDK headers, `liblua.a`, the runtime archive, and the standard library from below the
root, and searches compiled modules along the compile-time Titan path
`.;<root>/lib/titan/0.6`.

A compiled executable sets up no paths at startup. When it loads a module from a DSO,
it searches its own directory, then `../lib/titan/0.6` beside it, and finally, at
most once per Lua state, the installed SDK: `<TITAN_ROOT>/lib/titan/0.6`, or the
`lib/titan/0.6` below the root that `titanc --print-root` reports. It never searches
the working directory. See [The Titan path](modules.md#the-titan-path) for the
details and for deploying providers with a program.

A Lua whose own paths do not lead to the tree, such as the `PREFIX` Lua of
[a separate rocks tree](#a-separate-rocks-tree), can use the tree through environment
variables:

```sh
export TITAN_ROOT="$ROCKS_TREE"
export LUA_PATH_5_5="$ROCKS_TREE/share/lua/5.5/?.lua;$ROCKS_TREE/share/lua/5.5/?/init.lua;;"
export LUA_CPATH_5_5="$ROCKS_TREE/lib/lua/5.5/?.so;;"
```

`TITAN_ROOT` selects the compiler's root, and Lua hosts and programs reach the
standard library through the SDK fallback. Do not put `$ROCKS_TREE/lib/titan/0.6` on
`package.cpath`: Lua's own C searchers run before Titan's and could open a provider
without Titan's checks. [Running with a stock Lua](modules.md#running-with-a-stock-lua)
shows the same setup for an unmodified interpreter.

Overrides:

- `TITAN_PATH_0_6` (or `TITAN_PATH`) sets the directories searched for compiled Titan
  modules. The compile-time default is the current directory plus
  `<root>/lib/titan/0.6`; the run-time default is described above. Short
  standard-library imports expand before lookup: `import "timer"` becomes
  `import "titan.timer"` and resolves below `$ROCKS_TREE/lib/titan/0.6`.
- `TITAN_ROOT` names the Titan tree directly instead of deriving it from the
  interpreter. A separate Unix tree needs it.
- `TITANC` names the `titanc` program that programs and Lua hosts run for the SDK
  fallback when `TITAN_ROOT` is unset. It is one program name or path, started without
  a shell and with the single argument `--print-root`, not a command line. On Windows,
  a name without a directory is looked up only in the `PATH` entries, with `.exe`
  appended when it has no extension.
- `--lua <path>` selects another complete Lua source and build tree for one compiler
  run. It works only in a source checkout. If the path matches the installed Lua SDK's
  `src/lua-5.5.1/`, linking uses the SDK's `lib/liblua.a`; otherwise it uses that tree's
  own `liblua.a` (for a stock Lua tree, see [A stock Lua tree](#a-stock-lua-tree)). An
  installed compiler rejects `--lua`, because its headers, `lib/liblua.a`, and
  `lib/titan/0.6/libtitan.a` are one matched SDK.

A normal prefix install needs none of these overrides.

Other settings that affect builds:

- `TITAN_NO_LINE_DIRECTIVES=1` (or `--no-line-directives`) leaves generated C attributed
  to its own file and lines. Use it to investigate native diagnostics such as sanitizer
  reports. Tracebacks may then omit native Titan functions, so do not use it for normal
  builds.
- Compiled C-FFI probe results are cached by their full unpreprocessed source, including
  rejected probes. The cache does not track compiler options or header changes. If
  results look stale, clear `<prefix>/var/cache/titan-probes/2` or set
  `TITAN_PROBE_CACHE_DISABLE=1`. A nonempty `TITAN_PREFIX` selects the cache prefix;
  otherwise Titan uses the installed prefix. See the
  [FFI probe cache](c-ffi-expressions.md#compiled-probe-cache).

## Native dependencies

### libuv

Titan's async library uses a pinned, patched libuv 1.53.0, built as a static PIC
library, so neither the compiler nor the standard modules depend on a system libuv. The
rock build fetches, verifies, and builds it. In a checkout, `make libuv` does the same
on its own.

- The build includes a [small Unix spawn cleanup correction](../../vendor/libuv/README.md).
- System libuv is not supported. The build rejects any nonempty `LIBUV_MODE`, so remove
  old overrides.
- Bundled libuv builds only on Linux and macOS.
- In a checkout, `make libuv-config` prints the pinned source, include flags, archive,
  and platform support libraries.
- CMake owns the archiver for the bundled build. To use unusual CMake toolchain
  executables, set `LIBUV_CMAKE_FLAGS`, not Make's `AR` or `RANLIB` (those configure
  Titan's own runtime archive).
- When you change the compiler or flags, clean the native build directory and the
  affected Titan outputs.

#### Writing an extension that uses libuv

A compiled Titan extension that does `foreign import "uv.h"` must also import the
`titan.uv` module (normally `import "uv"`), and must leave its `uv_*` references
unresolved. Do not link it with `-luv` or with the private bundled archive, and never
embed `libuv.a` in another DSO: that would create a second libuv instance.

```titan
local runtime = import "uv"
foreign import "uv.h"
```

Why the explicit import matters: Titan loads every compiled dependency with
`RTLD_LAZY | RTLD_GLOBAL`. Lazy binding lets the extension map while its libuv calls are
still unresolved. The generated initializer then loads the `uv` import globally, before
any Titan code can make one of those calls. `RTLD_NOW` would fail while mapping the
extension, before the initializer could load the provider. `RTLD_LOCAL` would hide a
provider loaded later from the extension's lazy bindings. These flags apply to every
generated runtime import; there is no libuv-specific loader. Compiler interface
inspection is separate and uses `RTLD_LAZY | RTLD_LOCAL`.

This works for ordinary function calls. Native constructors run before the generated
module initializer, and imported data and function-address relocations are eager. Do not
use those forms unless the process has already made the provider global.

If Lua loads the extension directly, load the provider first:

```lua
require "titan"
local uv = require "titan.uv"
local extension = require "my.libuv_extension"
```

`require "titan"` installs Titan's package searcher. For `titan.uv` the searcher finds
the canonical `titan.so` provider along the Titan path, checks its ABI, promotes it with
`RTLD_LAZY | RTLD_GLOBAL`, and calls `luaopen_titan_uv`. On stock Lua 5.5 on Linux and
macOS, this first qualified `require` is what establishes the provider. Because it
happens before the extension is mapped, it also supports eager libuv relocations and
native constructors. A Lua-only extension that omitted the Titan `uv` import can use the
same preload, but it does not meet the Titan-side contract above.

### llhttp, SQLite, and OpenSSL

`titan.http` always uses a private, pinned llhttp 9.4.3, and `titan.sqlite3` always uses
a private, pinned SQLite 3.53.4 amalgamation. The build downloads, verifies, and compiles
them (in a checkout, `make llhttp` and `make sqlite3` do so alone). There is no system
mode for either. Their libraries are carried into `titan.so` and `titan.a` in either
OpenSSL mode, and neither becomes a public SDK library. llhttp's eight C callbacks are
source-defined foreign functions in the generated `titan.http` object. OpenSSL is covered
under [Bundled OpenSSL](#bundled-openssl).

## Uninstalling

Run `titan-uninstall` from the installation. It asks LuaRocks to remove every installed
Titan rock version in the selected tree, including the compiler scripts and modules,
the support module, and private payloads. Only if that succeeds does it remove Titan's
external headers, providers, runtime archive, notices, build-profile record, and the
`make browser-sdk`-owned files under `lib/titan-browser/<ver>/`. Lua, LuaRocks,
dependency Lua modules, the browser Lua in `lib/browser/`, user archives in
`lib/titan-browser/<ver>/`, and shared third-party headers and libraries stay. Titan's
canonical paths are shared by all rock versions, so the command cleans the whole Titan
installation in that tree. You cannot remove one version.

`titan-uninstall --luarocks PATH` picks another LuaRocks executable. By default it tries
the recorded executable, then `luarocks` on `PATH`. Plain `luarocks remove titan` leaves
Titan's external files in place.

## Cleaning a checkout

- `make clean` removes the `out/` tree and generated native build and test artifacts
  (objects, generated C, compiled modules, coverage data). It also cleans legacy
  source-adjacent compiler outputs and the checkout's support module. It keeps sources
  and downloaded dependency trees.
- `make distclean` also removes the downloaded or cloned LuaRocks, libbacktrace, libuv,
  llhttp, SQLite, and OpenSSL source and build trees and their release tarballs. It
  cleans Lua's build artifacts, keeps the pinned submodule, and removes the
  checkout-local `.lua` installation.
- Each dependency also has its own target: `clean-luarocks`, `clean-libbacktrace`,
  `clean-libuv`, `clean-llhttp`, `clean-sqlite3`, `clean-openssl`, and `clean-lua`.

None of these touches other installed prefixes. Delete a throwaway prefix yourself when
you no longer need it.
