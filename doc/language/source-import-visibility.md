# Visibility through source imports

A Titan `import` can resolve to source in the current compilation or to a
compiled `.so`/`.a` provider. The two cases intentionally expose different
interfaces.

A **direct source import** exposes the imported module's complete Titan
collaboration surface through the written import alias. A binary import exposes
only its ordinary public interface. This lets a group of source modules share
implementation details without publishing those details to separately compiled
consumers or to Lua.

Ordinary dependencies select compiled providers before source. A
[`titanc --test`](standard-library-test.md) invocation is the deliberate
exception: it prefers source across the complete requested closure so test
modules can collaborate directly with local implementation declarations, then
falls back to compiled providers on a clean source miss.

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
did not write the corresponding `foreign import`. Each generated C translation
unit includes its own direct foreign-import headers plus the normalized origin
headers of C types for which that unit actually emits declarations. An unused
source dependency does not contribute a blanket or transitive header closure.
Quoted origins use the same normalized spelling in producer and consumer, so
path-sensitive declarations such as `sizeof(__FILE__)` agree.

This does **not** expose the producer's `foreign import` alias or grant Titan
visibility transitively. Source modules remain ordinary C translation units
compiled with the same configured compiler and flags. Headers are expected to
be self-contained and compatible under ordinary C rules; Titan does not compare
macro environments, layouts, attributes, or preprocessing histories between
translation units. Import an umbrella header directly when declarations depend
on a particular include or macro order.

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
format. Titan ABI 0.22 nevertheless accompanies this feature for two concrete
layout changes: the standard-library dogfood pass deliberately made most of
`titan.uv` local, changing that module's serialized public members and
reconstructible public closure prefix, and every generated module now carries
the fixed physical-provider identity slot used before source-private access.
Older providers must be rebuilt; no migration is performed.
