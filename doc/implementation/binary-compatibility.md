# Selective binary dependency verification

Separate shared-object imports verify the consumer's compiled assumptions
instead of comparing the provider's complete serialized module interface byte
for byte. The [language contract](../language/toolchain.md#replacing-shared-library-dependencies) defines
which changes an unchanged consumer accepts. This chapter describes the
checker-owned requirements, separate metadata projection, and runtime
verification path. Windows-specific loading, launchers, and DLL publication are
in [Experimental Windows build](windows-build.md#windows-loader-boundary)
([launchers](windows-build.md#windows-application-launchers),
[DLL publication](windows-build.md#windows-dll-publication)).

## Separate metadata and canonical erasure

`titan-compiler/binarycompat.lua` produces two projections:

* `module` publishes a provider's public compatibility inventory;
* `requirements` selects the declarations required by one checked consumer.

The inventory has a protocol version (`binarycompat.VERSION`), logical module
identity, and separate `functions`, `variables`, `records`, `unions`, and
`interfaces` categories. `encode` renders a deterministic Lua chunk returning
that plain table. `verifier` emits another chunk returning a function that
compares the selected requirements against the loaded table and raises an
entity-specific error.

Value-type leaves are `types.serialize_semantic(types.erase(t))`. The input
comes from canonical declarations in the declared module/registry graph, not
from a generic call's specialized signature. Parameter names remain separate
ordered signature data. Variadic inputs, flexible results, and const type
qualifiers survive through their ordinary erased type representation.

Public foreign declarations use the same function category with their exact
`Type.CFunction` signature and parameter names. Calls and contextual callback
conversions record usage; declarations imported from a C header are outside the
Titan module compatibility graph. Raw imported addresses resolve through the
checked canonical provider, then publish atomically in hidden typed slots
owned by the consumer image. Later initialization must select the same address.
These stable bindings have no module-state slot or public metadata entry; see
[foreign-function binding](foreign-functions.md#source-collaboration-and-binary-isolation).
Only statically included candidates enter the direct native-reference set.

The projection intentionally excludes module slot numbers, private record
fields, and producer-private physical layout. Records publish ordered public
fields and maps of public methods/statics. Unions publish ordered public
variants with stable tags and named part signatures, their callable maps, and
the total variant count. Interfaces publish their complete ordered field and
method lists. Nominal descriptors carry the canonical fully qualified owner
identity. A public nominal alias is also published under its exposed name in
the appropriate record, union, or Interface category.

Public native record-member C names likewise derive from the public field
names, so private-interleaved logical index changes do not alter the consumer's
emitted public prefix. Semantic field indices and physical metadata formats are
unaffected; see [Native nominal storage](nominal-storage.md).

Requirements for a record or union retain the complete public data shape but
select only used methods and statics. A union's total variant count is retained
only for a consumer that depends on the closed inventory. The verifier allows
extra provider entries at selective boundaries; the required signature, field,
variant, and Interface lists compare exactly.

This protocol does not alter semantic `_types` serialization, `_layouts`, the
archive metadata section, source-object metadata formats, or the language-server
API. It does not replace the compiler's closed validator for recovered module
interfaces or weaken physical-layout validation during native compilation.
`binarycompat.VERSION` is independent of the compiled-module ABI and the
language-server API version.

## Usage belongs to the consumer

`checker/binary_usage.lua` collects usage from successfully checked syntax and
explicit adjustment/conversion plans. Each check owns its own module inventory
and usage map, attached to the AST as `_binary_modules` and `_binary_usage`.
Imported descriptors can be shared across checks without accumulating another
consumer's requirements.

Collection follows selected declarations, written type selections, inferred
expression types, and the nominal types nested in those value types. It covers
module-variable writes as well as reads, direct and first-class calls,
bound methods, generic declaration selections, and contextual constructors.
Frozen Interface implementation plans contribute the concrete methods called
by generated adapters. These are dependencies even if no source expression
directly selects the method.

Do not follow every descriptor back-reference or recursively walk an imported
module's entire public graph. Import recovery and validation are eager; that
does not make every validated export a consumer dependency. Likewise, an
imported callable's shared `_used` state is not a per-consumer manifest.

Alias exposure and canonical identity are distinct requirements. A written
`api.Item` selection records the alias in `api` and the actual nominal owner's
shape. A concrete method reached through an inferred returned type records its
owner even if that owner has no written import in the consumer. Checker owner
recovery supplies those descriptors; code generation uses the finalized
provider provenance to decide where to verify them.

### Construction and closed-union proofs

An imported record literal contributes a separate `literal = true` requirement
(`checker/binary_usage.lua`). Providers advertise this capability only for
records with no constructor override and a complete public field layout.
Direct construction can inline allocation using that layout. Adding the first
private field or overriding `new` removes the capability and rejects literal
consumers, even if a public override keeps the generated constructor's exact
signature. Ordinary calls depend on `new`'s signature; access-only consumers
require the public field shape and can accept changed private storage. See
[record constructor
metadata](record-constructors.md#semantic-metadata-and-separate-providers).

The same raw-construction capability is required by a generated record call
whose fresh native arguments are fused into its userdata allocation. Ordinary
calls to a separate provider use its callable implementation; fused-storage
calls keep direct construction to preserve their ownership contract, and
therefore reject a replacement constructor override.

An imported constructor call in a module-variable initializer normally depends
only on `new`'s callable signature, just like a call in a function body or final
`do` block: the imported module has already initialized, so its custom
constructor is a valid initialization dependency. The exception is a generated
record call whose delivered stored arguments carry an own callable (a lambda,
bound own method, own Interface implementation, or own method-bearing
record/union value, possibly nested in other stored arguments). The initializer
checker accepts that storage only because generated construction does not call
it, so it marks the call `_binary_initializer_constructor` and usage collection
requests `literal` as well. A replacement that overrides `new` then fails
compatibility checking before the consumer initializes, instead of invoking
the callable against uninitialized module state. Nested generated constructors
carry the requirement for both the outer and the inner record. Raw literals and
fused-storage calls retain their separate construction-capability requirement.
Every evaluated argument is still checked for own references and exposure, but
discarded surplus and spread setup carriers do not independently request
`literal`; only values delivered to the constructor's fixed parameters do. An
implicit Map call evaluated inside an argument is checked separately and
cannot be made safe by this storage capability.

A `case` whose non-fallthrough proof depends on complete variant coverage
([case checking and control flow](unions.md#case-checking-and-control-flow)) is marked
`_binary_closed_union`, and the usage manifest then requests the union's total
variant count. This includes a falling-through `else` made unreachable by
complete coverage; an independently terminating `else` needs no inventory
requirement. A provider that adds a variant therefore rejects only consumers
that relied on the closed inventory.

Public variant tags occupy the initial zero-based range in their relative
source order; private variants follow in their relative source order. This
keeps public dispatch stable when private variants change. See [Case checking
and control flow](unions.md#case-checking-and-control-flow).

## Generated exports and runtime verification

Each generated logical module additionally exports (`coder/binary.lua`
`_binary_exports`):

```c
int some_module_compatibility(lua_State *L);
```

It returns exactly one Lua string containing the encoded provider metadata
chunk. `_abi`, `_types`, and `_layouts` keep their independent contracts, and
compiler-time DSO membership and metadata recovery use those entries.

Every generated logical module also exports a Lua-free native ABI query:

```c
const char *some_module_abi_value(void);
```

It returns the `TITAN_ABI_VERSION` string literal directly, with no Lua
argument, allocation, state access, or module initialization. Its immutable
provider-owned result must not be freed and stays valid while the image is
retained. It is per logical module, even when several modules share an image;
there is no physical-provider descriptor. Source and cached-object symbol
inventories include the query, and the generated canonical module resolver
(`coder/binary.lua` `_binary_resolver`) exposes it too. Recovered type metadata
alone does not promise this export, so the interface-derived collision
inventory excludes it: a provider that never defined the symbol is not
rejected for colliding with it.

`int some_module_abi(lua_State *L)` stays the discovery entry: Unix compiler
probes, runtime checks, and publication checks call it, including on providers
that lack `_abi_value`. A native caller must resolve and invoke the plain-C
query as `const char *(*)(void)`; `package.loadlib` and `titan._loadlib` wrap
symbols as `lua_CFunction` and must not be used to call it. Changing the `_abi`
signature would be unsafe even with an ABI bump, because every reader calls
that entry to discover the ABI.

Every generated module userdata has a native payload beginning with
`TitanModuleData`. Its `symbols` callback resolves the native entries, metadata
callbacks, and public slot symbols belonging to the image that created that
userdata. The callback is an immutable generated function; it requires neither
a filename nor a dynamic-loader handle. Source-linked, archive-linked, and
Lua-loaded modules publish the same header.

On ELF, generated Titan declarations and definitions use protected visibility
(the `#pragma GCC visibility push(protected)` in the `coder/module.lua`
preamble), after the foreign headers. Their addresses therefore refer to their
own image even when another version of the same logical module is globally
mapped. Darwin's ordinary two-level namespace supplies the corresponding
binding. Foreign C declarations keep their normal linkage policy.

Titan-owned runtime helpers use `TITAN_RUNTIME_FUNC` (`titan-runtime/titan/ffi.h`),
independently of Lua's `LUAI_FUNC`. Each provider links its runtime helpers
locally. The annotation is `visibility("internal")` on GCC-compatible
ELF/Mach-O targets and plain `extern` elsewhere, including Windows. Titan-owned
Windows compiles redefine `LUAI_FUNC` as a `__declspec(dllimport)` declaration
so they import Lua's internal API from the stock `lua55.dll`
([consumer definitions](windows-build.md#one-controlled-lua-dll-and-its-sdk)),
and the separate annotation keeps Titan helpers from becoming imports too.

For an explicit dynamic dependency, `coder/module.lua` uses:

```c
TitanModuleProvider provider = titan_module_provider(L,
    "some.module", "some/provider.so");
titan_check_module_abi(L, provider, "some_module_abi", "some/provider.so");
titan_check_module_compatibility(L, provider, "some_module_compatibility",
    "some/provider.so", verifier_source, verifier_length);
```

Provider selection (canonical registry module, matching native preload
descriptor, private executable-linked resolver, then `loadlib` of the file)
is described in [Static vs dynamic dependency
wiring](codegen-overview.md#static-vs-dynamic-dependency-wiring).
Generated initialization registers the descriptor through
`titan_module_preload`, separately from the Lua preload loader; it holds only
matching loader and `TitanModuleSymbols` resolver pointers, with no module
state. `lua.new()` copies only descriptors matching eligible native loaders,
including inherited descriptors for modules not yet initialized in its source
state. In all cases, ABI and consumer compatibility checks precede
initialization.

`require` from Lua does not use the private linked provider set. The [Titan
package searcher](driver.md#the-titan-package-searcher) tries the canonical
module and then a matching native preload before looking for a file. It
checks a claimed candidate's ABI with `titan_check_abi_entry`
(`titan-runtime/titan_path.c`, which the
searcher shares with generated imports; on Windows through `_abi_value`) before
the searcher returns `luaopen_<mangled>`, and that opener's [file-load
name guard](codegen-overview.md#lua-entries-and-abi-type-and-layout-metadata)
rejects a provider for a different logical name with the same mangled spelling
before `_init` runs. An ABI mismatch reports `Titan compiled module '<file>'
ABI mismatch: expected 2 but found <n>`. Lua callers have no consumer
requirements, so the searcher performs no compatibility check.

Explicit imports are selected, checked, and initialized in sequence: an earlier
initializer may establish a later import's canonical module. After each
initializer returns, the importer recovers the canonical callback and repeats
the checks if selection changed. Native entry and slot bindings are filled only
after those initializations, using the final canonical providers.

The shared compatibility checker (`titan-runtime/titan.c`
`titan_check_module_compatibility` and `titan_check_compatibility_entry`)
resolves the metadata symbol, checks the entry's result count, Lua stack delta,
and exact string type, evaluates the metadata and verifier chunks, and calls
the verifier on the resulting table. A successful check restores the original
Lua stack top. Missing entries, malformed metadata, and mismatches raise
through the importing initializer's ordinary Lua error path. The ABI check
always precedes compatibility checks.

Both chunks are loaded as text (`titan_load_compatibility_chunk`) with a private
environment exposing the verifier's `type`, `next`, and `error` primitives
through C implementations.
Application changes to Lua's global functions cannot disable verification.
The metadata string remains rooted while its chunk is loaded and evaluated.
This is a protocol between generated native providers, not a sandbox for
untrusted shared libraries.

Transitive nominal owners (`global` bindings) run their own ABI and
consumer-specific compatibility checks before native use. Final
`static_deps`/provider provenance skips compatibility checks for source or
archive code residing in the same binary; those direct edges instead require
the exact linked provider's identity before using its fixed layout or code. An
already initialized dynamic dependency does not authorize a new consumer to
skip its own requirements, and returning an existing canonical module does not
initialize caches belonging to another image of that logical module.

## Provider-owned slots and direct calls

The public-prefix slot order ([User-value
allocation](codegen-overview.md#user-value-allocation)) is fixed within one
producer, but a separate dynamic consumer cannot embed those indices:
compatible additions or reordering may move them.

`coder/binary.lua` (`_binary_slot_name`) exports one `const unsigned int` for
each public variable or canonical closure slot, named from the native callable
prefix plus `_variable_slot` or `_closure_slot`. A dynamic consumer resolves the
required data symbols once through the selected logical provider and uses the
resulting index for reads and writes; the consumer-owned slot holding the
import stays constant. Self-owned and same-binary provider accesses keep their
compile-time indices. The resolved indices live with the other per-state
bindings in the importer's native payload, so two Lua states can elect
different providers; direct calls and first-class closure reads then follow
[Static vs dynamic dependency
wiring](codegen-overview.md#static-vs-dynamic-dependency-wiring).

## Regression boundaries

Pure compatibility tests exercise erased projection and selective comparison;
checker tests exercise independent usage maps and implicit dependencies.
`spec/coder/binary_compatibility_spec.lua` builds a consumer against a DSO,
replaces only the provider, verifies that the consumer bytes are unchanged, and
loads it in a fresh process. In-memory sources and absent paired archives force the dynamic
path. Assertions cover both accepted changes and load-time rejection before
unsafe native use, including moved variable/callable slots, alias owners,
construction, closed-union proofs, ABI precedence, and protocol failures.

Its `canonical providers` cases initialize one provider first, leave a different
compatible image at the consumer's selected filename, and prove that the
consumer uses the existing module's code and slots. They cover executable-embedded
and `package.loadlib` providers, transitive owners, and two Lua states with
different elected providers. Direct edges must reject a different canonical
physical provider.

Provider and incremental integration must also preserve the driver's
direct/handle/global provenance after object reuse and final linking. These are
link-plan classifications; dynamic runtime lookup still obeys logical module
identity. An exact incremental-cache validity decision is separate from an
already-built consumer's selective runtime compatibility check.
