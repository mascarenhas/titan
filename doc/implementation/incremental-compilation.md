# Object-backed source modules

`titanc --incremental` certifies and reuses compiled `.o` files across both
whole-graph builds and compile-only (`-c --incremental`) invocations. An object
is reused only when its embedded `.titan.source` certificate matches the
current compiler and frontend inventory, runtime preamble closure, native
toolchain and compile options, own-source bytes and folder membership, split
and coverage code-generation options, split-part artifacts, transitive C header
file/search/origin closures, direct-import public or source-private interface
digests, contextually exposed nominal-owner digests, and resolved native
bindings. Plain `-c` without `--incremental` forces a fresh compile of every
selected source module.

The user-facing contract, `-v` diagnostics, and build-tool examples are in
[Incremental and separate compilation](../language/incremental-compilation.md).
Whole-graph planning, parallel worker scheduling, `.titan-build.lock`
coordination, `--c-source` nodes, final-link certificates, and `--test-dir`
discovery live in [Compiler-owned build coordinator](build-coordinator.md).

## Resolver and CLI boundary

Source-object certification is split into three side-effect-free stages in
`titan-compiler/incremental.lua` and one restoration step in
`titan-compiler/driver.lua`:

```text
incremental.certify_local(context, modname, source)
    -> { status = "hit" | "miss", reason?, detail?, record?, imports?, object?, objects? }
incremental.verdict(record, plan)
    -> { status = "hit" | "miss" | "pending", reason?, detail?, names? }
driver.restore_source_object(context, modname, source, record, options?)
    -> entry | nil, code, detail | false, err
```

Reuse applies only to resolved flat or folder source modules whose descriptors
do not carry in-memory `source.contents` (such as the synthetic test runner)
and whose resolver context is not `analysis_only`. The primary object path is
derived from the module's output stem (`<stem>.o`); `.o` files never enter
binary provider search on `TITAN_BIN_PATH`.

Neither `certify_local` nor `verdict` parses Titan source, runs the checker or
code generator, spawns a module-compilation child process, or mutates
`driver.imported`, `types.registry`, or FFI header state. Only after both
stages accept a record does `driver.restore_source_object` install the module's
declarations and checking headers into the active resolver.

Two execution paths share this pipeline:

1. **Coordinator-scheduled builds (`titanc` via `build.run`).** The planning
   loader (`driver.defaultloader` with `plan_mode = true`) resolves the
   requested root closure, runs `incremental.certify_local` on each source
   module, and follows either `certified.imports` (when the record schema and
   own-source bytes/membership match) or lexically scanned imports
   (`build.imports_for`). `driver.resolution_plan(context)` closes planning and
   orders source modules topologically with bytewise ties. As each module's
   dependencies settle, the coordinator runs `incremental.verdict(record,
   plan)`. A hit calls `driver.restore_source_object` in-process and records
   the accepted certificate in the plan (`plan.update`). A miss spawns a
   short-lived worker process (`titan-compiler.build_worker`) that compiles
   only that module against the coordinator's frozen plan; the coordinator
   validates and publishes the staged objects and then calls
   `driver.restore_source_object(..., { published = true })`. See
   [Compiler-owned build coordinator](build-coordinator.md).
2. **In-process loader (`load_source_object` in `driver.defaultloader`).**
   Programmatic callers that run `driver.defaultloader` directly with
   `incremental = true` (and without `plan_mode` or `worker_plan`) certify in
   one process. `load_source_object` computes
   `driver.incremental_configuration(context)`, runs
   `incremental.certify_local(context, modname, source)`, and—because certified
   own-source bytes fix the exact import list a fresh parse would make—loads
   `certified.imports` recursively through `loader` while `driver.imported[modname]`
   holds `CIRCULAR_MARK`. It then evaluates `incremental.verdict` against
   `resolver_plan(context, static_deps)`. In this single-pass in-process mode,
   a source dependency that missed and was freshly checked in the same
   invocation has not yet run code generation and therefore has no self digest;
   `verdict` returns `status = "pending"`, which `load_source_object` converts
   into a `dependency-rebuilt <names>` miss. When `verdict` returns `"hit"`,
   `load_source_object` calls `restore_source_object`.

`restore_source_object` first reattaches any `entry.ffi_header_descriptor` to
the current invocation's selected `entry.source_imports` descriptors and
materializes the checking `.ffi.h` (`ffiheaders.materialize`) and, when
`native.foreign_header` is present, the checking `.titan.h` helper file. If a
recorded import or source-import FFI descriptor is missing or still marked
circular before any resolver table is mutated, `restore_source_object` returns
`nil, "dependency-unavailable", name` so the caller treats it as a reuse miss.
Once checking headers are ready, it populates `entry` (`filename`,
`source_files`, `native_output`, `program_output`, `compiled`,
`compiled_objects`, `has_main`, `test_functions`, `external_symbols`,
`private_symbols`, `native_references`, `deps`, `interface_digests`), merges
`entry.declared_registry` into `types.registry`, publishes
`driver.imported[modname] = entry` and `static_deps[modname] = true`, and
registers the module interface via `checker.register_module_interface`. When
`context.probe_verbose` (`-v`) is set and the call is neither a worker
restoring a parent-certified dependency (`worker_plan`) nor the coordinator
loading a just-published worker result (`published = true`), it writes
`Titan object hit <modname>: <object>` to `stderr`.

### Failure-to-miss and cancellation discipline

Filesystem and decode failures are classified by where they occur:

