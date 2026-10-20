# Const values

Titan's `const` qualifier can make a binding or record field read-only, and
`const { T }` names a separate read-only Array type. These are shallow rules:
they prevent replacing the qualified storage, but do not recursively freeze
objects stored in it.

This chapter specifies the declaration forms, the one module-initialization
assignment region, Interface field snapshots, and the explicit conversion from
a mutable Array to a const Array. The ordinary declaration, record, Interface,
and container rules still apply unless this chapter says otherwise.

## Binding declarations

### Const locals

A block may declare const locals with or without the otherwise optional
`local` keyword:

```titan
const name = "Titan"
local const lower: integer, upper: integer = 1, 10
```

`const` applies to every name in the declaration list. A const-local
declaration always has an initializer expression list; `const item: T` and
`local const item: T` are syntax errors. The initializer list follows the
ordinary multiple-result and adjustment rules.

A const local cannot be assigned after its declaration, including through a
capturing lambda. Its initializer is resolved before the new names enter
scope, so const shadowing can deliberately consume an outer value:

```titan
function require_name(input: string?): string
    local name? = input
    const name = name -- reads and forces the outer string?
    return name
end
```

The inner `name` is a plain `string` and cannot be reassigned.

### Mutable locals without an initializer

An ordinary mutable `local` may omit its expression list:

```titan
local pending: string?
local dynamic: value
```

Every name must have an explicit type that actually admits a missing nil
representation: `nil`, `value`, an Option, or one of Titan's existing nullable
pointer domains. The compiler supplies one typed nil per declaration.

This rule is intentionally narrower than ordinary assignment adjustment.
Truthiness does not make `boolean` nil-bearing, and a numeric or nominal type
cannot be left uninitialized:

```text
local ready: boolean  -- rejected: boolean does not admit missing nil
local count: integer  -- rejected
local inferred        -- rejected: there is no initializer to infer from
```

Use the omitted form when a mutable optional slot will be filled later, then
shadow it with a const local when a required value is needed.

### Const module variables

At module level the form is:

```text
[local] const name [: type] [= expression]
```

An initialized const module variable is read-only after its declaration:

```titan
const version = "0.6.0"
local const retries: integer = 3
```

An initializer-less const module variable must have an explicit type from the
same missing-nil domain as an initializer-less mutable local. It starts as the
corresponding nil/NULL representation:

```titan
const configured: string?

do
    configured = "ready"
end
```

Only code executing directly in that variable's owning root module
initializer may assign it. Nested blocks inside that initializer retain the
permission; a nested function or lambda does not. Another module's initializer
does not gain permission through an import. The owner initializer may assign
the slot conditionally or more than once—this is an initialization region,
not flow-sensitive single assignment. When the root initializer finishes, the
variable is read-only for the rest of that Lua-state module instance.

An initializer-less const is not a definite-assignment promise. Code can still
observe nil when the initializer leaves it unset, so use an Option or another
nil-bearing type honestly.

Public const module variables are readable by importers and Lua but cannot be
written by either. Local const module variables follow the normal explicit-
source-import visibility rules.

## Const record fields

A record field accepts `const` after an optional `local`:

```titan
record Request
    const method: string
    local const token: string?
    metadata: {string: value}
end
```

The complete form is `[local] const name: T`; an optional field writes
`[local] const name: T?`. There is no optional field-name shorthand. Const fields are filled by `Record.new`, a
named call, or a context-typed record constructor. They cannot be replaced by
a later Titan assignment or Lua field write. A mutable record field remains
writable as before.

Field constness is shallow. In the example above, making `metadata` const would
prevent `request.metadata = another_map`, but would not prevent
`request.metadata["trace"] = true`. Use `const { T }` when the Array container
itself must be read-only.

