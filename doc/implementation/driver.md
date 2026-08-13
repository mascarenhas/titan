# Driver and toolchain

This chapter covers everything from resolving source/compiled modules through
producing a `.so`/`.a` pair or executable: `titan-compiler/driver.lua` (module lookup, the
import loader, C compilation and linking), the `titanc` command-line
front end, the small utility module the whole compiler leans on
(`util.lua`), and the C runtime-support library in
`titan-runtime/`. A reference table of every environment variable,
default path and flag closes the chapter.

## Module names and the search paths

Module lookup deals in dot-separated **module names**, never file paths.
Every component matches `[A-Za-z_][A-Za-z0-9_-]*`; this is checked before
source/binary lookup, code generation, generated-shim planning, and static
metadata acceptance. The alphabet is exactly what the native protocol can
turn into a portable C identifier after its established dash-to-underscore
mangling, and it keeps template metacharacters such as `$` out of generated
symbol names.
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
  `TITAN_PATH_0_24` wins over `TITAN_PATH`; with neither set, installed mode
  uses `".;" .. root .. "/lib/titan/0.24"`.

For `import foo.bar`, each compiled-format pass probes the shallow `foo`
provider and then exact `foo/bar` provider with that pass's extension:
`foo.so`, `foo/bar.so` in the DSO pass and `foo.a`, `foo/bar.a` in the
archive pass. If source is needed, lookup checks `foo/bar/bar.titan` before
`foo/bar.titan` in each source root. The compile-time path walk expands `;;`
with the same "insert the ordinary default here" convention as the run-time
loader in `titan.c`, then skips empty separators.
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
matching `src/lua-5.5.1`, `include`, `lib/liblua.a`, `lib/libtitan.a`,
`lib/libbacktrace.a`, and every compiled Titan module. Test mode additionally
selects `share/titan/0.24/src/titan/test.titan` from that same root as canonical
compiler-data source. Bundled libuv headers
are staged under `include`, but its static archive remains a private
source-build input rather than part of the installed SDK. Checkout mode
deliberately retains the repository paths for compiler/runtime development.
This is root discovery, not the previous policy of adding every
`package.cpath` directory to the Titan path. Outside a checkout, failure to
find that exact suffix becomes `driver.INSTALLATION_ERROR` and stops
compiler/toolchain use instead of silently mixing installations.

The standard library consists of eighteen ordinary qualified logical modules:
`titan.coroutine`, `titan.uv`, `titan.async`, `titan.timer`, `titan.io`,
`titan.fs`, `titan.net`, `titan.ssl`, `titan.url`, `titan.http`, `titan.os`,
`titan.peg`, `titan.string`, `titan.math`, `titan.lua`, `titan.iteration`,
`titan.gc`, and `titan.test`. Most
checkout sources are `titan/<name>.titan`; `titan.uv`, `titan.http`,
`titan.peg`, and `titan.string` are folder
ensembles. One `titanc` invocation links their independent objects and
`ltitanlib.o` into the physical checkout provider pair `titan.so`/`titan.a`.
The private namespaced LPegLabel archive follows `ltitanlib.o` as metadata-free
payload; selected libuv, private llhttp, and selected OpenSSL payloads follow
it. Installation publishes both forms below `<root>/lib/titan/0.24/`
and eighteen generated logical-module shims below
`<root>/share/lua/5.5/titan/`. Titan imports discover each module through the
preferred compiled-format pass; Lua requires use a generated shim and the DSO
form.

`titan.uv` is the private Runtime and native-provider layer. `titan.async`
imports it and exposes the public asynchronous facade, including transparent
aliases of uv-owned record types. The timer/fs/net/os modules also import uv
directly for their low-level plumbing, so all five consumers share one Runtime
and one canonical libuv provider image.

For source convenience, the parser desugars the fourteen short standard-library
imports before module resolution: `import "async"`, for example, places
`titan.async` in the import AST exactly as `import "titan.async"` would. The same
mapping applies to `coroutine`, `uv`, `timer`, `io`, `fs`, `net`, `ssl`, `url`, `http`,
`os`, `peg`, `string`, and `test`; every other name is left unchanged. The driver, checker, code
generator, and runtime thus
see only the qualified module name. Each qualified name naturally produces its
matching native symbols and Lua entry point (`titan_async_*` and
`luaopen_titan_async`, for example), so no separate Lua alias is required and
Lua's bare `coroutine` and `os` libraries remain unrelated.

### Source vs compiled providers: the selection logic

Dependency resolution is unconditionally **binary first**: the driver probes
the logical module's shallow-to-exact candidates on `TITAN_BIN_PATH`, recovers
the first validating interface, and does not inspect source timestamps. Only
when every candidate is absent or every existing ancestor is a clean metadata
nonclaim does it parse the first flat or folder source match. Source roots are
walked left to right; the folder-before-flat rule applies within each root,
rather than comparing one representation across all roots. This applies
equally to standard-library and application dependencies. In particular, a
stray `./titan/uv/uv.titan` folder does not capture `import "uv"` while an
installed compiled standard provider claims `titan.uv` on the binary path.

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
first. This is why one standard-library invocation can force all eighteen roots
through source even when a bootstrap or prior combined provider pair is
visible. Their internal imports resolve to the already selected source cache
entries and are linked statically into the replacement provider pair.

A `--test` invocation is the second deliberate exception. Its resolver context
sets `source_first`, making every dependency try the tagged source resolver
before compiled formats and retaining binary fallback only on a clean miss. A
narrow source override selects canonical `titan.test`, while generated
`titan.test.runner` uses an in-memory ordinary source descriptor. See
[Native test runner](test-runner.md).

