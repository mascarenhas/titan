# Option types

For any Titan type `T` (other than `value` and function types), there is an
*option type* `T?` whose values are the values of `T` plus `nil`. Option
types are how "this value may be absent" is spelled in Titan's type system:
reading an array or map element produces one, `nil` can only be stored where
one is expected, and the conversions between `T` and `T?` are implicit —
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

## Syntax

In a type annotation, `?` is a suffix on any simple type, including array
and map types and (qualified) record names:

```lua
local a: integer?           = nil
local b: string?            = "hi"
local c: {integer}?         = nil      -- option of array
local d: {string:integer}?  = nil      -- option of map
local p: Point?             = nil      -- option of a record type
local q: geom.Point?        = nil      -- imported record type
```

The suffix does not nest (`integer??` is a syntax error), and it cannot be
applied to a whole function type — there is no syntax for "optional
function" (see [Limitations](#limitations)). Writing `value?` is accepted
but means exactly `value`: the `value` type already contains `nil`, so
optionizing it changes nothing.

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

## What an option value is

A `T?` value is either a value of `T` or Lua's `nil` — there is no separate
"none" wrapper. For most base types that means "the value, or absent"; for
`boolean?` it makes a *three-state* type — `true`, `false`, or `nil` — whose
three values are distinct (`x == false` is true only for `false`, and a
plain truth test isolates `true`; comparing with a literal `nil` does not
compile — see [Equality](#equality)), though in a condition both `false`
and `nil` count as false.

*Implementation note:* a `T` value is stored unboxed in generated C (a
`lua_Integer`, a string pointer, ...), but a `T?` is stored as a full
tagged Lua value (a `TValue`), since it must be able to hold nil. See
[runtime value representation](../implementation/values-and-gc.md).

## Implicit conversions

### Wrapping is free

A `T` converts implicitly to `T?` wherever implicit coercions happen
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

For example, compiling and running:

```lua
-- Titan (first.titan)
function first(xs: {integer}): integer
    local x: integer = xs[1]    -- implicit unwrap of integer?
    return x
end
```

```lua
-- Lua
local m = require "first"
print(m.first({42}))        --> 42
print(pcall(m.first, {}))   --> false   first.titan:2:26: type error, expected integer but found nil
```

Besides annotated declarations, the checker unwraps options implicitly in
every context that needs the bare value: operands of arithmetic, bitwise,
relational and concatenation operators; the operands of unary `-`, `~` and
`#`; numeric `for` bounds; the indexed expression itself (so if
`a: {{string}}`, the inner read `a[1]` of type `{string}?` is unwrapped
before `a[1][1]` indexes it); the receiver of a field access; and
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
method call unwraps an option record receiver.

### Conversions between different option types

Options interconvert across base types: `t1?` converts to `t2?` whenever
`t1` is coercible to `t2` (for example `integer?` to `float?`). The
conversion is **nil-preserving** — `nil` flows straight through as `nil`,
and a present value is unwrapped, converted base-to-base, and re-wrapped.
Same-base conversions (`T` ↔ `T?`, and `nil → T?`) are implicit and
nil-preserving too. As with the underlying base conversion, a *narrowing*
one can still fail at run time on a present value — converting a `float?`
that holds a non-integral or out-of-range number to `integer?` raises the
usual "no integer representation" error, while `nil` is unaffected.

### Explicit `as` casts

The *explicit* cast from an option to its base type unwraps it with a
run-time nil check: `xs[1] as integer` evaluates to the integer when one
is present, and raises `expected integer but found nil` when the value is
`nil`. It is the explicit spelling of the same unwrap the implicit
coercions perform. For a *defaulted* unwrap that never raises, use `or`
instead (`xs[1] or 0`).

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
the element (clears the key), exactly as in Lua:

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
arrays and maps are real Lua tables, and a Lua table cannot store nil:
"holds nil" and "absent" are the same state. Indexing already gives you
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
checker wraps the *other* side into the option of its own type and compares
at the option type (behavior fixed by PR #250), so all of these typecheck:

```lua
function eq(t: {string}, s: string): boolean
    return t[1] == s          -- string? == string
end

function both(t1: {integer}, t2: {integer}): boolean
    return t1[1] ~= t2[1]     -- integer? ~= integer?
end
```

At run time, comparing options compares the underlying Lua values, "like
comparing two `value`s" (PR #255): nil equals only nil, and non-nil values
compare with Lua's primitive (raw) equality — which still equates numbers
across subtypes, so `1` held in an `integer?` equals `1.0` held in a
`float?`. (`__eq` metamethods are never involved; no Titan type has them.)

Otherwise the two sides must be compatible types — `integer? == string` is
the usual **compile-time error**
`trying to compare values of incomparable types: integer? and string?` —
with one carve-out: an `integer?` may be compared with a `float?` (and, via
the lifting above, `integer` with `float?` and vice versa) even though no
numeric promotion is applied to the option; the run-time numeric equality
just shown makes it behave as expected.

The lifting also rules out the `nil` *literal* as a comparand: in
`t[1] == nil` the right side is wrapped to `nil?`, and the comparison is
the same **compile-time error**
(`trying to compare values of incomparable types: integer? and nil?`).
Test for nil-ness with a condition (`if t[1]`, `not t[1]`) instead.

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

Options cross the Lua boundary as plain Lua values. A Titan function with a
`T?` parameter accepts nil from Lua, and otherwise checks the value as a
`T` parameter would: a `float?` parameter converts a Lua integer the way
`float` does, and an `integer?` parameter converts an integral float like
`3.0` exactly as a plain `integer` parameter would. A wrong, non-nil value
raises the usual boundary error (see [Lua interoperability](lua-interop.md)).
A `T?` return value simply arrives in Lua as nil or as the value.

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

The same applies to option-typed record fields written from Lua, and to
nil read out of arrays and maps — which is how most options are born: Lua
passes a table with holes, and the holes surface in Titan as nil options.

## Limitations

Beyond the notes already made above, the 0.5 prototype has these known
rough edges:

* **Option function types cannot be written.** `?` suffixes simple types
  only, and there is no parenthesized type syntax to attach it to a
  function type. An option of a function type still *arises* implicitly —
  indexing an array or map whose element type is a function yields one, and
  calling through it auto-unwraps (see [above](#unwrapping-is-checked)) —
  but it cannot be spelled in an annotation.
