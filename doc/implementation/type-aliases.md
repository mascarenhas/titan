# Type aliases: implementation

Titan type aliases are compile-time-only, transparent names. A resolved alias
is represented by its right-hand-side `Type.*` value itself. There is no
`Type.Alias` wrapper, run-time module slot, C declaration, metatable,
conversion, or alias-owned forwarding namespace. A record or union alias can
still be the compile-time base of a static selector, which resolves directly
to the original nominal member.

## Frontend and resolution

`type` is a reserved word (`lexer.lua`). The parser turns `[local] type Name =
T` into `Ast.TopLevelTypeAlias(loc, islocal, name, type)`, whose right-hand
side is in the Titan type category. `Ast.TypeOwned` is a Titan constructor
over a raw foreign pointer or array, so ordinary aliases may name owned
storage. A `foreign` prefix selects the separate foreign type grammar, whose
names are `Ast.TypeForeignName` nodes and whose pointer, array, and callable
shapes keep their own C-type AST constructors.

`symtab.lua` keeps aliases in `type_aliases`, separate from the lexical value
`blocks`, from `foreign_aliases`, and from the C-FFI namespace
(`st.ffi_namespace`). The checker reserves alias names first and resolves
targets lazily in `resolve_type_alias` (`checker/common.lua`). Its
`_alias_state` decoration moves from unset to `"resolving"` to `"resolved"`.
This admits forward aliases and aliases used by earlier signatures. Reaching
an alias that is still `"resolving"` reports "cyclic type alias involving
'%s'" and substitutes `Type.Invalid` for recovery. Recursive records and
unions remain valid because their cycle runs through a nominal declaration,
not through alias expansion. The same function rejects a target that resolves
to a direct C type other than an owned one: "type alias '%s' cannot name a
direct foreign type; use 'foreign type'".

