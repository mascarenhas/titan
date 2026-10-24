# Object-backed source modules

Incremental compilation adds a source-loader fast path and an object-only CLI
mode. It does not change ordinary provider lookup, source-private visibility,
or build-system ownership of dependencies. The user-facing contract and Make
example are in [Incremental and separate compilation](../language/incremental-compilation.md).

## Resolver and CLI boundary

`titanc` passes `incremental` and `forced_source_roots` to
`driver.defaultloader`, alongside the complete `source_roots` set.
With `-c`, every explicitly requested root is in the forced set before any
loader traversal. This matters when the first root imports a later root.
`--source-first` selects the `source_first` resolver policy independently from object
reuse and compilation mode.

Reuse happens only after resolving an actual flat or folder source module
(`driver.lua` `load_source_object`, local to `driver.defaultloader`). The object
is derived from that module's native output stem; `.o` is not added to
prefix-container binary discovery. The loader compares the object's mtime with
the current source constituent mtimes, then reads its source record with
`objectmetadata.read` and the expected ABI. An accepted hit is a source entry
with an existing compiled object and declared type state, not an analysis-only
manifest or a binary provider. A miss falls back to ordinary parsing and
checking.

The entry restores ordered import requests, nominal owners, baked native
bindings, and native-reference accounting needed by finalization and linking.
`entry.deps` alone is insufficient because it does not include dynamic imports.
Source-required edges retain their direct-source capability; ordinary edges
remain public-only. The generated physical-provider identity check continues
to apply to direct source consumers.

Native binding validation is per reused object. The final resolver determines
whether an owner is supplied directly or dynamically; the object's recorded
imports determine whether dynamic access uses its own provider handle or a
global symbol lookup. This matches `coder.generate`: an indirect record-method
consumer can store `global` for an owner that another module imports through a
handle. An invocation-wide dynamic-owner classification alone cannot validate
both access paths. Validation keeps exact handle-provider checks and the
source/static/dynamic identity constraints, and does not accept an unresolved
owner as a global binding. It uses restored imports and resolver data without
reparsing source or repeating provider discovery.

Test records also keep discovered function names. `test_runner.discover`
combines checked ASTs and these names, preserving ordinary filtering, sorting,
and source-closure discovery. `-c --test` discovers cases for test C flags but
does not synthesize a runner. Incremental final test linking synthesizes the
current runner and entrypoint while reusing eligible production and test-owner
objects. The runner imports `titan.test` and calls its public `run` function
through the selected standard provider. An unchanged production object can
serve both an application and a test link when flags and dependency bindings
match.

