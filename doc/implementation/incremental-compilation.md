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

1. the public `.titan.meta` (ELF, COFF, and Wasm) or `__TEXT,__titanmeta`
   (Mach-O) section consumed by archive and provider readers; and
2. the compiler-private `.titan.source` (ELF, COFF, and Wasm) or
   `__TEXT,__titansrc` (Mach-O) section (`titan-compiler/objectmetadata.lua`,
   symbol `titan_object_source_<mangled>`), appended to part 0's generated C
   after `#line` normalization or coverage marker conversion.

Sidecar `.part<k>.o` objects from a split module carry neither section. Both
sections use the same byte alignment, `used` attribute retention,
relocation-free string representation, and Clang AddressSanitizer exclusion,
and are located in-process by `staticmetadata.read_object_section` (including
COFF long section names via the string table, and Wasm DATA segments named in
the `linking` segment info).

### Record envelope and version gates

`objectmetadata.encode(entry, native)` (`titan-compiler/objectmetadata.lua`)
projects `entry` through `projectcache.project_declarations(entry)`, attaches
`projected.object_metadata = native`, and serializes a table-allocating Lua
chunk (`-- Titan object source metadata`) returning the envelope:

```lua
{
    abi = version.TITAN_ABI_VERSION,        -- "2"
    schema = version.OBJECT_RECORD_SCHEMA,  -- "1"
    digest = version.CERTIFICATE_DIGEST,    -- "sha256"
    canonicalization = version.CERTIFICATE_CANONICALIZATION,
                                            -- "titan-certificate-v1"
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
  `record.digest ~= version.CERTIFICATE_DIGEST`,
  `record.canonicalization ~= version.CERTIFICATE_CANONICALIZATION`,
  `record.abi ~= expected_abi`, or a non-table `record.entry` returns
  `nil, err, "record-schema"`;
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

`incremental.digest(context, tag, value)` (`titan-compiler/incremental.lua`)
serializes `{ version.CERTIFICATE_CANONICALIZATION, tag, value }` through
`canonical` and hashes the resulting bytes with SHA-256 via
`context.cache_adapter.sha256_binary` (`titan._sha256_binary`, which `titanc`,
build workers and every resolver context created without a caller adapter
use; `titan-compiler/sha256.lua` remains only for hosts without the native
support library, for caller adapters without a digest, and when a digest
callback fails with a string error or returns no 32-byte digest):

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

`incremental.file_digest(context, path, bytes)` (`incremental.lua`)
hashes each distinct file at most once per resolver context:

1. It resolves `key = context.io:realpath(path)` (caching `path -> key` in
   `memo.aliases`) and returns the saved digest when `memo.files[key]` already
   exists. If caller-supplied `bytes` differ from the saved bytes (or, for a
   digest-only entry, hash to a different digest), it raises
   `<path>: file changed during build`.
2. When `bytes` is nil, it looks for a recorded digest of the same file. A
   [fresh context](#fresh-verification-contexts) first consults its parent
   context's memo entry for `key`. Every context then consults the loaded
   [installed SDK digest manifest](#installed-sdk-digest-manifest) entry for
   `key`, then the coordinator's
   [persistent digest cache](#persistent-digest-cache) entry for the absolute
   path. If any of these exist, it re-observes the file once and accepts the
   first record, in that order, whose precise observation equals the current
   one, provided the path is readable. Content digests are file identity, so
   these sources apply to every file role: sources, headers, objects,
   payloads, providers, archives, system libraries, and outputs. A hit leaves
   the memo with a digest without bytes, recording the current observation and
   its size, and counts as `sdk_reuses` for a manifest entry and as
   `observation_reuses` otherwise.
3. Otherwise, when `bytes` is nil (no record, or a coarse or changed
   observation), it records a pre-read observation combining
   `context.io:stat(path)` (which must be `kind == "file"`) and
   `context.io:lstat(path)` and reads the file. A file larger than
   `incremental.STREAM_THRESHOLD_BYTES` (4 MiB) whose digest alone is
   demanded is fed into a new `sha256_stream` from the cache adapter through
   the strategy's optional `absorb_file` when both are available. The whole
   file never becomes a single Lua string and its bytes are not retained; with
   the native stream's `absorb` (as `titanc` supplies), no Lua string holds
   any of its bytes. Any other file is read whole through
   `context.io:read_file(path)`. Either way it then checks that the post-read
   observation and `realpath(path)` are identical and that the byte count
   matches a precise observed size; any mismatch raises
   `<path>: file changed while it was read`. Caller-supplied `bytes` are
   neither observed nor read.
4. It hashes the read or caller-supplied bytes (a streamed file is already
   hashed) and records `{ digest, bytes, observation, size }` in
   `memo.files[key]`, without bytes for a streamed file and without an
   observation for caller-supplied bytes or a coarse read. `size` is the
   measured byte count of the whole read, the stream, or the caller's bytes,
   kept whatever the observation's precision. Only a read with a precise
   observation is stored in the persistent cache or serves later observation
   reuse. It then
   updates `incremental.counters(context)` (`file_hashes`, `file_reads`,
   `file_bytes`, `observation_reuses`, `sdk_reuses`, `digest_calls`, and
   `files[key]`),
   calls `context.io:yield()`, and returns `digest, bytes, observation`.
   `size` stays private to the memo and the compiler inventory. Identical bytes
   under a changed observation hash to the recorded digest, so a touched but
   unchanged file still matches every digest certified for it.

A consumer that needs file bytes rather than a digest calls
`incremental.file_contents(context, path, max_bytes?)`, which always reads
whole. It reuses memoized bytes, or, after a digest-only memo entry (a reuse
from step 2 or a streamed digest), reads once under the same race guard,
retains the bytes, and raises `file changed during build` if the fresh
observation differs from the one that authorized the digest. A streamed
digest recorded without a precise observation is checked by content instead.

`incremental.check_headers` supplies the per-context file memo to
`revalidate_header_input` during certification, so certification hashes each
C header at most once per invocation. The driver also passes
`context_file_digest(context)` to `cprobe.new_service` and to fresh checking
options, but neither the probe service nor the checker retains it, so fresh
C-header parsing and C probes may hash files independently. Only a publisher
that replaces an owned output
calls `incremental.invalidate_file(context, path)` to evict `path` and its
aliases from the memo and the persistent cache.

### Fresh verification contexts

`incremental.fresh_context(context)` returns the context that every
verification after a build step uses: `incremental.revalidate_record` and the
uncertified source-snapshot check before staged module publication, the
post-compile and post-publication checks of a `--c-source` object, and the
post-link `linkcertificate.commit`. It starts with an empty memo whose parent
is the caller's memo and shares the caller's persistent cache and SDK
manifest. It therefore never trusts the caller's memo as is: each input is
re-observed, a recorded digest from the parent memo, the SDK manifest, or the
persistent cache is reused only under an equal precise observation, and a
file whose observation changed is read and rehashed. A file that first
appears during the step, such as a freshly linked output or staged object,
has no record and is hashed once. Only a content change fails verification,
and the digests computed there prime the persistent cache for the next
invocation. Compilation is not treated as adversarial: digests exist to avoid
rebuilding a file whose metadata changed while its content did not, so a
content change that preserves the complete precise observation, change time
included, is outside what verification detects. "Precise" describes the
observation API, which reports integer nanoseconds, not the filesystem's
timestamp granularity, and no portable API reports that granularity. On a
filesystem with coarse timestamps (one second on HFS+, ext3, and some NFS
servers), a same-size in-place rewrite within one tick that keeps the inode
therefore yields an equal observation and keeps the old digest. Titan
publishes its own outputs by rename, so only user-edited inputs and
externally rewritten libraries are exposed to this.

### Persistent digest cache

`incremental.load_digest_cache(context, output_root)` and
`incremental.save_digest_cache(context)` keep observation-keyed digests across
invocations in `<output>/.titan/digests`. `titanc` loads the cache right after
acquiring its output locks and saves it while closing the coordinator context,
before releasing them. Workers, source-adjacent builds without `--output`, and
programmatic contexts that never load a cache neither read nor write it.

The file is a `graphcodec` record of at most 32 MiB whose envelope carries
`schema = version.DIGEST_CACHE_SCHEMA` (`"1"`), `digest =
version.CERTIFICATE_DIGEST`, `canonicalization =
version.CERTIFICATE_CANONICALIZATION`, and `abi = version.TITAN_ABI_VERSION`,
plus two tables:

* `files[absolute_path] = { digest, observation }`, where `observation` holds
  `kind`, `dev`, `ino`, `size`, `mode`, `mtime_ns`, and `ctime_ns` with
  `precision = "ns"`. Only precise observations (integer nanosecond times and
  nonempty opaque `dev`/`ino` strings) are stored, so coarse metadata always
  rehashes.
* `objects[content_digest] = { fingerprint?, kind?, lto? }`, pure content
  facts: the target fingerprint of a split-part object
  (`incremental.part_fingerprint`), and the binary format (`archive`, `object`,
  `shared`, `thin`, or `unknown`) plus an LLVM-bitcode flag of a native link
  input (`incremental.native_input_kind`). Each fact is optional and written
  without disturbing the others; a missing fact is recomputed, and a kind fact
  never substitutes for the metadata-free part scan. The facts contain no
  paths, observations, or module views; callers still compare a fingerprint
  with the primary object's target. A persisted fingerprint must have the
  closed shape of its format: an ELF, Mach-O, or COFF table, or the Wasm
  table `{ format = "wasm", word_size = 32, linking_version = 2, features }`
  with a canonical feature list. `native_input_kind` classifies a relocatable
  Wasm object (version 1, with a `linking` custom section and no `dylink.0`)
  as a non-LTO `object` and an archive of them as `archive`; a linked or
  side-module Wasm file, another version, or a truncated one is `unknown`, and
  LLVM bitcode keeps reporting `object` with the LTO flag.

A `files` entry vouches for its digest only while the file's precise
observation is unchanged. A missing, unreadable,
oversized, malformed, or wrong-schema file loads as an empty cache, which the
next save replaces. A save runs only from the owning context and only when no
valid cache was loaded or an entry changed; it writes `digests.tmp.<unique>`,
renames it over the file, and removes the staging file on failure. `titanc`
ignores save errors so they cannot replace compilation diagnostics. Entries
are replaced in place and removed only by `invalidate_file`; there is no other
pruning.

### Installed SDK digest manifest

An installed SDK carries `lib/titan/<ver>/sdk-digests`
(`incremental.SDK_DIGESTS`, `driver.INSTALL_PATHS.sdk_digests`). It records
content digests of the installation's own native link inputs, so a fresh
output tree, or a build without `--output`, need not hash a large standard
provider or archive that has not changed since installation. Only the
installer writes it: `scripts/titan_install.lua` `publish` calls
`incremental.write_sdk_digests` with the just-installed provider's
`_sha256_binary`, `_stat_precise`, and, when that provider has it,
`_sha256_stream`. It covers exactly the approved SDK link
inputs (`sdk_link_inputs`): the Titan-owned `titan.so`, `titan.dll`,
`titan.a`, and `libtitan.a` directly under `lib/titan/<ver>/`, the copied
`lib/libbacktrace.a` when present, and the Lua archive that
`driver.installed_paths` links
(`lib/liblua.a`, or `lib/liblua55.a` on Windows). When Lua shares the prefix,
the installer records that prefix's existing Lua archive in place, without
copying, replacing, or taking cleanup ownership of it; a separate tree
records the archive the installer copied. Preserved or foreign files, even
inside the version directory, the `.dSYM` bundle, and headers are never
recorded. Each file is read under the ordinary read-race guard, streamed when
it is larger than `STREAM_THRESHOLD_BYTES` and the stream is available, and a
file
without a precise observation gets no entry. The manifest is replaced through
`sdk-digests.tmp.<unique>` and a rename. A payload without a loadable
compiler and provider writes none. The installer records the manifest path as
`digests` in its `installer/location.lua`. Uninstall removes that file only
when the recorded value has the exact form
`lib/titan/<major>.<minor>/sdk-digests`; any other value, including an
unrelated in-prefix name or a traversal, is ignored and the file kept. Payload
paths are contained by rejecting `.` and `..` components, splitting on both
`/` and `\` on Windows.

The file is a `graphcodec` record with `schema = version.SDK_DIGEST_SCHEMA`
(`"1"`), the same `digest`, `canonicalization`, and `abi` envelope as the
per-output cache, and `files[realpath] = { digest, observation }` validated
like the cache's `files`. An installed `titanc` loads it read-only with
`incremental.load_sdk_digests` right after the per-output cache. A missing,
unreadable, oversized, malformed, or foreign-schema manifest contributes no
entries, and `titanc` never writes it. A [browser](browser-target.md)
invocation loads only the browser manifest path
`lib/titan-browser/<ver>/sdk-digests` from its descriptor, never the native
manifest; while no browser SDK is installed it contributes nothing.

`titanc` applies no admission filter of its own: every valid entry is one
more recorded digest, trusted exactly like a cache entry in every context,
including the [fresh post-link recheck](#fresh-verification-contexts). The
file must have the same resolved path, an equal precise observation (`dev`,
`ino`, `size`, `mode`, and nanosecond `mtime` and `ctime`, which is
`ChangeTime` on Windows), and be readable. A Windows volume without
`ChangeTime` or file IDs yields only coarse observations, which never match
an entry, so the installer records no entry for them and `titanc` rehashes
them. A changed observation reads and
hashes the file; if those bytes differ from what the ticket certified, the
recheck fails with `link input changed during build`. Reuses count as
`sdk_reuses`.

### Certificate layout

`incremental.make_certificate(context, entry, native, inputs)`
(`incremental.lua`) builds `native.certificate`, and
`valid_certificate(value, modname)` (`incremental.lua`) checks the required
fields before any of them is trusted: their types, dense ordered lists, and
the name relationships among imports, owners, bindings, and providers. It
does not reject unknown extra keys:

| Field | Shape | Meaning |
| --- | --- | --- |
| `configuration` | `{ digest, compiler, preamble, toolchain, options }` | Invocation-wide configuration digests (all strings). |
| `layout` | `"flat"` \| `"folder"` | Source module layout from the tagged source resolver. |
| `sources` | `{ { path, sha256 }, ... }` | Dense ordered own-source list (the selected main first, then the selected contributors in bytewise order of logical filenames). |
| `stem` | `string` | Output stem with a compiler-owned root label when applicable (`<stem>.o` without `.o`). |
| `codegen` | `{ c_parts, split_threshold, test_flags, coverage? }` | Per-module code-generation policy (`coverage` is `nil` or `{ enabled, backend }`). |
| `imports` | `{ { name, source_required, view, interface }, ... }` | Direct imports in declaration/constituent order (`view` is `"source"` or `"public"`). |
| `owners` | `{ { name, interface }, ... }` | Bytewise-sorted contextually exposed nominal owners not in `imports` or `{modname}`. |
| `bindings` | `{ [name] = "direct" \| "handle" \| "global" }` | Coder native binding mode per referenced module (`name` must be self, an import, or an owner). |
| `providers` | `{ [name] = <string> }` | Selected dynamic provider relative filename (`type.file`) per handle-bound direct import. |
| `interface` | `{ public = <hex>, source = <hex> }` | Producer self digests computed from this module's coder outputs. |
| `object_identity` | `<hex>` | Recipe digest over configuration, module name, stem, codegen options, generated C parts before record injection, and `.priv.h`. |
| `roots` | `{ sdk?, compiler?, output? }` | Concrete original compiler-owned roots, used only to rebind named filesystem fields. |
| `generated` | `{ { spelling, bytes, sha256, semantic }, ... }` | Per-part generated-C filename at creation, metadata-free prefix length, and content/expanded-program digests. |

## Configuration, toolchain, and preamble certificates

`driver.incremental_configuration(context)` installs
`context.incremental_options` (`driver.lua`) and calls
`incremental.configuration(context, options)` (`incremental.lua`) once
per resolver context. The resulting table `{ digest, compiler, preamble,
toolchain, options }` is memoized at `context.incremental_configuration`. In a
multi-module build, the coordinator computes it once and passes it to workers
via `driver.worker_configuration(context)`. That closed worker configuration
always carries a top-level `compiler`, the installed compiler inventory
digest, and each worker recomputes that inventory
(`incremental.compiler_component`) in `driver.new_worker_context`, rejecting a
mismatch or an unreadable inventory, to verify that the loaded compiler Lua
files did not change after the coordinator started.

Only the explicit third result `"uncertified"` from the configuration or
toolchain identity (for example a Windows tool whose launcher policy cannot
be proven) selects raw compilation. The resolver then keeps
`incremental_configuration` nil and stores the reason separately as
`incremental_uncertified`, and the worker configuration carries
`uncertified = reason` instead of `configuration`. In that mode existing
objects are never reused: planning parses and selects fresh source, and
generated objects carry their ordinary metadata but no producer interface
digests and no certificate, so a later unchanged invocation still cannot hit.
The final link and `--c-source` nodes are likewise marked uncacheable. Any
other configuration failure is still an invocation error, and non-string
cancellations propagate unchanged.

Uncertainty limited to final output (an uncertain linker backend from
`driver.native_link_backend`, which is never memoized as a guessed backend,
or an uncertified final output tool) is a separate layer. It reaches only the
final-link request as its `uncacheable` reason, so that target's link ticket
neither hits nor records, while module objects and `--c-source` nodes keep
their own valid certificates and can still hit.

The four component digests are stored separately in the record so a mismatch
reports the exact component:

1. **`compiler` (`incremental.compiler_component`, `incremental.lua`).**
   Locates the loaded compiler root from `DRIVER_SOURCE` (the directory
   containing the loaded `titan-compiler/driver.lua`, never `package.searchpath`
   or `PATH`), lists every `*.lua` file directly inside `titan-compiler/`,
   `titan-compiler/checker/`, `titan-compiler/coder/`, and `c-parser/`, and
   hashes each file as `{ path = <relative>, length = <bytes>, sha256 = <hex> }`.
   It adds the executing frontend script passed as `context.frontend` (`arg[0]`
   from `titanc`, which in a Unix LuaRocks installation is the real
   `lib/luarocks/rocks-5.5/titan/<version>/bin/titanc` script rather than the
   outer wrapper, and on Windows the
   `share/lua/5.5/titan-compiler/titanc.lua` script that `titanc.exe` runs, so
   that file is hashed both as a `titan-compiler/` entry and as the frontend;
   programmatic callers without `frontend` record `{ path =
   "titanc", api = true }`). Each `length` is the file's measured byte count
   from the invocation memo: the whole read, the streamed count, or a precise
   reuse's current size. A file over the streaming threshold that is streamed
   under a coarse observation (a Windows volume without `ChangeTime` or file
   IDs, or a host strategy that reports coarse metadata) therefore keeps an
   exact length although that observation authorizes no reuse. Entries are
   sorted bytewise by `path` and
   hashed with tag `"compiler"`.
2. **`toolchain` (`incremental.toolchain_identity`, `incremental.lua`).**
   Describes which compiler installation runs, independent of the effective
   compile flags (those belong to `options`). The description argv is the
   complete tokenized `CC` command, kept verbatim because later words may name
   an interpreter script, wrapper arguments, or compiler options; on POSIX
   `perf.compiler_command` first drops a leading shell `exec` word, which is
   not an executable. The digest combines:
   * the predefined-macro dump of `<CC...> -dM -E -x c /dev/null` (`NUL` on
     Windows);
   * the `<CC...> -E -v -x c /dev/null -o /dev/null` banner, capturing vendor,
     package release, target triple, `InstalledDir`, and search directories.
     `stable_toolchain_banner` rewrites only the caller-dependent operands of a
     printed Clang `-cc1` action, `-fdebug-compilation-dir` and
     `-fcoverage-compilation-dir`, to `=<compilation-directory>`, so Apple
     Clang identities do not depend on the working directory; every other line
     and argument is kept; and
   * `incremental.physical_executable` records (it also returns, second, the
     admitted absolute command spelling, neither realpath-resolved nor
     lexically normalized, since POSIX `PATH` candidates keep their raw
     spelling through symlinked directories and `..`, for callers that must
     run exactly the certified tool) (`{ path = realpath, size,
     device, inode, mode, modified_*, changed_*, precision, dev, ino,
     mtime_ns, ctime_ns, time_precision }`) for the resolved compiler driver
     (`cc[1]`), any explicit compiler wrapped by `ccache`, `sccache`, or
     `distcc` (`cc[2]`), and the stage executables returned by
     `<CC + effective flags> -print-prog-name=<stage>` (`cc1` and `as` for
     non-Clang compilers; `as` for Clang only when `-fno-integrated-as` is
     active and not overridden by a later `-fintegrated-as`). The compiler
     counts as Clang only when a line of its `-E -v` banner is a
     `clang version <n>` version line; a "clang" that merely appears in an
     installation path does not. The same classification selects the
     `"llvm"` stage launcher policy, so stage inventory and launching agree.

   Both probes run through `cpp.cached_command` and are memoized per resolver
   context by description argv; the complete identity is memoized by command,
   flags, target profile, and executable path.

   For the [browser target](browser-target.md) the described compiler is
   the descriptor's `emcc` launcher, whose `-E -v` banner carries the
   Emscripten and Clang versions, and the toolchain descriptor carries
   `target_identity`, the descriptor identity. `toolchain_identity` adds it
   to the hashed details as `target_identity`, not only to its memo key, so
   every browser object certificate depends on the complete descriptor
   (tools, record, flags, include roots, profile, and policies). A host
   toolchain descriptor has no `target_identity`, and its details keep their
   original fields, so native certificates are unchanged.

   Executable admission follows the operating system's own choice. On POSIX,
   a name containing `/` is an explicit path and is checked directly, while
   any other name (backslashes and drive-letter prefixes are ordinary name
   characters there) walks `PATH` in order. When `PATH` is unset the
   launcher would use its own default search path, so the tool cannot be
   certified rather than being searched in the current directory. Either way
   admission takes the first regular
   file for which the I/O strategy's `executable(path)` capability reports
   `true` (effective-user `X_OK`, so owner-only or group-only execute bits
   are judged as the kernel would, and an execute-only file need not be
   readable); a missing capability or an indeterminate answer fails the
   selection rather than guessing from mode bits.

   On Windows, admission follows the launcher that will actually run the tool,
   and readability is never consulted:

   * **Direct launches** (the compiler driver and tools `titanc` starts
     itself) follow bundled libuv's spawn search. In each searched directory
     the exact name is tried only when its basename has a nonempty extension,
     then `<name>.com`, then `<name>.exe`; the suffixes are appended even to a
     name that already has one. An explicit path searches only its own
     directory. A bare name checks the current directory and then each `PATH`
     directory in order. The optional I/O capability
     `executable_search_cwd()` (native `NeedCurrentDirectoryForExePathW`)
     reports whether the launcher searches the current directory: `true`
     makes a current-directory hit win, `false` skips it, and when the answer
     is unavailable a current-directory hit that differs from the `PATH` hit
     cannot be certified. Directories are skipped; any other non-regular
     candidate cannot be certified.
   * **Compiler-reported LLVM stages** (selection `"llvm"`, an explicit path
     that Clang names in its job description) follow LLVM's own launcher: the
     exact path when it exists, otherwise the path with `.exe` appended. An
     existing non-file at either name is an error, and a bare LLVM stage name
     cannot be certified.
   * **Link entries**, under either policy: each existing candidate is also
     examined with `lstat`. An ordinary entry uses that metadata. A symbolic
     link or reparse-point entry is certifiable only when its target can be
     followed and its entry's raw `windows_attributes` DWORD is a valid value
     whose `FILE_ATTRIBUTE_DIRECTORY` bit agrees with the target's kind; a
     valid file link records the target's physical identity under the
     original admitted spelling. A dangling, unprovable, or kind-changing link
     entry makes the tool uncertified rather than falling through to the next
     suffix or `PATH` directory; only a genuinely absent candidate falls
     through.
   * **Any other selection policy**, such as an unknown producer or wrapper
     delegate, cannot be certified.

   A tool that cannot be certified makes `physical_executable` return
   `nil, reason, "uncertified"` instead of an identity. The build still runs
   with that tool; what loses reuse depends on which tool it is. An
   uncertified compiler configuration selects raw compilation (above): no
   module object, `--c-source` node, or final link can hit or record a
   certificate. When only a final output tool or the linker policy is
   uncertified, only that target's final-link ticket neither hits nor records;
   independently certified module objects and C nodes can still hit. A
   successful selection always returns the physical identity and, second, the
   admitted spelling of the candidate actually selected. Admission never reads
   tool contents.

   Tool executables are certified by self-description plus physical metadata
   rather than by hashing the compiler binary bytes. The change timestamp
   (`ctime` on POSIX, `ChangeTime` on Windows through the native precise stat)
   catches preserved-mtime replacements (`cp -p`, `touch -r`). A Windows
   volume that reports no `ChangeTime` leaves the identity without a change
   time (recorded with `"coarse"` precision). There a preserved-mtime
   replacement is caught only through a changed file ID or size, so an
   in-place same-size overwrite, or any such replacement on a volume without
   file IDs, is undetected. An in-place,
   same-size binary overwrite that preserves both timestamps (possible within
   one tick of the LuaFileSystem fallback's coarse clock or of a
   coarse-timestamp filesystem), or an unrecognized
   wrapper script that hides a changed downstream binary without changing
   `-E -v` or `-dM` output, is outside physical tool detection.
3. **`preamble` (`incremental.preamble_identity`, `incremental.lua`).**
   Every generated module includes the fixed C preamble from
   `titan-compiler/cpreamble.lua`, even when the Titan source contains no
   `foreign import`. `cpreamble.include_constants` (`cpreamble.lua`) is
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
4. **`options` (`incremental.lua`).** Hashes `{ compile_prefix,
   build_profile, emit_line_directives, pretty_print, extra_ffi_include_dirs,
   titan_root }` with tag `"compile-options"`. Module-resolution flags
   (`--source-first`, `--static`, `--test`'s source-first preference), `--jobs`,
   and link-only options (`-L`, `-l`, `-X`, `--ldflag`, `--exe`) are excluded:
   resolved dependency bindings are checked per module in `verdict`, allowing
   application and `--test` builds in the same output tree to share unchanged
   production objects.

## Compiler-owned root relocation

`titan-compiler/relocation.lua` separates a path's current I/O spelling from its
certified identity. Resolver contexts identify the selected SDK prefix, the
compiler's source checkout when applicable, and the output root. A path under
one of these roots receives a root label and relative suffix; the most
specific root wins. A symlinked root is not admitted as a relocatable binding.
Neither a user source root nor an arbitrary external include/provider/tool
directory becomes relocatable just because it appears in a command.
The reuse-on-move guarantee requires an explicit `-o`/`--output` tree.
Source-adjacent builds without it have no owned output root and miss
conservatively when moved; the user source directory is not added to the root
map.

Configuration hashing applies this mapping to known path operands in the
ordered compile argv, FFI include roots, the SDK root, and preamble dependency
paths and realpaths. Preprocessed preamble bytes are hashed unchanged.
Opaque flags and their separated operands, `-D` values, prefix-map options,
runtime search paths, and external paths keep their exact bytes. Bare absolute
argv elements are not inferred to be file operands; native source and link
input/output files have separate typed inventories. Browser certification
derives a root-relative view of the frozen descriptor's SDK paths without
changing its operational identity or external Emscripten tool selection, and
native and browser probes keep separate cache directories. Browser final-link
profiles carry their operational target identity and SDK-dependent flag lists,
so a moved browser SDK may miss its link certificate; browser final-link reuse
after a move is outside the native guarantee described here.

Generated FFI descriptor identities and their include operands use the same
mapping, rather than embedding an output-root address into every probe
source's environment-digest comment. The C parser's nominal declaring-header
identity is rooted only for these owned paths; the separately recorded origin
still checks the current realpath. Source-private header manifests and native
provider bindings likewise retain the relative selected input and its
content/interface evidence.
On Windows the rebound origin's realpath retains native path serialization,
matching the I/O strategy that records and revalidates it. Concrete path case
and semantic C strings are not folded or rewritten.

Compilation records each generated part's final C prefix, after formatting and
any coverage line conversion, before source-record injection. A binary read
supplies its byte count and digest; appending the primary source record uses
binary read/write to preserve that prefix. Formatting and coverage conversion
are text operations that precede this boundary.
`incremental.preprocessed_identities` preprocesses the metadata-free prefix
once, using the effective compile prefix, its actual quoted-include directory,
and macro-prefix mappings from the private temporary path and basename to
the actual generated filename and basename. The scratch source is made
absolute after registering cleanup, keeping those mapping keys distinct even
when an I/O strategy returns a relative name. GCC and Clang strip the basename
for `__FILE_NAME__` before applying the mappings. The resulting digest keeps all
expanded C bytes, including `__FILE__`, `__BASE_FILE__`, `__FILE_NAME__`, and
`__LINE__`; it does not substitute roots inside expanded strings.

The preprocessor leaves native presumed-location builtins unresolved. A
streaming lexical match detects `__builtin_FILE`, `__builtin_FILE_NAME`,
`__builtin_LINE`, `__builtin_COLUMN`, `__builtin_source_location`,
`__builtin_FUNCSIG`, `__PRETTY_FUNCTION__`, `__FUNCSIG__` and `L__FUNCSIG__`
after macro expansion, including token-pasted names, without allocating a
token graph. Quoted and GNU C raw strings, character constants, comments and
longer identifiers do not count as location reads. For affected parts, the
digest also includes the original generated prefix, filename and concrete SDK,
compiler and output roots. This conservatively rejects a moved location context even
when `-E -P` removes the relevant line information or leaves identical tokens;
an SDK-header origin remains significant when the output root stays fixed.
The basename, line and column values may be unchanged by a particular move,
but are not inferred from the stripped token stream. The source-location
aggregate is a C++ facility, not enabled by Titan's C compilation; its spelling
is conservatively recognized as well. Clang can print an anonymous C parameter
type's presumed file, line and column inside a signature.
Signature forms are treated as path-semantic on every toolchain, including
GCC C's name-only `__PRETTY_FUNCTION__` expansion; unadorned
`__builtin_FUNCTION`, `__func__`, `__FUNCTION__`, `L__FUNCTION__` and
`__FUNCDNAME__` do not add this location context.
See the [GCC builtin semantics](https://gcc.gnu.org/onlinedocs/gcc/Other-Builtins.html),
[Clang source-location semantics](https://clang.llvm.org/docs/LanguageExtensions.html#source-location-builtins),
and Clang's
[signature construction](https://github.com/llvm/llvm-project/blob/main/clang/lib/AST/Expr.cpp)
and [anonymous-type location printing](https://github.com/llvm/llvm-project/blob/main/clang/lib/AST/Decl.cpp).

Parts of one module run through `io.run_batch` under the resolver's local cap
and shared Make job-slot ledger when the strategy supports batching; custom
synchronous runners keep their own execution boundary unless they also supply
a batch override. The batch reaps every launched compiler and returns its exact
borrowed token bytes before preprocessing removes its source/output scratch.

An ordinary preprocessing or scratch-cleanup failure returns `nil, diagnostic`;
fresh materialization returns that failure through the normal compilation
result, before appending a source record or starting object compilation. A
relocation check turns the same diagnostic into a miss, never a successful
semantic certificate. Raised non-string values retain their identity after all
scratch-removal attempts, with the original exceptional outcome taking
precedence over cleanup noise. A caught native batch signal is retained on the
resolver context and raised as a non-string value, so certification cannot
demote cancellation to a miss. `driver.close_resolver_context` redelivers it
under the restored signal action after closing the header and probe owners.

Certificates retain the roots at object creation. A separate materialization
receipt records the roots used for the generated companions and is bound to
the object recipe. Fresh compilation records that state after materializing
its generated files. Before moving existing companions, certification marks
the receipt incomplete; an interrupted or malformed materialization cannot
certify a later hit.

When either root set differs, local certification rebinds explicit header and
descriptor fields from their recorded roots, and companion files from their
last materialization roots. It compares current generated contents before
writing them, including on a return to the creation roots. Restored header
plans likewise compare contents before preserving a file; a formatter's
unchanged output is not republished. Header contents, origins and lookup
candidates are freshly validated.

Only a move away from the creation roots requires checking every saved
generated prefix against its hash and comparing the current preprocessed
program with the original semantic digest. A mismatch is
`c-input relocated generated-C semantics`; missing semantics are
`record-schema`, not a migration. Ordinary same-root hits do not repeat this
preprocessing.

The disposable `<stem>.relocation` data-only receipt binds successful semantic
comparison to the exact object/generated companion bytes and concrete current
roots, so subsequent unchanged builds do not preprocess again. It also keeps
materialization state distinct from immutable certificate roots. It cannot
replace the ordinary source, configuration, header or dependency checks.
Reused native objects keep their original debug and diagnostic path strings.
Authored C nodes keep their ordinary preprocessing check over root-relative
source, argv and dependency identities
([`--c-source` nodes](build-coordinator.md#--c-source-compilation-and-records)).
Final-link records rebind only named owned input and output paths before their
ordinary validation, so a changed external path or a missing output still
misses.

## Own-source content and folder membership

`incremental.source_certificate(context, source, contents_by_path)`
(`incremental.lua`) records `layout = source.kind` (`"flat"` or
`"folder"`) and `sources = { { path, sha256 }, ... }` in the tagged source
resolver's canonical order: the selected `source.main` first, followed by the
selected immediate folder contributors sorted by logical filename (`source.files`). Paths use the exact spelling
that `driver.lua` embeds in `#line` directives. That spelling comes from the
selected `--tree` root and is deliberately not canonicalized: it reaches
generated C, native debug information, and tracebacks, so a different spelling
of the same source root misses with `source-set` and rebuilds. Output paths
are different: `driver.prepare_output_root` makes `--output` and the `--exe`
directory absolute and, on Linux and macOS, resolves existing ancestors
through `realpath`, so relative, absolute, and symlinked-parent spellings of
one destination reuse the same objects and link record.