* **Configuration inventory errors fail the invocation.**
  `driver.incremental_configuration(context)` and
  `incremental.configuration(context, options)` fail with
  `cannot certify compiler configuration: <detail>` when a loaded compiler Lua
  file, the executing frontend script, the native compiler/stage tools, or the
  shared preamble probe cannot be read or executed. A toolchain that cannot
  inventory itself cannot compile fresh modules either.
* **Per-object certification errors become reuse misses.** During
  `certify_local`, `verdict`, and the pre-mutation prefix of
  `restore_source_object`, any string error from reading or decoding the
  object, hashing source constituents, checking split parts or coverage notes,
  or revalidating C header inputs is caught and returned as `{ status = "miss",
  reason = <code>, detail = <detail> }`. Under `-v`, the compiler logs
  `Titan object miss <modname>: <code>[ <detail>]` and recompiles the module
  from source instead of aborting the build.
* **Non-string errors always propagate.** Cooperative cancellation tokens
  raised by a host `context.io` strategy or `cache_adapter` are non-string Lua
  values; every `pcall` boundary in `incremental.lua`, `cdriver.lua`, and
  `driver.lua` rethrows `type(err) ~= "string"` with `error(err, 0)`.

## Trusted source record

Each compiled primary object `<stem>.o` carries two metadata sections:

1. the public `.titan.meta` (ELF and COFF) or `__TEXT,__titanmeta` (Mach-O)
   section consumed by archive and provider readers; and
2. the compiler-private `.titan.source` (ELF and COFF) or `__TEXT,__titansrc`
   (Mach-O) section (`titan-compiler/objectmetadata.lua`, symbol
   `titan_object_source_<mangled>`), appended to part 0's generated C after
   `#line` normalization or coverage marker conversion.

Sidecar `.part<k>.o` objects from a split module carry neither section. Both
sections use the same byte alignment, `used` attribute retention,
relocation-free string representation, and Clang AddressSanitizer exclusion,
and are located in-process by `staticmetadata.read_object_section` (including
COFF long section names via the string table).

### Record envelope and version gates

`objectmetadata.encode(entry, native)` (`titan-compiler/objectmetadata.lua:64-77`)
projects `entry` through `projectcache.project_declarations(entry)`, attaches
`projected.object_metadata = native`, and serializes a table-allocating Lua
chunk (`-- Titan object source metadata`) returning the envelope:

```lua
{
    abi = version.TITAN_ABI_VERSION,        -- "2"
    schema = version.OBJECT_RECORD_SCHEMA,  -- "1"
    digest = version.CERTIFICATE_DIGEST,    -- "sha256"
    module = projected.type.name,
    entry = projected,
}
```

All version constants live in `titan-compiler/version.lua`:

| Constant | Value | Role |
| --- | --- | --- |
| `version.TITAN_ABI_VERSION` | `"2"` | Generated-code and provider binary ABI. Never used as a cache-invalidation knob. |
| `version.OBJECT_RECORD_SCHEMA` | `"1"` | `.titan.source` envelope and `object_metadata.certificate` layout version. |
| `version.TITAN_LINK_RECORD_SCHEMA` | `"1"` | Final-link record schema (`titan-compiler/linkcertificate.lua`). |
| `version.TITAN_NATIVE_RECORD_SCHEMA` | `"1"` | `--c-source` native-object record schema (`titan-compiler/nativeinputs.lua`). |
| `version.CERTIFICATE_DIGEST` | `"sha256"` | Digest algorithm for object, native-C, and final-link certificates. |
| `version.CERTIFICATE_CANONICALIZATION` | `"titan-certificate-v1"` | Tagged structural canonicalization prefix for `incremental.digest`. |
| `version.BUILD_WORKER_PROTOCOL` | `"titan-build-worker-v1"` | Coordinator-to-worker RPC protocol (`titan-compiler/build.lua`). |
| `version.C_HEADER_FILE_PROTOCOL` | `"c-header-file-v3"` | Content-only C header file identity prefix. |
| `version.C_HEADER_SEARCH_PROTOCOL` | `"c-header-search-v2"` | C include search-candidate identity prefix. |
| `version.C_HEADER_ORIGIN_PROTOCOL` | `"c-header-origin-v1"` | Declaring-header realpath origin identity prefix. |
| `version.C_HEADER_CACHE_VERSION` | `8` | Persistent `c-header-v8` extracted declaration cache version. |
| `version.PROJECT_CACHE_VERSION` | `6` | Persistent language-server project-manifest version. |
| `version.SOURCE_INTERFACE_FORMAT` | `"titan-source-interface-v2"` | Source-private declaration manifest format (`titan-compiler/sourceinterface.lua`). |
| `driver.LANGUAGE_SERVER_API_VERSION` | `1` | Long-lived semantic-client API handshake (`titan-compiler/driver.lua`). |

`objectmetadata.decode(payload, origin, expected_abi)` loads the chunk in an
empty environment (`load(payload, "@" .. origin, "t", {})`) and checks the
envelope before inspecting the projected entry:

* chunk load or execution failure returns `nil, err, "record-unreadable"`;
* a non-table envelope, `record.schema ~= version.OBJECT_RECORD_SCHEMA`,
  `record.digest ~= version.CERTIFICATE_DIGEST`, `record.abi ~= expected_abi`,
  or a non-table `record.entry` returns `nil, err, "record-schema"`;
* invalid split-part metadata in `objectmetadata.validate_parts(native)` returns
  `nil, err, "parts"`; and
