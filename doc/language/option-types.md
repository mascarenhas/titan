# Option types

For any source-level simple Titan type `T` other than `value`, there is an
*option type* `T?` whose values are the values of `T` plus `nil`. Option
types are how "this value may be absent" is spelled in Titan's type system:
reading an array or map element produces one, `nil` can only be stored where
one is expected, a finite position projected from a flexible result run
produces one, and the conversions between `T` and `T?` are implicit —
free in one direction, checked at run time in the other.

This chapter covers syntax, the conversion rules, equality, the `or`/`and`
idioms, the interaction with [arrays and maps](arrays-maps.md), conditions,
and the Lua boundary; the general coercion machinery that options plug
into is described in [the type system](types.md).

## Motivation

Option types were added in PR #239, whose description is still the best
statement of the design:

> The idea of this first version of option types (`t?`) is to be "gradually
> typed", that is, Titan has a distinction between `t` and `t?`, but will
> implicitly cast between those two types (of course, casting from `t?` to
> `t` will fail at runtime if the value is not there). The rationale is to
> not bother the programmer with having to prove that the value is always
> there, as that is very finnicky in an imperative language, but fail fast
> if he thinks he is handling a real value but the value is not actually
> there, so "nulls" do not propagate.
>
> — Fabio Mascarenhas, PR #239

Two consequences of that rationale shape everything below:

* **No proof obligations.** There is no flow-sensitive nil analysis and no
  pattern-matching ceremony: where the context expects a `T` and you supply
  a `T?`, the compiler inserts a single run-time check.
* **Options are opt-in.** Type inference never produces an option type on
  its own; "the programmer has to explicitly 'opt-in' to having an
  expression be nullable" (PR #239). A nil you did not ask to handle is an
  immediate run-time error at the point of use, not a `nil` propagating
  through your data.

