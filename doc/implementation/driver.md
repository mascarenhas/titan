# Driver and toolchain

This chapter covers everything from resolving source/compiled modules through
producing a `.so`/`.a` pair or executable: `titan-compiler/driver.lua` (module
lookup, the import loader, the language-server compiler API, C compilation and
linking), the `titanc` command-line front end, the small utility module the
whole compiler leans on (`util.lua`), and the C runtime-support library in
`titan-runtime/`. Reference tables of every `titanc` flag, environment
variable and default path close the chapter.

Unless a Windows section or row says otherwise, native output paths, paired
providers, archive selection, and static Lua linking below describe Linux and
macOS. Windows uses DLL-only Titan providers and the controlled Lua import
library; see [Windows application launchers](windows-build.md#windows-application-launchers)
and the [Windows build guide](windows-build.md).

## Module names and the search paths

Module lookup deals in dot-separated **module names**, never file paths.
Every component matches `[A-Za-z_][A-Za-z0-9_-]*`; this is checked before
source/binary lookup, code generation, generated-shim planning, and static
metadata acceptance. The alphabet is exactly what the native protocol can
turn into a portable C identifier after its established dash-to-underscore
mangling, and it keeps template metacharacters such as `$` out of generated
symbol names. The validator also rejects a dotted logical name whose final
component is `titan`: import syntax reserves that terminal spelling as the
explicit-source marker. Bare `titan` and a nonterminal `titan` component remain
valid. The reservation applies only to logical module keys. A physical provider
prefix derived from valid roots may end in that component, so
`pkg.titan.left` and `pkg.titan.right` can share `pkg/titan.so` and
`pkg/titan.a`.
Binary lookup maps a logical name to every shallow-to-exact provider
candidate: for `a.b.c`, those are `a.so`, `a/b.so`, and `a/b/c.so`, plus the
corresponding `.a` names (`driver.module_compiled_candidates`). It runs one
complete format pass at a time (`.so` then `.a`, swapped by `--static`),
walking search roots from left to right and candidates from shallowest to
exact within a pass. An earlier root's existing candidate occupies that
relative pathname for its format even when its metadata does not claim the
requested module. [Compiled-module candidate
search](multi-module-libraries.md#compiled-module-candidate-search) owns the
shadowing and claim rules; [Static compiled
modules](static-compiled-modules.md) owns the archive reader and the shared
invocation-wide resolver state.

Source lookup has a separate tagged resolver because a logical module may be
flat or a [folder module](folder-modules.md). In each source root it tests the
folder main `P/B.titan` before the flat `P.titan` and returns a `flat`,
`folder`, or `blocked` result; `nil` is only a clean miss, and a selected or
blocked result never falls through to another source form or later root.
[Tagged source resolution](folder-modules.md#tagged-source-resolution) owns the
order, contributor enumeration, and the constituent-privacy rule.

All modules, including the standard library, use the same two path strings:

* **`driver.TITAN_SOURCE_PATH`** — where `.titan` sources live. Default
  `"."`; `titanc --tree <root>` overrides it.
* **`driver.TITAN_BIN_PATH`** — where compiled provider `.so` and `.a` files
  live.
  `TITAN_PATH_0_6` wins over `TITAN_PATH`; with neither set, installed mode
  uses `".;" .. root .. "/lib/titan/0.6"`.

The compile-time path walk (`driver.expand_titan_bin_path`) expands `;;` with
the same "insert the ordinary default here" convention as the run-time loader
in `titan.c` `pushpath`, then skips empty separators.

Here and below, `root` is the Titan SDK/rocks-tree root, not the owner of the
Lua or LuaRocks installation. The Makefile's `PREFIX` owns Lua and LuaRocks;
`ROCKS_TREE` owns the Titan rock, SDK, and stdlib. The supported developer and
CI installation currently sets `ROCKS_TREE == PREFIX`, but that is a layout
policy rather than an inherent identity. The internal
`TITAN_ROCKS_ROOT` setting identifies `ROCKS_TREE` for installed-compiler
builds. Without that override, when the compiler is not
running from the Titan source checkout, the driver scans `package.cpath` from
left to right for the first literal template ending in
`/lib/titan/0.6/?.so` (`?.dll` on Windows), stripping that suffix. If none exists,
it repeats the scan for the ordinary `/lib/lua/5.5/?.so` template. Preferring
Titan's current version avoids selecting LuaRocks' prepended user-tree path;
other Titan versions and suffix lookalikes do not match. Lua-owned default paths
follow the ordinary equal-root layout; an explicit root override can select a
separate Unix rocks tree. The resulting Titan root selects the
matching `src/lua-5.5.1`, `include`, `lib/liblua.a`,
`lib/titan/0.6/libtitan.a`,
`lib/libbacktrace.a`, and every compiled Titan module, including `titan.test`
for native test executables. Bundled libuv headers
are staged under `include`, but its static archive remains a private
source-build input rather than part of the installed SDK. Checkout mode
deliberately retains the repository paths for compiler/runtime development.
Outside a checkout, failure to find that exact suffix becomes
`driver.INSTALLATION_ERROR` and stops compiler/toolchain use instead of
silently mixing installations.

The CLI's `--print-root` query calls the same
`driver.resolve_installation_root(package.cpath, TITAN_ROCKS_ROOT)` function
before creating a resolver or checking build options. It therefore reports the
normalized SDK root without a C toolchain or any C-probe/cache work, including
when compilation flags or `TITAN_JOBS` are invalid. Windows ordinary drive and
UNC paths retain the driver's normalized forward-separator spelling; explicit
extended paths retain their namespace and literal semantics. No installation
prefix is embedded in the query, compiler, Lua, or native provider. Its only
successful stdout is the root and one newline. Module names are rejected;
without `--print-root`, `--test-dir`, or `-c --c-source`, the CLI requires at
least one module name.

### Standalone startup path discovery

`driver.entrypoint_contents` embeds `titan-compiler/standalone_paths.lua` as a
built-in-only Lua chunk. After `luaL_openlibs` and before `titan_init_paths` or
any module initialization, the launcher supplies its executable
directory, library version, and registry keys. Linux uses `/proc/self/exe`,
macOS uses `_NSGetExecutablePath` plus `realpath`, and Windows uses
`GetModuleFileNameW` with UTF-8 conversion. None uses CWD or `argv[0]`.

For unset paths, the chunk probes `titanc --print-root`, then
`lua -e "io.write(package.cpath)"`, suppressing probe stderr and requiring a
successful exit. A root query must return one absolute root; the Lua fallback
scans exact current-Titan templates before Lua 5.5 templates. Missing commands,
failed queries, and unusable output fall back to the executable directory.
The selected root replaces only unset Lua package paths and seeds
`TITAN_ROOT_KEY` before ordinary runtime path initialization. An explicit
Lua C path with a recognized anchor remains the runtime root source.
Versioned environment variables retain precedence over unversioned variables;
empty explicit values are still overrides. When all three paths are explicit,
no probe runs. Lua's existing explicit-path and `;;` expansion is retained.
Windows also keeps adjacent bundle provider/shim paths after discovered paths,
so its DLL launcher can find the application's own provider. Its default Titan
path is `.;<root>/lib/titan/0.6;<exe-dir>/../lib/titan/0.6`. The chunk stores
that default under `TITAN_PATH_KEY`. When a Titan path variable is set, it
stores the selected value instead, with each `;;` replaced by that same default
the way `pushpath` substitutes it. An override such as
`<sdk>/lib/titan/0.6;;` therefore still reaches the launcher's own DLL, while a
value without `;;` replaces the default. When all three paths are explicit, the
chunk returns early: `pushpath` then expands `;;` against the executable-relative
root from `titan_win_push_root`, whose default names the same adjacent tree.
A Unix executable links its main module, so the chunk leaves the Titan path to
`pushpath`. Its root-only default, `.;<root>/lib/titan/0.6`, is the same for an
unset variable and for `;;`.

The chunk uses no compiler modules at runtime and embeds no build prefix.
Ordinary Lua hosts keep the existing `titan_init_paths` behavior.

### Standard-library modules and short imports

The standard library is a set of ordinary qualified logical modules published
together in the reserved physical provider pair `titan.so`/`titan.a`. The root
list, folder ensembles, native payload order, and installed layout live in
[Reserved `titan` and the standard-library
image](multi-module-libraries.md#reserved-titan-and-the-standard-library-image);
the Make and LuaRocks build lives in [Build and installation
responsibilities](build-script-audit.md). The driver gives these modules no
special lookup: they use the same compiled-format passes and source roots as
any other module. `titan.uv` is the public binding to the bundled libuv; see
the [binding reference](../language/standard-library-uv.md) and the [async
implementation](libuv-runtime.md).

For source convenience, the parser first removes one terminal explicit-source
marker, `.titan`, and then desugars the short standard-library imports before
module resolution (`titan-compiler/parser.lua` `standard_imports` and
`parser.normalize_import`): `import "async"`, for example, places
`titan.async` in the import AST exactly as `import "titan.async"` would. The
mapping covers `coroutine`, `uv`, `async`, `timer`, `io`, `fs`, `path`, `net`,
`ssl`, `url`, `http`, `websocket`, `os`, `peg`, `string`, `test`, `lua`,
`math`, `gc`, `iteration`, `reflect`, `sqlite3`, `json`, `protobuf`,
`transfer`, and `thread`; every other name is left unchanged. The driver,
checker, code generator, and runtime thus see only the qualified module name.
Each qualified name naturally produces its matching native symbols and Lua
entry point (`titan_async_*` and `luaopen_titan_async`, for example), so no
separate Lua alias is required and Lua's bare `coroutine` and `os` libraries
remain unrelated. The AST retains the marker only as
`TopLevelImport.source_required`; its `modname` is canonical. Thus `uv.titan`
and `titan.uv.titan` both carry `modname == "titan.uv"`, and no cache key,
dependency, symbol, output, or metadata entry includes the marker.

### Source vs compiled providers: the selection logic

Ordinary dependency resolution is **binary first**: the driver probes
the logical module's shallow-to-exact candidates on `TITAN_BIN_PATH`, recovers
the first validating interface, and does not inspect source timestamps. Only
when every candidate is absent or every existing ancestor is a clean metadata
nonclaim does it parse the first flat or folder source match. Source roots are
walked left to right; the folder-before-flat rule applies within each root,
rather than comparing one representation across all roots. This applies
equally to standard-library and application dependencies. In particular, a
stray `./titan/uv/uv.titan` folder does not capture `import "uv"` while an
installed compiled standard provider claims `titan.uv` on the binary path.

An explicit `.titan` import arrives as `request.kind == "source-import"` and
is source-required: the loader resolves it only through the tagged source
resolver, a clean miss is terminal, and it replaces a cached DSO/archive
selection without ever falling back to it. [Loader result and module
views](source-import-visibility.md#loader-result-and-module-views) owns this
request, the per-resolver projection guard (`check_used_compiled_interface`),
and the visibility it grants.

For an ordinary import, source privacy is evaluated only after the complete
binary-candidate miss. A requested nested flat file that is an immediate
constituent of its parent folder module returns `blocked` and stops source-root
traversal; it cannot be exposed by a later root. Any claiming child provider
still wins before this check for an ordinary import, and a genuine deeper child
folder wins before the constituent flat candidate in either mode.

An explicitly requested `titanc` root is another source-required case because
naming a root is a request to build it. `titanc` passes the complete requested-root set
as `options.source_roots`; each such module tries source first, even if a
binary for it was cached by an earlier import in the same compiler process.
If its source is absent, compilation fails rather than treating an existing
binary as an empty build root. Imports reached from that root remain binary
first. This is why one standard-library invocation can force all standard roots
through source even when a bootstrap or prior combined provider pair is
visible. Their internal imports resolve to the already selected source cache
entries and are linked statically into the replacement provider pair.

A `--test` invocation is the invocation-wide source-preference case. Its
resolver context sets `source_first`, making every dependency try the tagged source resolver
before compiled formats and retaining binary fallback only on a clean miss.
Generated `titan.test.runner` uses an in-memory ordinary source descriptor and
imports `titan.test` through its public `Case.new`/`run` API. The standard module
follows ordinary provider selection and is not substituted or rebuilt specially.
Source preference does not expose locals through ordinary imports. See
[Native test runner](test-runner.md).

The compiled branch runs complete format passes. A DSO candidate is probed
through the internal lazy/local `titan._loadlib` helper for its
`<mangled>_abi`/`<mangled>_types` pair; a successful dynamic claim stores the
selected relative pathname transiently in `Type.Module.file`. A static
candidate is scanned in-process for canonical object-section metadata; a
successful claim records the selected archive/provider but never places an
archive path in `Type.Module.file`. [Claim and terminal-error
states](multi-module-libraries.md#claim-and-terminal-error-states) owns the
claim protocol, and [Static compiled modules](static-compiled-modules.md) owns
archive validation, contextual owner recovery, and native-binding constraints.

A provider's `<mangled>_abi` marker must equal `TITAN_ABI_VERSION` before its
`<mangled>_types` is evaluated; a mismatch is terminal before native linking
begins. The marker, `TITAN_VERSION`, and the versioned search paths are defined
in [Compiled-module ABI](codegen-overview.md#compiled-module-abi); the
separate `<mangled>_layouts` protocol is in [Native nominal
storage](nominal-storage.md).

## The loader protocol

The checker does not know how to find modules. `checker.checkimport`
(and, through it, every `import` statement) calls a **loader** callback
with the protocol:

```
loader(modname, request)
    -> ok, moduletype_or_error_message, errors, import_info
```

On success `ok` is true, the second value is the dependency's
`Type.Module`, and the third is the (possibly empty) list of type errors
found while checking it. `import_info.kind` reports trusted source, dynamic, or
static provenance and may carry a source-generated foreign header. `request` is
normally nil; explicit `.titan` imports pass `kind == "source-import"`, while
compiled nominal-owner recovery uses its separate contextual request. On
failure `ok` is false and the second value is a message. See
[the type checker](checker.md) for the consumer side.

### `driver.new_resolver_context(options)`

A resolver context is the invocation-wide state shared by every loader call,
header request, and C probe of one compilation or analysis. `titanc` creates
one synchronous context per invocation; semantic clients create one per
analysis and close it with `driver.close_resolver_context`. Unknown option keys
are ignored. Callback options must be functions, and an invalid cache adapter,
embedded provider, I/O strategy, or include list raises while the context is
created.

| Option | Meaning |
| --- | --- |
| `io` | Compiler I/O strategy; defaults to `compiler_io.new_sync()`. See [Compiler I/O strategy](#compiler-io-strategy). |
| `output_root` | The `titanc --output` folder. Wraps `io:tmpname` so checking headers and transient probe payloads are reserved as `<output_root>/.titan-temporary-*`; persistent probe-cache destinations do not change. See [Output directory](output-directory.md). |
| `prefer_static` | `titanc --static`: run the archive pass before the DSO pass. |
| `source_first` | `--test` or `--source-first`: try source before compiled formats for every dependency, keeping compiled fallback on a clean miss. |
| `verbose`, `pretty_print` | Carry `-v` and `--pretty-print` into resolver-owned C-probe and checking-header work. |
| `extra_ffi_include_dirs` | Analysis-local include roots, normalized here and appended to a fresh C-probe toolchain descriptor without changing the process-global foreign-C configuration. |
| `cache_adapter`, `header_inputs`, `c_header_analysis` | Persistent cache callbacks, host-validated input observations, and the per-analysis header-validation token; see [Cache adapter and persistent payloads](#cache-adapter-and-persistent-payloads). |
| `embedded_interface_provider` | Trusted host ABI/type inventory; see [Embedded interface provider and target profile](#embedded-interface-provider-and-target-profile). |
| `analysis_only`, `completion`, `completion_closed_world`, `transient_caches` | Semantic-analysis modes; see [Analysis loader options](#analysis-loader-options) and [Completion](completion.md). |
| `source_process_trace`, `c_header_process_trace`, `c_probe_cache_trace`, `c_probe_semantic_trace`, `c_probe_execution_trace` | Best-effort observers; see [Observability callbacks](#observability-callbacks). |
| `jobs` | The invocation's local native job cap (`titanc` passes its resolved `--jobs`). Above one, ordinary checks of this resolver may batch body-phase acceptance C probes under that cap; absent or one keeps every probe synchronous. See [GNU Make jobserver participation](#gnu-make-jobserver-participation). |
| `frontend` | Path of the executing `titanc` script (`arg[0]`), or `"api"` when omitted; hashed into the `compiler` component of the incremental configuration certificate. |

Checkout/installation discovery and platform initialization do not perform
filesystem or subprocess work while `driver.lua` is loaded. Context creation
resolves the compiler layout through `context.io` (`driver.initialize_layout`);
`driver.configure_foreign_c(context)` later obtains `uname` and the target
profile through the same strategy. `titanc` explicitly creates the default
synchronous context before reading layout-dependent settings and configuring
foreign C.

`context.checked_source_modules` is an ordered dense list of modules actually
parsed and checked by that context. Cached source entries and serialized
interfaces are not appended. After each checked module is completely published
in `driver.imported` and `static_deps`, the loader appends its name and calls
`context.io:yield(modname)`. A Titan-backed strategy may suspend its own Task
there; the synchronous strategy (`titan-compiler/io.lua` `Sync:yield`) ignores
the argument and does nothing.

### `driver.defaultloader(static_deps, options)`

`defaultloader` uses three pieces of process state:

* **`driver.imported`** — a process-global cache keyed by logical module name.
  Source entries carry `{ kind = "source", ast, type, filename, native_output,
  source_files, program_output, deps, c_header_dependencies, headers,
  source_manifest }`; `source_manifest` is absent only when its serialization
  reports an error, and object-backed entries ([Object-backed source
  modules](incremental-compilation.md)) add `compiled`, `has_main`,
  `test_functions`, and `external_symbols`. DSO entries carry
  `{ kind = "dynamic", type, filename, relative, layouts, layout_inventory }`;
  archive entries carry `{ kind = "static", type, filename, relative,
  static_archive, static_provider, layouts, layout_inventory }`; trusted
  host-inventory entries carry `{ kind = "embedded", type, filename,
  embedded_provider }`. Tests and long-lived tools reset this cache together
  with `types.registry`.
* **`CIRCULAR_MARK`** — a unique sentinel stored before recursively checking a
  source module; encountering it reports `"circular reference to module"`.
* **the resolver context** — invocation-wide compiled-format preference,
  archive-scan cache, the optional copied embedded inventory, ordinary
  provenance, selected static providers,
  contextual type-only owner recovery and its metadata-only physical
  resolutions, native-binding constraints, and the finalized direct-name
  sets.

The loader's `options` table also seeds the resolver context: when
`options.context` is absent, `defaultloader` creates one from the same table.
Loader-owned options are:

* `context` — the shared [resolver context](#drivernew_resolver_contextoptions).
* `source_roots` — requested build roots, which are source-required (see
  [the selection logic](#source-vs-compiled-providers-the-selection-logic)).
  Under `--incremental`, requested roots are certified like any other source
  module; without `--incremental`, every source module is rebuilt.
* `source_overrides` — in-memory or pre-resolved source descriptors keyed by
  module name, such as `titanc`'s generated `titan.test.runner` or descriptors
  returned by `testroots.discover`; an override makes that module
  source-preferred.
* `incremental`, `test`, `coverage`, `output_root`, `c_parts`,
  `split_threshold` — [object-backed source reuse](incremental-compilation.md),
  test-owner flag policy (`context.codegen_policy`), [native
  coverage](native-coverage.md) instrumentation, [output
  routing](output-directory.md), and split-unit codegen policy.
* `plan_mode`, `imports_for`, `worker_plan` — [build
  coordinator](build-coordinator.md) closure planning and worker execution
  modes; see [Compiler-owned module builds](#compiler-owned-module-builds).
* `known_source_modules`, `cached_source_entries`, `cached_interfaces`,
  `cached_binary_interfaces` — semantic-client inputs; see [Analysis loader
  options](#analysis-loader-options).
* `after_source_check` is rejected; cooperative suspension uses the context
  checkpoint above. Recursive parents may still be mid-check, so abandoning a
  Task requires closing the resolver and discarding the attempt's
  `driver.imported`/`types.registry` state.

The closure proceeds in this order:

1. A contextual nominal-owner request first follows the exposing compiled
   interface's producer choice. A carried static or embedded owner is recovered
   from that same inventory; a DSO-carried owner is probed from that same DSO;
   otherwise a compiled lookup may recover type information without committing
   ordinary resolver state or selecting an archive. Each successful recovery
   also adds one metadata-only `context.contextual_resolutions` entry with
   logical owner, exposer, compiled kind, physical provider file, and whether
   ordinary lookup supplied a separate provider. It does not add the owner to
   `driver.imported` or select it for linking.
2. The loader derives `source_required` for command-line roots and explicit
   `.titan` requests, and `source_preferred` from that requirement, test mode's
   invocation-wide `source_first`, or a source override. A preferred source may
   replace a compiled cache entry; a required-source clean miss is terminal,
   while `source_first` retains the compiled cache/fallback on a clean miss.
3. A remaining cache hit returns its type and records the dependency. Otherwise
   a preferred lookup tries folder/flat source first. An ordinary lookup first
   consults a non-overlapping embedded inventory, then runs one complete
   compiled pass per format on `TITAN_BIN_PATH`—`.so` then `.a` by default,
   reversed by `prefer_static`—before its final source fallback on
   `TITAN_SOURCE_PATH`. Root-major, shallow-to-exact order and occupied relative-
   path shadowing are independent within each filesystem format.
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

The loader attempts source-interface serialization even when checking reports
errors: a body error need not prevent a valid declaration manifest. If
serialization fails, the checked entry is still published with its AST and
module type, while `source_manifest` remains absent. The loader returns
`true, module_type, errors, source_info`, adding a diagnostic at the canonical
main's `1:1` location that names the module and serializer failure. Ordinary
imports propagate this diagnostic with the existing checker errors, and CLI
compilation stops before code generation. Semantic clients can publish these
diagnostics but must exclude the failed module from reusable interface and
project caches; absence of a source manifest is not an analyzer failure. A
fresh analysis resets `driver.imported` and `types.registry` as usual and can
retry serialization after the underlying problem is fixed.

An embedded hit is described under [Embedded interface provider and target
profile](#embedded-interface-provider-and-target-profile). For a DSO hit,
`find_dynamic_interface` uses
`titan._loadlib(path, symbol)` to map each existing candidate with
`RTLD_LAZY | RTLD_LOCAL`, probe the requested callable pair, and validate a
claim. For an archive hit, `find_static_interface` parses the complete regular
archive and its ELF/Mach-O metadata sections in-process, validates every
member and interface, and returns only the requested key. Both paths evaluate
the serialized type expression in the `types` constructor environment and
require a canonical `Type.Module` for the logical name. See [the complete
claim rules](multi-module-libraries.md#claim-and-terminal-error-states).

Each source entry's `deps` stores direct dependencies that are already native
inputs—source or selected static—regardless of which contributor declared
the import. The loader's `static_deps` argument retains this compatibility
view for embedding callers and test helpers. Production `titanc` instead
finalizes the shared resolver context after all roots are checked, deriving
`native_static_names` as every invocation source name plus every logical key
physically carried by the deduplicated selected archives. It passes that
complete set to every `coder.generate` call and passes the selected archives
once to native linking.

Finalization also filters `context.contextual_resolutions` against the final
compiled exposer selection. The exposer's physical file must still match the
one observed during checking. A carried owner must share that provider; an
ordinary-fallback owner may retain its separately resolved provider. This keeps
simple nominal aliases whose canonical registry nodes do not replay recovery,
while dropping provisional metadata made obsolete by a later source-root or
provider selection. Long-lived semantic clients read the filtered table only
after successful finalization and use it for cache graph edges, not native link
inputs.

`coder.generate` binds source and selected static names directly through
`extern` symbols and DSO-selected dependencies through the handle-scoped
provider protocol (`titan_module_provider`/`titan_module_symbol`); each
importer retains the resolved pointers in its own per-state module payload
([Static vs dynamic dependency
wiring](codegen-overview.md#static-vs-dynamic-dependency-wiring)). Generated
`_types` functions persist none of this provenance or the transient DSO path.
Folder layout does not add a loader protocol; the relevant filesystem options
are `source_roots` and the shared resolver `context`.

#### Interface recovery and the closed validator

Every compiled or cached serialized interface (DSO `_types`, archive metadata,
embedded inventory entries, and cached interfaces) enters through
`driver.decode_module_interface(serialized, modname, origin)`. It loads the
text as one Lua chunk in the `types` constructor environment, so the payload
can only call `Type.*` constructors, and requires exactly one returned value.
It then resolves compiled C references (`types.resolve_compiled_c_references`)
and runs `driver.validate_module_interface(modtype, modname)`, which returns
`nil, message` on the first violation.

The validator is closed: it rejects what it does not recognize. It requires a
valid logical module name; a non-local `Type.Module` whose `name`, `prefix`
(`<mangled>_`), and `file` (the slash path plus `.so`) are canonical for the
requested name; and no compiler-only source state (`_source`,
`source_members`, `source_type_members`, `_source_foreign_includes`,
`_source_c_context`). Member lists must be dense. Every value and type member
is walked by `validate_interface_type` with per-shape validators
(`validate_record_interface`, `validate_union_interface`,
`validate_declared_interface`, `validate_callable_descriptor`,
`validate_function_scheme`, `validate_generic_alias`). Local alias projections
and generic applications are then checked against their owners and
constraints (`driver._validate_metadata_generic_application`). A final
`types.serialize` call is the recursive schema walk that catches unknown tags
and missing nested fields while this candidate is still the diagnostic subject.

Feature-specific rules live in the validators named above. A callable may
carry a `flexrettype` that is a valid vararg element
(`types.valid_varg_element`); record and union constructors reject any
`flexrettype`. Interfaces are accepted only as direct `Module.type_members`,
with owner/key, public locality, the canonical nonempty ordered Method
projection, parameter-name metadata, and every value-facing signature component
checked before the checker registers them ([Interfaces](interfaces.md#separate-compilation-and-schema-validation)).
The serialized form itself is described in [Lua entries and ABI, type, and
layout metadata](codegen-overview.md#lua-entries-and-abi-type-and-layout-metadata).
A source entry's `source_manifest` uses a different encoder,
`titan-compiler/sourceinterface.lua` (`version.SOURCE_INTERFACE_FORMAT`,
`titan-source-interface-v2`): the public `types.serialize` text plus a
closed-schema source delta and header inputs (`file`, `search`, and `origin`).

### `driver.tableloader(modtable, imported, deps, options)`

The in-memory variant used by the spec suite: module sources come from
the `modtable` table instead of the filesystem (filename is faked as
`"./" .. modname .. ".titan"`), and the caller supplies the `imported`
cache (and optionally the `deps` set) explicitly. After a successful check, it
retains both the trusted raw `source_type` and a public `type` round-tripped
through `types.serialize` and `load`, exactly like the `.so` path. Ordinary
calls receive the public projection by default. `options.interface == "source"`
or an explicit `source-import` request receives the raw source view plus trusted
source provenance; only the request can grant an import AST local visibility.
Source-required replacement follows the same rules as `defaultloader`
([Loader result and module
views](source-import-visibility.md#loader-result-and-module-views)). The round
trip exposes drift between the serializer and the constructor schema.
It deliberately remains a flat one-string-per-module loader. Source folders,
privacy blocks, and contributor enumeration belong only to
`defaultloader`; neither tests nor embeddings acquire a synthetic source-unit
AST shape.

## Language-server compiler API

[Caret-specific completion analysis](completion.md) extends this boundary with
disposable source transforms, checker-produced candidates, detached scalar facts
and closed captured dependency catalogs.

`driver.LANGUAGE_SERVER_API_VERSION` identifies the exact compiler contract
for long-lived semantic clients. It remains **1 until Titan's first public
release**; prerelease compiler and language-server changes move together without
bumping this marker. It is independent from `driver.TITAN_ABI_VERSION` (`"2"`)
and persisted cache/record schema versions owned in `titan-compiler/version.lua`
(`OBJECT_RECORD_SCHEMA`, `TITAN_LINK_RECORD_SCHEMA`, `TITAN_NATIVE_RECORD_SCHEMA`,
`C_HEADER_CACHE_VERSION = 8`, `PROJECT_CACHE_VERSION = 6`,
`SOURCE_INTERFACE_FORMAT = "titan-source-interface-v2"`). A client must reject
an absent, noninteger, or different marker before invoking these options.

The contract includes parser/checker source metadata, analysis-local FFI include
roots, transient checked ASTs, compact declared manifests, serialized interfaces,
known-source identities, exact
`c_header_dependencies`, and `driver.restat_c_header_dependencies`, including
stable changed identities for ordinary deleted or unreadable inputs. Analysis
source/provider discovery, compiler probes, external topology resolution, and
C-header restatting all use the exact strategy stored in the resolver context.
The context owns cooperative `yield` checkpoints and the ordered
`checked_source_modules` publication list described with
[`driver.new_resolver_context`](#drivernew_resolver_contextoptions), whose
option table lists every context option.

The subsections below are the complete compiler-side contract, in order: the
embedded interface provider, declared project manifests, the cache adapter and
its persistent payloads, observability callbacks, the compiler I/O strategy,
analysis loader options, C-header dependency closures, and the two
metadata-only helpers.

### Embedded interface provider and target profile

The optional trusted-host `embedded_interface_provider` supplies one inventory. The driver
validates and decodes its closed ABI/type inventory when that raw provider
identity is first used, consults it before filesystem compiled providers, and
reports the host executable as stable binary provenance. The inventory is
analysis-only: `provider_file` is trusted provenance which the driver does not
stat, open, or otherwise inspect; the executable never becomes a native link
input.

An optional `target_profile` extends that analysis-only provider.
It is declarative numeric metadata exported by `csemantics.export_profile`
from the exact build SDK/toolchain. `csemantics.import_profile` validates the
closed versioned schema and identity, reconstructs canonical scalar descriptors
and their lowering traits, and rejects embedded interfaces whose numeric
metadata disagrees before publishing the provider snapshot. Every context gets
its own profile and descriptor graph; caller mutation cannot change an accepted
snapshot. Source-overlap rejection discards the complete provider, including
its profile, so a source-selected project keeps ordinary target selection. If
the build profile was consumed before a late overlap, the resolver verifies
the live target agrees before checking can continue; it rejects an unavailable
or different target instead of retaining mixed numeric conversion traits.

`driver.get_target_profile(context)` uses this trusted build target for pure
semantic decisions without opening SDK headers or invoking a C compiler.
The checker's `target_profile_provider` is separate from its native
`probe_service_provider`: native header processing and compile probes still use
`driver.get_probe_service(context)`, which acquires the live toolchain profile
and requires it to agree with the declared target. Missing native prerequisites
remain errors. Omitting the profile preserves ordinary driver/checker behavior.

`options.embedded_interface_provider` has the closed schema
`{ provider_file = <absolute path>, entries = { [module] = { abi, types } },
target_profile = <optional exported profile data> }`
(`validate_embedded_interface_provider` in `driver.lua`). The provider and
every entry must be plain tables with no extra fields; logical names, ABI
strings, serialized `Type.Module` graphs, and native symbol-prefix uniqueness
are validated eagerly. The driver copies the inventory and retains no
caller-owned entry table. A successfully validated raw provider table is a
trusted immutable snapshot: reusing the same table identity uses a weak-keyed
validated cache, so later mutation of that raw table is unsupported and is not
observed. Every resolver context still receives a distinct provider object and
cloned decoded type graphs; resolver-local rebinding or annotation therefore
cannot leak across contexts. A distinct raw table identity is validated and
decoded independently.

Before cache reuse, the loader reconciles the process-global cache with
the resolver's embedded inventory. It removes embedded entries owned by a
different resolver/provider object; when the current closed inventory remains
active, it evicts cached DSO/archive entries for every carried logical name and
clears every carried name from the supplied `static_deps` map, including names
whose cached import entry was already pruned. Cached source provenance instead
rejects the complete embedded inventory and remains selected. An embedded hit
carries `kind = "embedded"` and the trusted absolute `provider_file`; no
filesystem or dynamic-loader operation occurs.

Selected embedded entries and their carried contextual owners are replayed at
finalization like a static provider's interface closure, but remain outside
`static_deps`, `selected_static_providers`, `native_static_names`, native
bindings, and linker arguments. A source identity discovered after an embedded
entry was selected rejects the whole inventory and re-resolves every earlier
selection through ordinary disk providers before source checking continues.

### Declared project manifests

Compiler-owned declared manifests preserve reusable analysis semantics. The
embedding owns its database, transactions, file/provider validation, and
publication policy; the ordinary compiler has no database dependency. A clean
project module retains its declared public and source-only surfaces, owner
registry, provenance, direct dependency names and ordered source imports.
Checked ASTs, bodies, lowered types and plans, declaration back-references,
source text, and CPP graphs are not part of this representation. Hosts extract
and store editor facts separately before releasing each checked AST.

* `driver.compact_project_entry(entry, options)` returns a detached analysis
  entry or `nil, error`. It projects a successful checked source entry through
  the closed declaration schema shared with C-header manifests. Recursive and
  shared semantic types, generic binders and constraints, local declarations,
  C field shapes and extents, and numeric traits survive; unknown compiler
  annotations do not. The owned registry includes this module's owners and the
  owner closure reached from its interface, excluding unrelated process state.
  Iterative traversal retains strong identity memoization across cooperative
  yields and garbage collection. The returned entry has `_analysis_manifest =
  true` and no `ast` field.
* `driver.encode_project_entry(entry, options)` accepts a checked or compact
  source entry and returns a binary Lua string or `nil, error`. It uses the same
  projection before the literal graph codec preserves declaration sharing,
  cycles, exact numeric forms and binary strings. Generated C environments
  contain only validated include plans, ordered dependency plans and input
  provenance; function bodies and full generated `.titan.h` text are excluded.
* `driver.decode_project_entry(bytes, options)` returns a private compact entry
  or `nil, error`. It checks graph, project-cache, release/library and ABI
  versions, then validates the closed declaration schema, source capability,
  hybrid member maps, optional `module_name`, and generated C plan identities,
  digests and dependency order. Old AST payloads and unknown fields are misses.
  Optional `header_inputs` overlays matching current host-validated observation
  records without changing semantic identity; unmatched records remain.
  Decode never executes Lua, registers types, changes `driver.imported`, or
  performs filesystem I/O. Hosts validate all saved file/provider inputs before
  supplying entries to `cached_source_entries`.
* `driver.project_entries_registry(entries, options)` returns a fresh declared
  owner map for checked or compact project entries. A project's own entry wins
  over imported owner views, and entries with no owners add none. The host
  installs this map as `types.registry` while holding its compiler permit.
  Preparation and decoding do not publish state. Entries are independent
  payloads, so a host can preserve a clean row while rebuilding the registry
  from the complete current entry set. Projection, encoding, decoding and
  registry assembly cooperate through `options.yield` and propagate
  cancellation objects unchanged.
* `driver.language_server_cache_identity({context = context})` returns an
  opaque digest or `nil, error`. It includes API, graph, release/library/ABI,
  conversion and target identities, working directory, compiler command, and
  the actual preprocessor argv/include-root/predefined-macro/forced-header
  world. Call it once per saved analysis before reading project payloads. A
  verified embedded profile allows a distinct native-unavailable identity
  when no SDK is installed. Hosts additionally fingerprint the loaded compiler
  and native-module files, embedded provider, configuration, source roots and
  semantic schema. The generated-code ABI alone is not a cache namespace.

### Cache adapter and persistent payloads

`options.cache_adapter` on a resolver context supplies dot callbacks
`get(kind, key)` and optional `put(kind, key, bytes, inputs)` and
`refresh_inputs(kind, key, inputs)`. Reads return a binary string or a miss,
optionally followed by current input metadata. A nil second result means legacy
or unavailable metadata; an empty array represents a known empty closure.
Writes return success. `inputs` is a dense ordered array of
`{kind, path, identity, observation?}`, where `kind` is `"file"`, `"search"`,
or `"origin"`. An observation has `precision` (`"ns"` or `"coarse"`), integer
`size`, integer `modified_seconds`, integer `modified_nanoseconds` in
`[0, 1000000000)`, optional integer `changed_seconds` and `changed_nanoseconds`
(`ctime`), and a `physical_identity` string; it is validation metadata, never
part of semantic/cache-key equality.
String transport exceptions and bad payloads degrade to ordinary compilation;
non-string exceptions preserve the cancellation object's identity. Callbacks
may suspend through the host's compiler boundary. Read-only clients omit both
write callbacks; saved indexing can stage completed writes and commit them
with its own snapshot transaction.

`refresh_inputs` changes only observation metadata for an existing key; hosts
need not rewrite its potentially large semantic BLOB. Header restore uses the
second `get` result only when the complete ordered kind/path/identity list
matches the decoded manifest. FFI replay binds declarations to the current
combined include descriptor and its freshly validated input closure. A legacy byte-only adapter can omit these
additions: a same-content touch then re-encodes the existing graph once without
preprocessing, parsing, conversion or source checking.

Project encode/decode options and the cache adapter also accept an optional
`sha256_binary(bytes)` dot callback returning exactly 32 binary SHA-256 bytes.
Embeddings can use a synchronous native digest implementation for large graph
payloads; omission retains the dependency-free Lua implementation. The callback
must hash the supplied complete string, including embedded NUL/high bytes,
without changing compiler state. Its output uses the same wire checksum as the
fallback, so payloads remain readable in either mode and the graph wire
format is unchanged. Invalid results and string errors are cache misses; non-string
exception objects propagate unchanged through the graph boundary. Required
header content hashing also uses this callback when available; a broken string
result/error falls back to the ordinary Lua digest, while cancellation propagates.

A **digest-only** adapter supplies `sha256_binary` alone, with no `get`, `put`,
`refresh_inputs`, or `yield` (`titan-compiler/cacheadapter.lua` `validate`);
`titanc` passes this shape. It offers no storage, so storage work is gated on the
actual capability (`cacheadapter.can_get`, `cacheadapter.can_put`), never on
adapter presence. Header-cache restoration and observation refresh require
`get`, header and FFI-conversion stores require `put`, and
`checker/declarations.lua` builds an FFI conversion key and encodes its graph
only when `get` exists. The digest still reaches first-load C-header identities
(including forced-header scans), header revalidation, and the C-probe cache's
result and baseline keys (`cprobe.Service:_digest`). Those keys keep the
lowercase hexadecimal spelling of the pure-Lua digest, so probe-cache entries
are shared between native and pure-Lua compilations.

The `c-header-v8` payload (`c-parser/cdriver.lua` `HEADER_CACHE_VERSION`, set
from `version.C_HEADER_CACHE_VERSION = 8`) stores the closed
extracted-declaration graph described in [FFI
internals](ffi-internals.md#checker-rules); it excludes CPP macro environments,
token/spacing sidecars, body definitions, and parser records. Fresh processing
projects the completed header once; disk restoration performs one
schema-checked reconstruction. The process cache then retains and returns the
same immutable declaration object across resolver contexts and analysis
tokens, with no projection or deep copy on a live hit. Checker conversion
creates separate Titan types.

A disk miss runs ordinary preprocessing, parsing and declaration extraction.
Before accepting a disk hit, the compiler revalidates every recorded `file`,
`search`, and `origin` input (`cpp.revalidate_header_input`). The fourth `put`
argument carries the reusable header's dependency and search tails; the
caller's forced-header/top-level search prefix is reconstructed for every
request. A saved `file` content digest (`c-header-file-v3:sha256:<hex>`) is
reused from metadata without reading only when both the saved/baseline
observation and current observation declare `precision == "ns"`, include valid
`changed_seconds` (`ctime`), and match in every field (`size`, `modified_*`,
`changed_*`, and `physical_identity`), and the path remains `readable`.
Strategies that report `time_precision = "coarse"` (the LuaFileSystem fallback
used when the native `titan` support library is unavailable) always read the
file once per validation pass, guarding before and after the read with
physical observations and hashing the bytes; synchronous `titanc` normally
reads native nanosecond observations and takes the metadata path. Equal
content refreshes observation metadata without invalidating
declarations. `origin` inputs (`c-header-origin-v1;real=<realpath>`) are
re-resolved via `realpath` on every validation pass, even when `file`
observations take the `"ns"` fast path. Missing or malformed legacy
observations take a fresh read once.

Forced `-include`/`-imacros` preprocessing contexts remain local to the active
I/O provider. Subsequent preprocessing needs their mutable macro/output state,
so they are not persisted through the C-header adapter. A fresh provider
rescans forced inputs and performs its native macro probe before considering
extracted header-cache entries. Repeated use with the same provider validates
the complete file/search closure and clones its mutable context. Changes to
ordered flags, macros, selection or physical inputs rebuild that context;
failed scans or probes publish none.

The `ffi-conversion-v8` payload (`titan-compiler/foreigncache.lua` `KIND`)
stores one module-wide namespace's final converted C module; its contents and
replay are described in [FFI internals](ffi-internals.md#checker-rules). Its
key includes module/source identity, the combined header graph key, complete
observed C inputs, and the live target profile; importer body bytes are
independent. Final C validation uses the current combined environment after
replay, and writes report their complete observed input closure in the fourth
`put` argument. Generated physical checking paths never become reusable input
authority: generated header descriptors contain immutable include plans whose
contents, dependency order and recorded digests project restoration validates,
and owned generated paths, including relative `..` components in nested
includes, never become durable file inputs.

The graph codec bounds bytes, strings, nodes and edges, checks its version and
SHA-256 integrity, and allocates table references before restoring edges. The
general codec supports CPP sidecars for transient compiler uses; persistent
project, C-header and FFI payloads project through their closed declaration
schemas and do not contain them. Functions, userdata and threads are
unsupported. Corrupt, truncated, incompatible, nonliteral or structurally
invalid manifests are misses. Payloads are disposable implementation data,
not portable binary-module metadata. Project compaction and C definition
extraction omit compiler annotations and physical generated paths before the
codec runs. Project encode/decode/registry options and cache adapters accept
an optional zero-argument
`yield` callback. Graph edge/node/directory traversal and registry assembly
cooperate after at most 4096 logical work units, including large flat tables.
Native string operations and a supplied digest remain synchronous. Cancellation
objects propagate unchanged and no partly decoded graph is published.
`driver.compiler_cache_stats({context = context})` returns `headers` and
`conversion` counters; conversion has `lookups`, `hits`, `misses` and `stores`.
Header counters additionally include cumulative `file_reads`, `file_hashes`,
`metadata_reuses`, `search_checks`, `origin_checks`, and `memo_reuses` for that
I/O strategy.
Reads/hashes include preprocessing and forced-header work, not just cache
validation; graph checksums are separate. Clearing a process cache resets these
counters.
Use a fresh `c_header_analysis` token per saved analysis even when retaining
the same I/O strategy's process cache: an analysis token intentionally skips
repeat closure restats only within that one analysis.

Optional resolver `header_inputs` supplies the current host-validated input
observations for that analysis generation. The driver indexes them once by
kind/path/semantic identity (`cdriver.header_observation_index`), then uses
them as fresher baselines when retained project graphs still contain an earlier
timestamp. Validation always checks current filesystem metadata before reusing
the content identity; this baseline is separate from pass memoization and does
not mutate retained graphs. Hosts can pass the complete current owner-closure
union.

### Observability callbacks

`options.source_process_trace` is an optional best-effort observability
callback with the scalar signature
`(module_name, filename, outcome, self_cpu_ms, total_cpu_ms, parse_cpu_ms,
check_cpu_ms)`. Callbacks which consume only the original five arguments remain
valid because Lua ignores trailing arguments. The driver emits one event for
each source module it checks or rehydrates as a cached source entry. `outcome`
is `complete` or `failed`; all durations are process CPU milliseconds measured
with `os.clock`, so they exclude native child-process CPU and can include
process CPU consumed by other Tasks during cooperative I/O. `total_cpu_ms`
spans the whole module operation, including recursively checked source
dependencies. `self_cpu_ms` subtracts each direct source child's total, the
cooperative checkpoint following a completed child, and exactly the two
non-overlapping C-header terminal phases: `process_total` and
`downstream_ffi_conversion`. Header component phases such as preprocessing and
C parsing are already contained by `process_total`; they remain trace detail
and are not subtracted again.

`parse_cpu_ms` sums the direct `parser.parse` calls for every constituent of a
folder module. It includes a parser call which reports a syntax error, but is
zero for cached-source rehydration or a failure before parsing starts.
`check_cpu_ms` measures the direct `checker.check` call and subtracts source
children, post-child cooperative checkpoints, complete C-header processing,
and downstream FFI conversion which occur during that call; it is zero when
checking is not reached or a cached source entry is rehydrated. Both exclusive
components are clamped to zero. The remaining direct source-driver CPU can be
derived as `max(self_cpu_ms - parse_cpu_ms - check_cpu_ms, 0)`. The event is
emitted before the module's own cooperative checkpoint. The callback is
protected, so a tracing failure cannot change analysis, and an invariant or
cancellation which raises may omit this best-effort terminal event together
with the discarded analysis.

`options.c_probe_cache_trace` is an optional best-effort observability callback
with the scalar signature `(module_name, stage, hit, key, path)`. `module_name`
is the source module whose checker requested the probe, or the empty string for
a lookup outside a source check; `stage` is the C-probe stage; `hit` is a
boolean; `key` is the persistent result digest; and `path` is its absolute
pathname. The driver and C-probe service protect the callback, so a tracing
failure cannot change analysis. This callback is separate from verbose probe
evidence and never writes to stdout.

`options.c_probe_semantic_trace` is an optional best-effort callback receiving
one bounded event table for every logical probe request. Its scalar fields are
`event = "semantic_result"`, `module`, `key`, `probe_kind`,
`header_identity`, `header_label`, `outcome`, `cache_tier`, `repeated`, and
`publication`.
`key` is SHA-256 of the requested raw probe source, or empty when an early
infrastructure failure prevents rendering it. `header_identity` is
SHA-256 of its raw baseline source and serves only as an observation label.
`header_label` is a bounded display of the literal top-level include spellings.
Cache tiers are `service`, `analysis`, `persistent`, or `compiler`; outcomes
are `success`, `compiler_rejection`, or `infrastructure_failure`. The event
contains no source, command, argv, diagnostic, or filesystem path.

`options.c_probe_execution_trace` similarly receives one event per physical C
compiler launch. Its fields are `event = "compiler_execution"`, `module`,
`key`, `probe_kind`, `batch_kind`, `header_identity`, `header_label`, `outcome`,
`started`, `persistent_lookup`, `publication`, and optional `wall_ms`. The service
reports `batch_kind = "single"` for a synchronous launch and `"speculative"`
for a flushed probe-batch member.
`key` and `header_identity` have the same source-digest meanings as in the
semantic event. The I/O strategy may supply finite nonnegative child wall
milliseconds in its normalized `run` result; process CPU is never substituted.
Both structured callbacks are protected and may not change compilation when
they fail.

### Compiler I/O strategy

Every resolver context owns exactly one validated compiler-I/O strategy in
`context.io`. `options.io` supplies a table or userdata whose colon methods are
`cwd`, `realpath`, `stat`, `lstat`, `readable`, `read_file`, `write_file`,
`list`, `mkdir`, `unlink`, `rmdir`, `rename`, `tmpname`, `run`, and `yield`.
Omitting it constructs the canonical synchronous Lua implementation from
`titan-compiler/io.lua`, so ordinary compiler callers retain blocking behavior.
Missing or non-callable methods are rejected while the context is created.

The following is the complete normative language-server strategy contract. Signatures use Lua multiple-return notation. Every table that crosses
this boundary is an ordinary Lua table: implementations must not expose
backend-specific records, arrays, error objects, or task handles.

| Method | Result and contract |
| --- | --- |
| `cwd()` | `pathname, nil` or `nil, message`. Returns the process working directory as an absolute pathname without changing it. |
| `realpath(path)` | `pathname, nil` or `nil, message`. Returns an absolute existing path. POSIX resolves symbolic links; the synchronous Windows implementation normalizes the lexical spelling. |
| `stat(path)` | `metadata, nil`, `nil, nil` for a clean missing path, or `nil, message`. Follows the final symbolic link. |
| `lstat(path)` | The same result convention as `stat`, but describes the final symbolic link itself. |
| `readable(path)` | One boolean. `true` means the path can be opened for binary reading; absence, invalid input, and ordinary open failures are `false`. |
| `executable(path)` (optional) | `true`, `false`, or `nil, message`. Whether the current process may execute `path` under its effective user, groups, and ACLs; the synchronous POSIX strategy uses native `faccessat(AT_EACCESS, X_OK)` and neither opens nor reads the file. Tool selection (`incremental.physical_executable`) requires this capability on POSIX: a strategy without it, or an indeterminate `nil, message`, fails selection closed rather than guessing from mode bits or readability. |
| `executable_search_cwd()` (optional, Windows) | `true`, `false`, or `nil, message`. Whether the native launcher searches the current directory for a bare executable name; the synchronous strategy asks `NeedCurrentDirectoryForExePathW`, the same policy libuv uses. Without a definite answer, a current-directory candidate that differs from the `PATH` candidate cannot be certified. |
| `read_file(path, max_bytes?)` | `bytes, nil` or `nil, message`. Without a bound, reads the complete file as a binary-safe Lua string. A bound must be a nonnegative integer; the method returns the complete file when its size is at most that bound, or exactly the first `max_bytes + 1` bytes when it is larger. This optional form lets bounded decoders detect overflow without materializing an unbounded replacement. |
| `write_file(path, bytes)` | `true, nil` or `nil, message`. Publishes only complete contents: an observer sees complete file contents. Windows replacement may briefly leave the destination absent between removal and rename. Failure and cancellation must not leak the strategy's sibling temporary. If cancellation races the final rename, the destination may contain either complete version. |
| `list(path)` | A dense one-based array of entry basenames, or `nil, message`. `.` and `..` are excluded and order is unspecified. |
| `mkdir(path, remove_if_cancelled?)` | `true, nil` or `nil, message`. Creates one directory; its parent must already exist. The optional ownership rule is described below. |
| `unlink(path, remove_if_cancelled?)` | `true, nil` or `nil, message`. Removes a non-directory path without following its final symbolic link. The optional ownership rule is described below. |
| `rmdir(path)` | `true, nil` or `nil, message`. Removes one empty directory. |
| `rename(from, to)` | `true, nil` or `nil, message`. Renames within the filesystem using the platform's replacement semantics. |
| `tmpname()` | `path, nil` or `nil, message`. On success `path` names an existing, process-unique, empty regular file owned by the caller. Ownership transfers only with the successful return; cancellation before that return must not leak the reservation. |
| `run(argv, options?)` | One normalized result table. `argv` is a nonempty dense array of strings, not a shell-fragment interface. `LANG` and `LC_ALL` are fixed to `C`. `options.stderr_to_stdout` defaults to `true`; when false, only stdout is captured and stderr remains on the compiler process's stderr. When `titanc` has bound its held output locks to the synchronous POSIX strategy, every child inherits those lock descriptors with the same command, environment, stderr, and status contract: `run` (and a serial `run_batch`) captures through `process.capture`, while a parallel `run_batch` launches its jobs through `jobs.launch` and `process.start_job` ([POSIX lock inheritance](build-coordinator.md#planned-worker-resolution-and-orphan-lifetime)). |
| `yield(module_name)` | No results. The cooperative post-module checkpoint receives the name of the module just checked; the synchronous implementation ignores it. |

`stat` and `lstat` metadata has the Lua-facing fields `kind`, `size`,
`mode`, `modified_seconds`, `modified_nanoseconds`, and `time_precision`,
plus optional `changed_seconds`, `changed_nanoseconds`, `device`, and `inode`.
The synchronous strategy uses the runtime's native `titan._stat_precise` when
the `titan` support library loads: its results also carry `precision = "ns"`,
integer `mtime_ns` and `ctime_ns`, and opaque `dev`/`ino` strings (POSIX
`st_dev`/`st_ino`; on Windows the volume serial number and `FileIdInfo` file
ID), copied into `device`/`inode`. On Windows they also carry
`windows_attributes`, the raw `FileAttributes` DWORD from the same
`FileBasicInfo` query. Without that library it falls back to
LuaFileSystem with `time_precision = "coarse"` and, on Windows, no
`device`/`inode`, because LuaFileSystem provides no useful Windows file
identity. Host strategies may supply `"ns"` observations of their own. When
present, `device` and `inode` form an opaque physical-file identity pair:
clients compare the pair only for equality and must not interpret either
component. `kind` is `file`, `directory`, `symlink`, or `other`;
`size` and the timestamps are integers, nanoseconds are in `[0, 1000000000)`,
and `mode` carries the POSIX file-type and permission bits used by
filesystem/header identity code.

`run` always supplies boolean `started` and `ok` plus a string `diagnostic`.
A completed process also supplies integer `status`, string `why` (`exit` or
`signal`), boolean `interrupted`, the reproducible quoted `command`, and binary
string `output`. Signal termination sets `interrupted`, uses the signal number
as `status`, and may additionally publish `signal` and `shell_status`. Argument
or spawn failures set `started == false`; capture or wait failures after a
successful launch retain `started == true`. Failures may omit fields that could
not be established. A normal zero exit is the only successful
result.

The optional `true` arguments on `unlink` and `mkdir` are ownership
markers, not general recursive-cleanup requests. The compiler passes
`unlink(path, true)` only for the existing empty regular file returned by its
immediately preceding `tmpname()` call, while it remains the sole owner. If
cancellation is delivered before, during, or with completion of that unlink,
the strategy must arrange for the reservation to be absent before its runtime
quiesces. After that unlink succeeds, the compiler may pass `mkdir(path, true)`
for the same unique, now-absent path. If the mkdir creates the directory but
the caller observes cancellation instead of success, the strategy must arrange
to remove that new empty directory before quiescence. A successful return
transfers directory ownership to the caller. Lua's ordinary one-argument
methods ignore these extra optional values, preserving synchronous `titanc`
behavior.

Every method may cooperatively suspend in an asynchronous implementation.
For contract-valid arguments, ordinary filesystem, subprocess, validation, and
platform failures are normalized to the return forms above; they are not
raised. Task cancellation is the exception: the strategy must propagate the
original cancellation object unchanged rather than turn it into an error
message or a `run` result. Any uncancelled cleanup work required by the
ownership rules remains rooted until it finishes. Callers must therefore close
or discard the resolver attempt after cancellation and must not reuse its
partially populated compiler state.

#### Optional probe-batch capability

`run_batch(commands, { jobs = N })` is optional, never a required strategy
method. `commands` is a dense array of argv arrays. It returns
`results, signal?`: `results` contains `run`-shaped tables in input order,
with stdout and stderr merged and the same fixed C locale; `signal`, when
present, is a caught POSIX INT/TERM/HUP number. Every launched child must be
reaped and strategy-owned temporaries removed before the call returns or
raises. Strategy cancellation propagates as the original object unchanged.
Ordinary checks consult this capability only when the effective probe cap
is above one, never for analysis or completion. Inherited stock batching
requires the strategy's resolved `run` to be stock too; a strategy overriding
`run` stays synchronous unless it explicitly supplies its own `run_batch`.
See [C probe batches](#parallel-generated-c-compilation) for the stock
transport and cleanup rules.

### Analysis loader options

These loader options serve semantic clients; ordinary `titanc` compilation
leaves them unset. `cached_binary_interfaces` belongs to closed completion
analysis and is described in [Completion](completion.md).

* `known_source_modules` is a validated `{[modname] = true}` identity set. It
  tells source/provider overlap planning which logical names belong to source
  without making any module dirty or retaining its AST. One overlap rejects the
  complete embedded inventory for that resolver context.
* `analysis_only = true` opts a resolver context into declaration-manifest
  reuse and suppresses generated source foreign-function `.titan.h` bodies.
  Fresh dirty modules are parsed and fully checked, retaining their source-level
  typed AST: applied generic expression types, written generic arguments and
  case bindings are not rewritten by runtime generic erasure. Declaration
  snapshots and their detached owner registry remain available for compact
  manifests and completion. Checking still performs semantic elaboration,
  validation and FFI dependency capture; this is not a parser-only mode.
  Native compilation leaves this option unset and receives the lowered AST
  required for code generation. Analysis ASTs are not code-generation input.
* `cached_source_entries` contains caller-certified clean `source` entries:
  either complete checked AST entries or compact declared manifests with a
  `Type.Module`, source filenames, dependency map, ordered source imports,
  exact C-header inputs and generated C include plan. Compact entries and
  source ASTs marked `_analysis_only` require an analysis-only resolver; native
  checking must obtain a lowered AST from a fresh check instead. The loader reuses entries only for non-dirty,
  non-`source_first` modules, restores ordered source dependency environments
  and materializes their small `.ffi.h` include plans without reparsing the
  clean module or regenerating `.titan.h` bodies. Dirty overrides and native
  source-first loads obtain fresh ASTs. Resolver-local physical header fields
  are rebound on reuse, so hosts serialize compiler access and discard an
  abandoned analysis state.
* `cached_interfaces` contains serialized `Type.Module` manifests plus source
  provenance, dependency-name lists, and the source module's exact
  `c_header_dependencies`, never an annotated AST. Ordinary imports decode this
  public view lazily. If a retained project entry has an explicit `.titan` edge to
  an external source, the cached source-file list instead gives the loader an
  exact transient reparse descriptor. This replaces a metadata-only entry even
  when an earlier ordinary import in the same analysis already decoded that
  public view; the external AST is not added to the caller's retained project
  cache.

### C-header dependency closures

Every successfully checked source entry also owns an ordered
`c_header_dependencies` array with three input kinds (`c-parser/cpp.lua` and
`c-parser/cdriver.lua`):

* `file`: a header read by the preprocessor, carrying content-only identity
  `c-header-file-v3:sha256:<hex>` (or
  `c-header-file-v3:unreadable:<search-identity>`) and an optional physical
  `observation`;
* `search`: a candidate path probed during ordered include lookup up to and
  including the winner, carrying
  `c-header-search-v2;exists=<yes|no>;kind=<followed-kind|missing>;open=<readable|unreadable>`;
  and
* `origin`: a real (non-generated) header whose lines reach parsed output and
  participate in `declaration_scope_resolver`, carrying
  `c-header-origin-v1;real=<realpath>` to certify its realpath-nominal C
  declaration scope separately from file bytes.

The checker unions the complete written/imported foreign-include set for that
module, deduplicates identical `kind .. "\0" .. path` entries in first-seen
order (so `file` and `origin` entries for the same header coexist), and rejects
conflicting identities from one check. Paths are absolute lookup spellings: a
relative candidate is prefixed with the captured process cwd and harmless
standalone `.` components are removed, but `..`, repeated separators, and
symbolic-link components remain untouched. Restat and generated C therefore
traverse the same lookup route; retargeting a symbolic link changes the
`search` or `origin` identity instead of leaving a cache entry pinned to its
former target. Configured `-imacros` and `-include` inputs are part of this
same per-module closure, including their transitive includes and every
candidate consulted to resolve a relative operand. Resolver-owned generated
`.ffi.h` trees are parsed by `cdriver` as the module C environment. Their
validated descriptors identify the generated text and nested dependency trees;
these compiler-owned inputs do not escape as restattable temporary paths. Exact
physical author headers, search candidates, and declaring origins still populate
the observed closure. The C probe baseline includes the same module `.ffi.h`
and supplies the authoritative compilation check.

### `driver.restat_c_header_dependencies(dependencies, options)`

This helper validates a previously published ordered dependency array (`file`,
`search`, and `origin` entries) and returns four values:
`inputs, nil, changed, classified`. `inputs` is the same kind/path sequence
with current identities and observations; `changed` is a boolean semantic-change
flag (including `false` when touch-only observation metadata changed over
identical content and origin); and `classified` is `nil` when `changed` is
`false`, or `"c-input <path>: <reason>"` for the first changed input, where
`<reason>` is `content`, `provenance`, `missing`, `unreadable`, `candidate`, or
`changed-during-read`. It does not parse Titan source, reparse a header, walk
an include directory, or mutate the dependency input.

Initial and revalidated header reads certify metadata before and after reading
the exact bytes. If a header's physical observation changes while it is being
read, `revalidate_header_input` returns a read-race error and
`driver.restat_c_header_dependencies` returns
`nil, "cannot fingerprint C header input '<path>': C header changed while it was read: <path>", true, "c-input <path>: changed-during-read"`.
Ordinary filesystem churn is data rather than a failure: if a former `file` was
deleted, replaced by another kind, or became unreadable, its refreshed entry
carries `c-header-file-v3:unreadable:<search-identity>` and classifies the
change as `missing` or `unreadable`. If a former `origin` cannot be resolved,
its refreshed entry carries `c-header-origin-v1;unresolved` with reason
`missing` or `unreadable`, and a resolved realpath change reports `provenance`.
Malformed dependency shapes or unknown kinds return `nil, message`.

The optional second argument may be a resolver context, an options table with
`context`, or an options table with `io`. The first two forms borrow the
caller's context; the last creates and closes a temporary resolver around that
strategy. `options.header_validation` defaults to `context.header_validation`
so all certifications in one resolver context share one validation pass per
invocation, memoizing checks by `kind .. "\0" .. path` and sharing
`context.file_digest`. Semantic hosts start a fresh `header_validation` table
at each filesystem validation boundary. Every header read, `lstat`/`stat`,
`realpath`, and `readable` check uses `context.io`.

### `driver.resolve_external_modules(requests, known_sources, options)`

This metadata-only helper resolves already-known external dependency names
without parsing source or retaining compiler entries. Its optional trailing
argument has the same direct-context, `{ context = ... }`, `{ io = ... }`, or
omitted forms as header restatting. A borrowed context remains caller-owned;
an internally created context is closed on both success and failure. Source
flat/folder stat and enumeration, compiled-provider occupancy, canonical roots,
and static archive bytes all use that context's strategy. An embedded result
reports `{ kind = "embedded", provider_file = <host executable> }` without
opening that path. Existing two-argument callers therefore retain the
synchronous default.

## Compiling one module: `driver.compile`

`driver.compile(modname, ast, sourcef, static_deps, verbose, options,
source_entry)` turns one checked logical-module AST into its ordered object
files: `<stem>.o` and, for a [split module](codegen-overview.md#translation-unit-parts),
`<stem>.part1.o` and so on. For a folder module, `sourcef` is its canonical main
and `ast` is the combined dense list; there is still one call. `options`
carries `nominal_layouts`, `pretty_print`, `coverage`, `coverage_backend`,
per-request `extra_compile_flags`, an optional `c_parts` override, the
test-only `split_threshold`, and `native_inputs` for alias preflight.
`source_entry` receives coverage metadata, `private_symbols`, and the ordered
`compiled_objects`. On success the call returns `true, nil, primary_object,
native_references, objects`.

1. **Select the runtime SDK.** Installed mode is read-only: it uses headers
   from `<root>/include` and the already-built
   `<root>/lib/titan/0.6/libtitan.a`.
   Checkout developer mode lazily rebuilds and later links the corresponding
   local archive (`check_runtime` in `driver.lua`), so edits to runtime support
   can be exercised without reinstalling:

   ```sh
   make --no-print-directory TITAN_RUNTIME_LUA_SOURCE_PATH=<lua source> \
     titan-runtime/libtitan.a
   ```

   `MAKE` selects the make command, and `TITAN_RUNTIME_PREBUILT=1` skips this
   rebuild. Both modes link `libtitan.a`; the driver never substitutes a direct
   `titan.o` link, and `driver.runtime_archive_members_are_exact` requires the
   archive to contain exactly `titan.o` and `minicoro.o`. The checkout
   freshness check covers `titan.c`, the reduced `minicoro.c`, and their
   runtime headers. Source callback edits rebuild their generated module
   objects instead.
2. **Prepare generated C headers.** `titanc` plans each source module's
   `.ffi.h` and, when it defines foreign functions, `.titan.h`. It rewrites
   checking-tree dependency edges to final absolute paths and validates every
   destination before writing any. Each header is written to a sibling stage,
   normalized and optionally formatted, then renamed into place before the
   first object is compiled (`driver.plan_foreign_headers` and
   `driver.write_foreign_header_plans`). `driver.compile` falls back to
   one-module planning unless the AST is already marked prepared, so direct
   programmatic callers still work. Folder headers
   live beside the canonical main, with no contributor-specific outputs. See
   [Foreign-function implementation](foreign-functions.md#generated-titanh-planning).
3. **Generate.** `coder.generate(modname, ast, static_deps, abi,
   emit_line_directives, options)` returns the
   [generated-module table](codegen-overview.md#translation-unit-parts):
   dense `parts` (part `i` has `index = i - 1`), an optional `private_header`,
   `private_symbols`, `direct_native_modules`, `native_bindings`, and
   `encoded_layouts`. The driver passes the effective part cap
   (`driver.effective_c_parts`: `options.c_parts`, then `TITAN_C_PARTS`, then
   `driver.default_c_parts`, which is 4 on Linux and 1 elsewhere), the
   threshold (`coder.DEFAULT_SPLIT_THRESHOLD` unless overridden), and the
   absolute `<stem>.priv.h` path for the parts'
   `#include`. The qualified `modname` controls the native prefix, registry
   identity, `_init`, `_abi`, `_types`, `luaopen_*`, and module-private `ℙ`
   symbols consistently. The `.titan.source` record stores `parts_version = 1`,
   the relative `parts` suffixes, the effective `c_parts`, `split_threshold`,
   the `.priv.h` suffix when split, and `private_symbols`.
4. **Plan outputs and certificate without writing** (`prepare_compile`). The
   stem is `sourcef:gsub("[.]titan$", "")`, **next to the flat source or folder
   main**, or the matching path below the output root with `titanc --output`
   (`driver.relocate_source_output`; see [Output directory](output-directory.md)).
   Part 0 is `<stem>.c`/`<stem>.o`, part `k` is `<stem>.part<k>.c`/`.o`, and a
   split module adds `<stem>.priv.h`. Contributors never receive generated C or
   object files. When the module splits, an existing `<stem>.priv.h` must be a
   regular file starting with `coder.PRIVATE_HEADER_MARKER`; otherwise the
   compile refuses to overwrite the user-owned path. An unrelated
   `<stem>.priv.h` is ignored when the module does not split.

   When `options.context` and `source_entry.source_certificate` are present,
   `prepare_compile` calls `driver.incremental_configuration(context)`,
   computes the producer self digests (`incremental.producer_digests` stored on
   `source_entry.interface_digests`), and builds `native.certificate` via
   `incremental.make_certificate` ([Object-backed source
   modules](incremental-compilation.md)). It also computes per-module test-owner
   flags via `driver.test_owner_flags(options.test, test_functions)`.

   The prior inventory names the only stale split files that may be deleted. It
   is read solely from the existing primary `<stem>.o`'s validated
   `object_metadata.parts` record: for each prior part `k >= 1`,
   `<stem>.part<k>.c`, `.o`, `.gcno`, and `.gcda`, plus an existing
   marker-owned `<stem>.priv.h`. No companion manifest file is written and no
   directory is scanned, so an unrecorded file such as `<stem>.part99.c` is
   never touched. The plan's outputs are the private header, every new part's
   C, object, `.gcno`, `.gcda`, and compile temporary, every prior-inventory
   path, and the module's generated headers and their staging files. Its inputs
   are the source constituents, C header dependencies, and `native_inputs`.

   Primary object metadata is read in binary mode here (the prior inventory)
   and wherever else the driver reads compiled objects, including the Windows
   link-interface lookup at link time: UCRT text reads can truncate a COFF
   object at byte `0x1A`. Ordinary source/header text I/O retains its existing
   text-mode semantics.
5. **Preflight.** Before any invalidation or write, `driver.compile`
   validates the plan with `driver.validate_provider_output_paths`: an
   existing output must be a regular non-link file, and no output may alias
   another output or an input (normalized path, symlink-resolved path,
   case-folded path, or the same existing file through a hard link) or nest
   below one. It then records the module's public `external_symbols` and its
   `private_symbols` with `driver.record_module_symbols`. The CLI does the same
   for the whole link set first; see
   [batch planning](#batch-planning-drivercompile_modules).
6. **Materialize** (`plan.materialize`). This first writes the module's
   generated headers, but only when `prepare_compile` planned them itself: its
   caller passed no header plan for the module, and at least one of the
   module's two headers was not yet written by
   `driver.write_foreign_header_plans` in this process. Absent such an earlier
   write, that is a direct `driver.compile` or `driver.compile_module` call, or
   a programmatic `driver.plan_compile_requests` or `driver.compile_modules`
   call without a `header_plans` entry for the module. `titanc` plans the
   headers of every source module it compiles (`driver.plan_foreign_headers`),
   passes those plans to batch planning, and writes them itself, so under the
   CLI materialize never writes a header. Materialize then invalidates: unless
   `options.staged` is set (in a build worker, whose coordinator already
   retired the primary object before dispatch), it removes `<stem>.o` (the
   commit marker), then removes `<stem>.c`, `<stem>.gcda`, `<stem>.gcno`, and
   every prior-inventory path. It writes `<stem>.priv.h` for a split module and
   each part's C file, unlinking the old file first and appending the
   `.titan.source` record to part 0. Each file is normalized in place and
   optionally formatted with `--pretty-print`. Formatting failure aborts before
   its object is compiled but retains the raw or partially formatted `.c` as a
   diagnostic artifact. Coverage mode converts each part's markers and then
   appends the record to part 0 ([native
   coverage](native-coverage.md#selection-and-object-ownership)).
7. **Compile.** Each part's C is compiled with `driver.generated_compile_prefix()`
   (the parsed `driver.CC`, `driver.CFLAGS`, normalized compile extras from
   `TITAN_EXTRA_CPPFLAGS`/`TITAN_EXTRA_CFLAGS` and CLI `-I`/`-D`/`--cflag`, and
   trailing SDK `-I` include roots), followed by `driver.test_owner_flags` and
   per-request `extra_compile_flags`. When the resulting
   command enables LTO and names no seed, the driver appends a stable seed so
   archive bytes stay reproducible: `-frandom-seed=<modname>` for an unsplit
   module, and `-frandom-seed=<modname>.part<k>` for every part of a split
   module, part 0 included. Each object goes to a sibling temporary that is
   renamed into place only at publication. A direct `driver.compile` call runs
   every part command in part order, even after one fails, so all diagnostics
   appear. `titanc` instead plans and materializes every source module first
   ([batch planning](#batch-planning-drivercompile_modules)); then
   `driver.compile_modules` runs only these independent object commands, in
   order with `--jobs 1` and concurrently with the default four jobs or any
   larger bound, as described in [Parallel generated-C
   compilation](#parallel-generated-c-compilation).

   A representative part command:

   ```sh
   cc --std=c99 -O3 -Wall -Wno-unused-but-set-variable -Wno-unused-function \
      -fPIC -g1 -flto=auto -ffat-lto-objects \
      -I <root>/include -I <root>/src/lua-5.5.1 \
      -frandom-seed=foo.bar -c foo/bar.c -o <sibling temporary>
   ```

   These command examples show Linux defaults. Both GCC and Clang use
   `-O3 -flto=auto -ffat-lto-objects` there, retaining native object sections for
   metadata loading while enabling LTO. Other platforms, including macOS,
   use `-O3` without the two LTO options. Compilation and final links share
   those defaults; an explicit LTO opt-out requires `-fno-lto` in both
   `TITAN_EXTRA_CFLAGS` and `TITAN_EXTRA_LDFLAGS`.

   Checkout mode substitutes `titan-runtime`, `lua-5.5.1/src`, and
   `libbacktrace` include paths. Production debug defaults retain function names
   and `#line` file/line attribution without local-variable debug information:
   GCC uses `-g1`; Clang uses `-gline-tables-only -fdebug-info-for-profiling`.
   The profiling option keeps the ordinary function records that Clang's line
   tables alone can omit. A lazy, header-free predefined-macro probe identifies
   the configured compiler command, with `__clang__` taking precedence over
   `__GNUC__` (`select_platform_defaults`). Other compilers conservatively
   retain `-g`. Explicit `CFLAGS` remain caller-owned. The validation build
   profile (`TITAN_BUILD_PROFILE=validation`) uses `-O0 -fno-lto -g` for all
   compiler families; any value other than `production` or `validation` is a
   toolchain configuration error.
   A later `-g` in `TITAN_EXTRA_CFLAGS` restores debugger information; use the
   same override in `TITAN_EXTRA_LDFLAGS` for LTO links.
   Native test functions additionally receive
   `-fno-optimize-sibling-calls` to retain their tail frames. Sanitizer CI
   explicitly disables LTO so saved object functions can be compared with
   the generated-C diagnostic shadow.
8. **Publish** (`publish_compiled_object`). For a direct in-process compile,
   only when every part compiled, the driver renames the nonzero part objects
   into place from the highest index down and renames `<stem>.o` last, so the
   primary object is the module's commit marker. Any failure removes the
   primary object and every part temporary and part object. In a coordinator
   build (`build.run`), workers compile with `options.staged = true` and return
   their sibling temporary object paths in `result.staged`; the coordinator
   alone revalidates inputs and renames the parts and `<stem>.o` into place via
   `driver.publish_staged_module` ([Staged module publication
   order](build-coordinator.md#staged-module-publication-order)).

### Batch planning: `driver.compile_modules`

`driver.compile_module(modname, mod, static_deps, verbose, options)` remains the
single-module wrapper around `driver.compile` for programmatic callers. It
skips a module whose cache entry says `compiled` and records the produced
object list. `titanc` instead passes its ordered, logical-module/output-
deduplicated source set to `driver.plan_compile_requests` and then to
`driver.compile_modules`; planning asserts that same ownership invariant. Object
identity compares normalized absolute paths, physical spellings resolved from
the longest existing ancestor, portable case-folded spellings, and existing
device/inode pairs, so lexical, symlink, case, and hard-link aliases between
requests' primary objects are rejected before preparation.

`driver.plan_compile_requests(requests, verbose, native_inputs, symbol_owners,
header_plans)` runs steps 3–5 for every source request without writing
anything. Each source module is planned and generated with its own entry from
`header_plans`, so it does not plan a second copy of its headers. A request
whose module is already compiled contributes its recorded object list, source
files, and C header dependencies as inputs, plus its recorded symbols. The
inputs form one deduplicated list. All modules' public and
private symbols are recorded into a copy of `symbol_owners`, the inventory the
CLI has already filled from every carried or reused module, so two modules
that would define the same C symbol fail with `cannot link C symbol ...` before
any output changes. The generated and restored headers in `header_plans`, and
their staging files, join the outputs, and the whole set is checked once with
`driver.validate_provider_output_paths`. The returned plans carry the complete
`outputs` and `inputs`. This planning check applies to compile-only, library,
and program invocations alike. Program and library invocations then check
those exact outputs a second time, against the same input list, together with
their final outputs: a program (including a `--test` runner) with
`driver.validate_program_output_paths`, whose sixth `planned_outputs` argument
replaces the per-module estimate, and a library with
`driver.validate_provider_output_paths` over the provider and its Lua shims. A
compile-only (`-c`/`--compile-only`) invocation has no final output, so it
skips this second check. Only then does the CLI write every planned header, as
the batch's sole header writer, and call `driver.compile_modules(requests,
parallelism, verbose, plans)`, which plans the batch itself when no plans are
given. Each plan's `materialize` closure runs once and is then released,
dropping the generated C it held.

`driver.compile_modules` materializes every source plan in request order
before compiling anything; only the native object commands that follow ever
overlap. With a bound of one it runs each module's part commands in request
and part order. A larger bound flattens all prepared part jobs across all
modules into one worklist that launches the largest part first, by its
`code_bytes` cost estimate, with stable ties by module request index and then
part index ([Parallel generated-C
compilation](#parallel-generated-c-compilation)). Afterwards each module is
published separately (`publish_compiled_object`), with the same cache
mutation and per-module result order for every bound; a successful module's
cache entry records its primary object (`compiled`), the ordered
`compiled_objects`, its `private_symbols`, and native references. Every later
consumer, including program, provider, archive, validation, and coverage
links, receives each module's objects as part 0 followed by its other parts
(`driver.module_compiled_objects`).

The native-tool strings, and `CLANG_FORMAT` when `--pretty-print` actually
selects it, are parsed into dense argument arrays with a small shell-word grammar
supporting whitespace, single/double
quotes, and backslash escapes. Each command builder quotes every resulting word,
so spaces and shell metacharacters remain part of one argument rather than being
reinterpreted. A direct command ends in `os.execute`; batch transports are
described in [Parallel generated-C compilation](#parallel-generated-c-compilation).
Unterminated quotes, trailing escapes, NUL bytes, an empty configured command,
and non-dense programmatic argument arrays produce configuration errors.
A malformed `CLANG_FORMAT` is therefore inert in the default mode. `-v` writes
the same safely quoted compiler/linker commands—and any opted-in formatter
command—that are executed to standard error.

### Compiler-owned module builds

While `driver.compile_module` and `driver.compile_modules` remain available for
programmatic callers and `--print-ast`, ordinary `titanc` invocations delegate
module-graph discovery, certification, and parallel compilation to
`titan-compiler/build.lua` and `titan-compiler/build_worker.lua` (see
[Compiler-owned build coordinator](build-coordinator.md)). The driver exports
the following functions for the coordinator, workers, native inputs, and test
discovery:

| Function | Role |
| --- | --- |
| `driver.incremental_configuration(context)` | Installs `context.incremental_options` and computes/memoizes the invocation's `{ digest, compiler, preamble, toolchain, options }` certificate (`nil, err` on failure). |
| `driver.restore_source_object(context, modname, source, record, options?)` | Restores an accepted `.titan.source` record into `driver.imported` and `types.registry` without parsing or checking (`options.published` suppresses the `-v` hit line). |
| `driver.test_owner_flags(test_build, test_functions)` | Returns `test_runner.TEST_COMPILE_FLAGS` (`{"-fno-optimize-sibling-calls"}`) when `test_build` is true and `test_functions` is nonempty, else `{}`; shared by compilation and `codegen-options` certification. |
| `driver.resolve_source(context, modname, source_path?)` | Runs the tagged source resolver over `source_path` (default `driver.TITAN_SOURCE_PATH`), returning a `flat`, `folder`, or `blocked` descriptor, `nil` on a clean miss, or `nil, err`. Used by `titan-compiler/testroots.lua`. |
| `driver.resolution_plan(context)` | Closes a `plan_mode` loader and returns the authoritative `plan` (`modules`, topological/bytewise `order`, `linked`, `provider_file`, `digest`, `update`, `accepted`). |
| `driver.plan_descriptor(plan, modname)` | Projects `plan` into the closed `titan-build-worker-v1` table sent to `modname`'s worker, carrying accepted dependency `.o` paths and exact selected binary providers. |
| `driver.worker_configuration(context)` | Serializes driver paths/flags, resolver options, `codegen_policy`, and `context.incremental_configuration` as closed data for a worker. |
| `driver.new_worker_context(configuration, io_strategy)` | Reconstructs a worker's resolver context from `worker_configuration` and verifies `incremental.compiler_component` against the coordinator's `configuration.compiler` (failing with `compiler installation changed during build` on mismatch). |
| `driver.invalidate_source_object(context, modname, source)` | Coordinator pre-dispatch step: reads any existing `<stem>.o`'s validated `parts` list, unlinks `<stem>.o` first, and unlinks recorded `.part<k>.{o,c,gcno,gcda}` files. |
| `driver.compile_planned_module(context, modname, options)` | Worker entry: checks `modname` against `options.plan` (`worker_plan` loader mode, reporting `build plan divergence` on any discrepancy), writes generated headers and C files, compiles object parts to sibling temporaries (`staged = true`), and returns `{ modname, object, objects, staged, diagnostics }`. |
| `driver.publish_staged_module(context, result)` | Coordinator post-worker step: decodes the staged primary `.o`, resolves a fresh source descriptor, runs `incremental.revalidate_record` in a fresh pass, and renames sidecar `.part<k>.o` files then `<stem>.o` last. |
| `driver.apply_native_inputs(normalized)` | Installs `normalized.compile_argv` (`driver.NATIVE_COMPILE_FLAGS`) and `normalized.link_argv` (`driver.NATIVE_LINK_FLAGS`) from `nativeinputs.normalize`. |
| `driver.link_extra_flags()` | Returns `driver.NATIVE_LINK_FLAGS` when installed, else `driver.EXTRA_LDFLAGS` or `{}`. |
| `driver.native_link_backend(context)` | Returns `"darwin"` on macOS and `"none"` on Windows. On other Unix hosts it probes `<cc> -Wl,--dependency-file=<tmp> -Wl,--version` and returns `"gnu"`, `"lld"`, or `"none"`; the result is memoized per resolver context and persisted by `linkcertificate.linker_backend` in `<output>/.titan/linker-feature`, keyed by the compiler argv, link flags, toolchain identity, and physical compiler/linker identities. When the output tools are already uncertified (for example an opaque compiler prefix, whose final link is `uncacheable`), it returns `"none"`, the reason, and `"uncertified"` on every platform without probing, inventorying tools, reading or writing `linker-feature`, or memoizing the result. |
| `driver.windows_launcher_name(modname, override?)` | Validates the Windows launcher basename: the logical module name by default, or the `--exe` basename. Rejects separators, control and reserved characters, trailing dots/spaces, reserved DOS device names, and components over 255 UTF-16 units, then appends `.exe` when absent. |
| `driver.windows_program_paths(modname, exe, output_module, output_root)` | Computes Windows `.exe` launcher and `.dll` provider paths (`exe` overrides the default `<output>/bin/<logical>.exe`, appends `.exe` if absent, embeds the relative path from `<exe-dir>/../lib/titan/0.6` to the provider under `--output`, and rejects cross-volume paths). |
| `driver.publish_windows_provider(staged, destination, shim_plans, provider, before_commit?)` | Publishes a validated Windows provider DLL and its Lua shims via `windows_publication.publish`, invoking `before_commit` to invalidate the link certificate before the first public mutation. |

### Parallel generated-C compilation

Materialization (the `materialize` function of the plan that `prepare_compile`
in `driver.lua` returns) yields one record per logical module. Its ordered
`jobs` array holds the module's native compile commands, part 0 first. Each
job records its owning `module_index` (the module's request
index), `part_index`, C and object paths, sibling temporary object, argument
array, and `cost_bytes`, the generated byte count used as a deterministic
compile-cost estimate. `driver.run_prepared_compiles(prepared, parallelism,
verbose)` schedules such a list. Its pure helpers and the native batch
mechanism shared with provider links and C probe batches live in
`titan-compiler/jobs.lua`: the completion channel (`jobs.open_channel`,
`jobs.close_channel`), the background launcher (`jobs.launch`), the
non-throwing reaper (`jobs.reap`), and the launch/wait/reap/release loop
(`jobs.drive`). Compilation keeps only its own records, logs, replay and
publication:

1. It flattens every module's jobs and keeps each job's owner
   (`jobs.flatten`).
2. It launches the largest `cost_bytes` first. Ties keep module request order,
   then part order (`jobs.launch_order`).
3. It refills a slot as soon as any child reports completion, so completion
   order is independent of launch order.
4. After every child has been reaped, it replays each job's captured stdout and
   stderr to the compiler's stderr in module/part order, whatever the
   completion order was.
5. A module succeeds only when every one of its jobs succeeded. Its error and
   exit code are those of its first failing part, and every part's own result
   stays in the module result's `jobs` array (`jobs.summarize`). An ordinary
   compiler failure stops neither the module's remaining parts nor other
   modules' queued jobs.

The call returns one `{ok, err, code, jobs}` result per prepared module, in
input order, plus the number of an INT, TERM, or HUP signal that cancelled the
batch. It never publishes objects. `driver.compile_modules` publishes each
successful module and then re-raises that signal (`jobs.propagate`). A cancelled
batch fails every module, so no object is published before the signal is
delivered.

A one-job bound or a batch with only one job uses module/part order through
the direct command path. On POSIX, an explicit parent `make -j1` or an
unusable parent jobserver also selects that path.
Otherwise each child's stdout and stderr go to separate
temporary files so a blocked pipe cannot deadlock the batch. Windows launches
children through the stock LuaRocks `luv` process API, whose bundled libuv is
independent of the Titan stdlib libuv payload. On Linux and macOS the batch
requires the standard POSIX `mkfifo` utility. Each child is a `sh` wrapper that
runs the compiler in a subshell, then writes its batch index to one mode-`0600`
named FIFO and exits with the compiler's status. Both shells catch INT, TERM,
and HUP with a no-op trap (`trap :`, not an ignored signal), which `exec`
resets, so the compiler keeps its default actions. A signal sent to the whole
process group therefore cannot end a wrapper before its compiler has exited,
and reaping a wrapper proves the compiler's lifetime ended. The parent opens
the FIFO read/write, so it neither blocks before the first child nor sees a
transient EOF while a slot is refilled. It makes the Lua `FILE` unbuffered
before the first read, because it
polls the descriptor and stdio read-ahead could otherwise hold a completion
line that the kernel no longer reports. The parent then reaps exactly the child
that completed and frees its slot. A completion-channel failure stops new
launches, reaps every active wrapper directly in launch order without
waiting for further messages, and fails the unlaunched jobs rather than
risking a deadlock. Preparation failures do not launch a process. A schedule
position is each child's completion index.

The C probe service uses the same mechanism through the default compiler I/O
strategy's optional `run_batch(commands, { jobs = N })` capability
(`io.lua`). It launches each probe through `jobs.launch` with standard output
and error merged into one log, and returns `run`-shaped results in input order.
On POSIX its command text uses the same `env LANG=C LC_ALL=C` prefix as
`Sync:run`; Windows uses `platform.windows_process_command` and sets the
locale in the spawn environment. One ledger
(`jobs.open_slots(N, { guard = true })`) bounds each flush; a single granted
slot or a single command runs in order through `run`. Every exit, returned or
raised, reaps each launched child before its slot is released, closes the
ledger, and removes the completion channel and every log. On POSIX ledger
closure also returns every borrowed token and restores the signal actions.
Windows uses only the local cap, without POSIX signal capture or jobserver
tokens. An error raised by the
strategy's own `run`, `tmpname` or `read_file`, such as an injected
cancellation, stops further launches (`jobs.drive` returns it instead of
recording a launch failure) and is rethrown unchanged after that teardown;
the generated-C launcher keeps converting its own unexpected launch errors
into that job's failure. As for generated-C batches, a token-return, ledger,
completion-channel or log-removal failure, including one reported only while
tearing down, fails every command of the flush even when every child already
launched: a launched command keeps `started` and its captured output but no
exit status, so its result is non-semantic and is never published. The
caller re-raises a caught signal only after the service and header cleanup
([C FFI](c-ffi-expressions.md#speculative-batched-acceptance-probes)).

### GNU Make jobserver participation

The local cap is `titanc --jobs`, else `TITAN_JOBS`, else four. `titanc`
resolves it once; programmatic callers pass it as `parallelism`, and `titanc`
also passes it to `driver.new_resolver_context({ jobs = N })`, which bounds
that resolver's speculative C probe batches (`driver.probe_batch_jobs`
returns one, keeping probes synchronous, without a cap above one, under an
explicit serial POSIX `make -j1`, and for analysis or completion resolvers). Checking
finishes before generated-C compilation starts and nested modules flush their
batches one at a time, so probe and compiler children never share the budget
concurrently; each batch opens and closes its own ledger. A parent GNU
Make never raises it: a recipe running `titanc -j4` inside `make -j16` still
runs at most four C compilers. On Linux and macOS, `jobs.open_slots` reads the
inherited `MAKEFLAGS` (`jobs.make_policy`). Option words end at a standalone
`--`, GNU Make backslash escapes are honored, and the **last**
`--jobserver-auth=fifo:PATH`, `--jobserver-auth=R,W`, or legacy
`--jobserver-fds=R,W` wins. Without an authorization, an explicit `-j1` runs
serially; no `-j`, an unlimited `-j`, or no `MAKEFLAGS` at all uses the local
cap. A cap of one never opens the jobserver.

With a usable jobserver each running C compiler holds one slot:

- The first active job uses the implicit slot that Make granted the recipe.
  Titan never writes that slot back.
- Each additional simultaneously running job first borrows one token. The
  batch acquires it immediately before the launch, and the native client keeps
  the exact byte it read in a ledger.
- A failed launch frees its slot at once. Otherwise the slot is freed only
  after the child has been reaped, including after a compiler failure. Freeing
  a slot writes the most recently borrowed byte back whenever the ledger holds
  more than `max(active - 1, 0)` bytes, so the ledger always equals the number
  of borrowed slots and Make receives exactly the bytes it lent.
- Batch cleanup (`Slots:close`) returns every remaining byte on success,
  failure, and cancellation paths. Collecting or `<close>`-ing a native client
  also returns its bytes.

The native client (`titan-runtime/ltitanlib.c` `_jobserver_open`) uses private
open-file descriptions, never the inherited ones. A FIFO authorization is
opened twice, read-only and write-only, after checking that the path is a FIFO
and that both opens reach that channel. On Linux, a pipe authorization is
reopened through `/proc/self/fd/R` and `/proc/self/fd/W` after `fstat` proves
that both descriptors are one open pipe. Only these private descriptions become
nonblocking and close-on-exec; the descriptions Make shares with other recipes
keep their blocking mode. A token read that loses a race with another client
returns `EAGAIN`, and the batch waits again. `_jobserver_wait` polls the
unbuffered completion FIFO, the token descriptor (only while a launch is
waiting for a slot), and the signal wake pipe together. The batch therefore
never blocks in a token read while its own children can still finish, and two
recipes sharing `make -j2` each progress with their implicit slots. No helper
process reads tokens.

An advertised but unusable authorization—an unrecognized format, closed or
mismatched descriptors, a FIFO that cannot be opened, or GNU Make 4.4's
`-2,-2` marker when a recipe lacks `+`—prints one warning per process
(`warn_unusable`) and falls back to one job. When a valid inherited pipe
authorization (`--jobserver-auth=R,W` or `--jobserver-fds=R,W`) is encountered
on a non-Linux POSIX platform that cannot privately reopen pipe descriptions
(such as macOS's stock GNU Make 3.81), `_jobserver_open("pipe", R, W)` returns
`nil, reason, "unsupported"`, and `jobs.unshareable_pipe_limit` prints one
warning per process and retains `titanc`'s own local `--jobs`/`TITAN_JOBS` cap
outside the parent Make pool rather than mutating the parent's shared pipe
flags or serializing the build. Sharing a parent Make pool on macOS requires
GNU Make >= 4.4's FIFO jobserver (`gmake`). A Makefile that runs `titanc` must
mark the recipe with `+` and preserve `MAKEFLAGS` and jobserver descriptors
through any wrapper ([Make job
pool](build-script-audit.md#make-job-pool-and-titanc-recipes)). Windows uses
only the local cap, because MSYS2 Make's jobserver descriptors are not native
UCRT descriptors.

In coordinator builds (`build.run`), a single `jobs.open_slots` ledger is
shared by live worker frontends and coordinator-launched native jobs via
`Slots:token_descriptor()`, `Slots:signal_descriptor()`, and
`jobs.use_remote(session)`; see [Slot ledger and jobserver
rules](build-coordinator.md#slot-ledger-and-jobserver-rules).

On POSIX, a parallel batch installs a temporary INT/TERM/HUP action (`_signal_guard`)
that only records the first signal in a `sig_atomic_t` and writes a wake byte;
ignored signals stay ignored. The batch checks for a recorded signal before
every slot acquisition and launch, so a signal that arrives together with a
ready token or completion starts no further compiler. It then stops reading
completion messages and reaps its running wrappers directly, each after its
compiler has exited, freeing one slot per reaped wrapper. Finally it returns
every borrowed byte, restores the previous actions (including Lua's SIGINT
hook), and fails every module. Every path that closes the guard, including a
failed completion-channel setup, returns the recorded signal to the caller.
`driver.compile_modules` re-raises it under the restored action after
publication cleanup, so SIGINT surfaces as Lua's `interrupted!` error and
SIGTERM or SIGHUP terminates the process by its default action without the
CLI's remaining cleanup. Probe batches instead unwind through resolver/service
cleanup; their SIGINT exit is status 1 with
`C probe batch interrupted by signal 2`, while TERM/HUP take their default
action after cleanup; see [C FFI](c-ffi-expressions.md#speculative-batched-acceptance-probes).
A SIGKILL cannot be intercepted, and tokens a killed process held are not returned.

### Shared C preprocessor, compiler, and linker inputs

At driver initialization, `CC` defaults to `cc` (`clang.exe` on Windows) and
the three append-only environment variables (`TITAN_EXTRA_CPPFLAGS`,
`TITAN_EXTRA_CFLAGS`, `TITAN_EXTRA_LDFLAGS`) are tokenized with the shell-word
rules above. When `titanc` runs, `nativeinputs.normalize` and
`driver.apply_native_inputs` combine defaults, environment variables, and
repeatable CLI native switches in a single deterministic order
([Native inputs and `--c-source` nodes](build-coordinator.md#native-inputs-and---c-source-nodes)):

* **Compilation (`driver.generated_compile_prefix()`).** Starts with parsed
  `CC` and profile-selected `driver.CFLAGS`. When `driver.NATIVE_COMPILE_FLAGS`
  is installed (`titanc`), it appends `TITAN_EXTRA_CPPFLAGS`,
  `TITAN_EXTRA_CFLAGS`, and CLI `-I`/`--include-dir`, `-D`/`--define`, and
  `--cflag` options in exact command-line order, followed last by the fixed
  SDK/runtime `-I` directories (`driver.foreign_include_dirs()`, so user `-I`
  paths are searched before `<root>/include` and `<root>/src/lua-5.5.1`).
  Direct programmatic callers that do not call `driver.apply_native_inputs`
  keep `driver.EXTRA_CPPFLAGS` before `driver.CFLAGS` and `driver.EXTRA_CFLAGS`
  after it. The C parser, C probe service, preamble certification probe,
  generated module C, standalone entrypoints, and `--c-source` nodes all use
  this same prefix.
* **Linking (`driver.link_extra_flags()`).** Appends `TITAN_EXTRA_LDFLAGS`
  followed by CLI `-L`/`--library-dir`, `-l`/`--link` (comma lists expanded,
  repeats and interleaving preserved), and `--ldflag` options in exact
  command-line order after Titan's objects, archives, and runtime libraries on
  every provider, program, and standalone archive-probe link.

Both compile-flag channels may use GCC/Clang's separated or joined
`-imacros file`/`-imacrosfile` and `-include file`/`-includefile` spellings.
The checker preserves every occurrence and the compiler's effective ordering:
all `-imacros` operands first, then all `-include` operands, stable within each
class. In a joined spelling an initial `=` is part of the filename, matching
the compiler (`-include=file` requests the literal name `=file`). Relative
operands consult the process cwd and then the complete ordered quote/system
search. Their exact bytes, transitive closure, and all winning and earlier candidate states partition the
preprocessor macro cache. This dependency tracking belongs to C header parsing.

Compiled C probes use only SHA-256 of their complete unpreprocessed source as
the cache key. Include directives count as literal text; forced-header
contents, toolchain options, target profiles, and header search state do not.
Memory and disk reuse acceptance and rejection under that same key. Format 2
(`titan-compiler/cprobe_cache.lua` `VERSION`) stores one bounded result with
diagnostics and optional typed enum selection at
`<prefix>/var/cache/titan-probes/2/<digest>.result`, where `<prefix>` is
`TITAN_PREFIX` when set and otherwise the installation root. Clear that
directory or set `TITAN_PROBE_CACHE_DISABLE=1` to bypass persistent reuse if
external changes make results stale. Generated C is compiled normally. See
[compiled probe caching](c-ffi-expressions.md#analysis-local-and-persistent-semantic-results)
for record and failure handling.

Response-file arguments (`@file`) and opaque preprocessor forwarding through
`-Wp,` or `-Xpreprocessor` are rejected in this path: Titan cannot safely
discover a forced-header closure hidden inside those encodings. Missing or
unreadable forced headers are likewise configuration failures during header
processing.

A standalone entrypoint is therefore compiled to its own `.o` with both
extra compile flag sets, then linked in a separate command that contains
only the fixed defaults and extra linker flags. This prevents warning,
language, and code-generation-only options from leaking into the final
link while preserving feature macros for the generated entrypoint.

## Linking a provider pair

Library mode links the staged DSO with the same argv as
`driver.compile_library_output` and builds the matching self-describing `.a`
with the archive helpers described in [Static compiled
modules](static-compiled-modules.md#native-composition). Both artifacts contain
the same logical source/archive membership; the archive additionally preserves
metadata-free native `-X` payload byte-for-byte.

### `driver.compile_library_output`

`driver.compile_library_output(soname, libnames, link, verbose,
extra_objects, static_archives, ordered_payload, install_name, module_names)`
links an explicitly named DSO from the complete logical source-module object
union. `install_name` is the optional Darwin install name; `module_names` is
the logical inventory that Windows requires for its export file:

```sh
cc --std=c99 -O3 ... -fPIC -g1 -flto=auto -ffat-lto-objects -shared \
   -o app.so app_model.o app_view.o dep.o ... \
   [force-load selected-provider.a ...] \
   [ordered extra.o ... force-load native-payload.a ...] \
   <root>/lib/titan/0.6/libtitan.a <root>/lib/libbacktrace.a <root>/lib/liblua.a \
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

On Linux and macOS, `titanc` derives the public provider from the requested
roots and calls `driver.link_provider_pair`. That function links the DSO under
the public basename in a sibling staging directory, builds the staged regular
archive, and performs embedded/DSO/archive-backed protocol validation. Its step
order, job-slot use, and failure cleanup are described in [Provider link
pipeline](static-compiled-modules.md#provider-link-pipeline). A block-local
preparation step builds the link argv. It also records the post-link
obligations: removing the Windows `.def` file and running Darwin `dsymutil`.
`compile_library_output` runs that argv synchronously. The pipeline runs it as
a background native job and completes the same obligations after reaping.
`driver.link_failure_message` formats every link-failure diagnostic that
`titanc` and the pipeline report.

`driver.shared_library_flags` supplies `-shared`, plus `-undefined
dynamic_lookup` on Darwin and `-Wl,--exclude-all-symbols` on Windows. Windows
links also pass `-Xlinker --no-insert-timestamp` and a generated `.def` export
file (`driver.windows_provider_exports`). On Darwin `dsymutil` must succeed
before the bundle is valid, and preserving the DSO basename keeps the dSYM's
inner name correct. `titanc` also passes the eventual relative public provider
path as `install_name`; the driver forwards it as the `LC_ID_DYLIB` value
(`-install_name`) instead of allowing Darwin's linker to derive that identity
from the unique staging path. That public-provider link also uses Darwin's
`-reproducible` mode so its debug map does not encode volatile input-object
properties. For this staged-provider case, when `dsymutil` was certified,
the driver runs that pinned absolute `dsymutil` from the unique stage
directory with only the stable DSO leaf name; this keeps the dSYM's
relocation-map `binary-path` metadata independent of the transaction's random
directory, so an unchanged relink can retain byte-identical DSO, UUID, and
dSYM contents. An uncertified `dsymutil` instead runs as plain `dsymutil` from
the original working directory with the full output path, and its final link
is uncacheable, so no stable-metadata guarantee applies
([uncertified `dsymutil`](build-coordinator.md#recipe-file-digests-and-native-library-policy)).

Validation, the unchanged-bundle equivalence check, and the
`publish_provider_bundle` commit order (shims and dSYM, archive, then the DSO
as the commit point, with caught failures restoring the prior owned set) are
owned by [Three-way validation](static-compiled-modules.md#three-way-validation)
and [Publication and installation](static-compiled-modules.md#publication-and-installation);
generated shims are covered in [Validated publication and generated
shims](multi-module-libraries.md#validated-publication-and-generated-shims).
Provider-validation child Lua processes preserve the compiler's
`package.cpath`, so they can load the private bootstrap support image before a
canonical provider exists.

Ordinary UV clients import the [public compiled module](../language/standard-library-uv.md)
and do not foreign-import `uv.h`. The packaging loader fixture in
`spec/rockspec_spec.lua` deliberately exercises a different boundary: its
`provider_probe.c` includes `uv.h` and makes an unresolved native `uv_random`
call; its Titan source foreign-imports only the one-function
`provider_probe.h` and imports public `uv`. This is a native loader probe, not
an adapter recipe. Compiler inspection maps the DSO lazy/local; generated
runtime import maps its selected provider lazy/global, so standard-provider
initialization precedes the probe's native function call. Eager relocations and
native constructors still require provider loading before the probe DSO is
mapped. The bundled archive remains payload of `titan.so`/`titan.a`; the fixture
does not embed a second libuv instance.

## Linking a standalone program: `driver.compile_program`

`driver.compile_program(modname, libnames, link, verbose, extra_objects,
program_output, static_archives, entrypoint_output, program_name, options)`
produces an executable at the optional `program_output` path (or `options.exe`
when given), relative to the working directory. Omitting it preserves the
original `modname:gsub("[.]", "/")` default for programmatic callers and
`tableloader`. The trailing `static_archives` list contains selected
self-describing providers. The optional entrypoint path and display name let
`titanc` place synthetic runner and entrypoint files inside the target's
`.titan-links/<key>/synthetic/` directory without changing the logical main
identity. The optional `options` table carries `no_uv_bootstrap`,
`pretty_print`, `exe`, `final_link_flags` (the final-link certificate's linker
dependency-report flag, appended only to the final Unix executable link),
`before_commit` (invalidating the link certificate record before mutating
public outputs), `output_module`, `output_root`, `coverage_runtime`,
`module_names`, `archive_entries`, `archive_names`, and
`validate_titan_support`. On Windows, `compile_windows_program` stages both the
provider `.dll` and launcher `.exe`, validates the staged DLL in a fresh child
process, and publishes them as one recoverable set via
`windows_publication.publish_program` (committing the `.dll` before the `.exe`
after `before_commit`); staging cleanup failures and stale-stage retirement
are described in [Windows DLL publication](windows-build.md#windows-dll-publication).
Filesystem source descriptors cache:

| Form for `foo.bar` | `program_output` |
| --- | --- |
| flat | `foo/bar` |
| folder | `foo/bar__main` |

It first writes `<mod>__entrypoint.c` from `entrypoint_template` (rendered by
`driver.entrypoint_contents`) — a small srlua-derived C `main` — compiles it
with the normal extra compile flags, and then links its object with the same
object set as a library:

```sh
cc [TITAN_EXTRA_CPPFLAGS...] --std=c99 -O3 ... -fPIC -g1 -flto=auto -ffat-lto-objects \
   [TITAN_EXTRA_CFLAGS...] -I <root>/include -I <root>/src/lua-5.5.1 \
   -c foo/bar__entrypoint.c -o foo/bar__entrypoint.o
cc --std=c99 -O3 ... -fPIC -g1 -flto=auto -ffat-lto-objects -o foo/bar \
   foo/bar__entrypoint.o foo/bar.o ... \
   [selected-provider.a ...] [extra.o ...] \
   <root>/lib/titan/0.6/libtitan.a [selected-provider.a ...] \
   <root>/lib/libbacktrace.a \
   <root>/lib/liblua.a [-ldl] -lm [-lSDL2 ...] \
   [TITAN_EXTRA_LDFLAGS...]
```

The command above shows the flat default. A folder program changes only the
link output after `-o` to `foo/bar__main`. On ELF, selected providers first
receive an ordinary grouped search, then `-X` retains its established
standalone order, and a second group containing runtime `libtitan.a` plus the
providers resolves references in either direction; the remaining
runtime/platform/final inputs stay outside (`driver.standalone_native_link_inputs`).
Darwin's linker performs its continual archive search without those groups. No
selected provider or `-X` archive is force-loaded into an executable. The SDK
itself never supplies libuv: an executable carries the bundled libuv only when
it selects the standard `titan.a`, whose private payload includes it, and
extension DSOs leave their `uv_*` calls unresolved for the loaded provider.

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
  runs `titan_init_standalone_paths`: the embedded
  [startup path discovery](#standalone-startup-path-discovery) chunk, then
  `titan_init_paths` (see [the dynamic loader](#titanc-the-dynamic-loader)). It
  then registers the main module for `require` *without* loading it:

  ```c
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, $LUAOPEN_FN);
  lua_setfield(L, -2, "$MODNAME");
  ```

  The entrypoint registers no dependency itself. Generated module code takes
  over during initialization: after a module's `_init` completes successfully,
  its generated `<prefix>\u2119_register_preload` helper (`<prefix>ℙ_register_preload`
  in linkage spelling) calls `titan_module_preload`,
  which stores the module's `luaopen_<mangled>` function under its logical
  name in `registry[LUA_PRELOAD_TABLE]`, the table exposed as
  `package.preload`. Requiring the main module recursively initializes its
  imports, so that successfully initialized closure publishes itself. A
  private static import follows the same path. An unused or otherwise
  uninitialized linked module publishes nothing.

  It then pushes Titan's runtime `errorhandler` and runs `pmain` under
  `lua_pcall(L, 2, 1, -4)` with `argc` and `argv` as arguments; a
  failed pcall formats the still-available original error object and the
  captured raw traceback before exiting with `EXIT_FAILURE`. On success
  the integer returned by the Titan `main` becomes the **process exit status**:
  `ret = lua_tointeger(L, -1); lua_close(L); return ret;`.
* **`pmain`** first publishes the original `argc` integer and `argv` pointer
  under `TITAN_MAIN_ARGC_KEY` and `TITAN_MAIN_ARGV_KEY`, then calls global
  `require("$MODNAME")` and retrieves and retains that module's `main`
  callable. A transitive `titan.async` initialization calls the public
  idempotent `uv.setup_process_args()` helper, which passes only those
  original entrypoint values to `uv_setup_args` and replaces the private
  `argv` slot with the pointer returned by libuv. Importing `titan.uv` alone
  neither calls it nor installs a Task bootstrap; a low-level UV client can
  call the same helper explicitly, and an ordinary Lua host without the
  entrypoint registry contract receives false. After `require`, `pmain`
  rereads that pointer, creates the string-element Array writer closure
  (`titan_main_string_array_writer`), and builds an Array with that writer and
  capacity `argc - 1`. It copies `argv[i]` to logical index `i` only for
  `i = 1 .. argc-1`; the executable name is omitted. A Titan
  `main(args: {string}): integer` therefore sees `args[0] == nil`, `args[1]`
  as the first real argument, and `#args == argc - 1`. Requiring the main
  module first
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
  frame line through the Titan `main` frame. The report removes the synthetic
  bootstrap chunk prefix from the headline (`strip_bootstrap_prefix`) and omits
  bootstrap Lua/C frames after `main`. If no Titan trace was captured, it reports
  only the converted error message. Either way the process exits
  non-zero; see [Runtime trace model](error-handling.md#runtime-trace-model).

Mechanically, then, a standalone Titan program is an embedded Lua interpreter
whose entrypoint preloads only the compiled main module. `pmain`'s require of
that module performs the unchanged Titan initialization recursion; each module
publishes its loader only after its own successful `_init`. A later Lua require
of one of those initialized logical names calls its `luaopen_*` entry, recovers
the canonical registry module value, and applies the normal `package.loaded`
policy.

## The `titanc` command line

```sh
./titanc [--print-root] [--print-ast] [--pretty-print] [-v|--verbose] \
  [-j|--jobs <jobs>] [--c-parts <n>] [--exe <path>] [--static] \
  [--source-first] [--incremental] [-c|--compile-only] [--test] \
  [--test-dir <dir>]... [--test-exclude <module>]... \
  [--coverage [--coverage-backend <backend>] [--coverage-module <glob>]... \
    [--coverage-root <dir>] [--coverage-gcov <cmd>] \
    [--coverage-format <format>]... [--coverage-output <dir>] \
    [--coverage-gcovr <cmd>]] \
  [--no-uv-bootstrap] [--no-line-directives] [-u|--lua <luasrc>] \
  [-t|--tree <srcroot>] [-o|--output <dir>] \
  [-I|--include-dir <dir>]... [-D|--define <def>]... [--cflag <arg>]... \
  [-L|--library-dir <dir>]... [-l|--link <libs>]... [--ldflag <arg>]... \
  [--c-source <file>]... [--print-c-objects] \
  [-X|--extra-object <payload>...] [<module>...]
```

`titanc` (an `argparse` script at the repository root) takes dot-separated
module names, `--test-dir` discovery directories, or `-c --c-source` files; the
[flag table](#titanc-flags) lists every option and constraint. `--print-root`
prints the installation root and exits ([above](#module-names-and-the-search-paths)).
`--tree` overrides `driver.TITAN_SOURCE_PATH`. In source-checkout mode, `--lua`
overrides `driver.LUA_SOURCE_PATH`; installed mode rejects it so the installed
headers, `liblua.a`, and `libtitan.a` remain a matched SDK. `-o`/`--output`
routes generated files below one folder while preserving the source hierarchy
([Output directory](output-directory.md)). `--exe` sets the exact executable
output path relative to the current working directory on every platform
(appending `.exe` on Windows when absent while keeping the Windows provider DLL
under `--output` and embedding its relative path from `<exe-dir>/../lib/titan/0.6`).

`--pretty-print` opts every emitted C/header boundary into the fixed
`clang-format` pass; default builds do not invoke it. `-v` writes safely quoted
native-tool and formatter commands, replayed worker and native-job output, and
incremental certification decisions to standard error:
`Titan object hit <mod>: <object>`, `Titan object miss <mod>: <code>[ <detail>]`,
`Titan native hit <source>`, `Titan native miss <source>`,
`Titan link hit <target>`, and `Titan link miss <target>: <reason>`. Standard
output carries only requested results: the `--print-root` root, `--print-ast`
dumps, and `--print-c-objects` paths.
`--print-ast` runs the shared `build.plan` and output preflight, then checks
requested modules in-process and dumps each AST.
`-j`/`--jobs` sets the positive local job cap (overriding `TITAN_JOBS`, default
4), which bounds concurrent worker frontends, generated-C compilations, the
second provider link, and speculative C-probe batches ([GNU Make jobserver
participation](#gnu-make-jobserver-participation)). `--static` swaps the
compiled-provider passes to prefer self-describing archives before DSOs,
`--test` (with optional `--test-dir` and `--test-exclude`) selects the native
test pipeline ([Native test runner](test-runner.md)), and the `--coverage`
family instruments and reports native line coverage ([Native
coverage](native-coverage.md)).

Repeatable `-I`/`--include-dir`, `-D`/`--define`, and `--cflag` options append
to the normalized compile flags after `TITAN_EXTRA_CPPFLAGS`/`CFLAGS` and
before the SDK include roots. Repeatable `-L`/`--library-dir`, `-l`/`--link`
(comma-separated or repeated), and `--ldflag` options append to the normalized
link flags after `TITAN_EXTRA_LDFLAGS` in exact command-line order. Repeatable
`--c-source` options compile and certify C files into `<output>/.native/` with
the invocation's generated-C compile prefix and link their objects before
`-X`/`--extra-object` payloads. With `-c`, `--print-c-objects` writes the
absolute path of each certified object, one line per `--c-source` argument in
argument order, after the output locks are released. Native nodes are keyed by
canonical source path, so a moved checkout leaves the old nodes behind;
consumers that copy a node use the printed path instead of enumerating
`.native/`.

`--incremental` enables semantic certification for every source module in the
closure (including explicit command-line roots, both in full builds and with
`-c`), `--c-source` nodes, and final executable or provider links. Without
`--incremental`, every selected source module and `--c-source` node is rebuilt.
`-c`/`--compile-only` stops after object and header emission. See
[Object-backed source modules](incremental-compilation.md) and [Compiler-owned
build coordinator](build-coordinator.md).

Before creating a resolver, `titanc` rejects:

* `--print-root` with module names;
* no module names unless `--print-root`, `--test-dir`, or `-c --c-source` is
  given;
* `--incremental` with `--print-ast`;
* any `--coverage-*` option without `--coverage`;
* `--static` on Windows;
* `-c`/`--compile-only` with `--exe`, `-l`, `-L`, `--ldflag`, `-X`, or
  `--no-uv-bootstrap`;
* `--test-dir` or `--test-exclude` without `--test`, or `--test-exclude`
  without `--test-dir`;
* `--print-c-objects` without `-c` and at least one `--c-source`, or with
  `--print-root` or `--print-ast`; and
* a `--jobs`/`TITAN_JOBS` or `--c-parts`/`TITAN_C_PARTS` value that is not a
  positive integer.

After those preflight checks, `titanc` loads `require "titan"`, requires
`_sha256_binary`, creates its resolver context with `frontend = arg[0]`,
applies normalized native inputs, and discovers any `--test-dir` roots. It
locks the `--output` directory, or without `--output` every `--tree` source
root plus the working directory (source-adjacent objects may belong to any
root, and default providers and executables are CWD-relative), and adds the
`--exe` directory when given, all through `build.lock_outputs`. With
`--output` it then loads the
[persistent digest cache](incremental-compilation.md#persistent-digest-cache).
It runs `build.run`, whose coordinator-side pre-dispatch
[output preflight](build-coordinator.md#pre-dispatch-output-preflight)
rejects output collisions and graph-dependent option errors (`--exe` or
`--no-uv-bootstrap` without a standalone or test executable, `--coverage` on
library-only builds unless `-c` is given, multiple `main` roots, and library
roots without a common prefix) before any worker starts; each worker checks
the C headers its fresh module discovers against the same reservations before
writing generated module artifacts. `build.run`
certifies, compiles, and restores the module closure. `titanc` then compiles
any `--c-source` nodes via `nativeinputs.compile` and—for linking
invocations—gates runner/entrypoint synthesis, archive probing, and linking
with `linkcertificate.prepare`, `linkcertificate.check`,
`linkcertificate.invalidate`, and `linkcertificate.commit`. On Windows it
calls `driver.cleanup_stale_staging` between `prepare` and `check`
([End-to-end invocation sequence](build-coordinator.md#end-to-end-invocation-sequence)).
The digest cache is saved before the locks are released.

## Optional `clang-format` generated-source formatting

The coder builds C by pasting strings, with no C AST or in-process
pretty-printer. Presentation formatting is deliberately opt-in:
`titanc --pretty-print` invokes the parsed `CLANG_FORMAT` command (default
`clang-format`) in place on every emitted `.c`, `.ffi.h`, and `.titan.h` stage. The
default pipeline never parses, discovers, or invokes that tool. It persists the
valid raw template output instead.

The opted-in command supplies an explicit LLVM-based, four-space style and
disables include sorting rather than discovering an ambient project
`.clang-format`. Include order is intentional in generated module preambles and
generated headers: source dependencies precede direct foreign directives in
`.ffi.h`, and the module C environment precedes Titan-generated declarations.

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
* **`util.tostring(v)`** — recursively formats primitive values and nested
  tables (both array-like sequences and keyed maps) into canonical Lua-literal
  string representations; used by `types.serialize` for compound C-FFI type
  metadata (such as array lengths and bitfield tables).
* **`util.to_set`**, **`util.curry`**, **`util.any`** — small
  functional helpers (`to_set` in the C parser; `any` and `curry` only in the
  specs).

## The runtime support library: `titan-runtime/`

Every installed-mode compiled module and standalone program links
`<root>/lib/titan/0.6/libtitan.a`; checkout mode links
`titan-runtime/libtitan.a`. Neither mode links `titan.o` directly. Each archive
contains exactly the dynamic loader/error runtime `titan.o` and reduced
minicoro implementation/tag support `minicoro.o`. Source foreign callbacks
live in generated standard-module objects instead. Static-archive selection
pulls in only referenced objects. Vendored `libbacktrace.a` is a separate link
input. `ltitanlib.o` is also separate: it is the only input to the private
support bootstrap and is passed once as shared native payload when the
standard logical modules are published in the full `titan.so`/`titan.a` pair.
The private five-member LPegLabel archive follows it only in the standard
provider payload and is not part of the runtime SDK.
The staged non-Lua SDK headers under `<root>/include` are `minicoro.h`,
`titan.h`, `transfer.h`, `titan/ffi.h` (`Makefile` `TITAN_SDK_ROOT_HEADERS` and
`TITAN_SDK_NAMESPACED_HEADERS`), `llhttp.h`, and `sqlite3.h`. Bundled libuv also
installs `uv.h` and `uv/`; bundled OpenSSL installs the complete public
`openssl/` tree, combining ordinary source headers with generated configuration
headers. Reinstalling in the default system OpenSSL mode removes only the
bundled OpenSSL headers so subsequent OpenSSL checks use the system headers.
Checkout developer mode selects the corresponding local archive and headers so
runtime edits can be tested before reinstalling.

### `titan.h`

* **`TITAN_LIKELY(x)` / `TITAN_UNLIKELY(x)`** — `__builtin_expect`
  wrappers (plain parentheses off GCC/Clang); used on the hot/cold
  sides of generated type checks.
* **`TITAN_COLD`** — `__attribute__((cold))` (empty off GCC/Clang) on the
  abandoned-coroutine unwind helpers. It marks calls to them unlikely, which lets
  optimized builds place the calling blocks outside the hot instruction stream.
* **Constants** — the version and path constants (`TITAN_ABI_VERSION`,
  `TITAN_VERSION`, `TITAN_LIBRARY_VERSION`, `TITAN_LIBRARY_VERSION_SUFFIX`,
  `TITAN_PATH_VAR`; see [Compiled-module
  ABI](codegen-overview.md#compiled-module-abi)), `TITAN_PATH_SEP "/"`,
  `TITAN_ROOT_DEFAULT "/usr/local"`, `TITAN_LUA_CPATH_SUFFIX
  "/lib/lua/5.5/?.so"`, and `TITAN_LUAINTEGER_NBITS` for shift code
  generation. `titan.h` defines the loader's registry keys `TITAN_ROOT_KEY`,
  `TITAN_PATH_KEY`, `TITAN_LIBS_KEY`, `TITAN_BT_STATE_KEY`, and
  `TITAN_NAMES_KEY`; the trace, entrypoint, preload, and metatable keys are in
  `titan/ffi.h`. [The registry
  footprint](lua-interop-internals.md#the-registry-footprint) owns every key's
  role.
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
`titan.c`: `loadlib`, `loadsym`, `loadglobalsym`, `titan_module_provider`,
`titan_module_symbol`, the ABI/compatibility check helpers, and `errorhandler`.
Generated imports use `titan_check_module_abi` and
`titan_check_module_compatibility` with the selected logical provider.

### `titan.c`: the dynamic loader

* **`pushroot(L)` / `titan_init_paths(L)`** normalize and cache the Titan
  SDK/rocks-tree root under `TITAN_ROOT_KEY`. A value already in the registry
  wins; a generated executable's startup chunk seeds it as described under
  [standalone startup path discovery](#standalone-startup-path-discovery).
  Otherwise Unix scans the inherited
  `package.cpath` for the first entry ending in `/lib/titan/0.6/?.so`, then
  `/lib/lua/5.5/?.so` as a bootstrap fallback, falling
  back to `/usr/local` only when no such entry exists. Windows uses
  `titan_win_push_root`, the parent of the executable's directory.
  `titan_init_paths` also
  prepends the exact `<root>/lib/titan/0.6/?.so` template to `package.cpath`
  when it is absent (`add_titan_package_cpath`) and eagerly initializes the
  Titan loader path. The Titan Lua fork's POSIX default C path lists
  `lib/lua/5.5/?.so` and `loadall.so` before `lib/titan/0.6/?.so`; generated
  executables put the Titan template first through the [startup path
  discovery](#standalone-startup-path-discovery) chunk.
* **`pushpath(L)`** resolves the run-time module search path once per
  Lua state and caches it in the registry under `TITAN_PATH_KEY`. A cached
  value wins, including the complete path a Windows standalone launcher's
  startup chunk stores. Otherwise the
  order is: `getenv("TITAN_PATH_0_6")` (the versioned variable,
  `TITAN_PATH_VAR TITAN_LIBRARY_VERSION_SUFFIX`), then `getenv("TITAN_PATH")`,
  then `".;<root>/lib/titan/0.6"` with `pushroot`'s `<root>`. A `;;` in
  the environment value is replaced by that default path (two
  `luaL_gsub` passes through a `\1` placeholder), so
  `TITAN_PATH="/opt/titan;;"` means "look in `/opt/titan`, then the
  installation defaults". The compiler-side expansion
  (`driver.expand_titan_bin_path`) follows the same contract.
* **The libs registry** — a table under `TITAN_LIBS_KEY` maps `.so`
  file names to light-userdata `dlopen` handles. The cache avoids repeated
  `dlopen` calls within a state. Titan deliberately does not call `dlclose` at
  state shutdown: generated modules form a manually wired dependency graph for
  which neither insertion nor reverse-insertion order is universally safe, and
  finalizable Lua objects can still retain native entry pointers. The operating
  system reclaims the mapped images when the process exits.
* **`loadlib(L, file)`** — returns the cached handle for `file` if
  present; otherwise walks the path `;`-entry by entry, builds
  `dir "/" file`, and tries `dlopen(filename, RTLD_LAZY | RTLD_GLOBAL)`; total
  failure raises a Lua error with `dlerror()` (which describes only the last
  attempt). Lazy binding lets a module's initializer load a provider before the
  module's unresolved function calls bind, while global visibility lets that
  later provider satisfy them.
* **Generated logical-module shims** — a Lua `require "titan.uv"` first finds
  `titan/uv.lua`, whose `package.searchpath("titan", package.cpath)` selects the
  physical provider. The shim calls `require "titan"`, then uses the support
  table's separate `_loadlibglobal` helper to map/promote that provider with
  lazy/global flags and resolve `luaopen_titan_uv`. The same template serves
  every logical module; `titan.c` has no shim-specific or libuv-specific case.
* **`titan_module_provider(L, module, file)`** and
  **`titan_module_symbol(L, provider, sym)`** — select a dependency's provider
  (registry module, copied native descriptor, or `file`) and resolve its
  symbols; `loadsym(L, lib, sym)` is `dlsym` with `luaL_error(L, dlerror())`
  on `NULL`. The generated import sequence that uses them is owned by [Static
  vs dynamic dependency
  wiring](codegen-overview.md#static-vs-dynamic-dependency-wiring), and its
  verification protocol by [Generated exports and runtime
  verification](binary-compatibility.md#generated-exports-and-runtime-verification).
* **`errorhandler(L)`** — the message handler that every generated Lua entry
  wrapper ensures is active around the native call. It stores the raw unified
  Lua and Titan trace in `registry[TITAN_BACKTRACE_KEY]` (subject to the
  `TITAN_TRACE_PINNED` pin) and returns the original error value unchanged.
  [Runtime trace model](error-handling.md#runtime-trace-model) and the
  following sections own trace construction, pinning, frame merging, and the
  `TITAN_NO_LIBBACKTRACE` fallback.

### `ltitanlib.c`: the `titan` Lua module

This companion is built separately from `libtitan.a`: Make compiles
`ltitanlib.c` into `ltitanlib.o`, links only that object into the private
bootstrap `titan-runtime/bootstrap/titan.so`, and passes it once as native
payload when building the full standard `titan.so`/`titan.a` provider pair.
It is *not* part of the runtime SDK's `libtitan.a` or ordinary generated
modules. Its table (`ltitanlib.c` `titanlib`) exports the user-facing
`backtrace`, the internal testing helpers `pin` and `clear` used to exercise
the traceback pin discipline, the loader helpers `_loadlib` and
`_loadlibglobal`, the compiler digest `_sha256_binary`, the output-tree lock
`_output_lock_open`, the precise file observation `_stat_precise`, on Windows
only `_abivalue`, `_native_process_tree_guard`, and the current-directory
search query `_executable_search_cwd` (backing `Sync:executable_search_cwd`),
and elsewhere the effective-permission query `_executable_access` (backing
`Sync:executable`) and the compiler's jobserver and signal helpers:

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

`titan._abivalue(path, symbol)` (Windows only) is the compiler's ABI-marker
query for PE providers; its contract is in [Windows loader
boundary](windows-build.md#windows-loader-boundary).

`titan._sha256_binary(bytes)` returns the 32-byte binary SHA-256 digest of a
string, including embedded NUL and high bytes, and raises for any other
argument. It is portable C over the public Lua API, with no OpenSSL or process
dependency, so the private bootstrap provides it before the standard library
exists. `titanc` refuses to start without it ([The `titanc` command
line](#the-titanc-command-line)), and a physical provider named `titan` is
published only when a fresh Lua process finds it, beside `_loadlib` and
`_loadlibglobal`, in the linked support table (`driver.lua`
`support_validation_script`); a stale `ltitanlib.o` therefore fails before
publication instead of producing an installation that `titanc` rejects.

The POSIX-only `_jobserver_open`, `_jobserver_wait`, `_signal_guard`,
`_signal_pending`, `_signal_raise`, `_signal_wake_descriptor`, and
`_sigpipe_ignore` are private to `titan-compiler/jobs.lua` and
`titan-compiler/build.lua`; `client:descriptor()` exposes the private
nonblocking jobserver read fd for `luv` polling, `_signal_wake_descriptor()`
exposes the signal guard's wake pipe read fd, and `_sigpipe_ignore()` ignores
`SIGPIPE` while the coordinator communicates with worker pipes and restores the
prior `sigaction` on `guard:restore()`. [GNU Make jobserver
participation](#gnu-make-jobserver-participation) and [Slot ledger and
jobserver rules](build-coordinator.md#slot-ledger-and-jobserver-rules) describe
their use.

#### Output-tree coordination

`titan._output_lock_open(path)` (`ltitanlib.c`) backs
`build.lock_outputs`: it opens `<directory>/.titan-build.lock` without
following a terminal symlink or reparse point (`O_NOFOLLOW | O_CLOEXEC` and
`S_ISREG` on POSIX; `FILE_FLAG_OPEN_REPARSE_POINT` without `FILE_SHARE_DELETE`
on Windows) and returns a `titan.outputlock` userdata with methods `try()`
(nonblocking `flock(LOCK_EX | LOCK_NB)` or `LockFileEx`), `linked(path)`,
`identity()`, `descriptor()` (the POSIX fd inherited by build workers so an
orphaned worker keeps the output domain locked until exit), and `close()`. See
[Output-tree coordination](build-coordinator.md#output-tree-coordination).

## Lua installation and executable-relative search paths

`make lua` compiles the Titan Lua fork pinned by
the `lua-5.5.1` Git submodule, without applying patches or rewriting source files.
Windows copies the same submodule sources unchanged into its separate build tree. Its POSIX `luaconf.h` sets
`LUA_ROOT "!/"` and includes a Titan provider template using the build-supplied
`TITAN_VDIR` alongside the ordinary Lua C-module templates. In `loadlib.c`'s `LUA_USE_DLOPEN` branch, the fork replaces the no-op `setprogdir`
macro with a function that expands every `LUA_EXEC_DIR` (`!`) occurrence in
the string on top of the Lua stack, then removes the original string. This
applies to both default module paths and environment overrides containing
the marker, with ordinary Lua environment precedence and `;;` expansion.

Linux obtains the actual executable through `/proc/self/exe`; macOS obtains
it with `_NSGetExecutablePath` and canonicalizes it with `realpath` before
stripping directory components. The parent of the executable's directory is
the module-path root: `<root>/bin/lua` uses `<root>`. Symlink launch paths and
the working directory do not select another installation. The POSIX change leaves
Lua's native loader flags and Titan's separate lazy/local and lazy/global
helpers unchanged.

The Lua source bytes are identical across platforms and independent of `PREFIX`.
The Windows implementation and DLL annotations are selected by the source's
platform guards at compilation. `make lua` runs the fork's platform build and
installation with `TITAN_LIBRARY_VERSION` and `PREFIX`; the fork's installer
copies the archive, public headers, and internal sources. Platform defaults
(`linux-readline`, `macosx`) and the rule that preparation checks only the
installed `$PREFIX/bin/lua` and `$PREFIX/bin/luarocks` programs, so callers
must clean and replace them when rebuilding, are in [Build and installation
responsibilities](build-script-audit.md). LuaRocks uses stock `configure`,
`make`, and `make install` with `--prefix`, `--rocks-tree`, `--with-lua`, and
`--force-config`; it retains its ordinary generated configuration and
wrappers. Pass custom native tools to later rock builds explicitly.
Executable-relative Lua paths are not a complete relocation scheme for all
installed tools.

For native runtime builds and SDK staging, Make prefers the installed
`$PREFIX/src/lua-5.5.1` source/header tree when its `lua.h` and `lobject.h`
exist, and requires the matching `$PREFIX/lib/liblua.a`. A missing archive
in this selected installation is an error; only absent installed headers
select the checkout Lua build. Native targets do not reinstall a selected
installed Lua. This lets `luarocks make` consume its own
prefix's Lua configuration even when the checkout build belongs to another
prefix. SDK staging preserves these Lua artifacts when `ROCKS_TREE` is
`PREFIX`, and copies the selected pair for a separate destination.
Explicit runtime source selection remains authoritative: the checkout
compiler passes its `driver.LUA_SOURCE_PATH` to Make, including a source tree
selected with `titanc --lua`. When that source/header path physically matches
the active installed Lua SDK's `src/lua-5.5.1`, `source_link_inputs` selects
the matching `<prefix>/lib/liblua.a`. Other source trees retain their local
`liblua.a`. Installed
compiler invocations still reject `--lua`. LuaRocks' `ROCK_LUA_INCDIR` remains
the explicit public-header input for its native helper builds.

## Reference: environment variables, paths, and flags

### `titanc` flags

The complete `argparse` declaration is at the top of `titanc`; the checks are
listed in [The `titanc` command line](#the-titanc-command-line).

| Flag | Effect | Constraints |
| --- | --- | --- |
| `<module>...` | Logical modules to build; all become source-required roots. | At least one, unless `--print-root`, `--test-dir`, or `-c --c-source`. |
| `--print-root` | Print the selected installation root and exit. | No module names. |
| `--print-ast` | Print each module's AST after checking. | Not with `--incremental`. |
| `--pretty-print` | Format generated C and headers with `CLANG_FORMAT`. | |
| `-v`, `--verbose` | Write native-tool/formatter commands, replayed worker output, and incremental object, native-C, and link hit/miss decisions to standard error. | |
| `-j`, `--jobs <n>` | Local cap on concurrent worker frontends and native compiler processes; overrides `TITAN_JOBS`, default 4. `1` keeps every C probe synchronous. | Positive integer. |
| `--c-parts <n>` | Maximum generated C translation units per module whose generated code reaches 2 MiB; overrides `TITAN_C_PARTS` (default 4 on Linux, otherwise 1); `1` disables splitting; independent of `--jobs`. See [Translation-unit parts](codegen-overview.md#translation-unit-parts). | Positive integer. |
| `--exe <path>` | Exact executable destination relative to CWD (`.exe` appended on Windows when absent; Windows provider DLL stays under `--output`). | Requires a standalone or test executable; not with `-c` or library-only builds. |
| `--static` | Run the archive pass before the DSO pass. | Not on Windows. |
| `--source-first` | Prefer source to compiled providers for every dependency. | |
| `--incremental` | Certify and reuse source module objects (including explicit roots), `--c-source` objects, and final links. | Not with `--print-ast`. |
| `-c`, `--compile-only` | Emit objects and headers only; without `--incremental` every module and `--c-source` file is rebuilt. | Not with `--exe`, `-l`, `-L`, `--ldflag`, `-X`, or `--no-uv-bootstrap`. |
| `--test` | Build native tests (objects only with `-c`). | No requested module may be named `titan.test.runner`. |
| `--test-dir <dir>` | Recursively discover source modules under `<dir>` whose final component is `test(s)`, `spec(s)`, `*_test(s)`, or `*_spec(s)` as roots; repeatable. | Requires `--test`; `<dir>` must lie inside a `--tree` root. |
| `--test-exclude <module>` | Exclude an exact logical module name from automatic `--test-dir` discovery (explicit roots still win); repeatable. | Requires `--test` and `--test-dir`. |
| `--coverage` | Instrument source modules without `test_` functions and report when the test executable runs. | Requires a test or standalone executable unless `-c`. |
| `--coverage-backend <name>` | `gcc-gcov` (Unix default) or `llvm-gcov` (Windows default). | Every `--coverage-*` option requires `--coverage`. |
| `--coverage-module <glob>` | Override automatic selection with a logical-module glob (`*`, `?`); repeat for a union. | |
| `--coverage-root <dir>` | Source repository root for reports (default: current directory). | |
| `--coverage-gcov <cmd>` | gcov reader (default: `GCOV`, `gcov`, or `llvm-cov gcov`). | |
| `--coverage-format <format>` | Richer report via gcovr: `html`, `lcov`, or `cobertura`; repeatable. | |
| `--coverage-output <dir>` | Report directory (default: `.coverage/report`). | |
| `--coverage-gcovr <cmd>` | gcovr command (default: `GCOVR`, then `gcovr`). | |
| `--no-uv-bootstrap` | Call `main` directly instead of the registered async bootstrap hook. | Requires a standalone or test main; not with `-c`. |
| `--no-line-directives` | Omit generated Titan `#line` directives. | |
| `-u`, `--lua <dir>` | Lua source tree (`driver.LUA_SOURCE_PATH`). | Source checkouts only. |
| `-t`, `--tree <dir>` | Source root (`driver.TITAN_SOURCE_PATH`, default `.`). | |
| `-o`, `--output <dir>` | Folder for generated files, preserving the source hierarchy. | |
| `-I`, `--include-dir <dir>` | Native include directory for C headers, probes, generated C, and `--c-source`; repeatable, order kept, searched before the SDK. | |
| `-D`, `--define <def>` | Native preprocessor definition `NAME[=VALUE]`; repeatable, order kept. | |
| `--cflag <arg>` | One native compile argument (for example `--cflag=-pthread`); repeatable, order kept. | |
| `-L`, `--library-dir <dir>` | Native library search directory for final links; repeatable, order kept. | Not with `-c`. |
| `-l`, `--link <libs>` | Comma-separated or repeated libraries passed as `-l` to the final link; order and repeats kept. | Not with `-c`. |
| `--ldflag <arg>` | One native link argument (for example `--ldflag=-Wl,--as-needed`); repeatable, order kept. | Not with `-c`. |
| `--c-source <file>` | Authored/generated C file compiled and certified under `<output>/.native/`, linked before `-X` payloads; repeatable. | Allowed without `<module>` when combined with `-c`. |
| `--print-c-objects` | Print the absolute certified object path for each `--c-source` argument, one per line in argument order; nothing else is written to stdout. | Requires `-c` and at least one `--c-source`; not with `--print-root` or `--print-ast`. |
| `-X`, `--extra-object <payload>...` | Native objects/archives carried into the linked outputs after `--c-source` objects. | Not with `-c`; library mode accepts only relocatable objects and regular archives. |

### Environment variables

| Variable | Read by | Default | Meaning |
| --- | --- | --- | --- |
| `CC` | `driver.lua`, `c-parser/cpp.lua`, `checker/c_types.lua` | `cc`; `clang.exe` on Windows | C compiler command, parsed as shell words and shared with foreign-import probing. |
| `AR`, `RANLIB` | `driver.lua` | `ar`, `ranlib` | Archive tools for provider archives. |
| `CLANG_FORMAT` | `driver.lua` | `clang-format` | Formatter command, parsed only when `--pretty-print` selects it. |
| `RC` | `driver.lua` | `llvm-rc` | Windows launcher resource compiler. |
| `MAKE` | `driver.lua` `check_runtime` | `make` | Make command for the checkout runtime archive. |
| `TITAN_EXTRA_CPPFLAGS` | `driver.lua`, `nativeinputs.lua` | empty | Preprocessing words for foreign-import probes, C probes, generated modules, `--c-source` nodes, runtime, and entrypoints (followed by CLI `-I`/`-D`). |
| `TITAN_EXTRA_CFLAGS` | `driver.lua`, `nativeinputs.lua` | empty | Compilation-only words after `TITAN_EXTRA_CPPFLAGS` (followed by CLI `--cflag`); never used by final links. |
| `TITAN_EXTRA_LDFLAGS` | `driver.lua`, `nativeinputs.lua` | empty | Ordered linker inputs appended to final provider and program links (followed by CLI `-L`, `-l`/`--link`, and `--ldflag`). |
| `TITAN_BUILD_PROFILE` | `driver.lua` | `production` | `validation` selects `-O0 -fno-lto -g`; any other value is a toolchain error. |
| `TITAN_NO_LINE_DIRECTIVES` | `driver.lua` | unset | Exact value `1` disables generated `#line` directives, like `--no-line-directives`. |
| `TITAN_JOBS` | `titanc` | `4` | Local job cap when `--jobs` is absent. |
| `MAKEFLAGS` | `jobs.lua` `open_slots` (Unix) | unset | A parent GNU Make's jobserver authorization and `-j1`; see [GNU Make jobserver participation](#gnu-make-jobserver-participation). |
| `TITAN_C_PARTS` | `titanc`, `driver.lua` (`driver.effective_c_parts`) | `4` on Linux; `1` on Windows, macOS, and other platforms (`driver.default_c_parts`) | Maximum generated C translation units per module when `--c-parts` is absent; `1` disables splitting. A changed value makes reused objects miss. |
| `TITAN_PATH_0_6`, `TITAN_PATH` | `driver.lua`, `titan.c` `pushpath`, `standalone_paths.lua` | unset | Compiled-module search path; the versioned name wins, and `;;` expands to the default. |
| `TITAN_ROCKS_ROOT` | `driver.lua`, `titanc --print-root`, installed-compiler Make invocations | unset (empty means unset) | Internal `ROCKS_TREE` override for installation-root discovery; not a public deployment setting. |
| `TITAN_PREFIX` | `driver.lua` | installation root | Root of the persistent C-probe cache `var/cache/titan-probes/2`. |
| `TITAN_PROBE_CACHE_DISABLE` | `driver.lua` | unset | Exact value `1` disables persistent C-probe reuse. |
| `TITAN_RUNTIME_PREBUILT` | `driver.lua` `check_runtime` | unset | Exact value `1` skips the checkout `libtitan.a` rebuild. |
| `GCOV`, `GCOVR` | `coverage.lua` | `gcov`/`llvm-cov gcov`, `gcovr` | Coverage readers when the matching `--coverage-*` flag is absent. |
| `TEMP`, `TMP` | `io.lua` (Windows) | system default | Directory for `Sync:tmpname` reservations. |
| `LUA_PATH_5_5`, `LUA_PATH`, `LUA_CPATH_5_5`, `LUA_CPATH` | `standalone_paths.lua`, Lua | unset | Explicit paths that generated executables keep; probing is skipped only when the Lua paths and `TITAN_PATH` are all set. |

Make-level settings such as `PREFIX`, `ROCKS_TREE`, `OPENSSL_MODE`, and
`STDLIB_USE_INSTALLED_RUNTIME` belong to the build; see [Build and installation
responsibilities](build-script-audit.md). `PREFIX` owns Lua and LuaRocks and
`ROCKS_TREE` owns the Titan rock, SDK, and standard library; the supported
workflow sets them equal, but they are separate ownership concepts.

### Paths and internal settings

| Name | Default / value | Meaning |
| --- | --- | --- |
| `driver.TITAN_ROOT` | internal override, otherwise first current Titan `package.cpath` template (`/lib/titan/0.6/?.so`), then the ordinary Lua template (`/lib/lua/5.5/?.so`); Windows uses `?.dll` | Titan SDK/rocks-tree root. Module loading only parses absolute roots lexically; resolver initialization normalizes relative roots through `context.io`. |
| `driver.SOURCE_CHECKOUT` / `driver.INSTALLED` | detected from checkout files unless the internal root is set | Select the writable checkout SDK/archive inputs or read-only installed SDK inputs. Detection is lazy (`driver.initialize_layout`); before resolver initialization the module exposes only a provisional lexical checkout layout. |
| `driver.INSTALL_PATHS` | `driver.installed_paths(root)` | `root`, `lua_source`, `include`, `lib`, `libtitan`, `libbacktrace`, `liblua` (`liblua55.a` on Windows), `titan_bin`, and `lua_cpath`; bundled `libuv.a` is deliberately not an installed SDK path. |
| `driver.TITAN_BIN_PATH` | `TITAN_PATH_0_6`, `TITAN_PATH`, or `.;<root>/lib/titan/0.6` in installed mode | Roots for compiled-provider search; checkout mode retains the `/usr/local` fallback. |
| `driver.TITAN_SOURCE_PATH` | `"."` (`titanc --tree`) | Semicolon-separated source roots. |
| `driver.LUA_SOURCE_PATH` | `<root>/src/lua-5.5.1` installed; `lua-5.5.1/src` in checkout mode | Lua internal source/header tree; checkout-only override by `titanc --lua`. |
| `driver.INCLUDE_PATH` | `<root>/include` in installed mode | SDK headers used by generated C and foreign imports; see [the runtime support library](#the-runtime-support-library-titan-runtime). |
| `driver.TITAN_RUNTIME_PATH` / `driver.LIBBACKTRACE_PATH` | `titan-runtime/` / `libbacktrace` | Checkout-only runtime and libbacktrace locations. |
| `driver.LANGUAGE_SERVER_API_VERSION` | `1` | Exact compiler/semantic-client handshake; see [Language-server compiler API](#language-server-compiler-api). |
| `driver.EMIT_LINE_DIRECTIVES` | true unless `TITAN_NO_LINE_DIRECTIVES=1` | Default `#line` policy. |
| `driver.CFLAGS` | `--std=c99 -O3 -Wall -Wno-unused-but-set-variable -Wno-unused-function -fPIC` plus compiler-specific debug flags; Linux production adds `-flto=auto -ffat-lto-objects` | GCC uses `-g1`, Clang `-gline-tables-only -fdebug-info-for-profiling`, other compilers `-g`. |
| `driver.NATIVE_COMPILE_FLAGS` / `driver.NATIVE_LINK_FLAGS` | `driver.apply_native_inputs(normalized)` | Normalized ordered compile and link extras (`TITAN_EXTRA_*` then CLI native switches). |
| `driver.OUTPUT_ROOT` | `args.output` in `titanc` | Selected `--output` directory for synchronous native publication temporaries. |
| `driver.PROJECT_CACHE_VERSION` | `version.PROJECT_CACHE_VERSION` (`6`) | Language-server project-manifest schema version. |
| shared-library flags | `driver.shared_library_flags` | `-shared`; Darwin adds `-undefined dynamic_lookup`, Windows `-Wl,--exclude-all-symbols`. |
| installed link set | `driver.installed_link_inputs` | Unix: `libtitan.a`, `libbacktrace.a`, `liblua.a`, `-ldl` (non-Darwin), `-lm`; Windows: `libtitan.a`, `libbacktrace.a`, `liblua55.a`, `-static-libgcc`. Not copied into package archives. |
| checkout link set | `driver.source_link_inputs` | Local `libtitan.a`, `libbacktrace.a`, matching `liblua.a` (`<prefix>/lib/liblua.a` when `LUA_SOURCE_PATH` physically matches the installed Lua SDK), `-ldl -lm`. |
| `TITAN_ROOT_DEFAULT` / `TITAN_LUA_CPATH_SUFFIX` | `/usr/local` / `/lib/lua/5.5/?.so` | Run-time root fallback and Lua template suffix used for root discovery (`titan.h`). |

The pieces upstream of the driver are described in
[the type checker](checker.md) (which calls the loader) and the
[code generator overview](codegen-overview.md) (which produces what the
driver compiles); the contents of the runtime archive's callers — the
generated `_init`, standalone path initialization, and Lua entry wrappers that
ensure `errorhandler` is active —
are in [Lua interop internals](lua-interop-internals.md).

### Build-worker transport

`titan-compiler/process.lua` provides the cross-platform `luv` transport
(`luv >= 1.52.1` on Linux, macOS, and Windows, anchored once per Lua state in
the registry under `"titan-compiler.process: luv"`; on Windows,
`platform.getenv` reads environment variables through the same anchored
module, so both share one `luv` module table and native loop whichever loads
it first). On every platform, the
build coordinator uses `process.start_worker` (spawning `luv.exepath()` with a
coordinator-to-worker request pipe on `fd 3`, a worker-to-coordinator pipe on
`fd 4`, captured stdout/stderr pipes, and inherited POSIX `.titan-build.lock`
descriptors on `fds 5..`), `process.open_control(3, 4)`,
`process.frame`/`process.new_frames` (4-byte big-endian length framing up to
256 MiB + 64 bytes), `process.encode_record`/`process.decode_record`
(`graphcodec` with native SHA-256), and `process.start_job` for worker-submitted
native compile and C-probe batches. See [Build-worker
transport](build-coordinator.md#build-worker-transport).

## Experimental Windows process transports

`titan-compiler.platform` reads the Lua host separator without filesystem or
process operations at import. `initialize_platform` retains lazy Unix `uname`
through the injected strategy, while native Windows initializes as `Windows`
without that subprocess. This host choice does not replace the generated
object's authoritative target fingerprint.

Configured tool names reach the process transport unchanged. Titan does not
resolve executables, append extensions, or inspect binary formats before launch.
The operating system reports lookup and execution failures. On Windows,
serial inherited-output commands, including native links, launch through
`process.run` with the parsed argument array, sharing the compiler's standard
streams under the same process-tree guard as worker and batch launches. The
Windows renderer (C-runtime quoting followed by `cmd` escaping) only formats
the verbose command echo.

Windows native links use `driver.run_link_command` to avoid the `cmd.exe`
command-length limit as the number or length of object paths grows. It first
requires a dense argument array whose leading words equal the parsed `CC`
command/wrapper prefix, returning an error otherwise. That prefix stays on the
command line; the remaining compiler and linker arguments go into a unique
sibling temporary `<output>.link.rsp.tmp.<id>` beside the output.
`platform.windows_response_contents` wraps every argument in double quotes and
escapes backslashes and quotes, the GNU response-file quoting MSYS2 Clang
parses (no `cmd` escaping), one argument per LF line, written in binary mode.
DLL providers, standalone/test providers, launchers, and the standalone
archive probe share this path. The temporary is removed after successful and
failed execution and after a Lua error or interrupt during launch; a launch
error is returned as a link failure so each caller's own temporary cleanup
runs, and only a forced kill can leave the file behind. Verbose mode prints
the expanded logical command followed by the actual short `@file` invocation;
native diagnostics and exit codes retain their normal transport. POSIX links
and ordinary compile/tool commands are unchanged.

Captured Windows commands, parallel generated-C workers and probe batches use
the stock `luv` LuaRocks dependency. `uv.spawn` receives the parsed argument
array, cwd and child environment; libuv owns Windows executable search and
argument quoting. Capture uses a binary pipe, sharing its writer for merged
stdout/stderr when requested. Generated-C workers write separate stdout and
stderr files. Probe workers pass equal log paths: `Batch:spawn` opens one
descriptor shared by both streams and closes that parent descriptor once.
These file logs cannot fill an unread pipe while the scheduler waits.
Exit callbacks queue the completed schedule position; `uv.run("once")`
delivers whichever child finishes first. Larger generated-C units start first
and each completion frees its slot immediately. Diagnostics still replay in
original request order.

Every `process.lua` spawn first calls `titan._native_process_tree_guard()`
once per process, assigning the compiler process to a non-breakaway
`KILL_ON_JOB_CLOSE` Job Object whose handle lives until process teardown.
Children therefore inherit a strict ancestor job before executing, whatever
job libuv adds them to; a failed guard reports an error and launches nothing
([orphan lifetime](build-coordinator.md#planned-worker-resolution-and-orphan-lifetime)).

The adapter closes process and pipe handles after completion and retains the
native exit value, including 256 and 9009. Launch failures are distinct from
child exit statuses. Windows exits are not decoded as POSIX signals. The common
scheduler waits for launched compilers before returning from an error. Process
tree termination is left to the external test runner. The compiler-I/O API is
the same on every platform; the POSIX transports use the FIFO completion and
shell-status behavior described in [Compiling one
module](#compiling-one-module-drivercompile).

The synchronous compiler filesystem implementation uses LuaFileSystem and Lua's
ordinary file operations. Windows `realpath` checks that the path exists and
returns its normalized absolute lexical spelling. It does not resolve links or
query handle-based file identities. `stat` and `lstat` normalize LuaFileSystem's
size, kind, mode and modification time; Windows device/inode fields are absent
because LuaFileSystem does not expose useful Windows file identities. C-header
validation therefore reads and hashes the file instead of using the optional
identity-and-timestamp shortcut. Injected strategies may still supply physical
identities.

Temporary names come from `os.tmpname`; Windows puts the leaf beneath `TEMP` or
`TMP` and creates the caller-owned file with `io.open`. Sibling stages use that
basename beside the destination. Windows replacement removes an existing
destination before `os.rename`, so a failed rename can leave the destination
absent. These ordinary operations rely on the programmer to avoid concurrent
writes to the same outputs. Provider publication retains its caught-failure
rollback and copies predecessors before committing replacements.

`spec/fixtures/windows_serial/` contains actual Windows transport and filesystem
oracles. Host tests cover dispatch, validation, and status normalization but do
not establish Windows quoting or filesystem semantics. Run the native oracles
with the edited compiler files on guest-local NTFS, then repeat the filesystem
gate on the shared workspace. Unicode input also
requires the controlled Lua executable's UTF-8 startup policy; changing only
the locale after startup does not repair initial narrow argv. The fixtures
record the remaining platform gates separately from Linux regression results.