A const field containing an embedded C aggregate or fixed C array follows the
same shallow rule. Reading it projects a borrowed pointer: the field cannot be
replaced, but the pointed-to contents may be mutated unless the declared C type
itself imposes `const`. A const raw pointer/array-view field can also receive a
fresh buffer in the record's allocation. See [Native storage in records and
unions](nominal-storage.md).

The field's visibility is independent of constness. A local const field is
still visible only to its defining source module, and an exported record with a
local field keeps the existing constructor restrictions.

## Interface fields

An Interface body may contain fields, methods, or both:

```titan
interface NamedReader
    name: string
    function read(): string?
end
```

Interface fields use `name: T` and are implicitly const. As with record
fields, write `name: T?` when the field type is an Option. Field and method names share one namespace, so a duplicate or
field/method collision is rejected in source order. The body must contain at
least one member.

A record satisfies an Interface field only when it has a visible, same-name
const field whose type has the ordinary automatic assignment adjustment to the
Interface field type. A mutable field does not satisfy a read-only Interface
field: later replacement would make the result depend on an aliasing policy the
Interface did not promise. A union can satisfy a method-only Interface but
cannot satisfy an Interface that contains a field.

```titan
interface Labelled
    label: string
end

record Item
    const label: string
end

function view(item: Item): Labelled
    return item
end
```

The conversion snapshots every Interface field after applying its checked
adjustment. Later activity observes the wrapper's snapshot, not another read
from the concrete record slot. The snapshot is shallow: if a const record field
contains a mutable Map, Array, record, or other reference value, the snapshot
retains that same object and mutations through the object's own mutable API
remain visible.

Interface field reads use ordinary dot syntax in Titan and Lua. Every write to
an Interface wrapper is rejected. Method dispatch and wrapper identity retain
the rules in [Interfaces](interfaces.md).

## Const Arrays

### Type spelling and identity

`const { T }` is an Array whose container cannot be mutated:

```titan
const primes: const { integer } = {2, 3, 5, 7}
```

The `const` appears before the braces. This keeps it unambiguous with the C FFI
pointer qualifier:

```text
{ const *c.Item }       mutable Array of pointers to const C Item
const { *c.Item }       const Array of mutable C Item pointers
const { const *c.Item } const Array of pointers to const C Item
```

`{T}` and `const { T }` are distinct invariant types and have distinct
run-time tags. Const does not apply to Maps; `{K: V}` remains the one Map type.

A const Array supports indexing, deterministic `#` length, holes, identity,
iteration, nested storage, and the same strict typed element reads as a mutable
Array. Titan rejects every indexed assignment. At the Lua boundary its
canonical userdata proxy has `__index` and `__len` but no `__newindex`, so a
Lua assignment and a mutating `table.*` operation fail without changing the
Array. Raw table operations already reject either Array proxy because it is
userdata.

### Constructors and shallow conversion

A positional constructor in a `const { T }` target context constructs a const
Array directly:

```titan
function small_primes(): const { integer }
    return {2, 3, 5, 7}
end
```

There is no implicit conversion between mutable and const Arrays. The written
cast is the sole cross-qualifier operation:

```titan
function snapshot(items: {string}): const { string }
    return items as const { string }
end
```

The cast makes a shallow copy. It preserves logical length and holes and
copies each present element value without recursively freezing it. It is
allowed only when the source and target element types are equal or gradually
consistent; a shallow freeze cannot perform a numeric, nominal, or other
per-element conversion. A later typed read through the target element view
performs the ordinary strict gradual guard.

Const-to-mutable conversion is rejected, including after a `value` round trip.
The two Array qualifiers have different exact tags, and gradual consistency
exists only within one qualifier: `const { value }` is consistent with
`const { integer }`, while neither is consistent with mutable `{value}` or
`{integer}`.

For an admitted statically known mutable-to-const pair,
`items is const { T }` evaluates `items` once and returns true without
copying, freezing, or allocating. The matching `as` performs the conversion.
A test whose source is `value` instead inspects the exact qualified run-time
tag. Direct mutable/const Array comparison is rejected; both sides can be
explicitly viewed as `value` when ordinary boxed identity comparison is
intended.

