# Type Aliases, Options, and Dynamic `value`

Every expression, variable, and parameter in Titan has a static type checked at compile time. Where programs need transparent names for existing types, nullable values, or genuinely dynamic Lua data, Titan provides three dedicated tools: `type` aliases, option types (`T?`), and the dynamic `value` type.

| Category | Spelling | Equality |
| --- | --- | --- |
| Scalars | `nil`, `boolean`, `integer`, `float`, `string` | Structural |
| Dynamic slot | `value` | Structural |
| Option | `T?` | Structural |
| Containers | `{T}`, `const { T }`, `const? { T }`, `{K: V}` | Structural |
| Functions | `function (A, B): (R1, R2)` | Structural |
| Nominal types | `record`, `union`, `interface` | Nominal (`module.Name`) |
| Transparent aliases | `type Name = T` | Resolves to `T` |
| C FFI types | `foreign int`, `foreign *T`, `owned *T`, `owned T[]` | See [Calling C](ffi.md) |

Parentheses group any single type without changing its meaning: `({string: integer})?` makes the whole Map optional, `(function (string): (boolean))?` makes the whole function optional (rather than its return type), and `{(function ()): integer}` uses a zero-return function as a Map key.

## Transparent type aliases

A `type` alias gives an existing Titan type another compile-time name without creating a new type identity or runtime value:

```titan
type UserId = integer
type Handler = function (string): (boolean)
type MaybeHandler = Handler?
local type Scratch = {string}

function total_ids(ids: {UserId}): UserId
    local sum = 0
    for i = 1, #ids do
        sum = sum + ids[i]
    end
    return sum
end
```

Aliases are completely transparent: `UserId` and `integer` are identical everywhere, require no conversion, and compare equal in all type checks. Alias chains and forward references are allowed; alias cycles (including cycles through compound types) are compile-time errors. Because a union variant is a constructor rather than a type, a variant cannot appear on the right-hand side of a `type` alias.

Aliases live in the module's type-only namespace: an alias may share a name with a function or variable, cannot collide with another type, and creates no field on the Lua module table.

### Preserved nominal namespaces and re-exports

An alias to a record, union, or Interface preserves the original nominal identity and methods. For records and unions, the alias also forwards the original type's static namespace at compile time—including record-call shorthand, `.new`, static functions, and variant constructors:

```titan
record Point
    x: float
    y: float
end

function Point.origin(): Point
    return Point(0.0, 0.0)
end

type Coord = Point

function make_coords(): (Coord, Coord)
    local a = Coord(1.0, 2.0)
    local b = Coord.origin()
    return a, b
end
```

Key rules for nominal aliases:

- **Generic forwarding:** An alias to a bare generic owner forwards its type parameters (`type Crate = Box` allows `Crate<|integer|>(1)`), whereas an alias to an applied generic (`type IntBox = Box<|integer|>`) is already closed (`IntBox(1)`).
- **Visibility unchanged:** An alias never exposes a `local` record function, `local` `new`, or `local` union variant outside its defining module.
- **Public re-exports:** A public alias to an imported nominal type (`type Point = geometry.Point`) lets downstream importers use `shapes.Point`, its methods, and its public constructors without separately importing `geometry`. A public alias cannot expose a `local` nominal type.
- **Separate C typedefs:** Ordinary `type` aliases may name `owned` C storage or Titan containers/options holding foreign components, but cannot alias a bare raw C type; use `foreign type Name = T` for module-local C typedefs ([Calling C](ffi.md)).

## Option types (`T?`)

For any Titan type `T`, the option type `T?` holds either a value of type `T` or `nil`. There is no separate wrapper object and no flow-sensitive proof system: wrapping `T` into `T?` is free, and using `T?` where a bare `T` is required inserts a runtime nil check that fails immediately if the value is absent.

Options never nest (`integer??` is a syntax error), and `value?` is identical to `value` because `value` already includes `nil`.

### Where options arise

Options appear wherever absence is part of ordinary control flow:

