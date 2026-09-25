# Selective binary dependency verification

Separate shared-object imports verify the consumer's compiled assumptions
instead of comparing the provider's complete serialized module interface byte
for byte. The [language contract](../language/binary-compatibility.md) defines
which changes an unchanged consumer accepts. This chapter describes the
checker-owned requirements, separate metadata projection, and runtime loading
path.

## Separate metadata and canonical erasure

`titan-compiler/binarycompat.lua` produces two projections:

* `module` publishes a provider's public compatibility inventory;
* `requirements` selects the declarations required by one checked consumer.

The inventory has a protocol version, logical module identity, and separate
`functions`, `variables`, `records`, `unions`, and `interfaces` categories.
`encode` renders a deterministic Lua chunk returning that plain table.
`verifier` emits another chunk returning a function that compares the selected
requirements against the loaded table and raises an entity-specific error.

Value-type leaves use `types.erase` followed by `types.serialize`. The input
comes from canonical declarations in the declared module/registry graph, not
from a generic call's specialized signature. Parameter names remain separate
ordered signature data. Variadic inputs, flexible results, and const type
qualifiers survive through their ordinary erased type representation.

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
emitted public prefix. Semantic field indices and physical metadata keep their
existing formats; see [Native nominal storage](nominal-storage.md).

Requirements for a record or union retain the complete public data shape but
select only used methods and statics. A union's total variant count is retained
only for a consumer that depends on the closed inventory. The verifier allows
extra provider entries at selective boundaries; the required signature, field,
variant, and Interface lists compare exactly.

This protocol does not alter semantic `_types` serialization, `_layouts`, the
archive metadata section, source-object metadata formats, or the language-server
API. It does not replace the compiler's closed validator for recovered module
interfaces or weaken physical-layout validation during native compilation.
The compatibility protocol version is independent of `TITAN_ABI_VERSION = 2`,
`TITAN_VERSION = 0.6.0`, and `LANGUAGE_SERVER_API_VERSION = 1`.

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
owner even if that owner has no written import in the consumer. Existing
checker owner recovery supplies those descriptors; code generation uses the
existing finalized provider provenance to decide where to verify them.

### Construction and closed-union proofs

An imported record literal contributes a dependency on its synthesized public
`new`. Direct construction can inline allocation using the complete public
record layout. If a replacement adds the first private field, the public
constructor disappears and verification rejects this consumer before it can
allocate an undersized record. Access-only consumers require the public field
shape and can accept changed private storage.

The case checker retains its existing `_always_returns` inference. When all
arms terminate and complete variant coverage supplies the non-fallthrough
proof, `_binary_closed_union` records the relied-upon union. The usage manifest
then requests the total inventory count. This includes a falling-through
`else` made unreachable by complete coverage. An independently terminating
`else` needs no inventory requirement. No case trap, mandatory coverage rule,
or conservative disabling of the flow proof is introduced.

Public variant tags occupy the initial zero-based range in their relative
source order; private variants follow in their relative source order. The AST
and source evaluation order stay unchanged. This keeps public dispatch stable
when private variants change. See [Union implementation](unions.md).

## Generated exports and runtime verification

Each generated logical module additionally exports:

```c
int some_module_compatibility(lua_State *L);
```

It returns exactly one Lua string containing the encoded provider metadata
chunk. `_abi`, `_types`, and `_layouts` retain their existing independent
contracts. Compiler-time DSO membership and metadata recovery still use those
existing entries.

For an explicit dynamic dependency, `coder/module.lua` emits:

```c
void *handle = loadlib(L, "some/provider.so");
titan_check_abi(L, handle, "some_module_abi", "some/provider.so");
titan_check_compatibility(L, handle, "some_module_compatibility",
    "some/provider.so", verifier_source, verifier_length);
```

Only after these checks does initialization use the dependency's native
entries. `titan_check_compatibility` resolves the metadata symbol, checks the
entry's result count, Lua stack delta, and exact string type, evaluates the
metadata and verifier chunks, and calls the verifier on the resulting table.
A successful check restores the original Lua stack top. Missing entries,
malformed metadata, and mismatches raise through the importing initializer's
ordinary Lua error path. The ABI check always precedes compatibility checks.

Both chunks are loaded as text with a private environment exposing the
verifier's `type`, `next`, and `error` primitives through C implementations.
Application changes to Lua's global functions cannot disable verification.
The metadata string remains rooted while its chunk is loaded and evaluated.
This is a protocol between generated native providers, not a sandbox for
untrusted shared libraries.

Transitive nominal owners use the existing global-symbol path after explicit
providers initialize. Their ABI and consumer-specific compatibility checks run
before using their global native entries. The final `static_deps`/provider
provenance bypasses these checks for source or archive code residing in the
same binary; it also preserves direct initialization and source-provider
identity checks. An already initialized dependency does not authorize a new
consumer to skip its own requirements.

## Provider-owned slots and direct calls

The module public-prefix layout remains exported variables, top-level callable
closures, and nominal static closures. Its order is still useful within a
producer, but a separate dynamic consumer cannot embed those slot indices:
compatible additions or reordering may move them.

`coder/binary.lua` exports one `const unsigned int` for each public variable
or canonical closure slot. Names derive from the existing native callable
prefixes with `_variable_slot` or `_closure_slot`. A dynamic consumer resolves
the required data symbols once, through its explicit provider handle or the
existing global owner path, and uses the resulting index for reads and writes.
The containing consumer-owned slot that stores its import remains constant.
Self-owned and same-binary provider accesses retain their known constant
indices.

`mod.func()` still calls the resolved native symbol with the imported module
state and `NULL` closure argument. It never fetches a function value first.
`mod.func` instead reads the provider's canonical closure at its resolved slot;
the same rule applies to first-class nominal statics. No replacement closure,
Lua namespace lookup, or identity adapter is introduced.

## Regression boundaries

Pure compatibility tests exercise erased projection and selective comparison;
checker tests exercise independent usage maps and implicit dependencies. The
coder replacement-provider suite builds a consumer against a DSO, replaces only
the provider, verifies that the consumer bytes are unchanged, and loads it in a
fresh process. In-memory sources and absent paired archives force the dynamic
path. Assertions cover both accepted changes and load-time rejection before
unsafe native use, including moved variable/callable slots, alias owners,
construction, closed-union proofs, ABI precedence, and protocol failures.

Provider and incremental integration must additionally preserve the driver's
direct/handle/global provenance after object reuse and final linking. An exact
incremental-cache validity decision is separate from an already-built
consumer's selective runtime compatibility check.
