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
remains unmodified; generated logical-module loaders use Titan's native
lazy/global helper to map or promote their physical provider. The build then
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
| `$ROCKS_TREE/include/minicoro.h`, `titan.h`, `titan_longjmp.h` | Non-Lua top-level SDK headers |
| `$ROCKS_TREE/include/titan/{ffi,coro,uv}.h` | Namespaced portable FFI, coroutine, and libuv shim headers |
| `$ROCKS_TREE/lib/titan/0.16/titan.so` | The one standard-library provider: native `require "titan"` support plus the independent `coroutine`, `uv`, `async`, `timer`, `fs`, `net`, and `os` logical modules |
| `$ROCKS_TREE/share/lua/5.5/titan/{coroutine,uv,async,timer,fs,net,os}.lua` | Generated logical-module loader shims that map the canonical provider globally and invoke their exact `luaopen_titan_*` entries |

Bundled-libuv installs also contain `$ROCKS_TREE/include/uv.h` and
`$ROCKS_TREE/include/uv/`. The bundled `libuv.a` is a private build artifact:
it is consumed only while linking the canonical `titan.so` and is not
installed or exported as part of the Titan SDK. System mode uses the selected
system libuv instead. The standard logical modules have independent state and
entries inside that one image; installation does not create child DSO aliases,
symbolic links, hard links, or copied DSOs. The combined `titan.so` supplies
the process's one complete libuv provider.

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

In bundled mode, the combined `titan.so` is the sole complete libuv provider.
A compiled Titan extension DSO that directly `foreign import`s `uv.h` must also import the
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

The generated `titan/uv.lua` loader resolves the physical provider name
`titan` with `package.searchpath("titan", package.cpath)`, obtains the native
support table through bare `require "titan"`, then uses its separate
`RTLD_LAZY | RTLD_GLOBAL` cache to promote the same canonical `titan.so` and
invoke `luaopen_titan_uv`. Thus the first qualified `require` above establishes
the provider on stock Lua 5.5 on Linux and macOS. The bare support load uses
Lua's ordinary eager/local C searcher; the generated loader performs the
explicit promotion without a patched `loadlib.c` or a self-loading provider.

Because this explicit Lua preload happens before the extension is mapped, it
also supports its eager libuv relocations and native constructors. It can make
the native symbols available even to a Lua-only extension that omitted the
Titan `uv` import, but such a module does not satisfy the Titan-side contract.

System mode may instead link the extension against the same
pkg-config-selected shared libuv used by `titan.so`. In either mode, never
embed the bundled `libuv.a` in another DSO: it is private to the standard
provider and a second static embedding would create a second native libuv
instance.

CMake owns the archiver and indexer associated with the bundled build's C
compiler; select unusual CMake toolchain executables explicitly through
`LIBUV_CMAKE_FLAGS` rather than Make's `AR`/`RANLIB`, which configure Titan's
own runtime archive.

The Titan-owned Lua's configured default `package.cpath` contains
`$PREFIX/lib/titan/0.16/?.so` before `$PREFIX/lib/lua/5.5/?.so`. The first
template lets the generated `titan.*` loaders find the canonical provider; the
second remains the root-discovery anchor. The default `package.path` finds all
seven loaders under `$PREFIX/share/lua/5.5/titan/`. In the currently supported
layout
`ROCKS_TREE == PREFIX`, so `titanc` can use the first entry ending in
`/lib/lua/5.5/?.so` to recover its Titan SDK/rocks root.
During the source rock's post-install build, the internal `TITAN_ROCKS_ROOT`
override identifies `ROCKS_TREE` directly. The recovered Titan root supplies
the staged Lua sources and archives and compiled provider under
`$ROCKS_TREE/lib/titan/0.16/`; the standard library's qualified `titan.*`
modules consequently live as independent entries inside `titan.so`. This
discovery rule implements the supported equal-root layout; it does not redefine the
separately owned `PREFIX` and `ROCKS_TREE` as one concept.

At startup a compiled executable inherits Lua's default `package.cpath` and
ensures `$ROCKS_TREE/lib/titan/0.16/?.so` is present. Both it and the installed
Lua therefore resolve `titan.<name>` through a generated loader to the same
canonical file at `$ROCKS_TREE/lib/titan/0.16/titan.so`; there are no child,
Lua-facing, or parent-level compatibility copies.

