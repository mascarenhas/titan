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

# Usage

        $ titanc [--print-ast] [--lua <path>] [--tree <path>] <module> [<module>]

The compiler takes a list of module names that you want to compile. Modules
are looked up in the source tree (defaults to the current working directory,
but you can override this with the `--tree` option), as well as in the Titan
binary path, a semicolon-separated list of paths 
(defaults to `.;/usr/local/lib/titan/0.11`, you can override with a `TITAN_PATH_0_11`
or `TITAN_PATH` environment variable).

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

        --print-ast                     Print the AST.
        --lua <path>                    Path to the Lua sources (default 'lua-5.5.0/src')
        --tree <path>                   Path to the source tree for your Titan modules (default '.')
        -h, --help                      Show this help message and exit.
        
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
* error handling with `raise`, `catch`, `finally`, Lua `pcall`, and
  unified Lua/Titan backtraces via `titan.backtrace()`
* asymmetric, tagged (nested) coroutines as building block for async IO

## Next

* for-in construct for iterators (`next`, `next,state`, `next,state,start`)
* minimal standard library (expose Lua tostring/tonumber, file/socket IO using libuv, string library, math library, load/run Lua code)
* FFI with C, continued (function pointers, callbacks from C into Titan, owned structs with flexible array members)
* tagged variants (unions of records with some syntax for switch/case on the record tag)
* parametric polymorphism (via type erasure and boxed values)
* some mechanism for ad-hoc polymorphism, either Go/Java/C#/Swift-like interfaces/protocols or Haskell/Rust-like typeclasses/traits
* Language server
* ...Titan 1.0!
