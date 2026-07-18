# Type aliases: implementation

Titan type aliases are compile-time-only, transparent names. The implementation
keeps them out of the value namespace and represents a resolved alias by the
right-hand-side `Type.*` value itself; there is no `Type.Alias` wrapper, run-time
module slot, C declaration, metatable, or conversion.

## Frontend and resolution

The parser turns `[local] type Name = T` into `Ast.TopLevelTypeAlias`. The lexer
reserves `type`, and the right-hand side uses the ordinary type grammar, so all
compound types are available without a parallel parser.

`symtab.lua` maintains a top-level alias table separate from lexical value
blocks and from the C-FFI type namespace. The checker predeclares alias names,
then resolves targets lazily. Resolution has unresolved, resolving, and resolved
states: this supports forward aliases and aliases used by earlier signatures,
while a second visit to a resolving alias reports a cycle and substitutes
`Type.Invalid` for recovery. Recursive records remain valid because the cycle
is through the nominal record declaration rather than through alias expansion.

Top-level collection visits every Titan and foreign import in AST order before
the alias-resolution stage. A qualified alias target may consequently name an
import written later; the checker has loaded that module and reserved its alias
without reordering the AST. Aliases remain visible module-wide when module
variables are checked. The module-variable frontier is enforced by ordinary
symbol lookup instead: a direct qualified reference to a later import is
masked under `st.initializer_order` even though alias resolution and other
non-variable declarations see the complete import environment.

An unqualified `Ast.TypeName` checks the alias table before falling back to a
nominal record name. For `m.Name`, `Ast.TypeQualName` checks the imported Titan
module's `type_members` before its exported record members. Expression lookup
continues to consult only value members, which is what makes aliases type-only.

Export validation walks resolved alias targets recursively. Public aliases that
contain C-FFI types or local record types are rejected by the same rules as
function signatures, variables, and public record members.

## Module interfaces

`Type.Module` has two namespaces:

* `members` contains run-time variables, functions, and record namespaces;
* `type_members` maps exported alias names directly to their resolved targets.

The two maps are serialized independently and deterministically by
`types.serialize`. A compiled-interface importer therefore rehydrates a
transparent alias with the same nominal record name and structural component
types, whether the interface came from DSO callables or an archive metadata
section, without inventing a run-time member. Adding this third serialized
`Module` component was an interface ABI change, so this feature advanced
`TITAN_VER` to 0.12.

`checker.checkimport` recursively registers records reachable through both
namespaces. This matters when the alias is the only exported reference to a
record whose source is unavailable: nominal lookup still has to recover the
owning record declaration from the serialized interface.

## Transitive record methods across DSOs

Consider three dynamically linked modules:

```text
A exports record Foo
B imports A and exports type Foo = A.Foo
C imports B and calls a method on a B.Foo value
```

The alias keeps the method's defining name as `A.Foo`, so C code refers to A's
native method and bound-method trampoline symbols. C must not open A directly:
B's initializer already calls Titan's `loadlib` for A with
`RTLD_LAZY | RTLD_GLOBAL`.

Code generation separates those transitive symbols from ordinary direct
imports. `_init` performs the steps in this order:

```text
load C's explicit dependency B
initialize B (which globally loads and initializes A)
resolve A's method symbols with loadglobalsym / dlsym(RTLD_DEFAULT, ...)
recover A's module userdata and record metatable from the Lua registry
```

Direct dynamic imports still use their own checked handle and `loadsym`.
Transitive symbol lookup deliberately has no `loadlib("A.so")` or redundant
ABI check in C: B checked A before publishing its interface and symbols. The
module userdata used as the method's `_mod` argument is recovered under
`"Titan module A"`, which B's initialization has populated.

This ordering also applies to Lua trampolines for bound method references.