An unmodified Lua 5.5 can reproduce those search paths with versioned
environment variables. Include the ordinary Lua C-module template because it
is also Titan's installation-root anchor:

```sh
export LUA_PATH_5_5="$ROCKS_TREE/share/lua/5.5/?.lua;$ROCKS_TREE/share/lua/5.5/?/init.lua;;"
export LUA_CPATH_5_5="$ROCKS_TREE/lib/titan/0.16/?.so;$ROCKS_TREE/lib/lua/5.5/?.so;;"
```

If that root-anchor template is deliberately omitted, set
`TITAN_PATH_0_16="$ROCKS_TREE/lib/titan/0.16"` as well.

`TITAN_PATH_0_16` (or the unversioned `TITAN_PATH`) overrides the Titan binary
search path. A short standard-library import is desugared before resolution
(`import "timer"` becomes `import "titan.timer"`), so ordinary qualified
lookup below `$ROCKS_TREE/lib/titan/0.16` reaches the canonical provider. In a
source checkout, `--lua` can select another complete Lua source/build tree for an
individual compiler invocation. An installed compiler rejects `--lua` because
its headers, `liblua.a`, and `libtitan.a` are one matched SDK. These overrides
are mainly useful for testing and nonstandard source builds; a normal
local-prefix install needs none of them.

This is not yet Titan's story for packaging or distributing Titan libraries
and applications: give a project its own standalone absolute `PREFIX` and use
the currently equal system-style `ROCKS_TREE` and installed `titanc`. The
current Titan rock is likewise a **source-install** package. Its
`build_target = "titan"` builds the runtime, a private support-only bootstrap,
and the SDK archives/headers/Lua sources. When the canonical 0.16 provider is
absent, the build atomically stages that bootstrap at
`$ROCKS_TREE/lib/titan/0.16/titan.so` so the just-installed compiler can load
its native support table; a repeated install preserves an already valid full
image. After LuaRocks deploys the compiler, the source-only `post_install` hook
invokes that `titanc` once for all seven standard roots, stages the combined
image and generated loaders privately, validates them, and publishes them with
rollback, committing `titan.so` last. There is no separate Make install pass
or pre-install hook. The provider, generated loaders, and SDK files remain
direct artifacts outside the rock manifest, so `luarocks remove titan` does
not remove them. Titan does not provide binary rocks yet; packaging and
uninstall ownership for these files will be revisited with a Titan
library/application distribution system.

# Usage

```sh
$ titanc [--print-ast] [--lua <path>] [--tree <path>] <module> [<module>]
```

The compiler takes a list of module names that you want to compile. Modules
are looked up in the source tree (defaults to the current working directory,
but you can override this with the `--tree` option), as well as in the Titan
binary path, a semicolon-separated list of paths. By default this is the
current directory plus `<root>/lib/titan/0.16`, where `<root>` is recovered
from `package.cpath`; override it with `TITAN_PATH_0_16` or `TITAN_PATH`.

Compiled dependency lookup probes component-prefix providers. For logical
`a.b.c`, each binary root is checked at `a.so`, `a/b.so`, and exact
`a/b/c.so`; the first candidate with valid `a_b_c_abi` and `a_b_c_types`
metadata wins. An earlier root's existing relative pathname shadows the same
candidate in later roots. Modules named explicitly on the command line remain
source-first, while ordinary dependencies remain binary-first. See
[Multi-module libraries](doc/language/multi-module-libraries.md) for the
provider, metadata-claim, and generated-loader rules.

A logical module may be one flat source or a folder of immediate
contributors. For module `M`, let `P` be its dotted name with slashes and `B`
its last component: each source root checks folder main `P/B.titan` before
flat `P.titan`. A selected folder contributes every immediate regular
`.titan` sibling in deterministic numeric-byte basename order; all files share
one module namespace, checker/codegen pass, state, generated object, and
logical loader. The final provider may also contain other logical modules.
Contributors are not directly importable as apparent flat child modules,
although a genuine deeper folder `P/child/child.titan` remains legal. See
[Folder modules](doc/language/folder-modules.md) for ordering, initialization,
lookup privacy, and artifacts.

Within either source form, records, type aliases, ordinary functions, methods,
and record functions are order-independent; a method, record function, or
record construction may precede its written record declaration. Imports are
available regardless of placement to those declarations and their bodies. A
module-variable declaration is the exception: it sees only earlier imports
and earlier module variables, while still seeing every record, alias, and
callable declaration. Logical source order continues to determine duplicate
precedence, interface/member and module-slot ordering, module-variable
initialization, and code generation.