`checktoplevel` (`checker/declarations.lua`) visits every import in AST order
before resolving any alias, so a qualified alias target may name an import
written later without reordering the AST. Aliases are visible module-wide
while module variables are checked. The module-variable frontier is enforced
by ordinary symbol lookup instead: under `st.initializer_order`, a direct
qualified reference to a later import is masked, even though alias resolution
and other non-variable declarations see the complete import environment. See
[staged top-level collection](checker.md#staged-top-level-collection-and-body-checking).

In `checker/type_syntax.lua`, an unqualified `Ast.TypeName` checks generic
type parameters, then the alias table, then nominal names. For `m.Name`,
`Ast.TypeQualName` resolves `m` and checks its
`type_members` before its exported nominal members.

Expression lookup (`checker/variables.lua`) still gives value declarations
and `Module.members` precedence. When an otherwise unbound `Ast.VarName`, or a
missing run-time member in `Ast.VarDot`, names an alias whose resolved target
is a visible record or union, `generic_annotate_alias_namespace` marks the
node `_alias_namespace`, records `_alias_decl`, and gives it the canonical
`Type.Record` or `Type.Union` descriptor. The following selector takes the
ordinary static-function path, including its per-member visibility check. A
bare alias expression is rejected like any other nominal namespace used as a
value ("trying to access %s type '%s' as a first-class value",
`checker/expressions.lua`). An Interface name or alias reports "interface '%s'
is a type and has no runtime value"; non-nominal aliases do not enter this
fallback.

`Type.Variant` entries inside a union are not type members. A qualified
`Message.move` in a type position reports "union member '%s.%s' is not a type;
use union type '%s' or a case statement", while `type Event = Message` permits
`Event.move(...)` to select the original public constructor.

Export validation walks resolved alias targets recursively. A public alias
containing a local nominal type or a nonexportable C descriptor is rejected by
the same rules as function signatures, variables, and public nominal members.
Portable owned graphs and Titan constructors with exportable foreign
components are eligible public targets. `types.is_exportable_c_type_graph`
accepts a named header `CTypedef` with valid declaration provenance
(`types.c_declaration_origin`) when its complete target graph is exportable;
consumers must provide the original compatible C declarations, because an
ordinary Titan import does not inherit the declaring headers. The alias adds no
boxing, lifetime, or serialization policy. See [the C export
boundary](../language/ffi.md).

## Foreign aliases are a separate C declaration

`Ast.TopLevelForeignTypeAlias` represents `foreign type Name = foreigntype`. It
is always local and has no `local` modifier, and its right-hand side cannot
contain Titan types, including owned storage. `resolve_foreign_type_alias`
(`checker/common.lua`) resolves it with its own cycle check ("cyclic foreign
type alias involving '%s'"), builds a `Type.CTypedef`, records the rendered
declaration in `_c_typedef`, and appends the node to `st.foreign_alias_order`.
A written array or function type keeps an undeclared component as
`Type.Invalid`; such an alias becomes `Type.Invalid` itself and renders no
typedef, because the component's own diagnostic was already reported.
After all foreign aliases resolve, `checktoplevel` copies the declarations to
`ast._foreign_typedefs` and re-checks the C environment, which must then
declare each typedef name. `ffiheaders.lua` emits them into the module's
`.ffi.h`. This path follows C declaration identity and collision rules, not
transparent Titan alias expansion.

An explicit source import inherits the generated header and its unqualified
typedef names. A regular module import does not acquire a `module.Name`
foreign alias. [FFI internals](ffi-internals.md) describes header publication
and restoration.

## Module interfaces

`Type.Module` has two public namespaces:

* `members` holds run-time variables, functions, and record/union namespaces;
* `type_members` maps exported alias names directly to their resolved targets,
  alongside exported Interfaces.

Foreign aliases belong to the header environment, not to either map.
`types.serialize` writes `type_members` as the third `Module(...)` component,
sorted with `util.bytewise_less`, so it is part of the compiled-module ABI. An
importer of a compiled interface (DSO callables or archive metadata) therefore
rehydrates a transparent alias with the same nominal owner name and structural
component types, without inventing a run-time member. The source-private
`source_members`/`source_type_members` views used by explicit source imports
are described in [Source-import
visibility](source-import-visibility.md#loader-result-and-module-views).

`checker.register_module_interface` (`checker/imports.lua`, called first by
`checker.checkimport`)
registers records and unions reachable through both namespaces. This matters
when an alias is the only exported reference to an owner whose source is
unavailable: nominal lookup still has to recover the owning declaration from
the serialized interface.

A `type_members` entry never receives a module-userdata slot. The public
prefix contains only variables, functions, and public nominal statics
([user-value allocation](codegen-overview.md#user-value-allocation)), and
first-class selectors through an alias index the original owner's userdata.

## Transitive nominal members across providers

Consider three dynamically linked modules:

```text
A exports record Foo with constructor/static functions and methods
B imports A and exports type Foo = A.Foo
C imports B and uses B.Foo.new, B.Foo.static, and a method on B.Foo
```

The alias keeps every member's defining name as `A.Foo`, so C refers to A's
native static, method, and bound-method trampoline symbols. A becomes a
transitive owner of C that C never imports directly. C initializes B first,
which establishes A's canonical module userdata, then recovers A by logical
name from the Lua registry, checks A's ABI and C's compatibility requirements
for A, and resolves A's symbols and public slots through A's export callback.
The lookup never opens `A.so` or uses `RTLD_DEFAULT`, so A may live in an
executable, a linked archive, or a locally loaded DSO. The general mechanism is
in [static vs dynamic dependency
wiring](codegen-overview.md#static-vs-dynamic-dependency-wiring).

The alias-specific consequence is that C never reads a namespace or closure
slot from B. A first-class static selector reads the canonical closure from
A's recovered userdata at A's resolved public slot. A direct static call, a
method call, or a bound-method trampoline passes that same userdata as `_mod`
to A's resolved native entry. Static archive and same-binary providers use the
same logical owner and registry recovery, but keep direct native linkage and
constant slot indices.
