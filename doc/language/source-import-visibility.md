# Visibility through source imports

A Titan `import` can resolve to source in the current compilation or to a
compiled `.so`/`.a` provider. The two cases intentionally expose different
interfaces.

A **direct source import** exposes the imported module's complete Titan
collaboration surface through the written import alias. A binary import exposes
only its ordinary public interface. This lets a group of source modules share
implementation details without publishing those details to separately compiled
consumers or to Lua.

## Direct source visibility

Given a direct source edge

```lua
local engine = import "example.engine"
```

`engine` can select declarations owned by `example.engine`, including local:

* module variables, for both typed reads and writes;
* functions;
* records and unions;
* type aliases;
* record fields and union variants;
* generated record and variant constructors;
* methods and nominal functions.

Top-level values and types remain qualified (`engine.reset`, `engine.State`).
A local field or method is selected from a value of the owner type in the usual
way (`state.hidden`, `state:advance()`); the compiler checks that the current
module has a direct source capability for that nominal owner.

Local module variables refer to the producer's canonical module state. Likewise,
reading a local function, constructor, method, or nominal function as a value
returns the producer's canonical closure; each importer does not manufacture a
new copy.

Local Interfaces are not supported. A local concrete method that is visible
through a direct source import may, however, satisfy an ordinary public
Interface at that cast site.

## Visibility is direct, not transitive

Titan member permission follows only written direct source edges. If `middle`
source-imports `owner`, and `consumer` imports only `middle`, `consumer` does
not acquire access to declarations local to `owner`. It must import `owner`
directly as source.

The same rule applies to local nominal members and aliases. A public declaration
cannot be used to launder a wholly local record or union into a transitive
capability.

Bare names are unaffected: an import never injects another module's declarations
into the importing module's lexical scope.

## Foreign declarations

A source-visible declaration may contain a C FFI type even though its consumer
did not write the corresponding `foreign import`. The compiler therefore carries
the ordered closure of required C headers and C tag/prototype context through
source imports. That closure is transitive because every generated C translation
unit must see declarations used by its direct source dependencies.

This C context does **not** grant Titan visibility transitively and does not
expose the producer's `foreign import` alias as a member. Consumers use C-bearing
values through the producer's qualified Titan declarations. Header order,
redefinition, `#undef`, include guards, and `#pragma once` have the same effect as
in the generated C preamble.

## Binary imports and Lua

A `.so` or `.a` import remains public-only. Compiled metadata contains no source
collaboration overlay, local variable slots, local aliases, or local nominal
members. Co-residence in one physical provider, static linking, registry state,
or a matching source file elsewhere does not create source permission.

Lua sees the same public-only module and nominal member maps. Source-local
members cannot be read or written through `require`, even when they exist in the
same physical provider.

## Selecting source deliberately

Dependency lookup prefers compiled providers before source. To compile a
collaborating set from source, request its roots together (or otherwise ensure
that resolution selects source) rather than relying on a stale provider in the
search path. Initialization still follows the ordinary acyclic import graph and
its topological order.

The generic source overlay is compiler-only and is not a serialized interface
format. Titan ABI 0.22 nevertheless accompanies this feature because the
standard-library dogfood pass deliberately made most of `titan.uv` local,
changing that module's serialized public members and reconstructible public
closure prefix. Older providers must be rebuilt; no migration is performed.