- functions that explicitly return `T?` (such as lookups and `io.Reader:read()`);
- indexed reads on Arrays (`xs[i]` has type `T?`) and Maps (`m[k]` has type `V?`);
- finite reads from a flexible return tail `(...: T)`; and
- `and` expressions whose left operand may be falsy.

Container element and Map value types de-optionize (`{integer?}` means `{integer}` and `{string: integer?}` means `{string: integer}`), because writing `nil` deletes an entry rather than storing an optional wrapper. Map keys cannot be `nil` or `T?`.

### Forcing vs. preserving options (`local x` vs. `local x?`)

Unannotated local inference **never** infers an option type. Initializing an ordinary `local` from a `T?` expression unwraps it immediately and raises if it is `nil`. Append `?` to the variable name to preserve the option:

```titan
function lookup_demo(values: {string}, index: integer): string
    local optional? = values[index]     -- string?; nil flows through
    if optional ~= nil then
        return optional
    end
    local required = values[1]          -- string; raises immediately if values[1] is nil
    return required
end
```

The three local declaration spellings:

| Declaration | Inferred or declared type |
| --- | --- |
| `local x = expr` | Forces `T?` to `T` (raises if `nil`) |
| `local x? = expr` | Preserves `T?` (or wraps `T` as `T?`) |
| `local x: T? = expr` | Explicit `T?` (also writable as `local x?: T = expr` in blocks) |

The `?` name marker works in multi-value local declarations (`local hit?, err? = parse(input)`) and generic `for` binders (`for i, item? in iteration.ipairs(xs) do`). Module-variable declarations require an explicit type annotation (`pending: string? = nil`).

### Automatic unwrap sites

Whenever a `T?` value reaches a context that requires a bare `T`, Titan inserts a checked nil unwrap automatically. These contexts include:

- typed declarations, assignments, call arguments, returns, and constructor entries;
- arithmetic, bitwise, relational, concatenation (`..`), unary (`-`, `~`), and length (`#`) operands;
- numeric `for` bounds;
- the container being indexed (so `matrix[1][1]` unwraps `matrix[1]` before the second lookup);
- record and Interface field reads and writes;
- method calls on optional receivers (`entry:describe()`) and calls through optional function values (`handlers[i](x)`); and
- union `case` scrutinees (`nil` raises and never selects `else`).

Because unwrapping is automatic, check for `nil` once and then use the value directly without adding a redundant `as` cast:

```titan
local strings = import "string"

function first_match(pattern: strings.Regex, subject: string): string?
    local hit? = pattern:match(subject)
    if not hit then
        return nil
    end
    return hit:whole() -- hit auto-unwraps here without `as`
end
```

Direct base coercions also compose with options in a nil-preserving way: `integer? -> float?`, `float? -> integer?`, and `R? -> I?` pass `nil` through unchanged and convert present values (narrowing conversions such as `float? -> integer?` can still raise on a non-integral present value). As always, option coercions do not lift through containers or function types: `{integer}` is not `{integer?}` and `function (): (integer)` is not `function (): (integer?)`.

