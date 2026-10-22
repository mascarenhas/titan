# Titan
[![CI](https://github.com/mascarenhas/titan/actions/workflows/ci.yml/badge.svg)](https://github.com/mascarenhas/titan/actions/workflows/ci.yml)
[![Coverage Status](https://codecov.io/gh/titan-lang/titan/coverage.svg?branch=master)](https://codecov.io/gh/titan-lang/titan/branch/master)

Titan is a statically typed programming language that is compiled ahead of time
to native code. It is a sister language to [Lua](http://www.lua.org): the syntax
is close to Lua's, every variable has a static type, and compiled modules run
inside the Lua runtime. Lua programs `require` Titan modules like any other
module, and the two languages share values and the garbage collector.

```titan
local io = import "io"

function main(args: {string}): integer
  local name = args[1] or "world"
  io.print("Hello, " .. name .. "!")
  return 0
end
```

```sh
titanc -o out hello    # compiles hello.titan
./out/hello Titan      # Hello, Titan!
```

Titan is a prototype (version 0.6.0). Linux and macOS are supported. The
Windows port is experimental.

## What is in it

- **Language:** integers, floats, booleans, strings, option types (`T?`),
  Arrays and Maps, records, unions, interfaces, generics with interface
  constraints, closures, multiple results, and a `value` type for dynamic Lua
  data. Errors use `raise`, `catch`, and `defer`.
- **Modules:** one module per source file or folder, importable by name, and
  compiled to shared and static libraries that carry their type information.
- **C interface:** `foreign import` binds C headers directly. `foreign function`
  writes C callbacks in Titan.
- **Standard library:** async tasks and timers on libuv, files, DNS and TCP,
  verified TLS, an HTTP/1.1 client and server, WebSocket, child processes,
  OS threads with channels, JSON, Protocol Buffers, SQLite, parsing
  expressions, byte strings and regular expressions, reflection, garbage
  collector control, and a native test runner.

## Install

The default installation puts three things under one prefix that you choose for
the project:

- Lua 5.5.1 from Titan's fork,
  [release `v5.5.1-1` of mascarenhas/lua-5.5.1](https://github.com/mascarenhas/lua-5.5.1/releases/tag/v5.5.1-1).
- Stock LuaRocks 3.13.0.
- Titan, installed by that LuaRocks with `luarocks install titan`.

You need a C compiler, `make`, CMake, `git`, `curl`, Readline and OpenSSL
development packages, and `pkg-config`:

```sh
# Ubuntu/Debian
sudo apt-get install build-essential cmake curl git libreadline-dev libssl-dev pkg-config
# Fedora
sudo dnf install gcc make cmake curl git readline-devel openssl-devel pkgconf-pkg-config
# macOS (see the installation guide for Homebrew's keg-only Readline)
xcode-select --install && brew install cmake readline openssl@3 pkgconf
```

Then build Lua and LuaRocks into your prefix and install the rock. On macOS, use
`macosx` instead of `linux-readline`.

```sh
export PREFIX="$HOME/.local/titan/my-project"

curl -fL -o lua-titan.tar.gz https://github.com/mascarenhas/lua-5.5.1/archive/refs/tags/v5.5.1-1.tar.gz
tar zxf lua-titan.tar.gz
(cd lua-5.5.1-5.5.1-1 &&
  make linux-readline MYCFLAGS=-fPIC TITAN_LIBRARY_VERSION=0.6 PREFIX="$PREFIX" &&
  make install TITAN_LIBRARY_VERSION=0.6 PREFIX="$PREFIX")

curl -fLO https://luarocks.github.io/luarocks/releases/luarocks-3.13.0.tar.gz
tar zxf luarocks-3.13.0.tar.gz
(cd luarocks-3.13.0 &&
  ./configure --prefix="$PREFIX" --rocks-tree="$PREFIX" --with-lua="$PREFIX" --force-config &&
  make && make install)

export PATH="$PREFIX/bin:$PATH"
luarocks install titan
titanc --print-root    # prints $PREFIX if the install worked
```

Keep `$PREFIX/bin` first on `PATH` so that `lua`, `luarocks`, and `titanc` all
come from this installation. The build downloads and compiles libuv, llhttp,
SQLite, and libbacktrace, and LuaRocks fetches four Lua dependencies, so it needs
network access and takes a while.

### Other ways to install

[Installing Titan on Linux and macOS](doc/language/installation.md) explains each
step above and covers the other cases:

- [From a Git checkout](doc/language/installation.md#from-a-git-checkout), where
  `make lua`, `make luarocks`, and `luarocks make` replace the manual steps.
- [Bundled OpenSSL](doc/language/installation.md#bundled-openssl) instead of the
  system library.
- [Readline on macOS](doc/language/installation.md#readline-on-macos) and
  [building Lua without Readline](doc/language/installation.md#without-readline).
- [Your own compiler and flags](doc/language/installation.md#your-own-compiler-and-flags).
- [A separate rocks tree](doc/language/installation.md#a-separate-rocks-tree),
  [a binary rock](doc/language/installation.md#a-binary-rock), and
  [a debug installation](doc/language/installation.md#a-debug-validation-installation).
- [Rebuilding the standard library](doc/language/installation.md#building-the-standard-library-from-a-checkout)
  while developing it, [uninstalling](doc/language/installation.md#uninstalling),
  and [what gets installed](doc/language/installation.md#what-gets-installed).

On Windows, follow
[Installing and using Titan on Windows](doc/language/windows-build.md).

## Using `titanc`

`titanc` takes dotted module names, not file paths, and looks for source
in the current directory (change it with `--tree`). Pass `-o DIRECTORY` to keep
all generated files in one place.

```sh
titanc -o out app.main              # a program, if app/main.titan defines main
titanc -o out greeting              # a library: out/greeting.so, .a, and .lua
titanc -o out --test calc_test      # a native test executable
```

- A module that defines `function main(args: {string}): integer` becomes an
  executable. `args[1]` is the first command-line argument.
- Any other module becomes a library. Titan code imports it with `import`, and
  Lua code uses `require`:

  ```sh
  LUA_PATH='out/?.lua;;' LUA_CPATH='out/?.so;;' \
    lua -e 'print(require("greeting").make("Lua"))'
  ```

- Standard-library modules have short names in Titan (`import "fs"`) and
  qualified names in Lua (`require "titan.fs"`).

The [language reference](doc/language/modules.md#compiling-modules-titanc) lists
every `titanc` option. See also
[Output directories](doc/language/output-directory.md),
[Incremental and separate compilation](doc/language/incremental-compilation.md),
and [Testing Titan code](doc/language/standard-library-test.md).

## Documentation

- [Titan quick tour](doc/quick-tour.md): short runnable programs that introduce
  the language and standard library. Start here.
- [Language reference](doc/language/index.md): the full description of the
  language and every standard-library module.
- [Style guide](doc/style-guide.md): conventions for Titan and
  standard-library code.
- [Implementation documentation](doc/implementation/index.md): the compiler,
  generated C, runtime, ABI, and how Titan and Lua interoperate. Read it if you
  want to change Titan itself.

## Working on Titan

Work from a [Git checkout](doc/language/installation.md#from-a-git-checkout).
Run the whole test suite in a throwaway installation:

```sh
export PREFIX="/tmp/titan-$USER-test"
export PATH="$PREFIX/bin:$PATH"
make test
```

`make test` builds Lua and LuaRocks into the prefix if they are missing,
reinstalls the current checkout, and then runs the compiler specs (Busted) and the
standard library's native tests. The
[repository workflow](doc/implementation/repository-workflow.md) lists the
commands for running one part, filtering tests, and using the checkout compiler
without reinstalling. The
[test runner](doc/implementation/test-runner.md) and
[continuous integration](doc/implementation/continuous-integration.md) chapters
cover how the suite is organized and what CI runs, including the required
macOS check before merging.

Use `make clean` to remove generated outputs and `make distclean` to also remove
downloaded dependency sources. See
[Cleaning a checkout](doc/language/installation.md#cleaning-a-checkout).

## Roadmap

This roadmap toward Titan 1.0 is preliminary. Everything is subject to change,
and items further down are more likely to change.

### Supported

- Control structures from Lua, including generic `for ... in`
- Errors with `raise`, `catch`, and `defer`, integrated with Lua errors, with
  unified Lua and Titan backtraces
- Multiple assignment and multiple results
- Scalar types: integers, floats, booleans, strings
- The `value` type, with checked conversions at its boundary
- Arrays that can have interior holes while `#` stays O(1), and Maps that are
  ordinary Lua tables
- Variadic functions (`...: T`) and flexible results (`(...: T)`)
- First-class functions, anonymous functions with lexical scope, and bound
  methods
- [Generics](doc/language/generics.md) with interface constraints and local
  type inference
- Nominal records and unions, interfaces, const values, and transparent type
  aliases (including public re-exports of nominal types)
- [Native storage in records](doc/language/nominal-storage.md), module-local
  fields, `{ ... }` construction, record and union methods, and bound methods
- `case`/`when` dispatch on union variants
- Modules that can span several `.titan` files in one folder and publish type
  information in `.a` and `.so` files. Ordinary imports see only public
  declarations. `import "foo.bar.titan"` requires source and also exposes the
  module's local declarations to that one importer. Dotted module names ending
  in `titan` are reserved for this syntax.
- Module initializers: a `do ... end` block that runs at module startup
- A C interface: primitive types, pointers, arrays, structs and unions
  (including stack allocation and flexible array members), owned heap
  allocation, C varargs, and C function calls
- `foreign` functions, which define C callbacks in Titan
- Asymmetric, tagged, nestable coroutines as the base for async I/O
- Async tasks, timers, files, DNS, TCP, verified TLS, HTTP/1.1 clients and
  servers, WebSocket, OS utilities and signals, child processes with pipes, and
  graceful process exit
- OS threads, each with its own Lua state, connected by bounded channels
- JSON, Protocol Buffers, SQLite, typed parsing expressions (PEGs), byte
  strings with Lua-compatible formatting and packing, and compiled regular
  expressions
- Math and random numbers, dynamic Lua loading, generic iteration, runtime
  reflection, explicit garbage-collector control, and table and userdata
  finalizers
- A native test runner with source coverage

### Next

- A language server
- Titan 1.0
