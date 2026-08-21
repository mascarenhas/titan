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

## Use-driven C header origins

Titan visibility and C compilation context are separate. The checker-normalized
include descriptor that produced a C declaration is retained as compiler-only
`_c_origin_header` metadata on its declaration graph. Primitives from the
shared target profile remain undecorated. Typedefs, pointers, arrays, callbacks,
aggregates, and their physical fields retain enough origin information for a
later renderer to select what its exact spelling needs.

During C or companion-header generation, every actual C type/declaration
renderer records only origins on its selected declarator path. A retained
typedef or aggregate stops at its own spelling; hidden typedef targets/aggregate
fields are not traversed, and an `owned` value's `Udata *` representation does
not collect its payload header until a real payload cast or access renders that
type. The relevant preamble contains direct foreign imports in AST order,
followed by non-direct used origins in stable byte order; normalized
`include.rendered` text is the identity and emitted spelling for both roles.
Selecting an unrelated Titan nominal member therefore cannot pull in another
member's C header.

Explicit source imports do not merge Titan aliases, C type/tag registries, or
declaration graphs. Each module remains an ordinary C translation unit. An
explicitly imported producer with source foreign declarations does, however,
supply one real generated C header: after all imports are visited, the consumer
checker processes those headers in AST order and replays their macro effects
into its cumulative probe context. This is declaration plumbing, not Titan
permission—the explicit-source capability still gates `alias.foreign_member`
independently. It makes the consumer's checked macro/declaration surface agree
with the header that its final generated C will include.

Other source-private C uses retain the narrow use-driven rule. A probe context
starts from the consumer's direct imports and source-generated headers, then
adds only origins required by rendered operand declarations. Enum-carrier
selection uses that final context and the exact current surface, including an
outer typedef; a check in one producer or alias cannot certify another
unrelated header context.

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
use ABI 0.23's injective module/member UCN separator. Local nominal statics and
methods use the same module/owner/member hierarchy as public ones; visibility,
not an alternate spelling, keeps private entries out of the DSO's dynamic API. They
remain linkable within one source/static composition. The coder rejects a module-state slot count larger than
Lua's `unsigned short` user-value carrier before emitting an undersized Udata.

## Binary boundary and ABI

Neither DSO callable metadata nor archive metadata contains the source overlay
or private layout. Binary imports therefore use public closure slots and public
native symbols exactly as before. A static provider selected as a dependency
cannot grant local access merely because its objects enter the final link.

The overlay itself introduces no serialized constructor. ABI 0.22 is required
because localizing the `titan.uv` implementation deliberately removes members
from its public schema and public closure prefix, and because every module's
userdata gains the fixed physical-provider identity slot used to authenticate
source-private state. ABI 0.21 providers are rejected before metadata decoding.
ABI 0.23 retains that overlay/layout but adds source foreign collaboration and
changes the separated callable symbol families; 0.22 providers are rejected
before metadata decoding or native linking. ABI 0.24 retains the overlay and
native layout while extending generic declaration metadata; 0.23 providers are
rejected before decoding. ABI 0.25 retains the overlay and layout while
changing the public `titan.fs` and `titan.async` signatures; 0.24 providers are
rejected before decoding. ABI 0.26 retains the overlay while extending const
and Interface metadata; 0.25 providers are rejected before decoding. Earlier
trees are neither migrated nor deleted. The explicit `.titan` parser marker and
source-required request add no serialized field or native identity and
therefore require no additional ABI change.
