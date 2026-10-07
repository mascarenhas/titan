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

An imported record literal contributes a separate `literal = true` requirement.
Providers advertise this capability only for records with no constructor override
and a complete public field layout. Direct construction can inline allocation
using that layout. Adding the first private field or overriding `new` removes
the capability and rejects literal consumers, even if a public override retains
the generated constructor's exact signature. Ordinary calls depend on `new`'s
signature; access-only consumers require the public field shape and can accept
changed private storage. New literal consumers require rebuilt providers that
publish this capability. Historical consumers recorded only a `new` dependency
and cannot distinguish same-signature overrides; see
[record constructor metadata](record-constructors.md#semantic-metadata-and-separate-providers).

The same raw-construction capability is required by a generated record call
whose fresh native arguments are fused into its userdata allocation. Ordinary
calls to a separate provider use its callable implementation; fused-storage
calls retain direct construction to preserve their ownership contract, and
therefore reject a replacement constructor override.

Generated record calls accepted by `isconst` as constant module variable
initializers also require this capability. The checker marks each accepted
call with `_binary_constant_constructor`, including nested constructor calls,
and usage collection retains that proof requirement. Lambda bodies and
computed `do` initializers do not participate in this constant-expression
proof; ordinary calls there continue to depend only on `new`'s signature.
New consumers with this proof require providers rebuilt to publish the
capability.

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

Newly generated logical modules also export a Lua-free native ABI query:

```c
const char *some_module_abi_value(void);
```

`coder/module.lua` emits a direct return of the `TITAN_ABI_VERSION` string
literal. The query has no Lua argument, allocation, state access, or module
initialization. Its immutable provider-owned result must not be freed and
remains valid while that image is retained. It is per logical module, even
when several modules share an image; there is no physical-provider descriptor.
Source and cached-object symbol inventories include the query, and the
generated canonical module resolver exposes the owning image's entry too.
Recovered type metadata alone does not promise this optional export: the
common ABI-2 interface inventory excludes it so older providers are not
rejected for collisions with a symbol they never defined.

The existing `int some_module_abi(lua_State *L)` signature and implementation
remain unchanged. Unix compiler probes, runtime checks, and publication checks
still use it, including with existing ABI-2 providers that lack `_abi_value`.
The additive query changes neither compiled-code ABI `2` nor language-server
API `1`. A native caller must resolve and invoke the bootstrap query as
`const char *(*)(void)`; `package.loadlib` and `titan._loadlib` wrap symbols as
`lua_CFunction` and must not be used to call it. Replacing the old `_abi`
signature would be unsafe even with an ABI bump, because existing readers call
that entry to discover the ABI.

Every generated module userdata has a native payload beginning with
`TitanModuleData`. Its `symbols` callback resolves the native entries, metadata
callbacks, and public slot symbols belonging to the image that created that
userdata. The callback is an immutable generated function; it requires neither
a filename nor a dynamic-loader handle. Source-linked, archive-linked, and
Lua-loaded modules publish the same header.

On ELF, generated Titan declarations and definitions use protected visibility,
after the foreign headers. Their addresses therefore refer to their own image
even when another version of the same logical module is globally mapped.
Darwin's ordinary two-level namespace supplies the corresponding binding.
Foreign C declarations retain their normal linkage policy.

Titan-owned runtime helpers use `TITAN_RUNTIME_FUNC`, independently of Lua's
`LUAI_FUNC`. Each provider links its runtime helpers locally. The annotation
preserves internal visibility on GCC-compatible ELF/Mach-O targets and uses
plain `extern` elsewhere, including Windows. A controlled shared Lua build can
therefore mark its own internal API for DLL export/import without making Titan
helpers imports from the Lua DLL. The controlled Lua build owns its separate
DLL export/import configuration.

For an explicit dynamic dependency, `coder/module.lua` uses:

```c
TitanModuleProvider provider = titan_module_provider(L,
    "some.module", "some/provider.so");
titan_check_module_abi(L, provider, "some_module_abi", "some/provider.so");
titan_check_module_compatibility(L, provider, "some_module_compatibility",
    "some/provider.so", verifier_source, verifier_length);
```

`titan_module_provider` first looks up `"Titan module some.module"` in the Lua
registry. An existing canonical module supplies its payload callback, and the
selected file is never opened. Only a missing logical module invokes `loadlib`
for that file. ABI and compatibility checks precede initialization of a newly
loaded provider. Native symbol and slot resolution use `titan_module_symbol`
with the selected provider, keeping the metadata, code, and module state together.

Explicit imports are selected, checked, and initialized in sequence: an earlier
initializer may establish a later import's canonical module. After each
initializer returns, the importer recovers the canonical callback and repeats
the checks if selection changed. Native entry and slot bindings are filled only
after those initializations, using the final canonical providers.

The shared compatibility checker resolves the metadata symbol, checks the
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

Transitive nominal owners use the same logical registry lookup after explicit
providers initialize, with a null filename. The owner must already exist; no
second DSO is selected and no `RTLD_DEFAULT` lookup chooses its native entries.
Their ABI and consumer-specific compatibility checks run before native use.
Final `static_deps`/provider provenance bypasses compatibility checks for source
or archive code residing in the same binary. Those direct edges instead require
the exact linked provider's identity before using its fixed layout or code.
An already initialized dynamic dependency does not authorize a new consumer to
skip its own requirements. Returning an existing canonical module also does
not initialize caches belonging to another image of that logical module.

## Windows loader boundary

On Windows, `titan_winloader.h` converts UTF-8 provider paths to absolute UTF-16
paths before `LoadLibraryExW`. Its only dependency-search flags are
`LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32`. It does
not change the process DLL directories or `PATH`. Executables, the controlled
Lua DLL, and native dependency DLLs share `bin`; Titan DLLs are resolved from
`lib/titan/0.6`. The default distribution root comes from the executable's
parent directory, and wide environment access preserves Unicode Titan path
overrides and the distinction between an absent and empty override.

These flags govern explicit dynamic module loads, not initial EXE imports.
Titan's Lua interpreter, compiler frontend, and application launchers import
the controlled Lua DLL before runtime initialization and must retain it beside
the EXE.
Windows' already-loaded-module, KnownDLL, and API-set rules still apply.

Each private per-state handle cache uses the absolute path spelling actually
opened. These caches only avoid repeated loader calls: they do not establish
logical module identity. Successful OS references are never released, including
after Lua state teardown, because provider code may still back descriptors,
callbacks, and finalizers. Each provider embeds its own Titan helpers while all
providers use the same controlled Lua DLL. Titan dependency entries are resolved
through the selected handle or canonical descriptor, without Titan import
libraries or a process-wide native-symbol search.

The Windows `titan_check_module_abi` adapts the existing `_abi` symbol argument
to `_abi_value` and invokes it as `const char *(*)(void)` before any provider Lua
entry. The support module's internal `_abivalue(path, symbol)` exposes this safe
query to the compiler: success returns a copied Lua string; failure returns
`nil, diagnostic, stage`, where the stage is `open`, `init` (missing export), or
`abi` (invalid result). A missing query may prompt symbol-only membership checks,
but a provider that claims the logical module cannot proceed to Lua metadata
without a matching native query. Unix probes retain the existing `_abi` path.

Windows shims pass their known logical identity as a third `_loadlibglobal`
argument. The helper first checks the canonical registry userdata and returns
a closure holding that same userdata, without opening or ABI-checking the
replacement pathname. Otherwise it maps the selected image, checks the native
query, then returns the Lua opener. The preceding `package.searchpath` step in
the public shim is unchanged; direct helper calls cover canonical reuse with a
missing pathname. Neither helper supports passing a plain-C query through a
`lua_CFunction` call.

The Windows diagnostic backend combines Lua traceback frames with native
libbacktrace frames. Generated DWARF supplies Titan filenames, line numbers,
and functions for EXE and DLL code; provider loads invalidate the cached module
snapshot. Builds explicitly disabling libbacktrace retain native addresses as
a fallback. `spec/support/check_windows_runtime_loader.sh` is a
native CLANG64/UCRT gate using real controlled Lua headers and its import
library. It builds separate provider DLLs and checks ABI-before-initialization,
canonical identity, callback lifetime, Unicode paths, restricted native search,
and imports without additional toolchain runtime DLLs. Passing this gate does
not establish full compiler or standard-library Windows support.

## Windows application launchers

The Windows program link produces a Titan application DLL plus a small console
EXE. The DLL receives all selected source modules and native payload;
the EXE links only its entrypoint, manifest resource, embedded Titan runtime,
and the controlled Lua import library. Neither output links a Titan module
import library. The SDK runtime archive remains `libtitan.a`; Windows uses the
matching `lib/liblua55.a` plus the separate SDK `lib/libbacktrace.a` for
PE/COFF source attribution, and omits Unix `dl` and `m`. Windows links include
the system `bcrypt` import library and select static unwind linkage with
`-static-libgcc`, avoiding an additional toolchain runtime DLL.

`windows_program_paths` derives `bin/<logical-module>.exe` and
`lib/titan/0.6/<logical/module>.dll`. `--launcher-name` changes only the EXE
basename. For tests, the first requested logical root owns these output names,
while the embedded entry identity remains the generated test runner.
`windows_launcher_name` rejects paths, alternate streams, controls, reserved
DOS device names, invalid UTF-8, trailing dots/spaces, and components exceeding
255 UTF-16 code units. The CLI rejects the option for compile-only, library,
and non-Windows invocations. Program output preflight includes the provider,
`.def`, manifest, resource source, and compiled resource.

PE links disable automatic exports. `windows_provider_exports` writes a
producer-owned `.def` from every logical module physically carried into the
DLL: `_abi_value`, `_abi`, `_types`, `_layouts`, `_compatibility`, `_init`, and
`luaopen_*`. Existing canonical descriptor callbacks resolve subsequent native
function and slot addresses; collision inventories are not export inventories.
The support-only `luaopen_titan` keeps its explicit Lua-module export annotation.
Missing module inventories fail before an existing output is removed. Private
`.def` files are removed after either link success or failure. Private
archive-validation DLLs receive the same complete inventory, and fresh-process
Windows validation checks the plain-C ABI before invoking Lua metadata.
Windows CLI invocations reject `--static` and selected Titan archive providers;
all logical Titan modules use DLL providers. The internal standalone link helper
retains defensive archive metadata checks, but this does not expose a supported
Windows static-provider mode.

The entrypoint embeds logical identity and the relative provider path, never an
EXE basename. Its `package.preload` callback resolves that provider, checks the
native ABI, and invokes its exact Lua opener inside the existing protected
entrypoint. Ordinary Titan argument reconstruction, bootstrap hook selection,
error handling, Lua-state closure, and exit status remain shared with Unix.
The Unix-rendered entrypoint is unchanged. `llvm-rc` (or the parsed `RC`
command) embeds an `asInvoker`, UTF-8, long-path-aware manifest; no machine
setting or global DLL search path is changed.

`spec/support/generate_windows_launcher_fixture.lua` emits the actual driver C,
`.def`, manifest, and resource text for the native
`spec/support/check_windows_launcher.sh` gate. It verifies exact PE protocol exports,
allowed imports, a separate Titan dependency, Unicode arguments and resource
paths, default/overridden/renamed launchers, bootstrap opt-out, and fresh
incompatible-provider rejection. This generated-C gate does not establish a
complete native `titanc` or standard-library build.

## Provider-owned slots and direct calls

The module public-prefix layout remains exported variables, top-level callable
closures, and nominal static closures. Its order is still useful within a
producer, but a separate dynamic consumer cannot embed those slot indices:
compatible additions or reordering may move them.

`coder/binary.lua` exports one `const unsigned int` for each public variable
or canonical closure slot. Names derive from the existing native callable
prefixes with `_variable_slot` or `_closure_slot`. A dynamic consumer resolves
the required data symbols once through the logical provider selected above,
and uses the resulting index for reads and writes.
The containing consumer-owned slot that stores its import remains constant.
Self-owned and same-binary provider accesses retain their known constant
indices.

Resolved native function pointers and slot numbers live in the importing
module's native payload, alongside its per-state function-type tag cache and
Interface implementation arrays. They are not mutable file-global bindings:
two Lua states can select different canonical providers without overwriting
each other's calls, slot indices, or Interface dispatch. The payload contains
native pointers and scalars; GC-bearing module and closure references remain
in traced uservalue slots.

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

Canonical-provider tests initialize one provider first, leave a different
compatible image at the consumer's selected filename, and prove that the
consumer uses the existing module's code and slots. Cover executable-embedded
and `package.loadlib` providers, transitive owners, and two Lua states with
different elected providers. Direct edges must reject a different canonical
physical provider.

Provider and incremental integration must additionally preserve the driver's
direct/handle/global provenance after object reuse and final linking. These are
link-plan classifications; dynamic runtime lookup still obeys logical module
identity. An exact
incremental-cache validity decision is separate from an already-built
consumer's selective runtime compatibility check.

## Windows DLL publication

The no-main Windows branch validates the generated source-object inventory
against the linked DLL's callable ABI/types/layouts in a fresh Lua child. It
checks the plain-C ABI before any Lua metadata call. Only after that child exits
does `publish_windows_provider` publish the DLL and its exact physical-provider
shims. Unix paired archive/DSO publication is unchanged.

`titan-compiler.windows_publication` has no native-loader or driver dependency.
Its caller supplies native filesystem operations. It prepares destination-local
copies, copies predecessor bytes into sibling backups, and replaces companions
before the DLL. It must not move the old DLL aside: Windows can rename a mapped
image but then refuse its deletion. Replacing the still-existing mapped image
fails before changing its public pathname; caught failures restore only already
committed files. Failed restoration retains its backup and reports the path's
error. This is byte recovery, not metadata preservation, process-crash atomicity,
or protection against concurrent publishers.

General stale-shim retirement is deferred on Windows because the prior DLL does
not provide the old physical membership inventory. An arbitrary matching banner
or logical-name prefix is insufficient evidence of ownership. The fixed standard
provider uses exactly its 21 reviewed logical names, without broad deletion.
