# Source-import collaboration interfaces

This chapter implements the language rules in
[Visibility through source imports](../language/source-import-visibility.md).
The central invariant is that **loader provenance grants permission**. A rich
in-memory descriptor, nominal registry entry, selected static dependency, or
physical provider relationship never does.

## Loader result and module views

`driver.defaultloader` and `driver.tableloader` report whether an import was
selected from source, a DSO, or an archive. `checker.checkimport` returns that
trusted provenance with the module type. Only a direct `kind == "source"` edge
to a descriptor produced by the current checker sets the import AST's
`_source_import` capability.

A checked source module retains a compiler-only overlay on its `Type.Module`:

* `source_members` and `source_type_members` hold its own local value and type
  declarations;
* `_source_foreign_includes` is the ordered transitive include closure;
* `_source_c_context` carries the corresponding file/prototype C-tag context;
* `_source` and source-complete nominal decorations distinguish trusted
  producer descriptors from public facades.

The ordinary `members` and `type_members` tables remain the public projection.
Serialization uses only that projection. The recovered-interface validator
rejects every compiler-only source field, so evaluated DSO/archive metadata
cannot spoof source provenance.

`types.registry` may retain a source-complete nominal descriptor when a compiled
facade for the same owner is loaded later. That descriptor is canonical type
information, not authority: every local lookup also checks the current symbol
table's direct-owner source capability. This keeps mixed source/binary loading
order-independent.

## Checker staging

The import pass records the earliest direct source edge per owner. Module-variable
frontier checks consult that edge, so a local variable initializer sees only an
owner import that was written earlier; body checking retains the ordinary
placement-independent declaration rules.

Module/type/member lookup first uses the public projection. It consults the
source overlay only when the matching direct source capability is present.
Nominal lookup applies the same owner check to local fields, variants,
constructors, methods, and nominal functions. Capabilities are not copied from
an imported module, which enforces direct-only Titan visibility.

Local Interfaces remain rejected. Interface satisfaction is evaluated at the
cast site, so a source-visible local concrete method can participate without
turning Interface conversion into a transitive relation.

## C context closure

Titan visibility and C compilation context are separate. Every direct source
edge appends its producer's ordered `_source_foreign_includes` closure and merges
a cloned `_source_c_context`; the resulting context is retained for the next
source consumer. Cloning isolates mutable C completion graphs and target-profile
leaves between checker invocations while preserving cycles and sharing inside
one module.

Declaration extraction remains the C frontend's ordinary per-header work. For
field projections and declaration compatibility, independently extracted equal
named file-scope tags model the single namespace of the generated translation
unit; a visible later completion can supply fields without mutating the
producer's descriptor.

After all imports, the checker asks the configured C compiler once for the final
macro environment of the exact generated prefix, ordered foreign includes, and
post-header prefix. This delegates include guards, `#pragma once`, macro
push/pop, redefinitions, and implementation-defined preprocessing to the same
compiler used for generated C. The resulting definitions replace, rather than
accumulate with, earlier macro state. C probes are invalidated whenever the
include closure grows.

The overlay carries C descriptors with an immutable defining-module `_ffi_scope`.
Function-tag and owned-C metatable keys use that scope, so equal rendered C
spellings from different module TUs do not collapse. Probe-service target
profiles are cloned before these decorations are attached.

## Module state and native linkage

The public reconstructible module-state prefix is unchanged by the generic
mechanism. Generated modules then allocate the unconditional Array-metatable
cache, followed by a deterministic source-private region:

1. local module variables in source order;
2. local top-level function closures in source order;
3. local constructors and nominal-function closures in nominal/source order.

Every co-generated importer reconstructs those slots from the same layout.
Reads and writes target the producer `_mod`; GC-bearing writes use the userdata
back barrier. Function and nominal-value reads load the producer's canonical
closure slot, preserving identity across importers and Lua GC cycles.

Native entries needed across source translation units have hidden visibility
and private injective names. They remain linkable within one source/static
composition but absent from the DSO's dynamic API. Public entries retain their
existing ABI names. The coder rejects a module-state slot count larger than
Lua's `unsigned short` user-value carrier before emitting an undersized Udata.

## Binary boundary and ABI

Neither DSO callable metadata nor archive metadata contains the source overlay
or private layout. Binary imports therefore use public closure slots and public
native symbols exactly as before. A static provider selected as a dependency
cannot grant local access merely because its objects enter the final link.

The overlay itself introduces no serialized constructor. ABI 0.22 is required
because localizing the `titan.uv` implementation deliberately removes members
from its public schema and public closure prefix. ABI 0.21 providers are rejected
before metadata decoding and are neither migrated nor deleted.
