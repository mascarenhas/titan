# Type aliases: implementation

Titan type aliases are compile-time-only, transparent names. The implementation
keeps them out of the first-class value namespace and represents a resolved
alias by the right-hand-side `Type.*` value itself; there is no `Type.Alias`
wrapper, run-time module slot, C declaration, metatable, conversion, or
alias-owned forwarding namespace. A record or union alias may still be the
compile-time base of a static selector, which resolves directly to the original
nominal member.

## Frontend and resolution

The parser turns `[local] type Name = T` into `Ast.TopLevelTypeAlias`. The lexer
reserves `type`. The RHS enters the Titan type category; the checker also
rejects a grouped direct foreign type that would otherwise cross this boundary.
`Ast.TypeOwned` is a Titan constructor over a raw foreign pointer or array, so
ordinary aliases may name owned storage. The `foreign` prefix selects the separate foreign grammar, whose names are
`Ast.TypeForeignName` nodes and whose pointer, array, and callable shapes keep
their distinct C-type AST constructors.

`symtab.lua` maintains a top-level alias table separate from lexical value
blocks and from the C-FFI type namespace. The checker predeclares alias names,
then resolves targets lazily. Resolution has unresolved, resolving, and resolved
states: this supports forward aliases and aliases used by earlier signatures,
while a second visit to a resolving alias reports a cycle and substitutes
`Type.Invalid` for recovery. Recursive records and unions remain valid because
the cycle is through a nominal declaration rather than alias expansion.

Top-level collection visits every Titan and foreign import in AST order before
the alias-resolution stage. A qualified alias target may consequently name an
import written later; the checker has loaded that module and reserved its alias
without reordering the AST. Aliases remain visible module-wide when module
variables are checked. The module-variable frontier is enforced by ordinary
symbol lookup instead: a direct qualified reference to a later import is
masked under `st.initializer_order` even though alias resolution and other
non-variable declarations see the complete import environment.

An unqualified `Ast.TypeName` checks the alias table before falling back to a
nominal record or union name. For `m.Name`, `Ast.TypeQualName` checks the
imported Titan module's `type_members` before its exported nominal members.

Ordinary expression lookup still gives value declarations and `Module.members`
precedence. If an otherwise unbound `Ast.VarName`, or a missing run-time module
member in `Ast.VarDot`, names an alias whose resolved target is a visible
`Type.Nominal` record or union, the checker decorates that node as an alias
namespace and gives it the canonical `Type.Record` or `Type.Union` descriptor.
The following selector then takes the ordinary static-function path, including
the existing per-member visibility check. A bare alias expression is rejected
as an attempt to use a record or union type as a first-class value. Interfaces
and non-nominal aliases do not enter this fallback.

`Type.Variant` entries inside a union schema are not type members: aliasing or
annotating with `Message.move` is rejected, while `type Event = Message`
permits `Event.move(...)` to select the original public constructor.

Export validation walks resolved alias targets recursively. Public aliases
containing local nominal types or nonexportable C descriptors are rejected by
the same rules as function signatures, variables, and public nominal members.
Portable owned graphs and Titan constructors containing portable foreign
components remain eligible public targets; a direct raw foreign alias uses the
separate declaration below. A header-defined `CTypedef` remains nonexportable
regardless of its resolved target.

## Foreign aliases are a separate C declaration

`Ast.TopLevelForeignTypeAlias` represents `foreign type Name = foreigntype`.
It is always local and has no `local` modifier. The symbol table keeps foreign
aliases separate from ordinary Titan aliases, checks their dependency graph,
and emits real C typedefs into the module's `.ffi.h`. The RHS cannot contain
Titan types, including owned storage. This path uses C declaration identity
and collision rules rather than transparent Titan alias expansion.

An explicit source import inherits the generated header and its unqualified
foreign typedef names. A regular module import does not acquire a `module.Name`
foreign alias. The header plan persists typedef declarations and dependency
identity so restored source manifests rebuild the same C environment. See
[FFI internals](ffi-internals.md) for the complete publication path.

## Module interfaces

`Type.Module` has two namespaces:

* `members` contains run-time variables, functions, and record/union namespaces;
* `type_members` maps exported alias names directly to their resolved targets.

Foreign aliases belong to the header environment, not either of these maps.
The two maps are serialized independently and deterministically by
`types.serialize`. A compiled-interface importer therefore rehydrates a
transparent alias with the same nominal owner name and structural component
types, whether the interface came from DSO callables or an archive metadata
section, without inventing a run-time member. The third serialized `Module`
component is therefore part of the compiled-module ABI.

`checker.checkimport` recursively registers records and unions reachable through
both namespaces. This matters when the alias is the only exported reference to
an owner whose source is unavailable: nominal lookup still has to recover the
owning declaration from the serialized interface.

The module-userdata public-prefix layout is derived in `types.lua` from a
complete `Type.Module`: variables, top-level function closures, then public
nominal static closures in deterministic order. When the checker recovers an
owner interface transitively, it stamps the canonical static descriptors with
those closure indices. A facade's `type_members` entry never receives a slot;
first-class selectors through an alias later index the original owner userdata.

## Transitive nominal members across providers

Consider three dynamically linked modules:

```text
A exports record Foo with constructor/static functions and methods
B imports A and exports type Foo = A.Foo
C imports B and uses B.Foo.new, B.Foo.static, and a method on B.Foo
```

The alias keeps every member's defining name as `A.Foo`, so C code refers to
A's native static, method, and bound-method trampoline symbols. C must not open
A directly: B's initializer already calls Titan's `loadlib` for A with
`RTLD_LAZY | RTLD_GLOBAL` and initializes A's canonical module userdata.

Code generation separates those transitive symbols from ordinary direct
imports. `_init` performs the steps in this order:

```text
load C's explicit dependency B
initialize B (which globally loads and initializes A)
resolve any directly called A member symbols with loadglobalsym / dlsym(RTLD_DEFAULT, ...)
recover A's module userdata and record metatable from the Lua registry
```

Direct dynamic imports still use their own checked handle and `loadsym`.
Transitive symbol lookup deliberately has no `loadlib("A.so")` or redundant
ABI check in C: B checked A before publishing its interface and symbols. The
module userdata used as a method or static function's `_mod` argument is
recovered under `"Titan module A"`, which B's initialization has populated.

A first-class static selector does not need another native symbol lookup. It
reads the canonical closure from the recovered A userdata at the checker-stamped
public-prefix index; the closure already carries A's module, type tag, native
entry, and strict entry. A direct static call uses the same recovered owner
userdata and the statically resolved A entry point. Thus neither path reads a
nonexistent namespace or closure slot from B.

This ordering also applies to Lua trampolines for bound method references.
Static archive and multi-module providers use the same logical owner and
registry recovery; only their native symbol linkage differs from the DSO path.
