# The type system

Every variable, parameter and expression in Titan has a static type,
determined at compile time. The compiler rejects programs that violate the
typing rules with **compile-time errors** of the form
`file:line:col: type error: <message>`. Where Titan deliberately admits
dynamism — the `value` type, [option types](option-types.md), and every
value arriving from Lua — the compiler inserts **run-time checks** instead,
which raise ordinary Lua errors when they fail (see
[Error handling](error-handling.md)).

## The type language

| Type | Written as | Described in |
| --- | --- | --- |
| nil | `nil` | below |
| booleans | `boolean` | below |
| integers | `integer` | below |
| floats | `float` | below |
| strings | `string` | below |
| the dynamic type | `value` | [in depth below](#the-value-type-in-depth) |
| arrays | `{ t }` | [Arrays and maps](arrays-maps.md) |
| maps | `{ k : v }` | [Arrays and maps](arrays-maps.md) |
| records | `Point`, `mod.Point` | [Records](records.md) |
| option types | `t?` | [Option types](option-types.md) |
| function types | `(t1, t2) -> t3` | below (not first-class yet) |
| foreign types | from C headers | [The C FFI](ffi.md) |

### Basic types

`nil`, `boolean`, `integer`, `float` and `string` are exactly Lua's values
of those types: integers and floats are Lua's two number subtypes (by
default 64-bit integers and double-precision floats), and strings are
Lua's immutable byte strings. Unlike Lua, Titan keeps `integer` and
`float` apart in the type system — a variable is one or the other — but
the implicit numeric coercions described below keep mixed arithmetic
working the way a Lua programmer expects.

```lua
local n: integer = 10
local x: float = 3.5
local s: string = "hello"
local b: boolean = true
```

### Arrays and maps

An array type is written `{ t }` for any element type `t` (including
other compound types — `{ {integer} }` is an array of arrays of
integers); a map type is written `{ k : v }`. Both are backed by real Lua
tables and can be passed to and from Lua freely; the full account is in
[Arrays and maps](arrays-maps.md).

```lua
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

### Records

Record types are declared at the top level of a module and are the only
*nominal* types in Titan — see [Type equality](#type-equality) below and
the [Records](records.md) chapter. A record type's full name is qualified
by its module: the `Point` declared in module `geom` is the type
`geom.Point`, written `Point` inside its own module and `geom.Point`
elsewhere (for an `import "geom"` bound to `geom`).

```lua
record Point
    x: float
    y: float
end
```

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

Function types are written with the `->` constructor: `(a, b) -> (c)` is
the type of a function from an `a` and a `b` to a `c`. Parentheses are
optional around a single parameter or a single return type, and `->` is
right-associative: `a -> b -> c` is `a -> (b -> c)`.

Function types exist in the grammar and inside the compiler — they
describe module functions, methods and FFI functions, and appear in error
messages — but **functions are not first-class values in this version of
Titan**. You cannot store a function in a variable or pass one as an
argument; using a function name as a value is the compile-time error
`trying to access a function as a first-class value`, and calling
anything but a named function, static method or method reports
`first-class functions are not supported in this version of Titan`.
See [Functions](functions.md).

*Limitation:* the current compiler additionally aborts with raw internal
errors (Lua tracebacks, not type errors) on every *written* function-type
annotation: with zero or two-plus parameter types it stops in the type
checker (`functions with 0 or 2+ return values are not yet implemented`
— the message actually concerns parameters), and with exactly one
parameter type it passes the checker only to die in code generation
(`invalid type (integer) -> integer`). Since no value can inhabit a
function-typed variable anyway, written function types are best avoided
entirely in 0.5.

### Foreign types

`foreign import` introduces additional types derived from C headers —
pointer types (rendered `pointer to FILE`, `void pointer` in error
messages) and C typedefs. They appear in the relations below only in the
nullable-pointer and void-pointer rules; the details live in
[The C FFI](ffi.md).

## Type equality

Titan's types are *structural* except for records, which are *nominal*:

* Two basic types are equal only if they are the same type.
* `{t1}` equals `{t2}` exactly when `t1` equals `t2`; likewise maps
  compare key and value types pointwise, and function types compare
  parameter and return lists pointwise (same arities required).
* `t1?` equals `t2?` exactly when the base types are equal.
* Two record types are equal only if they are *the same declaration* —
  their fully-qualified names match. Field structure is irrelevant:

```lua
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