The standard-library short names (`coroutine`, `uv`, `async`, `timer`, `fs`,
`net`, and `os`) are parser sugar for the corresponding `titan.*` module
names. Module resolution checks binary dependencies before source, so an
ordinary `./titan/uv/uv.titan` folder cannot displace the installed `titan.so` provider;
someone who explicitly changes `TITAN_PATH` to hide that provider is choosing
a different module installation. Modules explicitly named on the `titanc`
command line must come from source and use the folder-before-flat rule. Titan code uses the
short imports, while Lua uses the
qualified names `require "titan.coroutine"`, `require "titan.async"`,
`require "titan.timer"`, `require "titan.fs"`, `require "titan.net"`, and
`require "titan.os"`. The private `titan.uv` logical module remains available
for runtime plumbing and direct-libuv extensions. Lua's own `coroutine` and
`os` modules remain unchanged.

The logical async chain remains `titan.coroutine -> titan.uv -> titan.async`,
with `titan.timer`, `titan.fs`, `titan.net`, and `titan.os` built on the same
private plumbing. Production builds pass all seven roots to one `titanc`
invocation, so their source imports are statically resolved inside
`titan.so`. That one provider consumes libuv directly: bundled mode links its
private archive once, while system mode links the pkg-config-selected shared
library once. Seven generated Lua loaders expose the qualified logical entries.
Its source is the reviewed folder ensemble rooted at `titan/uv/uv.titan`, with
`file.titan`, `os.titan`, `process.titan`, `runtime.titan`, `task.titan`, and
`tcp.titan` as contributors. The main file is the shared prelude and sole
initializer, retaining the common imports, shared constants, module state, and
bootstrap. Exported declarations, all private records, and the private `FS`
constants instance live with their related contributor implementations. That
deliberate member reorder is the compatibility boundary recorded for
compiled-module ABI 0.15: at that historical boundary the files compiled to
one `titan/uv.so`, never one image per contributor. ABI 0.16 keeps that folder
as one logical object and loader, then links it with the other standard objects
inside the combined `titan.so` provider. The generated import-resolution and
installed-layout change is the 0.16 compatibility boundary even though the
per-module type schema and native call convention are unchanged.

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

From Lua, schedule Tasks with the public `async` facade and drive them
explicitly:

```lua
local async = require "titan.async"
local timer = require "titan.timer"

local task = async.run(function()
    timer.yield()
    return "done"
end)
assert(task:status() == "ready") -- `run` has not executed it
async.loop()
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
* Otherwise, it compiles one C/object pair per logical source module and links
  their union into one shared-library provider named by the requested roots'
  longest common dotted-component prefix. It also emits one generated Lua
  loader per linked logical module, including source dependencies. The
  generated `.c` and `.o` files are written next to the flat source or
  canonical folder main; the provider and loaders are written relative to the
  directory where `titanc` runs. Dependencies selected from compiled providers
  remain dynamically loaded. Requested roots with no common component must be
  built in separate invocations.

For example, flat `foo.bar` uses source `foo/bar.titan`, generated
`foo/bar.c` and `.o`, loader `foo/bar.lua`, shared library `foo/bar.so`, and
executable `foo/bar`.
A folder `foo.bar` uses main `foo/bar/bar.titan`, generated
`foo/bar/bar.c` and `.o`, the same loader/provider paths, and executable
`foo/bar__main`. Both program forms retain entrypoint
`foo/bar__entrypoint.c`; the folder suffix prevents a collision with its
source directory, including with an external `--tree`. For dotted external
sources, Titan creates the logical output parent in the current directory
before linking. Contributors never produce separate artifacts. A multi-root
`titanc foo.left foo.right` build instead emits `foo.so`, `foo/left.lua`, and
`foo/right.lua`, with no child DSOs. The logical modules remain independent
inside that image; see
[Multi-module libraries](doc/language/multi-module-libraries.md).

# Running the test suite

The test suite is written using [Busted](https://lunarmodules.github.io/busted/).
The simplest way to run it in an isolated installation is:

```sh
$ export PREFIX="/tmp/titan-$USER-test"
$ export PATH="$PREFIX/bin:$PATH"
$ make lua
$ make luarocks
$ make libuv
$ make test
```

`make test` runs `luarocks make --force` followed by `luarocks test`. The forced
build installs the current checkout — including the combined `titan.so`
support/standard-library provider — and `luarocks test` installs the test dependencies
(Busted and cluacov, declared in the rockspec) and runs the suite from the
repository root. It clears ambient `LUA_PATH`/`LUA_CPATH` overrides for both
commands, so a shell left over from an old `luarocks init` project cannot make
the prefix tools load a different compiler snapshot. The supported workflow
does not use `luarocks init`; avoid exporting those project-tree paths while
working in a standalone Titan prefix. To run the iterative development steps
yourself:

```sh
$ "$PREFIX/bin/luarocks" make --force        # rebuild/reinstall the current checkout
$ "$PREFIX/bin/luarocks" test                # install test deps + run the suite
$ bash spec/support/ci_test_groups.sh compiler # compiler/language tests with LuaCov
```

The grouped compiler command is the coverage entry point. Library API and
runtime suites run without LuaCov because the hook measures the Lua compiler,
not the generated Titan or native library implementation; use
`bash spec/support/ci_test_groups.sh libraries` for that complete group.

Note that `luarocks test` does **not** build the rock-under-test, only its
dependencies, so always `luarocks make` first (that is what `make test` does).
If you drive Busted directly, use the `busted` installed in `$PREFIX/bin`; the
prefix-configured Lua paths then find the native support entry installed in
the canonical provider by `luarocks make`. Once the Titan rock is installed, Busted loads compiler
modules from that *installed* rock, not from your checkout. Re-run
`$PREFIX/bin/luarocks make` after editing compiler sources so tests see the
changes.

With a working Titan installation's `bin` directory already on `PATH`, the
equivalent `luarocks make --force` and `luarocks test` commands work from the
repository root without setting `PREFIX` or `ROCKS_TREE`. The tests discover
the active installation from Lua's configured module paths and use the `lua`
on `PATH` for child interpreters.

# Building the examples

The `examples/` directory has its own `Makefile` with a target per example
module plus an `all` target. From the repository root, `make examples` builds
them all:

```sh
$ make examples            # or: make -C examples all
$ make -C examples utils   # build a single example
```

`sdl_demo` depends on `sdl_quit`, and both use the C FFI against SDL2, so they
need the SDL2 development headers installed.

# Cleaning up

`make clean` removes generated build and test artifacts (object files, generated
C, compiled modules, coverage data), including nested `titan/uv/uv.c` and
`titan/uv/uv.o` plus the seven known generated standard-library loaders, while
keeping source files and downloaded dependency trees.
`make distclean` additionally removes the downloaded Lua, LuaRocks,
libbacktrace, and libuv source/build trees and release tarballs. Neither target
removes an installed `PREFIX`; delete a throwaway `/tmp` prefix separately
when it is no longer needed.

# Compiler options

```
        --print-ast                       Print the AST.
        -v, --verbose                     Print safely quoted effective compiler commands.
        --lua <path>                      Path to a Lua source/build tree (source checkouts only).
        --tree <path>                     Path to the source tree for Titan modules (default '.').
        -l, --link <lib1,lib2>            Add libraries to the final link.
        -X, --extra-object <object...>     Add object/archive inputs to the final link.
        -h, --help                        Show this help message and exit.
```

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
* folder modules: one logical namespace and artifact assembled
  deterministically from a canonical main plus immediate contributors
* order-independent records, aliases, functions, methods, and record functions,
  with source-ordered import/module-variable initialization frontiers
* multiple assignment/multiple returns
* FFI with C (C primitive types, pointers, arrays, structs/unions, owned
  buffers, explicit C varargs, and C function calls)
* records (structs) with `:` method calls
* maps
* transparent type aliases, including public record re-exports
* first-class functions
* anonymous functions and closures, with proper lexical scoping
* bound methods (`obj:method`) as first-class values
* variadic parameters in functions (Lua `...`)
* flexible return tails (`...: T`), including contextual multiple-result
  calls through Lua `value` callables
* generic `for ... in` iterators with optional state, start value, and close
  callable
* error handling with `raise`, `catch`, `finally`, Lua `pcall`, and
  unified Lua/Titan backtraces via `titan.backtrace()`
* asymmetric, tagged (nested) coroutines as building block for async IO
* libuv-backed `async` Tasks, timers, asynchronous binary filesystem I/O, DNS,
  TCP,
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