“Gradually typed” in that historical description does not mean that `T` is a
subtype of `T?`, or that the pair belongs to Titan's gradual-consistency
relation. `T -> T?` and `T? -> T` are named automatic coercions with explicit
representation and nil behavior. They do not lift through an Array, Map, or
Function: in particular, an `() -> T` value cannot be adjusted to
`() -> T?`. See the type system's
[relations and normative boundary matrix](types.md#relations-and-boundaries-no-subtyping).

A declared [flexible return](flexible-returns.md) is another source of
may-be-absent positions. When a finite context requests a `...: T` result,
that position is `T?`: the call may not have produced it. An unannotated local
still follows the rule above and forces the option to `T`; use the form
`local x? = f()` or annotate `x: T?` to keep the absence. A `...: value`
projection stays `value`, because `value` already includes nil.

## Syntax

In a type annotation, `?` is a suffix on any simple type, including array
and map types and (qualified) record, union, or Interface names:

```lua
local a: integer?           = nil
local b: string?            = "hi"
local c: {integer}?         = nil      -- option of array
local d: {string:integer}?  = nil      -- option of map
local p: Point?             = nil      -- option of a record type
local q: geom.Point?        = nil      -- imported record type
local m: Message?           = nil      -- option of a union type
local r: Reader?            = nil      -- option of an Interface type
local s: api.Reader?        = nil      -- imported Interface type
```

The suffix does not nest (`integer??` is a syntax error), and it cannot be
applied directly to a whole function type because function types are not
simple types in this grammar. Name the function type with an alias and apply
the suffix to that name instead:

```titan
local type Handler = (string) -> boolean
local handler: Handler? = nil
```

Writing `value?` is accepted but means exactly `value`: the `value` type
already contains `nil`, so optionizing it changes nothing.

Container reads and finite flexible-result projections can nevertheless
produce a may-be-absent function value internally. Consuming it as a function
performs the same checked unwrap as any other option; direct call syntax does
that automatically.

### Declaration forms and option inference

An unannotated `local` declaration never infers an option type — `tryforce`
applies first, so the initializer is unwrapped and the variable gets the
base type. Putting `?` on the *name* opts in to option inference:

```lua
function read(xs: {integer})
    local x = xs[1]      -- x: integer  (xs[1] is integer?, unwrapped — raises if absent)
    local y? = xs[1]     -- y: integer? (option type inferred, nil flows through)
end
```

The three `?` spellings in declarations:

| Form | Meaning |
| --- | --- |
| `local x: T? = e` | `x` has the written type `T?`; `e` is coerced to it. |
| `local x?: T = e` | Identical to the previous form: with an annotation present, the `?` on the name simply moves into the type, producing `T?`. |
| `local x? = e` | No annotation; `x`'s type is *the option of* the inferred type of `e` (and inferring from an expression that is already an option keeps it an option). |

The subtle difference: *with* a type, `x?:` is pure sugar for writing `T?`;
*without* one, `x?` is an inference directive — the only way to say
"infer, but keep it nullable".

The `?` name marker works in every position the parser accepts it,
including on a module-level variable (`y? = 18` at the top level infers
`integer?`) and on a declaration that receives one of the *extra* values of
a multiple-return call (`local a, b? = f()` optionizes `b`).
This is especially useful for a finite projection from a flexible result tail:
`local first?, second? = produce()` retains the possibility that either
position is absent.

## What an option value is

A `T?` value is either a value of `T` or Lua's `nil` — there is no separate
"none" wrapper. For most base types that means "the value, or absent"; for
`boolean?` it makes a *three-state* type — `true`, `false`, or `nil` — whose
three values are distinct (`x == false` is true only for `false`, and a
plain truth test isolates `true`; `x == nil` isolates absence — see
[Equality](#equality)), though in a condition both `false` and `nil` count as
false.

*Implementation note:* a `T` value is stored unboxed in generated C (a
`lua_Integer`, a string pointer, ...), but a `T?` is stored as a full
tagged Lua value (a `TValue`), since it must be able to hold nil. See
[runtime value representation](../implementation/values-and-gc.md).

## Implicit conversions

### Wrapping is free

A `T` converts implicitly to `T?` wherever implicit adjustments happen
(declarations, assignments, arguments, returns, initializer entries —
the full list is in [the type system](types.md)), and `nil` converts to any
option type:

```lua
function find(xs: {string}, wanted: string): integer?
    for i = 1, #xs do
        if xs[i] == wanted then
            return i        -- integer wrapped into integer?
        end
    end
    return nil              -- nil converts to integer?
end
```

### Unwrapping is checked

A `T?` also converts implicitly to `T` — this is the "casting from `t?` to
`t` will fail at runtime if the value is not there" half of the design. The
compiler inserts a nil check; if the value is nil, a **run-time error** is
raised with this message shape (catchable with `pcall` from Lua, like every
Titan run-time error — see [error handling](error-handling.md)):

```
<file>:<line>:<col>: type error, expected <T> but found nil
```

Gradually consistent option bases retain the same strict policy. For example,
a `value?` may be used where `integer?` is expected. Nil passes unchanged; a
present payload must already carry the integer tag. An integral float such as
`2.0` is not converted at this implicit Titan view and raises a normal type
error. Written `value as integer?` and a genuine Lua-to-Titan boundary remain
the broader dynamic conversions described below.

For example, compiling and running:

```lua
-- Titan (first.titan)
function first(xs: {integer}): integer
    local x: integer = xs[1]    -- implicit unwrap of integer?
    return x
end

function singleton(): {integer}
    return {42}
end

function empty(): {integer}
    return {}
end
```

```lua
-- Lua
local m = require "first"
print(m.first(m.singleton()))        --> 42
print(pcall(m.first, m.empty()))     --> false   first.titan:2:26: type error, expected integer but found nil
```

Besides annotated declarations, the checker unwraps options implicitly in
every context that needs the bare value: operands of arithmetic, bitwise,
relational and concatenation operators; the operands of unary `-`, `~` and
`#`; numeric `for` bounds; the indexed expression itself (so if
`a: {{string}}`, the inner read `a[1]` of type `{string}?` is unwrapped
before `a[1][1]` indexes it); the receiver of a field access; a union
`case` scrutinee; and
unannotated initializers, as shown above. Notably *not* unwrapped:
`==`/`~=` operands, conditions, `not`, `and`/`or` operands, and method-call
receivers (each covered in its own section below).

```lua
function get(a: {{string}}): string
    return a[1][1]       -- a[1] : {string}? is unwrapped, then indexed
end
```

This unwrap works wherever an option reaches a context that needs the bare
value, whether the option is the direct result of an array or map read or
is held in a plain *variable* — a local, a parameter, a module variable, or
a record field — and whether the consuming context is arithmetic, a call
argument, an array or map index, or string concatenation. A nil at run time
raises the `expected <T> but found nil` error shown above.

The same unwrap fires when you **call through** an option-of-function. An
array or map whose element type is a function yields a `T?` on indexing, so
calling the result directly — `arr[i](x)` — auto-unwraps the option with a
run-time nil check, raising cleanly if the element is nil, exactly as a
method call unwraps an option nominal receiver.

`case` is another bare-value context. If its scrutinee has type `Union?`, the
checker forces it to `Union` before reading a variant tag. A present union
dispatches normally; nil raises the same `expected Union but found nil` error.
Nil does not select the case statement's `else`.

### Conversions between different option types

Options interconvert across base types through Titan's explicitly named
Option coercion plans: `t1?` converts to `t2?` whenever the direct base
conversion is one of those plans (for example `integer?` to `float?`). The
conversion is **nil-preserving** — `nil` flows straight through as `nil`,
and a present value is unwrapped, converted base-to-base, and re-wrapped.
Same-base conversions (`T` ↔ `T?`, and `nil → T?`) are implicit and
nil-preserving too. As with the underlying base conversion, a *narrowing*
one can still fail at run time on a present value — converting a `float?`
that holds a non-integral or out-of-range number to `integer?` raises the
usual "no integer representation" error, while `nil` is unaffected.

An implicit gradual projection from `value` to `T?` is checked against the
whole Option type: nil remains nil, while a present value must pass the
**strict** gradual guard for `T`. It does not apply numeric conversion or
truthiness. Thus a `value` holding an actual boolean projects to `boolean?`,
but a present string does not become `true`. This differs deliberately from
the written/Lua dynamic Option rule described below.

These recursive Option plans are a deliberate exception for the Option
constructor itself, not a general transitive-closure rule. They do not license
`{T?}`/`{U?}` element conversion or component conversion through Function
types.

### Explicit `as` casts

The *explicit* cast from an option to its base type unwraps it with a
run-time nil check: `xs[1] as integer` evaluates to the integer when one
is present, and raises `expected integer but found nil` when the value is
`nil`. It is the explicit spelling of the same unwrap the implicit
coercions perform. For a *defaulted* unwrap that never raises, use `or`
instead (`xs[1] or 0`).

### Interfaces and options

The direct record/union-to-Interface wrapper coercion composes with Options
through explicitly named plans:

| Source | Target | Behavior |
| --- | --- | --- |
| satisfying concrete `R` | `I?` | construct a fresh `I` wrapper, then make it present |
| satisfying `R?` | `I` | force non-nil, then construct a fresh `I` wrapper |
| satisfying `R?` | `I?` | preserve nil; wrap a present `R` |
| `I` | `I?` | ordinary Option introduction |
| `I?` | `I` | ordinary checked force |
| `value` | `I?` | preserve nil; a present value follows the exact-or-compiler-witnessed dynamic `I` rule |

These plans do not make `R` and `I` gradually consistent and do not authorize
general coercion lifting. Written casts are deliberately narrower:
`I? as/is R` may downcast/test the present concrete value, and `I? as/is I`
uses the ordinary exact force/test, but the other implicit combinations are
not automatically written-castable. The complete matrix is in
[Interfaces](interfaces.md#options).

## Arrays, maps, and `nil`

Options are woven into the container types in three ways (details in
[arrays and maps](arrays-maps.md)):

**Indexing yields an option.** If `xs: {T}`, then `xs[i]: T?`; if
`m: {K:V}`, then `m[k]: V?`. A missing element reads as nil — it does not
raise. Whether that nil then raises depends on what you do with the
result: use it where a `T` is required and the unwrap check fires; test
it, default it, or store it into an option and it flows.

**Writing `nil` deletes.** Because the element's type in an assignment is
the same optionized type, `nil` is assignable, and assigning it removes
the element (clears the Array slot or Map key):

```lua
function delete(xs: {integer}, i: integer)
    xs[i] = nil          -- removes the element
end
function clear(m: {string:integer}, k: string)
    m[k] = nil           -- removes the key
end
```

**Option annotations are stripped from element positions.** An array
element type or map value type written as an option is silently
*de-optionized*: `{integer?}` means exactly `{integer}`, and
`{string: integer?}` means `{string: integer}`. Nothing is lost — Titan
containers do not store nil elements: "holds nil" and "absent" are the same
state in both an Array's private backing table and an ordinary Map table.
Indexing already gives you
`integer?` and assigning nil already deletes, so an option element type
would promise a distinction the representation cannot make. Map *keys* are
different: a nil key is impossible, so both forms are **compile-time
errors**:

```
type of map key cannot be nil
type of map key cannot be option type
```

## Equality

`==` and `~=` accept options freely. When either side is an option, the
checker wraps an ordinary other operand into the option of its own type and
compares at the option type (behavior fixed by PR #250). A `nil` operand is
instead wrapped directly into the existing option type: nil inhabits every
option, and independently constructing `nil?` would lose that relationship.
All of these typecheck:

```lua
function eq(t: {string}, s: string): boolean
    return t[1] == s          -- string? == string
end

function both(t1: {integer}, t2: {integer}): boolean
    return t1[1] ~= t2[1]     -- integer? ~= integer?
end

function missing(candidate: boolean?): boolean
    return candidate == nil   -- true for nil, false for false and true
end
```

At run time, comparing options compares the underlying Lua values, "like
comparing two `value`s" (PR #255): nil equals only nil, and non-nil values
compare with Lua's primitive (raw) equality — which still equates the Lua
integer and floating representations, so `1` held in an `integer?` equals
`1.0` held in a `float?`. `__eq` metamethods are never involved on this option
path, including when a present option payload is a Map. The metamethod-aware
exception requires a non-option static Map/Map or Map/`value` comparison.

Otherwise the two sides must be comparable types — `integer? == string` is
the usual **compile-time error**
`trying to compare values of incomparable types: integer? and string?` —
with one carve-out: an `integer?` may be compared with a `float?` (and, via
the lifting above, `integer` with `float?` and vice versa) even though no
numeric promotion is applied to the option; the run-time numeric equality
just shown makes it behave as expected.

Use `candidate == nil` or `candidate ~= nil` when the option base can itself
be falsy. In particular, a `boolean?` condition cannot distinguish its
present `false` state from nil, while equality with nil can. Truthiness remains
a compact presence test for options whose present values are always truthy.

## Defaulting with `or`, optionizing with `and`

PR #239 again, on the intended idioms:

> Option types play well with the usual Lua idioms for `and` and `or`. The
> type of `x and y` is an option type constructed from the type of `y`, and
> the type of `x or y` is `t` if `x` has type `t?` and `y` has type `t`, so
> the "ternary operator" `<cond> and <exptrue> or <expfalse>` works as
> expected. — PR #239

**`or` is the defaulted unwrap.** When the left operand has type `T?` and
the right operand has type `T` (exactly `T` — see below), the whole
expression has the bare type `T`: if the option is nil you get the default,
otherwise the value, with no error possible.

```lua
function get(t: {integer}, i: integer, def: integer): integer
    return t[i] or def
end
```

The base types must match exactly: with `x: float?`, `x or 0.0` has type
`float`, but `x or 0` is a **compile-time error** —
`left hand side of 'or' is a float? but right hand side is a integer` —
there is no integer-to-float promotion through `or`. Two escapes from the
exact-match rule: if either operand is a `boolean`, or the `or` sits in a
boolean context, both sides are coerced to `boolean` instead; and if the
right operand is a `value`, the option widens and the result is `value`.

**`and` produces an option.** When the left operand of `and` is not
statically known to be truthy or falsy (so: a `boolean`, an option, or a
`value`), the result type is the *option* of the right operand's type —
`b and 1.0` is typed `float?`, because the expression yields the left
operand when it is false or nil — and a falsy left operand surfaces as the
*nil* of the result option (with `v: value`, `v and 1.0` evaluates to nil
both when `v` is nil and when it is `false`). That is exactly what makes
the Lua ternary idiom type out: in `t[i] and v1 or v2` with `v1, v2: T`,
the `and` has type `T?` and the `or` collapses it back to `T`:

```lua
function pick(t: {integer}, i: integer, v1: integer, v2: integer): integer
    return t[i] and v1 or v2
end
```

(As in Lua, the idiom requires that `v1` itself cannot be false or nil —
with `v1: integer` it cannot.)

An option-producing `and` works with any left operand, including a plain
`boolean` and any comparison result, so both `b and 1.0` above and
`(a > b) and v1 or v2` compile and run. The `and` also works in a boolean
context (`if a and b then`, `x and y` returned as a `boolean`), where both
sides are coerced to `boolean` instead.

## Options in conditions

Any expression, of any type, can be a condition in `if`/`while`/`repeat`
as far as the checker is concerned; no conversion is applied (see
[statements](statements.md)). For an option,
its nil-ness is its falsiness: a `T?` condition is false when nil and true
otherwise — except `boolean?`, where both `nil` and `false` are false,
matching Lua truthiness exactly. `not` follows the same rule. Testing
before using is therefore the natural pattern for container reads:

```lua
function fill(t: {integer}, i: integer, v: integer): integer
    if t[i] then
        return t[i] + 1      -- this read is unwrapped; the check still runs
    else
        t[i] = v
        return v
    end
end
```

Note that the `if` does *not* change the type of `t[i]` inside the branch —
there is no flow typing. The read in the then-branch is a fresh `integer?`
unwrapped by the `+`, with its own (now unfailing) nil check; to pay for
the check once, combine the test and the use with `or`.

The same falsiness rule applies in `while` and `repeat`/`until` conditions:
an option condition there tests nil-ness exactly as in `if` (`while t[i] do`
loops while the element is present), and `not` yields a `boolean`; see
[statements](statements.md).

## Options at the Lua boundary

Options cross the Lua boundary as plain Lua values. At a genuine Lua boundary,
a `T?` target accepts nil first and otherwise applies the exact same
target-directed dynamic conversion as `T`. Thus `float?` converts a Lua
integer, `integer?` converts an exactly integral in-range float, and
`boolean?` preserves nil but truthiness-converts every present value. The
same recursive rule governs `value as/is T?`; in particular,
`value is boolean?` is total. A wrong, non-nil value raises the usual
boundary error (see [Lua interoperability](lua-interop.md)). A `T?` return
value simply arrives in Lua as nil or as the value.

For an Interface base `I`, “the dynamic conversion for `I`” means exact
wrapper identity or compiler-witnessed metatable discovery. Nil is accepted
first for `I?`; a present existing `I` wrapper is accepted; and bare full
userdata is accepted when its metatable has a non-nil wrapper entry registered
by an initialized module that compiled that concrete/Interface pair. The entry
constructs a fresh wrapper. Titan does not structurally inspect methods at run
time, so an otherwise satisfying record/union remains rejected when no loaded
conversion site witnessed the pair. `is I?` tests entry presence without
calling it.

```lua
-- Titan (greet.titan)
function greet(name: string?): string
    return "hello " .. (name or "world")
end
```

```lua
-- Lua
local m = require "greet"
print(m.greet(nil))        --> hello world
print(m.greet("titan"))    --> hello titan
print(pcall(m.greet, 42))  --> false   greet.titan:1:1: type error, expected string but found number
```

The same dynamic rule applies to option-typed module or record fields written
from Lua and to constructor/function parameters, including union payload
constructors. By contrast, a present value read from a typed Array or Map uses
the strict gradual guard for `T`; only absence itself produces nil. These
distinctions are centralized in the
[normative boundary matrix](types.md#normative-boundary-matrix).

## Limitations

Beyond the notes already made above, the current prototype has these known
rough edges:

* **A direct function type cannot take `?`.** `?` suffixes simple types only,
  and there is no parenthesized type syntax to attach it directly to a
  function type. The type system does support options of function types:
  give the function type an alias and write `Alias?`. Such an option can also
  arise implicitly when indexing an array or map whose element type is a
  function; calling through it auto-unwraps (see
  [above](#unwrapping-is-checked)).