Some constructs demand equality directly: relational comparisons
(`<`, `<=`, `>`, `>=`) require equal operand types after numeric
promotion, and the `or` defaulting rule for options (`x or d` where
`x: t?`) requires `d` to have exactly the base type `t`.

## Compatibility: how `value` flows through compound types

Between equality and "unrelated" sits *compatibility* — the consistency
relation of gradual typing: two types are compatible when, ignoring every
position where one of them says `value`, they agree. The compiler accepts
a compatible type wherever a given type is expected, in equality
comparisons, and as the precondition of explicit `as` casts. The rules:

1. Equal types are compatible.
2. `value` is compatible with **every** type.
3. Compatibility recurses through arrays, maps and function types:
   `{value}` is compatible with `{float}`, `{value: integer}` with
   `{string: integer}`, and a `value -> integer` function type with
   `integer -> integer`.
4. Record types are compatible only with themselves. The recursion of
   rule 3 does **not** look inside records: `PointV` above, whose fields
   are `value`, is still incompatible with `PointF`. Nominal means
   nominal.
5. A foreign pointer type is compatible with `nil` (pointers are
   nullable), and a void pointer is compatible with `string` (though the
   conversion itself requires an explicit cast — see [the FFI](ffi.md)).

When two types are merely compatible — related through `value` inside a
compound type rather than by a direct coercion — **no conversion happens
at all**. The value passes through unchanged, and the type mismatch is
paid for later, as run-time checks at the points where elements are
actually read. With `sum: ({float}) -> float` from above:

```lua
function caller(): float
    local vs: {value} = { 1.0, 2.0, 3.0 }
    return sum(vs)   -- accepted: {value} is compatible with {float}
end
```

If an element of `vs` had been a string, `caller` would still compile and
`sum` would raise a run-time error at the `xs[i]` read. This deferred
checking is the same mechanism that guards tables arriving from Lua — see
[Lua interoperability](lua-interop.md).

## Implicit coercions

Distinct from compatibility, a *coercion* is a conversion the compiler
inserts for you. Some coercions always succeed (they are pure conversions
or boxing); others compile into a single run-time check that raises an
error shaped like
`file:line:col: type error, expected <type> but found <type>` (or, for
float-to-integer narrowing,
`... number '<n>' has no integer representation` — on some code paths
prefixed only `type error at line <line>`, with no file or column) when
the value does not conform.

### The coercion table

