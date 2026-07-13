# Driver and toolchain

This chapter covers everything between "a typed AST exists" and "a `.so`
or executable exists": `titan-compiler/driver.lua` (module lookup, the
import loader, C compilation and linking), the `titanc` command-line
front end, the two small utility modules the whole compiler leans on
(`pretty.lua` and `util.lua`), and the C runtime-support library in
`titan-runtime/`. A reference table of every environment variable,
default path and flag closes the chapter.

## Module names and the search paths

Module lookup deals in dot-separated **module names**, never file paths.
`findmodule` (`driver.lua`) maps a name to a relative path by replacing
dots with slashes and appending an extension, then tries that path under
each `;`-separated entry of a search-path string, returning the
modification time and full filename of the first hit:

```lua
local function findmodule(paths, modname, extension)
    local modf = modname:gsub("[.]", "/") .. extension
    for path in paths:gmatch("[^;]+") do
        local filename = path .. "/" .. modf
        local mtime = lfs.attributes(filename, "modification")
        if mtime then return mtime, filename end
    end
    return nil
end
```

Ordinary application modules use two path strings:

* **`driver.TITAN_SOURCE_PATH`** — where `.titan` sources live. Default
  `"."`; `titanc --tree <root>` overrides it.
* **`driver.TITAN_BIN_PATH`** — where compiled `.so` modules live.
  `TITAN_PATH_0_11` wins over `TITAN_PATH`; with neither set, installed mode
  uses `".;" .. root .. "/lib/titan/0.11"`.

Reserved standard modules use two separate, pinned origins:

* **`driver.TITAN_STDLIB_SOURCE_PATH`** — the standard source tree,
  defaulting to `TITAN_STDLIB_SOURCE_PATH` or `"stdlib"`. It is read
  only for the one root named by an explicit `--stdlib-build`; ordinary
  application imports never compile standard-library sources.
* **`driver.TITAN_STDLIB_PATH`** — the canonical compiled standard
  modules, defaulting to `TITAN_STDLIB_PATH` or
  `root .. "/lib/titan/0.11"`. With no override,
  `driver.TITAN_STDLIB_IMPLICIT_PREFIX` is true and lookup prepends `titan/`
  to the short module name, reaching the canonical `titan/*.so` children.
  An explicit override is instead a direct directory containing `<name>.so`.
  Both compile-time interface recovery and generated run-time standard-module
  loads use this pinned origin rather than ordinary Titan lookup.

