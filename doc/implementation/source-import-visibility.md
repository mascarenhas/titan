# Explicit source-import collaboration interfaces

This chapter implements the language rules in
[Visibility through explicit source imports](../language/source-import-visibility.md).
The central invariant is that **written opt-in and trusted source provenance
jointly grant permission**. Neither half is sufficient: an ordinary import is
public-only even when the loader selected source, while a `.titan` import cannot
fall back to a binary. A rich in-memory descriptor, nominal registry entry,
selected static dependency, or physical provider relationship never grants
permission by itself.

## Parsing and logical identity

`parser.normalize_import` recognizes one terminal `.titan` marker, removes it,
then applies standard-library shorthand. The resulting `Ast.TopLevelImport`
stores the canonical `modname` plus a separate `source_required` bit. For
example, both `uv.titan` and `titan.uv.titan` produce canonical module name
`titan.uv` with `source_required == true`.

Only the separate bit records the written request. The stripped name is used by
the checker, resolver caches, dependency graph, source paths, native mangling,
generated artifacts, `Type.Module`, DSO metadata, and archive manifests. The
marker is therefore never observable as a second module identity.

`staticmetadata.valid_module_name` rejects a dotted logical name whose final
component is `titan`, because its import spelling would always be consumed as
the marker. Bare `titan` remains the canonical standard-provider identity, and
`titan` may remain a nonterminal component.

## Loader result and module views

`checker.checkimport` forwards a source-required request only for an import AST
whose marker bit is set. `driver.defaultloader` services that request by running
canonical folder/flat source lookup before any compiled-provider pass. A clean
miss is the compile-time error `source module '<name>' not found`; a blocked
folder constituent or source error is likewise terminal. The loader never
falls back to a DSO or archive for this request, and it replaces or bypasses an
already cached compiled selection when source exists.

One resolver context records every serialized public projection of each
compiled interface it has actually returned, including nominal-owner views
recovered contextually through compiled facades. If a later source-required
edge replaces that selection, the checked source module is serialized through
the same public-only projection and must match every recorded view. A mismatch
is added to the ordinary source-checker error list before foreign-header
preparation, so compilation stops before finalization or code generation while
retaining coherent source state for diagnostics. Process-global compiled
entries that were not used by this resolver are intentionally replaceable; a
later independent compilation must not be constrained by an old cache entry.

`driver.defaultloader` and `driver.tableloader` still report whether the selected
module actually came from source, a DSO, or an archive. `checker.checkimport`
returns that trusted provenance with the module type. Only an import that both
has `source_required == true` and receives `kind == "source"` for a descriptor
produced by the current checker sets the AST's `_source_import` capability.

Ordinary resolver contexts may also select source after compiled-provider
passes. The test runner's invocation-local `source_first` policy changes lookup
order, not visibility: ordinary imports in either context remain public-only.
The generated runner writes an explicit `import "titan.test.titan"` edge for its
private protocol. See [Native test runner](test-runner.md).

A checked source module retains a compiler-only overlay on its `Type.Module`:

* `source_members` and `source_type_members` hold its own local value and type
  declarations; a source `foreign function` also lives only in this overlay and
  is marked as a declaration designator rather than a module-state value;
* `_source` and source-complete nominal decorations distinguish trusted
  producer descriptors from public facades.

No generated-header pathname is serialized or treated as module-type
authority. A trusted source loader result carries the temporary/final companion
path separately, and the consumer import AST records it for checking/codegen.

The ordinary `members` and `type_members` tables remain the public projection.
Serialization uses only that projection. The recovered-interface validator
rejects every compiler-only source field, so evaluated DSO/archive metadata
cannot spoof source provenance.

`types.registry` may retain a source-complete nominal descriptor when a compiled
facade or ordinary source import for the same owner is loaded later. That
descriptor is canonical type information, not authority: every local lookup
also checks the current symbol table's explicit direct-owner capability. This
keeps mixed public/explicit and source/binary loading order-independent.

Interface registration first validates the public projection with public-only
member visibility, then traverses the complete trusted source declarations.
That second pass includes private fields, variants and callable signatures on
public nominal owners, as well as local top-level declarations. Referenced
owners are recovered through the active loader, so a retained declaration
manifest cannot substitute its carried owner view for a changed dependency.
The source pass validates generic constraints with the producer's own direct
source-import permissions. Fresh checking supplies its symbol-table imports;
loader results reconstruct the same permissions from checked import annotations
or a compact entry's retained `source_imports`. These permissions stay within
interface validation and never enter the consumer's symbol table.
The table loader uses the same proven producer edge to select an owner's source
view during nominal recovery, while ordinary import aliases retain the public
view. If the owner is cached as a binary interface, that edge requires its
current source before validating the producer's private declarations.
Nested source recovery uses each recovered producer's own direct edges; the
outer importer's permissions do not substitute for that producer's provenance.
Owner recovery memoization includes the exposing context, so a public view
selected by an earlier ordinary edge cannot satisfy a later producer's source
edge. Validation still checks the public projection before private declarations.

