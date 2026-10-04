# Driver and toolchain

This chapter covers everything from resolving source/compiled modules through
producing a `.so`/`.a` pair or executable: `titan-compiler/driver.lua` (module lookup, the
import loader, C compilation and linking), the `titanc` command-line
front end, the small utility module the whole compiler leans on
(`util.lua`), and the C runtime-support library in
`titan-runtime/`. A reference table of every environment variable,
default path and flag closes the chapter.

Unless a Windows section or row says otherwise, native output paths, paired
providers, archive selection, and static Lua linking below describe Linux and
macOS. Windows uses DLL-only Titan providers and the controlled Lua import
library; see [Windows application launchers](binary-compatibility.md#windows-application-launchers)
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
  `TITAN_PATH_0_6` wins over `TITAN_PATH`; with neither set, installed mode
  uses `".;" .. root .. "/lib/titan/0.6"`.

For ordinary import `foo.bar`, each compiled-format pass probes the shallow `foo`
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
matching `src/lua-5.5.1`, `include`, `lib/liblua.a`,
`lib/titan/0.6/libtitan.a`,
`lib/libbacktrace.a`, and every compiled Titan module. Test mode additionally
selects `share/titan/0.6/src/titan/test.titan` from that same root as canonical
compiler-data source. Bundled libuv headers
are staged under `include`, but its static archive remains a private
source-build input rather than part of the installed SDK. Checkout mode
deliberately retains the repository paths for compiler/runtime development.
This is root discovery, not the previous policy of adding every
`package.cpath` directory to the Titan path. Outside a checkout, failure to
find that exact suffix becomes `driver.INSTALLATION_ERROR` and stops
compiler/toolchain use instead of silently mixing installations.

The standard library consists of twenty-two ordinary qualified logical modules:
`titan.coroutine`, `titan.uv`, `titan.async`, `titan.timer`, `titan.io`,
`titan.fs`, `titan.net`, `titan.ssl`, `titan.url`, `titan.http`, `titan.websocket`, `titan.os`,
`titan.peg`, `titan.string`, `titan.math`, `titan.lua`, `titan.iteration`,
`titan.gc`, `titan.test`, `titan.reflect`, `titan.sqlite3`, and `titan.json`. Most
checkout sources are `titan/<name>.titan`; `titan.uv`, `titan.http`, `titan.websocket`,
`titan.peg`, `titan.string`, `titan.sqlite3`, and `titan.json` are folder
ensembles. One `titanc` invocation links their independent objects and
`ltitanlib.o` into the physical checkout provider pair `titan.so`/`titan.a`.
The private namespaced LPegLabel archive follows `ltitanlib.o` as metadata-free
payload; selected libuv, private llhttp/SQLite, and selected OpenSSL payloads follow
it. Installation publishes both forms below `<root>/lib/titan/0.6/`
and twenty-two generated logical-module shims below
`<root>/share/lua/5.5/titan/`. Titan imports discover each module through the
preferred compiled-format pass; Lua requires use a generated shim and the DSO
form.

`titan.uv` is the public low-level binding to the bundled libuv provider.
`titan.async` owns the Runtime and its public Task, result, error, and
subscription types. Async, timer, fs, net, os, and sqlite3 import the ordinary
compiled `titan.uv` interface; none requires a source-private UV scheduler.
All twenty-two modules share the canonical physical provider pair while
retaining their separate logical and nominal identities. See the
[public binding reference](../language/standard-library-uv.md) and
[async implementation](libuv-runtime.md).

For source convenience, the parser first removes one terminal explicit-source
marker, `.titan`, and then desugars the twenty-two short standard-library imports
before module resolution: `import "async"`, for example, places
`titan.async` in the import AST exactly as `import "titan.async"` would. The same
mapping applies to `coroutine`, `uv`, `timer`, `io`, `fs`, `net`, `ssl`, `url`, `http`, `websocket`,
`os`, `peg`, `string`, `test`, `math`, `lua`, `iteration`, `gc`, `reflect`,
`sqlite3`, and `json`; every other name is left unchanged. The driver, checker, code
generator, and runtime thus
see only the qualified module name. Each qualified name naturally produces its
matching native symbols and Lua entry point (`titan_async_*` and
`luaopen_titan_async`, for example), so no separate Lua alias is required and
Lua's bare `coroutine` and `os` libraries remain unrelated.
The AST retains the marker only as `TopLevelImport.source_required`; its
`modname` is canonical. Thus `uv.titan` and `titan.uv.titan` both carry
`modname == "titan.uv"`, and no cache key, dependency, symbol, output, or
metadata entry includes the marker.

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

An import request carrying `kind == "source-import"` is source-required. The
loader resolves the stripped canonical name through the same tagged folder/flat
source resolver, without entering a compiled-provider pass. A clean miss returns
`source module '<name>' not found`; blocked source and all source errors are also
terminal. The request bypasses a cached DSO/archive selection and replaces it
with source when source exists. It never falls back to that cached provider.
When the current resolver has already returned that compiled interface to an
earlier importer, replacement additionally requires the source module's
serialized public projection to match it. This per-resolver guard prevents
stale typed ASTs while leaving an unused process-global cache entry replaceable
by a later independent compilation.

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
first. This is why one standard-library invocation can force all twenty-two roots
through source even when a bootstrap or prior combined provider pair is
visible. Their internal imports resolve to the already selected source cache
entries and are linked statically into the replacement provider pair.

A `--test` invocation is the invocation-wide source-preference case. Its
resolver context sets `source_first`, making every dependency try the tagged source resolver
before compiled formats and retaining binary fallback only on a clean miss. A
narrow source override selects canonical `titan.test`, while generated
`titan.test.runner` uses an in-memory ordinary source descriptor. This lookup
preference does not expose locals through ordinary imports; the generated runner
writes `import "titan.test.titan"` for its private protocol. See
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

Compiled providers expose an `<mangled>_abi` marker before serialized
`<mangled>_types`. `TITAN_ABI_VERSION` is the independent monotonic marker,
currently `2`; a mismatch is terminal before type metadata is evaluated or
native linking begins. The current ABI covers callable metadata and signatures,
physical-provider selection, canonical Array proxies, unions, Interfaces,
generic declarations, source-private provider identity, source foreign
callbacks, const-qualified descriptors and wrappers, and native nominal storage.
The separate `<mangled>_layouts` protocol supplies validated public physical
plans; see [Native nominal storage](nominal-storage.md).

`TITAN_VERSION` is the independent compiler and standard-library semantic
version, currently `0.6.0`. Its derived `0.6` library version selects
`TITAN_PATH_0_6`, `lib/titan/0.6`, and `share/titan/0.6`; patch releases share
those paths. The reset provides no migration or compatibility aliases for
earlier Titan installations.

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

### Language-server compiler API

[Caret-specific completion analysis](completion.md) extends this boundary with
disposable source transforms, checker-produced candidates, detached scalar facts
and closed captured dependency catalogs.

`driver.LANGUAGE_SERVER_API_VERSION` identifies the exact compiler contract
for long-lived semantic clients. It remains **1 until Titan's first public
release**; prerelease compiler and language-server changes move together without
bumping this marker. It is independent from `driver.TITAN_ABI_VERSION` and
persisted cache schema versions. A client must reject an absent, noninteger,
or different marker before invoking these options.

The contract includes parser/checker source metadata, analysis-local FFI include
roots, transient checked ASTs, compact declared manifests, serialized interfaces,
known-source identities, exact
`c_header_dependencies`, and `driver.restat_c_header_dependencies`, including
stable changed identities for ordinary deleted or unreadable inputs. Analysis
source/provider discovery, compiler probes, external topology resolution, and
C-header restatting all use the exact strategy stored in the resolver context.
The context owns cooperative `yield` checkpoints and the ordered
`checked_source_modules` publication list described below.

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

`options.cache_adapter` on a resolver context supplies dot callbacks
`get(kind, key)` and optional `put(kind, key, bytes, inputs)` and
`refresh_inputs(kind, key, inputs)`. Reads return a binary string or a miss,
optionally followed by current input metadata. A nil second result means legacy
or unavailable metadata; an empty array represents a known empty closure.
Writes return success. `inputs` is a dense ordered array of
`{kind, path, identity, observation?}`. An observation has integer
`modified_seconds`, integer `modified_nanoseconds` in `[0, 1000000000)`, and a
`physical_identity` string; it is not part of semantic/cache-key equality.
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

The `c-header-v6` payload stores extracted C declarations through a closed
schema: CType shapes, canonical tags, typedef identity, qualifiers, callable
signatures, declaration origins, field and array extents, exact integer tokens, final object-macro
field classifications, and the finite predefined macro facts needed by target
profiles. It excludes CPP macro environments, token/spacing/raw-spelling
sidecars, body definitions, source parser records and conversion memo state.
Fresh processing projects the completed header once; disk restoration performs
one schema-checked reconstruction. The process cache then retains and returns
the same immutable declaration object across resolver contexts and analysis
tokens, with no projection or deep copy on a live hit. Checker conversion
creates separate Titan types.

A disk miss runs ordinary preprocessing, parsing and declaration extraction.
Before accepting a disk hit, the compiler checks each dependency's physical
identity and saved mtime and restats every search candidate. The fourth `put`
argument carries the reusable header's dependency and search tails; the
caller's forced-header/top-level search prefix is reconstructed for every
request. Matching mtime and physical identity reuse the saved content identity
without reading or hashing. Changed mtime reads/hashes once; equal content
refreshes observation metadata without invalidating declarations.
Replacement/retarget takes a fresh read/hash because the physical input changed.
Missing inputs invalidate through metadata without a content read.
Same-physical-input changes preserving the observed mtime are intentionally not
detected. Timestamps retain the I/O strategy's exact seconds/nanoseconds;
LuaFileSystem retains its reported precision. Missing or malformed legacy
observations require a fresh read once.

Forced `-include`/`-imacros` preprocessing contexts remain local to the active
I/O provider. Subsequent preprocessing needs their mutable macro/output state,
so they are not persisted through the C-header adapter. A fresh provider
rescans forced inputs and performs its native macro probe before considering
extracted header-cache entries. Repeated use with the same provider validates
the complete file/search closure and clones its mutable context. Changes to
ordered flags, macros, selection or physical inputs rebuild that context;
failed scans or probes publish none.

The `ffi-conversion-v3` payload stores one module-wide namespace's final
`CModule`, converted `foreign_types`, canonical file tags, target profile, and
object-macro field classifications. It excludes conversion histories, memos,
raw CType roots, CPP environments and declaration ASTs. Its key includes
module/source identity, the combined header graph key, complete observed C
inputs, and the live target profile; importer body bytes are independent.
Replay reconstructs the closed semantic graph, rebinds declaration origins to
the current combined include, and skips `foreigntypes.convert`. The checker
reconstructs its needed declaration-history entries from those final types.
Final C validation uses the current combined environment after replay, and
writes report its complete observed input closure in the fourth argument.
Generated physical checking paths never become reusable input authority.
Generated header descriptors contain immutable include plans; project
restoration validates their contents, dependency order and recorded digests.
Owned generated paths, including relative `..` components in nested includes,
never become durable file inputs.

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
`metadata_reuses`, `search_checks`, and `memo_reuses` for that I/O strategy.
Reads/hashes include preprocessing and forced-header work, not just cache
validation; graph checksums are separate. Clearing a process cache resets these
counters.
Use a fresh `c_header_analysis` token per saved analysis even when retaining
the same I/O strategy's process cache: an analysis token intentionally skips
repeat closure restats only within that one analysis.

### `driver.new_resolver_context(options)`

Optional resolver `header_inputs` supplies the current host-validated input
observations for that analysis generation. The driver indexes them once by
kind/path/semantic identity, then uses them as fresher baselines when retained
project graphs still contain an earlier timestamp. Validation always checks
current filesystem metadata before reusing the content identity; this baseline
is separate from pass memoization and does not mutate retained graphs. Hosts
can pass the complete current owner-closure union.

Every resolver context owns exactly one validated compiler-I/O strategy in
`context.io`. `options.io` supplies a table or userdata whose colon methods are
`cwd`, `realpath`, `stat`, `lstat`, `readable`, `read_file`, `write_file`,
`list`, `mkdir`, `unlink`, `rmdir`, `rename`, `tmpname`, `run`, and `yield`.
Omitting it constructs the canonical synchronous Lua implementation from
`titan-compiler.io`, so ordinary compiler callers retain blocking behavior.
Missing or non-callable methods are rejected while the context is created.

`options.embedded_interface_provider`, when present, has the closed schema
`{ provider_file = <absolute path>, entries = { [module] = { abi, types } },
target_profile = <optional exported profile data> }`.
The provider and every entry must be plain tables with no extra fields; logical
names, ABI strings, serialized `Type.Module` graphs, and native symbol-prefix
uniqueness are validated eagerly. The driver copies the inventory and retains
no caller-owned entry table. A successfully validated raw provider table is a
trusted immutable snapshot: reusing the same table identity uses a weak-keyed
validated cache, so later mutation of that raw table is unsupported and is not
observed. Every resolver context still receives a distinct provider object and
cloned decoded type graphs; resolver-local rebinding or annotation therefore
cannot leak across contexts. A distinct raw table identity is validated and
decoded independently.

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
`started`, `persistent_lookup`, `publication`, and optional `wall_ms`. The service always
reports `batch_kind = "single"`: each compiler invocation checks one probe.
`key` and `header_identity` have the same source-digest meanings as in the
semantic event. The I/O strategy may supply finite nonnegative child wall
milliseconds in its normalized `run` result; process CPU is never substituted.
Both structured callbacks are protected and may not change compilation when
they fail.

The following is the complete normative language-server strategy contract. Signatures use Lua multiple-return notation. Every table that crosses
this boundary is an ordinary Lua table: implementations must not expose
backend-specific records, arrays, error objects, or task handles.

| Method | Result and contract |
| --- | --- |
| `cwd()` | `pathname, nil` or `nil, message`. Returns the process working directory as an absolute pathname without changing it. |
| `realpath(path)` | `pathname, nil` or `nil, message`. Canonicalizes an existing path to an absolute pathname, following symbolic links. |
| `stat(path)` | `metadata, nil`, `nil, nil` for a clean missing path, or `nil, message`. Follows the final symbolic link. |
| `lstat(path)` | The same result convention as `stat`, but describes the final symbolic link itself. |
| `readable(path)` | One boolean. `true` means the path can be opened for binary reading; absence, invalid input, and ordinary open failures are `false`. |
| `read_file(path, max_bytes?)` | `bytes, nil` or `nil, message`. Without a bound, reads the complete file as a binary-safe Lua string. A bound must be a nonnegative integer; the method returns the complete file when its size is at most that bound, or exactly the first `max_bytes + 1` bytes when it is larger. This optional form lets bounded decoders detect overflow without materializing an unbounded replacement. |
| `write_file(path, bytes)` | `true, nil` or `nil, message`. Publishes only complete contents: an observer may see the previous file or the complete replacement, never a partially written destination. Failure and cancellation must not leak the strategy's sibling temporary. If cancellation races the final rename, the destination may contain either complete version. |
| `list(path)` | A dense one-based array of entry basenames, or `nil, message`. `.` and `..` are excluded and order is unspecified. |
| `mkdir(path, remove_if_cancelled?)` | `true, nil` or `nil, message`. Creates one directory; its parent must already exist. The optional ownership rule is described below. |
| `unlink(path, remove_if_cancelled?)` | `true, nil` or `nil, message`. Removes a non-directory path without following its final symbolic link. The optional ownership rule is described below. |
| `rmdir(path)` | `true, nil` or `nil, message`. Removes one empty directory. |
| `rename(from, to)` | `true, nil` or `nil, message`. Renames within the filesystem using the platform's replacement semantics. |
| `tmpname()` | `path, nil` or `nil, message`. On success `path` names an existing, process-unique, empty regular file owned by the caller. Ownership transfers only with the successful return; cancellation before that return must not leak the reservation. |
| `run(argv, options?)` | One normalized result table. `argv` is a nonempty dense array of strings, not a shell-fragment interface. `LANG` and `LC_ALL` are fixed to `C`. `options.stderr_to_stdout` defaults to `true`; when false, only stdout is captured and stderr remains on the compiler process's stderr. |
| `yield()` | No arguments or results. This is the cooperative post-module checkpoint; the synchronous implementation is a no-op. |

`stat` and `lstat` metadata has exactly the Lua-facing fields `kind`, `size`,
`mode`, `device`, `inode`, `modified_seconds`, and `modified_nanoseconds`.
`device` and `inode` are integers that form an opaque physical-file identity
pair: clients compare the pair only for equality and must not interpret either
component. `kind` is `file`,
`directory`, `symlink`, or `other`; `size` and the timestamps are integers,
nanoseconds are in `[0, 1000000000)`, and `mode` carries the POSIX file-type
and permission bits used by filesystem/header identity code.

`run` always supplies boolean `started` and `ok` plus a string `diagnostic`.
A completed process also supplies integer `status`, string `why` (`exit` or
`signal`), boolean `interrupted`, the reproducible quoted `command`, and binary
string `output`. Signal termination sets `interrupted`, uses the signal number
as `status`, and may additionally publish `signal` and `shell_status`. Argument,
spawn, capture, or wait failures set `started == false` and may omit fields
that could not be established. A normal zero exit is the only successful
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

Checkout/installation discovery and platform initialization do not perform
filesystem or subprocess work while `driver.lua` is loaded. Context creation
resolves the compiler layout through `context.io`; `configure_foreign_c(context)`
later obtains `uname` and the target profile through the same strategy.
`titanc` explicitly creates the default synchronous context before reading
layout-dependent settings and configuring foreign C.

`context.checked_source_modules` is an ordered dense list of modules actually
parsed and checked by that context. Cached source entries and serialized
interfaces are not appended. After each checked module is completely published
in `driver.imported` and `static_deps`, the loader appends its name and invokes
`context.io:yield()` with no arguments. A Titan-backed strategy may suspend its
own Task there; the synchronous strategy's method is a no-op.

### `driver.defaultloader(static_deps, options)`

`defaultloader` uses three pieces of process state:

* **`driver.imported`** — a process-global cache keyed by logical module name.
  Source entries carry `{ kind = "source", ast, type, filename,
  source_files, program_output, deps, c_header_dependencies, source_manifest }`;
  `source_manifest` is absent only when its serialization reports an error.
  DSO entries
  carry `{ kind = "dynamic", type, filename, relative }`; archive entries
  carry `{ kind = "static", type, filename, static_archive,
  static_provider }`; trusted host-inventory entries carry
  `{ kind = "embedded", type, filename, embedded_provider }`. Tests and
  long-lived tools reset this cache together with `types.registry`.
* **`CIRCULAR_MARK`** — a unique sentinel stored before recursively checking a
  source module; encountering it reports `"circular reference to module"`.
* **the resolver context** — invocation-wide compiled-format preference,
  archive-scan cache, the optional copied embedded inventory, ordinary
  provenance, selected static providers,
  contextual type-only owner recovery and its metadata-only physical
  resolutions, native-binding constraints, and the finalized direct-name
  sets.

The analysis-facing options are narrow and caller-owned:

* `known_source_modules` is a validated `{[modname] = true}` identity set. It
  tells source/provider overlap planning which logical names belong to source
  without making any module dirty or retaining its AST. One overlap rejects the
  complete embedded inventory for that resolver context.
* `embedded_interface_provider` is accepted by `new_resolver_context`, not as
  mutable loader state. It is a semantic-client input with the closed
  schema and optional build target profile above; after its first successful
  validation, the host must treat that
  raw table identity as immutable. Ordinary compiler callers omit it.
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
* `io` is accepted by `new_resolver_context`, not as a second loader-owned
  callback. `after_source_check` is rejected; cooperative suspension uses the
  context checkpoint and checked-module list described above. Recursive parents
  may still be mid-check, so abandoning the Task requires closing the resolver
  and discarding the attempt's `driver.imported`/`types.registry` state.
* `extra_ffi_include_dirs` is normalized while creating the resolver context and
  appended to a fresh C-probe toolchain descriptor. It never changes the
  process-global foreign-C configuration used by other compiler clients.

Before cache reuse, the loader reconciles the process-global cache with
the resolver's embedded inventory. It removes embedded entries owned by a
different resolver/provider object; when the current closed inventory remains
active, it evicts cached DSO/archive entries for every carried logical name and
clears every carried name from the supplied `static_deps` map, including names
whose cached import entry was already pruned. Cached source provenance instead
rejects the complete embedded inventory and remains selected.

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

Every successfully checked source entry also owns an ordered
`c_header_dependencies` array. A `file` item names a header whose exact parsed
bytes and followed physical-file identity supply the recorded fingerprint. A
`search` item names one exact candidate consulted during ordered lookup, up to
and including the winner, and records its final-component `lstat` state,
followed state, physical identities, and the exact read-open predicate used for
selection, including missing files, broken symlinks, and effective access
failures. The checker unions the complete written/imported
foreign-include set for that module, deduplicates identical kind/path
observations in first-seen order, and rejects conflicting identities from one
check. Paths are absolute lookup spellings: a relative candidate is prefixed
with the captured process cwd and harmless standalone `.` components are
removed, but `..`, repeated separators, and symbolic-link components remain
untouched. Restat and generated C therefore traverse the same lookup route;
retargeting an intermediate symbolic link changes the physical fingerprint
instead of leaving a cache entry pinned to its former target.
Configured `-imacros` and `-include` inputs are part of this same per-module
closure, including their transitive includes and every candidate consulted to
resolve a relative operand. Resolver-owned
generated `.ffi.h` trees are parsed by `cdriver` as the module C environment.
Their validated descriptors identify the generated text and nested dependency
trees; these compiler-owned inputs do not escape as restattable temporary paths.
Exact physical author headers and search candidates still populate the observed
closure. Saved source identity and regenerated descriptors cover generated
inputs. The C probe baseline includes the same module `.ffi.h` and supplies the
authoritative compilation check.

For an embedded hit, the already-decoded entry carries `kind = "embedded"` and
the trusted absolute `provider_file`; no filesystem or dynamic-loader operation
occurs. For a DSO hit, `find_dynamic_interface` uses
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
trusted. Embedded entries pass that same decoder during context creation. See
[Interfaces](interfaces.md#separate-compilation-and-schema-validation).

Each source entry's `deps` stores direct dependencies that are already native
inputs—source or selected static—regardless of which contributor declared
the import. The loader's `static_deps` argument retains this compatibility
view for embedding callers and test helpers. Production `titanc` instead
finalizes the shared resolver context after all roots are checked, deriving
`native_static_names` as every invocation source name plus every logical key
physically carried by the deduplicated selected archives. It passes that
complete set to every `coder.generate` call and passes the selected archives
once to native linking.

Selected embedded entries and their carried contextual owners are replayed at
finalization like a static provider's interface closure, but remain outside
`static_deps`, `selected_static_providers`, `native_static_names`, native
bindings, and linker arguments. A source identity discovered after an embedded
entry was selected rejects the whole inventory and re-resolves every earlier
selection through ordinary disk providers before source checking continues.

Finalization also filters `context.contextual_resolutions` against the final
compiled exposer selection. The exposer's physical file must still match the
one observed during checking. A carried owner must share that provider; an
ordinary-fallback owner may retain its separately resolved provider. This keeps
simple nominal aliases whose canonical registry nodes do not replay recovery,
while dropping provisional metadata made obsolete by a later source-root or
provider selection. Long-lived semantic clients read the filtered table only
after successful finalization and use it for cache graph edges, not native link
inputs.

`coder.generate` therefore has three binding paths: direct `extern` symbols
for source/static names, handle-scoped `loadlib`/`loadsym` for selected DSOs,
and process-global symbol recovery for producer-dynamic transitive record
owners. Generated `_types` functions persist none of this provenance or the
transient DSO path ([static vs dynamic
wiring](codegen-overview.md)). Folder layout does not add a loader protocol;
the relevant filesystem options are `source_roots` and the shared resolver
`context`.

### `driver.restat_c_header_dependencies(dependencies, options)`

This language-server helper validates a previously published ordered dependency
array and returns `inputs, nil, changed`: the same kind/path sequence with current
identities/observations and a boolean semantic-change flag (including false).
Touch-only observation changes leave that flag false. It does
not parse source, reparse a header, walk an include directory, or mutate the
dependency input. When it owns a temporary resolver, creating and closing that
resolver may initialize driver layout state and perform the context lifecycle
work described above. File content is read only when its saved physical identity
or timestamp is inapplicable or differs. It examines only the exact `file` paths
and `search` candidates already observed by the checker. A changed transitive header or
newly valid earlier search candidate therefore changes the owning module's
fingerprint.

Initial ordinary, nested and forced header reads certify metadata before and
after reading the exact bytes passed to the dependency observer. A modification
or replacement across that boundary rejects the operation before publication.
The observer retains that certified observation rather than restatting later;
final closure validation then detects an edit that happened after the read.
Caller-supplied bytes or a pre-opened `FILE*` have no certified mtime and require
a fresh content comparison at final validation.

Ordinary filesystem churn is data rather than a driver failure. If a former
`file` cannot now be read because it was deleted, replaced by another kind, or
became unreadable, the result carries a stable
`c-header-file-v2:unreadable:...` identity describing its current `lstat` and
followed/read-open state. Recreating a readable file replaces that state with
its exact byte and followed physical-file identity. Malformed dependency shapes,
unknown kinds and a file changing during the required read return `nil, message`.

The optional second argument may be a resolver context, an options table with
`context`, or an options table with `io`. The first two forms borrow the
caller's context; the last creates and closes a temporary resolver around that
strategy. Omitting the argument uses synchronous I/O and the same mtime-first
policy. Optional `options.header_validation` is a caller-owned table shared by
all module closures in one coherent validation pass; it memoizes file metadata,
required reads/hashes, and search checks by exact kind/path. Start a new table
at every filesystem validation boundary. Ordinary parser calls keep private
passes, and completed-analysis graph reuse remains separately branded.
Every header read, lstat/stat, and readability check uses the selected
`context.io`.

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
An explicit request may replace a cached compiled entry when `modtable` has the
source and fails when it does not. If that compiled interface was already
returned in the same resolver, its public serialization must match the new
source projection. The round trip already exposes constructor-schema drift such
as `flexrettype`; it does not by itself authorize loading that schema under the
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
   from `<root>/include` and the already-built
   `<root>/lib/titan/0.6/libtitan.a`.
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
2. **Prepare generated C headers.** `titanc` plans each source module's
   `.ffi.h` and, when it defines foreign functions, `.titan.h`. It rewrites
   checking-tree dependency edges to final absolute paths and validates every
   destination before writing any. Each header is written to a sibling stage,
   normalized and optionally formatted, then renamed into place before the
   first object is compiled. `driver.compile` consumes the supplied plan; direct
   programmatic callers retain the one-module planning fallback. Folder headers
   live beside the canonical main, with no contributor-specific outputs. See
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
   `TITAN_EXTRA_CFLAGS`, in that order. A direct `driver.compile` call runs this
   command immediately. The CLI's default one-job path preserves that same
   generate/format/compile sequence for each logical module. With a larger
   bound, it prepares every source module through step 4 in logical-name order,
   then `driver.compile_modules` runs only these independent object commands
   concurrently, bounded by `--jobs`/`TITAN_JOBS`:

   ```sh
   cc --std=c99 -O3 -flto=auto -ffat-lto-objects -Wall -fPIC -g -c foo/bar.c \
      -I <root>/include -I <root>/src/lua-5.5.1 -o foo/bar.o
   ```

   These command examples show Linux defaults. Both GCC and Clang use
   `-O3 -flto=auto -ffat-lto-objects` there, retaining native object sections for
   metadata loading while enabling LTO. Other platforms, including macOS,
   use `-O3` without the two LTO options. Compilation and final links share
   those defaults; an explicit LTO opt-out requires `-fno-lto` in both
   `TITAN_EXTRA_CFLAGS` and `TITAN_EXTRA_LDFLAGS`.

   Checkout mode substitutes `titan-runtime`, `lua-5.5.1/src`, and
   `libbacktrace` include paths. `-g` emits the DWARF carrying `#line`
   file/line attribution. Native test functions additionally receive
   `-fno-optimize-sibling-calls` to retain their tail frames. Sanitizer CI
   explicitly disables LTO so saved object functions can be compared with
   the generated-C diagnostic shadow.

On Windows, a requested bound above one is reduced to one before entering the
existing per-module generation/formatting/compilation path. No Windows FIFO,
parallel child manager, or compiler-bootstrap libuv dependency is introduced.
Linux and macOS retain the completion-driven scheduling below unchanged.

The native-tool strings, and `CLANG_FORMAT` when `--pretty-print` actually
selects it, are parsed into dense argument arrays with a small shell-word grammar
supporting whitespace, single/double
quotes, and backslash escapes. Each command builder quotes every resulting word,
so spaces and shell metacharacters remain part of one argument rather than being
reinterpreted. A direct command ends in `os.execute`. For a parallel module
batch, `io.popen` starts at most the requested number of those same rendered
commands. Titan launches larger generated translation units first, using their
byte lengths as a deterministic compile-cost estimate. Each compiler's stdout
and stderr go to separate temporary files so a blocked pipe cannot deadlock the
batch. Parallel mode requires the standard POSIX `mkfifo` utility. Each child
publishes its prepared-batch index to one mode-`0600` named FIFO after the
compiler exits; the parent reaps whichever child completed and immediately
refills that slot. Once every child has been reaped, Titan replays and removes
the logs in logical request order. A completion-channel failure stops new
launches, reaps active children, and fails the unlaunched requests rather than
risking a deadlock. Preparation failures do not launch a process, and native
failures do not prevent already independent module objects from being attempted.
Unterminated quotes, trailing escapes, NUL bytes, an empty configured command,
and non-dense programmatic argument arrays produce configuration errors.
A malformed `CLANG_FORMAT` is therefore inert in the default mode. `-v` prints
the same safely quoted compiler/linker commands—and any opted-in formatter
command—that are executed.

`driver.compile_module(modname, mod, static_deps, verbose, options)` remains the
single-module wrapper for programmatic callers. It skips a module whose cache
entry says `compiled` and records the produced object filename. `titanc` instead
passes its ordered, logical-module/output-deduplicated source set to
`driver.compile_modules`; the batch API asserts that same ownership invariant.
Object identity compares normalized absolute paths, physical spellings resolved
from the longest existing ancestor, portable case-folded spellings, and existing
device/inode pairs. Lexical, symlink, case, and hard-link aliases are therefore
rejected before preparation. The CLI's earlier program/provider preflight uses
the same portable identity for generated C, objects, foreign headers, final
artifacts, and native inputs, so it rejects those collisions before publishing
a header. A one-job batch uses the single-module wrapper in order, while a
larger batch preserves the same cache mutation and per-module result order and
overlaps only the final C object commands.

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
stores one bounded result with diagnostics and optional typed enum selection at
`<prefix>/var/cache/titan-probes/2/<digest>.result`. Clear that directory or set
`TITAN_PROBE_CACHE_DISABLE=1` to bypass persistent reuse if external changes make
results stale. Generated C is compiled normally. See
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
cc --std=c99 -O3 -flto=auto -ffat-lto-objects -Wall -fPIC -g -shared \
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
cc [TITAN_EXTRA_CPPFLAGS...] --std=c99 -O3 -flto=auto -ffat-lto-objects -Wall -fPIC -g \
   [TITAN_EXTRA_CFLAGS...] \
   -c foo/bar__entrypoint.c -I <root>/include -I <root>/src/lua-5.5.1 \
   -o foo/bar__entrypoint.o
cc --std=c99 -O3 -flto=auto -ffat-lto-objects -Wall -fPIC -g -o foo/bar \
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
  ensures `<root>/lib/titan/0.6/?.so` is in `package.cpath`; the configured
  Titan-owned Lua already places it before the `lib/lua` templates. It then
  registers the main module for
  `require` *without* loading it:

  ```c
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, $LUAOPEN_FN);
  lua_setfield(L, -2, "$MODNAME");
  ```

  The entrypoint registers no dependency itself. Generated module code takes
  over during initialization: after a module's `_init` completes successfully,
  it stores its own `luaopen_<mangled>` function under its logical name in
  `registry[LUA_PRELOAD_TABLE]`, the table exposed as `package.preload`.
  Requiring the main module recursively initializes its imports, so that
  successfully initialized closure publishes itself. A private static import
  follows the same path. An unused or otherwise uninitialized linked module
  publishes nothing.

  It then pushes Titan's runtime `errorhandler` and runs `pmain` under
  `lua_pcall(L, 2, 1, -4)` with `argc` and `argv` as arguments; a
  failed pcall formats the still-available original error object and the
  captured raw traceback before exiting with `EXIT_FAILURE`. On success
  the integer returned by the Titan `main` becomes the **process exit status**:
  `ret = lua_tointeger(L, -1); lua_close(L); return ret;`.
* **`pmain`** first publishes the original `argc` integer and `argv` pointer
  under `TITAN_MAIN_ARGC_KEY` and `TITAN_MAIN_ARGV_KEY`, then calls global
  `require("$MODNAME")` and retrieves and retains that module's `main`
  callable. Async initialization calls the public idempotent
  `uv.setup_process_args()` helper, which uses only those original entrypoint
  values and replaces the private `argv` slot with the pointer returned by
  libuv. A low-level UV client can call the same helper explicitly; an ordinary
  Lua host without the entrypoint registry contract receives false. After `require`, `pmain` rereads
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

Mechanically, then, a standalone Titan program is an embedded Lua interpreter
whose entrypoint preloads only the compiled main module. `pmain`'s require of
that module performs the unchanged Titan initialization recursion; each module
publishes its loader only after its own successful `_init`. A later Lua require
of one of those initialized logical names calls its `luaopen_*` entry, recovers
the canonical registry module value, and applies the normal `package.loaded`
policy.

## The `titanc` command line

```sh
./titanc [--print-ast] [--pretty-print] [-v|--verbose] \
  [-j|--jobs <jobs>] [-u|--lua <luasrc>] [--static] [--test] \
  [--source-first] [--incremental] [-c|--compile-only] \
  [--no-uv-bootstrap] [--no-line-directives] \
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
formatter command, `--print-ast` dumps each module's AST after checking, and
`-j`/`--jobs` sets the positive generated-C compilation bound. The command-line
value overrides `TITAN_JOBS`; an unset environment defaults to one process.
Neither setting parallelizes checking, code generation, formatting, provider
validation, archiving, or linking. `--static` swaps the compiled-provider passes
to prefer self-describing archives before DSOs, `--test` selects the native test
pipeline described in [Native test runner](test-runner.md), and
`--no-uv-bootstrap`
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
`-X` in every build.

`--incremental` enables source-object metadata reuse, and `-c/--compile-only`
stops after object/header emission. Compile-only roots always rebuild; the
complete requested-root set becomes `forced_source_roots` before traversal.
`--source-first` selects the same source preference already used by `--test`
without changing ordinary-import visibility. Cached roots supply `has_main`
and `external_symbols` facts when their AST is absent. The CLI rejects
`--incremental` with `--print-ast`, and compile-only mode with
`-l`, `-X`, or `--no-uv-bootstrap`. Separate/incremental test builds share
`titan/test__test_support.o`; cached discovery records supply test function
names, and only the final test invocation synthesizes the runner. See
[Object-backed source modules](incremental-compilation.md) for record replay,
header restoration, and Make-owned invalidation.

Every CLI module name is placed in one `requested_roots` set and passed to the
filesystem loader. Those roots are source-first; everything they import runs
the configured complete compiled-format passes before source (`.so`, then
`.a` by default; swapped by `--static`), unless `--source-first` was selected.
After checking, linking in library mode derives
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

Fresh source modules reachable from every root are compiled once; incremental
object hits reuse their declarations and machine code. Dynamic
dependencies retain exact selected DSO handles. Selected static dependencies
contribute deduplicated physical archives: their complete validated
membership is direct native input and is repackaged into both output forms,
without bulk-entering ordinary resolver state. [Multi-module
libraries](multi-module-libraries.md) documents logical grouping and DSO
loading; [Static compiled modules](static-compiled-modules.md) documents the
archive resolver, binding constraints, composition, and paired publication.

After its per-module object targets complete, the standard library uses the
same generic path to link all twenty-two qualified roots:

```sh
titanc --source-first --incremental \
  titan.coroutine titan.uv titan.async titan.timer titan.io titan.fs titan.net \
  titan.ssl titan.url titan.http titan.websocket titan.os \
  titan.peg titan.string \
  titan.math titan.lua titan.iteration titan.gc titan.test titan.reflect titan.sqlite3 titan.json \
  -X titan-runtime/ltitanlib.o lpeglabel-build/libtitan-lpeglabel.a \
     libuv-build/libuv.a llhttp-build/libtitan-llhttp.a \
     sqlite3-build/libtitan-sqlite3.a \
     openssl-build/libssl.a openssl-build/libcrypto.a  # OPENSSL_MODE=bundled
```

The provider prefix is `titan`, so checkout output is `titan.so`, `titan.a`,
and twenty-two generated `titan/*.lua` shims. Each logical module retains its own
`luaopen_titan_*`, `_init`, `_abi`, `_types`, registry module state, and
initializer; `ltitanlib.o` supplies the twenty-second entry, `luaopen_titan`, and the
support table without adding an archive metadata key. The `titan.uv` folder
still generates only `titan/uv/uv.c`/`.o`, and no contributor shim. The
five-member LPegLabel archive is force-carried into both providers after
`ltitanlib.o` but contributes no logical metadata. The build puts the private
libuv archive after it in the shared `-X` payload, followed by the private
llhttp and SQLite archives and then any bundled OpenSSL archives used directly by
`titan.ssl`.
The default system OpenSSL mode omits only the OpenSSL archives, keeps their
pkg-config-selected settings as repeated final-link inputs, and never copies
them into `titan.a`; libuv, llhttp, and SQLite remain private payload in either
OpenSSL mode.
The eight llhttp callbacks are source-defined in the generated `titan.http`
object, so there is no HTTP adapter object.

Make owns one object target per standard module, including one object for each
whole folder ensemble. Explicit imports order the object/header prerequisites;
each stale target invokes `titanc --source-first --incremental -j1 -c` with its
own logical root. The compiler reuses dependencies already built by Make. An
inexpensive completeness check repairs missing generated headers while leaving
valid object/header mtimes unchanged. `make stdlib-objects` runs this graph
without linking a provider.

Make tracks every standard source explicitly, the compiler/runtime/support and
embedded-format inputs, effective `CC`/`AR`/`RANLIB`, extra flags, libuv and
OpenSSL configurations, and the private llhttp/SQLite identities. Configuration
changes invalidate the module objects. The final completion stamp depends on
those objects and invokes one source-first incremental link for the paired
provider. A missing `titan.so`, `titan.a`, generated shim, canonical test-support source,
or Darwin dSYM invalidates the stamp. A warm invocation also
rescans `titan.a` for the exact twenty-two logical keys without changing pair
mtimes. Exact child DSOs are removed as stale production outputs; the isolated
coroutine test is the only supported exact-image variant.

The source rock retains a two-stage bootstrap. `make titan` builds
`libtitan.a`, the SDK, and a distinct support-only image at
`titan-runtime/bootstrap/titan.so`. With `ROCKS_TREE`, the bootstrap is
atomically placed at `<root>/lib/titan/0.6/titan.so` only when that path is
absent; an existing valid bootstrap or full image is preserved, and an
incompatible image is left untouched with an error. The rock manifest then
deploys the compiler script/Lua modules but does not own a `titan` C module.

The source-only post-install hook delegates to `install-stdlib` using the
just-deployed `titanc`. It retains source-adjacent objects, checkout providers
and shims, and the completion stamp. Once the prefix contains `titanc`, ordinary
`make stdlib` selects that installed compiler and SDK too. Canonical compiler,
Lua, and SDK paths keep the configuration identical even when LuaRocks and PATH
spell a symlinked prefix differently. Installed compiler Lua files, the deployed
CLI, and SDK headers invalidate objects; runtime archives also invalidate the
final link. Published providers and shims are outputs, not prerequisites, so
publication cannot invalidate the retained build. `STDLIB_USE_INSTALLED_RUNTIME=0`
selects the checkout compiler/runtime explicitly.

The shared publication recipe uses the same effective native toolchain, extra
flags, rocks root, runtime mode, and OpenSSL policy as compilation.
Optional sanitizer snapshots capture the retained provider and exact generated
C/object pairs before publication or tests can replace them. The publisher validates the twenty-three Lua entries, twenty-two logical
protocols, exact twenty-two-key archive metadata, three-way
embedded/DSO/archive-backed ABI/types equality, twenty-two shims, the canonical test-support source, and Darwin dSYM. It prepares private destination copies and backs up
the active `0.6` public set and stale active-layout copies, commits shims and
the compiler source, then dSYM and `titan.a`, and renames the validated DSO last. A caught or injected
failure restores either the prior complete pair or the first-install
bootstrap. The canonical installed artifacts are
`<root>/lib/titan/0.6/{titan.so,titan.a}`, the DSO's macOS dSYM, and
`<root>/share/lua/5.5/titan/*.lua` shims plus
`<root>/share/titan/0.6/src/titan/test.titan`. SDK and stdlib artifacts remain
direct files outside the rock manifest and are not removed by
`luarocks remove`. Earlier Titan installations are neither migration sources
nor active-layout predecessors. Linux CI rebuilds the active `0.6` rock and
direct shims, and asserts that the
resulting interpreter uses the `0.6` library path. This does not waive the
ordinary manually dispatched full macOS pre-merge suite.

Its flow:

1. **Typecheck everything first.** One loader and resolver context shared by
   the complete `source_roots` set checks every requested module through
   `checker.checkimport`; requested roots are source-first, ordinary imports are
   checked recursively with compiled-format-first resolution, explicit `.titan`
   imports are source-required, and each selected
   folder is parsed into one dense AST and checked under its logical name.
   Each source module records direct source/static dependency edges under
   canonical stripped logical names. After all roots,
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
  functional helpers (`any` in the coder, `to_set` in the c-parser,
  `curry` only in the specs).

## The runtime support library: `titan-runtime/`

Every installed-mode compiled module and standalone program links
`<root>/lib/titan/0.6/libtitan.a`; checkout mode links
`titan-runtime/libtitan.a`. Neither mode links `titan.o` directly. Each archive
contains exactly the dynamic loader/error runtime `titan.o` and reduced
minicoro implementation/tag support `minicoro.o`. Source foreign callbacks
live in generated standard-module objects instead. Static-archive selection
pulls in only referenced objects. Vendored `libbacktrace.a` is a separate link
input. `ltitanlib.o` is also separate: it is the only input to the private
support bootstrap and is passed once as shared native payload when the twenty-two
standard logical modules are published in the full `titan.so`/`titan.a` pair.
The private five-member LPegLabel archive follows it only in the standard
provider payload and is not part of the runtime SDK.
The staged non-Lua SDK headers under `<root>/include` are `minicoro.h`,
`titan.h`, `titan/ffi.h`, `llhttp.h`, and `sqlite3.h`. Bundled libuv also
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
* **Constants** — `TITAN_ABI_VERSION "2"`, `TITAN_VERSION "0.6.0"`,
  `TITAN_LIBRARY_VERSION "0.6"`, `TITAN_LIBRARY_VERSION_SUFFIX "_0_6"`,
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
`titan.c`: `loadlib`, `loadsym`, `loadglobalsym`, `titan_module_provider`,
`titan_module_symbol`, the ABI/compatibility check helpers, and `errorhandler`.
Generated imports use `titan_check_module_abi` and
`titan_check_module_compatibility` with the selected logical provider. The retained
`titan_check_types` helper implements exact serialized comparison; generated
separate-DSO imports use the selective compatibility protocol instead.

### `titan.c`: the dynamic loader

* **`pushroot(L)` / `titan_init_paths(L)`** normalize and cache the Titan
  SDK/rocks-tree root under `TITAN_ROOT_KEY`. After `luaL_openlibs`, a compiled
  executable scans the inherited
  `package.cpath` for the first entry ending in `/lib/lua/5.5/?.so`, falling
  back to `/usr/local` only when no such entry exists. `titan_init_paths` also
  ensures the exact `<root>/lib/titan/0.6/?.so` template is in
  `package.cpath` and eagerly initializes the Titan loader path. The configured
  Titan-owned Lua already places that template before the ordinary `lib/lua`
  templates, so Lua and standalone programs resolve the same qualified module
  DSOs.
* **`pushpath(L)`** resolves the run-time module search path once per
  Lua state and caches it in the registry under `TITAN_PATH_KEY`. The
  order is: `getenv("TITAN_PATH_0_6")` (the versioned variable,
  `TITAN_PATH_VAR TITAN_LIBRARY_VERSION_SUFFIX`), then `getenv("TITAN_PATH")`,
  then `".;<root>/lib/titan/0.6"`, where `<root>` is recovered from
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
  `dlopen(filename, RTLD_LAZY | RTLD_GLOBAL)`. Newly needed runtime providers
  use these same flags; there is no libuv-specific filename case. Lazy binding
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
* **`titan_module_provider(L, module, file)`** — first reads the canonical
  logical module from the registry and uses the export callback in its native
  payload. Only an absent logical module loads `file`; a null filename requires
  an already initialized transitive owner. Executable-embedded, archive-linked,
  and locally loaded modules publish the same callback.
* **`titan_module_symbol(L, provider, sym)`** — resolves a symbol through the
  canonical callback or, for a newly opened provider, through `loadsym`.
  `loadsym(L, lib, sym)` is `dlsym` with `luaL_error(L, dlerror())` on `NULL`.
  Generated initialization verifies ABI and consumer requirements before calling
  a newly loaded dependency's initializer, then retains resolved native pointers
  and slot indices in its own per-state module payload
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

## Lua installation and executable-relative search paths

`make lua` configures the pinned `luaconf.h` with `LUA_ROOT "!/"`, retaining
the Titan provider template before the ordinary Lua C-module template. In
`loadlib.c`'s `LUA_USE_DLOPEN` branch, Titan replaces the no-op `setprogdir`
macro with a function that expands every `LUA_EXEC_DIR` (`!`) occurrence in
the string on top of the Lua stack, then removes the original string. This
applies to both default module paths and environment overrides containing
the marker, with ordinary Lua environment precedence and `;;` expansion.

Linux obtains the actual executable through `/proc/self/exe`; macOS obtains
it with `_NSGetExecutablePath` and canonicalizes it with `realpath` before
stripping directory components. The parent of the executable's directory is
the module-path root: `<root>/bin/lua` uses `<root>`. Symlink launch paths and
the working directory do not select another installation. The patch leaves
Lua's native loader flags and Titan's separate lazy/local and lazy/global
helpers unchanged.

The patched Lua source bytes are independent of `PREFIX`. Make still records
the destination prefix, platform, native tools, Readline selection, and build
flags in its configuration stamp; changing those inputs cleans the matching
Lua objects and installs the resulting archive, public headers, and internal
sources together. Warm builds preserve unchanged stamps. LuaRocks retains its
own destination-specific configuration and wrappers, so executable-relative
Lua paths are not a complete relocation scheme for all installed tools.

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
selected with `titanc --lua`, and uses that tree's matching archive. Installed
compiler invocations still reject `--lua`. LuaRocks' `ROCK_LUA_INCDIR` remains
the explicit public-header input for its native helper builds.

## Reference: environment variables, paths, and flags

| Name | Where read | Default / value | Meaning |
| --- | --- | --- | --- |
| `PREFIX` | Makefile / rockspec build input | Titan Lua prefix detected from `PATH`, otherwise `/usr/local`; explicit `PREFIX` takes precedence | Owns the Lua installation plus the LuaRocks executable and configuration; Lua module paths resolve from the running executable rather than embedding this build destination. |
| `ROCKS_TREE` | Makefile / rockspec build input | empty for a direct build; LuaRocks' `$(SCRIPTS_DIR)/..` for a source install | Owns the installed Titan rock, SDK, and stdlib. The supported workflow currently sets it equal to `PREFIX`, but they are separate ownership concepts. |
| `TITAN_PATH_0_6` | `driver.lua` (compile time), `titan.c` `pushpath` (run time) | unset | Versioned module search path; wins over `TITAN_PATH`. |
| `TITAN_PATH` | same | unset | Module search path; `;;` expands to the ordinary default at compile time and run time. |
| `TITAN_ROCKS_ROOT` | `driver.lua`, source-rock post-install Make invocation | unset | Internal normalized `ROCKS_TREE` override used while the just-deployed compiler builds the standard modules; not a public deployment setting. |
| `driver.TITAN_ROOT` | `driver.lua` | internal override, otherwise first `package.cpath` entry ending `/lib/lua/5.5/?.so` | Titan SDK/rocks-tree root. Module loading only parses absolute roots lexically; resolver initialization normalizes relative roots through `context.io`. Package-path discovery relies on the currently supported `ROCKS_TREE == PREFIX` layout. |
| `driver.SOURCE_CHECKOUT` / `driver.INSTALLED` | `driver.initialize_layout(context)` | detected from checkout files unless the internal root is set | Select the writable checkout SDK/archive inputs or read-only installed SDK inputs. Detection is lazy and uses `context.io`; before resolver initialization the module exposes only a provisional lexical checkout layout. |
| `driver.INSTALL_PATHS` | `driver.installed_paths` | paths below `driver.TITAN_ROOT` | Holds `lua_source`, `include`, `lib`, `libtitan`, `libbacktrace`, `liblua`, `titan_bin`, and `lua_cpath`; bundled `libuv.a` is deliberately not an installed SDK path. |
| `driver.TITAN_BIN_PATH` | `driver.lua` | `TITAN_PATH_0_6`, `TITAN_PATH`, or `.;<root>/lib/titan/0.6` in installed mode | Roots for root-major, shallow-to-exact compiled-provider search; checkout mode retains the legacy `/usr/local` fallback. |
| `driver.TITAN_SOURCE_PATH` | `driver.lua` | `"."` (overridden by `titanc --tree`) | Semicolon-separated roots searched for folder `P/B.titan` before flat `P.titan`, including contributor privacy checks. |
| `driver.LANGUAGE_SERVER_API_VERSION` | `driver.lua` | `1` | Exact compiler/semantic-client handshake, independent from generated-code ABI; covers private source metadata, exact C-header dependencies, context-owned I/O/checkpoints, the embedded interface/target provider, and compiler-owned declared analysis manifests. |
| `TITAN_NO_LINE_DIRECTIVES` / `driver.EMIT_LINE_DIRECTIVES` | environment / `driver.lua` | unset / true | Exact environment value `1`, or `titanc --no-line-directives`, disables generated Titan `#line` directives for physical generated-C diagnostics; this can omit ordinary native Titan frames from logical tracebacks. |
| `options.source_roots` | `titanc` / `driver.defaultloader` | every CLI module name | Requires explicit build roots to come from flat/folder source; other ordinary edges retain the resolver context's binary-first or source-first policy, while `.titan` edges remain source-required. Selected source descriptors also provide `program_output`. |
| `options.incremental` | `titanc` / `driver.defaultloader` | `false` | Allows source companion objects no older than current source constituents to supply trusted declarations and native code; Make owns other invalidation. |
| `options.forced_source_roots` | `titanc` / `driver.defaultloader` | `{}` | Complete explicit-root set for compile-only mode; bypasses object reuse even if a root is first reached through another import. |
| `options.known_source_modules` | semantic clients / `driver.defaultloader` | `{}` | Validated module-name set used for resolver-wide source identity and source/provider overlap planning without marking modules dirty. |
| `options.analysis_only` | semantic clients / `driver.new_resolver_context` | `false` | Retains the source-level checked AST without runtime generic erasure, enables compact analysis-manifest reuse and skips `.titan.h` body generation; analysis ASTs/manifests are not native code-generation input. |
| `options.cached_source_entries` | semantic clients / `driver.defaultloader` | `{}` | Caller-certified checked or compact declared source entries, including exact C-header inputs; compact entries and marked analysis ASTs require analysis-only mode; compact entries restore C include plans without AST replay. |
| `options.cached_interfaces` | semantic clients / `driver.defaultloader` | `{}` | Serialized clean source interfaces plus exact source and C-header provenance; used without AST for ordinary imports and as transient reparse input for explicit `.titan` edges. |
| `options.embedded_interface_provider` | semantic clients / `driver.new_resolver_context` | `nil` | Closed `{ provider_file, entries, target_profile? }` ABI/type inventory with an optional declarative build target profile, copied from a trusted host; it precedes disk compiled lookup but never becomes a static dependency or link input. |
| `options.io` / `context.io` | semantic clients / `driver.new_resolver_context` | `compiler_io.new_sync()` | Validated context-owned filesystem, process, and cooperative-yield strategy. The omitted default preserves synchronous compiler and `titanc` behavior. |
| `options.source_process_trace` | semantic clients / `driver.new_resolver_context` | `nil` | Best-effort scalar `(module_name, filename, outcome, self_cpu_ms, total_cpu_ms, parse_cpu_ms, check_cpu_ms)` observer for exclusive source-module process CPU. Parse time sums folder constituents; check and self time exclude nested source work, post-child checkpoints, complete C-header processing, and downstream FFI conversion. Cached rehydration reports zero parse/check CPU; five-argument Lua callbacks remain valid. |
| `context.checked_source_modules` | `driver.defaultloader` | `{}` | Ordered dense list of source modules checked during this resolver run. A module is appended after its complete result is published and before `context.io:yield()`; retained cached modules are excluded. |
| `options.extra_ffi_include_dirs` | semantic clients / `driver.new_resolver_context` | `{}` | Analysis-local include roots appended to a fresh foreign-C probe descriptor without process-global reconfiguration. |
| `options.c_probe_cache_trace` | semantic clients / `driver.new_resolver_context` | `nil` | Best-effort scalar `(module_name, stage, hit, key, path)` observer for persistent semantic-result lookups; it neither enables verbose evidence nor writes to stdout. |
| `options.c_probe_semantic_trace` | semantic clients / `driver.new_resolver_context` | `nil` | Best-effort bounded event-table observer for one logical terminal result per probe request, including outcome, cache tier, repeat, and publication state. |
| `options.c_probe_execution_trace` | semantic clients / `driver.new_resolver_context` | `nil` | Best-effort bounded event-table observer for physical compiler launches, including source digest, outcome, cache/publication state, and optional child wall milliseconds. |
| `titan._loadlib` | `ltitanlib.c` / `driver.lua` | internal `RTLD_LAZY` + `RTLD_LOCAL` loader | Maps DSO candidates lazily for callable ABI/type interface recovery without initializing them or globalizing their symbols; archive candidates are parsed in-process instead. |
| `titan._loadlibglobal` | `ltitanlib.c` / generated shims | internal canonical-path `RTLD_LAZY` + `RTLD_GLOBAL` loader | Maps or promotes a Lua-selected provider in a separate per-state cache and returns the requested logical `luaopen_*` entry. |
| `Type.Module.file` | `types.lua`, `driver.lua`, `coder.lua` | exact logical `.so` path for a DSO claim, overwritten after dynamic lookup | Transient selected relative DSO used by generated handle imports; deliberately omitted from serialized interfaces and never populated with an archive path. |
| `driver.LUA_SOURCE_PATH` | `driver.lua` | `<root>/src/lua-5.5.1` installed; `lua-5.5.1/src` in checkout mode; checkout-only override by `titanc --lua` | Lua internal source/header tree used at compile time. Installed mode rejects the override because `INSTALL_PATHS` supplies matching `<root>/lib/liblua.a` and `<root>/lib/titan/0.6/libtitan.a`. |
| `driver.INCLUDE_PATH` | `driver.lua` | `<root>/include` in installed mode | Titan SDK and selected bundled-dependency headers used by generated C and foreign imports: `minicoro.h`, `titan.h`, `titan/ffi.h`, `llhttp.h`, `sqlite3.h`, plus bundled `uv.h`, `uv/`, and `openssl/`. Generated source-foreign companions are source-build intermediates, not installed SDK headers. |
| `driver.TITAN_RUNTIME_PATH` / `driver.LIBBACKTRACE_PATH` | `driver.lua` | `titan-runtime/` / `libbacktrace` | Checkout-only runtime source/archive/header and separate libbacktrace locations. |
| `CC` / `driver.CC` | environment / `driver.lua` | `"cc"` on Unix; `"clang.exe"` on Windows | C compiler command, parsed as shell words and shared with foreign-import probing. |
| `TITAN_JOBS` / `titanc --jobs` | environment / CLI | `1` | Positive bound for concurrent generated logical-module C object compilations. The CLI wins over the environment. It does not affect checker probes, code generation, formatting, entrypoints, linking, archiving, or provider validation. |
| `CLANG_FORMAT` / `driver.CLANG_FORMAT` | environment / `driver.lua` | `"clang-format"` | Formatter command used only by `titanc --pretty-print`, then parsed as shell words. The driver appends its in-place operation, fixed explicit style with include sorting disabled, and generated-source path; default builds neither parse nor invoke it. |
| `driver.CFLAGS` | `driver.lua` | C99, `-O3`, warnings, PIC and debug info; Linux additionally uses `-flto=auto -ffat-lto-objects` | Shared compile/link defaults for both GCC and Clang. macOS keeps native objects without LTO. |
| `TITAN_EXTRA_CPPFLAGS` / `driver.EXTRA_CPPFLAGS` | environment / `driver.lua` | empty | Parsed `-I`/`-D` and other preprocessing inputs; used by foreign-import compiler probes and prepended to every Titan/runtime/entrypoint compilation. |
| `TITAN_EXTRA_CFLAGS` / `driver.EXTRA_CFLAGS` | environment / `driver.lua` | empty | Parsed compilation-only flags, after fixed defaults; never used by final links. |
| `TITAN_EXTRA_LDFLAGS` / `driver.EXTRA_LDFLAGS` | environment / `driver.lua` | empty | Parsed ordered linker inputs appended to final module and program links. |
| shared-library flags | `shared_flag()` | `-shared`; on Darwin `-shared -undefined dynamic_lookup` | Platform from `driver.UNAME`, populated lazily by `driver.configure_foreign_c(context)` through `context.io:run({"uname"})`. |
| installed link set | `driver.installed_link_inputs` / `append_runtime_libraries` | Unix: `<root>/lib/titan/0.6/libtitan.a` + separate `<root>/lib/libbacktrace.a` + `<root>/lib/liblua.a` + platform libraries; Windows: `libtitan.a` + `<root>/lib/liblua-5.5.1.dll.a` + `-lbcrypt` | Used by provider DSOs and programs; Linux adds `-ldl`, and Linux/macOS add `-lm`. These common final inputs are not copied into Unix package archives. The Unix standard build always supplies pinned libuv as `-X` payload to both `titan.so` and `titan.a`; system OpenSSL keeps explicit pkg-config link flags at final link. |
| checkout link set | `driver.source_link_inputs` / `append_runtime_libraries` | local `libtitan.a` + separate local `libbacktrace.a` + local `liblua.a` + `-ldl -lm` | Preserves the writable source-development path while using the same archive contract; it never links `titan.o` directly. |
| `TITAN_ROOT_DEFAULT` / `TITAN_LUA_CPATH_SUFFIX` | `titan.h`/`titan.c` | `/usr/local` / `/lib/lua/5.5/?.so` | Legacy run-time root fallback and exact template suffix used for root discovery. |
| `titan_init_paths` | generated standalone entrypoint / `titan.c` | root parsed from inherited `package.cpath` | Caches the root and Titan module path and ensures `<root>/lib/titan/0.6/?.so` is in `package.cpath`; Titan-owned Lua has it first by default, with `<root>` inferred from the running executable. |
| registry keys | `titan.h` | `TITAN_ROOT_KEY`, `TITAN_PATH_KEY`, `TITAN_LIBS_KEY`, `TITAN_MAIN_BOOTSTRAP_KEY`, `TITAN_MAIN_ARGC_KEY`, `TITAN_MAIN_ARGV_KEY`, `TITAN_BT_STATE_KEY`, `TITAN_BACKTRACE_KEY`, `TITAN_NAMES_KEY`, `TITAN_TRACE_PINNED`, `TITAN_TRACE_APPEND_KEY` (UUID strings) | Per-state caches and hooks: Titan SDK/rocks-tree root, module path, dlopen handles, optional standalone bootstrap, original process arguments and libuv's possibly replaced `argv`, registry-owned libbacktrace state, last raw backtrace, native-frame display names, re-raise traceback pin, and coroutine traceback append handoff. |
| generated ABI symbol | `coder.lua` | `<mangled>_abi` returning `TITAN_ABI_VERSION` | Checked before DSO type rehydration and before run-time dynamic-import `dlsym`; the same value is embedded in static metadata and compared during paired validation. Markerless compiled modules are incompatible. |

The pieces upstream of the driver are described in
[the type checker](checker.md) (which calls the loader) and the
[code generator overview](codegen-overview.md) (which produces what the
driver compiles); the contents of the runtime archive's callers — the
generated `_init`, standalone path initialization, and Lua entry wrappers that
ensure `errorhandler` is active —
are in [Lua interop internals](lua-interop-internals.md).

## Experimental Windows serial transport

`titan-compiler.platform` reads the Lua host separator without filesystem or
process operations at import. `initialize_platform` retains lazy Unix `uname`
through the injected strategy, while native Windows initializes as `Windows`
without that subprocess. This host choice does not replace the generated
object's authoritative target fingerprint.

The Windows-only command renderer accepts already parsed argv. It represents
C-runtime quote/backslash rules, then protects the representation from `cmd`
metacharacter interpretation. The executable position uses Windows separators;
extensionless tools explicitly select `.exe`, avoiding implicit PATHEXT batch
selection. `.exe` and `.com` are native tool forms; explicit batch/script
filenames fail before execution. A fixed `set` prefix supplies `LANG=C` and
`LC_ALL=C`. The Unix command renderers remain unchanged.

Before rendering, `_win_resolve_executable` resolves the first parsed word with
`GetFullPathNameW` for explicit paths or the documented `SearchPathW` order for
bare names. It does not change the process search mode, consult `PATHEXT`, or
execute a probe. `GetBinaryTypeW` rejects directories, scripts and non-native
images; the returned absolute pathname becomes argv[0]. These checks distinguish
lookup/access failures from ordinary child exit values but do not eliminate the
race between lookup and launch. The initial cmd transport rejects explicit
`\\?\` executable spellings: native lookup can validate them but the shell
cannot launch the tested form. It does not silently strip their namespace.
Ordinary installation roots retain their ordinary normalized spelling, including
when the controlled Lua cpath starts with `bin/..`. See Microsoft's [SearchPathW contract](https://learn.microsoft.com/en-us/windows/win32/api/processenv/nf-processenv-searchpathw)
and [GetBinaryTypeW contract](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getbinarytypew).

Serial inherited-output commands still use `os.execute`. Captured commands
still use `io.popen`, with `rb` on Windows so CRLF, NUL, and Ctrl-Z bytes are not
translated. Windows statuses are not decoded as POSIX signals. All native exits,
including 1, 126, 127 and 9009, retain `started=true` and their exact value. The
semantic-probe classifier conservatively reserves out-of-contract statuses as
infrastructure failures rather than persisting rejection evidence. These shell
transports do not provide the same direct child-launch evidence as a process API.

The synchronous Windows filesystem implementation lazily acquires private
helpers from native support. `_win_tmpname` reserves a caller-owned regular file;
`_win_reserve_sibling` reserves a regular file or directory directly beside a
destination. Names contain 128 OS-random bits and use exclusive creation.
`_win_replace` performs one same-volume replacement without a delete-before-move
or cross-volume copy fallback. Paths are converted explicitly between UTF-8 and
UTF-16. All helpers and their bcrypt import are Windows-only; Unix bootstrap
contents and dependencies stay unchanged. The injected compiler-I/O required
surface stays unchanged, and injected strategies retain their temporary-file
ownership and cancellation behavior.

`_win_stat(path, follow)` reports the same seven compiler-I/O fields, using
lossless tagged strings for device/file identity. Full `FileIdInfo` volume and
128-bit file IDs are preferred. Only unsupported-query errors on the positively
identified `VirtIO-FS` filesystem permit the approved fallback: actual
handle-reported volume GUID plus the full legacy 64-bit file index. No zero
volume serial, pathname, hash, case folding or truncated ID substitutes for
identity. Size and 100ns timestamps remain Lua integers; mode contains type bits
only. Symlinks and junctions have deliberate lstat semantics; unknown reparse
tags and failed traversal are errors. `_win_realpath` returns the exact
OS-resolved extended spelling separately from identity. `_win_abspath` uses
`GetFullPathNameW` for the default process's per-drive resolution; injected
strategies may provide optional `absolute` capability instead, with no required
API surface change. Pure Windows path operations preserve case, Unicode and
authored observation components, distinguish drive/UNC/extended roots, and
never supply physical identity. Missing Win32 errors
2/3 become `nil,nil` only at the synchronous stat/lstat boundary; access and
query errors remain visible. The existing persisted physical identity is already
an opaque string, so no cache-schema or API-1 marker change is needed.

On the tested VM, NTFS junction-follow reports error 448 (untrusted mount
point), including junctions created with Windows' `mklink`. That error remains
explicit; no security setting is changed. VirtIO-FS does not provide the tested
hardlink, junction and sparse-file operations. Regular live file bytes and
stable file identities work on the share. Share long-path and notification
limitations remain separate platform boundaries.

`spec/fixtures/windows_serial/` contains actual Windows transport and filesystem
oracles. Host tests cover dispatch, validation, and status normalization but do
not establish Windows quoting or filesystem semantics. Run the native oracles
with the edited compiler files and exact helper header on guest-local NTFS,
then repeat the filesystem gate on the shared workspace. Unicode input also
requires the controlled Lua executable's UTF-8 startup policy; changing only
the locale after startup does not repair initial narrow argv. The fixtures
record the remaining platform gates separately from Linux regression results.