So `import foo.bar` looks for `foo/bar.titan` under the source path and
`foo/bar.so` under the bin path. Note that the compile-time path walk
skips empty entries (`[^;]+`) and does **not** implement the `;;`
"insert the default path here" convention; the run-time loader in
`titan.c` does (see [pushpath](#titanc-the-dynamic-loader) below).
Here and below, `root` is the Titan SDK/rocks-tree root, not the owner of the
Lua or LuaRocks installation. The Makefile's `PREFIX` owns Lua and LuaRocks;
`ROCKS_TREE` owns the Titan rock, SDK, and stdlib. The supported developer and
CI installation currently sets `ROCKS_TREE == PREFIX`, but that is a layout
policy rather than an inherent identity. The rock's internal
`TITAN_ROCKS_ROOT` setting identifies `ROCKS_TREE` during source installation
and its post-install standard build. Otherwise, when the compiler is not
running from the Titan source checkout, the driver scans `package.cpath` from
left to right and uses the first literal template ending in
`/lib/lua/5.5/?.so`, stripping that suffix. This discovery relies on the
currently supported equal-root layout. The resulting Titan root selects the
matching `src/lua-5.5.0`, `include`, `lib/liblua.a`, `lib/libtitan.a`,
`lib/libbacktrace.a`, ordinary Titan modules, and standard modules. Bundled
libuv headers are staged under `include`, but its static archive remains a
private source-build input rather than part of the installed SDK. Checkout mode
deliberately retains the repository paths for compiler/runtime development.
This is root discovery, not the previous
policy of adding every `package.cpath` directory to the Titan path. Outside a
checkout, failure to find that exact suffix becomes `driver.INSTALLATION_ERROR`
and stops compiler/toolchain use instead of silently mixing installations.

### Reserved standard modules

`coroutine`, `uv`, `timer`, `fs`, `net`, and `os` are reserved canonical
Titan identities. When application code imports one, `defaultloader`
ignores ordinary source-versus-binary timestamps and loads its interface as
`<root>/lib/titan/0.11/titan/<name>.so` by default. With an explicit override,
it uses `<TITAN_STDLIB_PATH>/<name>.so` directly. It marks that dependency
with the distinct `"standard"` origin; generated code consequently calls
`loadstdlib`, whose search path never includes `.` or ordinary
`TITAN_PATH` entries.

The loader also rejects capture attempts. A same-named source under the
application `--tree` is accepted only when it is the canonical standard
source. A same-named `.so` on the ordinary Titan binary path is accepted only
when it is the canonical standard binary at
`<root>/lib/titan/0.11/titan/<name>.so`; every other match produces a
`reserved standard module ... is shadowed` diagnostic.

Canonical-file checks use device/inode information when available and a
normalized absolute path otherwise. Standard interface recovery remains pinned
to that one canonical qualified image; installation creates no parent-level or
`lib/lua` aliases.

Standard sources are entered only through `--stdlib-build`, which accepts
exactly one reserved root and requires its exact `--lua-name titan.<root>`
alias. That root is parsed from `--tree` (or
`TITAN_STDLIB_SOURCE_PATH`); any reserved modules it imports are still
recovered from already-built canonical binaries. This keeps one standard
implementation in the dependency graph, prevents accidental bare Lua entries
such as `luaopen_os`, and enforces the build order instead of recursively
source-linking duplicate modules.

### Source vs `.so`: the selection logic

The following timestamp policy applies only to non-reserved application
modules:

The policy is: **if source is available and newer, compile it in and
link it statically; if only a `.so` exists, or the `.so` is at least as
new as the source, recover its interface from the compiled module and
load it dynamically at run time.** The guard in `driver.defaultloader`
that chooses the `.so` branch reads:

```lua
if mtime_bin and ((not mtime_src) or mtime_bin >= mtime_src) then
```

So the `.so` branch is taken when a compiled module exists *and* either
no source is present (`not mtime_src`) or the `.so` is at least as new
as the source (`mtime_bin >= mtime_src`); otherwise the loader falls
through to the source path below. The `.so`-only case works end to end:
the branch first `package.loadlib`s the `<mangled>_abi` symbol and
requires it to return the current `driver.TITAN_VER`, then loads
`<mangled>_types`, evaluates the serialized interface, caches it as
`{ type = ..., compiled = true }`, and the dependency is then linked
dynamically at run time. The dynamic-loading machinery this rides on
(the `_abi`/`_types` symbols, `loadlib`/`titan_check_abi`/`loadsym`, the
generated `_init`) is the same one exercised through every other entry
point.

## The loader protocol

The checker does not know how to find modules. `checker.checkimport`
(and, through it, every `import` statement) calls a **loader** callback
with the protocol:

```
loader(modname) -> ok, moduletype_or_error_message, errors
```

On success `ok` is true, the second value is the dependency's
`Type.Module`, and the third is the (possibly empty) list of type errors
found while checking it. On failure `ok` is false and the second value
is a message. See [the type checker](checker.md) for the consumer side.

### `driver.defaultloader(static_deps, options)`

`defaultloader` uses three pieces of process state:

* **`driver.imported`** — a process-global cache, module name → the full
  `{ ast, type, filename, origin, deps }` for source modules, the smaller
  `{ type, compiled = true }` for ordinary `.so`-only modules,
  `{ type, compiled = true, filename, origin = "dynamic-uv" }` for a binary
  whose interface metadata declares a canonical libuv-provider dependency, or
  `{ type, compiled = true, filename, origin = "standard" }` for
  canonical standard binaries. Tests and long-lived tools must reset
  the cache (`driver.imported = {}`), together with `types.registry`.
* **`CIRCULAR_MARK`** — a unique sentinel table stored in
  `driver.imported[modname]` *before* recursively checking that module;
  if a loader call finds the mark, the import cycle is reported as
  `"circular reference to module"`.
* **`driver._uv_provider_path`** — the canonical pathname of the `uv.so`
  loaded globally during interface recovery. `ensure_uv_provider` accepts a
  later request only when device/inode identity (or normalized-path fallback)
  denotes the same file; it rejects a different `options.stdlib_path` because
  the process cannot safely switch native providers. Isolated tests save and
  restore this field with `driver.imported` and `types.registry`; a long-lived
  compiler must not clear it to bypass the guard.

The closure proceeds: cache hit → return the cached type and restore its
source, standard, or `"dynamic-uv"` dependency marker; reserved standard
identity → use the explicit build-root source or pinned canonical binary path
described above; ordinary `.so` selected (see the
[selection logic above](#source-vs-so-the-selection-logic)) →
`package.loadlib` the `<mangled>_abi` symbol. If that first attempt fails in
the open stage with an unresolved `uv_*` symbol, load the pinned canonical
provider globally and retry. Require the current `TITAN_VER`, then load
`<mangled>_types` and call it. Its first result is the serialized interface;
the optional second `"uv-provider"` result marks the dependency `"dynamic-uv"`
regardless of whether the initial open needed the bootstrap fallback. The
marker path also establishes or validates the pinned canonical provider and
records its file identity. A bootstrap retry must return that marker; otherwise
reject the binary and ask for a rebuild with an explicit standard `uv` import.
Evaluate the serialized string with
`load("return " .. serialized, modname, "t", types)`;
ordinary source found → parse, set `CIRCULAR_MARK`, run
`checker.check` recursively with the same loader, cache the result, and
set `static_deps[modname] = true`. The serialized interface is a Lua
expression over `types.lua` constructors (see
[the module protocol](codegen-overview.md)).

Dependency origin has two related views. Each source cache entry's `deps`
stores that translation unit's direct imports: source is `true`, a canonical
compiled standard module is `"standard"`, a direct-libuv binary is
`"dynamic-uv"`, and an ordinary compiled module has no entry. `titanc` passes
that direct map when generating a non-root source dependency. For every
explicit root, `driver.dependency_closure(root)` recursively merges origins
reachable through statically linked source dependencies and passes the full
closure to `coder.generate` as well as to final linking. Thus a non-root source
dependency cannot lose the standard origin and accidentally emit an ordinary
loader call, while a root DSO propagates `"uv-provider"` metadata for libuv used
anywhere in its statically linked source closure. Recomputing the closure also
handles a second root that reuses an already cached source module. The loader's
`static_deps` argument retains that closure-style compatibility view for direct
embedding callers and test helpers.

`coder.generate(modname, ast, deps)` emits a direct `extern` call
to the dependency's `_init` only for `true`, a
`loadstdlib`/`loadsym` sequence for `"standard"`, and the
`loadlibwithuv`/`loadsym` sequence for `"dynamic-uv"`; unmarked binaries use
the ordinary `loadlib`/`loadsym` sequence
([static vs dynamic wiring](codegen-overview.md)). The optional loader
settings select the one `stdlib_build_root` and override its source or
binary standard paths in focused builds and specs.

### `driver.tableloader(modtable, imported, deps)`

The in-memory variant used by the spec suite: module sources come from
the `modtable` table instead of the filesystem (filename is faked as
`"./" .. modname .. ".titan"`), and the caller supplies the `imported`
cache (and optionally the `deps` set) explicitly. After checking, it round-trips the
module type through `types.serialize` and `load`, exactly like the
`.so` path, so the serializer is exercised even in pure-source tests.

## Compiling one module: `driver.compile`

`driver.compile(modname, ast, sourcef, static_deps, verbose, options)`
turns a checked AST into an object file:

1. **Select the runtime SDK.** Installed mode is read-only: it uses headers
   from `<root>/include` and the already-built `<root>/lib/libtitan.a`.
   Checkout developer mode lazily rebuilds and later links the corresponding
   local archive, so edits to any runtime or callback shim can be exercised
   without reinstalling:

   ```sh
   make --no-print-directory titan-runtime/libtitan.a
   ```

   Both modes link `libtitan.a`; the driver never substitutes a direct
   `titan.o` link. The checkout freshness check covers `titan.c`,
   `titan_coro.c`, `titan_uv.c`, and their shim headers.
2. `coder.generate(modname, ast, static_deps, options)` produces one C
   translation unit as a string; `pretty.reindent_c` reformats it. For a
   requested standard root, `options.lua_name` changes only the generated
   `luaopen_*` entry name; the canonical Titan prefix, registry identity,
   `_init`, `_abi`, and `_types` symbols remain based on `modname`.
3. The `.c` file is written **next to the `.titan` source**:
   `sourcef:gsub("[.]titan$", "") .. ".c"` (if `sourcef` is not given it
   defaults to the dots-to-slashes path). Any previous `.c`/`.o` for the
   module is `os.remove`d first.
4. The object is compiled with the parsed `driver.CC`, then
   `TITAN_EXTRA_CPPFLAGS`, Titan's fixed `driver.CFLAGS`, and
   `TITAN_EXTRA_CFLAGS`, in that order:

   ```sh
   cc --std=c99 -O2 -Wall -fPIC -g -fno-optimize-sibling-calls -c foo/bar.c \
      -I <root>/include -I <root>/src/lua-5.5.0 -o foo/bar.o
   ```

   Checkout mode substitutes `titan-runtime`, `lua-5.5.0/src`, and
   `libbacktrace` include paths. `-g` emits the DWARF that carries the `#line` file/line a unified
   trace needs; `-fno-optimize-sibling-calls` keeps tail frames on the
   stack so libbacktrace can unwind them; `-I libbacktrace` finds
   `backtrace.h`.

Toolchain strings are parsed once into dense argument arrays with a
small shell-word grammar supporting whitespace, single/double quotes,
and backslash escapes. The compiler/linker command builder quotes every
resulting word before its final `os.execute`, so spaces and shell
metacharacters remain part of one argument rather than being
reinterpreted. Unterminated quotes, trailing escapes, NUL bytes, an empty
`CC`, and non-dense programmatic argument arrays produce configuration
errors. `-v` prints the same safely quoted toolchain command that is
executed.

`driver.compile_module(modname, mod, static_deps, verbose, options)` is
the thin wrapper `titanc` uses: it skips modules whose cache entry says
`compiled` (the `.so` case), passes root-only generation options through,
and records the produced object filename in `mod.compiled`.

### Shared C preprocessor, compiler, and linker inputs

At driver initialization, `CC` defaults to `cc` and the three
append-only Titan variables are parsed with the argument rules above:

* `TITAN_EXTRA_CPPFLAGS` supplies feature macros and include paths. The
  checker gives the same parsed words and `CC` to every `foreign import`.
  The C parser asks that real compiler, in C99 mode, for its effective
  include search and predefined macros, so a header found through `-I`
  and a branch selected by `-D` agree with the later generated-C build.
  The probe then adds the same current runtime/Lua fixed include directories
  in their real order; in source-checkout mode, applying `titanc --lua`
  refreshes this checker configuration before any import is checked. Installed
  mode keeps its matched SDK fixed.
  These words also precede Titan's fixed compile defaults when compiling
  generated modules, `titan-runtime/titan.c`, and standalone entrypoints.
* `TITAN_EXTRA_CFLAGS` follows Titan's fixed compile defaults on those
  same three compilation paths. It is compilation-only and is not
  copied into a shared-library or executable link command.
* `TITAN_EXTRA_LDFLAGS` is appended, in its parsed order, after Titan's
  objects, archives, built-in `-ldl -lm`, and `-l` options on each final
  shared-library or executable link.

A standalone entrypoint is therefore compiled to its own `.o` with both
extra compile flag sets, then linked in a separate command that contains
only the fixed defaults and extra linker flags. This prevents warning,
language, and code-generation-only options from leaking into the final
link while preserving feature macros for the generated entrypoint.

## Linking a shared library: `driver.compile_library`

`driver.compile_library(modname, libnames, link, verbose, extra_objects)` produces
`<modname-with-slashes>.so` — relative to the working directory, not
next to the source like the `.c`/`.o` — from a list of object files:

```sh
cc --std=c99 -O2 -Wall -fPIC -g -fno-optimize-sibling-calls -shared -o foo/bar.so \
   foo/bar.o dep.o ... extra.o ... <root>/lib/libtitan.a \
   <root>/lib/libbacktrace.a <root>/lib/liblua.a \
   [-ldl] -lm [-lSDL2 ...] [TITAN_EXTRA_LDFLAGS...]
```

The link set is: every object in `libnames` (the module itself plus its
statically-linked Titan dependencies), then any `extra_objects` supplied
by the caller, then `libtitan.a` (installed from the SDK root or built locally
under `titan-runtime/` in checkout mode), `libbacktrace.a` (the separate native
unwinder/symbolizer, **before** `liblua.a`), and the matching `liblua.a`.
Neither mode links an individual `titan.o` in place of the runtime archive.
Generic module and program links do not receive `libuv.a`; only the canonical
`uv.so` build adds bundled or system libuv and its platform support through
its ordered `TITAN_EXTRA_LDFLAGS`. Linux adds `-ldl`, while installed Darwin
builds need no separate libdl. These inputs are followed by `-lm`, then one `-l<lib>`
per entry of the comma-separated `link` string (`titanc -l`), then the
ordered `TITAN_EXTRA_LDFLAGS`. On Darwin
(`driver.IS_DARWIN`, cached from a `uname` shell-out when `driver.lua`
is loaded) the shared flag becomes `-shared -undefined dynamic_lookup` —
the standard macOS idiom for Lua C modules — and, **after the link**,
`driver.compile_library` runs `dsymutil <output>` to produce the
companion `.dSYM` bundle libbacktrace needs to symbolize Mach-O PCs to
`.titan` file/line (the Mach-O linker does not embed DWARF in the
binary). `compile_program` does the same for the executable. On Linux
`dsymutil` is **not** invoked (DWARF is embedded; `dsymutil` may be
absent).

A bundled-mode extension DSO that directly calls `uv_*` is deliberately not an
exception to that generic link set. Its Titan source must import the standard
`uv` module as well as foreign-import `uv.h`, and its link leaves the libuv
references unresolved. Compile-time interface recovery first tries the
ordinary Lua C-module load. When `package.loadlib` reports `where == "open"`
and an unresolved `uv_*` symbol, `ensure_uv_provider` loads canonical `uv.so`
globally and retries so interface recovery can proceed. The module's
`<mangled>_types` optionally returns a second `"uv-provider"` result whenever
its origin map contains standard `uv` or another `"dynamic-uv"` dependency;
that deterministic marker records the dependency origin as `"dynamic-uv"`
even when the initial open already succeeded. Reading the marker calls
`ensure_uv_provider`, establishing or validating the pinned provider and its
process identity. Generated consumers select `loadlibwithuv`, which establishes
that provider before it calls `dlopen` on the extension. Other ordinary dependencies continue
to use `RTLD_NOW | RTLD_LOCAL`. For direct Lua loading, Titan patches Lua's `loadlib.c` so the
C-module searcher requests global visibility when the entry symbol is exactly
`luaopen_titan_uv`; all other Lua C modules retain local loading. This
is portable across the supported Linux and macOS loaders and requires no
self-dlopen helper in `uv.so`. System mode may instead pass the same
pkg-config-selected shared libuv through `TITAN_EXTRA_LDFLAGS`. The private
bundled archive is never a general extension link input. Provider-first mapping
supports imported data, taken function addresses, and native constructors as
well as ordinary function calls.

The unresolved-symbol bootstrap is not itself dependency classification. After
the retry, the interface must return `"uv-provider"`; otherwise the compiler
rejects the malformed binary. This keeps classification independent of whether
another import had already made libuv visible in the compiler process.

## Linking a standalone program: `driver.compile_program`

`driver.compile_program(modname, libnames, link, verbose, extra_objects)` produces an
executable named `modname:gsub("[.]", "/")` (no extension, again
relative to the working directory). It first
writes `<mod>__entrypoint.c` from `entrypoint_template` — a small
srlua-derived C `main` — compiles it with the normal extra compile flags,
and then links its object with the same object set as a library:

```sh
cc [TITAN_EXTRA_CPPFLAGS...] --std=c99 -O2 -Wall -fPIC -g \
   -fno-optimize-sibling-calls [TITAN_EXTRA_CFLAGS...] \
   -c foo/bar__entrypoint.c -I <root>/include -I <root>/src/lua-5.5.0 \
   -o foo/bar__entrypoint.o
cc --std=c99 -O2 -Wall -fPIC -g -fno-optimize-sibling-calls -o foo/bar \
   foo/bar__entrypoint.o foo/bar.o ... extra.o ... \
   <root>/lib/libtitan.a <root>/lib/libbacktrace.a \
   <root>/lib/liblua.a [-ldl] -lm [TITAN_EXTRA_LDFLAGS...]
```

The generated entrypoint, walked through (template substitutions:
`$MODNAME` = the dotted module name, `$LUAOPEN_FN` =
`luaopen_<mangled>`, `$PROGNAME` = the last dotted component, used in
error alerts):

* **`main`** creates a fresh `lua_State`, opens the standard libraries, and
  calls `titan_init_paths`. That parses the inherited `package.cpath` for the
  first `/lib/lua/5.5/?.so` template, initializes the root, ordinary path, and
  dedicated standard path in the registry, and
  ensures `<root>/lib/titan/0.11/?.so` is in `package.cpath`; the patched
  Titan-owned Lua already places it before the `lib/lua` templates. It then
  registers the main module for
  `require` *without* loading it:

  ```c
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, $LUAOPEN_FN);
  lua_setfield(L, -2, "$MODNAME");
  ```

  It then pushes Titan's runtime `errorhandler` and runs `pmain` under
  `lua_pcall(L, 2, 1, -4)` with `argc` and `argv` as arguments; a
  failed pcall formats the still-available original error object and the
  captured raw traceback before exiting with `EXIT_FAILURE`. On success
  the integer returned by the Titan `main` becomes the **process exit status**:
  `ret = lua_tointeger(L, -1); lua_close(L); return ret;`.
* **`pmain`** calls global `require("$MODNAME")`, retrieves and retains
  that module's `main` callable, then builds the `arg` table from `argv`
  with Lua's convention — index 0 is the program name, indices 1..n the
  arguments (`for (i = 0; i < argc; i++) ... lua_rawseti(L, -2, i)`).
  So a Titan `main(args: {string}): integer` sees `args[1]` as the first
  real argument and `#args == argc - 1`. Requiring the main module first
  initializes all imports; an async standard module may install a
  callable under `registry[TITAN_MAIN_BOOTSTRAP_KEY]` during that work.
  If the key is nil, `pmain` calls `main(arg)` directly as before. If a
  hook is present, it calls `hook(main, arg)` instead. Both paths remain
  inside `main`'s single outer protected call, and retrieving `main`
  before consulting the hook prevents an importer from replacing the
  program's entry function.
* **Top-level reporting** uses Titan's own `errorhandler` as the
  `lua_pcall` message handler. On error, that handler records the raw
  unified trace in `registry[TITAN_BACKTRACE_KEY]` and returns the
  original raised value unchanged. `main` then converts that value with
  `lua.c`'s string/number, `__tostring`, or typed-placeholder policy and
  prints a Lua-style report to stderr: `<progname>: <error message>`,
  `stack traceback:`, then the raw trace with a tab prepended to each
  frame line through the Titan `main` frame. The report strips the
  historical synthetic-bootstrap chunk prefix if present and omits
  bootstrap Lua/C frames after `main`. If no Titan trace was captured, it reports
  only the converted error message. Either way the process exits
  non-zero; see [the runtime library](#titanc-the-dynamic-loader).

Mechanically, then, a standalone Titan program is an embedded Lua
interpreter whose only preloaded module is the compiled main module;
the other modules linked into the binary are reached through the
normal module-init protocol.

## The `titanc` command line

```sh
./titanc [--print-ast] [-v|--verbose] [-u|--lua <luasrc>] \
  [-t|--tree <srcroot>] [-l|--link lib1,lib2] \
  [-X|--extra-object obj.o...] [--stdlib-build] \
  [--lua-name <qualified.name>] <module>...
```

`titanc` (a short `argparse` script at the repository root) takes one
or more dot-separated module names. `--tree` overrides
`driver.TITAN_SOURCE_PATH`. In source-checkout mode, `--lua` overrides
`driver.LUA_SOURCE_PATH`; installed mode rejects it so the installed headers,
`liblua.a`, and `libtitan.a` remain a matched SDK. `-v` prints every `cc`
command line, `--print-ast` dumps each module's
AST after checking, `-l` passes extra system libraries to the linker, and
`-X`/`--extra-object` appends one or more already-built object files to
the final link. Runtime and callback-shim objects are not passed this way:
both checkout and installed builds select them from `libtitan.a`. The `uv`
image also links the selected libuv, while higher standard modules dynamically
import the qualified `uv` image instead of embedding more copies.

`--stdlib-build` is the sole source-build entry for a reserved standard
module. It requires exactly one requested module, that name must be in
the reserved set, its `--lua-name` must be exactly `titan.<module>`, and
`--tree` selects its standard source root. Without the flag, requesting a
reserved module as the compilation root is an error; importing it from an
application instead uses its pinned compiled binary. The Makefile drives the
coroutine build as:

```sh
make titan/coroutine.so
```

That rule invokes `titanc --stdlib-build --tree stdlib --lua-name
titan.coroutine coroutine`; the driver selects `titan_coro.o` from
`libtitan.a` itself. The canonical `uv` build then resolves `coroutine` from
the already-built standard binary and applies the same separated Lua entry
name:

```sh
make titan/uv.so                       # pinned bundled libuv
LIBUV_MODE=system make titan/uv.so     # pkg-config-selected system libuv
```

In bundled mode this canonical image is the process's sole complete libuv
provider. An extension DSO that imports standard `uv` may call libuv directly
without linking it: interface recovery classifies the dependency
`"dynamic-uv"`, and a generated consumer's `loadlibwithuv` establishes this
image globally before mapping the extension. A direct Lua caller must
`require "titan.uv"` before requiring that
extension; Titan's Lua opens the exact `luaopen_titan_uv` module globally on
that first load, while every other C module remains local. System-mode
extensions may still link the same shared libuv selected by pkg-config. Linking
the private bundled archive into a second DSO would create another native
instance, even when the archive version matches.

Both rules select `titan_uv.o` from `libtitan.a`. The `uv.so` rule also puts
the chosen libuv linker inputs after that archive, where its extracted shim's
undefined symbols can resolve; no runtime or shim object is passed through
`-X`.

Higher modules then resolve `uv` from that canonical binary. They receive no
shim object or libuv archive themselves, and the Make targets move titanc's
transient root output into the sole qualified image:

```sh
make titan/timer.so titan/fs.so titan/net.so titan/os.so
```

All six rules first assemble `libtitan.a` as an order-only Make prerequisite,
then set the internal `TITAN_RUNTIME_PREBUILT=1` contract for their source-driver
invocation. The driver still validates freshness and the exact archive members,
but does not recursively reconfigure the prepared runtime with module-specific
CPP/link flags. Direct `titanc` use leaves the variable unset and retains the
normal lazy runtime build.

For incremental staleness, the archive itself is order-only while each DSO has
normal prerequisites on the members it can extract: `titan.o` for facades,
`titan.o` plus `titan_coro.o` for coroutine, and `titan.o` plus `titan_uv.o` for
uv. Make therefore assembles and validates the same unified `libtitan.a` before
linking, but changing only the libuv mode does not relink images that cannot
consume `titan_uv.o`.

`--lua-name` accepts one valid dot-qualified Lua module name and exactly
one non-`main` root. It changes only that root's exported Lua loader
symbol (`titan.coroutine` becomes `luaopen_titan_coroutine`, `titan.uv`
becomes `luaopen_titan_uv`, `titan.timer` becomes `luaopen_titan_timer`, and
`titan.fs` becomes `luaopen_titan_fs`, `titan.net` becomes
`luaopen_titan_net`, and `titan.os` becomes `luaopen_titan_os`); canonical
Titan symbols keep their short module prefixes. In particular, the OS facade
does not export `luaopen_os`, so Lua's built-in OS library remains distinct.
It is not propagated to dependencies. The Makefile installs one ordinary file
per standard module under `<root>/lib/titan/0.11/titan`. The Titan-owned Lua's
default `package.cpath` includes `<root>/lib/titan/0.11/?.so`, so qualified Lua
names and Titan's implicit standard prefix reach the same DSO without a copied,
symbolic-link, or hard-link alias. Qualified Lua names still avoid replacing
Lua's bare `coroutine` or `os` libraries.

The source rock deliberately has an unusual two-stage deployment. Its
`build_target = "titan"` disables the separate Make install pass and passes a
`ROCKS_TREE` derived from LuaRocks' `$(SCRIPTS_DIR)/..`. `make titan` builds
`libtitan.a` and `titan.so`; only when `ROCKS_TREE` is nonempty does it also
copy the matching Lua sources, SDK headers, `libtitan.a`, and the separate
`libbacktrace.a` into that tree. Bundled libuv headers are included, but its
archive remains in the source build tree for the later canonical `uv.so` link
and is not exported. `PREFIX` remains the Lua/LuaRocks owner; today's supported installation
passes equal paths for the two variables. The non-Lua headers staged under
`$ROCKS_TREE/include` are `minicoro.h`, `titan.h`, `titan_longjmp.h`,
`titan/ffi.h`, `titan/coro.h`, and `titan/uv.h`. A direct checkout `make titan`
is build-only. After LuaRocks has
installed the compiler script and Lua modules, the source-only `post_install`
hook invokes the standard install target, which forces the build through that
just-installed `titanc` and writes each standard DSO once at its qualified
canonical path. There is no
pre-install hook.

LuaRocks cannot describe the SDK archives/headers or the Titan module
directory as ordinary Lua rock modules. These directly copied files are
therefore outside the rock manifest and are not removed by
`luarocks remove titan`. No binary rocks are provided yet; this source-only
arrangement is an installation bootstrap, not the eventual packaging system
for Titan libraries and applications. A standalone per-project `PREFIX` and
the currently equal sole system-style `ROCKS_TREE` are the supported developer
workflow; the ownership distinction remains explicit for future layouts.

Its flow:

1. **Typecheck everything first.** Each requested module gets a fresh loader
   and goes through `checker.checkimport`; imports are checked recursively,
   each source module records its own direct origin map, and the requested
   root receives a recomputed `driver.dependency_closure` for code generation
   and final linking.
   All errors — load failures and type errors alike — accumulate into one
   list, and if it
   is nonempty `titanc` prints them all to stderr and exits with status
   1 **before any code generation** (behavior introduced by PR #248).
2. **`main` detection.** For each successfully checked module,
   `checker.has_main(ast)` looks for a top-level function named `main`
   with exactly one parameter of checked type `{string}` and exactly
   one return type whose AST node is `Ast.TypeInteger` — i.e. the
   literal annotation `: integer` is required (the `integer` keyword is
   the only syntax that produces that node; omitting the annotation
   means a nil return type). At most one requested module may have a `main`;
   a second produces the error
   `<modname>: multiple main functions found (already declared in <main_module>)`.
3. **Compile.** Every module in `driver.imported` — requested or pulled
   in as a source dependency — is compiled to a `.o` with
   `driver.compile_module`. Failures are collected and reported at the
   end (the final `exit` at the bottom of the script).
4. **Link.** If a `main` module was found, *all* compiled objects are
   linked into a single executable with `driver.compile_program` —
   standalone programs always bundle every module statically. Otherwise
   each requested module is linked into its own `.so` with
   `driver.compile_library`, passing exactly the objects whose
   `static_deps` value is `true` (the module itself and its transitive
   source dependencies), plus any `--extra-object` files. Dependencies
   marked `"standard"` stay dynamically pinned and are not added to the
   link.
   Link failures are collected and make `titanc` exit with status 1, after
   the C compiler has printed its own diagnostic.

## `pretty.lua`: the C style contract and the reindenter

The coder builds C by pasting strings, with no C AST, so it cannot
track indentation; `pretty.reindent_c` re-indents the finished
translation unit instead. The algorithm is deliberately dumb: strip
each line; if the line *starts* with `}` or `)`, dedent first (clamped
at zero, so one mismatch ruins at most one function's indentation); if
the line *ends* with `{` or `(`, indent after it; 4-space units; runs
of blank lines collapse (a blank line survives only at indent 0).

Because the heuristic looks only at line-edge braces and parentheses,
generated C must follow the style contract spelled out in `pretty.lua`'s
header comment, and any code added to `coder.lua` templates must too:

* prefer `/* */` comments over `//`; never place a comment after a `{`
  on the same line; comments must not span lines, contain C code, or
  contain user-controlled text (a stray `{` inside a comment would
  desynchronize the indenter);
* K&R brace placement; multi-line statements must use braces.

The reindenter never changes tokens, only leading whitespace, so a
violation produces ugly-but-correct C; the contract exists to keep
generated code readable for the humans debugging it.

## `util.lua`: templates and helpers

* **`util.render(code, substs, ignore_missing)`** is the compiler's
  entire template engine. It replaces `$VAR` and `${VAR}` (pattern
  `%$({?)([A-Za-z_][A-Za-z_0-9]*)(}?)`) with `substs[VAR]`, and renders
  each substitution value **recursively** with the same table, so
  template fragments can contain further `$VARs`. A missing key is a
  hard abort — `error("Internal compiler error: missing template
  variable " .. k .. "\n" .. code)` — unless `ignore_missing` is
  passed; an unmatched `${` is also an error. One quirk to know when
  writing templates: the match pattern consumes a `}` standing directly
  after `$VAR`, and the replacement function appends it back — so
  `$VAR}` renders as the substitution followed by `}`, and
  brace-adjacent template text comes out intact.
* **`util.make_visitor(functions)`** returns a dispatcher on
  `node._tag` that *asserts* a handler exists — adding an AST tag
  without updating every visitor fails loudly
  ([AST and typedecl](ast-typedecl.md)).
* **`util.get_file_contents(filename)`** / **`set_file_contents`** —
  whole-file read/write returning `false, err` on failure; the driver
  uses them for sources and generated `.c` files.
* **`util.split_string(str, delim)`** — plain-pattern split; used to
  turn the `-l` comma list into linker flags.
* **`util.to_set`**, **`util.curry`**, **`util.any`** — small
  functional helpers (`any` in the coder, `to_set` in the c-parser,
  `curry` only in the specs).

## The runtime support library: `titan-runtime/`

Every installed-mode compiled module and standalone program links
`<root>/lib/libtitan.a`; checkout mode links
`titan-runtime/libtitan.a`. Neither mode links `titan.o` directly. Each archive
contains exactly the dynamic loader/error runtime `titan.o`, coroutine shim
`titan_coro.o`, and libuv callback shim `titan_uv.o`. Static-archive selection
pulls in only referenced objects. Vendored `libbacktrace.a` is a separate link
input. `titanlib.o` is also separate and becomes the `titan.so` Lua module.
The staged non-Lua SDK headers under `<root>/include` are `minicoro.h`,
`titan.h`, `titan_longjmp.h`, and `titan/{ffi,coro,uv}.h`. Checkout developer
mode selects the corresponding local archive and headers so runtime edits can
be tested before reinstalling.

### `titan.h`

* **`TITAN_LIKELY(x)` / `TITAN_UNLIKELY(x)`** — `__builtin_expect`
  wrappers (plain parentheses off GCC/Clang); used on the hot/cold
  sides of generated type checks.
* **Constants** — `TITAN_VER "0.11"`, `TITAN_VER_SUFFIX "_0_11"`,
  `TITAN_PATH_VAR "TITAN_PATH"`, `TITAN_PATH_SEP "/"`, plus the
  dedicated `TITAN_STDLIB_PATH_VAR`, `TITAN_ROOT_DEFAULT "/usr/local"`,
  `TITAN_LUA_CPATH_SUFFIX "/lib/lua/5.5/?.so"`, and UUID
  strings used as Lua-registry keys: `TITAN_PATH_KEY` and
  `TITAN_STDLIB_PATH_KEY` (cached search paths), `TITAN_ROOT_KEY`
  (normalized Titan SDK/rocks-tree root), `TITAN_STDLIB_IMPLICIT_PREFIX_KEY`
  (default-vs-explicit standard lookup mode), `TITAN_LIBS_KEY`
  (dlopen handle table), `TITAN_MAIN_BOOTSTRAP_KEY` (optional
  standalone-main hook),
  `TITAN_BT_STATE_KEY` (registry-owned libbacktrace state cache),
  `TITAN_BACKTRACE_KEY` (last raw error backtrace),
  `TITAN_NAMES_KEY` (native-symbol display-name table), and
  `TITAN_TRACE_PINNED` (re-raise traceback pin), and
  `TITAN_TRACE_APPEND_KEY` (temporary coroutine traceback append slot).
  `TITAN_LUAINTEGER_NBITS` is used by shift code generation.
* **`titan_pushmodule(L, c)`** — pushes a `Udata*` (the module state
  object) onto the Lua stack by writing the slot and bumping
  `L->top.p` directly.
* **`titan_setbvalue(obj, x)`** — sets a boolean `TValue` from a C
  `int`. Exists because Lua 5.5 removed `setbvalue`: booleans carry no
  payload, truth lives in the type tag (`setbtvalue`/`setbfvalue`).
* **`titan_cast_func(t, p)`** — `void*`-to-function-pointer cast for
  `dlsym` results (undefined by ISO C, assumed by POSIX); named to
  avoid colliding with Lua 5.5's own single-argument `cast_func` in
  `llimits.h`.
* **`_integer2str(L, i)` / `_float2str(L, f)`** — inline helpers
  returning a fresh `TString*`. They call `lua_integer2str` and
  `luaO_tostringbuff` — the same conversion routines the Lua core uses
  in `tostring` and string coercion — so a Titan `i as string` or
  concatenation produces *exactly* the string Lua would produce for
  the same number, byte for byte.

It also declares the dynamic-loading and error functions exported by
`titan.c`: `loadlib`, `loadlibwithuv`, `loadstdlib`, `loadsym`,
`titan_check_abi`, and `errorhandler`.

### `titan.c`: the dynamic loader

* **`pushroot(L)` / `titan_init_paths(L)`** normalize and cache the Titan
  SDK/rocks-tree root under `TITAN_ROOT_KEY`. After `luaL_openlibs`, a compiled
  executable scans the inherited
  `package.cpath` for the first entry ending in `/lib/lua/5.5/?.so`, falling
  back to `/usr/local` only when no such entry exists. `titan_init_paths` also
  ensures the exact `<root>/lib/titan/0.11/?.so` template is in
  `package.cpath` and eagerly initializes both Titan loader paths. The patched
  Titan-owned Lua already places that template before the ordinary `lib/lua`
  templates, so Lua and standalone programs resolve the same canonical
  standard DSOs.
* **`pushpath(L)`** resolves the run-time module search path once per
  Lua state and caches it in the registry under `TITAN_PATH_KEY`. The
  order is: `getenv("TITAN_PATH_0_11")` (the versioned variable,
  `TITAN_PATH_VAR TITAN_VER_SUFFIX`), then `getenv("TITAN_PATH")`,
  then `".;<root>/lib/titan/0.11"`, where `<root>` is recovered from
  the first literal `package.cpath` template ending in
  `/lib/lua/5.5/?.so` (or `/usr/local` as the legacy fallback). A `;;` in
  the environment value is replaced by that default path (two
  `luaL_gsub` passes through a `\1` placeholder), so
  `TITAN_PATH="/opt/titan;;"` means "look in `/opt/titan`, then the
  installation defaults". As noted earlier, the *compile-time* search in
  `driver.lua` reads the same variables but does not implement `;;`.
* **`pushstdlibpath(L)`** independently caches
  `getenv("TITAN_STDLIB_PATH")` or `"<root>/lib/titan/0.11"` under
  `TITAN_STDLIB_PATH_KEY`, and records under
  `TITAN_STDLIB_IMPLICIT_PREFIX_KEY` whether the default was used. Default
  standard loads insert `titan/` between that directory and `<name>.so`;
  an explicit override is used directly. It never adds `.`, arbitrary
  `package.cpath`, or ordinary Titan-path entries, so a generated standard
  dependency stays pinned at run time as well as compile time.
* **The libs registry** — a table under `TITAN_LIBS_KEY` maps `.so`
  file names to light-userdata `dlopen` handles. Standard handles use a
  separate `stdlib:<file>` key namespace. The cache avoids repeated
  `dlopen` calls within a state. Titan deliberately does not call `dlclose` at
  state shutdown: generated modules form a manually wired dependency graph for
  which neither insertion nor reverse-insertion order is universally safe, and
  finalizable Lua objects can still retain native entry pointers. The operating
  system reclaims the mapped images when the process exits.
* **`loadlib(L, file)`** — returns the cached handle for `file` if
  present; otherwise walks the path `;`-entry by entry, builds
  `dir "/" file` (the coder passes `file` as the dots-to-slashes
  module path plus `.so`), and tries
  `dlopen(filename, RTLD_NOW | RTLD_LOCAL)`. This is the path for ordinary
  unmarked binary dependencies. The first success is
  cached and returned; total failure raises a Lua error with
  `dlerror()` (which describes only the last attempt).
* **`loadstdlib(L, file)`** — performs the same cached `dlopen` operation
  through `pushstdlibpath` and the standard handle namespace. When the
  implicit-default flag is set it tries `dir "/titan/" file`; with an explicit
  override it tries `dir "/" file`. Generated `_init` code selects it for
  dependencies whose origin marker is `"standard"`. The canonical `uv.so` is
  opened with `RTLD_NOW | RTLD_GLOBAL`, making its complete libuv implementation
  available to later images. Other
  standard modules use `RTLD_NOW | RTLD_LOCAL`.
* **`loadlibwithuv(L, file)`** — selected only for a `"dynamic-uv"`
  dependency. It calls `loadstdlib(L, "uv.so")` first, then delegates to
  `loadlib(L, file)`. The provider is therefore global before the extension's
  eager `dlopen`, satisfying function calls, data/function-address relocations,
  and constructors without relying on lazy binding.
* **Titan-owned Lua's C loader** — the patched `loadlib.c` C-module searcher
  requests global visibility on a first load when the entry symbol equals
  `luaopen_titan_uv`. Normal `require "titan.uv"` therefore establishes the
  same global provider on Linux and macOS before Lua loads a direct extension;
  every other C-module entry retains Lua's ordinary local visibility. The
  provider DSO contains no self-dlopen or promotion shim.
* **`loadsym(L, lib, sym)`** — `dlsym` with `luaL_error(L, dlerror())`
  on `NULL`. The generated `_init` of a module with dynamic
  dependencies uses `loadlib` + `loadsym` + `titan_cast_func` to wire
  cross-module function pointers
  ([static vs dynamic wiring](codegen-overview.md)).
* **`errorhandler(L)`** — the message handler that every generated Lua
  entry wrapper ensures is active in `L->errfunc` around the native call
  ([Lua interop internals](lua-interop-internals.md)). It builds **one
  unified, intermingled trace** (innermost→outer): the CallInfo chain
  supplies every Lua frame, and libbacktrace (`backtrace_full`,
  DWARF/`#line`-symbolized to `.titan` file/line) supplies the Titan
  native frames, spliced at the entry-wrapper boundaries (identified by
  the `titanentry` symbol substring). Interpreter, standard-library,
  `titan-runtime` and unsymbolized native frames are filtered out. The
  result — raw merged frame lines only, with no error message, no `stack
  traceback:` header, and no presentation tabs — is stored in the
  registry under `TITAN_BACKTRACE_KEY` (subject to the
  `TITAN_TRACE_PINNED` pin discipline). It then restores the stack top
  and returns 1 — so the **original error value** reaches `pcall`
  unchanged, and the enriched backtrace is fetched separately. (Its
  push-everything-first ordering exists because a Lua 5.5 `luaL_Buffer`
  must stay at the stack top while in use.) Without libbacktrace
  (`TITAN_NO_LIBBACKTRACE`) it falls back to raw Lua traceback lines plus
  raw `execinfo` C frames.

### `titanlib.c`: the `titan` Lua module

This companion is built separately from `libtitan.a`: Make compiles
`titanlib.c` into `titanlib.o` and links only that object into the Lua module
`titan.so`, which the rockspec installs as `titan`. It is *not* linked into
generated modules. Its user-facing operation is `backtrace`; it also exposes
the internal testing helpers `pin` and `clear` used to exercise the traceback
pin discipline:

```lua
-- Lua
local titan = require "titan"
local ok, err = pcall(mod.f)        -- a Titan function that raises
if not ok then
    print(titan.backtrace())        -- raw unified Lua+Titan frame lines
end
```

`titan.backtrace()` rawgets `TITAN_BACKTRACE_KEY` from the registry and
returns the string stored by the last `errorhandler` run, or `nil` if
no Titan error has occurred in this state. It duplicates the key string
literal rather than including `titan.h`, so it builds against a stock
Lua. See [error handling](../language/error-handling.md) for the
user-facing story.

## Reference: environment variables, paths, and flags

| Name | Where read | Default / value | Meaning |
| --- | --- | --- | --- |
| `PREFIX` | Makefile / rockspec build input | `/usr/local` for direct Make; an absolute per-project path in the supported workflow | Owns the patched Lua installation plus the LuaRocks executable and configuration. |
| `ROCKS_TREE` | Makefile / rockspec build input | empty for a direct build; LuaRocks' `$(SCRIPTS_DIR)/..` for a source install | Owns the installed Titan rock, SDK, and stdlib. The supported workflow currently sets it equal to `PREFIX`, but they are separate ownership concepts. |
| `TITAN_PATH_0_11` | `driver.lua` (compile time), `titan.c` `pushpath` (run time) | unset | Versioned module search path; wins over `TITAN_PATH`. |
| `TITAN_PATH` | same | unset | Module search path; `;;` expands to the default at run time only. |
| `TITAN_STDLIB_SOURCE_PATH` | `driver.lua` | `"stdlib"` | Pinned standard source root used only by explicit standard-library builds; `--tree` overrides it for that build. |
| `TITAN_STDLIB_PATH` | `driver.lua` (compile time), `titan.c` `pushstdlibpath` (run time) | unset | Direct-directory override containing short standard filenames. Without it, lookup uses `<root>/lib/titan/0.11` plus an implicit `titan/` prefix. |
| `TITAN_ROCKS_ROOT` | `driver.lua`, source-rock post-install Make invocation | unset | Internal normalized `ROCKS_TREE` override used while the just-deployed compiler builds the stdlib; not a public deployment setting. |
| `driver.TITAN_ROOT` | `driver.lua` | internal override, otherwise first `package.cpath` entry ending `/lib/lua/5.5/?.so` | Normalized Titan SDK/rocks-tree root. Package-path discovery relies on the currently supported `ROCKS_TREE == PREFIX` layout. |
| `driver._uv_provider_path` | `driver.lua` compiled-interface recovery | unset until a direct-libuv binary or canonical `uv` interface needs the provider | Remembers the canonical provider's file identity and rejects a different provider path in the same compiler process. Tests save/restore it with `driver.imported` and `types.registry`. |
| `driver.SOURCE_CHECKOUT` / `driver.INSTALLED` | `driver.lua` | detected from checkout files unless the internal root is set | Select the writable checkout SDK/archive inputs or read-only installed SDK inputs. |
| `driver.INSTALL_PATHS` | `driver.installed_paths` | paths below `driver.TITAN_ROOT` | Holds `lua_source`, `include`, `libtitan`, `libbacktrace`, `liblua`, `titan_bin`, `titan_stdlib`, and `lua_cpath`; bundled `libuv.a` is deliberately not an installed SDK path. |
| `driver.TITAN_BIN_PATH` | `driver.lua` | `TITAN_PATH_0_11`, `TITAN_PATH`, or `.;<root>/lib/titan/0.11` in installed mode | Where compiled `.so` modules are searched at compile time; checkout mode retains the legacy `/usr/local` fallback. |
| `driver.TITAN_SOURCE_PATH` | `driver.lua` | `"."` (overridden by `titanc --tree`) | Where `.titan` sources are searched. |
| `driver.TITAN_STDLIB_SOURCE_PATH` | `driver.lua` | `TITAN_STDLIB_SOURCE_PATH` or `"stdlib"` | Canonical source location for the one `--stdlib-build` root. |
| `driver.TITAN_STDLIB_PATH` / `TITAN_STDLIB_IMPLICIT_PREFIX` | `driver.lua` | explicit direct path/false, otherwise `<root>/lib/titan/0.11`/true | Select the base and relative name (`<name>.so` or `titan/<name>.so`) used for standard interface recovery. |
| `driver.LUA_SOURCE_PATH` | `driver.lua` | `<root>/src/lua-5.5.0` installed; `lua-5.5.0/src` in checkout mode; checkout-only override by `titanc --lua` | Lua internal source/header tree used at compile time. Installed mode rejects the override because `INSTALL_PATHS` supplies its matching `liblua.a` and `libtitan.a`. |
| `driver.INCLUDE_PATH` | `driver.lua` | `<root>/include` in installed mode | Titan SDK and bundled-libuv headers used by generated C and foreign imports; the non-Lua set is `minicoro.h`, `titan.h`, `titan_longjmp.h`, and `titan/{ffi,coro,uv}.h`. |
| `driver.TITAN_RUNTIME_PATH` / `driver.LIBBACKTRACE_PATH` | `driver.lua` | `titan-runtime/` / `libbacktrace` | Checkout-only runtime source/archive/header and separate libbacktrace locations. |
| `CC` / `driver.CC` | environment / `driver.lua` | `"cc"` | C compiler command, parsed as shell words and shared with foreign-import probing. |
| `driver.CFLAGS` | `driver.lua` | `"--std=c99 -O2 -Wall -fPIC -g -fno-optimize-sibling-calls"` | Flags for every compile and link step. |
| `TITAN_EXTRA_CPPFLAGS` / `driver.EXTRA_CPPFLAGS` | environment / `driver.lua` | empty | Parsed `-I`/`-D` and other preprocessing inputs; used by foreign-import compiler probes and prepended to every Titan/runtime/entrypoint compilation. |
| `TITAN_EXTRA_CFLAGS` / `driver.EXTRA_CFLAGS` | environment / `driver.lua` | empty | Parsed compilation-only flags, after fixed defaults; never used by final links. |
| `TITAN_EXTRA_LDFLAGS` / `driver.EXTRA_LDFLAGS` | environment / `driver.lua` | empty | Parsed ordered linker inputs appended to final module and program links. |
| shared-library flags | `shared_flag()` | `-shared`; on Darwin `-shared -undefined dynamic_lookup` | Platform from `driver.UNAME` (output of `uname`). |
| installed link set | `driver.installed_link_inputs` / `append_runtime_libraries` | installed `libtitan.a` + separate `libbacktrace.a` + `liblua.a` + platform libraries | Used by both modules and programs; Linux adds `-ldl`, and all platforms add `-lm`. The canonical `uv.so` build alone receives the private bundled archive; direct bundled-mode extension DSOs leave `uv_*` unresolved, while system mode may use explicit pkg-config link flags. |
| checkout link set | `driver.source_link_inputs` / `append_runtime_libraries` | local `libtitan.a` + separate local `libbacktrace.a` + local `liblua.a` + `-ldl -lm` | Preserves the writable source-development path while using the same archive contract; it never links `titan.o` directly. |
| `TITAN_ROOT_DEFAULT` / `TITAN_LUA_CPATH_SUFFIX` | `titan.h`/`titan.c` | `/usr/local` / `/lib/lua/5.5/?.so` | Legacy run-time root fallback and exact template suffix used for root discovery. |
| `titan_init_paths` | generated standalone entrypoint / `titan.c` | root parsed from inherited `package.cpath` | Caches the root and Titan paths and ensures `<root>/lib/titan/0.11/?.so` is in `package.cpath`; patched Titan-owned Lua has it first by default. |
| `--stdlib-build` | `titanc` | off | Permit exactly one reserved standard source root to be compiled explicitly; requires its exact `--lua-name titan.<root>`. |
| `--lua-name` | `titanc`/`coder.lua` | canonical Titan module name for ordinary roots; required `titan.<root>` for standard builds | Override only the requested non-main root's `luaopen_*` symbol with a qualified Lua require name. |
| registry keys | `titan.h` | `TITAN_ROOT_KEY`, `TITAN_PATH_KEY`, `TITAN_STDLIB_PATH_KEY`, `TITAN_STDLIB_IMPLICIT_PREFIX_KEY`, `TITAN_LIBS_KEY`, `TITAN_MAIN_BOOTSTRAP_KEY`, `TITAN_BT_STATE_KEY`, `TITAN_BACKTRACE_KEY`, `TITAN_NAMES_KEY`, `TITAN_TRACE_PINNED`, `TITAN_TRACE_APPEND_KEY` (UUID strings) | Per-state caches and hooks: Titan SDK/rocks-tree root, ordinary and standard search paths, standard prefix mode, dlopen handles, optional standalone bootstrap, registry-owned libbacktrace state, last raw backtrace, native-frame display names, re-raise traceback pin, and coroutine traceback append handoff. |
| generated ABI symbol | `coder.lua` | `<mangled>_abi` returning `TITAN_VER` | Checked before `.so` type rehydration and before run-time dynamic-import `dlsym`; markerless modules are treated as incompatible. |

The pieces upstream of the driver are described in
[the type checker](checker.md) (which calls the loader) and the
[code generator overview](codegen-overview.md) (which produces what the
driver compiles); the contents of the runtime archive's callers — the
generated `_init`, standalone path initialization, and Lua entry wrappers that
ensure `errorhandler` is active —
are in [Lua interop internals](lua-interop-internals.md).