* invalid `native.layouts` in `nominallayout.decode(native.layouts,
  record.module)` returns `nil, err, "record-unreadable"`.

There is no historical record migration: objects written by an older schema or
without a valid `object_metadata.certificate` miss with `record-schema` and are
recompiled. When a programmatic caller invokes `driver.compile` without a
resolver context or with a source dependency whose self digest was not
computed, `prepare_compile` still emits a valid `.titan.source` record without
`native.certificate` (printing `Titan object uncertified <modname>: <err>`
under `-v`); any later `--incremental` check rejects that object with
`record-schema`.

## Certificate canonicalization and fields

### Tagged canonicalization and invocation file memos

`incremental.digest(context, tag, value)` (`titan-compiler/incremental.lua:33-76`)
serializes `{ version.CERTIFICATE_CANONICALIZATION, tag, value }` through
`canonical` and hashes the resulting bytes with SHA-256 via
`context.cache_adapter.sha256_binary` (`titan._sha256_binary`, falling back to
`titan-compiler/sha256.lua` only in pure-Lua test harnesses):

* `nil` encodes as `"n"`;
* `boolean` encodes as `"b1"` or `"b0"`;
* `string` encodes as `"s" .. #value .. ":" .. value`;
* finite `number` encodes as `"d" .. #text .. ":" .. text`, using `tostring`
  for integers and `string.format("%a", value)` for floats;
* `table` encodes as `"t" .. #keys .. ":"` followed by each encoded key and
  value, with keys sorted deterministically by Lua type (`boolean` < `number` <
  `string`), then `false` before `true`, `<` for numbers, and
  `util.bytewise_less` for strings.

Cycles, non-finite numbers, and non-scalar table keys raise an assertion error.

`incremental.file_digest(context, path, bytes)` (`incremental.lua:108-142`)
hashes each distinct file at most once per resolver context:

1. It resolves `key = context.io:realpath(path)` (caching `path -> key` in
   `memo.aliases`) and returns `saved.digest, saved.bytes` when `memo.files[key]`
   already exists. If caller-supplied `bytes` differ from `saved.bytes`, it
   raises `<path>: file changed during build`.
2. When `bytes` is nil, it records a pre-read observation combining
   `context.io:stat(path)` (which must be `kind == "file"`) and
   `context.io:lstat(path)`, reads the file through `context.io:read_file(path)`,
   and checks that the post-read observation and `realpath(path)` are
   identical; any mismatch raises `<path>: file changed while it was read`.
3. It hashes the bytes, records `{ digest, bytes }` in `memo.files[key]`,
   updates `incremental.counters(context)` (`file_hashes`, `file_reads`,
   `file_bytes`, `digest_calls`, and `files[key]`), calls `context.io:yield()`,
   and returns `digest, bytes`.

The driver wires `context_file_digest(context)` into `cdriver`, `cprobe`, and
`check_source_module`, so C-header parsing and object certification share the
same per-context file memo. Only a publisher that replaces an owned output
calls `incremental.invalidate_file(context, path)` to evict `path` and its
aliases from the memo.

### Certificate layout

`incremental.make_certificate(context, entry, native, inputs)`
(`incremental.lua:434-475`) builds `native.certificate`, and
`valid_certificate(value, modname)` (`incremental.lua:492-540`) validates its
closed shape before any field is trusted:

| Field | Shape | Meaning |
| --- | --- | --- |
| `configuration` | `{ digest, compiler, preamble, toolchain, options }` | Invocation-wide configuration digests (all strings). |
| `layout` | `"flat"` \| `"folder"` | Source module layout from the tagged source resolver. |
| `sources` | `{ { path, sha256 }, ... }` | Dense ordered own-source list (main first, then bytewise-sorted contributors). |
| `stem` | `string` | Normalized absolute output stem (`<stem>.o` without `.o`). |
| `codegen` | `{ c_parts, split_threshold, test_flags, coverage? }` | Per-module code-generation policy (`coverage` is `nil` or `{ enabled, backend }`). |
| `imports` | `{ { name, source_required, view, interface }, ... }` | Direct imports in declaration/constituent order (`view` is `"source"` or `"public"`). |
| `owners` | `{ { name, interface }, ... }` | Bytewise-sorted contextually exposed nominal owners not in `imports` or `{modname}`. |
| `bindings` | `{ [name] = "direct" \| "handle" \| "global" }` | Coder native binding mode per referenced module (`name` must be self, an import, or an owner). |
| `providers` | `{ [name] = <string> }` | Selected dynamic provider relative filename (`type.file`) per handle-bound direct import. |
| `interface` | `{ public = <hex>, source = <hex> }` | Producer self digests computed from this module's coder outputs. |
| `object_identity` | `<hex>` | Recipe digest over configuration, module name, stem, codegen options, generated C parts before record injection, and `.priv.h`. |

## Configuration, toolchain, and preamble certificates

`driver.incremental_configuration(context)` installs
`context.incremental_options` (`driver.lua:4255-4315`) and calls
`incremental.configuration(context, options)` (`incremental.lua:359-381`) once
per resolver context. The resulting table `{ digest, compiler, preamble,
toolchain, options }` is memoized at `context.incremental_configuration`. In a
multi-module build, the coordinator computes it once and passes it to workers
via `driver.worker_configuration(context)`; each worker recomputes only
`compiler` (`incremental.compiler_component`) in `driver.new_worker_context` to
verify that the loaded compiler Lua files did not change after the coordinator
started.

The four component digests are stored separately in the record so a mismatch
reports the exact component:

1. **`compiler` (`incremental.compiler_component`, `incremental.lua:161-196`).**
   Locates the loaded compiler root from `DRIVER_SOURCE` (the directory
   containing the loaded `titan-compiler/driver.lua`, never `package.searchpath`
   or `PATH`), lists every `*.lua` file directly inside `titan-compiler/`,
   `titan-compiler/checker/`, `titan-compiler/coder/`, and `c-parser/`, and
   hashes each file as `{ path = <relative>, length = #bytes, sha256 = <hex> }`.
   It adds the executing frontend script passed as `context.frontend` (`arg[0]`
   from `titanc`, which in a LuaRocks installation is the real
   `lib/luarocks/rocks-5.5/titan/<version>/bin/titanc` script rather than the
   outer wrapper; programmatic callers without `frontend` record `{ path =
   "titanc", api = true }`). Entries are sorted bytewise by `path` and hashed
   with tag `"compiler"`.
2. **`toolchain` (`incremental.toolchain_identity`, `incremental.lua:247-308`).**
   Combines:
   * `cdriver.preprocessor_cache_identity(configured)` (`c-parser/cdriver.lua:457-464`,
     `cpp.lua:1278-1303`), which covers the compiler argv, C99 language flags,
     probed system include directories, a digest of all predefined macros, and
     content identities of any forced `-include`/`-imacros` files;
   * the raw output of the compiler's `-E -v` probe (`preprocessor_banner`),
     capturing vendor, package release, target triple, and `InstalledDir`;
   * the target profile identity (`driver.TARGET_PROFILE.identity`); and
   * `incremental.physical_executable` records (`{ path = realpath, size,
     device, inode, mode, modified_seconds, modified_nanoseconds,
     changed_seconds, changed_nanoseconds, time_precision }`) for the resolved
     compiler driver (`cc[1]`), any explicit compiler wrapped by `ccache`,
     `sccache`, or `distcc` (`cc[2]`), and the stage executables returned by
     `<cc + flags> -print-prog-name=<stage>` (`cc1` and `as` for non-Clang
     compilers; `as` for Clang only when `-fno-integrated-as` is active and not
     overridden by a later `-fintegrated-as`).

   Tool executables are certified by self-description plus physical metadata
   rather than by hashing the compiler binary bytes. On POSIX, `changed_seconds`
   (`ctime`) catches preserved-mtime replacements (`cp -p`, `touch -r`). An
   in-place, same-size binary overwrite within the same coarse timestamp tick
   (or on Windows where LuaFileSystem `ctime` is creation time), or an
   unrecognized wrapper script that hides a changed downstream binary without
   changing `-E -v` or `-dM` output, is outside physical tool detection.
3. **`preamble` (`incremental.preamble_identity`, `incremental.lua:322-357`).**
   Every generated module includes the fixed C preamble from
   `titan-compiler/cpreamble.lua`, even when the Titan source contains no
   `foreign import`. `cpreamble.include_constants` (`cpreamble.lua:10-35`) is
   the single include list shared by emitted module preambles
   (`cpreamble.fixed_includes`, `module = true` entries) and the certification
   probe (`cpreamble.certification_includes`, which adds `"lua.h"`,
   `"lualib.h"`, `<titan/ffi.h>`, and platform-guarded `<windows.h>`,
   `<wchar.h>`, `<unistd.h>`, `<limits.h>`, and `<mach-o/dyld.h>`). The driver
   places the probe translation unit at the stable path
   `<output_root or first source root>/.titan/preamble.c` and rewrites it only
   when its text differs, keeping `__FILE__` and `__BASE_FILE__` expansions in
   forced headers invariant across runs. `preamble_identity` runs
   `<compile_prefix> -E -dD -P -MD -MF <tmp> -MT titan-preamble -x c <source>`,
   parses the depfile with `depfile.parse` (`titan-compiler/depfile.lua`), and
   hashes `{ expanded = <stdout>, inputs = { { path, realpath, sha256 }, ... } }`
   over all external depfile prerequisites (excluding the synthetic
   `preamble.c` path itself). Hashing both the `-E -dD -P` output and the
   prerequisite file bytes catches system-header edits, SDK header edits
   (`titan.h`, `transfer.h`, `titan/ffi.h`, Lua internal headers), new
   shadowing headers in `-I`/`-isystem`, and `__has_include` branches that
   alter declarations or macros without adding a positive depfile entry.