At implicit typed sinks, [maybe-const Array widening](arrays-maps.md#read-only-and-maybe-const-arrays)
also preserves `nil` between Options and can introduce or force an Option
without changing the Array itself.

### Truthiness, `boolean?`, and equality

Conditions (`if`, `while`, `repeat ... until`) and `not` accept any option without unwrapping it and without narrowing its static type. For most option types, truthiness tests presence (`nil` is falsy; every present value is truthy).

For `boolean?`, however, there are **three** states: `true`, `false`, and `nil`. Because a plain condition merges `false` and `nil`, compare explicitly with `nil` when `false` must stay distinct from absence:

```titan
function enabled_by_default(flag: boolean?): boolean
    if flag == nil then
        return true
    end
    return flag
end
```

`==` and `~=` never unwrap options. When either operand is an option, the other operand lifts to its option type (or `nil` lifts directly into the option type), and equality compares raw values: `nil` equals only `nil`, numeric values compare mathematically (`1` in `integer?` equals `1.0` in `float?`), and Map `__eq` metamethods are not invoked on option comparisons.

### Defaulting with `or` and optionizing with `and`

`x or default` is the idiomatic non-raising unwrap. When `x` has type `T?` and `default` has exact type `T`, the expression has type `T` (no implicit `integer -> float` promotion occurs across `or`, so write `x or 0.0` for `x: float?`):

```titan
function first_available(a: integer?, b: integer?, fallback: integer): integer
    return a or b or fallback
end

function pick_label(found: string?, yes: string, no: string): string
    return found and yes or no
end
```

Chaining `T? or T?` preserves `T?`. For `boolean?`, a present `false` is falsy, so `flag or fallback` chooses `fallback` for both `nil` and `false`.

When the left operand of `and` is a `boolean`, an option, or a `value`, `left and right` produces the option type of `right` (returning `nil` if `left` is falsy—except when both operands are plain `boolean`, which yields `boolean`). That makes Lua's `cond and a or b` idiom type-check cleanly whenever `a` and `b` share the same type `T` and `a` cannot be falsy.

### Options at the Lua boundary

Options cross to Lua as `nil` or their plain value. On inputs from Lua, a `T?` parameter or field accepts `nil` first and otherwise runs Lua-boundary dynamic conversion for `T` (for example, `integer?` accepts `nil`, `42`, or `42.0`; `boolean?` keeps `nil` as `nil` and converts any non-nil value by Lua truthiness).

## Gradual typing with `value`

`value` is Titan's dynamic type. A `value` slot can hold `nil` or any Lua-representable value—scalars, strings, tables, Lua functions, records, unions, Interfaces, Arrays, and Maps. (By-value C structs/unions, C arrays, and C function pointers have no `value` representation.)

Use `value` at genuine dynamic boundaries—such as JSON trees, heterogeneous Lua tables, or callbacks arriving from Lua—and recover a concrete static type close to that boundary.

### `value` is not TypeScript `any`

Unlike TypeScript's `any`, `value` never turns off type checking or silently propagates dynamism into surrounding expressions. Arithmetic, ordering (`<`), string concatenation (`..`), length (`#`), and indexing *into* a `value` are all **compile-time errors** until you convert it to a concrete type:

```text
function bad(v: value): integer
    return v + 1   -- compile error: operand is value instead of a number
end
```

What you *can* do directly with a `value`:

- **Store, pass, and return it** in variables, parameters, fields, and containers.
- **Test its truthiness** in conditions and `and`/`or`/`not`.
- **Compare it with `==` and `~=`.** Comparing two `value` operands uses Lua's raw equality and never invokes `__eq`, even if both hold tables. (Only a comparison where one static operand is a Map invokes table `__eq`.)
- **Use it as a container index** (`xs[v]` applies a strict projection to the container's key type).
- **Call it contextually** with positional arguments. Titan derives a temporary function contract from the written arguments and expected result context, checking callability and types at run time:

```titan
function invoke_dynamic(callback: value, x: integer): integer
    local result: integer = callback(x)
    return result
end
```

Named-call syntax is unavailable on `value` because a dynamic value carries no declaration parameter names.

`value` also participates in **gradual container views**: `{integer}` and `{value}` (or `{string: integer}` and `{string: value}`) share the same container without copying, enforcing strict runtime checks whenever typed code reads an element. Records, unions, and Interfaces are nominal walls—consistency never descends into nominal members.

## Strict implicit projection vs. explicit `as` and `is`

Titan deliberately distinguishes **implicit projection** from `value` in a typed sink from **explicit conversion** with `as` (and genuine Lua boundaries):

```titan
function strict_int(raw: value): integer
    return raw              -- strict projection: accepts integer 2, rejects float 2.0
end

function converted_int(raw: value): integer
    return raw as integer   -- dynamic conversion: accepts integer 2 and float 2.0
end
```

| Target `T` | Implicit `value -> T` (strict projection) | Explicit `value as T` and Lua boundary (dynamic conversion) |
| --- | --- | --- |
| `integer` | Exact Lua integer only (rejects `2.0`) | Lua integer or exact in-range integral float (`2.0` -> `2`) |
| `float` | Exact Lua float only (rejects `2`) | Lua float or integer (`2` -> `2.0`) |
| `boolean` | Exact Lua boolean only (`true`/`false`) | Lua truthiness (`nil`/`false` -> `false`, all else `true`) |
| `string`, record, union | Exact tag / nominal identity | Exact tag / nominal identity |
| Interface `I` | Exact `I` wrapper or compiled witness | Exact `I` wrapper or compiled witness |
| `{T}` / `const { T }` / `const? { T }` | Matching Array proxy qualifier | Matching Array proxy qualifier |
| `{K: V}` | Lua table | Lua table |
| `function (...)` | Boxed value (callability checked on call) | Boxed value (callability checked on call) |
| `T?` | `nil`, or strict projection to `T` | `nil`, or dynamic conversion to `T` |

Typed Array and Map element reads always use the **strict** column, even if the value was placed there by Lua or an `__index` metamethod.

### Testing with `is`

`e is T` tests whether `e as T` would succeed without raising. It evaluates `e` once, returns `boolean`, and **does not narrow** `e`'s static type:

```titan
function read_number(raw: value): integer?
    if raw is integer then
        return raw as integer -- use `as integer` because `is integer` accepts 2.0
    end
    return nil
end
```

Notice the pairing in `read_number`: because `raw is integer` uses the dynamic conversion rules and returns `true` for the float `2.0`, a strict implicit `local n: integer = raw` afterward would reject `2.0`, whereas `raw as integer` converts it consistently. For nominal types such as records and unions, strict and dynamic checks require the exact same nominal identity, so an annotated binding works directly after `if raw is Point`.

Reserve `as` for places where you specifically want dynamic conversion (`value as integer`), an Array snapshot or qualifier downcast (`items as const { T }`), an Interface concrete downcast (`writer as strings.StringWriter`), or an explicit FFI cast. Do not write `as` after an option `nil` check where automatic unwrapping already applies.

## Summary of Titan's conversion model

Titan has **no general subtyping**. Even a widening conversion such as `integer -> float` or `T -> T?` is an explicit outer operation that does not lift through containers or function types:

```text
integer -> float                          accepted (direct coercion)
integer -> integer?                       accepted (direct coercion)
{integer} -> {float}                      compile error
function (): (integer) -> function (): (float)     compile error
function (): (integer) -> function (): (integer?)  compile error
```

Instead, Titan's checker selects one of four distinct mechanisms at each typed sink:

1. **Exact identity** (after resolving transparent `type` aliases).
2. **Direct coercion:** `integer -> float` (always succeeds), `float -> integer` (checked exact integer), `T <-> T?` and `nil -> T?`, compatible `S? -> T?`, non-C Titan values to `boolean` (Lua truthiness), satisfying record/union `R -> I` Interface wrappers, numbers to `string` *only* as operands of `..` (use `"" .. n` elsewhere; `n as string` is rejected), and explicit FFI numeric/pointer conversions.
3. **Gradual views and strict projections:** `T -> value`, strict `value -> T`, and same-kind/same-qualifier container views (`{value}` <-> `{T}`, `{K: value}` <-> `{K: V}`).
4. **Directional callable adjustment:** matching function values with compatible parameter/result arities and tails without inserting scalar conversions on components ([First-Class Functions and Closures](closures.md)).

### Where implicit conversions apply

Titan applies these assignment adjustments in eight contexts:

1. annotated `local` declarations;
2. assignment statements;
3. `return` statements;
4. function and method call arguments;
5. Array and Map index expressions;
6. Array, Map, and record constructor entries;
7. annotated module-variable initializers; and
8. generic `for` iterator tuples and loop-variable bindings.

Numeric `for` bounds are intentionally **not** a conversion context: `for x: float = 1, 10` is a compile-time error. Unwrapping an option bound is allowed, but start, finish, and step must match the control variable's exact numeric type (`for x: float = 1.0, 10.0`).

For the compact lookup table of every type relation, boundary check, and operator rule, see [Appendix C: Lexical, Conversion, and Grammar Reference](grammar.md). For C pointer and numeric casts, see [Calling C](ffi.md).