### Maybe-const Arrays

`const? { T }` names a read-only view type that can accept both mutable `{ T }`
and const `const { T }` Arrays:

```titan
function sum(items: const? { integer }): integer
    local total = 0
    for i = 1, #items do
        total = total + (items[i] or 0)
    end
    return total
end
```

`const? { T }` permits indexed reads and `#` length, but forbids indexed element
writes (`xs[i] = v` is a compile-time error).

Public fields, function parameters, and results retain `const?` when their
module is imported from source, a shared provider, or a static archive. Passing
an Array through this view preserves the original mutable or const Array;
the view does not freeze or copy it.

#### Assignment and Option propagation

- Mutable `{ T }`, const `const { T }`, and maybe-const `const? { T }` can all
  be assigned to `const? { T }` (provided the element types are equal or
  gradually consistent).
- Option versions propagate consistently: `({ T })?` and `(const { T })?` can
  both be assigned to `(const? { T })?`.
- A `const? { T }` source cannot be implicitly assigned to a mutable `{ T }` or
  `const { T }` target.

#### Explicit casts

A `const? { T }` value can be explicitly cast using `as`:
- `xs as { T }`: succeeds at runtime if `xs` is a mutable array proxy; raises a
  runtime error if `xs` is a const array.
- `xs as const { T }`: succeeds at runtime if `xs` is a const array proxy; raises
  a runtime error if `xs` is a mutable array.
- `xs is { T }` and `xs is const { T }` perform non-allocating runtime type
  guards.

### Copy elision and linear returns

The language semantics are always the shallow copy above. The compiler may
freeze the original proxy in place only when a conservative linear-use proof
shows that the allocation has not escaped before the cast and that neither the
source binding nor any mutable alias is used afterward.

1. **Local builder pattern:** Starts with one local initialized from a fresh
   mutable Array `{}`. Structured control flow and loops may query `#` and read
   or write elements. If the local does not escape before being cast or returned
   to a `const` target, the compiler emits in-place `titan_array_freeze`. The
   cast must be the whole initializer of a one-name local declaration or the
   whole returned expression, in the builder's own block. Later statements may
   consume that frozen local (`local frozen = items as const { T }` followed by
   `consume(frozen)`). A cast nested inside another expression, such as
   `consume(items as const { T })`, or a returned cast that the function result
   then converts to `value`, keeps the copy.
2. **Linear function returns:** When all return paths of a function return a
   freshly constructed array, an unaliased local builder array, or the result
   of an earlier linear call, the function's
   return type is marked linear. Directly assigning or casting the call result to
   `const { T }` (e.g. `local res: const { B } = map(xs, f)`) freezes the
   returned array in place without copying. Only a callee that precedes the
   caller in the same module's logical declaration order carries this proof
   when the caller is checked; a written cast of any other call result copies.

Code must not depend on whether this optimization fires. If both the mutable
source and const result could still be observed, the proof is not valid and
the compiler must copy.

## C `const` is separate

Titan binding constness and the C FFI pointee qualifier solve different
problems. A const local containing inline C aggregate or fixed-array storage
cannot mutate that storage, take a mutable address of it, or use a mutable
automatic-decay path. The rule remains shallow across a pointer or `owned`
value: a const binding cannot be replaced, but an independently mutable
pointee is not frozen. A nominal embedded-field or union-part projection is
such a borrowed pointer; assigning that projection to a const local prevents
replacing the pointer, not writing through it. See [C FFI declarations and expressions](c-ffi-expressions.md).

## ABI boundary

Const module/field metadata, Interface fields and wrapper snapshots, and
qualified Array tags are part of the compiled-module ABI. The compiler rejects a mismatched
provider before decoding its descriptor or exchanging values; there is no
in-place compatibility adapter.