| From | To | Can fail at run time? |
| --- | --- | --- |
| `integer` | `float` | no |
| `float` | `integer` | yes — error if the float has no exact integer representation (`2.0` is fine, `2.5` raises) |
| any type except `boolean` | `boolean` | no — `nil` and `false` become `false`, everything else `true` |
| any type except `value` | `value` | no |
| `value` | any type except `value` | yes — checked against the target type |
| `t` | `t?` | no |
| `t?` | `t` | yes — error `expected t but found nil` if the value is absent |
| `nil` | `t?` | no |
| `s?` | `t?` | yes — nil check, then convert, then re-wrap: a nil raises instead of flowing through to the target option (nil passes through only between *equal* option types, where no coercion happens at all) |
| `s` | `t?` | as for `s` to `t` (convert, then wrap) |
| `s?` | `t`, for inter-coercible bases | yes — nil check, then convert (in practice the numeric pairs: `integer? → float`, `float? → integer`; the compiler's test for this rule swaps its operands, so it also admits backwards pairs like `boolean? → integer`, which compile into run-time checks that always fail) |
| `integer` or `float` | `string` | no — **only** as an operand of `..`; integral floats format with a `.0` suffix exactly like Lua's `tostring` |
| `string` or pointer | void pointer | no (FFI only) |

Notes on the entries a Lua programmer might not expect:

* **Anything coerces to `boolean`.** Assigning any value to a
  boolean-typed variable or parameter gives you its truthiness — Lua's
  rule, where only `nil` and `false` are false. The same coercion is what
  makes `return a and b` legal in a function returning `boolean` even
  when `a` and `b` are integers.
* **Numbers become strings only in concatenation.** `"x = " .. 3.0`
  produces `"x = 3.0"`, but there is no implicit number-to-string
  coercion anywhere else: `local s: string = 3` is the compile-time error
  `types in declaration of local variable s do not match, expected string
  but found integer`. There is no explicit cast either — `3 as string` is
  also rejected — so concatenating with the empty string (`"" .. n`) is
  the idiom for converting a number to a string.
* **The option rules compose with the others.** Coercing `arr[i]` (an
  `integer?`) to `float` first inserts the nil check, then the numeric
  conversion. Coercions targeting `boolean` or `value` do *not* unwrap
  the option — nil-ness maps to falseness, or rides along in the `value`.

### Where implicit coercions are applied

The compiler inserts coercions in exactly these syntactic contexts,
whenever the expression's type is coercible to the expected type:

1. The right-hand side of a **local variable declaration** with a type
   annotation (including expanded multiple-return extras).
2. The right-hand side of an **assignment**.
3. The expressions of a **`return`** statement.
4. **Arguments** of function and method calls (including expanded
   multiple-return tails).
5. **Index expressions**: an array index is coerced to `integer`, a map
   index to the map's key type. A float array index gets the checked
   narrowing; an integer key into a `{float: v}` map is promoted, so
   `m[1]` and `m[1.0]` are the same entry.
6. Entries of **constructor expressions**: array elements, map keys and
   values, and record constructor fields.
7. **Module variable initializers** (when the variable has a type
   annotation).

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

```lua
local s: float = 0.0
for x: float = 1, 10 do   -- compile-time error: types in 'for' start
    s = s + x             -- expression do not match, expected float
end                       -- but found integer
```

Write `for x: float = 1.0, 10.0` instead. See
[Statements](statements.md) for the rest of the `for` typing rules.

### Coercions performed by operators

The operators insert their own conversions, independent of the contexts
above: mixed `integer`/`float` operands of arithmetic, relational and
equality operators promote the integer side to `float` (`/` and `^`
always promote operands and result to `float`); the bitwise operators
narrow float operands to `integer` with a run-time check; `..` converts
numeric operands to strings; `not` — and `and`/`or` in a boolean
context — coerce to `boolean`; `==`/`~=` box the other side to `value`
if either side is a `value`, and lift each side to its own option type
if either side is an option; and most operators (`#`, unary `-`,
arithmetic, relational, concatenation, bitwise, indexing) implicitly
unwrap an option operand with a run-time nil check. The complete
operator semantics are in [Expressions](expressions.md).

## Type inference

A declaration without a type annotation takes its type from its
initializer:

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

```lua
local arr: {integer} = {1, 2, 3}
local x = arr[1]      -- x: integer  (checked at run time, raises if nil)
local y? = arr[1]     -- y: integer? (nil flows through)
```

`local y?: integer = arr[1]` is accepted too, as pure sugar for
`local y: integer? = arr[1]`.

*Limitation:* the `?` marker is ignored in two places: for names bound to
the extra values of a multiple-return call (`local a, b? = f()` infers a
non-option type for `b` when `b` comes from `f`'s second return), and on
module-level variables (`y? = 18` at the top level parses, but the
variable is inferred non-option).

Two other positions are inferred: the control variable of a numeric `for`
takes the type of the start expression when not annotated (and must end
up `integer` or `float`), and module variables without annotations are
inferred from their compile-time-constant initializers with the same
de-optionization rule — see [Modules](modules.md).

## The `value` type in depth

`value` is Titan's dynamic type, in the gradual-typing sense: a `value`
can hold any Titan value and anything Lua can produce. It is the
deliberate escape hatch for code that traffics in genuinely dynamic data
— heterogeneous tables, values handed over by Lua, containers like
`{value}` that mirror plain Lua tables.

Conversions *to* `value` are free, implicit and total. Conversions *from*
`value` are implicit in every coercion context listed above, and compile
to a single run-time type check:

```lua
function double(v: value): integer
    local n: integer = v     -- implicit value -> integer, checked
    return n * 2
end
```

`double(21)` returns `42`; `double("foo")` raises the run-time error
`... type error, expected integer but found string`.

What you **can** do with a `value`, beyond converting it:

* **Store it and pass it along** — in variables, arrays, maps, record
  fields of type `value`, arguments, returns.
* **Compare it with `==` and `~=`.** If either operand of an equality
  test is a `value`, the other side is boxed and the comparison is Lua's
  *raw* equality — `__eq` metamethods are not consulted. (An earlier
  version of this manual claimed casting and passing along were the only
  available operations; equality has been supported since the type was
  introduced.)
* **Test it.** A `value` can be a condition and an operand of `and`,
  `or` and `not`; its truthiness is Lua's (only `nil` and `false` are
  false). These operators have no metamethods in Lua, so their raw
  semantics are already the Lua semantics.
* **Use it as an index.** An index expression of type `value` is coerced
  to the container's key type with a run-time check: `xs[v]` works when
  `v` holds `2` or `2.0`, and raises when it holds `"foo"`.
* **Cast it explicitly** with `as` — see below.

What you **cannot** do (all compile-time errors): arithmetic — every
operand of `+ - * % // / ^` must be a number, so a `value` operand is the
error `... is a value instead of a number` (a `value` does not implicitly
unbox inside operators; write `(v as integer) + 1`); relational
comparison (`< <= > >=`, which require equal numeric or string types);
concatenation (`cannot concatenate with value of type 'value'`); taking
the length (`#` requires an array or string); indexing *into* it
(`expression in indexing is not an array or map but value`); and calling
it. This restriction to explicitly-cast, metamethod-free operations is by
design: implicit unboxing inside operators would silently give "raw"
semantics to code that looks like ordinary Lua arithmetic, so the
conversions are confined to positions where a target type is named.

`value` composes with the compound types: `{value}` is an array of
anything, `{string: value}` a string-keyed map of anything, and the
[compatibility rules](#compatibility-how-value-flows-through-compound-types)
let such containers stand in for their fully-typed counterparts (and vice
versa) with element checks deferred to the point of use — except inside
records, which are nominal and admit no such substitution.

## Explicit casts

The cast expression `e as t` is *narrower* than the implicit coercion
relation, not wider: a cast must relate types that are both coercible
**and** compatible. In practice that leaves the conversions involving the
dynamic type — `e as value` (always succeeds) and `e as t` for a
`value`-typed `e` (run-time checked, for any `t`) — plus the FFI-only
`p as string` for a void pointer `p`, which is the one conversion that is
*never* done implicitly. Everything else is the compile-time error
`cannot cast '<t1>' to '<t2>'`. That includes identity casts
(`x as integer` when `x` is already an `integer`) and, notably, pairs
that *do* coerce implicitly: `integer as float`, `float as integer`,
`t as t?` and `t? as t` are all rejected. Those conversions are available
only implicitly, by placing the expression in a context that expects the
target type — for example `local n: integer = f` rather than
`f as integer`. Full details and examples are in
[Expressions](expressions.md).