The CLI reads main and external-symbol facts from cached entries when no AST
is available. Compile-only mode skips main selection and common provider-name
derivation, emits the selected source closure's objects/headers, closes the
resolver, and returns before target/provider validation and final linking.
Normal incremental linking uses the same publication and target checks as a
cold build. Reused objects are never rewritten. A freshly compiled module is
published as a group, with the primary `<stem>.o` renamed into place last as
its commit marker; see
[Compiling one module](driver.md#compiling-one-module-drivercompile).

### Split modules

A [split module](codegen-overview.md#translation-unit-parts) is reused as a
whole or not at all. The authoritative inventory is the `parts` list in the
primary object's `.titan.source` record, never the `<stem>.parts` companion,
which exists only for Make. `load_source_object` applies these checks in order
and misses on the first failure:

1. `<stem>.o` is a regular file no older than every source constituent, and
   its record loads.
2. `objectmetadata.validate_parts` accepts the record: `parts_version` is 1,
   `parts` is a dense list whose entry `i` has `index = i - 1` and exactly the
   `.c`/`.o` or `.part<k>.c`/`.part<k>.o` suffixes, a split record names the
   `.priv.h` suffix and an unsplit one names none, and any recorded `c_parts`
   and `split_threshold` are well-formed integers. Objects written before part
   records existed therefore always miss.
3. The recorded `c_parts` and `split_threshold` equal the current effective
   values (`driver.effective_c_parts` and the generator threshold); otherwise
   the miss reason is `split generation policy changed`. The record stores the
   requested part count, not the actual one, so changing `--c-parts` or
   `TITAN_C_PARTS` invalidates unsplit modules as well.
4. For each recorded part after part 0: `<stem>.part<k>.o` is a regular file
   no older than every source constituent; it scans as a native object for the
   current ABI; it carries no Titan metadata or source record; and its target
   fingerprint matches the primary object's.
5. In coverage mode, the recorded coverage file list has one entry per part,
   and every part's `.c` and `.gcno` are regular files.

A hit returns the complete ordered object list, part 0 first. The loader does
not look for part files beyond the record; a stale higher-numbered part left on
disk is never linked.

## Trusted source record

Each generated relocatable module carries its public `.titan.meta` (ELF/COFF)
or `__TEXT,__titanmeta` (Mach-O) section and callable ABI/type/layout protocol.
A second `.titan.source` / `__TEXT,__titansrc` section holds a Lua
reconstruction chunk (`titan-compiler/objectmetadata.lua` `encode`/`render`,
symbol `titan_object_source_<mangled>`). `driver.compile` appends it to part
0's generated C; with coverage enabled it is appended after line conversion so
the record carries the coverage anchors. Both sections exist only in the
primary object; split part objects carry neither. The same in-process section
reader
locates these bytes. Emission uses the same byte alignment, `used` retention,
relocation-free representation, and Clang address-sanitizer exclusion as the
public metadata.

Ordinary COFF uses the same `.titan.source` name and source-record format as
ELF. Its section lookup follows the COFF long-name string table and rejects
uninitialized or relocated payloads. Supporting this object representation
does not enable Windows static providers or complete Windows compilation.

The chunk allocates graph tables before assigning their scalar and reference
fields, preserving recursive C declarations and shared generic/nominal state.
The declaration projection is shared with `projectcache`, but this path does
not use its validating `graphcodec` transport or analysis-only reader. Source
record acceptance is Lua load/execution followed by ABI compatibility. There
is no additional checksum, deep schema validation, or hostile-input policy.

The graph retains declared public/private views, owner registry, source/output
paths, main/symbol facts, ordered imports and native bindings, and replayable
header data. `native.layouts` also carries the independently encoded public
physical layout inventory; native reuse requires and validates it before
installing its plans in the resolver. It does not retain checked function ASTs. `types.serialize`
continues to represent only the public compiled interface; `source_manifest`
is an equality representation, not the source record's restore format.

The source section may remain inert in archives and DSOs. Their readers
consume only public metadata. Physical layouts remain separate from semantic
`types.serialize` and analysis inventories, which expose only ABI/types.
See [Native nominal storage](nominal-storage.md). The source record is not
part of the generated-code ABI or the language-server API, and
`objectmetadata.read` checks only the ABI marker: the build system must rebuild
objects after compiler changes to the record representation.

## Optimization across native objects

The default optimization and LTO flags are defined in [Compiling one
module](driver.md#compiling-one-module-drivercompile). Generated-object
compilation and the shared/executable link helpers, including archive-backed
validation images and executable protocol probes, all use them.

Linux fat objects retain native ELF sections for target inspection and both
Titan metadata protocols, alongside compiler IR. Archive extraction and
repacking preserve the member bytes, so the final compiler-driver link can
optimize across source objects or selected archive members. LTO does not
change the public provider protocol or dynamic binding boundaries. Do not replace
these objects with bitcode-only containers or disable native metadata gates to
accommodate an incompatible toolchain.

Compile overrides follow default flags; link overrides follow default link
flags. Cheap fixtures use `TITAN_EXTRA_CFLAGS='-O0 -fno-lto'` and
`TITAN_EXTRA_LDFLAGS='-fno-lto'`. Ordinary extra C flags remain compile-only.
Make owns invalidation after compiler or optimization policy changes.

The focused `spec/coder/lto_spec.lua` uses an unresolved symbol in a branch
which can only be eliminated after seeing another module's implementation. It
checks direct executable linking, shared publication, and a later standalone
consumer of Titan's own archive; disabling LTO exposes the unresolved symbol.
This proves inter-module optimization rather than merely checking accepted
flags or successful runtime results.

## Headers without an AST

An object stores both the `.ffi.h` declaration environment and, when present,
the generated `.titan.h` interface including the local direct-call helpers
and their copied foreign bodies. Types alone cannot reproduce those inline implementations. Header
planning accepts these records alongside freshly checked ASTs.

Compiler-owned include references identify logical module dependencies and are
rendered through the current output mapping. For example, the checking-tree
name `titan/http.ffi.h` differs from the folder module's native companion
`titan/http/http.ffi.h`. Replaying a logical header verbatim at the latter path
would change relative include resolution. Header materialization must preserve
helper bodies while resolving those owned references correctly; temporary
resolver paths are not persistent metadata.

Complete existing companions are not rewritten on a hit. Missing required
headers can be restored from the record without parsing/checking its producer.
Their semantic invalidation remains Make's responsibility, including changed
foreign helper bodies and C header inputs.

## Build and validation ownership

Titan checks only source existence, source/object timestamp eligibility,
metadata load/ABI compatibility, the split-part checks above, and the recorded
split policy for reuse. Make owns imported objects/headers, folder membership,
compiler/toolchain/SDK settings, other flags, provider choice, and other
dependencies. No dependency hashes or configuration inventory are used to
certify a hit.

The standard-library object graph keeps one object target per logical module
and the explicit folder inventories, then publishes the provider pair from the
persistent objects in the selected output tree (`TITAN_OUTPUT_DIR`, default
`out/`); see [Build and installation responsibilities](build-script-audit.md)
and [output-directory routing](output-directory.md). The native stdlib test
suite likewise has per-module object targets and installed-provider
prerequisites, then a final incremental `--test` link in one build directory.
Both object rules also read each module's `<stem>.parts` companion as a cheap
completeness check and rebuild the whole module when it or a listed part is
missing or malformed. Make reads the companion; the incremental loader never
does, and the `.titan.source` record remains the reuse authority
([standard-library object graph](build-script-audit.md#standard-library-object-graph)).

Root driver/metadata specs cover object lookup, fallback, replay, and skipped
compiler phases. `spec/coder/incremental_compilation_spec.lua` owns CLI and
native behavior, including cached mains, source-private foreign interfaces,
missing-header recovery, and Make-forced recompilation. Standard-library API
tests remain in the uncovered native suite; packaging tests own the stdlib DAG
and bundled/system publication boundaries.