During stage 1 certification, `source_verdict(context, source, certificate)`
(`incremental.lua`) compares the freshly resolved `source` descriptor
against `certificate`:

* any contributor path present in `certificate.sources` but absent from
  `source.files` misses with `source-set removed <path>`;
* any path present in `source.files` but absent from `certificate.sources`, a
  flat/folder `layout` change, or an ordering change misses with
  `source-set added <path>`; and
* each file in `source.files` is hashed via `incremental.file_digest`; any read
  error or SHA-256 mismatch misses with `source-content <path>`.

The bytes read during `source_verdict` are stored in
`source.certified_contents[path]`; after a digest-only
[persistent cache](#persistent-digest-cache) hit there are no stored bytes.
When a module misses and falls back to `parse_source_inner` (`driver.lua`),
the parser consumes `source.certified_contents[filename]` or materializes it
once through `incremental.file_contents`, which rejects a file whose
observation changed after its digest was accepted. `prepare_compile` passes
the precomputed `entry.source_certificate` into
`incremental.make_certificate`. The new object record therefore certifies the
exact source bytes that were parsed and compiled.

The paths are the [target-selected](target-source-selection.md#certificates)
files, so the existing verdict already covers target variants without a format
change: adding or removing a variant that changes the selection, or switching
between byte-identical files, changes a path and misses with `source-set`; a
contributor variant misses for its owning folder module only. Editing,
adding, or removing a variant whose label does not apply leaves the selected
list and digests unchanged, so the module hits and nothing compiles or links.
Certificates record no absent candidates: every invocation selects afresh, and
that resolution supplies the negative evidence. The output stem compared by
`output-moved` is the logical stem, never a variant's name.

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
  a metadata fast path when the I/O strategy declares `precision == "ns"`
  with valid `changed_seconds` and a physical file identity, and as a
  before/after read-race guard. Synchronous `titanc` reads native
  `titan._stat_precise` observations, so an unchanged header is accepted from
  metadata; with the coarse LuaFileSystem fallback, `revalidate_header_input`
  reads and hashes each distinct header once per invocation through the
  shared `context.header_validation` pass and `context.file_digest` memo.
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

`check_headers(context, record)` (`incremental.lua`) validates the
deduplicated union of `record.c_header_dependencies` and
`record.ffi_header_descriptor.search_inputs` during `certify_local`, before any
declarations or checking `.ffi.h` descriptors are restored. Any changed,
missing, unreadable, or racing input returns
`c-input <path>: content|provenance|missing|unreadable|candidate|changed-during-read`.

## Interface digests, contextual owners, and bindings

### Producer self digests and per-module binary digests

When a source module is prepared for compilation (`prepare_compile` in
`driver.lua`), `incremental.producer_digests(context, source_entry,
encoded_layouts, ast._foreign_header_recipe)` (`incremental.lua`)
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
* `entry.source_manifest` is computed once by
  `sourceinterface.serialize(entry, context)` (`titan-source-interface-v2`)
  during checking and reused by certification. It adds private top-level
  declarations, inherited C-header input identities, and documentation maps
  for explicit `.titan` source importers.

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
(`incremental.lua`) hashes `{ types.serialize_semantic(entry.type),
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
  return or field types (`recover_contextual_owner` in `driver.lua`).
* `certificate.bindings` and `certificate.providers`: the coder's native
  binding map (`"direct"`, `"handle"`, or `"global"`) and selected dynamic
  provider map (`provider_file` for direct dynamic imports).

In stage 2, `incremental.verdict(record, plan)` (`incremental.lua`)
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

`incremental.certify_local(context, modname, source)` (`incremental.lua`)
evaluates local evidence in a fixed order before any dependency check:

1. **Object presence and readability.** `context.io:lstat("<stem>.o")` must
   succeed (`record-unreadable <err>` on a string `lstat` error) and report
   `kind == "file"` (`no-object` when missing or non-regular). The object bytes
   are read for their metadata through `incremental.file_contents`; its digest
   may come from the persistent cache under the precise-observation rules, and
   the bytes are still read once under the same race guard.
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
   `toolchain`, `options`, `preamble`, returning
   `configuration <component>` on the first mismatch.
5. **Own-source verdict and output location.** If step 3 failed or missed,
   returns `source-set added|removed <path>` or `source-content <path>`. Then
   compares the root-relative certified stem, returning `output-moved` only
   when that identity differs (not merely when its owned root moved).
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
record)` (`incremental.lua`). It creates a private validation context
with empty `header_validation` and `header_observations` tables, strips
`certified_contents`, re-runs `source_verdict` and `check_headers` from disk,
and accumulates its I/O counts under `incremental.counters(context).revalidation`
(`passes`, `file_hashes`, `file_reads`, `file_bytes`, `digest_calls`, `files`)
without incrementing the warm hash-once counters. A source or C-header edit
that this fresh end-of-compilation snapshot or a guarded read observes
therefore fails publication instead of committing a mismatched certificate.
It is not a check of every intermediate state: an edit that is reverted
before revalidation goes unnoticed, which is why builds require stable inputs
while `titanc` runs.

### Split modules

A [split module](codegen-overview.md#translation-unit-parts) is reused as a
complete unit or recompiled as a whole. The sole authority for split artifacts
is the `parts` list in the primary object's `.titan.source` record
(`record.object_metadata.parts`). After `codegen-options` verifies `c_parts`
and `split_threshold`,
`check_parts(context, record, stem, bytes)` (`incremental.lua`) and
`check_coverage(context, native, stem)` (`incremental.lua`) require:

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
   regular non-symlink file whose `incremental.part_fingerprint` is a valid
   single-architecture object for `version.TITAN_ABI_VERSION`, carries neither
   public `.titan.meta` nor `.titan.source`, and matches the primary object's
   target fingerprint (`staticmetadata.fingerprint_matches`). The part is
   hashed through `incremental.file_digest`, so the final-link certificate
   reuses that digest, and its scan result is cached by content digest in the
   [persistent digest cache](#persistent-digest-cache); an unchanged part is
   neither read nor rescanned on a warm build.
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
accommodate an incompatible toolchain. Emscripten has no fat Wasm objects, so
the [browser target](browser-target.md#unsupported-flags) never adds LTO,
rejects user LTO flags, and rejects bitcode objects and archive members.

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

Existing complete companions are left untouched on a same-root hit. A
relocation rebinds their compiler-owned directives before its semantic check.
If a generated `.ffi.h` or `.titan.h` file was removed from the output tree,
`driver.prepare_foreign_headers` (`titanc`) restores it from the
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