The compiled branch runs complete format passes. A DSO candidate is probed
through the internal lazy/local `titan._loadlib` helper for its
`<mangled>_abi`/`<mangled>_types` pair; a successful dynamic claim stores the
selected relative pathname transiently in `Type.Module.file`. A static
candidate is scanned in-process for canonical object-section metadata; a
successful claim records the selected archive/provider but never places an
archive path in `Type.Module.file`. The default order is all `.so`, then all
`.a`; `--static` swaps those passes. Generated code uses handle-scoped dynamic
wiring for the former and direct native symbols for source or physically
carried static names. See [Static compiled
modules](static-compiled-modules.md) for archive validation, contextual owner
recovery, and native-binding constraints.

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

ABI 0.17 keeps serialized `Array(...)` descriptors and exact `Table *` /
`Table **` call shapes, but changes what those pointers mean: they now denote
private dense-Array backings paired with canonical proxy Udata at Lua-visible
boundaries. Every generated module gains an Array-metatable cache and explicit
boxing/unboxing paths. Old and new code cannot safely exchange Arrays, so the
marker, `TITAN_PATH_0_17`, and installed namespace advance together. See
[Dense Arrays](dense-arrays.md#abi-017-020-021-022-023-and-024-boundaries).

ABI 0.18 preserved those serialized and native Array shapes but changed the
standard-library archive/runtime contract. Logical standard-library objects
directly reference promoted libuv callback trampolines and no longer reference
replaced libuv/coroutine helper symbols. A 0.18 provider and runtime had to be
built and distributed together, so its marker, `TITAN_PATH_0_18`, and
installed namespace advanced together.

ABI 0.19 added serialized `Type.Union`/`Type.Variant` schemas, the union
userdata/tag protocol, and the public module-slot prefix for exported nominal
statics.

ABI 0.20 added the second traced Array-proxy user value carrying its
genuine-Lua writer closure, and the fixed-brand/strict-entry-trailer protocol
for first-class Titan functions. ABI 0.21 retained those layouts while
advancing the embedded Lua contract from 5.5.0 to 5.5.1. ABI 0.22 is the
source-local `titan.uv` surface/private-provider boundary: its serialized public
schema and reconstructible module-userdata prefix change while Lua 5.5.1 and
the other value/native-call layouts remain unchanged. Every generated module
also gains the fixed physical-provider identity slot used to authenticate
canonical source-private state. ABI 0.23 retains those layouts while changing
the native callback contract and separating module, nominal owner, and member
in callable symbols. ABI 0.24 extends serialized interfaces for generic binder
scopes, parameter references, applied nominals, schemes, generic owners and
methods, and constructor-preserving aliases while retaining erased native
layouts. The current marker, `TITAN_PATH_0_24`, and `lib/titan/0.24` namespace
advance together. A 0.23 candidate is rejected before type metadata is decoded
or native linking begins.

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

* **`driver.imported`** — a process-global cache keyed by logical module name.
  Source entries carry `{ kind = "source", ast, type, filename,
  program_output, deps }`; DSO entries carry `{ kind = "dynamic", type,
  filename, relative }`; archive entries carry `{ kind = "static", type,
  filename, static_archive, static_provider }`. Tests and long-lived tools
  reset this cache together with `types.registry`.
* **`CIRCULAR_MARK`** — a unique sentinel stored before recursively checking a
  source module; encountering it reports `"circular reference to module"`.
* **the resolver context** — invocation-wide compiled-format preference,
  archive-scan cache, ordinary provenance, selected static providers,
  contextual type-only owner recovery, native-binding constraints, and the
  finalized direct-name sets.

The closure proceeds in this order:

1. A contextual nominal-owner request first follows the exposing compiled
   interface's producer choice. A carried static owner is recovered from that
   same archive; a DSO-carried owner is probed from that same DSO; otherwise a
   compiled lookup may recover type information without committing ordinary
   resolver state or selecting an archive.
2. An ordinary cache hit returns the cached type and remembers a direct
   source/static edge for compatibility callers. If a name is now an explicit
   `options.source_roots` build root, a prior compiled cache entry is discarded
   so cache history cannot hide the requested source.
3. An explicit root resolves folder/flat source or fails. Every other lookup
   runs one complete compiled pass per format on `TITAN_BIN_PATH`—`.so` then
   `.a` by default, reversed by `prefer_static`—before looking for source on
   `TITAN_SOURCE_PATH`. Root-major, shallow-to-exact order and occupied
   relative-path shadowing are independent within each format.
4. A source hit is a tagged flat/folder descriptor. Every listed file is read
   and parsed independently with its real filename. The main initializer is
   saved, contributor roots are appended in descriptor order, contributor
   initializers are rejected, and the saved initializer is appended once.
   The dense AST is recursively checked exactly once and cached with direct
   source/static dependencies; the canonical main becomes `filename` and the
   descriptor supplies `program_output`.
5. A DSO hit is cached with dynamic provenance and the selected transient
   relative provider path. A static hit is cached with its one claimed logical
   interface and physical provider; sibling keys remain physical membership,
   not ordinary resolver results.

The folder descriptor is temporary loader input, not AST metadata. One cache
entry, circularity sentinel, module type, direct-dependency set, and
initializer remain keyed by `modname`. Node locations are the only retained
per-contributor information. The checker receives the main filename as its
source directory; because contributors are immediate siblings, quoted foreign
headers from any file resolve under that same directory.

For a DSO hit, `find_dynamic_interface` uses
`titan._loadlib(path, symbol)` to map each existing candidate with
`RTLD_LAZY | RTLD_LOCAL`, probe the requested callable pair, and validate a
claim. For an archive hit, `find_static_interface` parses the complete regular
archive and its ELF/Mach-O metadata sections in-process, validates every
member and interface, and returns only the requested key. Both paths evaluate
the serialized type expression in the `types` constructor environment and
require a canonical `Type.Module` for the logical name. See [the complete
claim rules](multi-module-libraries.md#claim-and-terminal-error-states).

The shared closed validator accepts Interfaces only as direct
`Module.type_members`. It checks the owner/key, public locality, canonical
nonempty ordered Method projection, parameter-name metadata, and every
value-facing signature component before the checker registers those
descriptors. DSO and archive paths therefore recover the same nominal
Interface graph and reject malformed wrappers before any native symbol is
trusted. See [Interfaces](interfaces.md#separate-compilation-and-schema-validation).

Each source entry's `deps` stores direct dependencies that are already native
inputs—source or selected static—regardless of which contributor declared
the import. The loader's `static_deps` argument retains this compatibility
view for embedding callers and test helpers. Production `titanc` instead
finalizes the shared resolver context after all roots are checked, deriving
`native_static_names` as every invocation source name plus every logical key
physically carried by the deduplicated selected archives. It passes that
complete set to every `coder.generate` call and passes the selected archives
once to native linking.

`coder.generate` therefore has three binding paths: direct `extern` symbols
for source/static names, handle-scoped `loadlib`/`loadsym` for selected DSOs,
and process-global symbol recovery for producer-dynamic transitive record
owners. Generated `_types` functions persist none of this provenance or the
transient DSO path ([static vs dynamic
wiring](codegen-overview.md)). Folder layout does not add a loader protocol;
the relevant filesystem options are `source_roots` and the shared resolver
`context`.

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

`driver.compile(modname, ast, sourcef, static_deps, verbose, options)`
turns one checked logical-module AST into an object file. For a folder module,
`sourcef` is its canonical main and `ast` is the combined dense list; there is
still one call. `options.foreign_header_plan` carries the already validated
invocation-wide source-header plan when the CLI owns the compilation:

1. **Select the runtime SDK.** Installed mode is read-only: it uses headers
   from `<root>/include` and the already-built `<root>/lib/libtitan.a`.
   Checkout developer mode lazily rebuilds and later links the corresponding
   local archive, so edits to runtime support can be exercised without
   reinstalling:

   ```sh
   make --no-print-directory titan-runtime/libtitan.a
   ```

   Both modes link `libtitan.a`; the driver never substitutes a direct
   `titan.o` link. The checkout freshness check covers `titan.c`, the reduced
   `minicoro.c`, and their runtime headers. Source callback edits rebuild
   their generated module objects instead.
2. **Prepare the source-foreign companion.** `titanc` plans every logical
   source module after checking, rewrites temporary dependency-header edges to
   their final absolute paths, and validates all owned/unowned destinations
   before writing any. It writes each required `*.titan.h` to a sibling stage,
   applies required `#line` normalization and, only with `--pretty-print`, the
   configured `clang-format`, then renames the completed header into place
   before compiling the first object.
   `driver.compile` consumes that supplied plan; a direct programmatic caller
   gets a one-module planning/writing fallback. A folder module's companion is
   beside its canonical main and contributors never own one. See
   [Foreign-function implementation](foreign-functions.md#generated-titanh-planning).
3. `coder.generate(modname, ast, static_deps, abi,
   emit_line_directives)` produces one raw C translation unit as a string plus
   its direct-native-reference set. The qualified `modname` controls the native
   prefix, registry identity, `_init`, `_abi`, `_types`, and `luaopen_*`
   symbols consistently.
4. The raw translation unit is written **next to the flat source or folder
   main** as `sourcef:gsub("[.]titan$", "") .. ".c"` (if `sourcef` is not
   given it defaults to the dots-to-slashes path), then normalized in place.
   `--pretty-print` additionally formats it before compilation. Formatting
   failure aborts before its object is compiled but retains the raw or partially
   formatted `.c` as a diagnostic artifact. Contributors never
   receive generated C or object files.
5. The object is compiled with the parsed `driver.CC`, then
   `TITAN_EXTRA_CPPFLAGS`, Titan's fixed `driver.CFLAGS`, and
   `TITAN_EXTRA_CFLAGS`, in that order:

   ```sh
   cc --std=c99 -O2 -Wall -fPIC -g -fno-optimize-sibling-calls -c foo/bar.c \
      -I <root>/include -I <root>/src/lua-5.5.1 -o foo/bar.o
   ```

   Checkout mode substitutes `titan-runtime`, `lua-5.5.1/src`, and
   `libbacktrace` include paths. `-g` emits the DWARF that carries the `#line` file/line a unified
   trace needs; `-fno-optimize-sibling-calls` keeps tail frames on the
   stack so libbacktrace can unwind them; `-I libbacktrace` finds
   `backtrace.h`.

The native-tool strings, and `CLANG_FORMAT` when `--pretty-print` actually
selects it, are parsed into dense argument arrays with a small shell-word grammar
supporting whitespace, single/double
quotes, and backslash escapes. Each command builder quotes every resulting word
before its final `os.execute`, so spaces and shell metacharacters remain part of
one argument rather than being reinterpreted. Unterminated quotes, trailing
escapes, NUL bytes, an empty configured command, and non-dense programmatic
argument arrays produce configuration errors. A malformed `CLANG_FORMAT` is
therefore inert in the default mode. `-v` prints the same safely quoted
compiler/linker commands—and any opted-in formatter command—that are executed.

`driver.compile_module(modname, mod, static_deps, verbose, options)` is the thin
wrapper `titanc` uses: it skips modules whose cache entry says `compiled` (the binary
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

`driver.compile_library_output(soname, libnames, link, verbose,
extra_objects, static_archives, ordered_payload, install_name)` links an
explicitly named DSO from the complete logical source-module object union.
The final argument is an optional Darwin install name:

```sh
cc --std=c99 -O2 -Wall -fPIC -g -fno-optimize-sibling-calls -shared \
   -o app.so app_model.o app_view.o dep.o ... \
   [force-load selected-provider.a ...] \
   [ordered extra.o ... force-load native-payload.a ...] \
   <root>/lib/libtitan.a <root>/lib/libbacktrace.a <root>/lib/liblua.a \
   [-ldl] -lm [-lSDL2 ...] [TITAN_EXTRA_LDFLAGS...]
```

The objects are sorted by logical module name and deduplicated before this
call. Selected Titan archives follow and are force-loaded into the DSO. The
classified `ordered_payload` retains `-X` CLI order: objects enter directly
and archives are force-loaded. `extra_objects` is the legacy unclassified
fallback. Runtime `libtitan.a`, separate `libbacktrace.a` (**before**
`liblua.a`), matching `liblua.a`, platform libraries, `-l`, and ordered
`TITAN_EXTRA_LDFLAGS` follow. Neither installed nor checkout mode links an
individual `titan.o`. `compile_library(modname, ...)` remains a thin
exact-output wrapper for programmatic and test-only callers. The paired
archive builder flattens the same source, selected-provider, and ordered
payload members without copying those common final libraries.

`titanc` derives the public provider from the requested roots, links the DSO
under the public basename in a sibling staging directory, builds the staged
regular archive, and performs embedded/DSO/archive-backed protocol validation.
On Darwin the shared flag is `-shared -undefined dynamic_lookup`; `dsymutil`
must succeed before the bundle is valid, and preserving the DSO basename keeps
the dSYM's inner name correct. `titanc` also passes the eventual relative
public provider path as `install_name`; the driver forwards it as the
`LC_ID_DYLIB` value instead of allowing Darwin's linker to derive that identity
from the unique staging path. That public-provider link also uses Darwin's
reproducible mode so its debug map does not encode volatile input-object
properties. For this staged-provider case, the driver runs `dsymutil` from the
unique stage directory with only the stable DSO leaf name; this keeps the
dSYM's relocation-map `binary-path` metadata independent of the transaction's
random directory. An unchanged relink can therefore retain byte-identical DSO,
UUID, and dSYM contents. `publish_provider_bundle` then commits generated shims
and dSYM, the archive, and finally the DSO as the dynamic-path commit point;
caught failures restore the prior owned set. After building and validating the
staged artifacts, the equivalence check described in [Static compiled
modules](static-compiled-modules.md#publication-and-installation) discards an
unchanged staged bundle and preserves public mtimes. The older `publish_library`
helper remains DSO-only for programmatic/test callers and is not the `titanc`
no-main path.
See [Validated publication and generated
shims](multi-module-libraries.md#validated-publication-and-generated-shims).

A bundled-mode extension DSO that directly calls `uv_*` remains an ordinary
case. Its source imports `titan.uv` and foreign-imports `uv.h`, leaving ordinary
libuv calls unresolved. Compiler inspection maps it lazy/local; generated
runtime import maps its selected provider lazy/global, and the initializer
loads the combined standard `titan.so` before those calls bind. Native
constructors, imported data, and taken function addresses still need eager
resolution and cannot rely on initializer ordering. System mode may instead
link the same pkg-config-selected shared libuv. The private bundled archive is
shared standard-provider payload: it is force-loaded into `titan.so` and
flattened into `titan.a`, never linked into a general extension.

## Linking a standalone program: `driver.compile_program`

`driver.compile_program(modname, libnames, link, verbose, extra_objects,
program_output, static_archives, entrypoint_output, program_name, options)`
produces an
executable at the optional
`program_output` path, relative to the working directory. Omitting it
preserves the original `modname:gsub("[.]", "/")` default for programmatic
callers and `tableloader`. The trailing `static_archives` list contains
selected self-describing providers. The optional entrypoint path and display
name let test mode keep synthetic native artifacts beside the selected program
without changing its logical main identity. The optional final table currently
carries `no_uv_bootstrap`; omitting it preserves the ordinary hook-selection
behavior for programmatic callers. Filesystem source descriptors
cache:

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
   -c foo/bar__entrypoint.c -I <root>/include -I <root>/src/lua-5.5.1 \
   -o foo/bar__entrypoint.o
cc --std=c99 -O2 -Wall -fPIC -g -fno-optimize-sibling-calls -o foo/bar \
   foo/bar__entrypoint.o foo/bar.o ... \
   [selected-provider.a ...] [extra.o ...] \
   <root>/lib/libtitan.a [selected-provider.a ...] \
   <root>/lib/libbacktrace.a \
   <root>/lib/liblua.a [-ldl] -lm [-lSDL2 ...] \
   [TITAN_EXTRA_LDFLAGS...]
```

The command above shows the flat default. A folder program changes only the
link output after `-o` to `foo/bar__main`. On ELF, selected providers first
receive an ordinary grouped search, then `-X` retains its established
standalone order, and a second group containing runtime `libtitan.a` plus the
providers resolves references in either direction; the remaining
runtime/platform/final inputs stay outside. Darwin's linker performs its
continual archive search without those groups. No selected provider or `-X`
archive is force-loaded into an executable.

The entrypoint C/object path,
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
  ensures `<root>/lib/titan/0.24/?.so` is in `package.cpath`; the configured
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
  that pointer and builds an Array with capacity `argc - 1`. It copies
  `argv[i]` to logical index `i` only for `i = 1 .. argc-1`; the executable
  name is omitted. A Titan `main(args: {string}): integer` therefore sees
  `args[0] == nil`, `args[1]` as the first real argument, and
  `#args == argc - 1`. Requiring the main module first
  initializes all imports; an async standard module may install a
  callable under `registry[TITAN_MAIN_BOOTSTRAP_KEY]` during that work.
  The rendered `$SKIP_MAIN_BOOTSTRAP` constant is true only for
  `options.no_uv_bootstrap`. If it is true or the key is nil, `pmain` pops the
  retrieved hook value and calls `main(arg)` directly. Otherwise it calls
  `hook(main, arg)`. The bypass does not clear or replace the registry key.
  Both paths remain inside `main`'s single outer protected call, and retrieving
  `main` before consulting the hook prevents an importer from replacing the
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
./titanc [--print-ast] [--pretty-print] [-v|--verbose] \
  [-u|--lua <luasrc>] [--static] [--test] [--no-uv-bootstrap] \
  [--no-line-directives] \
  [-t|--tree <srcroot>] [-l|--link lib1,lib2] \
  [-X|--extra-object obj.o...] <module>...
```

`titanc` (a short `argparse` script at the repository root) takes one
or more dot-separated module names. `--tree` overrides
`driver.TITAN_SOURCE_PATH`. In source-checkout mode, `--lua` overrides
`driver.LUA_SOURCE_PATH`; installed mode rejects it so the installed headers,
`liblua.a`, and `libtitan.a` remain a matched SDK. `--pretty-print` opts every
emitted C/header boundary into the fixed `clang-format` pass; default builds do
not invoke it. `-v` prints every native-tool command line plus any opted-in
formatter command, `--print-ast` dumps each module's AST after checking,
`--static` swaps the compiled-provider passes to prefer
self-describing archives before DSOs, `--test` selects the native test pipeline
described in [Native test runner](test-runner.md), and `--no-uv-bootstrap`
threads one entrypoint-only option through `driver.compile_program`. The driver
renders the bootstrap condition with a constant direct-path operand; module
initialization, `TITAN_MAIN_ARGC_KEY`/`TITAN_MAIN_ARGV_KEY` publication,
libuv's possible argv replacement, main retrieval, protected error handling,
and the registry hook itself are unchanged. The CLI rejects the option before
finalization when no standalone main or generated test main exists.
`--no-line-directives` tells the coder
to leave native diagnostics attributed to the generated C file instead of
Titan source, `-l` passes extra system libraries to the linker, and
`-X`/`--extra-object` appends one or more already-built native payloads.
The environment setting `TITAN_NO_LINE_DIRECTIVES=1` applies the same policy
to direct driver users and build automation. `driver.compile` passes the
resolved policy explicitly to `coder.generate`; every generation resets the
coder's emission policy, including when one Lua process alternates modes.
Because the traceback builder recognizes ordinary native Titan frames through
their Titan-attributed debug filenames, disabling directives can omit those
frames from logical tracebacks. Entry boundaries may instead render as `[C]`.
In library mode those payloads must be supported relocatable objects or
regular archives: archives are force-carried into the DSO and flattened into
the paired `.a`, while mixed payload retains CLI order in both forms.
Executable mode keeps the broader established final-link behavior. Runtime and
callback-shim objects are not normally passed this way: both checkout and
installed builds select them from `libtitan.a`. The standard provider's
`ltitanlib.o` is the deliberate support payload. Bundled libuv joins it in
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

In test mode, requested roots still come from source, but their entire
invocation uses source-first dependency selection. After those modules check,
`titanc` discovers cases, checks generated `titan.test.runner` as the sole main,
and reuses standalone linking. Input application mains are ignored; the first
requested root determines the executable path. Only case-owning modules receive
the trailing sibling-call-preservation flag.

All source modules reachable from every root are compiled once. Dynamic
dependencies retain exact selected DSO handles. Selected static dependencies
contribute deduplicated physical archives: their complete validated
membership is direct native input and is repackaged into both output forms,
without bulk-entering ordinary resolver state. [Multi-module
libraries](multi-module-libraries.md) documents logical grouping and DSO
loading; [Static compiled modules](static-compiled-modules.md) documents the
archive resolver, binding constraints, composition, and paired publication.

The standard library uses the same generic path with all eighteen qualified roots
in one command:

```sh
titanc titan.coroutine titan.uv titan.async titan.timer titan.io titan.fs titan.net \
  titan.ssl titan.url titan.http titan.os \
  titan.peg titan.string \
  titan.math titan.lua titan.iteration titan.gc titan.test \
  -X titan-runtime/ltitanlib.o lpeglabel-build/libtitan-lpeglabel.a \
     libuv-build/libuv.a llhttp-build/libtitan-llhttp.a \
     openssl-build/libssl.a openssl-build/libcrypto.a  # bundled modes
```

The provider prefix is `titan`, so checkout output is `titan.so`, `titan.a`,
and eighteen generated `titan/*.lua` shims. Each logical module retains its own
`luaopen_titan_*`, `_init`, `_abi`, `_types`, registry module state, and
initializer; `ltitanlib.o` supplies the nineteenth entry, `luaopen_titan`, and the
support table without adding an archive metadata key. The `titan.uv` folder
still generates only `titan/uv/uv.c`/`.o`, and no contributor shim. The
five-member LPegLabel archive is force-carried into both providers after
`ltitanlib.o` but contributes no logical metadata. Bundled mode puts the private
libuv archive after it in the shared `-X` payload, followed by the private
llhttp archive and then the bundled OpenSSL archives used directly by
`titan.ssl`.
System mode omits the selected libuv/OpenSSL archives, keeps their
pkg-config-selected settings as repeated final-link inputs, and never copies
them into `titan.a`; the llhttp archive remains private payload in either mode.
The eight llhttp callbacks are source-defined in the generated `titan.http`
object, so there is no HTTP adapter object.

Make tracks every standard source explicitly, the compiler/runtime/support and
embedded-format inputs, effective `CC`/`AR`/`RANLIB`, extra flags, libuv and
OpenSSL configurations, and the private llhttp identity in a
completion/config stamp. A missing `titan.so`, `titan.a`, generated shim, canonical test-support source,
or Darwin dSYM invalidates the stamp. A warm invocation also
rescans `titan.a` for the exact eighteen logical keys without changing pair
mtimes. Exact child DSOs are removed as stale production outputs; the isolated
coroutine test is the only supported exact-image variant.

The source rock retains a two-stage bootstrap. `make titan` builds
`libtitan.a`, the SDK, and a distinct support-only image at
`titan-runtime/bootstrap/titan.so`. With `ROCKS_TREE`, the bootstrap is
atomically placed at `<root>/lib/titan/0.24/titan.so` only when that path is
absent; an existing valid bootstrap or full image is preserved, and an
incompatible image is left untouched with an error. The rock manifest then
deploys the compiler script/Lua modules but does not own a `titan` C module.

The source-only post-install hook invokes the just-deployed `titanc` once in a
private staging directory on the destination filesystem under the same
effective native toolchain, extra flags, rocks root, runtime mode, and
libuv/OpenSSL policies. The hook snapshots `titan/test.titan` into that exact
stage before compilation. The publisher validates the nineteen Lua entries, eighteen logical
protocols, exact eighteen-key archive metadata, three-way
embedded/DSO/archive-backed ABI/types equality, eighteen shims, the canonical test-support source, and Darwin dSYM. It backs up
the active-0.24 public set and stale active-layout copies, commits shims and
the compiler source, then dSYM and `titan.a`, and renames the validated DSO last. A caught or injected
failure restores either the prior complete pair or the first-install
bootstrap. The canonical installed artifacts are
`<root>/lib/titan/0.24/{titan.so,titan.a}`, the DSO's macOS dSYM, and
`<root>/share/lua/5.5/titan/*.lua` shims plus
`<root>/share/titan/0.24/src/titan/test.titan`. SDK and stdlib artifacts remain
direct files outside the rock manifest and are not removed by
`luarocks remove`. Separately versioned 0.17 through 0.23 trees are not purged,
migrated, or treated as active-layout predecessors.

ABI 0.24 is a new versioned boundary, not an in-place 0.23 migration. Linux CI
keys its restored dependency state by the active ABI, runs `make lua` and
`make luarocks`, replaces only known active-0.24 Titan-owned rock/direct-shim
state, and asserts that the resulting interpreter's `package.cpath` contains
0.24 rather than the 0.23 template. Existing 0.23 artifacts remain preserved
prior-version state; no migration or cleanup path consumes them. The old 0.17-to-0.18
cutover canary is retired; this
does not waive the ordinary manually dispatched full macOS pre-merge suite.

Its flow:

1. **Typecheck everything first.** One loader and resolver context shared by
   the complete `source_roots` set checks every requested module through
   `checker.checkimport`; requested roots are source-first, imports are checked
   recursively with compiled-format-first resolution, and each selected
   folder is parsed into one dense AST and checked under its logical name.
   Each source module records direct source/static edges. After all roots,
   `driver.finalize_resolver_context` derives the invocation-wide source set,
   deduplicated selected archives, producer-binding constraints, and
   `native_static_names`, which every `compile_module`/`coder.generate` pass
   uses to choose direct native calls. Final linking separately consumes the
   resulting source objects and the context's deduplicated selected archives.
   All errors — load failures and type errors alike — accumulate into one list,
   and if it
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
4. **Link and publish.** If a `main` module was found, *all* compiled source
   objects and selected static providers are linked into a single executable
   with `driver.compile_program` — passing the main cache entry's
   `program_output`, so a folder root uses `P__main` while a flat root retains
   `P`. Dependencies selected from DSOs remain dynamic. Otherwise the sorted
   source-object union, selected static providers, and `--extra-object`
   payload feed one common provider bundle: the DSO force-carries archive
   payload, while the sibling regular `.a` flattens the same native members
   without duplicating runtime/final libraries. Titan validates the staged
   archive's exact metadata set, the DSO callable protocols, their
   byte-for-byte agreement, and an archive-backed validation image before
   recoverably publishing shims/dSYM, archive, and finally the DSO commit
   point. Link, archive, validation, and publication failures are collected
   and make `titanc` exit with status 1; caught publication failures restore
   the prior owned bundle.

## Optional `clang-format` generated-source formatting

The coder builds C by pasting strings, with no C AST or in-process
pretty-printer. Presentation formatting is deliberately opt-in:
`titanc --pretty-print` invokes the parsed `CLANG_FORMAT` command (default
`clang-format`) in place on every emitted `.c` and every `.titan.h` stage. The
default pipeline never parses, discovers, or invokes that tool. It persists the
valid raw template output instead.

The opted-in command supplies an explicit LLVM-based, four-space style and
disables include sorting rather than discovering an ambient project
`.clang-format`. Include order is intentional in generated module preambles and
source-foreign headers, where direct, supplemental, and generated companion
headers have distinct roles.

Every generated-file boundary performs the non-presentational normalization
needed for source maps: it removes all blank physical lines immediately after a
`#line` directive. The coder performs the same cleanup on its assembled module
source before returning it. Thus default and pretty-printed builds both make the
directive's named Titan line apply to the immediately following generated
statement.

The lifecycle is raw write, optional format, normalization, then native compile.
Generated headers use sibling stages and are renamed into place only after every
selected step succeeds, so an I/O or opted-in formatter error cannot replace a
usable owned header. Temporary checking headers complete the same boundary
before any compiler probe consumes them. Generated `.c` files remain at their
diagnostic paths when opted-in formatting fails, but no native compile begins.
This covers module translation units, source-foreign companions, generated
standalone/test entrypoints, and generated native-validation units. The C FFI's
semantic and rejection probes are not emitted codegen artifacts and continue
directly to the configured C compiler.

Templates must already produce valid C in either mode. Generated multiline
comments use conventional ` *` continuation lines so an opted-in formatter pass
is a fixed point. With `-v`, Titan prints the safely quoted formatter invocation
only when `--pretty-print` selects it, just as it prints executed native tool
commands.

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
contains exactly the dynamic loader/error runtime `titan.o` and reduced
minicoro implementation/tag support `minicoro.o`. Source foreign callbacks
live in generated standard-module objects instead. Static-archive selection
pulls in only referenced objects. Vendored `libbacktrace.a` is a separate link
input. `ltitanlib.o` is also separate: it is the only input to the private
support bootstrap and is passed once as shared native payload when the eighteen
standard logical modules are published in the full `titan.so`/`titan.a` pair.
The private five-member LPegLabel archive follows it only in the standard
provider payload and is not part of the runtime SDK.
The staged non-Lua SDK headers under `<root>/include` are `minicoro.h`,
`titan.h` and `titan/ffi.h`. Checkout developer
mode selects the corresponding local archive and headers so runtime edits can
be tested before reinstalling.

### `titan.h`

* **`TITAN_LIKELY(x)` / `TITAN_UNLIKELY(x)`** — `__builtin_expect`
  wrappers (plain parentheses off GCC/Clang); used on the hot/cold
  sides of generated type checks.
* **Constants** — `TITAN_VER "0.24"`, `TITAN_VER_SUFFIX "_0_24"`,
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
  `TITAN_NAMES_KEY` (native-symbol display-name table),
  `TITAN_TRACE_PINNED` (re-raise traceback pin), and
  `TITAN_TRACE_APPEND_KEY` (temporary coroutine traceback append slot).
  `TITAN_LUAINTEGER_NBITS` is used by shift code generation.
* **`titan_pushmodule(L, c)`** — pushes a `Udata*` (the module state
  object) onto the Lua stack by writing the slot and bumping
  `L->top.p` directly.
* **`titan_setbvalue(obj, x)`** — sets a boolean `TValue` from a C
  `int`. Exists because Lua 5.5 removed `setbvalue`: booleans carry no
  payload, truth lives in the type tag (`setbtvalue`/`setbfvalue`).
* **`titan_cast_func(t, p)`** — toolchain-supported conversion in either
  direction between function pointers and object/`void *` pointers. Dynamic
  loading uses `void *` to function pointer for `dlsym` results; explicit FFI
  erasure uses function pointer to `void *`. ISO C does not make these
  conversions portable, while POSIX and the supported toolchains provide the
  required contract. The Titan name avoids colliding with Lua 5.5's own
  single-argument `cast_func` in `llimits.h`.
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
  ensures the exact `<root>/lib/titan/0.24/?.so` template is in
  `package.cpath` and eagerly initializes the Titan loader path. The configured
  Titan-owned Lua already places that template before the ordinary `lib/lua`
  templates, so Lua and standalone programs resolve the same qualified module
  DSOs.
* **`pushpath(L)`** resolves the run-time module search path once per
  Lua state and caches it in the registry under `TITAN_PATH_KEY`. The
  order is: `getenv("TITAN_PATH_0_24")` (the versioned variable,
  `TITAN_PATH_VAR TITAN_VER_SUFFIX`), then `getenv("TITAN_PATH")`,
  then `".;<root>/lib/titan/0.24"`, where `<root>` is recovered from
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

### `ltitanlib.c`: the `titan` Lua module

This companion is built separately from `libtitan.a`: Make compiles
`ltitanlib.c` into `ltitanlib.o`, links only that object into the private
bootstrap `titan-runtime/bootstrap/titan.so`, and passes it once as native
payload when building the full standard `titan.so`/`titan.a` provider pair.
It is *not* part of the runtime SDK's `libtitan.a` or ordinary generated
modules. Its user-facing operation is `backtrace`; it also exposes
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
| `TITAN_PATH_0_24` | `driver.lua` (compile time), `titan.c` `pushpath` (run time) | unset | Versioned module search path; wins over `TITAN_PATH`. |
| `TITAN_PATH` | same | unset | Module search path; `;;` expands to the ordinary default at compile time and run time. |
| `TITAN_ROCKS_ROOT` | `driver.lua`, source-rock post-install Make invocation | unset | Internal normalized `ROCKS_TREE` override used while the just-deployed compiler builds the standard modules; not a public deployment setting. |
| `driver.TITAN_ROOT` | `driver.lua` | internal override, otherwise first `package.cpath` entry ending `/lib/lua/5.5/?.so` | Normalized Titan SDK/rocks-tree root. Package-path discovery relies on the currently supported `ROCKS_TREE == PREFIX` layout. |
| `driver.SOURCE_CHECKOUT` / `driver.INSTALLED` | `driver.lua` | detected from checkout files unless the internal root is set | Select the writable checkout SDK/archive inputs or read-only installed SDK inputs. |
| `driver.INSTALL_PATHS` | `driver.installed_paths` | paths below `driver.TITAN_ROOT` | Holds `lua_source`, `include`, `lib`, `libtitan`, `libbacktrace`, `liblua`, `titan_bin`, and `lua_cpath`; bundled `libuv.a` is deliberately not an installed SDK path. |
| `driver.TITAN_BIN_PATH` | `driver.lua` | `TITAN_PATH_0_24`, `TITAN_PATH`, or `.;<root>/lib/titan/0.24` in installed mode | Roots for root-major, shallow-to-exact compiled-provider search; checkout mode retains the legacy `/usr/local` fallback. |
| `driver.TITAN_SOURCE_PATH` | `driver.lua` | `"."` (overridden by `titanc --tree`) | Semicolon-separated roots searched for folder `P/B.titan` before flat `P.titan`, including contributor privacy checks. |
| `TITAN_NO_LINE_DIRECTIVES` / `driver.EMIT_LINE_DIRECTIVES` | environment / `driver.lua` | unset / true | Exact environment value `1`, or `titanc --no-line-directives`, disables generated Titan `#line` directives for physical generated-C diagnostics; this can omit ordinary native Titan frames from logical tracebacks. |
| `options.source_roots` | `titanc` / `driver.defaultloader` | every CLI module name | Requires explicit build roots to come from flat/folder source while all dependencies remain binary-first; selected source descriptors also provide `program_output`. |
| `titan._loadlib` | `ltitanlib.c` / `driver.lua` | internal `RTLD_LAZY` + `RTLD_LOCAL` loader | Maps DSO candidates lazily for callable ABI/type interface recovery without initializing them or globalizing their symbols; archive candidates are parsed in-process instead. |
| `titan._loadlibglobal` | `ltitanlib.c` / generated shims | internal canonical-path `RTLD_LAZY` + `RTLD_GLOBAL` loader | Maps or promotes a Lua-selected provider in a separate per-state cache and returns the requested logical `luaopen_*` entry. |
| `Type.Module.file` | `types.lua`, `driver.lua`, `coder.lua` | exact logical `.so` path for a DSO claim, overwritten after dynamic lookup | Transient selected relative DSO used by generated handle imports; deliberately omitted from serialized interfaces and never populated with an archive path. |
| `driver.LUA_SOURCE_PATH` | `driver.lua` | `<root>/src/lua-5.5.1` installed; `lua-5.5.1/src` in checkout mode; checkout-only override by `titanc --lua` | Lua internal source/header tree used at compile time. Installed mode rejects the override because `INSTALL_PATHS` supplies its matching `liblua.a` and `libtitan.a`. |
| `driver.INCLUDE_PATH` | `driver.lua` | `<root>/include` in installed mode | Titan SDK and bundled-libuv headers used by generated C and foreign imports; the non-Lua Titan set is `minicoro.h`, `titan.h` and `titan/ffi.h`. Generated source-foreign companions are source-build intermediates, not installed SDK headers. |
| `driver.TITAN_RUNTIME_PATH` / `driver.LIBBACKTRACE_PATH` | `driver.lua` | `titan-runtime/` / `libbacktrace` | Checkout-only runtime source/archive/header and separate libbacktrace locations. |
| `CC` / `driver.CC` | environment / `driver.lua` | `"cc"` | C compiler command, parsed as shell words and shared with foreign-import probing. |
| `CLANG_FORMAT` / `driver.CLANG_FORMAT` | environment / `driver.lua` | `"clang-format"` | Formatter command used only by `titanc --pretty-print`, then parsed as shell words. The driver appends its in-place operation, fixed explicit style with include sorting disabled, and generated-source path; default builds neither parse nor invoke it. |
| `driver.CFLAGS` | `driver.lua` | `"--std=c99 -O2 -Wall -fPIC -g -fno-optimize-sibling-calls"` | Flags for every compile and link step. |
| `TITAN_EXTRA_CPPFLAGS` / `driver.EXTRA_CPPFLAGS` | environment / `driver.lua` | empty | Parsed `-I`/`-D` and other preprocessing inputs; used by foreign-import compiler probes and prepended to every Titan/runtime/entrypoint compilation. |
| `TITAN_EXTRA_CFLAGS` / `driver.EXTRA_CFLAGS` | environment / `driver.lua` | empty | Parsed compilation-only flags, after fixed defaults; never used by final links. |
| `TITAN_EXTRA_LDFLAGS` / `driver.EXTRA_LDFLAGS` | environment / `driver.lua` | empty | Parsed ordered linker inputs appended to final module and program links. |
| shared-library flags | `shared_flag()` | `-shared`; on Darwin `-shared -undefined dynamic_lookup` | Platform from `driver.UNAME` (output of `uname`). |
| installed link set | `driver.installed_link_inputs` / `append_runtime_libraries` | installed runtime-SDK `libtitan.a` + separate `libbacktrace.a` + `liblua.a` + platform libraries | Used by provider DSOs and programs; Linux adds `-ldl`, and all platforms add `-lm`. These common final inputs are not copied into package archives. The standard build separately supplies bundled libuv as `-X` payload to both `titan.so` and `titan.a`; system mode keeps explicit pkg-config link flags at final link. |
| checkout link set | `driver.source_link_inputs` / `append_runtime_libraries` | local `libtitan.a` + separate local `libbacktrace.a` + local `liblua.a` + `-ldl -lm` | Preserves the writable source-development path while using the same archive contract; it never links `titan.o` directly. |
| `TITAN_ROOT_DEFAULT` / `TITAN_LUA_CPATH_SUFFIX` | `titan.h`/`titan.c` | `/usr/local` / `/lib/lua/5.5/?.so` | Legacy run-time root fallback and exact template suffix used for root discovery. |
| `titan_init_paths` | generated standalone entrypoint / `titan.c` | root parsed from inherited `package.cpath` | Caches the root and Titan module path and ensures `<root>/lib/titan/0.24/?.so` is in `package.cpath`; prefix-configured Titan-owned Lua has it first by default. |
| registry keys | `titan.h` | `TITAN_ROOT_KEY`, `TITAN_PATH_KEY`, `TITAN_LIBS_KEY`, `TITAN_MAIN_BOOTSTRAP_KEY`, `TITAN_MAIN_ARGC_KEY`, `TITAN_MAIN_ARGV_KEY`, `TITAN_BT_STATE_KEY`, `TITAN_BACKTRACE_KEY`, `TITAN_NAMES_KEY`, `TITAN_TRACE_PINNED`, `TITAN_TRACE_APPEND_KEY` (UUID strings) | Per-state caches and hooks: Titan SDK/rocks-tree root, module path, dlopen handles, optional standalone bootstrap, original process arguments and libuv's possibly replaced `argv`, registry-owned libbacktrace state, last raw backtrace, native-frame display names, re-raise traceback pin, and coroutine traceback append handoff. |
| generated ABI symbol | `coder.lua` | `<mangled>_abi` returning `TITAN_VER` | Checked before DSO type rehydration and before run-time dynamic-import `dlsym`; the same value is embedded in static metadata and compared during paired validation. Markerless compiled modules are incompatible. |

The pieces upstream of the driver are described in
[the type checker](checker.md) (which calls the loader) and the
[code generator overview](codegen-overview.md) (which produces what the
driver compiles); the contents of the runtime archive's callers — the
generated `_init`, standalone path initialization, and Lua entry wrappers that
ensure `errorhandler` is active —
are in [Lua interop internals](lua-interop-internals.md).
