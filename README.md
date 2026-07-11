# Titan
[![CI](https://github.com/mascarenhas/titan/actions/workflows/ci.yml/badge.svg)](https://github.com/mascarenhas/titan/actions/workflows/ci.yml)
[![Coverage Status](https://codecov.io/gh/titan-lang/titan/coverage.svg?branch=master)](https://codecov.io/gh/titan-lang/titan/branch/master)

Titan is a new programming language, designed to be a statically-typed,
ahead-of-time compiled sister language to [Lua](http://www.lua.org). It is an
application programming language with a focus on performance.

# Install

The Titan compiler generates C that includes Lua 5.5's *internal* headers and
links against its static library, so you first need a built Lua 5.5.0 source
tree alongside this checkout. The provided `Makefile` downloads and builds it
for you:

        $ make lua

This fetches the [Lua 5.5.0 sources](http://www.lua.org/ftp/lua-5.5.0.tar.gz)
into a `lua-5.5.0` folder and builds them with `MYCFLAGS=-fPIC`, auto-detecting
the `linux`/`macosx` build target from `uname` (override with
`make lua LUA_PLATFORM=...`). To do it by hand instead, download and extract the
tarball into a `lua-5.5.0` folder and run `make linux MYCFLAGS=-fPIC` inside it.

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

`make all`, `make stdlib`, and the LuaRocks build also build this bundled
copy automatically. To use a system development package instead, install it
with pkg-config and select the optional mode explicitly:

```sh
# Ubuntu/Debian
sudo apt-get install libuv1-dev pkg-config
# Fedora
sudo dnf install libuv-devel pkgconf-pkg-config
# macOS (Homebrew's prefix is discovered through pkg-config)
brew install libuv pkgconf

LIBUV_MODE=system make libuv
LIBUV_MODE=system ./luarocks make
```

System mode requires libuv 1.43.0 or newer and consumes the complete ordered
`pkg-config --cflags/--libs` output. Run `make libuv-config` to inspect the
effective mode, include flags, archive, and support libraries; `make help`
lists the related targets and setup hints. The Makefile records the effective
mode, compiler, and flags, so switching between bundled and system mode
rebuilds `titan_uv.o` and `uv.so` without requiring a manual clean.

You can install the Titan compiler and its dependencies using  [LuaRocks](http://luarocks.org)
making sure that the dependencies will use the same exact Lua version Titan is using.
After installing luarocks, run these commands in the root of this repository:

        $ luarocks init --lua-dir=$PWD/.lua
        $ luarocks make

The `luarocks init` step creates `./lua` and `./luarocks` wrapper scripts in
the project root; use them directly (with `./`) to run Lua and LuaRocks with
the correct project paths baked in.  To also put `titanc` and `busted` (from
`lua_modules/bin/`) on your `$PATH`, run:

        $ cd <titan folder> && eval $(./luarocks path --bin)

LuaRocks records the canonical standard-module image under its managed,
ABI-qualified `lib/lua/5.5/titan/stdlib_0_11/` directory and replaces the
managed Lua-facing file with a relative symlink under `lib/lua/5.5/titan/`.
Both paths therefore belong to the rock manifest, binary rocks, upgrades, and
uninstall while still mapping one DSO image. A project-local `luarocks init` is
a custom prefix, so point Titan's dedicated standard loader at it when
compiling or running code that imports a standard module:

```sh
export TITAN_STDLIB_PATH="$PWD/lua_modules/lib/lua/5.5/titan/stdlib_0_11"
```

For a manual prefix, `make install-stdlib PREFIX=/opt/titan` installs canonical
modules under `/opt/titan/lib/titan/0.11` and Lua aliases under
`/opt/titan/lib/lua/5.5/titan`; set `TITAN_STDLIB_PATH` to the former and add
`/opt/titan/lib/lua/5.5/?.so` to `LUA_CPATH` for Lua hosts. The standard path is
separate from ordinary `TITAN_PATH` by design, so an application-local module
cannot replace a standard dependency.

# Usage

        $ titanc [--print-ast] [--lua <path>] [--tree <path>] <module> [<module>]

The compiler takes a list of module names that you want to compile. Modules
are looked up in the source tree (defaults to the current working directory,
but you can override this with the `--tree` option), as well as in the Titan
binary path, a semicolon-separated list of paths 
(defaults to `.;/usr/local/lib/titan/0.11`, you can override with a `TITAN_PATH_0_11`
or `TITAN_PATH` environment variable).

The reserved standard modules (`coroutine`, `uv`, `timer`, `fs`, `net`, and
`os`) use the separate `TITAN_STDLIB_PATH` (installed default
`/usr/local/lib/titan/0.11`) and cannot be shadowed through `--tree` or
`TITAN_PATH`. Titan code imports them by their short names, while Lua uses the
qualified aliases such as `require "titan.coroutine"`, `require "titan.uv"`,
`require "titan.timer"`, `require "titan.fs"`, `require "titan.net"`, and
`require "titan.os"`. Lua's own `coroutine` and `os` modules remain unchanged.

The currently implemented async chain is `coroutine.so -> uv.so ->
{timer.so, fs.so, net.so, os.so}`. Only the canonical `uv.so` contains libuv; the
higher modules dynamically import that standard image instead of linking
another copy. `make stdlib` builds all six canonical modules and their
`titan.*` Lua aliases in dependency order.

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
  given in the command-line, along with all their dependencies where
  source code was available, as a stand-alone executable program.
* Otherwise, it will compile each module into a shared library that you
  can `import` from Titan as well as `require` from Lua, and call any
  exported functions/access exported variables. The generated `.c` and
  `.o` files are written next to the `.titan` source; linked `.so` files
  are written relative to the directory where `titanc` runs. For each
  generated module, any of its transitive imports is statically linked if
  source code was found; dependencies that were only available as a shared
  library will be dynamically loaded.

# Running the test suite

The test suite is written using [Busted](https://lunarmodules.github.io/busted/).
The simplest way to run it is:

        $ make lua          # once, to build the bundled Lua 5.5.0 tree
        $ make test

`make test` runs `luarocks make` followed by `luarocks test`. The `luarocks make`
step builds and installs the rock — including the `titan` C runtime module that a
couple of tests need — and `luarocks test` installs the test dependencies (Busted
and cluacov, declared in the rockspec) and runs the suite from the repository
root. To run the steps yourself:

        $ luarocks make                      # build/install the rock (also picks up source edits)
        $ luarocks test                      # install test deps + run the suite
        $ luarocks test -- -c -o gtest       # ...forwarding flags to Busted (here: luacov coverage)

Note that `luarocks test` does **not** build the rock-under-test, only its
dependencies, so always `luarocks make` first (that is what `make test` does).
Two related gotchas if you drive Busted directly:

* A few tests need the `titan` runtime support module (for `titan.backtrace()`),
  which `luarocks make` installs; make sure the in-tree `.lua/bin/lua`
  interpreter can find it by including your rocks tree in `LUA_CPATH`, e.g.
  `LUA_CPATH="./?.so;$HOME/.luarocks/lib/lua/5.5/?.so;;" busted`.
* Once the `titan` rock is installed, Busted loads the compiler modules from the
  *installed* rock, not from your checkout — re-run `luarocks make` after editing
  compiler sources so the tests see your changes.

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
C, compiled modules, coverage data) while keeping the downloaded Lua tree.
`make distclean` additionally removes the `lua-5.*` source tree(s) and tarball.

# Compiler options

        --print-ast                       Print the AST.
        -v, --verbose                     Print safely quoted effective compiler commands.
        --lua <path>                      Path to the Lua sources (default 'lua-5.5.0/src').
        --tree <path>                     Path to the source tree for Titan modules (default '.').
        -l, --link <lib1,lib2>            Add libraries to the final link.
        -X, --extra-object <object...>     Add object/archive inputs to the final link.
        --stdlib-build                    Build one reserved standard source root (Makefile use).
        --lua-name <qualified.name>        Export a distinct Lua require entry for one root.
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
