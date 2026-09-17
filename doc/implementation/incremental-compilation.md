# Object-backed source modules

Incremental compilation adds a source-loader fast path and an object-only CLI
mode. It does not change ordinary provider lookup, source-private visibility,
or build-system ownership of dependencies. The user-facing contract and Make
example are in [Incremental and separate compilation](../language/incremental-compilation.md).

## Resolver and CLI boundary

`titanc` passes `incremental` and `forced_source_roots` to
`driver.defaultloader`, alongside the existing complete `source_roots` set.
With `-c`, every explicitly requested root is in the forced set before any
loader traversal. This matters when the first root imports a later root.
`--source-first` selects the existing resolver policy independently from object
reuse and compilation mode.

Reuse happens only after resolving an actual flat or folder source module.
The object is derived from that module's native output stem; `.o` is not added
to prefix-container binary discovery. The loader compares its timestamp with
the current source constituent timestamps, then reads its source record. An
accepted hit is a source entry with an existing compiled object and declared
type state, not an analysis-only manifest or a binary provider.

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
both access paths. Validation retains exact handle-provider checks and existing
source/static/dynamic identity constraints, and does not accept an unresolved
owner as a global binding. It uses restored imports and resolver data without
reparsing source or repeating provider discovery.

Test records also retain discovered function names. `test_runner.discover`
combines checked ASTs and these names, preserving ordinary filtering, sorting,
and source-closure discovery. `-c --test` discovers cases for test C flags but
does not synthesize a runner. Incremental final test linking synthesizes the
current runner and entrypoint while reusing support and test owner objects.
Both separate/incremental test paths assign the stable
`titan/test__test_support.titan` native output before loading any roots. The
historical default `--test` path retains its first-root-specific support output.

The CLI reads main and external-symbol facts from cached entries when no AST
is available. Compile-only mode skips main selection and common provider-name
derivation, emits the selected source closure's objects/headers, closes the
resolver, and returns before target/provider validation and final linking.
Normal incremental linking uses the same publication and target checks as a
cold build. Reused objects are never rewritten; failed native compilation must
not publish an object which a later invocation can mistake for a success.

## Trusted source record

Each generated relocatable module keeps its existing public `.titan.meta`
(ELF) or `__TEXT,__titanmeta` (Mach-O) and callable ABI/type protocol. A second
`.titan.source` / `__TEXT,__titansrc` section holds a Lua reconstruction chunk.
The existing in-process section reader locates these bytes. Emission uses the
same byte alignment, `used` retention, relocation-free representation, and
Clang address-sanitizer exclusion as public metadata.

The chunk allocates graph tables before assigning their scalar and reference
fields, preserving recursive C declarations and shared generic/nominal state.
The declaration projection is shared with `projectcache`, but this path does
not use its validating `graphcodec` transport or analysis-only reader. Source
record acceptance is Lua load/execution followed by ABI compatibility. There
is no additional checksum, deep schema validation, or hostile-input policy.

The graph retains declared public/private views, owner registry, source/output
paths, main/symbol facts, ordered imports and native bindings, and replayable
header data. It does not retain checked function ASTs. `types.serialize`
continues to represent only the public compiled interface; `source_manifest`
is an equality representation, not the source record's restore format.

The source section may remain inert in archives and DSOs. Their readers still
consume only public metadata. `LANGUAGE_SERVER_API_VERSION` remains 1, and the
source record does not itself change the generated-code ABI. Make must rebuild
objects after prerelease compiler/record representation changes within that ABI.

## Optimization across native objects

`driver.CFLAGS` supplies `-O3` on supported platforms. Platform initialization
adds `-flto -ffat-lto-objects` on Linux for GCC and Clang; macOS retains native
Mach-O objects without default LTO. Both generated-object compilation and
the shared/executable link helpers use these defaults, including archive-backed
validation images and executable protocol probes.

Linux fat objects retain native ELF sections for target inspection and both
Titan metadata protocols, alongside compiler IR. Archive extraction and
repacking preserve the member bytes, so the final compiler-driver link can
optimize across source objects or selected archive members. The public
provider protocol and dynamic binding boundaries are unchanged. Do not replace
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
the generated `.titan.h` interface including eligible inline source-foreign
bodies. Types alone cannot reproduce those inline implementations. Header
planning accepts these records alongside freshly checked ASTs.

Compiler-owned include references identify logical module dependencies and are
rendered through the current output mapping. For example, the checking-tree
name `titan/http.ffi.h` differs from the folder module's native companion
`titan/http/http.ffi.h`. Replaying a logical header verbatim at the latter path
would change relative include resolution. Header materialization must preserve
inline bodies while resolving those owned references correctly; temporary
resolver paths are not persistent metadata.

Complete existing companions are not rewritten on a hit. Missing required
headers can be restored from the record without parsing/checking its producer.
Their semantic invalidation remains Make's responsibility, including changed
foreign inline bodies and C header inputs.

## Build and validation ownership

Titan checks only source existence, source/object timestamp eligibility, and
metadata load/ABI compatibility for reuse. Make owns imported objects/headers,
folder membership, compiler/toolchain/SDK settings, flags, provider choice, and
other dependencies. No dependency hashes or configuration inventory are used
to certify a hit.

The stdlib object DAG keeps one object per logical module and the existing
explicit folder inventories. The final private publication stage reuses
persistent source-adjacent objects, combines the ordered native payload into
both provider forms, and performs normal pair/shim validation. The source-rock
post-install path uses the same object targets with the deployed compiler/SDK.
The native stdlib test suite likewise has shared support and per-module object
targets, then a final incremental `--test` link in one build directory.

Root driver/metadata specs cover object lookup, fallback, replay, and skipped
compiler phases. `spec/coder/incremental_compilation_spec.lua` owns CLI and
native behavior, including cached mains, source-private foreign interfaces,
missing-header recovery, and Make-forced recompilation. Standard-library API
tests remain in the uncovered native suite; packaging tests own the stdlib DAG
and bundled/system publication boundaries.
