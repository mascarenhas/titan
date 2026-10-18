# The type system

Every variable, parameter and expression in Titan has a static type,
determined at compile time. The compiler rejects programs that violate the
typing rules with **compile-time errors** of the form
`file:line:col: type error: <message>`. Where Titan deliberately admits
dynamism — the `value` type, [option types](option-types.md), and every
value arriving from Lua — the compiler records the corresponding run-time
guard or boundary conversion. A failing partial operation raises an ordinary
Lua error (see [Error handling](error-handling.md)).

## The type language

| Type | Written as | Described in |
| --- | --- | --- |
| nil | `nil` | below |
| booleans | `boolean` | below |
| integers | `integer` | below |
| floats | `float` | below |
| strings | `string` | below |
| the dynamic type | `value` | [in depth below](#the-value-type-in-depth) |
| mutable arrays | `{ t }` | [Arrays and maps](arrays-maps.md) |
| const arrays | `const { t }` | [Const values](const-values.md#const-arrays) |
| maybe-const arrays | `const? { t }` | [Const values](const-values.md#maybe-const-arrays) |
| maps | `{ k : v }` | [Arrays and maps](arrays-maps.md) |
| records | `Point`, `mod.Point` | [Records](records.md) |
| unions | `Message`, `mod.Message` | [Unions](unions.md) |
| interfaces | `Reader`, `mod.Reader` | [Interfaces](interfaces.md) |
| aliases | `type Name = t` | [Type aliases](type-aliases.md) |
| owned C storage | `owned *T`, `owned T[]` | [The C FFI](ffi.md) |
| option types | `t?` | [Option types](option-types.md) |
| function types | `function (t1, t2): (t3)` | below |
| foreign types | `foreign int`, `foreign *FILE` | [The C FFI](ffi.md) |

### Basic types

`nil`, `boolean`, `integer`, `float` and `string` are exactly Lua's values
of those types: integers and floats are Lua's two number subtypes (by
default 64-bit integers and double-precision floats), and strings are
Lua's immutable byte strings. Unlike Lua, Titan keeps `integer` and
`float` apart in the type system — a variable is one or the other — but
the implicit numeric coercions described below keep mixed arithmetic
working the way a Lua programmer expects.

```titan
local n: integer = 10
local x: float = 3.5
local s: string = "hello"
local b: boolean = true
```

### Arrays and maps

An Array type is written `{ t }` for a mutable container or `const { t }` for
a read-only container (including nested compound types); a Map type is written
`{ k : v }`. Arrays are dense-capacity containers represented at the Lua
boundary by canonical Titan userdata proxies, while Maps are ordinary Lua
tables. Both can cross the Lua boundary, but an Array requires the exact
qualified proxy created by Titan rather than an arbitrary Lua table; the full
account is in
[Arrays and maps](arrays-maps.md).

The type syntax does not promise that every FFI representation supports every
container operation. A typed element/value read is accepted only when Titan
has a sound guard for the optional result type. In particular, raw C-pointer
Array and Map reads are compile-time errors. Constructing an Array with a raw
C-pointer element is also rejected because the Array cannot provide its
required sound Lua writer; a Map may store a statically typed raw pointer, but
that typed value view cannot be indexed.

```titan
function sum(xs: {float}): float
    local s: float = 0.0
    for i = 1, #xs do
        s = s + xs[i]
    end
    return s
end

function count(m: {string: integer}, k: string): integer
    return m[k] or 0
end
```

The typing facts that belong in this chapter:

* **Reading an element produces an option.** If `xs` is `{float}`, the
  expression `xs[i]` has type `float?`, because the element may be
  absent; likewise `m[k]` has type `v?` for a `{k : v}` map. The implicit
  coercions below make this mostly invisible — `s = s + xs[i]` inserts a
  run-time nil check — but the option is real; see
  [Option types](option-types.md).
* **Element and value types are never options.** Writing `{integer?}`
  silently denotes the same type as `{integer}`, and similarly for map
  value types — reads already produce options, and writing `nil` into an
  element is how you delete it.
* **Map keys cannot be nil-able.** A `nil` key type is the compile-time
  error `type of map key cannot be nil`; an option key type,
  `type of map key cannot be option type`.

### Records, unions, and Interfaces

Record, union, and Interface types are declared at the top level of a module
and are the *nominal* types in Titan — see
[Type equality](#type-equality) below, [Records](records.md),
[Unions](unions.md), and [Interfaces](interfaces.md). A nominal type's full
name is qualified by its module: the `Point` declared in module `geom` is the type
`geom.Point`, written `Point` inside its own module and `geom.Point`
elsewhere (for an `import "geom"` bound to `geom`).

```titan
record Point
    x: float
    y: float
end
```

An existing type can be given a transparent compile-time name with a
[type alias](type-aliases.md). In particular, `type P = Point` still denotes
this exact nominal record; it does not declare a second record type. The same
is true for a union or Interface alias. A union variant is not itself a type:
`Message.write` is illegal in an annotation, alias, `as`, or `is`; use
`Message` and inspect it with `case`.

### Option types

Any type can be suffixed with `?` to make an *option type*: `integer?`,
`string?`, `Point?`, `{integer}?`. A `t?` holds either a `t` or `nil`.
Options give "this value or nil" — the single most common dynamic pattern
in Lua — a checked, first-class shape: the compiler converts between `t`
and `t?` implicitly, inserting a run-time nil check in the unwrapping
direction, so nils fail fast where a real value was assumed instead of
propagating. Options never nest (there is no `t??`), and `value?` is the
same type as `value` — a `value` can already hold nil. The full story
(defaulting with `or`, equality, conditions, the Lua boundary) is in the
[Option types](option-types.md) chapter.

### Function types

A function type starts with `function`, followed by a parenthesized parameter
type list and an optional return annotation: `function (A, B): C`. Parameter
parentheses are required even for one parameter. A single return type may be
written directly; multiple or flexible results use a parenthesized list.

- `function (A, B): C` takes two parameters and returns one `C`.
- `function (): (A, B)` takes no parameters and returns two values.
- `function (A): ()`, or `function (A)`, returns no values.
- `function (A): nil` returns one nil value.
- `function (A, ...: B): (C, ...: D)` has independent input and result tails.

Function types nest directly. `function (function (integer): integer): integer`
takes a function, and `function (): function (integer): integer` returns one.
An opening parenthesis in type position groups a type or begins a result list;
it never begins an arrow-style function type.

A colon immediately after a function type's parameter list belongs to that
function's return annotation. Consequently, `{function (): T}` is an Array of
functions. To use a zero-return function as a Map key, group it:
`{(function ()): T}`.

Function values can be named functions, record constructors, anonymous
functions, or bound method references. They can be stored, passed, returned,
and called. See [Functions](functions.md), [closures](closures.md), and
[Expressions](expressions.md).

### Parenthesized types

Parentheses can group any single type: `(T)` and `T` denote the same type,
and extra layers such as `((T))` are also allowed. Grouping works in ordinary
annotations, function parameters and results, generic type arguments, casts,
type tests, and C pointer or owned payloads. For example, `({string: T})?`
makes the entire Map optional, and `foreign *(int)` is the same C pointer type as
`foreign *int`. Nested pointers require grouping: `foreign *(*int)`. Parentheses do not change the restrictions on the enclosed type.

The `?` suffix applies to the complete preceding group. These function types
therefore have different meanings:

| Type | Meaning |
| --- | --- |
| `function (T): (U?)` | A function taking `T` and returning `U` or nil |
| `(function (T): (U))?` | A function taking `T` and returning `U`, or nil in place of the function |
| `function (function (T): (U)): (V)` | A function taking a `function (T): U` function and returning `V` |

A group contains exactly one type. `(T, U)` is a parameter or result list,
not a tuple type, and `()` is an empty parameter or result list. Such lists
remain valid in `function (): (T, U)` and function result annotations, but cannot
stand alone as a variable's type or receive an outer `?`. A flexible result
list such as `(...: T)` follows the same rule. To make the function optional,
group the whole function type, as in `(function (): (T, U))?`.

### Foreign types

Titan and C types have separate namespaces. In an ordinary annotation, cast,
type test, or Titan type constructor, prefix a raw C type with `foreign`:
`foreign int`, `foreign unsigned long`, `foreign float`, or `foreign *FILE`.
Names inside that foreign type are unqualified C names; `ffi.` belongs to
expressions such as `ffi.fclose(handle)`, not to type spellings.

`foreign import` supplies header declarations. `foreign type Name = T` adds a
module-local C typedef and makes it available through explicit source-import
headers. These typedefs are distinct from transparent Titan `type` aliases.
Public compiled interfaces may contain recursively exportable C type graphs,
including eligible named header typedefs, structs/unions, and fixed arrays—not
only header-free primitives and pointer graphs. Every component must satisfy
the C exportability rules, and consumers must make the original compatible
named declarations visible; an ordinary Titan import does not inherit C headers.
An ordinary `foreign function` declaration is public independently of its
signature, but that signature must still be exportable; unsupported graphs
are rejected rather than silently made local. See [the C FFI](ffi.md) and
[foreign-function exports](foreign-functions.md#public-exports-and-source-visibility).

Ownership is a Titan type constructor: write `owned *T`, `owned T[]`, or
`owned Alias` when a foreign alias resolves to a pointer or array. Do not prefix
`owned` with `foreign`. Ordinary Titan aliases may name owned types, and Titan
Arrays, Maps, Options, and function types can contain foreign or owned types
subject to their representation and export rules. A raw foreign type cannot
contain a Titan type. See [The C FFI](ffi.md) for the complete boundary.

## Type equality

Titan's types are *structural* except for records, unions, and Interfaces, which are
*nominal*:

* Two basic types are equal only if they are the same type.
* two Arrays are equal types exactly when their qualifiers match and their
  element types are equal; likewise maps
  compare key and value types pointwise, and function types compare
  fixed parameter and return lists pointwise, including the presence and
  element type of any input-variadic or flexible-result tail.
* `t1?` equals `t2?` exactly when the base types are equal.
* Two record, union, or Interface types are equal only if they are *the same declaration* —
  their fully-qualified names match. Field structure is irrelevant:

```titan
record PointF
    x: float
    y: float
end

record PointV
    x: value
    y: value
end
```

`PointF` and `PointV` are unrelated types, even though they have the same
field names — and they would still be unrelated if the field types
matched exactly. A `PointF` can never be used where a `PointV` is
expected, and there is no cast between them.

Interfaces are nominal in the same sense: two Interface declarations with
identical method signatures are still distinct and neither converts to the
other. Structural method matching is used only to decide whether a concrete
record or union can be wrapped as one particular Interface; it is not
Interface-to-Interface structural equality. See [Interfaces](interfaces.md).

Some constructs demand equality directly: relational comparisons
(`<`, `<=`, `>`, `>=`) require two numbers (any `integer`/`float` mix —
compared by mathematical value, with no promotion) or two strings, and
the `or` defaulting rule for options (`x or d` where `x: t?`) requires
`d` to have exactly the base type `t`.

## Relations and boundaries: no subtyping

Titan does not need a subtyping relation. Even an apparently widening use such
as `T` in a `T?` context is an automatic conversion: the two types can have
different representations, and the conversion does not automatically lift
through an Array, Map, or Function. In particular:

```text
integer -> float                 direct coercion
integer -> integer?              direct coercion
{integer} -> {float}             rejected
function (): integer -> function (): float    rejected
function (): integer -> function (): integer? rejected
```

The compiler instead keeps several deliberately separate relations and
operations:

* **consistent** is the symmetric, non-transitive relation of gradual typing.
  Equal types are consistent. A guardable type is consistent with `value`,
  and consistency descends pointwise through same-qualified Arrays, Maps, Options, and
  aligned Function components. Records, unions, and Interfaces remain nominal. For
  example, `{integer}` is consistent with `{value}`, and `{value}` with
  `{float}`, but `{integer}` is not consistent with `{float}`. This is the
  intended non-transitivity; the compiler never searches for a path through
  an intermediate type. Function consistency is likewise symmetric: it asks
  whether either direction can align the two shapes, but does not itself
  authorize a directional assignment.
* **coercible** means that one named, direct automatic conversion plan exists
  from the source type to the target type. Numeric conversion, Option
  introduction/force, satisfying record/union-to-Interface wrapper
  construction, and the enumerated FFI conversions are coercions.
  Coercions are directional and do not recurse generically through Arrays,
  Maps, Functions, or nominal fields.
* A **gradual view** observes the same compound value under a consistent
  static shape. It performs no element conversion when the view is made.
  Every later typed Array or Map read establishes the requested type with a
  strict guard before Titan uses the value. An Option has no mutable backing:
  when an `A?` is viewed as a consistent `B?`, nil passes and a present payload
  is guarded immediately as `B`.
* **callable adjustment** is Titan's directional function-shape operation:
  it records fixed-position alignment, ignored values, nil-filled argument and
  eligible missing-result positions, input/output tails, and flexible
  projection. Aligned components may use consistency and nested callable
  adjustment, but never ordinary numeric, Option, C, or Interface-wrapper
  coercions. A finite non-exact edge conditionally realizes a fresh
  target-tagged closure; its checker-recorded actions still govern the generic
  fallback when the run-time value is ineligible.
* **dynamic coercion** is the target-directed conversion used at an explicitly
  dynamic boundary: a written `value as/is T`, a genuine Lua-to-Titan sink,
  or a result entering Titan from a non-Titan Lua callable.
* **written-castable** means that the programmer explicitly requested one of
  the conversions or checks admitted by `as`/`is`. Written casts include the
  dynamic operation from `value` and a few explicitly unsafe FFI operations.
* **comparable** is the symmetric policy used by `==` and `~=`. It is not
  inferred from directional assignment or coercibility.
* A type is **guardable** (or **reifiable**) when the requested run-time type
  can actually be established, or a normal error can be raised before a value
  is used at that type. Being representable inside a Lua `TValue` is not by
  itself sufficient.

Transparent Titan aliases and C typedef chains are normalized before any of
these questions are asked. Alias transparency is therefore identity, not a
transitive relation edge.

### Normative boundary matrix

This is the canonical boundary policy for the language. The Array, Function,
Option, Lua-interoperation, flexible-return, variadic, and FFI chapters refer
back to this matrix rather than defining competing conversion rules.

| Context or operation | Rule | What happens at run time |
| --- | --- | --- |
| Ordinary typed Titan declaration, assignment, argument, return, or constructor slot | Exact identity, one direct outer coercion, a gradual view, or a directional callable adjustment must exist. Ordinary coercions never lift through an Array, Map, Function, or nominal member. | The checker-selected direct conversion is performed; a same-representation Array/Map gradual view preserves the object. An exact Function edge preserves its source closure; a non-exact one follows the conditional wrapper row below. |
| Written mutable `{S}` `as const { T }` | The sole cross-Array-qualifier conversion; `S` and `T` must be equal or gradually consistent. It is never an implicit assignment adjustment. | Make a shallow const copy preserving holes, length, and element identities. A sound linear last-use proof may freeze in place only when no mutable source or alias can be observed afterward. |
| Statically known non-exact Function `A -> B` adjustment (implicit or written `as`) | One checker-frozen directional `CallablePlan`, including only its named argument/result/tail actions and strict component operations. | Evaluate the operand once. An exact branded Titan `A` closure with upvalue room becomes a fresh target-`B` wrapper; other values stay unchanged for generic dispatch. No cache or equality unwrapping is used. |
| Implicit `value -> T` in a typed Titan context | Strict gradual projection; `T` must be guardable. This is not the broad dynamic coercion used by written casts or Lua. | The exact tag, shape, or nominal identity required for `T` is checked, subject to the compiler-witnessed Interface row below. No integral-float narrowing, integer-to-float conversion, truthiness, Option introduction/force, or pointer assertion is added by the guard. A Function target preserves the boxed value and creates no static adjustment wrapper. |
| Typed Titan Array element or Map value read | Strict target guard, regardless of which static view was used to write the slot or whether a Map value came from a raw entry, Lua, or `__index`. The checker rejects a read whose optional result type is not guardable. | An accepted read either produces the requested value or raises before Titan uses it. Array reads never invoke the Array's Lua writer. Map reads do not track write provenance, and an `__index` result receives the same strict guard, including the named Interface witness rule, rather than general dynamic conversion. |
| Written `v as T` / `v is T` with `v: value` | Shared dynamic coercion, except for the explicitly unsafe raw-C-pointer rule below. | `as` converts or raises; `is` tests acceptance without returning the converted value or raising for a mismatch. Both evaluate `v` once. A Function target remains unwrapped and defers callability. |
| Genuine Lua function argument, mutable exported module-variable write, mutable public record-field write, non-nil mutable-Array-element write, or result from a non-Titan Lua callable entering Titan | The same dynamic coercion as the preceding row. | Equal target types accept, reject, and convert the same values at all of these boundaries. Const storage rejects the write before conversion. |
| Lua writes `nil` to a mutable Array proxy | Deletion is recognized before element conversion. | The position is removed; the writer is not called, and an out-of-capacity deletion does not allocate. A const Array has no write path. |
| Array passes through `value`, Lua, an import, a return, a nested box, or another same-qualified consistent static view | Preserve the canonical proxy, backing, qualified tag, and (for mutable Arrays) construction-time writer. | No target-view writer is synthesized, compared, or installed. A mutable writer describes future genuine-Lua writes, not the current contents; a const proxy has no writer. |
| Exact native Titan function call | Exact function tag and static type. | Call the native entry directly; for a realized wrapper this is its target adapter. No Lua-stack boundary conversion occurs. |
| Branded Titan call after an exact-tag mismatch (dynamic Function view or wrapper-ineligible/later non-exact view) | Strict Titan-generic entry selected through the function's brand and trailer. | Ordinary closures use their declaration strict entry; wrappers use their consumer-local target relay and adapter. Arguments and observed results use strict gradual actions and the static demand. |
| Genuine Lua call of a Titan function or realized wrapper | The closure's coercive Lua entry. | An ordinary closure uses its source contract. A wrapper copies `source->f`, preserving whatever Lua surface its immediate source value already carries—ultimately the original declaration's—rather than synthesizing target `B`'s entry. |
| Titan call of a non-Titan Lua callable | Ordinary Lua call, followed by the dynamic boundary for results entering Titan. | Callability follows Lua, including `__call`; requested result types use dynamic coercion. |
| `value as/is` a raw C pointer | Written, explicitly unsafe pointer assertion only. Implicit gradual projection, typed container reads, callable adjustment, and non-Titan Lua-result conversion to a raw pointer are rejected. | The written operation may accept the lightuserdata/nil representation, but cannot prove the pointee type. See [the FFI policy](ffi.md#casts-and-coercions). |
| Interface target | A statically known satisfying record/union-to-Interface edge constructs a fresh wrapper, snapshots every required field, and causes its generated module to advertise that pair at initialization. A union cannot satisfy a field-bearing Interface. Strict and dynamic observation accept an existing exact wrapper or bare full userdata whose metatable has a non-nil compiler-witnessed entry under the target Interface metatable (or nil for an option). | A witnessed entry is called to construct a fresh wrapper and its field snapshots; `is` tests only entry presence. No structural member search occurs at run time, and ordinary wrapper construction still does not lift through containers or callable components. See [Interfaces](interfaces.md). |

For every row marked **dynamic coercion**, the target rules are the same:

* `integer` accepts a Lua integer or an exactly integral, in-range float and
  produces an integer; `float` accepts either numeric representation and
  produces a float.
* `boolean` applies Lua truthiness, so `value is boolean` is total.
* `string`, records, unions, and owned C userdata require their exact run-time
  category or nominal metatable. An Interface target first accepts its exact
  wrapper, then may raw-discover a compiler-witnessed wrapper entry on a bare
  full userdata's metatable. This is registered nominal evidence, not a
  structural member search.
* an Array target validates the exact mutable or const canonical Titan proxy
  selected by the target qualifier; a Map target validates a table. Neither
  operation walks contents, and later typed reads remain strict.
* a Function target preserves the boxed value and defers callability and
  signature enforcement until the call.
* an Option target accepts nil first and otherwise recursively applies the
  dynamic rule for its base. Thus `value as boolean?` preserves nil and
  truthiness-converts every present value, and `value is boolean?` is total.
* `value` and a raw C `TValue` copy the whole dynamic slot. Other supported C
  targets follow the explicit classifications in [the FFI](ffi.md); a raw C
  pointer is the written-only exception in the matrix.

Consistency is symmetric but does not by itself authorize assignment.
Callable adjustment and direct coercion are directional but are not subtyping.
Comparison has its own symmetric rules. Keeping these facts separate is what
prevents a valid scalar conversion from becoming an unchecked conversion of
every element or function result.

## Implicit coercions

Distinct from consistency, gradual views, and callable adjustment, a
*coercion* is one direct conversion plan the compiler
inserts for you. Some coercions always succeed (they are pure conversions
or boxing); others compile into a single run-time check that raises an
error shaped like
`file:line:col: type error, expected <type> but found <type>` (or, for
float-to-integer narrowing,
`... number '<n>' has no integer representation` — on some code paths
prefixed only `type error at line <line>`, with no file or column) when
the value does not conform.

### The direct coercion table

| From | To | Can fail at run time? |
| --- | --- | --- |
| `integer` | `float` | no |
| `float` | `integer` | yes — error if the float has no exact integer representation (`2.0` is fine, `2.5` raises) |
| any non-C Titan type except `boolean` and `value` | `boolean` | no — `nil` and `false` become `false`, everything else `true` |
| `t` | `t?` | no |
| `t?` | `t` | yes — error `expected t but found nil` if the value is absent |
| `nil` | `t?` | no |
| `s?` | `t?`, for an ordinary non-Interface base plan | whenever `s` coerces to `t`: `nil` passes straight through, and a present value is converted from `s` to `t` and re-wrapped — so e.g. `integer? → float?` works and is nil-preserving (a narrowing conversion can still raise on a present value) |
| `s` | `t?`, for an ordinary non-Interface base plan | as for `s` to `t` (convert, then wrap) |
| `s?` | `t`, for ordinary inter-coercible non-Interface bases | yes — nil check, then convert (in practice the numeric pairs: `integer? → float`, `float? → integer`; an option over a non-coercible base, like `boolean? → integer`, is a clean compile-time type error) |
| satisfying record or union `R` | Interface `I` | no — constructs a fresh `I` wrapper around the concrete value; satisfaction is checked statically at the conversion site |
| satisfying record or union `R` | Interface `I?` | no — constructs a fresh `I` wrapper, then makes it present |
| satisfying record or union `R?` | Interface `I` | yes — force non-nil, then construct a fresh `I` wrapper |
| satisfying record or union `R?` | Interface `I?` | no — nil passes through; a present concrete value receives a fresh `I` wrapper |
| Interface `I` | Interface `I?` | no — ordinary Option introduction with no new Interface wrapper |
| Interface `I?` | Interface `I` | yes — ordinary checked Option force |
| `integer` or `float` | `string` | no — **only** as an operand of `..`; integral floats format with a `.0` suffix exactly like Lua's `tostring` |
| C integer | `integer` | yes — values outside the target `lua_Integer` range are rejected |
| `integer` | C integer | yes — values outside the target C interval are rejected; C `_Bool` accepts only 0 and 1 |
| C float | `float` | when the target profile cannot prove a same-or-wider conversion — narrowing rejects non-finite or out-of-range values, while rounding and underflow are allowed |
| `float` or `integer` | C float | when the target profile cannot prove the conversion's range — checked floating narrowing rejects non-finite or out-of-range values |
| C pointer | `boolean` | no — null is false, non-null is true |
| owned C userdata | `boolean` | no — an owned object is true |
| `nil` | C pointer | no — becomes `NULL` |
| C array or counted owned C array | compatible C pointer | no |
| non-function C pointer | `void *` | no |
| non-pointer C object expression | compatible `const *T` or `const void *` | no (FFI calls; materializes the address for the call) |
| mutable non-pointer C local or formal | compatible `*T` or `void *` | no (FFI calls; C may write through the pointer) |
| `string` | C `char *` or `void *` | no (FFI only) |
| C integer or C float | `value` | yes when the exact C value does not fit its `lua_Integer` or `lua_Number` carrier |
| ordinary C pointer, C array-as-pointer, or owned C userdata | `value` | no — ordinary pointers become lightuserdata; owned objects stay full userdata |
| Lua-internal `Udata *` | `value` | no — non-NULL becomes that same full userdata; NULL becomes nil |
| `value` | Lua-internal `Udata *` | yes — accepts full userdata or nil, not lightuserdata |
| C `TValue` | `value` | no |
| `value` | C `TValue` | no |

Notes on the entries a Lua programmer might not expect:

* **`value` uses gradual injection/projection, not this table.** Converting
  an ordinary non-C Titan value with a `TValue` representation to `value` is a
  total gradual injection. C scalars instead use the checked carrier row
  above, and C aggregates/function pointers have no such representation.
  Implicitly projecting `value` to `T` uses the strict guard in the
  [normative boundary matrix](#normative-boundary-matrix). A written
  `value as/is T` deliberately uses the broader dynamic rule instead.

* **Most statically known Titan values coerce to `boolean`.** Assigning such a
  value to a boolean-typed variable or parameter gives you its truthiness —
  Lua's rule, where only `nil` and `false` are false. The same coercion is what
  makes `return a and b` legal in a function returning `boolean` even when
  `a` and `b` are integers. A dynamic `value` is deliberately different:
  implicit projection requires an actual boolean tag, while written `as/is`
  and genuine-Lua boundaries request truthiness conversion.
* **Numbers become strings only in concatenation.** `"x = " .. 3.0`
  produces `"x = 3.0"`, but there is no implicit number-to-string
  coercion anywhere else: `local s: string = 3` is the compile-time error
  `types in declaration of local variable s do not match, expected string
  but found integer`. There is no explicit cast either — `3 as string` is
  also rejected — so concatenating with the empty string (`"" .. n`) is
  the idiom for converting a number to a string.
* **The named Option rules compose with direct coercions.** Coercing `arr[i]` (an
  `integer?`) to `float` first inserts the nil check, then the numeric
  conversion. Coercions targeting `boolean` or `value` do *not* unwrap
  the option — nil-ness maps to falseness, or rides along in the `value`.
  This explicit Option composition does not authorize arbitrary structural
  coercion through an Array, Map, or Function.

### Where implicit adjustments are applied

The compiler applies the accepted assignment adjustment in exactly these
syntactic contexts. Depending on the source and target, that adjustment may be
identity, one direct coercion from the table above, a gradual view/projection,
or a callable adjustment:

1. The right-hand side of a **local variable declaration** with a type
   annotation (including finite projections of trailing call results).
2. The right-hand side of an **assignment**.
3. The expressions of a **`return`** statement.
4. **Arguments** of function and method calls (including finite or open
   trailing result runs).
5. **Index expressions**: an array index is coerced to `integer`, a map
   index to the map's key type. A float array index gets the checked
   narrowing; an integer key into a `{float: v}` map is promoted, so
   `m[1]` and `m[1.0]` are the same entry.
6. Entries of **constructor expressions**: array elements, map keys and
   values, and record constructor fields. Generated union payloads are
   covered by the ordinary call-argument rule above.
7. **Module variable initializers** (when the variable has a type
   annotation).
8. The finite scalar slots of a **generic `for`**: yielded-variable bindings
   and the iterator's typed state, initial-control, and close setup.

Expression-list consumers apply these rules per demanded scalar. A finite
non-exact Function edge is an expression effect: its operand is evaluated once
and it may allocate a fresh
[closure adjustment wrapper](closure-adjustment-wrappers.md). Exact Function
edges allocate nothing. A positional Array/integer-Map constructor or flexible
return may also consume an open run under an explicitly recorded element plan;
that does not create a structural conversion between the producer and
consumer's container or Function types, though a callable element uses the same
conditional wrapper rule.

Conditions of `if`, `while` and `repeat` are not on this list because
they need no coercion: *any* type is accepted as a condition, and its
truthiness is evaluated at run time. The condition position does count as
"boolean context" for the operators `and`, `or` and `not` inside it (see
[Expressions](expressions.md)).

One context conspicuously **not** on the list: the bound expressions of a
numeric `for`. Earlier versions of this manual claimed loop initializers
were a coercion context; the current compiler instead requires the start,
finish and step expressions to match the control variable's type exactly
(options are unwrapped, but no conversions are inserted):

```titan
local s: float = 0.0
for x: float = 1, 10 do   -- compile-time error: types in 'for' start
    s = s + x             -- expression do not match, expected float
end                       -- but found integer
```

Write `for x: float = 1.0, 10.0` instead. See
[Statements](statements.md) for the rest of the `for` typing rules.

### Coercions performed by operators

The operators insert their own conversions, independent of the contexts
above: mixed `integer`/`float` operands of *arithmetic* operators promote
the integer side to `float` (`/` and `^` always promote operands and
result to `float`), but the relational and equality operators do **not**
promote — a mixed `integer`/`float` comparison compares mathematical
values exactly, as in Lua; the bitwise operators
narrow float operands to `integer` with a run-time check; `..` converts
numeric operands to strings; `not` — and `and`/`or` in a boolean
context — coerce to `boolean`; `==`/`~=` box the non-`value` side only when
the symmetric comparison plan authorizes that injection (raw C pointers are
excluded, and a C scalar carrier check can raise), and lift each side to its
own option type if either side is an option, except that a `nil` operand is
lifted directly to the other operand's option type; and most operators (`#`, unary `-`,
arithmetic, relational, concatenation, bitwise, indexing) implicitly
unwrap an option operand with a run-time nil check. The complete
operator semantics are in [Expressions](expressions.md).

## Type inference

An initialized declaration without a type annotation takes its type from its
initializer. An initializer-less mutable local instead requires an explicit
nil-bearing type. Mutable and const module variables have the same omission
requirement; see [Const values](const-values.md#binding-declarations).

```lua
local n = 10            -- integer
local x = 2.5           -- float
local s = "hi"          -- string
local ps = {1.5, 2.5}   -- {float}, from the first element
local xs = {}           -- {integer}: the default for an empty {}
```

An empty constructor `{}` only defaults to `{integer}` when there is no
expected type; in a context that expects an array or map type (an
annotated declaration, an argument, an assignment) it takes the context's
type.

**Inference never produces an option type.** When the initializer has an
option type — typically an indexing expression — the compiler inserts the
run-time nil check and infers the base type. This is deliberate: nils
should fail fast at the point where the programmer assumed a real value,
not silently propagate through inferred types. To opt in to propagating
the option, put a `?` on the *name*:

```titan
function infer_options()
    local arr: {integer} = {1, 2, 3}
    local x = arr[1]      -- integer; a missing value raises here
    local y? = arr[1]     -- integer?; nil flows through
end
```

Inside a block, `local y?: integer = arr[1]` is accepted too, as sugar for
`local y: integer? = arr[1]`.

The marker preserves optional inference for block-local names, including
extra values from a multiple-return call (`local a, b? = f()` preserves an
option for `b`). Module variables instead require an explicit optional type,
such as `y: integer? = 18`; their names do not accept `?`.

Two other positions are inferred: the control variable of a numeric `for`
takes the type of the start expression when not annotated (and must end
up `integer` or `float`), and module variables without annotations are
inferred from their compile-time-constant initializers with the same
de-optionization rule — see [Modules](modules.md).

## The `value` type in depth

`value` is Titan's dynamic type, in the gradual-typing sense: a `value`
can hold any Lua-representable Titan value and anything Lua can produce.
Raw by-value C aggregates and C function pointers are notable exceptions
because they have no scalar `TValue` representation. It is the deliberate
escape hatch for code that traffics in genuinely dynamic data
— heterogeneous tables, values handed over by Lua, containers like
`{value}` whose element values are checked dynamically.

Gradual injections *to* `value` are free, implicit and total for ordinary
non-C Titan values. A C scalar type can have a `TValue` representation even
when a particular value lies outside the configured `lua_Integer` or
`lua_Number` carrier; boxing such a value performs the same checked carrier
conversion used by the FFI. Implicit projections *from* `value` are accepted in the typed
contexts listed above only when the requested type is guardable, and compile
to a strict run-time type check:

```titan
function double(v: value): integer
    local n: integer = v     -- implicit value -> integer, checked
    return n * 2
end
```

`double(21)` returns `42`; a `value` holding the Lua float `21.0` or the string
`"foo"` raises rather than being converted. The latter error has the form
`... type error, expected integer but found string`.

This implicit projection is intentionally stricter than a written
`v as integer` or an integer arriving from genuine Lua: those dynamic
operations accept an exactly integral, in-range float and convert it. The
distinction is normative in the
[boundary matrix](#normative-boundary-matrix).

What you **can** do with a `value`, beyond converting it:

* **Store it and pass it along** — in variables, arrays, maps, record fields,
  union payloads of type `value`, arguments, and returns.
* **Compare it with `==` and `~=`.** When `value` and the other operand are
  comparable, the other side is boxed. Comparison is Lua's *raw* equality
  unless that other operand is statically a Map. Map/`value` and
  `value`/Map first perform the same raw check, then use Lua table `__eq` only
  when the raw-unequal dynamic value is also a table; see
  [Map equality](arrays-maps.md#equality). A `value`/`value` comparison remains
  raw even when both values happen to contain tables, so `__eq` is not
  consulted. Equality checks the symmetric comparable relation first; it does
  not box a type such as a raw C pointer merely because that type has a
  separate conversion to `value`. (An earlier version of this manual claimed
  casting and passing along were the only available operations; equality has
  been supported since the type was introduced.)
* **Test it.** A `value` can be a condition and an operand of `and`,
  `or` and `not`; its truthiness is Lua's (only `nil` and `false` are
  false). These operators have no metamethods in Lua, so their raw
  semantics are already the Lua semantics.
* **Use it as an index.** An index expression of type `value` is coerced
  to the container's key type with the implicit strict projection:
  `xs[v]` works when `v` holds the Lua integer `2`, and raises when it
  holds the float `2.0` or the string `"foo"`. Write
  `xs[v as integer]` to explicitly request dynamic integral-float
  conversion.
* **Call it contextually.** Positional call syntax derives a temporary
  function type from the written arguments and the surrounding result demand.
  Titan then checks callability and argument/result types at run time. A
  finite unknown result is inferred as `value`; an open array, variadic-call,
  or flexible-return sink derives a flexible result tail. Named syntax is not
  available because a `value` carries no declaration parameter names.
* **Cast it explicitly** with `as` — see below.

What you **cannot** do (all compile-time errors): arithmetic — every
operand of `+ - * % // / ^` must be a number, so a `value` operand is the
error `... is a value instead of a number` (a `value` does not implicitly
unbox inside operators; write `(v as integer) + 1`); relational
comparison (`< <= > >=`, which require equal numeric or string types);
concatenation (`cannot concatenate with value of type 'value'`); taking
the length (`#` requires an array, an exact integer-keyed map, or a string);
and indexing *into* it
(`expression in indexing is not an array or map but value`). Contextual calls
are the deliberate callable exception: the surrounding demand supplies a
complete temporary contract. An exactly tagged Titan closure may use its
native entry. Because a contextual `value` call has no statically known source
Function type, it does not realize an adjustment wrapper: a differently tagged
branded Titan closure uses its strict entry, and an ordinary Lua callable may
honor `__call` before dynamically converting results. Arithmetic and container
operations still require an explicit cast because implicit
unboxing inside them would silently give raw semantics to code that looks
statically typed.

`value` composes with the compound types: `{value}` is an array of
anything, `{string: value}` a string-keyed map of anything, and the
[consistency and gradual-view rules](#relations-and-boundaries-no-subtyping)
let such containers stand in for consistently shaped counterparts (and vice
versa) with strict element checks deferred to the point of use — except inside
records, unions, or Interfaces, which are nominal and admit no such
substitution. In particular, the direct `R -> I` wrapper coercion described in
[Interfaces](interfaces.md) does not make `R` and `I` consistent. A direct
conversion such as `integer -> float` does not lift: `{integer}` and
`{float}` remain unrelated.

## Explicit casts

The cast expression `e as t` is admitted by the separate
**written-castable** relation. Identity casts are no-ops; direct automatic
conversions and gradual edges may be written where that relation enumerates
them; and the FFI supplies a few additional explicit-only conversions. Most
importantly, `e as t` for `e: value` requests the broad dynamic coercion in the
[normative boundary matrix](#normative-boundary-matrix), not the strict
implicit gradual projection. Ordinary numeric and Option conversions can
still be requested simply by placing an expression in a typed context.
Interface casts additionally provide explicit wrapper construction from a
statically satisfying record or union and exact-concrete downcasts from an
Interface wrapper; dynamic casts to an Interface accept an existing exact
wrapper or call a compiler-witnessed metatable entry for bare full userdata.
A written non-exact Function-to-Function `as` uses the same
conditional fresh wrapper as an implicit callable adjustment. Its corresponding
`is` test checks admission but remains allocation-free. A written or implicit
`value -> Function` edge remains a dynamic boxed projection and creates no
wrapper. See [Interfaces](interfaces.md#concrete-tests-and-downcasts) and
[Closure adjustment wrappers](closure-adjustment-wrappers.md#implicit-adjustment-as-and-is).

A written mutable-Array-to-const-Array cast is the one qualifier-changing
Array operation. It makes a shallow copy and admits only equal or gradually
consistent element types; it cannot apply a scalar conversion to every
element. The corresponding static `is` is an allocation-free admission test.
Const-to-mutable casts are rejected, and a dynamic `value as/is` Array checks
the exact qualified run-time tag. See
[Const Arrays](const-values.md#const-arrays).

For C FFI types, regular `as <type>` is also the explicit cast mechanism:
C integers can be cast to `integer`, C floats can be cast to `float`, Titan
`integer` can be cast to C integers, Titan `integer`/`float` can be cast to C
floats, C numeric types can be explicitly cast among themselves, boxable C values
can cross through `value`, C `TValue` can cross to/from Titan `value`, and C
`char *` / `void *` can be cast to `string` (copying bytes up to the first `\0`
and raising if the pointer is `NULL`). Lua-internal `Udata *` crosses the
`value` boundary as full userdata rather than an ordinary lightuserdata
pointer. A written `value as <raw C pointer>` is an explicitly unsafe
lightuserdata/nil assertion: Titan cannot establish the pointee type, so the
same edge is unavailable to implicit projection, typed container reads, and
generic calls. A written cast can also convert a C function pointer to or from C
`void *` through Titan's portability helper, or expose the native GC identity
of an Array, Map, record, union, Interface, or function value as C `void *`.
Direct
object-pointer/function-pointer conversion remains rejected. Separately,
qualification-preserving C object-pointer rules admit `void *` to a compatible
non-character object pointer directly and require a written cast for a
character-pointer target. The function identity cast raises when its boxed
value is not collectable; the other GC-identity cases are total. These are
borrowed internal addresses, not ownership transfers. There is no separate FFI
cast form.
These numeric casts are checked against the selected C target and Titan's
configured numeric carriers before any narrowing cast or boxed store.
Written C-integer-to-C-integer casts are the deliberate exception: they retain
ordinary C conversion semantics, including C's signed/unsigned result rules.
For every partial numeric cast, `is` runs the identical representability test
without converting or raising.
Full details and examples are in [Expressions](expressions.md) and
[The C FFI](ffi.md).

The related expression `e is t` is admitted for exactly the same static
source/target pairs. It evaluates `e` once and returns whether `e as t` would
finish without a cast error, rather than performing the conversion or raising
on a mismatch. It is only a predicate: it does not narrow `e`'s static type in
the true branch. Total casts always test true, including the deliberately
unchecked `value`-to-`boolean` and `value`-to-function conversions; a
function-typed value may still fail when it is later called. A dynamic Option
test recurses through its base: `value is boolean?` is total because nil is
accepted and every present value has a truthiness conversion. Testing a
function value as C `void *` is the separate collectability check described
above, so it may return false. See
[Explicit casts and type tests](expressions.md#explicit-casts-and-type-tests-as-and-is)
for the run-time predicates.
