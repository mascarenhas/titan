# Visibility through explicit source imports

A Titan `import` exposes only the imported module's public interface by default,
regardless of whether lookup selected source, a shared provider, or a static
provider. Source resolution alone is not permission to name local declarations.

An **explicit source import** appends the marker suffix `.titan` to the name in
the import string:

```titan
local engine = import "example.engine.titan"
```

The marker requires the logical module `example.engine` to be found as source
and exposes that module's complete Titan collaboration surface through this one
written alias. It does not become part of the logical module name. There is no
fallback to a `.so` or `.a`, even when a compatible provider is present or was
selected earlier in the compilation.

The marker is removed before standard-library shorthand and canonical lookup.
Thus `import "uv.titan"` and `import "titan.uv.titan"` both explicitly source-
import logical module `titan.uv`. Likewise,
`import "foo.bar.baz.titan"` searches for folder source
`foo/bar/baz/baz.titan` and then flat source `foo/bar/baz.titan`, following the
usual source-root precedence. All checker, dependency, native-symbol, generated-
artifact, and manifest identities remain `foo.bar.baz`.

Because the terminal spelling is always interpreted as this marker, a dotted
logical module name ending in the component `titan`, such as `example.titan`, is
not allowed. The root logical module `titan` and a nonterminal component such as
`example.titan.child` remain valid. This reserves logical module keys, not a
physical multi-module provider prefix: `pkg.titan.left` and `pkg.titan.right`
may still share the derived provider `pkg.titan` at `pkg/titan.so` and
`pkg/titan.a`.

This explicit opt-in lets a group of source modules share implementation details
without publishing them to ordinary source consumers, separately compiled
consumers, or Lua. Ordinary dependencies still select compiled providers before
source. A [`titanc --test`](standard-library-test.md) invocation prefers source
across the complete requested closure, but its ordinary imports remain public-
only; a test must use the `.titan` marker when it intentionally needs locals.

## Explicit source visibility

Given an explicit source edge

```titan
local engine = import "example.engine.titan"
```

`engine` can select declarations owned by `example.engine`, including local:

* module variables, for both typed reads and writes;
* ordinary functions;
* source-defined `foreign function` declarations as exact C designators;
* records and unions;
* type aliases;
* record fields and union variants;
* generated record and variant constructors;
* methods and nominal functions.

Top-level values and types remain qualified (`engine.reset`, `engine.State`).
A local field or method is selected from a value of the owner type in the usual
way (`state.hidden`, `state:advance()`); the compiler checks that the current
module has a written explicit-source capability for that nominal owner.

Local module variables refer to the producer's canonical module state. Likewise,
reading a local function, constructor, method, or nominal function as an exact
source value returns the producer's canonical closure; each importer does not
manufacture a new copy. If the consuming sink instead requires an admitted
non-exact Function type, that later edge has the ordinary conditional
[fresh-wrapper rule](closure-adjustment-wrappers.md); it does not change which
source closure the import selected. A foreign declaration is different: it has
no closure or module-state value and decays only to an exactly compatible
[`foreign (...) -> ...` pointer](foreign-functions.md).

Local Interfaces are not supported. A local concrete method that is visible
through an explicit source import may, however, satisfy an ordinary public
Interface at that cast site. The same applies to a visible local const record
field required by an Interface; binary or transitive consumers cannot use the
hidden member.

## Visibility is direct, not transitive

Titan member permission follows only written explicit source edges. If `middle`
imports `owner.titan`, and `consumer` imports only `middle` (with or without its
own `.titan` marker), `consumer` does not acquire access to declarations local
to `owner`. It must write its own `import "owner.titan"` edge.

The same rule applies to local nominal members and aliases. A public declaration
cannot be used to launder a wholly local record or union into a transitive
capability.

Bare names are unaffected: an import never injects another module's declarations
into the importing module's lexical scope.

## Foreign declarations

An explicit-source-visible declaration may contain a C FFI type even though its
consumer did not write the corresponding `foreign import`. Each generated C
translation unit includes its own direct foreign-import headers plus the
normalized origin headers of C types for which that unit actually emits
declarations. For those ordinary values the rule remains use-driven: an unused
source dependency does not contribute a blanket header closure. Quoted origins
use the same normalized spelling in producer and consumer, so path-sensitive
declarations such as `sizeof(__FILE__)` agree.

A producer that defines `foreign function` declarations additionally generates
one source-adjacent `*.titan.h`. Every explicit source importer includes that
companion, which contains the prototypes/eligible inline definitions and the C
headers required to render them. The consumer checker processes the same
companion before checking declarations and bodies, so its macros and C probes
match final generated C. Temporary companions make this possible during
recursive checking; the compiler rewrites them to final paths and removes them
from the resolver context afterward.

Neither mechanism exposes the producer's `foreign import` alias or grants Titan
visibility transitively. A generated C header is declaration plumbing;
`alias.member` still needs a written explicit-source capability, and a binary
provider carries no companion permission. Source modules remain ordinary C
translation units compiled with the same configured compiler and flags. Import
an umbrella header directly when unrelated declarations depend on a particular
include or macro order.

## Binary imports and Lua

A `.so` or `.a` import remains public-only. Compiled metadata contains no source
collaboration overlay, local variable slots, local aliases, or local nominal
members. Co-residence in one physical provider, static linking, registry state,
or a matching source file elsewhere does not create source permission.

Lua sees the same public-only module and nominal member maps. Source-local
members cannot be read or written through `require`, even when they exist in the
same physical provider.

## Selecting source deliberately

Ordinary dependency lookup prefers compiled providers before source. Use the `.titan`
marker on every import edge that intentionally collaborates with a dependency's
locals. The marker both selects source and records the permission; merely
requesting all modules as command-line roots, using test mode's source-first
resolver, or hiding a compiled provider is not a substitute. Initialization
still follows the ordinary acyclic import graph and its topological order.

If an earlier root in the same compilation already used any compiled interface
for the module, including a nominal owner recovered through a compiled facade,
the source module's public projection must match every view that was used. The
compiler rejects an inconsistent mixture instead of leaving the earlier root
checked against stale signatures or record layouts. This normally indicates
that a compiled provider and the selected source were built from different
public APIs.

The generic source overlay is compiler-only and is not a serialized interface
format. Titan ABI 0.22 nevertheless accompanies this feature for two concrete
layout changes: the standard-library dogfood pass deliberately made most of
`titan.uv` local, changing that module's serialized public members and
reconstructible public closure prefix, and every generated module now carries
the fixed physical-provider identity slot used before source-private access.
ABI 0.23 retains those layout rules while adding source-defined foreign
collaboration and separating module, nominal owner, and member in native
callable names. ABI 0.24 retains those visibility and native-layout rules while
extending generic declaration metadata. ABI 0.25 retains the same rules while
changing the public `titan.fs` and `titan.async` signatures. ABI 0.26 retains
the visibility model while extending const and Interface metadata. The explicit
`.titan` marker changes lookup and checker permission only; because it is
stripped before logical identity and serialization, it requires no further ABI
change. A 0.25 binary remains public-only and is rejected by the 0.26 toolchain;
older providers must be rebuilt and no migration is performed.
