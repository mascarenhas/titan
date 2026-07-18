# Driver and toolchain

This chapter covers everything from resolving source/compiled modules through
producing a `.so`/`.a` pair or executable: `titan-compiler/driver.lua` (module lookup, the
import loader, C compilation and linking), the `titanc` command-line
front end, the two small utility modules the whole compiler leans on
(`pretty.lua` and `util.lua`), and the C runtime-support library in
`titan-runtime/`. A reference table of every environment variable,
default path and flag closes the chapter.

## Module names and the search paths

Module lookup deals in dot-separated **module names**, never file paths.
Binary lookup maps a logical name to every shallow-to-exact provider
candidate. For `a.b.c`, those are `a.so`, `a/b.so`, and `a/b/c.so`, plus the
corresponding `.a` names. It performs one complete format pass at a time
(`.so` then `.a`, swapped by `--static`), walking search roots from left to
right and candidates from shallowest to exact within a pass. Once an earlier
root contains a relative candidate, that pathname is occupied for its format
and shadows the same relative pathname in later roots even when its metadata
does not claim the requested module. Missing files remain available in later
roots. See [Multi-module shared
libraries](multi-module-libraries.md#compiled-module-candidate-search) for
the DSO ABI/types claim state machine and [Static compiled
modules](static-compiled-modules.md) for the archive reader and shared
invocation-wide resolver state.

Source lookup has a separate tagged resolver because a logical module may be
flat or a [folder module](folder-modules.md). For logical name `M`, slash path
`P`, and final component `B`, each source root is tested in this order:

1. folder main `P/B.titan`; if it is a regular file, enumerate its directory,
   collect immediate regular `.titan` siblings, and return the main followed
   by contributors in `util.bytewise_less` basename order;
2. flat source `P.titan`;
3. before accepting a nested flat source, reject it as `blocked` when that
   exact file is a constituent of an immediate parent folder module.

The resolver distinguishes `flat`, `folder`, and `blocked` results; `nil` is
only a clean miss. An error enumerating a selected folder is a separate hard
failure. A selected or blocked result never falls through to another source
form or later source root. Testing the requested folder first still permits a
genuine deeper folder module even when its same-named sibling file contributes
to the parent. A parent marker without the requested flat constituent does not
reserve the missing child name.

All modules, including the standard library, use the same two path strings:

* **`driver.TITAN_SOURCE_PATH`** — where `.titan` sources live. Default
  `"."`; `titanc --tree <root>` overrides it.
* **`driver.TITAN_BIN_PATH`** — where compiled provider `.so` and `.a` files
  live.
  `TITAN_PATH_0_16` wins over `TITAN_PATH`; with neither set, installed mode
  uses `".;" .. root .. "/lib/titan/0.16"`.

So `import foo.bar` probes `foo.so` and then exact `foo/bar.so` within each
binary root and, if source is needed, `foo/bar/bar.titan` before
`foo/bar.titan` in each source root. Note that the compile-time path walk
expands `;;` with the same "insert the ordinary default here" convention as
the run-time loader in `titan.c`, then skips empty separators.
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
`lib/libbacktrace.a`, and every compiled Titan module. Bundled libuv headers
are staged under `include`, but its static archive remains a private
source-build input rather than part of the installed SDK. Checkout mode
deliberately retains the repository paths for compiler/runtime development.
This is root discovery, not the previous policy of adding every
`package.cpath` directory to the Titan path. Outside a checkout, failure to
find that exact suffix becomes `driver.INSTALLATION_ERROR` and stops
compiler/toolchain use instead of silently mixing installations.

The standard library consists of seven ordinary qualified logical modules:
`titan.coroutine`, `titan.uv`, `titan.async`, `titan.timer`, `titan.fs`,
`titan.net`, and `titan.os`. Most checkout sources are
`titan/<name>.titan`; `titan.uv` is the folder ensemble rooted at
`titan/uv/uv.titan`. One `titanc` invocation links their independent objects
and `titanlib.o` into the physical checkout provider `titan.so`. Installation
publishes that image at `<root>/lib/titan/0.16/titan.so` and publishes seven
generated logical-module shims below `<root>/share/lua/5.5/titan/`. Titan
imports discover each module through the shallow provider's ordinary metadata;
Lua requires discover the same provider through the generated shim.

`titan.uv` is the private Runtime and native-provider layer. `titan.async`
imports it and exposes the public scheduler facade, including transparent
aliases of uv-owned record types. The timer/fs/net/os modules also import uv
directly for their low-level plumbing, so all five consumers share one Runtime
and one canonical libuv provider image.

For source convenience, the parser desugars the seven short standard-library
imports before module resolution: `import "async"`, for example, places
`titan.async` in the import AST exactly as `import "titan.async"` would. The same
mapping applies to `coroutine`, `uv`, `timer`, `fs`, `net`, and `os`; every other
name is left unchanged. The driver, checker, code generator, and runtime thus
see only the qualified module name. Each qualified name naturally produces its
matching native symbols and Lua entry point (`titan_async_*` and
`luaopen_titan_async`, for example), so no separate Lua alias is required and
Lua's bare `coroutine` and `os` libraries remain unrelated.

### Source vs `.so`: the selection logic

Dependency resolution is unconditionally **binary first**: the driver probes
the logical module's shallow-to-exact candidates on `TITAN_BIN_PATH`, recovers
the first validating interface, and does not inspect source timestamps. Only
when every candidate is absent or every existing ancestor is a clean metadata
nonclaim does it parse the first flat or folder source match. Source roots are
walked left to right; the folder-before-flat rule applies within each root,
rather than comparing one representation across all roots. This applies
equally to standard-library and application dependencies. In particular, a
stray `./titan/uv/uv.titan` folder does not capture `import "uv"` while an
installed combined `titan.so` claims `titan.uv` on the binary path.

Source privacy is evaluated only after the complete binary-candidate miss. A requested
nested flat file that is an immediate constituent of its parent folder module
returns `blocked` and stops source-root traversal; it cannot be exposed by a
later root. Any claiming child provider still wins before this check, and a genuine
deeper child folder wins before the constituent flat candidate.

An explicitly requested `titanc` root is the one exception because naming a
root is a request to build it. `titanc` passes the complete requested-root set
as `options.source_roots`; each such module tries source first, even if a
binary for it was cached by an earlier import in the same compiler process.
If its source is absent, compilation fails rather than treating an existing
binary as an empty build root. Imports reached from that root remain binary
first. This is why one standard-library invocation can force all seven roots
through source even when a bootstrap or prior combined `titan.so` is visible.
Their internal imports resolve to the already selected source cache entries
and are linked statically into the replacement image.

The compiled branch uses the internal lazy/local `titan._loadlib` helper to
probe both `<mangled>_abi` and `<mangled>_types` in each existing candidate.
After a valid pair returns the current `driver.TITAN_VER` and a canonical
serialized interface, the driver caches the logical module separately and
sets its transient `Type.Module.file` to the selected relative provider.
Generated code loads that exact provider dynamically at run time. The
dynamic-loading machinery (`loadlib`/`titan_check_abi`/`loadsym` and the
generated `_init`) is unchanged and applies equally to standard-library and
application modules.

In ABI 0.13, the serialized interface carries formal `paramnames` on Titan
module-function, record-method, and record-static declaration descriptors for
named-call checking. Structural function types and the native call ABI are
unchanged. Because the loader validates `_abi` before evaluating `_types`, a
0.12 module is rejected cleanly instead of invoking the new descriptor
constructors with the old arities.

Flexible result shapes add `flexrettype` to callable serialization and a
trailing native output-descriptor/budget pair. Those changes require the
coordinated ABI 0.14 transition. The constants, paths, fixtures, and installed
images move together; the loader rejects—not reinterprets—a 0.13 compiled
interface.

ABI 0.15 keeps those descriptor and native-call shapes. It advances the
compatibility marker because `titan.uv` now declares exported members in
semantic folder contributors, changing their ordered module slots. The new
versioned path prevents a 0.14 importer from applying the monolithic order to
the reordered provider.

ABI 0.16 again keeps the serialized descriptors and native-call shapes. It
changes the physical import contract: generated imports remember a selected
prefix container rather than hard-coding only the exact logical DSO, and the
standard installation replaces seven child DSOs with one `titan.so` plus
generated shims. A 0.15 runtime cannot discover that shallow image, so marker,
path variable, and installed namespace advance together.

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
  `{ ast, type, filename, program_output, deps }` for source modules, the smaller
  `{ type, compiled = true, filename }` for binary modules. Tests and long-lived
  tools must reset the cache (`driver.imported = {}`), together with
  `types.registry`.
* **`CIRCULAR_MARK`** — a unique sentinel table stored in
  `driver.imported[modname]` *before* recursively checking that module;
  if a loader call finds the mark, the import cycle is reported as
  `"circular reference to module"`.
The closure proceeds in this order:

1. A cache hit returns the cached type and records `true` when the dependency
   comes from source; compiled dependencies carry no origin marker.
2. A module in `options.source_roots` first looks for source. If a binary-only
   cache entry already exists for that explicit root, the entry is discarded
   before this check so the requested source build cannot be hidden by cache
   history.
3. An explicit root with no source fails. Every other lookup runs the
   root-major shallow-to-exact provider search on `TITAN_BIN_PATH` before
   looking for source on `TITAN_SOURCE_PATH`.
4. A source hit is a tagged flat/folder descriptor. Every listed file is read
   and parsed independently with its real filename. The main initializer is
   saved, contributor roots are appended in descriptor order, contributor
   initializers are rejected, and the saved initializer is appended once.
5. The logical module is marked with `CIRCULAR_MARK`; the resulting dense AST
   is recursively checked
   exactly once under the logical module name, cached, and recorded as a
   static dependency. The canonical main becomes `filename`; executable
   naming from the descriptor becomes `program_output`.

The folder descriptor is temporary loader input, not AST metadata. One cache
entry, circularity sentinel, module type, direct-dependency set, and
initializer remain keyed by `modname`. Node locations are the only retained
per-contributor information. The checker receives the main filename as its
source directory; because contributors are immediate siblings, quoted foreign
headers from any file resolve under that same directory.

For a binary hit, `find_compiled_interface` uses the internal
`titan._loadlib(path, symbol)` helper to map each existing candidate with
`RTLD_LAZY | RTLD_LOCAL`, probe the requested metadata pair, and validate a
claim. The helper is the generic lazy analogue of `package.loadlib`; it exists
because stock Lua maps C modules with `RTLD_NOW`, which would prevent the
compiler from inspecting a DSO containing ordinary unresolved foreign
function calls. The driver evaluates the serialized interface with
`load("return " .. serialized, modname, "t", types)`, validates that it is a
canonical `Type.Module` for `modname`, then sets its unserialized `file` field
to the selected relative provider. The absolute candidate is retained in the
logical cache entry. See [the complete claim rules](multi-module-libraries.md#claim-and-terminal-error-states).

Dependency origin has two related views. Each source cache entry's `deps`
stores that logical translation unit's direct source imports as `true`, no
matter which contributor declared the import; compiled
imports have no entry. `titanc` passes that direct map when
generating a non-root source dependency. For every explicit root,
`driver.dependency_closure(root)` recursively merges origins reachable through
statically linked source dependencies and passes the full closure to
`coder.generate` as well as to final linking. Recomputing the closure also handles a second root that reuses
an already cached source module. The loader's `static_deps` argument retains
that closure-style compatibility view for direct embedding callers and test
helpers.

`coder.generate(modname, ast, deps)` emits a direct `extern` call
to the dependency's `_init` only for `true`; every compiled module uses the
same `loadlib`/`loadsym` sequence with the selected `Type.Module.file`.
Generated `_types` functions return only the serialized module interface and
never persist that physical path ([static vs dynamic
wiring](codegen-overview.md)). The only current filesystem-loader option is
the generic `source_roots` set. Folder layout does not add an option or a
different loader protocol.

### `driver.tableloader(modtable, imported, deps)`

The in-memory variant used by the spec suite: module sources come from
the `modtable` table instead of the filesystem (filename is faked as
`"./" .. modname .. ".titan"`), and the caller supplies the `imported`
cache (and optionally the `deps` set) explicitly. After checking, it round-trips the
module type through `types.serialize` and `load`, exactly like the
`.so` path, so the serializer is exercised even in pure-source tests.
That round trip already exposes constructor-schema drift such as
`flexrettype`; it does not by itself authorize loading that schema under the
current compiled-module ABI marker.
It deliberately remains a flat one-string-per-module loader. Source folders,
privacy blocks, and contributor enumeration belong only to
`defaultloader`; neither tests nor embeddings acquire a synthetic source-unit
AST shape.

## Compiling one module: `driver.compile`

`driver.compile(modname, ast, sourcef, static_deps, verbose)`
turns one checked logical-module AST into an object file. For a folder module,
`sourcef` is its canonical main and `ast` is the combined dense list; there is
still one call:

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
2. `coder.generate(modname, ast, static_deps)` produces one C translation unit
   as a string; `pretty.reindent_c` reformats it. The qualified `modname`
   controls the native prefix, registry identity, `_init`, `_abi`, `_types`,
   and `luaopen_*` symbols consistently.
3. The `.c` file is written **next to the flat source or folder main**:
   `sourcef:gsub("[.]titan$", "") .. ".c"` (if `sourcef` is not given it
   defaults to the dots-to-slashes path). Any previous `.c`/`.o` for the
   module is `os.remove`d first. Contributors never receive generated C or
   object files.
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

`driver.compile_module(modname, mod, static_deps, verbose)` is the thin wrapper
`titanc` uses: it skips modules whose cache entry says `compiled` (the binary
case) and records the produced object filename in `mod.compiled`.

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

## Linking a provider pair

Library mode uses `driver.compile_library_output` for the staged DSO and the
archive helpers described in [Static compiled
modules](static-compiled-modules.md#native-composition) for the matching
self-describing `.a`. Both artifacts contain the same logical source/archive
membership; the archive additionally preserves metadata-free native `-X`
payload byte-for-byte.

### `driver.compile_library_output`

`driver.compile_library_output(soname, objects, link, verbose,
extra_objects)` links an explicitly named output from the complete logical
source-module object union:

```sh
cc --std=c99 -O2 -Wall -fPIC -g -fno-optimize-sibling-calls -shared \
   -o app.so app_model.o app_view.o dep.o ... extra.o ... \
   <root>/lib/libtitan.a <root>/lib/libbacktrace.a <root>/lib/liblua.a \
   [-ldl] -lm [-lSDL2 ...] [TITAN_EXTRA_LDFLAGS...]
```

The objects are sorted by logical module name and deduplicated before this
call. They are followed by caller-supplied extra objects, `libtitan.a`, the
separate `libbacktrace.a` (**before** `liblua.a`), and matching `liblua.a`.
Neither installed nor checkout mode links an individual `titan.o`. Linux adds
`-ldl`; all platforms add `-lm`; `-l` inputs and ordered
`TITAN_EXTRA_LDFLAGS` come last. `compile_library(modname, ...)` remains a thin
exact-output wrapper for programmatic and test-only callers.

`titanc` derives the public provider from the requested roots, links first to
a sibling staging directory, validates every linked logical module's metadata,
`_init`, and Lua entry, then calls `publish_library`. On Darwin the shared flag
is `-shared -undefined dynamic_lookup`; `dsymutil` must succeed before the
image is valid. The staging DSO keeps the public basename so the Mach-O dSYM's
inner name matches the loaded file. Publication moves the dSYM companion and
uses the DSO rename as the commit point. Linux embeds DWARF and removes any
stale public dSYM.

Generated shims are written only after the image is published. They resolve
the provider with `package.searchpath`, obtain the exact `luaopen_*` entry via
`titan._loadlibglobal`, and call it. See [Validated publication and generated
shims](multi-module-libraries.md#validated-publication-and-generated-shims).

A bundled-mode extension DSO that directly calls `uv_*` remains an ordinary
case. Its source imports `titan.uv` and foreign-imports `uv.h`, leaving ordinary
libuv calls unresolved. Compiler inspection maps it lazy/local; generated
runtime import maps its selected provider lazy/global, and the initializer
loads the combined standard `titan.so` before those calls bind. Native
constructors, imported data, and taken function addresses still need eager
resolution and cannot rely on initializer ordering. System mode may instead
link the same pkg-config-selected shared libuv. The private bundled archive is
force-loaded only into the combined standard image, never into a general
extension.

## Linking a standalone program: `driver.compile_program`

`driver.compile_program(modname, libnames, link, verbose, extra_objects,
program_output)` produces an executable at the optional `program_output`
path, relative to the working directory. Omitting it preserves the original
`modname:gsub("[.]", "/")` default for programmatic callers and
`tableloader`. Filesystem source descriptors cache:

| Form for `foo.bar` | `program_output` |
| --- | --- |
| flat | `foo/bar` |
| folder | `foo/bar__main` |

It first writes `<mod>__entrypoint.c` from `entrypoint_template` — a small
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

The command above shows the flat default. A folder program changes only the
link output after `-o` to `foo/bar__main`. The entrypoint C/object path,
`$MODNAME`, `$LUAOPEN_FN`, `$PROGNAME`, registry identity, and compiled module
symbols remain derived from logical `foo.bar`. The suffix avoids colliding
with the source directory and works when `--tree` names an external tree.
Library and program compilation create the logical output parent when a
dotted external source tree has not already created it in the current working
directory.

The generated entrypoint, walked through (template substitutions:
`$MODNAME` = the dotted module name, `$LUAOPEN_FN` =
`luaopen_<mangled>`, `$PROGNAME` = the last dotted component, used in
error alerts):

* **`main`** creates a fresh `lua_State`, opens the standard libraries, and
  calls `titan_init_paths`. That parses the inherited `package.cpath` for the
  first `/lib/lua/5.5/?.so` template, initializes the root and Titan module
  path in the registry, and
  ensures `<root>/lib/titan/0.16/?.so` is in `package.cpath`; the configured
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
* **`pmain`** first publishes the original `argc` integer and `argv` pointer
  under `TITAN_MAIN_ARGC_KEY` and `TITAN_MAIN_ARGV_KEY`, then calls global
  `require("$MODNAME")` and retrieves and retains that module's `main`
  callable. A transitive `titan.uv` initialization can therefore call
  `uv_setup_args` in the canonical provider and replace the private `argv`
  slot with the pointer returned by libuv. After `require`, `pmain` rereads
  that pointer and builds the `arg` table with Lua's convention — index 0 is
  the program name, indices 1..n the arguments
  (`for (i = 0; i < argc; i++) ... lua_rawseti(L, -2, i)`).
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
  [-X|--extra-object obj.o...] <module>...
```

`titanc` (a short `argparse` script at the repository root) takes one
or more dot-separated module names. `--tree` overrides
`driver.TITAN_SOURCE_PATH`. In source-checkout mode, `--lua` overrides
`driver.LUA_SOURCE_PATH`; installed mode rejects it so the installed headers,
`liblua.a`, and `libtitan.a` remain a matched SDK. `-v` prints every `cc`
command line, `--print-ast` dumps each module's
AST after checking, `-l` passes extra system libraries to the linker, and
`-X`/`--extra-object` appends one or more already-built native payloads.
In library mode those payloads must be supported relocatable objects or
regular archives: archives are force-carried into the DSO and flattened into
the paired `.a`, while mixed payload retains CLI order in both forms.
Executable mode keeps the broader established final-link behavior. Runtime and
callback-shim objects are not normally passed this way: both checkout and
installed builds select them from `libtitan.a`. The standard provider's
`titanlib.o` is the deliberate support payload. Bundled libuv joins it in
`-X`; system libuv remains a final-link setting.

Every CLI module name is placed in one `requested_roots` set and passed to the
filesystem loader. Those roots are source-first; everything they import runs
the configured complete compiled-format passes before source (`.so`, then
`.a` by default; swapped by `--static`). After checking, library mode derives
one physical provider base from the requested roots' longest common dotted
prefix. It rejects an empty prefix, the reserved logical module `titan`,
conflicting mangled C prefixes/protocol symbols, unsafe physical overlaps,
producer-binding identity conflicts, input/output aliases, and unowned shim
destinations before native linking.

All source modules reachable from every root are compiled once. Dynamic
dependencies retain exact selected DSO handles. Selected static dependencies
contribute deduplicated physical archives: their complete validated
membership is direct native input and is repackaged into both output forms,
without bulk-entering ordinary resolver state. [Multi-module
libraries](multi-module-libraries.md) documents logical grouping and DSO
loading; [Static compiled modules](static-compiled-modules.md) documents the
archive resolver, binding constraints, composition, and paired publication.

The standard library uses the same generic path with all seven qualified roots
in one command:

```sh
titanc titan.coroutine titan.uv titan.async titan.timer titan.fs titan.net titan.os \
  -X titan-runtime/titanlib.o
```

The provider prefix is `titan`, so checkout output is `titan.so`, `titan.a`,
and seven generated `titan/*.lua` shims. Each logical module retains its own
`luaopen_titan_*`, `_init`, `_abi`, `_types`, registry module state, and
initializer; `titanlib.o` supplies the eighth entry, `luaopen_titan`, and the
support table without adding an archive metadata key. The `titan.uv` folder
still generates only `titan/uv/uv.c`/`.o`, and no contributor shim. Bundled
mode puts the private libuv archive in the shared `-X` payload so its objects
enter both providers. System mode keeps the pkg-config-selected setting as a
repeated final-link input and never copies it into `titan.a`.

Make tracks every standard source explicitly, the compiler/runtime/support and
embedded-format inputs, effective `CC`/`AR`/`RANLIB`, extra flags, and libuv
configuration in a completion/config stamp. A missing `titan.so`, `titan.a`,
generated shim, or Darwin dSYM invalidates the stamp. A warm invocation also
rescans `titan.a` for the exact seven logical keys without changing pair
mtimes. Exact child DSOs are removed as stale production outputs; the isolated
delayed-callback and coroutine tests are the only supported exact-image
variants.

The source rock retains a two-stage bootstrap. `make titan` builds
`libtitan.a`, the SDK, and a distinct support-only image at
`titan-runtime/bootstrap/titan.so`. With `ROCKS_TREE`, the bootstrap is
atomically placed at `<root>/lib/titan/0.16/titan.so` only when that path is
absent; an existing valid bootstrap or full image is preserved, and an
incompatible image is left untouched with an error. The rock manifest then
deploys the compiler script/Lua modules but does not own a `titan` C module.

The source-only post-install hook invokes the just-deployed `titanc` once in a
private staging directory on the destination filesystem under the same
effective native toolchain, extra flags, rocks root, runtime mode, and libuv
policy. The publisher validates the eight Lua entries, seven logical
protocols, exact seven-key archive metadata, three-way embedded/DSO/
archive-backed ABI/types equality, seven shims, and Darwin dSYM. It backs up
the active-0.16 public set and stale active-layout copies, commits shims/dSYM,
then `titan.a`, and renames the validated DSO last. A caught or injected
failure restores the prior complete pair, a legacy complete DSO/shim
installation while leaving its archive absent, or the first-install
bootstrap. The canonical installed artifacts are
`<root>/lib/titan/0.16/{titan.so,titan.a}`, the DSO's macOS dSYM, and
`<root>/share/lua/5.5/titan/*.lua` shims. SDK and stdlib artifacts remain
direct files outside the rock manifest and are not removed by
`luarocks remove`. Separately versioned 0.15 trees are not purged.

Its flow:

1. **Typecheck everything first.** Each requested module gets a fresh loader
   configured with the complete `source_roots` set and goes through
   `checker.checkimport`; requested roots are source-first, imports are checked
   recursively with binary-first resolution, each selected folder is parsed
   into one dense AST and checked under its logical name,
   each source module records its own direct origin map, and the requested
   root receives a recomputed `driver.dependency_closure` for code generation
   and final linking.
   All errors — load failures and type errors alike — accumulate into one
   list, and if it
   is nonempty `titanc` prints them all to stderr and exits with status
   1 **before any code generation** (behavior introduced by PR #248).
2. **`main` detection.** For each successfully checked module,
   `checker.has_main(ast)` looks for a top-level function named `main`
   with exactly one fixed parameter of checked type `{string}`, no input tail,
   exactly one checked return type of `integer`, and no flexible result tail.
   Transparent aliases may spell either type; omitting the return annotation
   means zero declared results and therefore is not a `main`. At most
   one requested module may have a `main`;
   a second produces the error
   `<modname>: multiple main functions found (already declared in <main_module>)`.
3. **Library preflight, then compile.** In no-main mode the compiler derives
   the common provider and validates the linked logical-name/mangling set and
   every shim destination before changing build outputs. Every source module
   in `driver.imported` — requested or pulled in as a source dependency — is
   then compiled once to a `.o` with `driver.compile_module`. Failures are
   collected and reported at the end.
4. **Link.** If a `main` module was found, *all* compiled objects are
   linked into a single executable with `driver.compile_program` —
   passing the main cache entry's `program_output`, so a folder root uses
   `P__main` while a flat root retains `P`. Standalone programs always bundle
   every module statically. Otherwise the sorted source-object union is linked
   once into the common provider through `driver.compile_library_output`,
   together with any `--extra-object` files. Dependencies represented by
   compiled binaries stay dynamic and are not added to the link. The staged
   DSO's logical protocols (and provider `titan` support contract when
   applicable) are validated before atomic publication; generated shims follow
   only after successful DSO publication.
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
* **`util.bytewise_less(a, b)`** — locale-independent lexicographic ordering
  by numeric string bytes, with shorter prefixes first. Folder-source
  discovery uses it for contributor basenames, and `types.serialize` uses it
  for keyed interface maps whose text must be reproducible.
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
input. `titanlib.o` is also separate: it is the only input to the private
support bootstrap and is passed once as an extra object when the seven
standard logical modules are linked into the full `titan.so`.
The staged non-Lua SDK headers under `<root>/include` are `minicoro.h`,
`titan.h`, `titan_longjmp.h`, and `titan/{ffi,coro,uv}.h`. Checkout developer
mode selects the corresponding local archive and headers so runtime edits can
be tested before reinstalling.

### `titan.h`

* **`TITAN_LIKELY(x)` / `TITAN_UNLIKELY(x)`** — `__builtin_expect`
  wrappers (plain parentheses off GCC/Clang); used on the hot/cold
  sides of generated type checks.
* **Constants** — `TITAN_VER "0.16"`, `TITAN_VER_SUFFIX "_0_16"`,
  `TITAN_PATH_VAR "TITAN_PATH"`, `TITAN_PATH_SEP "/"`,
  `TITAN_ROOT_DEFAULT "/usr/local"`,
  `TITAN_LUA_CPATH_SUFFIX "/lib/lua/5.5/?.so"`, and UUID
  strings used as Lua-registry keys: `TITAN_PATH_KEY` (cached module search
  path), `TITAN_ROOT_KEY` (normalized Titan SDK/rocks-tree root),
  `TITAN_LIBS_KEY` (dlopen handle table), `TITAN_MAIN_BOOTSTRAP_KEY` (optional
  standalone-main hook), `TITAN_MAIN_ARGC_KEY` and `TITAN_MAIN_ARGV_KEY`
  (generated-entrypoint process arguments and libuv's possibly replaced
  `argv` pointer),
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
`titan.c`: `loadlib`, `loadsym`, `loadglobalsym`,
`titan_check_abi`, and `errorhandler`.

### `titan.c`: the dynamic loader

* **`pushroot(L)` / `titan_init_paths(L)`** normalize and cache the Titan
  SDK/rocks-tree root under `TITAN_ROOT_KEY`. After `luaL_openlibs`, a compiled
  executable scans the inherited
  `package.cpath` for the first entry ending in `/lib/lua/5.5/?.so`, falling
  back to `/usr/local` only when no such entry exists. `titan_init_paths` also
  ensures the exact `<root>/lib/titan/0.16/?.so` template is in
  `package.cpath` and eagerly initializes the Titan loader path. The configured
  Titan-owned Lua already places that template before the ordinary `lib/lua`
  templates, so Lua and standalone programs resolve the same qualified module
  DSOs.
* **`pushpath(L)`** resolves the run-time module search path once per
  Lua state and caches it in the registry under `TITAN_PATH_KEY`. The
  order is: `getenv("TITAN_PATH_0_16")` (the versioned variable,
  `TITAN_PATH_VAR TITAN_VER_SUFFIX`), then `getenv("TITAN_PATH")`,
  then `".;<root>/lib/titan/0.16"`, where `<root>` is recovered from
  the first literal `package.cpath` template ending in
  `/lib/lua/5.5/?.so` (or `/usr/local` as the legacy fallback). A `;;` in
  the environment value is replaced by that default path (two
  `luaL_gsub` passes through a `\1` placeholder), so
  `TITAN_PATH="/opt/titan;;"` means "look in `/opt/titan`, then the
  installation defaults". The compiler-side expansion now follows the same
  contract.
* **The libs registry** — a table under `TITAN_LIBS_KEY` maps `.so`
  file names to light-userdata `dlopen` handles. The cache avoids repeated
  `dlopen` calls within a state. Titan deliberately does not call `dlclose` at
  state shutdown: generated modules form a manually wired dependency graph for
  which neither insertion nor reverse-insertion order is universally safe, and
  finalizable Lua objects can still retain native entry pointers. The operating
  system reclaims the mapped images when the process exits.
* **`loadlib(L, file)`** — returns the cached handle for `file` if
  present; otherwise walks the path `;`-entry by entry, builds
  `dir "/" file` (the coder passes the relative provider selected into the
  imported `Type.Module.file`), and tries
  `dlopen(filename, RTLD_LAZY | RTLD_GLOBAL)`. Every generated runtime import
  uses these same flags; there is no libuv-specific filename case. Lazy binding
  lets a module's initializer load a provider before the module's unresolved
  function calls bind, while global visibility lets that later provider
  satisfy the calls. The first success is
  cached and returned; total failure raises a Lua error with
  `dlerror()` (which describes only the last attempt).
* **Generated logical-module shims** — a Lua `require "titan.uv"` first finds
  `titan/uv.lua`, whose `package.searchpath("titan", package.cpath)` selects the
  physical provider. The shim calls `require "titan"`, then uses the support
  table's separate `_loadlibglobal` helper to map/promote that provider with
  lazy/global flags and resolve `luaopen_titan_uv`. The same template serves
  every logical module; `titan.c` has no shim-specific or libuv-specific case.
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
`titanlib.c` into `titanlib.o`, links only that object into the private
bootstrap `titan-runtime/bootstrap/titan.so`, and passes it once when building
the full standard provider `titan.so`. It is *not* part of `libtitan.a` or
ordinary generated modules. Its user-facing operation is `backtrace`; it also exposes
the internal testing helpers `pin` and `clear` used to exercise the traceback
pin discipline, plus the compiler-only `_loadlib` helper:

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

`titan._loadlib(path, symbol)` is not a user-facing module loader. The compiler
uses it to inspect a compiled module's ABI and serialized type entry points. It
caches handles in a private registry table, maps each image with
`RTLD_LAZY | RTLD_LOCAL`, and returns the requested Lua C function (or the same
`nil, message, "open"/"init"` shape as `package.loadlib`). This generic helper
lets interface recovery inspect a DSO whose ordinary foreign function calls
are intentionally unresolved without globally loading any dependency or
running the module initializer.

`titan._loadlibglobal(path, symbol)` is the generated-shim counterpart. It
canonicalizes an existing path with `realpath`, uses a different per-state
handle table keyed by that canonical absolute path, calls
`dlopen(canonical, RTLD_LAZY | RTLD_GLOBAL)` on the first request in that
table, and resolves the requested Lua entry with `dlsym`. It deliberately does
not reuse `_loadlib`'s local cache or Lua's C-library cache; calling it after
Lua's C searcher loaded the same standard `titan.so` eager/local performs the
required promotion. Errors retain the originally requested pathname and use
the same `nil, message, stage` result shape. Neither helper calls `dlclose`.

## Reference: environment variables, paths, and flags

| Name | Where read | Default / value | Meaning |
| --- | --- | --- | --- |
| `PREFIX` | Makefile / rockspec build input | `/usr/local` for direct Make; an absolute per-project path in the supported workflow | Owns the prefix-configured Lua installation plus the LuaRocks executable and configuration. |
| `ROCKS_TREE` | Makefile / rockspec build input | empty for a direct build; LuaRocks' `$(SCRIPTS_DIR)/..` for a source install | Owns the installed Titan rock, SDK, and stdlib. The supported workflow currently sets it equal to `PREFIX`, but they are separate ownership concepts. |
| `TITAN_PATH_0_16` | `driver.lua` (compile time), `titan.c` `pushpath` (run time) | unset | Versioned module search path; wins over `TITAN_PATH`. |
| `TITAN_PATH` | same | unset | Module search path; `;;` expands to the ordinary default at compile time and run time. |
| `TITAN_ROCKS_ROOT` | `driver.lua`, source-rock post-install Make invocation | unset | Internal normalized `ROCKS_TREE` override used while the just-deployed compiler builds the standard modules; not a public deployment setting. |
| `driver.TITAN_ROOT` | `driver.lua` | internal override, otherwise first `package.cpath` entry ending `/lib/lua/5.5/?.so` | Normalized Titan SDK/rocks-tree root. Package-path discovery relies on the currently supported `ROCKS_TREE == PREFIX` layout. |
| `driver.SOURCE_CHECKOUT` / `driver.INSTALLED` | `driver.lua` | detected from checkout files unless the internal root is set | Select the writable checkout SDK/archive inputs or read-only installed SDK inputs. |
| `driver.INSTALL_PATHS` | `driver.installed_paths` | paths below `driver.TITAN_ROOT` | Holds `lua_source`, `include`, `lib`, `libtitan`, `libbacktrace`, `liblua`, `titan_bin`, and `lua_cpath`; bundled `libuv.a` is deliberately not an installed SDK path. |
| `driver.TITAN_BIN_PATH` | `driver.lua` | `TITAN_PATH_0_16`, `TITAN_PATH`, or `.;<root>/lib/titan/0.16` in installed mode | Roots for root-major, shallow-to-exact compiled-provider search; checkout mode retains the legacy `/usr/local` fallback. |
| `driver.TITAN_SOURCE_PATH` | `driver.lua` | `"."` (overridden by `titanc --tree`) | Semicolon-separated roots searched for folder `P/B.titan` before flat `P.titan`, including contributor privacy checks. |
| `options.source_roots` | `titanc` / `driver.defaultloader` | every CLI module name | Requires explicit build roots to come from flat/folder source while all dependencies remain binary-first; selected source descriptors also provide `program_output`. |
| `titan._loadlib` | `titanlib.c` / `driver.lua` | internal `RTLD_LAZY` + `RTLD_LOCAL` loader | Maps compiled dependencies lazily for ABI/type interface recovery without initializing them or globalizing their symbols. |
| `titan._loadlibglobal` | `titanlib.c` / generated shims | internal canonical-path `RTLD_LAZY` + `RTLD_GLOBAL` loader | Maps or promotes a Lua-selected provider in a separate per-state cache and returns the requested logical `luaopen_*` entry. |
| `Type.Module.file` | `types.lua`, `driver.lua`, `coder.lua` | exact logical `.so` path, overwritten after compiled lookup | Transient selected relative provider used by generated imports; deliberately omitted from serialized interfaces. |
| `driver.LUA_SOURCE_PATH` | `driver.lua` | `<root>/src/lua-5.5.0` installed; `lua-5.5.0/src` in checkout mode; checkout-only override by `titanc --lua` | Lua internal source/header tree used at compile time. Installed mode rejects the override because `INSTALL_PATHS` supplies its matching `liblua.a` and `libtitan.a`. |
| `driver.INCLUDE_PATH` | `driver.lua` | `<root>/include` in installed mode | Titan SDK and bundled-libuv headers used by generated C and foreign imports; the non-Lua set is `minicoro.h`, `titan.h`, `titan_longjmp.h`, and `titan/{ffi,coro,uv}.h`. |
| `driver.TITAN_RUNTIME_PATH` / `driver.LIBBACKTRACE_PATH` | `driver.lua` | `titan-runtime/` / `libbacktrace` | Checkout-only runtime source/archive/header and separate libbacktrace locations. |
| `CC` / `driver.CC` | environment / `driver.lua` | `"cc"` | C compiler command, parsed as shell words and shared with foreign-import probing. |
| `driver.CFLAGS` | `driver.lua` | `"--std=c99 -O2 -Wall -fPIC -g -fno-optimize-sibling-calls"` | Flags for every compile and link step. |
| `TITAN_EXTRA_CPPFLAGS` / `driver.EXTRA_CPPFLAGS` | environment / `driver.lua` | empty | Parsed `-I`/`-D` and other preprocessing inputs; used by foreign-import compiler probes and prepended to every Titan/runtime/entrypoint compilation. |
| `TITAN_EXTRA_CFLAGS` / `driver.EXTRA_CFLAGS` | environment / `driver.lua` | empty | Parsed compilation-only flags, after fixed defaults; never used by final links. |
| `TITAN_EXTRA_LDFLAGS` / `driver.EXTRA_LDFLAGS` | environment / `driver.lua` | empty | Parsed ordered linker inputs appended to final module and program links. |
| shared-library flags | `shared_flag()` | `-shared`; on Darwin `-shared -undefined dynamic_lookup` | Platform from `driver.UNAME` (output of `uname`). |
| installed link set | `driver.installed_link_inputs` / `append_runtime_libraries` | installed `libtitan.a` + separate `libbacktrace.a` + `liblua.a` + platform libraries | Used by both providers and programs; Linux adds `-ldl`, and all platforms add `-lm`. The combined standard `titan.so` alone receives the private bundled archive; direct bundled-mode extensions leave `uv_*` unresolved, while system mode may use explicit pkg-config link flags. |
| checkout link set | `driver.source_link_inputs` / `append_runtime_libraries` | local `libtitan.a` + separate local `libbacktrace.a` + local `liblua.a` + `-ldl -lm` | Preserves the writable source-development path while using the same archive contract; it never links `titan.o` directly. |
| `TITAN_ROOT_DEFAULT` / `TITAN_LUA_CPATH_SUFFIX` | `titan.h`/`titan.c` | `/usr/local` / `/lib/lua/5.5/?.so` | Legacy run-time root fallback and exact template suffix used for root discovery. |
| `titan_init_paths` | generated standalone entrypoint / `titan.c` | root parsed from inherited `package.cpath` | Caches the root and Titan module path and ensures `<root>/lib/titan/0.16/?.so` is in `package.cpath`; prefix-configured Titan-owned Lua has it first by default. |
| registry keys | `titan.h` | `TITAN_ROOT_KEY`, `TITAN_PATH_KEY`, `TITAN_LIBS_KEY`, `TITAN_MAIN_BOOTSTRAP_KEY`, `TITAN_MAIN_ARGC_KEY`, `TITAN_MAIN_ARGV_KEY`, `TITAN_BT_STATE_KEY`, `TITAN_BACKTRACE_KEY`, `TITAN_NAMES_KEY`, `TITAN_TRACE_PINNED`, `TITAN_TRACE_APPEND_KEY` (UUID strings) | Per-state caches and hooks: Titan SDK/rocks-tree root, module path, dlopen handles, optional standalone bootstrap, original process arguments and libuv's possibly replaced `argv`, registry-owned libbacktrace state, last raw backtrace, native-frame display names, re-raise traceback pin, and coroutine traceback append handoff. |
| generated ABI symbol | `coder.lua` | `<mangled>_abi` returning `TITAN_VER` | Checked before `.so` type rehydration and before run-time dynamic-import `dlsym`; markerless modules are treated as incompatible. |

The pieces upstream of the driver are described in
[the type checker](checker.md) (which calls the loader) and the
[code generator overview](codegen-overview.md) (which produces what the
driver compiles); the contents of the runtime archive's callers — the
generated `_init`, standalone path initialization, and Lua entry wrappers that
ensure `errorhandler` is active —
are in [Lua interop internals](lua-interop-internals.md).