4. **`options` (`incremental.lua:366-371`).** Hashes `{ compile_prefix,
   build_profile, emit_line_directives, pretty_print, extra_ffi_include_dirs,
   titan_root }` with tag `"compile-options"`. Module-resolution flags
   (`--source-first`, `--static`, `--test`'s source-first preference), `--jobs`,
   and link-only options (`-L`, `-l`, `-X`, `--ldflag`, `--exe`) are excluded:
   resolved dependency bindings are checked per module in `verdict`, allowing
   application and `--test` builds in the same output tree to share unchanged
   production objects.

## Own-source content and folder membership

`incremental.source_certificate(context, source, contents_by_path)`
(`incremental.lua:383-393`) records `layout = source.kind` (`"flat"` or
`"folder"`) and `sources = { { path, sha256 }, ... }` in the tagged source
resolver's canonical order: `source.main` first, followed by bytewise-sorted
immediate folder contributors (`source.files`). Paths use the exact spelling
that `driver.lua` embeds in `#line` directives.

During stage 1 certification, `source_verdict(context, source, certificate)`
(`incremental.lua:542-571`) compares the freshly resolved `source` descriptor
against `certificate`:

* any contributor path present in `certificate.sources` but absent from
  `source.files` misses with `source-set removed <path>`;
* any path present in `source.files` but absent from `certificate.sources`, a
  flat/folder `layout` change, or an ordering change misses with
  `source-set added <path>`; and
* each file in `source.files` is hashed via `incremental.file_digest`; any read
  error or SHA-256 mismatch misses with `source-content <path>`.

The bytes read during `source_verdict` are stored in
`source.certified_contents[path]`. When a module misses and falls back to
`parse_source_inner` (`driver.lua:5350-5355,5435-5443`), the parser consumes
`source.certified_contents[filename]` rather than re-reading the file from disk,
and `prepare_compile` passes that precomputed `entry.source_certificate` into
`incremental.make_certificate`. The new object record therefore certifies the
exact source bytes that were parsed and compiled.

## Semantic C header identity summary

Each module record retains `c_header_dependencies` and, when FFI headers exist,
`ffi_header_descriptor.search_inputs`. Header identities separate semantic
content and nominal scope from physical observation metadata
([FFI internals](ffi-internals.md#header-file-search-and-origin-identities)):

* **`file` (`c-header-file-v3:sha256:<hex>` or
  `c-header-file-v3:unreadable:<search-identity>`).** Readable files are
  identified solely by their SHA-256 content digest. Physical `lstat`/`stat`
  attributes (`precision = "ns" | "coarse"`, `size`, `physical_identity`,
  `modified_seconds`, `modified_nanoseconds`, `changed_seconds`,
  `changed_nanoseconds`) live in `input.observation`, where they serve only as
  a metadata fast path when a host I/O strategy declares `precision == "ns"`
  with valid `changed_seconds` (`ctime`) and as a before/after read-race guard.
  Under synchronous `titanc` (`time_precision = "coarse"`), `revalidate_header_input`
  reads and hashes each distinct header once per invocation through the shared
  `context.header_validation` pass and `context.file_digest` memo.
* **`search` (`c-header-search-v2;exists=<yes|no>;kind=<kind|missing>;open=<readable|unreadable>`).**
  Records `lstat` existence, followed `stat` kind, and effective readability for
  every candidate path probed before and at the winning header, so a newly
  created shadowing header in an earlier `-I` directory invalidates the closure.
* **`origin` (`c-header-origin-v1;real=<realpath>`).** Recorded for every real
  (non-generated) header whose lines reach parsed output
  (`cdriver.declaration_scope_resolver`). Because exported C struct, union, and
  typedef identities derive their nominal `_ffi_scope` from
  `sha256("physical-header\0" .. realpath)`, certifying `origin` separately from
  `file` ensures that retargeting a symlink or directory link to another
  realpath with identical bytes misses with `c-input <path>: provenance` while
  republishing identical bytes at the same nominal origin hits.

`check_headers(context, record)` (`incremental.lua:631-666`) validates the
deduplicated union of `record.c_header_dependencies` and
`record.ffi_header_descriptor.search_inputs` during `certify_local`, before any
declarations or checking `.ffi.h` descriptors are restored. Any changed,
missing, unreadable, or racing input returns
`c-input <path>: content|provenance|missing|unreadable|candidate|changed-during-read`.

## Interface digests, contextual owners, and bindings

### Producer self digests and per-module binary digests

When a source module is prepared for compilation (`prepare_compile` in
`driver.lua:7975-7989`), `incremental.producer_digests(context, source_entry,
encoded_layouts, ast._foreign_header_recipe)` (`incremental.lua:395-408`)
computes two self digests from the coder's exact outputs and stores them in
`certificate.interface`:

```text
public = digest("public-interface", {
    types.serialize_semantic(entry.type),
    encoded_layouts,
    rendered_foreign_helper_or_empty,
})
source = digest("source-interface", {
    public,
    entry.source_manifest,
})
```

* `types.serialize_semantic(entry.type)` serializes the public `Type.Module`
  graph with documentation comments stripped.
* `encoded_layouts` is the exact string emitted into `<mangled>_layouts`
  (`nominallayout.encode`), capturing public record/union sizes, alignments,
  traced uservalue counts, and native field offsets—including private fields of
  public records that change physical layout without changing the semantic type.
* `rendered_foreign_helper_or_empty` is `ffiheaders.foreign_contents(recipe,
  "module.ffi.h", ...)` when the module exports or defines source
  `foreign function` helpers in `.titan.h`, and `""` otherwise.
* `entry.source_manifest` is `sourceinterface.serialize(entry)`
  (`titan-source-interface-v2`), which adds private top-level declarations,
  inherited C-header input identities, and documentation maps for explicit
  `.titan` source importers.

Because `interface.public` and `interface.source` are stored in the producer's
own `.titan.source` record and read back verbatim on a hit, a freshly compiled
producer and a restored producer always expose identical interface digests. An
implementation-only edit to a producer's function bodies changes neither digest,
allowing consumers to hit via early cutoff without recompiling. Whole-interface
digests are conservative: changing any public export invalidates all ordinary
importers of that module, and editing a documentation comment in a
`.titan`-imported module invalidates its explicit-source importers.

For a binary dependency (`kind == "dynamic"` or `"static"`),
`incremental.interface_digest(context, entry, "public")`
(`incremental.lua:410-432`) hashes `{ types.serialize_semantic(entry.type),
entry.layouts, "" }`, memoized per `(provider_path, module_name)`. Each logical
module inside a combined provider such as `titan.so` or `titan.a` is
fingerprinted individually from its own `_types` and `_layouts` symbols; whole
provider file bytes and timestamps never enter consumer module certificates.

### Direct imports, contextual owners, and binding verification

`incremental.make_certificate` records two dependency lists and two binding maps:

* `certificate.imports`: every direct import in `native.imports`, with
  `source_required`, `view = source_required and "source" or "public"`, and
  `interface = plan.digest(name, view)`.
* `certificate.owners`: every logical module in
  `(keys(ast._binary_usage) ∪ keys(native.bindings)) \ ({entry.type.name} ∪ direct_imports)`,
  sorted bytewise, with `interface = plan.digest(name, "public")`.
  `ast._binary_usage` (`titan-compiler/checker/binary_usage.lua`) tracks every
  module whose functions, variables, or nominal types the checked code uses,
  including nominal owners recovered contextually through another module's
  return or field types (`recover_contextual_owner` in `driver.lua:5577-5664`).
* `certificate.bindings` and `certificate.providers`: the coder's native
  binding map (`"direct"`, `"handle"`, or `"global"`) and selected dynamic
  provider map (`provider_file` for direct dynamic imports).

In stage 2, `incremental.verdict(record, plan)` (`incremental.lua:766-826`)
checks the decoded certificate against the final resolution `plan`:

1. For every entry in `cert.imports` (using `item.view`) and `cert.owners`
   (using `"public"`), it queries `plan.digest(name, view)`. If the dependency
   is not yet available in the plan (`status == "pending"`), `name` is added to
   the pending list; if it is unavailable, `verdict` returns
   `miss("dependency-unavailable", name)`; if the digest differs from
   `item.interface`, `verdict` returns
   `miss("import-interface", "<name> (<view>)")` or
   `miss("owner-interface", name)`.
2. For every module name in `keys(cert.bindings) ∪ keys(cert.providers)`, sorted
   bytewise, `verdict` computes the expected binding from the plan:
   * `linked = (name == modname) or plan.linked(name)` (true when `name` is a
     source module in the build or carried by a selected static archive);
   * `provider = (name ~= modname) and plan.provider_file(name) or nil`;
   * `expected = linked and "direct" or (direct[name] and provider and "handle" or "global")`;
   * `expected_provider = (not linked and direct[name]) and provider or nil`.

   If `cert.bindings[name]` (when present) differs from `expected` or
   `cert.providers[name]` differs from `expected_provider`, `verdict` returns
   `miss("import-binding", "<name>: <before> -> <after>")` for a direct import
   or `miss("owner-binding", "<name>: <before> -> <after>")` for a contextual
   owner.
3. If any dependency was pending and no earlier check missed, `verdict` returns
   `{ status = "pending", names = pending }`; otherwise it returns
   `{ status = "hit" }`.

## Certification ordering and `-v` miss vocabulary

`incremental.certify_local(context, modname, source)` (`incremental.lua:668-726`)
evaluates local evidence in a fixed order before any dependency check:

1. **Object presence and readability.** `context.io:lstat("<stem>.o")` must
   succeed (`record-unreadable <err>` on a string `lstat` error) and report
   `kind == "file"` (`no-object` when missing or non-regular). The object bytes
   are read and hashed via `incremental.file_digest`.
2. **Record envelope and schema.** `objectmetadata.read(bytes, path)` must
   decode a current-schema record (`record-unreadable` or `record-schema` or
   `parts`), `record.object_metadata.certificate` must pass
   `valid_certificate(cert, modname)` (`record-schema missing or invalid
   certificate`), and `record.type.name` must equal `modname`
   (`record-schema module name mismatch`).
3. **Own-source pre-check for planner imports.** `source_verdict` runs next so
   that whenever own-source membership and content hashes match,
   `result.imports = cert.imports` is returned to the coordinator planner even
   if a configuration or downstream check misses.
4. **Configuration components.** Compares `cert.configuration[component]`
   against `context.incremental_configuration[component]` in order `compiler`,
   `preamble`, `toolchain`, `options`, returning
   `configuration <component>` on the first mismatch.
5. **Own-source verdict and output location.** If step 3 failed or missed,
   returns `source-set added|removed <path>` or `source-content <path>`. Then
   checks `cert.stem == stem`, returning `output-moved` if the output tree
   moved.
6. **Code-generation options.** Compares `cert.codegen[key]` against
   `opts.codegen_options(modname, record)[key]` in order `c_parts`,
   `split_threshold`, `test_flags`, `coverage`, returning
   `codegen-options <key>` on the first mismatch. `driver.test_owner_flags`
   applies `test_runner.TEST_COMPILE_FLAGS` (`-fno-optimize-sibling-calls`)
   only when `test_build` is true and `test_functions` is nonempty, so
   test-owner modules compiled without `--test` miss with
   `codegen-options test_flags` while ordinary production modules remain
   reusable across application and `--test` builds.
7. **Split parts (`check_parts`).** Validates generated C companions, primary
   and sidecar `.part<k>.o` objects, and target fingerprints (`parts <detail>`).
8. **Coverage notes (`check_coverage`).** Validates `.c` and `.gcno` files when
   coverage is enabled (`coverage-artifacts <path>`).
9. **C header closure (`check_headers`).** Revalidates all recorded `file`,
   `search`, and `origin` inputs (`c-input <path>: <reason>`).

The complete `-v` object-decision vocabulary written to `stderr` is:

| `-v` stderr line | Emitted when |
| --- | --- |
| `Titan object hit <mod>: <object>` | Stage 1, stage 2, and `restore_source_object` succeeded. |
| `Titan object miss <mod>: no-object` | Primary `<stem>.o` is absent or not a regular file. |
| `Titan object miss <mod>: record-unreadable <detail>` | Primary `.o` could not be read, lacked `.titan.source`, failed Lua load/execution, or had invalid layout metadata. |
| `Titan object miss <mod>: record-schema <detail>` | Envelope `schema`, `digest`, or `abi` differed, or `certificate` was missing/invalid. |
| `Titan object miss <mod>: configuration compiler\|preamble\|toolchain\|options` | Loaded compiler/frontend Lua, preamble header closure, native toolchain, or compile options changed. |
| `Titan object miss <mod>: source-set added\|removed <path>` | Folder contributor added/removed, path spelling changed, or flat/folder layout changed. |
| `Titan object miss <mod>: source-content <path>` | Main or contributor `.titan` file bytes changed or could not be read. |
| `Titan object miss <mod>: output-moved` | Current output stem differs from `certificate.stem`. |
| `Titan object miss <mod>: codegen-options c_parts\|split_threshold\|test_flags\|coverage` | Per-module split policy, test-owner compile flag requirement, or coverage selection/backend changed. |
| `Titan object miss <mod>: parts <detail>` | Recorded `.c`/`.priv.h`/`.part<k>.o` companion missing, non-regular, metadata-bearing, or target-mismatched. |
| `Titan object miss <mod>: coverage-artifacts <path>` | Coverage `.c` or `.gcno` file missing or inventory count mismatched. |
| `Titan object miss <mod>: c-input <path>: content\|provenance\|missing\|unreadable\|candidate\|changed-during-read` | Recorded C header file, search candidate, or declaring realpath origin changed. |
| `Titan object miss <mod>: dependency-unavailable <name>` | Recorded import or contextual owner could not be resolved or restored. |
| `Titan object miss <mod>: dependency-rebuilt <names>` | In-process `defaultloader` checked a dependency from source in the same pass before codegen produced its self digest. |
| `Titan object miss <mod>: import-interface <name> (public\|source)` | Direct import's public or source-private interface digest changed. |
| `Titan object miss <mod>: owner-interface <name>` | Contextually exposed nominal owner's public interface or layout digest changed. |
| `Titan object miss <mod>: import-binding <name>: <before> -> <after>` | Direct import's native binding (`direct`/`handle`/`global`) or dynamic provider path changed. |
| `Titan object miss <mod>: owner-binding <name>: <before> -> <after>` | Contextual owner's native binding (`direct`/`global`) changed. |

Before publishing a worker's newly compiled object, the coordinator calls
`incremental.revalidate_record(context, modname, freshly_resolved_source,
record)` (`incremental.lua:730-764`). It creates a private validation context
with empty `header_validation` and `header_observations` tables, strips
`certified_contents`, re-runs `source_verdict` and `check_headers` from disk,
and accumulates its I/O counts under `incremental.counters(context).revalidation`
(`passes`, `file_hashes`, `file_reads`, `file_bytes`, `digest_calls`, `files`)
without incrementing the warm hash-once counters. Any concurrent edit to a
module's sources or C headers while its worker was compiling therefore fails
publication instead of committing a mismatched certificate.

### Split modules

A [split module](codegen-overview.md#translation-unit-parts) is reused as a
complete unit or recompiled as a whole. The sole authority for split artifacts
is the `parts` list in the primary object's `.titan.source` record
(`record.object_metadata.parts`). After `codegen-options` verifies `c_parts`
and `split_threshold`,
`check_parts(context, record, stem, bytes)` (`incremental.lua:573-612`) and
`check_coverage(context, native, stem)` (`incremental.lua:614-629`) require:

1. `objectmetadata.validate_parts(native)` succeeds: `parts_version` is `1`,
   `parts` is a dense array whose entry `i` has `index = i - 1`,
   `c_suffix = ".c"` (or `".part<k>.c"`), and `object_suffix = ".o"` (or
   `".part<k>.o"`), `private_header` is `nil` when `#parts == 1` and
   `".priv.h"` when `#parts > 1`, and `c_parts` and `split_threshold` are
   valid integers.
2. Every recorded C file `<stem><c_suffix>` and, when split,
   `<stem>.priv.h` exists as a regular non-symlink file (`context.io:lstat`).
   Removing a generated `.c` or `.priv.h` companion therefore forces a `parts`
   miss and regenerates the complete set.
3. Primary `<stem>.o` scans via `staticmetadata.scan_bytes` as a valid native
   object for `version.TITAN_ABI_VERSION`.
4. For each sidecar part `index = 2 .. #native.parts`: `<stem>.part<k>.o` is a
   regular non-symlink file, is hashed via `incremental.file_digest` (so the
   final-link certificate reuses its memoized digest without reading the part a
   second time), scans as a valid object for `version.TITAN_ABI_VERSION`,
   carries neither public `.titan.meta` nor `.titan.source`, and matches the
   primary object's target fingerprint (`staticmetadata.fingerprint_matches`).
5. When `native.coverage` has `enabled = true`, `native.coverage.files` has
   `#native.parts` entries, and every part's `<stem><c_suffix>` and matching
   `.gcno` are regular non-symlink files.

A hit returns the ordered `objects` array (`<stem>.o` followed by
`<stem>.part1.o`, ...). When a module misses and is recompiled,
`driver.invalidate_source_object` (in coordinator builds) and `prepare_compile`
(in direct `driver.compile` calls) read the old primary object's validated
`parts` list before unlinking `<stem>.o` and remove only the recorded prior
`.part<k>.{c,o,gcno,gcda}` and marker-verified `.priv.h` paths, without
scanning directories or touching unrecorded files.

## Optimization across native objects

The default optimization and LTO flags are defined in [Compiling one
module](driver.md#compiling-one-module-drivercompile). Generated-object
compilation, `--c-source` nodes, and the shared/executable link helpers,
including archive-backed validation images and executable protocol probes, all
use them.

Linux fat objects retain native ELF sections for target inspection and both
Titan metadata protocols, alongside compiler IR. Archive extraction and
repacking preserve the member bytes, so the final compiler-driver link can
optimize across source objects or selected archive members. LTO does not
change the public provider protocol or dynamic binding boundaries. Do not replace
these objects with bitcode-only containers or disable native metadata gates to
accommodate an incompatible toolchain.

Normalized compile extras (`TITAN_EXTRA_CPPFLAGS`, `TITAN_EXTRA_CFLAGS`, and
CLI `-I`, `-D`, `--cflag`) enter `driver.generated_compile_prefix()` and are
certified in `configuration.options` and `configuration.toolchain`. Normalized
link extras (`TITAN_EXTRA_LDFLAGS` and CLI `-L`, `-l`/`--link`, `--ldflag`)
enter `driver.link_extra_flags()` and are certified in the final-link record
([Final-link certificate and gate](build-coordinator.md#final-link-certificate-and-gate)).
Cheap test fixtures use `TITAN_EXTRA_CFLAGS='-O0 -fno-lto'` and
`TITAN_EXTRA_LDFLAGS='-fno-lto'`.

The focused `spec/coder/lto_spec.lua` uses an unresolved symbol in a branch
which can only be eliminated after seeing another module's implementation. It
checks direct executable linking, shared publication, and a later standalone
consumer of Titan's own archive; disabling LTO exposes the unresolved symbol.

## Headers without an AST

A compiled object's record stores both the `.ffi.h` declaration descriptor
(`entry.ffi_header_descriptor`) and, when the module declares source foreign
functions, the `.titan.h` recipe (`native.foreign_header`) including local
direct-call helpers and their copied foreign bodies. Header planning
(`driver.plan_foreign_headers`) accepts restored object records alongside
freshly checked ASTs.

Compiler-owned include references identify logical module dependencies and are
rendered through the current output mapping. For example, the checking-tree
name `titan/http.ffi.h` differs from the folder module's native companion
`titan/http/http.ffi.h`; materialization resolves those owned references to
their current paths while preserving helper bodies.

Existing complete companions are left untouched on a hit. If a generated
`.ffi.h` or `.titan.h` file was removed from the output tree,
`driver.prepare_foreign_headers` (`titanc:587-589`) restores it from the
accepted record under the output-tree lock even when every module object and
the final link hit. Because rendered `.titan.h` helper contents enter the
producer's `interface.public` and `interface.source` digests, any change to a
copied foreign helper body or signature automatically invalidates importing
consumers with `import-interface`.

## Build and validation ownership

`titanc --incremental` owns Titan module-graph discovery, object certification,
worker scheduling, output-tree locking, `--c-source` compilation, `--test-dir`
root discovery, and final-link certification. External build systems (Make,
LuaRocks, CI workflows) retain:

* bootstrapping Lua and LuaRocks and preparing third-party native libraries
  (libuv, OpenSSL, SQLite, llhttp, LPegLabel, libbacktrace);
* running custom source or C code generators before invoking `titanc` (generated
  `.c` files can then be passed via `--c-source`);
* keeping the compiler installation, SDK, and source/header files stable while
  a `titanc` invocation runs;
* passing separate `--output` directories for incompatible build configurations
  when simultaneous preservation is desired (sharing one `--output` tree is
  safe and serialized by `.titan-build.lock`, but switching flags or profiles
  in place rewrites the affected objects); and
* packaging, installation, and executing test binaries.

See [Build and installation responsibilities](build-script-audit.md) for the
repository's `stdlib`, `titan-stdlib-test-build`, and coverage invocations, and
[Compiler-owned build coordinator](build-coordinator.md) for the scheduler,
worker transport, and link-certificate implementation.

Unit and contract coverage is split across:

* `spec/incremental_spec.lua`, `spec/depfile_spec.lua`, and
  `spec/staticmetadata_spec.lua` — canonicalization, hash-once file memos,
  read-race guards, preamble and depfile parsing, toolchain identity,
  `certify_local`/`verdict`/`revalidate_record`, and `.titan.source` envelope
  schema gating;
* `spec/driver_spec.lua` and `spec/coder/incremental_compilation_spec.lua` —
  SDK republishing (copy, hardlink, symlink), C-header content/missing/candidate/unreadable/provenance
  misses, producer body cutoff vs public/layout/source-private/helper changes,
  contextual owners and binding changes, configuration components, split and
  test-owner codegen options, folder contributor membership, and `-c
  --incremental` root certification; and
* `spec/coder/build_scheduler_spec.lua`, `spec/coder/link_certification_spec.lua`,
  `spec/coder/native_inputs_spec.lua`, `spec/coder/build_coordination_spec.lua`,
  `spec/coder/test_root_discovery_spec.lua`, and
  `spec/coder/compiler_build_scenarios_spec.lua` — end-to-end coordinator,
  worker, lock, native-input, final-link, and test-discovery contracts.
