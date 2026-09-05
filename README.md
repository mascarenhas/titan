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
inherent requirement of what either name owns.

Generated C is compiled directly by default, so ordinary Linux and macOS builds
do not require a formatter. Pass `titanc --pretty-print` to run `clang-format`
on generated `.c` and `.titan.h` files before native compilation or
publication; install the `clang-format` package on Debian/Ubuntu,
`clang-tools-extra` on Fedora, or `brew install clang-format` on macOS for that
opt-in mode. `CLANG_FORMAT` selects a different compatible command.

For example:

```sh
export PREFIX="$HOME/.local/titan/my-project"
export PATH="$PREFIX/bin:$PATH"

make lua
make luarocks
"$PREFIX/bin/luarocks" make
```

`make lua` fetches the
[Lua 5.5.1 sources](https://www.lua.org/ftp/lua-5.5.1.tar.gz) and configures
`lua-5.5.1/src/luaconf.h` so `LUA_ROOT` is this `PREFIX`. Lua's `loadlib.c`
remains unmodified; generated logical-module loaders use Titan's native
lazy/global helper to map or promote their physical provider. The build then
compiles Lua with `MYCFLAGS=-fPIC` and
installs it under the prefix. It also installs the Lua `.c` and `.h` sources
under `$PREFIX/src/lua-5.5.1/`. Consequently the
installed `liblua.a`, the internal headers Titan-generated C uses, and the
public headers used when LuaRocks builds other Lua libraries all describe the
same prefix and the same Lua build. The Makefile selects `linux-readline` on
Linux and `macosx` on Darwin; override it with
`make lua LUA_PLATFORM=...` when necessary, and use `LUA_CC` to select Lua's
C compiler. For those interactive targets, `make lua` first compile-links a
small program against the host's Readline header and library. If that probe
fails (as it does on minimal or immutable hosts without a development
package), the build verifies and unpacks the pinned GNU Readline 8.3 base
archive, applies the checked-in combination of its first three official
patches, configures it with the same `PREFIX`, and installs its headers, static
archive, documentation, and license under a private prefix-local directory
before building Lua. Parallel Make completes Lua extraction before writing the
selection file inside that tree; fallback compilation may remain parallel, but
Readline's upstream install pass is serialized because its archive replacement
rules race. The applied patch and license are checksum-bound to the selection
stamp, and repair builds validate a sibling stage before replacing an existing
private installation. A system Readline development package is not
required, but the fallback still needs a linkable curses, `tinfo`, or `termcap`
provider.
If automatic terminal-library detection fails, install the platform's
terminal-library development package or set `READLINE_TERMCAP_LIB` explicitly.
`READLINE_MODE=system` or `bundled` can force either branch. Installing
`libreadline-dev` on Debian/Ubuntu or `readline-devel` on Fedora remains an
optional way to use the system branch. Cross builds can pass an Autoconf target
triplet through `READLINE_HOST`; `READLINE_CPPFLAGS`, `READLINE_CFLAGS`,
`READLINE_LDFLAGS`, and `READLINE_ARFLAGS` configure the fallback toolchain.
Changing the prefix, platform, compiler, Readline selection, or native-build
flags invalidates the Lua objects before rebuilding, so the installed source
headers cannot silently drift from `liblua.a`.

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
Titan's version identities are deliberately separate. `TITAN_VERSION` is the
compiler and standard-library semantic version, currently `0.6.0`; its derived
major/minor library version, `0.6`, owns installed library and compiler-data
paths. `TITAN_ABI_VERSION` is the independent monotonic compiled-module
compatibility marker, currently `2`, and also scopes persistent native-probe
caches. This reset assumes a fresh installation and provides no migration or
compatibility aliases for earlier Titan installations.

The installed files used to compile Titan code include:

| Owner and path | Purpose |
| --- | --- |
| `$PREFIX/src/lua-5.5.1/`, `$PREFIX/include/{lua,lauxlib,lualib,luaconf}.h`, `$PREFIX/lib/liblua.a` | The prefix-configured Lua sources, public configuration/headers, and static library owned by the Lua installation |
| `$ROCKS_TREE/src/lua-5.5.1/`, `$ROCKS_TREE/lib/liblua.a` | Matching Lua source and archive copies staged as part of the Titan compiler SDK |
| `$ROCKS_TREE/lib/titan/0.6/libtitan.a` | Exactly `titan.o` and `minicoro.o`: generated-code loader/error support plus minicoro implementation/tag support; source foreign functions own the standard-library callbacks |
| `$ROCKS_TREE/lib/libbacktrace.a` | The separate vendored native unwinder/symbolizer archive |
| `$ROCKS_TREE/include/minicoro.h`, `titan.h` | Non-Lua top-level SDK headers |
| `$ROCKS_TREE/include/titan/ffi.h` | Namespaced portable FFI and audited Lua-internal bridge header |
| `$ROCKS_TREE/lib/titan/0.6/titan.so` | The dynamic standard-library provider: native `require "titan"` support plus nineteen independent logical modules from `titan.coroutine` through `titan.reflect` |
| `$ROCKS_TREE/lib/titan/0.6/titan.a` | The self-describing static form of the same nineteen logical standard modules, plus native support, private LPegLabel/llhttp payload, and bundled libuv/OpenSSL payload when those modes are selected |
| `$ROCKS_TREE/share/lua/5.5/titan/{coroutine,uv,async,timer,io,fs,net,ssl,url,http,os,peg,string,math,lua,iteration,gc,test,reflect}.lua` | Generated logical-module loader shims that map the canonical provider globally and invoke their exact `luaopen_titan_*` entries |
| `$ROCKS_TREE/share/titan/0.6/src/titan/test.titan` | Canonical compiler-data source used for the source-private native test-runner protocol |

The nineteen-module pair, shims, and test support source are the coordinated
ABI-2 standard image. `titan.io` owns the shared Interface vocabulary and
I/O helpers; bare native support adds the twentieth DSO opener without adding
a logical metadata key.

Bundled-libuv installs also contain `$ROCKS_TREE/include/uv.h` and
`$ROCKS_TREE/include/uv/`. The bundled `libuv.a` is a private build artifact:
its objects are carried into the canonical `titan.so` and `titan.a`, but the
libuv archive itself is not installed or exported as part of the Titan SDK.
System mode uses the selected system libuv as a final-link input instead. The
standard logical modules have independent state and entries inside both
provider forms; installation does not create child DSO aliases, symbolic
links, hard links, or copied DSOs. The combined `titan.so` supplies the
dynamic process's one complete libuv provider.

The standard provider also embeds a pinned, privately namespaced LPegLabel
engine for `titan.peg` and `titan.string`. Its exact five-object archive is a
source-build input carried into `titan.so` and `titan.a`; the archive and its
headers are not installed in the SDK, and applications do not need a separate
LPeg/LPegLabel runtime module.

It likewise embeds the always-private llhttp parser. Its eight C callbacks are
source-defined foreign functions in the generated `titan.http` object, so there
is no HTTP adapter input. The TLS module calls OpenSSL directly through Titan's
C FFI and uses either the pinned bundled OpenSSL objects or the system-mode
final-link result. Neither the private llhttp archive nor bundled OpenSSL
headers or archives become public Titan runtime-SDK libraries.

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

In bundled mode, the combined `titan.so` is the sole complete dynamic libuv
provider, while `titan.a` carries the same bundled libuv objects for static
Titan consumers.
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

## OpenSSL and llhttp setup

`titan.ssl` uses OpenSSL and `titan.http` uses llhttp. The default build pins,
downloads, verifies, and statically builds OpenSSL 3.5.7 and llhttp 9.4.3.
llhttp is always private and bundled. In addition to the libuv tools above,
the bundled OpenSSL build requires Perl:

```sh
make openssl
make llhttp
```

To use a system OpenSSL 3.0 or newer, install its development package and
pkg-config metadata, then select that mode consistently for the provider
build:

```sh
# Ubuntu/Debian
sudo apt-get install libssl-dev pkg-config
# Fedora
sudo dnf install openssl-devel pkgconf-pkg-config
# macOS
brew install openssl@3 pkgconf

OPENSSL_MODE=system make openssl
OPENSSL_MODE=system "$PREFIX/bin/luarocks" make
```

The no-override TLS client API uses OpenSSL's compiled default certificate
paths; it is not a portable wrapper around every platform's native trust
database. See [TLS standard library](doc/language/standard-library-ssl.md) for
explicit CA-file selection and the complete verification contract.

The Titan-owned Lua's configured default `package.cpath` contains
`$PREFIX/lib/titan/0.6/?.so` before `$PREFIX/lib/lua/5.5/?.so`. The first
template lets the generated `titan.*` loaders find the canonical provider; the
second remains the root-discovery anchor. The default `package.path` finds all
nineteen loaders under `$PREFIX/share/lua/5.5/titan/`. In the currently supported
layout
`ROCKS_TREE == PREFIX`, so `titanc` can use the first entry ending in
`/lib/lua/5.5/?.so` to recover its Titan SDK/rocks root.
During the source rock's post-install build, the internal `TITAN_ROCKS_ROOT`
override identifies `ROCKS_TREE` directly. The recovered Titan root supplies
the staged Lua sources and archives and compiled provider under
`$ROCKS_TREE/lib/titan/0.6/`; the standard library's qualified `titan.*`
modules consequently live as independent entries inside both `titan.so` and
`titan.a`. This
discovery rule implements the supported equal-root layout; it does not redefine the
separately owned `PREFIX` and `ROCKS_TREE` as one concept.

At startup a compiled executable inherits Lua's default `package.cpath` and
ensures `$ROCKS_TREE/lib/titan/0.6/?.so` is present. Both it and the installed
Lua therefore resolve `titan.<name>` through a generated loader to the same
canonical file at `$ROCKS_TREE/lib/titan/0.6/titan.so`; there are no child,
Lua-facing, or parent-level compatibility copies.

An unmodified Lua 5.5 can reproduce those search paths with versioned
environment variables. Include the ordinary Lua C-module template because it
is also Titan's installation-root anchor:

```sh
export LUA_PATH_5_5="$ROCKS_TREE/share/lua/5.5/?.lua;$ROCKS_TREE/share/lua/5.5/?/init.lua;;"
export LUA_CPATH_5_5="$ROCKS_TREE/lib/titan/0.6/?.so;$ROCKS_TREE/lib/lua/5.5/?.so;;"
```

If that root-anchor template is deliberately omitted, set
`TITAN_PATH_0_6="$ROCKS_TREE/lib/titan/0.6"` as well.

`TITAN_PATH_0_6` (or the unversioned `TITAN_PATH`) overrides the Titan binary
search path. A short standard-library import is desugared before resolution
(`import "timer"` becomes `import "titan.timer"`), so ordinary qualified
lookup below `$ROCKS_TREE/lib/titan/0.6` reaches the canonical provider. In a
source checkout, `--lua` can select another complete Lua source/build tree for an
individual compiler invocation. An installed compiler rejects `--lua` because
its headers, `lib/liblua.a`, and `lib/titan/0.6/libtitan.a` are one matched
SDK. These overrides
are mainly useful for testing and nonstandard source builds; a normal
local-prefix install needs none of them.

This is not yet Titan's story for packaging or distributing Titan libraries
and applications: give a project its own standalone absolute `PREFIX` and use
the currently equal system-style `ROCKS_TREE` and installed `titanc`. The
current Titan rock is likewise a **source-install** package. Its
`build_target = "titan"` builds the runtime, a private support-only bootstrap,
and the SDK archives/headers/Lua sources. When the canonical provider is
absent, the build atomically stages that bootstrap at
`$ROCKS_TREE/lib/titan/0.6/titan.so` so the just-installed compiler can load
its native support table; a repeated install preserves an already valid full
image. After LuaRocks deploys the compiler, the source-only `post_install` hook
invokes that `titanc` once for all nineteen current standard roots, with private
LPegLabel, selected libuv, HTTP/llhttp, and TLS/OpenSSL payload after
`ltitanlib.o`. It stages the paired providers, generated loaders, and exact `titan.test`
compiler source privately, validates them, and publishes them with rollback, committing
`titan.a` before `titan.so` and using the DSO rename as the final commit point.
Publication recognizes the bootstrap and current complete pair as recoverable
states in the active `0.6` library namespace; nineteen modules are the current
installed contract. No earlier Titan installation is a migration source.
There is no separate Make install pass or pre-install hook. The provider,
generated loaders, and SDK files remain
direct artifacts outside the rock manifest, so `luarocks remove titan` does
not remove them. Titan does not provide binary rocks yet; packaging and
uninstall ownership for these files will be revisited with a Titan
library/application distribution system.

# Documentation

Start with the runnable [Titan quick tour](doc/quick-tour.md), then use the
[language reference](doc/language/index.md) for normative semantics. The
[style guide](doc/style-guide.md) records the conventions used by current
Titan and standard-library code, while the [implementation
documentation](doc/implementation/index.md) covers the compiler, generated C,
runtime, ABI, and interoperation machinery.

# Usage

```sh
$ titanc [--print-ast] [-j jobs] [--static] [--test] [--no-uv-bootstrap] \
    [--no-line-directives] \
    [--lua <path>] [--tree <path>] <module> [<module>]
```

The compiler takes a list of module names that you want to compile. Use
`-j/--jobs` (or `TITAN_JOBS`) to bound concurrent generated-C object
compilations; the default is one, and values above one require the standard
POSIX `mkfifo` utility. Pass `--static` to prefer self-describing
Titan archives over shared providers for ordinary dependencies; it is a
preference, not a system-linker `-static` request. Modules
are looked up in the source tree (defaults to the current working directory,
but you can override this with the `--tree` option), as well as in the Titan
binary path, a semicolon-separated list of paths. By default this is the
current directory plus `<root>/lib/titan/0.6`, where `<root>` is recovered
from `package.cpath`; override it with `TITAN_PATH_0_6` or `TITAN_PATH`.

Successful C-FFI compiler probes retain the existing empty
`<digest>.success` markers under `<prefix>/var/cache/titan-probes/2`.
Deterministic compiler rejections use bounded, checksummed sibling
`<digest>.negative` records so they can preserve the ordinary exit status and
stable diagnostic bytes. Both forms use the same unchanged cache digest. The
toolchain portion includes the parsed compiler argv, compile flags, language
mode and flag, CPP/C flags, ordered include flags and paths, target-profile
identity, compile mode, and forced-header manifest. The version-2 module header
context includes its source directory, the forced-header manifest, and every
ordered include descriptor's original, resolved, kind, name, rendered spelling,
and file/search inputs. The
version-3 persistent digest then covers that toolchain identity, forced-header
manifest, semantic probe key, and the complete probe C source.

This identity remains an intentionally practical cache boundary rather than a
complete model of a C compiler installation: it does not hash the compiler
executable or attempt to capture every possible external policy input. The
later compilation of Titan's generated C remains authoritative. Infrastructure
failures are never persisted. A nonempty `TITAN_PREFIX` selects the cache
prefix, otherwise Titan recovers the installed prefix from `package.cpath`.
`TITAN_PROBE_CACHE_IDENTITY` optionally selects an additional hashed namespace.
Stable local rebuilds reuse the same prefix cache just like CI builds. Unique
source-foreign checking headers are hidden behind stable private probe wrappers,
preserving nested quoted-include origin without making a safety nonce part of
the key. Macro-derived declarations use deterministic bytewise name order, and
every rejected declaration batch is cached under its exact batch key before it
is bisected. An aggregate rejection is only evidence that some member failed;
an individual negative verdict is recorded only for a rejected singleton.

Compiled dependency lookup probes component-prefix providers. For logical
`a.b.c`, the default first performs a complete shared pass at `a.so`,
`a/b.so`, and `a/b/c.so` in each binary root, then repeats the same pass for
`.a`; `--static` swaps those two format passes. Within one format, an earlier
root's existing relative pathname shadows the same candidate in later roots.
Modules named explicitly on the command line remain source roots. See
[Static compiled modules](doc/language/static-compiled-modules.md) for archive
metadata and precedence and [Multi-module
libraries](doc/language/multi-module-libraries.md) for provider and
generated-loader rules.

Pass `--test` to source-prefer the requested closure, discover public
`test_*` functions taking one `test.Context`, and link a native executable
without writing an application `main`:

```titan
-- calc_test.titan
local test = import "test"
local calc = import "app.calc"

function test_twice(context: test.Context)
  test.assert(calc.twice(21) == 42)
end
```

```sh
titanc --test --tree . calc_test
./calc_test --filter=test_twice$
```

See [Testing Titan code](doc/language/standard-library-test.md) for source
visibility, subtests, cleanup, filtering, output, and statuses.
`--no-uv-bootstrap` is valid only for a normal standalone executable or a
`--test` executable. It makes the generated entrypoint call `main(args)`
directly even when an imported module installed the ordinary async bootstrap
hook. The hook and module initialization remain unchanged; code using this
option must explicitly own any `async.run`/`async.loop` sessions it needs.

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

Within either source form, records, unions, type aliases, ordinary functions,
methods, and nominal functions are order-independent; a method, nominal
function, record construction, or union-constructor use may precede its
written nominal declaration. Imports are
available regardless of placement to those declarations and their bodies. A
module-variable declaration is the exception: it sees only earlier imports
and earlier module variables, while still seeing every nominal owner, alias, and
callable declaration. Logical source order continues to determine duplicate
precedence, interface/member and module-slot ordering, module-variable
initialization, and code generation.

The standard-library short names are parser sugar
for the corresponding `titan.*` module names. Module resolution checks binary dependencies before source, so an
ordinary `./titan/uv/uv.titan` folder cannot displace the installed compiled
provider;
someone who explicitly changes `TITAN_PATH` to hide that provider is choosing
a different module installation. Modules explicitly named on the `titanc`
command line must come from source and use the folder-before-flat rule. Lua
always uses the qualified stdlib module names with the `titan.` prefix.
The private `titan.uv` logical module remains available
for runtime plumbing and direct-libuv extensions. Lua's own `coroutine` and
`os` modules remain unchanged.

The logical async chain remains `titan.coroutine -> titan.uv -> titan.async`,
with `titan.timer`, `titan.fs`, `titan.net`, and `titan.os` built on the same
private plumbing. `titan.peg` owns the typed parsing-expression surface and
`titan.string` builds byte operations, formatting/packing, and regexes on it.
The independent `titan.io` module owns the standard Reader, Writer, and Closer
Interface vocabulary and I/O helpers. The high-level `titan.ssl` and
`titan.http` modules compose over public networking and I/O APIs without
changing `titan.uv`; `titan.url` supplies HTTP and applications with reusable
PEG-based URL parsing. Math, dynamic Lua loading, generic
iteration, and GC control live in `titan.math`, `titan.lua`, `titan.iteration`, and
`titan.gc`; `titan.test` supplies native test contexts and assertions.
[`titan.reflect`](doc/language/standard-library-reflect.md) inspects runtime
values, nominal schemas, and public fields. GC-backed
owners can attach table/full-userdata finalizers
without discarding an existing metatable. Clean validation builds pass all
nineteen roots to one `titanc` invocation, while the five high-level libuv
facades explicitly import `uv.titan` for their private collaboration edges; the
source graph is statically resolved
inside the paired `titan.so` and `titan.a` providers. Bundled mode carries
libuv's objects into both forms; system mode keeps the pkg-config-selected
library as a repeated final-link input. The private LPegLabel objects enter
both forms in either libuv mode. Nineteen generated Lua loaders expose the
qualified logical entries.
Its source is the reviewed folder ensemble rooted at `titan/uv/uv.titan`, with
`file.titan`, `os.titan`, `process.titan`, `runtime.titan`, `task.titan`, and
`tcp.titan` as contributors. The main file is the shared
prelude and sole initializer, retaining the common imports, shared constants,
module state, and bootstrap. Exported declarations and private records live
with their related contributor implementations. Folder contributors compile
as one logical module, and the complete standard library is linked into the
paired `titan.so`/`titan.a` provider.

The current ABI covers the public module schema, native callable symbols,
canonical Array proxy contract, union and Interface representations, generic
metadata, source-defined foreign callbacks, and const-qualified descriptors
and wrappers. A provider with a different ABI is rejected before metadata
decoding or native value exchange. Current lookup and publication use
`TITAN_PATH_0_6` and `lib/titan/0.6`; the manually dispatched full macOS
pre-merge suite remains required.

From Titan, importing `timer` is enough to enable the standalone async
bootstrap:

```titan
local timer = import "timer"

function main(args: {string}): integer
  timer.sleep(10)
  return 0
end
```

Standalone `args` contains only user arguments at positive indices:
`args[1]` is the first argument, `args[0]` is nil, and the executable name is
not stored.

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

local result
local task = async.run(function()
    timer.yield()
    result = "done"
end)
assert(task:status():as_string() == "ready") -- `run` has not executed it
async.loop()
assert(task:status():as_string() == "succeeded")
assert(result == "done")
```

A Task's terminal status retains its returned value, raised value plus
traceback, or cancellation reason. Cancellation retains its reason privately
while the Task remains in its current live status, then publishes terminal
`cancelled`. The `async.any_*`, `race_*`, `all_*`, and `join*` combinators wait
for bounded groups through terminal listeners and explicit suspension without
adding a second scheduler; see the async chapter for their fixed-arity result
unions. `async.running()` returns the current Task. Explicit suspension creates
a private nominal `async.ResumeToken`, passes that same record to
`async.suspend(token)`, and later supplies it to `Task:resume(token)`. Only the
exact token for the current explicit suspension is accepted; ordinary native
operation callbacks continue through their private tokenless path.

An ordinary libuv operation callback directly resumes its Titan Task, and
application code runs in that callback until it finishes or starts another
async operation and yields. A one-shot timer instead closes from `timer_cb` and
resumes only from `close_cb`. Explicit resume, cancellation wake, deferred
close, and repeating-ticker continuations may use a Task-owned one-shot timer;
there is no polling phase fence, taskless timer, or implicit ready queue.
`timer.yield()` explicitly cedes an event-loop turn. See
[Asynchronous I/O and tasks](doc/language/async-io.md) and the
[timer](doc/language/standard-library-timer.md),
[filesystem](doc/language/standard-library-fs.md), and
[TCP networking](doc/language/standard-library-net.md) modules. Portable
environment, directory, identity, executable-path, one-shot signal,
argv-based child-process, and binary stdio helpers are documented in the
[OS standard library](doc/language/standard-library-os.md); the
[I/O standard library](doc/language/standard-library-io.md) adds the
shell-based, merged-output `popen` convenience.
The `peg` module provides typed parsing-expression constructors and captures;
the `string` module provides binary byte operations, Lua-compatible
formatting/packing and `tostring`, plus compiled byte regular expressions.
See the [PEG](doc/language/standard-library-peg.md) and
[string](doc/language/standard-library-string.md) standard-library chapters.

If everything is all right with your modules, you will get the result of
your compilation as a native binary:

* if one of your Titan modules has a `main` function, with signature
  `function({string}):integer`, then `titanc` will bundle all modules
  given in the command-line, along with every dependency that module resolution
  selected from source, as a stand-alone executable program. Dependencies
  selected from DSOs remain dynamically loaded, while dependencies selected
  from static providers are linked directly into the executable.
* Otherwise, it compiles one C/object pair per logical source module and
  publishes matching shared and static providers named by the requested
  roots' longest common dotted-component prefix. It also emits one generated Lua
  loader per linked logical module, including source dependencies. The
  generated `.c` and `.o` files are written next to the flat source or
  canonical folder main; the provider and loaders are written relative to the
  directory where `titanc` runs. Dependencies selected from DSOs remain
  dynamically loaded; dependencies selected from static providers are carried
  into both new provider forms and use direct native symbols. Requested roots
  with no common component must be built in separate invocations.

For example, flat `foo.bar` uses source `foo/bar.titan`, generated
`foo/bar.c` and `.o`, loader `foo/bar.lua`, providers `foo/bar.so` and
`foo/bar.a`, and executable `foo/bar`.
A folder `foo.bar` uses main `foo/bar/bar.titan`, generated
`foo/bar/bar.c` and `.o`, the same loader/provider paths, and executable
`foo/bar__main`. Both program forms retain entrypoint
`foo/bar__entrypoint.c`; the folder suffix prevents a collision with its
source directory, including with an external `--tree`. For dotted external
sources, Titan creates the logical output parent in the current directory
before linking. Contributors never produce separate artifacts. A multi-root
`titanc foo.left foo.right` build instead emits `foo.so`, `foo.a`,
`foo/left.lua`, and `foo/right.lua`, with no child providers. The logical
modules remain independent inside both native forms; see [Multi-module
libraries](doc/language/multi-module-libraries.md) and [Static compiled
modules](doc/language/static-compiled-modules.md).

# Running the test suite

The repository uses [Busted](https://lunarmodules.github.io/busted/) for
compiler, packaging, and native dependency/build gates. There are no Lua files
under `spec/stdlib/` and no root-level standard-library boundary specs.
Module-owned standard-library behavior, including fresh-process and host-stdio
cases, lives under `spec/stdlib/titan/`: compiled Titan parents launch focused
standalone fixtures through C99 `system`, consume explicit temporary result
files, and clean them with `defer`. The Makefile names
all 23 roots explicitly and compiles them together with one `titanc --test`
invocation. `make titan-stdlib-test-build` places the executable and synthetic
runner outputs below `.titan-tests/`; it passes `--no-uv-bootstrap` so each
async test explicitly owns one Runtime and completes Runtime-bound cleanup
before that session returns. `make titan-stdlib-test-run` executes the binary
from the repository root, and `make titan-stdlib-test` performs both.
Temporary source-adjacent generated C/object files and reserved `__test_*`
outputs are cleaned by ownership patterns rather than per-test names, without
deleting author-written native fixtures.

The native executable runs under a Bash process-group deadline. Its combined
output is streamed through a pipe, preserving the parent-descriptor behavior
exercised by OS/stdio tests. Tests that intentionally provoke uncaught async
Task errors use flushed `Context:log` lines to bracket those expected
diagnostics clearly in the aggregate output.

The simplest way to run the complete mixed suite in an isolated installation
is:

```sh
$ export PREFIX="/tmp/titan-$USER-test"
$ export PATH="$PREFIX/bin:$PATH"
$ make test
# Or use four-way native build and generated-C compilation:
$ TITAN_JOBS=4 make -j4 test
```

`make test` runs `luarocks make --force` followed by `luarocks test`. The forced
build installs the current checkout, including the combined `titan.so` and
`titan.a` support/standard-library providers. The rockspec's command backend
enters `spec/support/run_rock_tests.sh`, which invokes `make rock-test`: the
Busted tree runs first, followed by the same aggregate native executable.
Busted 2.3 does not provide a shard option, and many compiler specs share fixed
checkout-root artifact names. For an unfiltered run with no forwarded Busted
arguments, `rock-test` therefore runs the eight retained runtime/packaging specs
once, then externally partitions the compiler/language specs into four measured
groups in private checkout copies. Every worker has private general and ccache
temporary directories. It runs four workers by default, with nested Make and
`titanc` work capped at one slot per worker; set
`TITAN_ROCK_TEST_JOBS=1` through `4` to lower that concurrency. A nonempty
`BUSTED_FILTER` or any forwarded Busted argument preserves the single-process
Busted path. `TITAN_FILTER` alone does not disable compiler sharding, and the
native aggregate remains one executable.

The Linux compiler CI job uses the same measured partition but retains its own
coverage runner: it schedules at most two groups concurrently to match the
private runner's two CPUs, streams tagged output, then merges their separate
LuaCov stats. Local shards do not collect LuaCov data.
`BUSTED_FILTER` and `TITAN_FILTER` are independent Lua-pattern selectors;
filtering one domain does not skip the other, so use a leaf target when only one
is wanted. A Titan filter changes execution only—the build still compiles all
23 source-authoritative roots.

```sh
$ make stdlib-test
$ TITAN_ROCK_TEST_JOBS=4 make rock-test
$ make busted-test BUSTED_FILTER='parser'
$ make titan-stdlib-test TITAN_FILTER='^http[.]tests[.]test_client'
$ make titan-stdlib-test-build
$ make titan-stdlib-test-run TITAN_FILTER='^os[.]tests[.]'
$ make rock-test BUSTED_FILTER='checker' TITAN_FILTER='^uv[.]task_tests[.]'
$ BUSTED_FILTER='loader' TITAN_FILTER='^net[.]tests[.]' luarocks test
```

The backend still passes ordinary `luarocks test -- ...` arguments to Busted;
its explicit `--busted-filter` and `--titan-filter` forms map to the same two
independent variables. LuaRocks installs the declared Busted and cluacov test
dependencies. `make test` clears ambient `LUA_PATH`/`LUA_CPATH` overrides for
both subprocesses, so a shell left over from an old
`luarocks init` project cannot make the prefix tools load another compiler
snapshot. The supported workflow does not use `luarocks init`. For canonical
validation, also unset ambient `ROCKS_TREE`, `TITAN_ROCKS_ROOT`,
`TITAN_EXTRA_CPPFLAGS`, and `TITAN_NO_LINE_DIRECTIVES`; those explicit policy
inputs change provider/root selection, fixture preprocessing, or source-line
attribution and `make test` deliberately does not erase them.

Useful iterative and CI-equivalent commands are:

```sh
$ "$PREFIX/bin/luarocks" make --force          # install the current checkout
$ "$PREFIX/bin/luarocks" test                  # run Busted + aggregate native suite
$ make stdlib-test                            # complete stdlib/runtime work, no LuaCov
$ bash spec/support/ci_test_groups.sh compiler  # complete compiler/language set with LuaCov
```

Linux CI has one uncovered stdlib producer, which also prepares and validates
the bundled/system production images, and one standard-runner consumer for the
complete covered compiler/language set. That consumer extracts four isolated
workers from the prepared archive, runs at most two concurrently with tagged
output, and emits the sole merged Codecov report. Linux build/compiler bounds
are two to match the private runner; the manual macOS job overrides them to
three. The ASan+UBSan job restores its separately fingerprinted native
Lua/libbacktrace/libuv/llhttp/OpenSSL tree before LuaRocks/Titan work, saves only
that clean dependency boundary, and reuses one aggregate native build for
focused filters; it does not consume the regular artifact. Its 35-minute bound
also admits the infrequent cold-cache rebuild under the two-CPU policy.
The complete macOS suite remains a manually dispatched pre-merge gate and is
run only with explicit maintainer authorization.

To test compiler Lua edits without reinstalling them, run the explicit
`checkout` Busted profile from the repository root with the `busted` installed
in `$PREFIX/bin` and its prepared, ABI-matched SDK:

```sh
$ TITAN_ROCKS_ROOT="$PREFIX" TITAN_PROBE_CACHE_DISABLE=1 \
    busted --run=checkout spec/parser_spec.lua
$ TITAN_ROCKS_ROOT="$PREFIX" TITAN_PROBE_CACHE_DISABLE=1 \
    busted --run=checkout spec/coder/coder_spec.lua --filter='for loop'
```

The repository's `.busted` `checkout` profile prepends
`./?.lua;./?/init.lua` after the LuaRocks launcher has set its paths. An ambient
checkout-first `LUA_PATH` alone cannot override the launcher's installed paths.
The profile leaves the C module path intact, while the existing
`TITAN_ROCKS_ROOT` option keeps header and runtime-library selection on the
specified installation even when the driver Lua comes from the checkout.
The profile's standard Busted helper prepares the existing driver layout and
direct checker's C-header lookup with that SDK before tests run; it reports a
missing `TITAN_ROCKS_ROOT` immediately. Keep the option scoped to the focused
command. Compiler fixtures deliberately
reuse header pathnames, so direct runs must set `TITAN_PROBE_CACHE_DISABLE=1`
as the Make targets already do.

Default Busted runs, `make busted-test`, and `luarocks test` continue to use the
installed compiler snapshot. Reinstall compiler changes before those commands
or an installed `titanc` invocation. `luarocks test` does **not** build the
rock-under-test, only its test dependencies. `make test` remains the canonical
full validation: it installs the current compiler, SDK, and standard provider
first. Reinstall after changing runtime or standard-library code as well; the
explicit checkout profile does not refresh installed artifacts or rebuild the
native aggregate executable.

With a working Titan installation's `bin` directory already on `PATH`, the
equivalent `luarocks make --force` and `luarocks test` commands work from the
repository root without setting `PREFIX` or `ROCKS_TREE`. Tests discover the
active installation from Lua's configured paths and use the `lua` on `PATH`
for child interpreters.

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
`titan/uv/uv.o`, the `titan/http`, `titan/peg`, and `titan/string` folder-main
outputs, and
the nineteen known generated standard-library loaders, while
keeping source files and downloaded dependency trees.
`make distclean` additionally removes the downloaded or cloned Lua, GNU
Readline, LuaRocks, libbacktrace, libuv, OpenSSL, and llhttp source/build trees
and their release tarballs where applicable. Neither target
removes an installed `PREFIX`; delete a throwaway `/tmp` prefix separately
when it is no longer needed.

# Compiler options

```
        --print-ast                       Print the AST.
        --pretty-print                    Format generated C and headers with clang-format.
        --test                            Build a native Titan test executable.
        --no-uv-bootstrap                 Call standalone main directly even if titan.uv installs its bootstrap hook.
        -v, --verbose                     Print safely quoted executed toolchain commands.
        -j <jobs>, --jobs <jobs>          Bound concurrent generated-C object compilations.
        --static                          Prefer static Titan archive providers.
        --no-line-directives              Omit Titan source #line directives from generated C.
        --lua <path>                      Path to a Lua source/build tree (source checkouts only).
        --tree <path>                     Path to the source tree for Titan modules (default '.').
        -l, --link <lib1,lib2>            Add libraries to the final link.
        -X, --extra-object <object...>     Add native payload; library mode carries it into both providers.
        -h, --help                        Show this help message and exit.
```

`--static` prefers self-describing `.a` providers over `.so` providers for
ordinary dependencies; it does not request a system-linker static build and
still permits DSO/source fallback. In library mode, `-X` object/archive
payload enters both the shared and static output; in executable mode it keeps
its established final-link role. `CC` selects the compiler. `-j/--jobs` accepts
a positive integer, overrides `TITAN_JOBS`, and defaults to one; it overlaps
only independent generated-module C object commands. `--pretty-print`
selects the otherwise unused `CLANG_FORMAT` command; Titan appends its fixed
in-place style arguments and does not consult an ambient project configuration.
Without the option even a missing or malformed formatter command is inert.
`--no-line-directives` leaves generated C attributed to its physical `.c`
file and line numbers, which is useful when investigating native diagnostics
such as sanitizer reports. The default keeps Titan source attribution.
`TITAN_NO_LINE_DIRECTIVES=1` provides the same policy for build automation.
Without Titan-attributed frames, logical tracebacks may omit native Titan
functions or render a boundary as `[C]`; this mode is therefore unsuitable for
normal builds or traceback validation.
`TITAN_EXTRA_CPPFLAGS` carries append-only `-I`/`-D` arguments shared by
C-FFI checking and generated compilation;
`TITAN_EXTRA_CFLAGS` is compile-only; and ordered `TITAN_EXTRA_LDFLAGS` is
final-link-only. Shell quoting in these environment strings is parsed once, so
paths containing spaces stay one argument and malformed quoting is rejected.

# Tentative roadmap

This is a *very* preliminary roadmap towards Titan 1.0, where everything is
subject to change, with things more likely to change the further
they are in the roadmap:

## Supported

* control structures from Lua, including generic for..in
* errors and error handling with `raise`/`catch`/`defer` integrated with
Lua error handling, unified Lua/Titan backtraces
* multiple assignment/multiple returns
* scalar types: integers, floats, booleans, strings
* `value` type with gradual typing guarantees
* arrays that can have internal holes with no effect on O(1) length
* maps as ordinary Lua tables, including positional construction and `#` for
exact integer-keyed maps
* variadic functions with `...: T` variadic tail, and flexible multiple
returns also with a`...: T` tail
* first-class functions, including anonymous functions with proper lexical scoping
* explicit invariant [parametric polymorphism](doc/language/generics.md) with
  Interface constraints, local call-site inference, and constraint-directed erasure
* modules: early-bound, can be spread over multiple `.titan` files within a
  single folder, and publish metadata in `.a`/`.so` files for binary import;
  ordinary imports expose only public declarations even when source-resolved,
  while `import "foo.bar.titan"` strips the marker to logical module `foo.bar`,
  requires source with no binary fallback, and grants that one alias visibility
  of module-local declarations ("friend" modules); dotted logical names ending
  in `titan` are reserved by this syntax
* module initializers (a `do ... end` block that executes on module startup)
* FFI with C (C primitive types, pointers, arrays/structs/unions including
stack allocation and FAMs, owned heap allocation, explicit C varargs, C function calls)
* `foreign` functions, for defining C callbacks entirely in Titan
* nominal records: fields map to compact slots, module-local fields, `{ ... }`
constructor syntax, record functions, methods with `:` method declaration and call
syntax, bound methods (`rec:method`) as first-class values
* nominal unions: variants map to dense integer tags, immutable, `case/when`
statement for dispatching on the tag, union functions and methods
* transparent type aliases, including public nominal type re-exports
* asymmetric, tagged (nested) coroutines as building block for async IO
* libuv-backed async tasks, timers, filesystem I/O, DNS,
TCP, verified TLS, streaming HTTP/1.1 clients and servers,
OS utilities and signals, child processes with pipes, graceful process exit
* typed PEG construction/captures and a byte-oriented string library with
Lua-compatible formatting/packing, `tostring`, and compiled regular
expressions
* typed math and random-number helpers, dynamic Lua loading, generic
map/array iteration, explicit garbage-collector control and table/userdata
finalizer ownership, formatted output

## Next

* Language server
* ...Titan 1.0!
