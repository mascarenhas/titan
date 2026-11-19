# Titan
[![CI](https://github.com/mascarenhas/titan/actions/workflows/ci.yml/badge.svg)](https://github.com/mascarenhas/titan/actions/workflows/ci.yml)
[![Coverage Status](https://codecov.io/gh/titan-lang/titan/coverage.svg?branch=master)](https://codecov.io/gh/titan-lang/titan/branch/master)

Titan is a statically typed, ahead-of-time-compiled sister language to
[Lua](https://www.lua.org). Its syntax and arithmetic stay close to Lua, every
variable has a static type, and compiled modules run inside the Lua runtime so
Lua programs `require` them directly while sharing values and the garbage
collector.

Titan compiles to native executables and libraries on Linux and macOS, with
experimental support for Windows and a WebAssembly browser target through
[Emscripten](https://emscripten.org).

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

## What is in it

- **Language:** 64-bit `integer`, IEEE-754 `float`, `boolean`, byte `string`,
  option types (`T?`), dense Arrays (`{T}`, `const { T }`, `const? { T }`) and
  Maps (`{K: V}`), nominal records and tagged unions with `case`, nominal
  Interfaces with structural satisfaction, erased generics with Interface
  constraints, first-class closures with multiple and flexible returns,
  gradually typed `value`, and error handling with `raise`, `catch`, and
  `defer`.
- **Modules and toolchain:** flat and folder modules, target-specific source
  variants, incremental compilation, shared `.so` and static `.a` providers
  carrying their own type metadata, and native executable-line coverage.
- **C interface:** `foreign import` binds C headers directly; `foreign function`
  exports C-ABI functions and writes GC-free C callbacks in a restricted C-like
  subset.
- **Standard library:** 26 native modules—cooperative `async` Tasks and timers
  on libuv, files, DNS/TCP, verified TLS, HTTP/1.1 client and server,
  WebSocket, child processes, OS threads with bounded channels, JSON, Protocol
  Buffers, SQLite, parsing expression grammars (`peg`), byte strings and
  regexes, reflection, GC controls, Lua states, and a native test runner—plus
  21 modules (including typed JavaScript bindings in `browser`) on the
  WebAssembly browser target.

## Install

The default Linux and macOS installation puts Lua 5.5.1 (from Titan's fork),
stock LuaRocks 3.13.0, and Titan under one absolute `PREFIX`. Install the
system prerequisites first:

```sh
# Ubuntu/Debian
sudo apt-get install build-essential cmake curl git libreadline-dev libssl-dev pkg-config
# Fedora
sudo dnf install gcc make cmake curl git readline-devel openssl-devel pkgconf-pkg-config
# macOS (see the installation guide for Homebrew's keg-only Readline)
xcode-select --install && brew install cmake readline openssl@3 pkgconf
```

Then build Lua and LuaRocks into your prefix and install Titan (use `macosx`
instead of `linux-readline` on macOS):

```sh
export PREFIX="$HOME/.local/titan/my-project"

curl -fL -o lua-titan.tar.gz https://github.com/mascarenhas/lua-5.5.1/archive/refs/tags/v5.5.1-1.tar.gz
tar zxf lua-titan.tar.gz
(cd lua-5.5.1-5.5.1-1 &&
  make linux-readline PREFIX="$PREFIX" &&
  make install PREFIX="$PREFIX")

curl -fLO https://luarocks.github.io/luarocks/releases/luarocks-3.13.0.tar.gz
tar zxf luarocks-3.13.0.tar.gz
(cd luarocks-3.13.0 &&
  ./configure --prefix="$PREFIX" --rocks-tree="$PREFIX" --with-lua="$PREFIX" --force-config &&
  make && make install)

export PATH="$PREFIX/bin:$PATH"
luarocks install titan
titanc --print-root    # prints $PREFIX
```

Keep `$PREFIX/bin` first on `PATH` so `lua`, `luarocks`, and `titanc` come from
the same installation. The rock build downloads and compiles libuv, llhttp,
SQLite, and libbacktrace alongside four Lua rocks.

### Other installation options

- [Installing Titan on Linux and macOS](doc/language/installation.md):
  [from a Git checkout](doc/language/installation.md#from-a-git-checkout),
  [bundled OpenSSL](doc/language/installation.md#bundled-openssl),
  [Readline on macOS](doc/language/installation.md#readline-on-macos),
  [without Readline](doc/language/installation.md#without-readline),
  [custom compilers and flags](doc/language/installation.md#your-own-compiler-and-flags),
  [separate rocks tree](doc/language/installation.md#a-separate-rocks-tree),
  [binary rocks](doc/language/installation.md#a-binary-rock),
  [validation debug installs](doc/language/installation.md#a-debug-validation-installation),
  [browser Lua and SDK](doc/language/installation.md#the-browser-lua-and-sdk),
  [rebuilding the standard library](doc/language/installation.md#building-the-standard-library-from-a-checkout),
  [what gets installed](doc/language/installation.md#what-gets-installed), and
  [uninstalling](doc/language/installation.md#uninstalling).
- [Installing and using Titan on Windows](doc/language/windows-build.md):
  experimental MSYS2 CLANG64 build and deployment guide.

## Using `titanc`

`titanc` takes dotted module names (not file paths) resolved from `--tree`
(default `.`). Pass `-o DIR` to keep all generated files in one directory:

```sh
titanc -o out app.main              # executable (when app/main.titan defines main)
titanc -o out greeting              # library pair: out/greeting.so and out/greeting.a
titanc -o out --test calc_test      # native test executable
```

- A module defining `function main(args: {string}): integer` builds an
  executable (`args[1]` is the first command-line argument).
- Any other module builds a library. Titan code loads it with `import`; Lua
  code installs Titan's package searcher with `require "titan"` and loads it
  along `TITAN_PATH_0_6`:

  ```sh
  TITAN_PATH_0_6='out;;' \
    lua -e 'require "titan"; print(require("greeting").make("Lua"))'
  ```

- Standard-library modules use short names in Titan (`import "fs"`) and
  qualified names in Lua (`require "titan.fs"`).

See [The `titanc` toolchain](doc/language/toolchain.md) for all compiler flags,
incremental builds, linking, and native coverage, and
[Testing Titan code](doc/language/standard-library-test.md) for the test runner.

## Documentation

- [A Tour of Titan](doc/language/tour.md): runnable walkthrough of the language
  and standard library. Start here.
- [The Titan Programming Language](doc/language/index.md): complete language
  guide, standard library reference, and appendices.
- [Titan Style Guide](doc/style-guide.md): idiomatic patterns and conventions
  for writing Titan code.
- [Implementation Documentation](doc/implementation/index.md): compiler
  pipeline, generated C, runtime, and contributor workflows.

## Working on Titan

Clone with submodules and run the full mixed test suite in an isolated prefix
(see [From a Git checkout](doc/language/installation.md#from-a-git-checkout)):

```sh
export PREFIX="/tmp/titan-$USER-test"
export PATH="$PREFIX/bin:$PATH"
make test
```

`make test` prepares Lua and LuaRocks if absent, reinstalls Titan, and runs the
Busted compiler specs and native standard-library tests. See
[Repository workflow](doc/implementation/repository-workflow.md),
[Test runner](doc/implementation/test-runner.md),
[Continuous integration](doc/implementation/continuous-integration.md), and
[Cleaning a checkout](doc/language/installation.md#cleaning-a-checkout).

## License

Titan is available under the MIT license. See [LICENSE](LICENSE).