## Checker staging

The import pass records the earliest explicit source edge per owner.
Module-variable frontier checks consult that edge, so a local variable
initializer sees only an owner import that was written earlier; body checking
retains the ordinary placement-independent declaration rules.

Module/type/member lookup first uses the public projection. It consults the
source overlay only when the matching explicit-source capability is present.
Nominal lookup applies the same owner check to local fields, variants,
constructors, methods, and nominal functions. Capabilities are not copied from
an imported module, which enforces direct-only Titan visibility.

Local Interfaces remain rejected. Interface satisfaction is evaluated at the
cast site, so a source-visible local concrete method can participate without
turning Interface conversion into a transitive relation.

## Combined C environment inheritance

Titan visibility and C compilation context are separate. An explicit `.titan`
edge carries the dependency's validated `.ffi.h` descriptor. The consumer's
`.ffi.h` includes all explicit-source dependency FFI headers in written import
order before its own foreign directives. The C driver preprocesses and parses
that actual combined header, preserving include guards, final macro state,
and C declaration/tag scopes. The resulting C names populate the consumer's
builtin `ffi` value namespace and separate foreign type namespace throughout its Titan module.

`foreign type Name = foreigntype` declarations are raw C typedefs in these
headers. They are always local to source, have no `local` modifier, and do not
occupy the exported or source-private Titan type-member maps. An explicit
source importer sees their unqualified foreign names through the header graph,
including transitive typedefs. Ordinary `type` aliases retain their existing
Titan namespace and direct source-private visibility.

This C include chain is transitive. Private Titan declarations still require a
direct explicit source-import capability; a transitive C include does not make
`alias.private_member` available. Ordinary Titan imports and binary providers
supply no generated C environment. Each module remains an ordinary separate C
translation unit.

A source dependency defining foreign functions also contributes `.titan.h` for
its prototypes and eligible inline bodies. Generated C includes its own
`.ffi.h` before any `.titan.h`. Resolver-owned checking trees contain the actual
generated headers with deterministic logical paths; there are no forwarding
wrappers or supplemental origin lists collected from used type graphs.

Enum selection and contextual C probes use the exact current type surface in
the consumer's combined `.ffi.h` context. A producer's successful probe does not
certify a different consumer header environment. Additional consumer headers
may cause C declaration or conversion diagnostics during final compilation.

## Module state and native linkage

The public reconstructible module-state prefix is unchanged by the generic
visibility mechanism. Generated modules then allocate the unconditional
Array-metatable cache and one immutable physical-provider identity slot,
followed by a deterministic source-private region:

1. local module variables in source order;
2. local top-level function closures in source order;
3. local constructors and nominal-function closures in nominal/source order.

A source foreign declaration has no closure or value slot and does not enter
this layout. Every co-generated importer reconstructs those slots from the same layout.
Before reading a private slot, it compares the canonical state token with the
hidden identity entry linked from its exact producer translation unit. A
same-name state installed by another physical provider is an error. Reads and
writes otherwise target the producer `_mod`; GC-bearing writes use the userdata
back barrier. Function and nominal-value reads load the producer's canonical
closure slot, preserving identity across importers and Lua GC cycles.

Native entries needed across source translation units have hidden visibility.
Ordinary local/public top-level functions and source foreign declarations all
use the current ABI's injective module/member UCN separator. Local nominal statics and
methods use the same module/owner/member hierarchy as public ones; visibility,
not an alternate spelling, keeps private entries out of the DSO's dynamic API. They
remain linkable within one source/static composition. The coder rejects a module-state slot count larger than
Lua's `unsigned short` user-value carrier before emitting an undersized Udata.

## Binary boundary and ABI

Neither DSO callable metadata nor archive metadata contains the source overlay
or private layout. Binary imports therefore use public closure slots and public
native symbols exactly as before. A static provider selected as a dependency
cannot grant local access merely because its objects enter the final link.

The overlay itself introduces no serialized constructor. ABI 2 covers the
localized `titan.uv` public schema and closure prefix, every module's physical-
provider identity slot, source foreign collaboration, callable symbol families,
generic declarations, and current public standard-library and const metadata.
The current compiler uses ABI 2, language version 0.6.0, and language-server
API marker 1. The separate public nominal-layout protocol is described
in [Native nominal storage](nominal-storage.md); private native layout remains
producer-owned. Rebuild the compiler, runtime, and providers together after
prerelease layout changes.
An ABI-marker mismatch is rejected before type decoding or native linking.
Native compilation also rejects missing or malformed physical-layout metadata;
analysis-only recovery does not require it. These checks do not replace the
clean rebuild required for same-marker prerelease changes. Earlier installations
are neither migrated nor deleted. The explicit `.titan` parser marker and
source-required request add no serialized field or native identity and
therefore require no additional ABI change.
