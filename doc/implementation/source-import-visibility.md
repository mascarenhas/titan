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

Ordinary resolver contexts reach that result only after compiled-provider
passes. The test runner's invocation-local `source_first` policy changes lookup
order, not the capability: its generated runner still receives private access
only because the canonical modules were actually parsed and checked from
source. See [Native test runner](test-runner.md).

A checked source module retains a compiler-only overlay on its `Type.Module`:

* `source_members` and `source_type_members` hold its own local value and type
  declarations;
* `_source` and source-complete nominal decorations distinguish trusted
  producer descriptors from public facades.

No header closure or C preprocessing context is stored on the module type.

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

## Use-driven C header origins

Titan visibility and C compilation context are separate. The checker-normalized
include descriptor that produced a C declaration is retained as compiler-only
`_c_origin_header` metadata on its declaration graph. Primitives from the
shared target profile remain undecorated. Typedefs, pointers, arrays, callbacks,
aggregates, and their physical fields retain enough origin information for a
later renderer to select what its exact spelling needs.

During `coder.generate`, every actual C type/declaration renderer records only
origins on its selected declarator path. A retained typedef or aggregate stops
at its own spelling; hidden typedef targets/aggregate fields are not traversed,
and an `owned` value's `Udata *` representation does not collect its payload
header until a real payload cast or access renders that type. The final preamble
contains all direct foreign imports, in AST order, followed by non-direct used
origins in stable byte order; normalized `include.rendered` text is the identity
and emitted spelling for both roles. Selecting an unrelated Titan nominal
member therefore cannot pull in another member's C header.

Source imports do not merge tag registries, macro definitions, declaration
graphs, or preprocessing state. Each module is an ordinary C translation unit
compiled by the same configured toolchain. Declaration extraction continues to
process each direct foreign import normally, and the compiler diagnoses an
ill-formed generated unit. A narrow use-time query builds an immutable probe
context from the consumer's direct imports plus only the origins required by
its rendered operand declarations. Enum-carrier selection uses that same final
context and the exact current surface, including an outer typedef; a check in
one producer or alias therefore cannot certify another header/macro context.
Neither kind mutates or grants authority through the consumer's direct-header
context.

## Module state and native linkage

The public reconstructible module-state prefix is unchanged by the generic
visibility mechanism. Generated modules then allocate the unconditional
Array-metatable cache and one immutable physical-provider identity slot,
followed by a deterministic source-private region:

1. local module variables in source order;
2. local top-level function closures in source order;
3. local constructors and nominal-function closures in nominal/source order.

Every co-generated importer reconstructs those slots from the same layout.
Before reading a private slot, it compares the canonical state token with the
hidden identity entry linked from its exact producer translation unit. A
same-name state installed by another physical provider is an error. Reads and
writes otherwise target the producer `_mod`; GC-bearing writes use the userdata
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
from its public schema and public closure prefix, and because every module's
userdata gains the fixed physical-provider identity slot used to authenticate
source-private state. ABI 0.21 providers are rejected before metadata decoding
and are neither migrated nor deleted.
