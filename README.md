# Titan
[![CI](https://github.com/mascarenhas/titan/actions/workflows/ci.yml/badge.svg)](https://github.com/mascarenhas/titan/actions/workflows/ci.yml)
[![Coverage Status](https://codecov.io/gh/titan-lang/titan/coverage.svg?branch=master)](https://codecov.io/gh/titan-lang/titan/branch/master)

Titan is a new programming language, designed to be a statically-typed,
ahead-of-time compiled sister language to [Lua](http://www.lua.org). It is an
application programming language with a focus on performance.

# Install

Titan is the primary entry point of a Titan+Lua installation. Give each
project its own local absolute prefix, then use that prefix's Lua, LuaRocks,
and Titan compiler to build and run the project. Two destination names have
distinct ownership even in the current single-directory layout:

* `PREFIX` owns the prefix-configured Lua installation and the LuaRocks
  program and configuration.
* `ROCKS_TREE` owns the installed Titan rock, compiler SDK, and standard
  library.

The supported developer install and CI configure LuaRocks' sole system tree so
`ROCKS_TREE == PREFIX`. That equality is the current deployment policy, not an
inherent requirement of what either name owns. For example:

```sh
export PREFIX="$HOME/.local/titan/my-project"
export PATH="$PREFIX/bin:$PATH"

make lua
make luarocks
make libuv
"$PREFIX/bin/luarocks" make
```

`make lua` fetches the
[Lua 5.5.0 sources](http://www.lua.org/ftp/lua-5.5.0.tar.gz) and configures
`lua-5.5.0/src/luaconf.h` so `LUA_ROOT` is this `PREFIX`. Lua's `loadlib.c`
remains unmodified; the installed `titan/uv.lua` loader uses the standard
`package.loadlib` global-link operation for the libuv provider. The build then
compiles Lua with `MYCFLAGS=-fPIC` and
installs it under the prefix. It also installs the Lua `.c` and `.h` sources
under `$PREFIX/src/lua-5.5.0/`. Consequently the
installed `liblua.a`, the internal headers Titan-generated C uses, and the
public headers used when LuaRocks builds other Lua libraries all describe the
same prefix and the same Lua build. The Makefile selects the `linux` or
`macosx` Lua target from `uname`; override it with
`make lua LUA_PLATFORM=...` when necessary, and use `LUA_CC` to select Lua's
C compiler. Changing the prefix, platform, compiler, or `LUA_MY*` flags
invalidates the Lua objects before rebuilding, so the installed source headers
cannot silently drift from `liblua.a`.

`make luarocks` fetches pinned LuaRocks 3.13.0 and configures its executable and
Lua location under `PREFIX`, with its sole system-style `ROCKS_TREE` set to the
same directory for the supported workflow. Its forced configuration avoids a
user or checkout-local project tree. The generated configuration also records
Make's effective `CC`, `AR`, and `RANLIB` (using `CC` for linking), so a later
direct `$PREFIX/bin/luarocks make` reuses the native tool identities that
prepared the prefix instead of invalidating and rebuilding dependencies.
Finally, that command builds and installs the Titan compiler, runtime archives
and headers, and the standard library into `ROCKS_TREE`. Keep `$PREFIX/bin`
first on `PATH` while developing so `lua`, `luarocks`, and `titanc` all come
from this installation.

Lua and LuaRocks record versioned, prefix-local completion stamps under
`$PREFIX/etc/titan/`. Repeating `make luarocks` against a prepared prefix is a
no-op, while selecting a fresh prefix performs a fresh installation; the Lua
stamp is invalidated when its matching source build changes.

Use a fresh prefix when migrating a directory that previously used
`luarocks init` or a user-tree LuaRocks configuration. Third-party command
launchers such as `busted` embed the active Lua paths when their rocks are
installed; changing LuaRocks' configuration later correctly migrates the
Titan-owned tools, but cannot rewrite arbitrary already-installed launchers.

The installed files used to compile Titan code include:

| Owner and path | Purpose |
| --- | --- |
| `$PREFIX/src/lua-5.5.0/`, `$PREFIX/include/{lua,lauxlib,lualib,luaconf}.h`, `$PREFIX/lib/liblua.a` | The prefix-configured Lua sources, public configuration/headers, and static library owned by the Lua installation |
| `$ROCKS_TREE/src/lua-5.5.0/`, `$ROCKS_TREE/lib/liblua.a` | Matching Lua source and archive copies staged as part of the Titan compiler SDK |
| `$ROCKS_TREE/lib/libtitan.a` | Exactly `titan.o`, `titan_coro.o`, and `titan_uv.o`: generated-code loader/error support plus the coroutine and libuv callback shims |
| `$ROCKS_TREE/lib/libbacktrace.a` | The separate vendored native unwinder/symbolizer archive |
| `$ROCKS_TREE/lib/lua/5.5/titan.so` | The separate Lua support module built only from `titan-runtime/titanlib.c`, including the compiler's internal `RTLD_LAZY` + `RTLD_LOCAL` interface loader; it is not a member of `libtitan.a` |
| `$ROCKS_TREE/include/minicoro.h`, `titan.h`, `titan_longjmp.h` | Non-Lua top-level SDK headers |
| `$ROCKS_TREE/include/titan/{ffi,coro,uv}.h` | Namespaced portable FFI, coroutine, and libuv shim headers |
| `$ROCKS_TREE/lib/titan/0.11/titan/*.so` | The single canonical files for the `coroutine`, `uv`, `timer`, `fs`, `net`, and `os` standard modules, used by both Titan imports and `require "titan.*"` |
| `$ROCKS_TREE/share/lua/5.5/titan/uv.lua` | The Lua loader that maps canonical `titan/uv.so` globally before invoking `luaopen_titan_uv` |

Bundled-libuv installs also contain `$ROCKS_TREE/include/uv.h` and
`$ROCKS_TREE/include/uv/`. The bundled `libuv.a` is a private build artifact:
it is consumed only while linking the canonical `titan/uv.so` and is not
installed or exported as part of the Titan SDK. System mode uses the selected
system libuv instead. Each standard module is one ordinary installed file at
the qualified path; installation does not create aliases with symbolic links,
hard links, or copied DSOs. Consequently Titan and Lua load the same native
image, and `titan/uv.so` supplies the process's one complete libuv provider.

## Libuv setup

Titan's async standard library uses libuv. The supported default is a pinned
libuv 1.52.1 static PIC build, so neither the compiler nor the resulting
standard modules depend on an unversioned system libuv at runtime. Install a C
compiler, CMake, tar, a downloader, and a SHA-256 tool, then let the Makefile
fetch, verify, and build it:

```sh
# Ubuntu/Debian
sudo apt-get install build-essential cmake curl

# Fedora
sudo dnf install gcc make cmake curl

# macOS (Apple's curl, tar, and shasum are already present)
xcode-select --install
brew install cmake

make libuv
```

The install sequence above builds this bundled copy before installing Titan.
To use a system development package instead, install it with pkg-config and
select the optional mode consistently for both steps:

```sh
# Ubuntu/Debian
sudo apt-get install libuv1-dev pkg-config
# Fedora
sudo dnf install libuv-devel pkgconf-pkg-config
# macOS (Homebrew's prefix is discovered through pkg-config)
brew install libuv pkgconf

LIBUV_MODE=system make libuv
LIBUV_MODE=system "$PREFIX/bin/luarocks" make
```

System mode requires libuv 1.43.0 or newer and consumes the complete ordered
`pkg-config --cflags/--libs` output. Run `make libuv-config` to inspect the
effective mode, include flags, archive, and support libraries; `make help`
lists the related targets and setup hints. The Makefile records the effective
mode, compiler, and flags, so switching between bundled and system mode
rebuilds the libuv-facing objects without requiring a manual clean.

In bundled mode, `titan/uv.so` is the sole complete libuv provider. A compiled
Titan extension DSO that directly `foreign import`s `uv.h` must also import the
`titan.uv` module (normally written `import "uv"`) and leave its `uv_*`
function references unresolved; do not link it with `-luv` or the private
bundled archive. Titan maps every compiled runtime dependency with its ordinary
`RTLD_LAZY | RTLD_GLOBAL` loader. Lazy binding lets the extension image map
while its libuv calls are still unresolved; its generated initializer then
loads the explicit `uv` import globally before Titan code can make one of those
calls. `RTLD_NOW` would instead fail while mapping the extension, before that
initializer could load the provider, while `RTLD_LOCAL` would not expose a
provider loaded later to the extension's lazy bindings. There is no
libuv-specific dependency metadata or loader entry point: these flags apply to
every generated runtime import. Compiler interface inspection remains separate
and uses `RTLD_LAZY | RTLD_LOCAL`.

For example, the extension source starts with both imports:

```titan
local runtime = import "uv"
local uv = foreign import "uv.h"
```

This Titan-side bundled contract covers ordinary function calls, whose
bindings can remain lazy. Native constructors run before the generated module
initializer, while imported data and function-address relocations are eager;
do not use those forms unless the embedding process has already made the
provider global. The explicit `uv` import remains required even if a particular
Lua host happens to preload the provider, because it is what makes the module
work through Titan's runtime loader.

When Lua loads such an extension directly, load the provider first:

```lua
local uv = require "titan.uv"
local extension = require "my.libuv_extension"
```

The `titan/uv.lua` loader resolves the canonical DSO with
`package.searchpath("titan.uv", package.cpath)`, calls
`package.loadlib(path, "*")` to make its symbols global, and then invokes the
exact `luaopen_titan_uv` entry from the same handle. Thus the first `require`
above establishes the same provider on stock Lua 5.5 on Linux and macOS while
every other C module keeps Lua's ordinary local-loading behavior.
`titan/uv.so` does not reopen or promote itself.

Because this explicit Lua preload happens before the extension is mapped, it
also supports its eager libuv relocations and native constructors. It can make
the native symbols available even to a Lua-only extension that omitted the
Titan `uv` import, but such a module does not satisfy the Titan-side contract.

System mode may instead link the extension against the same
pkg-config-selected shared libuv used by `titan/uv.so`. In either mode, never
embed the bundled `libuv.a` in another DSO: it is private to the standard
provider and a second static embedding would create a second native libuv
instance.

CMake owns the archiver and indexer associated with the bundled build's C
compiler; select unusual CMake toolchain executables explicitly through
`LIBUV_CMAKE_FLAGS` rather than Make's `AR`/`RANLIB`, which configure Titan's
own runtime archive.

The Titan-owned Lua's configured default `package.cpath` contains
`$PREFIX/lib/titan/0.11/?.so` before `$PREFIX/lib/lua/5.5/?.so`. The first
template lets `require "titan.*"` reach the canonical standard modules (with
`titan.uv` passing through its Lua loader first); the second remains the
root-discovery anchor. The default `package.path` likewise finds
`$PREFIX/share/lua/5.5/titan/uv.lua`. In the currently supported layout
`ROCKS_TREE == PREFIX`, so `titanc` can use the first entry ending in
`/lib/lua/5.5/?.so` to recover its Titan SDK/rocks root.
During the source rock's post-install build, the internal `TITAN_ROCKS_ROOT`
override identifies `ROCKS_TREE` directly. The recovered Titan root supplies
the staged Lua sources and archives and compiled modules under
`$ROCKS_TREE/lib/titan/0.11/`; the standard library's qualified `titan.*`
modules consequently live below its `titan/` subdirectory. This discovery
rule implements the supported equal-root layout; it does not redefine the
separately owned `PREFIX` and `ROCKS_TREE` as one concept.

At startup a compiled executable inherits Lua's default `package.cpath` and
ensures `$ROCKS_TREE/lib/titan/0.11/?.so` is present. Both it and the installed
Lua therefore resolve `titan.<name>` to the same canonical file at
`$ROCKS_TREE/lib/titan/0.11/titan/<name>.so`; there are no Lua-facing or
parent-level compatibility copies.

An unmodified Lua 5.5 can reproduce those search paths with versioned
environment variables. Include the ordinary Lua C-module template because it
is also Titan's installation-root anchor:

```sh
export LUA_PATH_5_5="$ROCKS_TREE/share/lua/5.5/?.lua;$ROCKS_TREE/share/lua/5.5/?/init.lua;;"
export LUA_CPATH_5_5="$ROCKS_TREE/lib/titan/0.11/?.so;$ROCKS_TREE/lib/lua/5.5/?.so;;"
```

If that root-anchor template is deliberately omitted, set
`TITAN_PATH_0_11="$ROCKS_TREE/lib/titan/0.11"` as well.

`TITAN_PATH_0_11` (or the unversioned `TITAN_PATH`) overrides the Titan binary
search path. A short standard-library import is desugared before resolution
(`import "timer"` becomes `import "titan.timer"`), so ordinary qualified
lookup below `$ROCKS_TREE/lib/titan/0.11` reaches the canonical file. In a source
checkout, `--lua` can select another complete Lua source/build tree for an
individual compiler invocation. An installed compiler rejects `--lua` because
its headers, `liblua.a`, and `libtitan.a` are one matched SDK. These overrides
are mainly useful for testing and nonstandard source builds; a normal
local-prefix install needs none of them.

This is not yet Titan's story for packaging or distributing Titan libraries
and applications: give a project its own standalone absolute `PREFIX` and use
the currently equal system-style `ROCKS_TREE` and installed `titanc`. The
current Titan rock is likewise a **source-install** package. Its
`build_target = "titan"` builds the runtime and copies the native archives,
headers, and Lua sources directly into `ROCKS_TREE`; after LuaRocks deploys the
compiler, a source-only `post_install` hook uses that installed `titanc` to
build and install each standard module once at its canonical qualified path.
There is no
separate Make install pass or
pre-install hook. The rockspec's C-module list contains only `titan.so`; the
six standard DSOs are deliberately absent. LuaRocks cannot
express these SDK and Titan-module destinations as normal Lua modules, so the
directly copied files are outside the rock manifest and
`luarocks remove titan` does not remove them. Titan does not provide binary
rocks yet; packaging and uninstall ownership for these files will be revisited
with a Titan library/application distribution system.

# Usage

        $ titanc [--print-ast] [--lua <path>] [--tree <path>] <module> [<module>]

The compiler takes a list of module names that you want to compile. Modules
are looked up in the source tree (defaults to the current working directory,
but you can override this with the `--tree` option), as well as in the Titan
binary path, a semicolon-separated list of paths. By default this is the
current directory plus `<root>/lib/titan/0.11`, where `<root>` is recovered
from `package.cpath`; override it with `TITAN_PATH_0_11` or `TITAN_PATH`.

The standard-library short names (`coroutine`, `uv`, `timer`, `fs`, `net`, and
`os`) are parser sugar for the corresponding `titan.*` module names. Module
resolution checks binary dependencies before source, so an ordinary
`./titan/uv.titan` cannot displace the installed `titan/uv.so`; someone who
explicitly changes `TITAN_PATH` to hide that binary is choosing a different
module installation. Titan code uses the short imports, while Lua uses the
qualified names `require "titan.coroutine"`, `require "titan.uv"`,
`require "titan.timer"`, `require "titan.fs"`, `require "titan.net"`, and
`require "titan.os"`. Lua's own `coroutine` and `os` modules remain unchanged.

The currently implemented async chain is `titan/coroutine.so -> titan/uv.so ->
titan/{timer.so, fs.so, net.so, os.so}`. Only the canonical `titan/uv.so`
consumes libuv directly: bundled mode links its private archive there, while
system mode links the pkg-config-selected shared library. The higher modules
dynamically import that qualified image instead of linking libuv themselves.
The standard build runs ordinary commands such as `titanc titan.uv`, producing
the qualified Lua entry points in dependency order.

From Titan, importing `timer` is enough to enable the standalone async
bootstrap:

```titan
local timer = import "timer"

function main(args: {string}): integer
  timer.sleep(10)
  return 0
end
```

Filesystem calls have the same synchronous appearance inside a Task. Payloads
are binary, while paths are text and reject embedded NUL:

```titan
local fs = import "fs"

function main(args: {string}): integer
  fs.write_file(args[1], "Titan\0data")
  if fs.read_file(args[1]) ~= "Titan\0data" then return 1 end
  return 0
end
```

From Lua, schedule Tasks with `uv.run` and drive them explicitly:

```lua
local uv = require "titan.uv"
local timer = require "titan.timer"

local task = uv.run(function()
    timer.yield()
    return "done"
end)
assert(task:status() == "ready") -- `run` has not executed it
uv.loop()
assert(task:join() == "done")
```

A libuv callback directly resumes its Titan Task and application code runs in
that callback until it finishes or starts another async operation and yields.
There is no extra protected callback wrapper or implicit ready queue;
`timer.yield()` explicitly cedes an event-loop turn. See
[Asynchronous I/O and tasks](doc/language/async-io.md) and the
[timer](doc/language/standard-library-timer.md),
[filesystem](doc/language/standard-library-fs.md), and
[TCP networking](doc/language/standard-library-net.md) modules. Portable
environment, directory, identity, executable-path, one-shot signal,
argv-based child-process, binary stdio, and concurrent `communicate` helpers are
documented in the [OS standard library](doc/language/standard-library-os.md).

If everything is all right with your modules, you will get the result of
your compilation as a native binary:

* if one of your Titan modules has a `main` function, with signature
  `function({string}):integer`, then `titanc` will bundle all modules
  given in the command-line, along with every dependency that module resolution
  selected from source, as a stand-alone executable program. Dependencies
  selected from compiled modules remain dynamically loaded.
* Otherwise, it will compile each module into a shared library that you
  can `import` from Titan as well as `require` from Lua, and call any
  exported functions/access exported variables. The generated `.c` and
  `.o` files are written next to the `.titan` source; linked `.so` files
  are written relative to the directory where `titanc` runs. For each
  generated module, any transitive import selected from source is statically
  linked; dependencies selected from shared libraries are dynamically loaded.

# Running the test suite

The test suite is written using [Busted](https://lunarmodules.github.io/busted/).
The simplest way to run it is:

        $ export PREFIX="/tmp/titan-$USER-test"
        $ export PATH="$PREFIX/bin:$PATH"
        $ make lua                   # prepare an isolated local installation
        $ make luarocks
        $ make libuv
        $ make test

`make test` runs `luarocks make --force` followed by `luarocks test`. The forced
build installs the current checkout — including the `titan` Lua support module
that a couple of tests need — and `luarocks test` installs the test dependencies
(Busted and cluacov, declared in the rockspec) and runs the suite from the
repository root. It clears ambient `LUA_PATH`/`LUA_CPATH` overrides for both
commands, so a shell left over from an old `luarocks init` project cannot make
the prefix tools load a different compiler snapshot. The supported workflow
does not use `luarocks init`; avoid exporting those project-tree paths while
working in a standalone Titan prefix. To run the iterative development steps
yourself:

        $ "$PREFIX/bin/luarocks" make --force        # rebuild/reinstall the current checkout
        $ "$PREFIX/bin/luarocks" test                # install test deps + run the suite
        $ bash spec/support/ci_test_groups.sh compiler # compiler/language tests with LuaCov

The grouped compiler command is the coverage entry point. Library API and
runtime suites run without LuaCov because the hook measures the Lua compiler,
not the generated Titan or native library implementation; use
`bash spec/support/ci_test_groups.sh libraries` for that complete group.

Note that `luarocks test` does **not** build the rock-under-test, only its
dependencies, so always `luarocks make` first (that is what `make test` does).
If you drive Busted directly, use the `busted` installed in `$PREFIX/bin`; the
prefix-configured Lua paths then find the `titan` Lua support module installed by
`luarocks make`. Once the Titan rock is installed, Busted loads compiler
modules from that *installed* rock, not from your checkout. Re-run
`$PREFIX/bin/luarocks make` after editing compiler sources so tests see the
changes.

# Building the examples

The `examples/` directory has its own `Makefile` with a target per example
module plus an `all` target. From the repository root, `make examples` builds
them all:

        $ make examples            # or: make -C examples all
        $ make -C examples utils   # build a single example

`sdl_demo` depends on `sdl_quit`, and both use the C FFI against SDL2, so they
need the SDL2 development headers installed.

# Cleaning up

`make clean` removes generated build and test artifacts (object files, generated
C, compiled modules, coverage data) while keeping downloaded dependency trees.
`make distclean` additionally removes the downloaded Lua, LuaRocks,
libbacktrace, and libuv source/build trees and release tarballs. Neither target
removes an installed `PREFIX`; delete a throwaway `/tmp` prefix separately
when it is no longer needed.

# Compiler options

        --print-ast                       Print the AST.
        -v, --verbose                     Print safely quoted effective compiler commands.
        --lua <path>                      Path to a Lua source/build tree (source checkouts only).
        --tree <path>                     Path to the source tree for Titan modules (default '.').
        -l, --link <lib1,lib2>            Add libraries to the final link.
        -X, --extra-object <object...>     Add object/archive inputs to the final link.
        -h, --help                        Show this help message and exit.

`CC` selects the compiler. `TITAN_EXTRA_CPPFLAGS` carries append-only `-I`/`-D`
arguments shared by C-FFI checking and generated compilation;
`TITAN_EXTRA_CFLAGS` is compile-only; and ordered `TITAN_EXTRA_LDFLAGS` is
final-link-only. Shell quoting in these environment strings is parsed once, so
paths containing spaces stay one argument and malformed quoting is rejected.
        
# Tentative roadmap

This is a *very* preliminary roadmap towards Titan 1.0, where everything is
subject to change, with things more likely to change the further
they are in the roadmap:

## Supported

* control structures
* integers
* floats
* booleans
* strings
* arrays
* top-level functions
* early-bound modules
* multiple assignment/multiple returns
* FFI with C (C primitive types, pointers, arrays, structs/unions, owned
  buffers, explicit C varargs, and C function calls)
* records (structs) with `:` method calls
* maps
* first-class functions
* anonymous functions and closures, with proper lexical scoping
* bound methods (`obj:method`) as first-class values
* variadic parameters in functions (Lua `...`)
* generic `for ... in` iterators with optional state, start value, and close
  callable
* error handling with `raise`, `catch`, `finally`, Lua `pcall`, and
  unified Lua/Titan backtraces via `titan.backtrace()`
* asymmetric, tagged (nested) coroutines as building block for async IO
* libuv-backed Tasks, timers, asynchronous binary filesystem I/O, DNS, TCP,
  portable OS helpers, one-shot signal waits, direct child processes with
  binary stdio, and concurrent `communicate`

## Next

* minimal standard library, continued (string library including tostring, math
  library including tonumber, and a Lua library to load/run Lua code)
* FFI with C, continued (function pointers, callbacks from C into Titan, owned structs with flexible array members)
* tagged variants (unions of records with some syntax for switch/case on the record tag)
* parametric polymorphism (via type erasure and boxed values)
* some mechanism for ad-hoc polymorphism, either Go/Java/C#/Swift-like interfaces/protocols or Haskell/Rust-like typeclasses/traits
* Language server
* ...Titan 1.0!
