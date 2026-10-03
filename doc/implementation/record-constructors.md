# Record constructors

The [language contract](../language/records.md#calling-a-record) distinguishes
calls to a record's `new` from raw context-typed record literals. Calling a
record namespace is syntax sugar; it does not introduce a new callable type or
make namespaces first-class Titan values.

## Declaration staging and call lowering

`parser.lua` continues to synthesize an adjacent `TopLevelStatic` marked
`_record_constructor` after each record. Before nominal signatures are staged,
`checker/declarations.lua:collect_nominal_constructors` finds written record
statics named `new`. For those owners it removes the synthetic declaration,
marks the record as having a custom constructor, and leaves the written static
to ordinary declaration checking. Source declarations retain their order and
locations. A second written `new` remains an ordinary duplicate error.

The override follows ordinary static-function rules, including visibility,
generic parameters, variadic input, and zero, multiple, or flexible results.
Its result need not be the owning nominal type. The discarded constructor has
no callable body, tag, or closure slot and cannot be reached from the override.

The existing parser already accepts positional, named, and string calls.
`checker/expressions.lua` resolves the callee and, for a `Type.Record`
namespace, replaces it with the existing `VarDot(namespace, "new")` selection.
The normal member and call paths then own access checks, inference, argument
evaluation and adjustment, result demand, and named-argument normalization.
Only namespaces get this rewrite; a local value shadowing a record name keeps
its normal call behavior. Imported records, aliases, and `M.Record` use the
same resolved namespace path.

The parser attaches a final written type-argument list to the call. Record
lowering moves that list back to its owner namespace before selecting `new`,
so `Box<|integer|>(x)` means `Box<|integer|>.new(x)`. Callable-local generic
arguments still follow `.new`; the existing all-explicit-or-all-inferred rule
is unchanged.

## Raw construction and generated-only operations

`Type.Record.custom_constructor` is a boolean, separate from `new`'s signature
or visibility. A same-signature override still changes construction authority.
`generic_resolve_named_record_constructor_context` rejects a raw `ExpInitList`
when this flag is true and the nominal owner's module differs from the current
module. This also rejects source-collaboration imports; they do not confer the
defining module's raw-allocation privilege. The existing private-field rule
continues to apply independently.

Three paths must distinguish generated constructors from ordinary `new`
functions:

- `_direct_nominal_constructor` selects native field/tail allocation plans only
  for the default constructor.
- `record_constructor_parameter` maps synthesized parameters to field
  declarations only for the default constructor.
- `isconstructor` accepts a constructor call as a constant module initializer
  only for the default constructor.

Custom constructors can allocate with a context-typed literal in their own
module, which follows ordinary layout, rooting, and write-barrier codegen.

## Semantic metadata and separate providers

The optional eighth `Record(...)` constructor argument carries
`custom_constructor`, after the existing generic scope and parameter list.
The default is false. Serialization retains the existing default-record form;
overrides append the flag, inserting the empty generic positions when needed.
Equality, substitution, erasure, source-interface graphs, and persisted
declaration schemas preserve it.

The imported-record validator checks this boolean and always validates the
ordinary callable graph. Its additional generated-`new` shape requirements
(field parameters, one owning-record result, no tails or callable-local
binders) apply only when the flag is false. A custom `new` may be absent from
the public interface when private. Physical nominal layout and native calling
conventions are unchanged.

An imported raw literal records a separate `literal` usage requirement. The
provider's erased compatibility descriptor advertises that capability only
for a default-constructor record with a complete public field layout. A
replacement that adds private fields or overrides `new` rejects a literal
consumer, including when the override has the same signature. Ordinary calls
depend on `new`'s callable signature and can accept that replacement. See
[binary compatibility](binary-compatibility.md#construction-and-closed-union-proofs).

When `isconst` accepts a generated record call in a module variable initializer,
it marks that call with `_binary_constant_constructor`. Usage collection then
requires the same `literal` capability: replacing `new` with arbitrary code
would invalidate the initializer's constant-expression proof. The marker is
set by the proof itself, so calls nested inside the initializer are covered
without treating calls in a lambda body or a computed `do` initializer as
constant construction.

Code generation retains ordinary calls across a separate record provider
boundary, so replacing a generated `new` with a compatible override changes
the implementation used by an unchanged consumer. Local, source-linked, and
archive-linked generated constructors may still inline. A call with fresh
native arguments fused into the record's own allocation also retains raw
construction: those argument plans carry an ownership contract that an
ordinary call cannot supply. Such calls explicitly require the same `literal`
capability, so a replacement override is rejected before that specialized
consumer runs. The final link's existing static-dependency classification owns
the call-versus-inline choice.

Providers built before this capability was emitted need rebuilding for new
literal, constant-initializer, and fused-storage consumers. Historical consumers
represented literals as a `new` dependency and cannot distinguish a
same-signature override from an ordinary compatible replacement. This additional
semantic check does not change ABI 2 or language-server API 1.

## Lua namespace calls

`coder/generate.lua` creates a metatable with `__call` on a record's static
namespace only when `new` is public. Its generated C entry receives
`namespace, args...`, looks up the namespace's `new`, replaces stack slot 1
with that callable, and calls it with the remaining arguments and
`LUA_MULTRET`. Returning the resulting stack height preserves zero results,
multiple results, interior nils, and flexible tails. The Lua stack roots the
namespace, arguments, constructor, and results throughout; the bridge keeps no
raw stack pointers across the call. `lua_callk` and a continuation returning
the final stack height preserve ordinary Lua yielding if Lua replaces the
public `new` member with a yielding callable. Errors propagate normally.

This metatable belongs to the namespace table, separate from the nominal
instance metatable. A private `new` creates neither a public member nor a
namespace `__call`. Direct Titan calls continue to use their statically checked
native or canonical callable paths.

## Standard-library adoption

Standard-library Titan record calls use the shorthand, while C allocation
pseudo-calls retain `foreign T.new(...)`. The string library's former private
builder factory is `local function StringWriter.new()`, constructing its raw
state with a literal; `string.writer()` retains its public API.

JSON decoding already invokes reflected public `new` with values mapped by
its parameter names. It accepts custom constructors only with fixed parameters
and exactly one result of the requested record type. Other signatures return
`constructor_unavailable` before invocation; reflection itself continues to
expose each ordinary public callable.
