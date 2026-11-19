# Explicit source-import collaboration interfaces

This chapter implements the language rules in
[Sharing private declarations across source modules](../language/modules.md#sharing-private-declarations-across-source-modules).
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

The checker's top-level import visitor (`checker/declarations.lua`
`toplevel_visitor`) passes a `{ kind = "source-import" }` request to
`checker.checkimport` only for an import AST whose marker bit is set; an
object-backed source entry replays the same request for its recorded
source-required imports (`driver.lua` `load_source_object`).
`driver.defaultloader` services that request by running canonical folder/flat
source lookup before any compiled-provider pass. A clean miss is the
compile-time error `source module '<name>' not found`; a blocked folder
constituent or source error is likewise terminal. The loader never falls back
to a DSO or archive for this request, and it replaces or bypasses an already
cached compiled selection when source exists.

One resolver context records every serialized public projection of each
compiled interface it has actually returned, including nominal-owner views
recovered contextually through compiled facades
(`remember_used_compiled_interface`, stored in
`context.used_compiled_interfaces`). If a later source-required edge replaces
that selection, the checked source module is serialized through the same
public-only projection and must match every recorded view
(`check_used_compiled_interface`). A mismatch (`source module '<name>' does not
match a compiled interface already used in this compilation`) is appended to
the ordinary source-checker error list before foreign-header preparation, so
compilation stops before finalization or code generation while keeping
coherent source state for diagnostics. Process-global compiled entries that
were not used by this resolver are intentionally replaceable; a later
independent compilation must not be constrained by an old cache entry.

`driver.defaultloader` and `driver.tableloader` report whether the selected
module came from source, a DSO, or an archive, and `checker.checkimport` returns
that trusted provenance with the module type. The import visitor sets the AST's
`_source_import` capability only when the import has `source_required == true`,
the loader reports `kind == "source"`, and the descriptor carries `_source`
(it was produced by the current checker).

Ordinary resolver contexts may also select source after compiled-provider
passes. The `source_first` policy (used by `--test` and `--source-first`)
changes lookup order, not visibility: ordinary imports remain public-only. The
generated test runner imports discovered source-backed owners explicitly with
`.titan`, so their public native fields keep the authored C header environment;
tests that inspect a producer's locals write their own explicit `.titan`
import. See [Native test runner](test-runner.md).

A checked source module retains a compiler-only overlay on its `Type.Module`:

* `source_members` and `source_type_members` hold its own local value and type
  declarations; a `local foreign function` also lives only in this overlay and
  is marked as a declaration designator rather than a module-state value;
* `_source` and source-complete nominal decorations distinguish trusted
  producer descriptors from public facades.

No generated-header pathname is serialized or treated as module-type
authority. A trusted source loader result carries the temporary/final companion
path separately, and the consumer import AST records it for checking/codegen.

The ordinary `members` and `type_members` tables remain the public projection.
Serialization uses only that projection. The recovered-interface validator
rejects every compiler-only source field (`metadata contains compiler-only
source interface state`), so evaluated DSO/archive metadata cannot spoof source
provenance. `checker/imports.lua` builds the overlay; `checker/lowering.lua`
empties it in erased copies.

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

The import visitor records each explicit source edge in `st.source_imports`,
keyed by module name. `symtab:source_import_visible` consults that edge
together with `symtab:hidden_from_initializer`, so a module-variable
initializer sees an owner's source overlay only through an import written
earlier in combined top-level order (`_toplevel_order`); function signatures
and bodies see every import.

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
including transitive typedefs. Ordinary `type` aliases stay in the Titan
namespace with direct source-private visibility.

This C include chain is transitive. Private Titan declarations still require a
direct explicit source-import capability; a transitive C include does not make
`alias.private_member` available. Ordinary Titan imports and binary providers
supply no generated C environment. Each module remains an ordinary separate C
translation unit.

A source dependency defining foreign functions also contributes `.titan.h` for
its prototypes and local direct-call helpers. Generated C includes its own
`.ffi.h` before any `.titan.h`. Resolver-owned checking trees contain the actual
generated headers with deterministic logical paths; there are no forwarding
wrappers or supplemental origin lists collected from used type graphs.

Enum selection and contextual C probes use the exact current type surface in
the consumer's combined `.ffi.h` context. A producer's successful probe does not
certify a different consumer header environment. Additional consumer headers
may cause C declaration or conversion diagnostics during final compilation.

## Module state and native linkage

Source-private module state follows the public prefix, the Array-metatable
caches, and the physical-provider identity slot; the complete slot order is in
[User-value allocation](codegen-overview.md#user-value-allocation). A foreign
declaration has no closure or value slot and does not enter this layout. Every
co-generated source importer reconstructs the producer's private slots from the
same layout (`coder._source_prefix_layout`). Lua stores a userdata's user-value
count in an `unsigned short`, so `coder.generate` asserts that the module needs
at most `0xFFFF` slots before it renders `_init`; a larger module fails
compilation with `module '<name>' requires <n> module-state slots; Lua supports
at most 65535`.

Before reading a private slot, the importer compares the producer's identity
slot with the hidden identity function linked from its exact producer
translation unit (`coder/module.lua` `import_module`, `source_check`). A
same-name state installed by another physical provider raises `source import
'<name>' found canonical module state from a different physical provider`.
Reads and writes otherwise target the producer `_mod`; GC-bearing writes use
the userdata back barrier. Function and nominal-value reads load the producer's
canonical closure slot, preserving identity across importers and Lua GC cycles.

Local native entries needed across source translation units are declared
`TITAN_SOURCE_LOCAL` (`cpreamble.lua`), which is `visibility("hidden")` on
GCC/Clang and empty elsewhere. Public foreign entries have ordinary C external
linkage and are callable through regular imports. Local nominal statics and
methods use the same module/owner/member name hierarchy as public ones;
visibility, not an alternate spelling, keeps private entries out of the DSO's
dynamic API, and they stay linkable within one source/static composition.

## Binary boundary and ABI

Neither DSO callable metadata nor archive metadata contains the source overlay
or private layout. Binary imports therefore use only public closure slots and
public native symbols. A static provider selected as a dependency cannot grant
local access merely because its objects enter the final link.

The overlay, the `.titan` parser marker, and the source-required request add no
serialized field or native identity. The identity slot and private-region
layout are part of the compiled-module ABI; see [Compiled-module
ABI](codegen-overview.md#compiled-module-abi). Private native layout remains
producer-owned, and the public nominal-layout protocol is in [Native nominal
storage](nominal-storage.md).
