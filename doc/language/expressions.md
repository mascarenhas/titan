# Lexical Structure, Values, and Expressions

Titan's lexical rules and expression operators match Lua closely: the same
literals, the same operator precedences, the same short-circuiting `and` and
`or`, and bit-for-bit identical arithmetic. Static typing restricts each
operator to the types it meaningfully supports and adds explicit `as` casts
and `is` type tests.

When an operand is a C value imported through `foreign import`, the expression
follows C promotion and operator rules instead; see
[Calling C](ffi.md).

## Lexical structure

Comments follow Lua's two forms: `--` runs to the end of the line, and long
comments `--[[ ... ]]` or `--[=[ ... ]=]` (with any matching count of `=`
signs) span multiple lines.

Identifiers match ASCII `[A-Za-z_][A-Za-z0-9_]*`. Titan reserves 38 keywords:

```text
and      as       break    case     catch    const    defer    do
else     elseif   end      false    finally  for      foreign  function
goto     if       import   in       interface is      local    nil
not      or       owned    raise    record   repeat   return   then
true     type     union    until    when     while
```

The five primitive type names—`boolean`, `integer`, `float`, `string`, and
`value`—are contextual identifiers, not reserved keywords. They name types in
type annotations and remain usable as ordinary variable, parameter, or field
names.

> **Reserved words as member names:** Local variables, parameters, `import`
> bindings, `for` binders, `case` local bindings, and bare expression names
> must not be reserved words. Top-level module declarations, record fields,
> union variants and payload parts, Interface members, dot and colon selectors
> (`entry.type`, `stream:end()`), named-call keys, and record constructor
> fields accept any ASCII identifier, including reserved words. For example,
> `response.type` and `range.end` are valid, whereas `local type = "http"` is
> a syntax error.

The complete lexical and syntactic grammar appears in
[Appendix C](grammar.md).

## Literals and basic types

Titan's six basic static types correspond directly to Lua's primitive values
plus `value` for dynamically typed slots:

| Type | Values | Notes |
| --- | --- | --- |
| `nil` | `nil` | Sole value of its type; represents absence |
| `boolean` | `true`, `false` | Only `nil` and `false` are falsy |
| `integer` | 64-bit signed integers | Exact two's-complement arithmetic |
| `float` | IEEE-754 64-bit floats | Distinct static type from `integer` |
| `string` | Immutable byte sequences | Byte-indexed; may contain embedded NULs |
| `value` | Any Lua-representable value | Checked dynamic slot; includes `nil` |

As in Lua, `nil` and `false` are the only falsy values; `0`, `0.0`, and `""`
are all truthy.

### Numbers

Numeric literals follow Lua's decimal and hexadecimal forms. A literal without
a decimal point or exponent is an `integer`; a decimal point or exponent makes
it a `float`:

```titan
function numbers(): float
    local mask = 0x1abcdef    -- hexadecimal integer
    local whole = 3.0         -- decimal float
    local half = .5           -- digits optional on either side: .5, 4.
    local tenth = 1.0e-1      -- decimal exponent
    local scaled = 0x1ap2     -- hexadecimal float: 26 * 2^2 = 104.0
    return (mask & 0xff) + whole + half + tenth + scaled
end
```

`10` has type `integer`; it converts to `float` implicitly only where a
`float` is expected (see [Type Aliases, Options, and Dynamic `value`](types.md)).
A numeric literal must end cleanly at a non-alphanumeric boundary:
`1337require`, `1e2e3`, and `1.2.3.4` are syntax errors.

### Strings

Short string literals are enclosed in `"` or `'`; either quote may appear
unescaped inside the other. A raw line break inside a short string is a syntax
error. Supported escape sequences are:

| Escape | Meaning |
| --- | --- |
| `\a` `\b` `\f` `\n` `\r` `\t` `\v` | Bell, backspace, form feed, newline, carriage return, tab, vertical tab |
| `\\` `\"` `\'` | Backslash, double quote, single quote |
| `\` followed by a line break | A newline character |
| `\ddd` | Byte with decimal value `ddd` (up to three digits, `< 256`, greedy: `"\12340"` is `"{"` then `"40"`) |
| `\xXX` | Byte with hexadecimal value `XX` (exactly two hex digits) |
| `\u{XXX}` | UTF-8 bytes for Unicode code point `XXX` (one or more hex digits, at most `0x10FFFF`) |
| `\z` | Skips the following run of whitespace, including line breaks |

Malformed escapes—decimal values of 256 or greater, `\x` without two hex
digits, `\u` above `0x10FFFF`, or unknown escape letters—are compile-time
syntax errors.

Long strings use `[[ ... ]]` or `[=[ ... ]=]` with any matching number of `=`
signs. Long strings perform no escape processing and discard one line break
immediately following the opening bracket:

```titan
function escapes(): string
    local tabbed = "col1\tcol2\n"
    local bytes = "\65\66\67" .. "\x41"        -- "ABCA"
    local snowman = "\u{2603}"                 -- three UTF-8 bytes
    local joined = "one \z
                    line"                      -- \z skips break and spaces
    local raw = [[verbatim: no \escapes, "quotes" fine]]
    return tabbed .. bytes .. snowman .. joined .. raw
end
```

## Operators and precedence

Operators follow Lua's precedences and associativities, with `as` and `is`
occupying one non-chaining level between multiplication and unary operators:

| Precedence | Operators | Associativity |
| --- | --- | --- |
| 1 (lowest) | `or` | Left |
| 2 | `and` | Left |
| 3 | `<` `>` `<=` `>=` `~=` `==` | Left |
| 4 | `\|` | Left |
| 5 | `~` (binary XOR) | Left |
| 6 | `&` | Left |
| 7 | `<<` `>>` | Left |
| 8 | `..` | Right |
| 9 | `+` `-` | Left |
| 10 | `*` `/` `//` `%` | Left |
| 11 | `as` `is` | Postfix on one unary expression; does not chain |
| 12 | `not` `#` `-` `~` (unary) | Prefix |
| 13 (highest) | `^` | Right |

Exponentiation `^` binds tighter than unary operators on its left, permits
unary operators on its right, and associates right-to-left: `-2 ^ 2 ^ 3`
parses as `-(2 ^ (2 ^ 3))` (`-256.0`), and `2 ^ -1` parses as `2 ^ (-1)`
(`0.5`).

`as` and `is` sit below unary operators and `^`, and above `*`, `/`, `//`,
and `%`; they attach to one expression on their left and parse a full type on
their right:

- `2 + v is integer` parses as `2 + (v is integer)`.
- `-v is integer` parses as `(-v) is integer`.
- `v ^ 2 as integer` parses as `(v ^ 2) as integer`, and `2 ^ -v as integer`
  parses as `(2 ^ (-v)) as integer`. To cast only the exponent, write
  `2 ^ (v as integer)`.
- Chaining requires parentheses: `(x as value) is float` is valid, while
  `x as value is float` and `v is integer ^ 2` are syntax errors.

Parentheses group subexpressions and perform single-value adjustment on calls,
varargs, and spreads: `(f())` keeps only the first result of a call (or
produces `nil` for a zero-return call), `(...)` selects the first variadic
argument or `nil` when absent, and parenthesized spreads such as `(...xs)`,
`(...xs[1, 2])`, and `(...[1, 2])` select their first element as `T?` or `nil`
if empty (see [Functions, Arguments, and Results](functions.md)). A bare slice
without `...`, such as `(xs[1, 2])`, is rejected because slices have no
standalone value.

## Arithmetic and bitwise operators

The arithmetic operators are `+`, `-`, `*`, `/`, `//`, `%`, `^`, and unary
`-`; the bitwise operators are `&`, `|`, `~`, `<<`, `>>`, and unary `~`:

- `+`, `-`, `*`, `//`, and `%` return `integer` when both operands are
  `integer`; if either operand is `float`, the other converts to `float` and
  the result is `float`.
- `/` and `^` always return `float`, converting `integer` operands (`6 / 3` is
  `2.0`).
- Bitwise operators and unary `~` always return `integer`. A `float` operand
  is checked at run time for an exact in-range integer value.
- Operands must be numeric. A `value` operand is a compile-time error until
  converted. Option-typed operands (`integer?`, `float?`) unwrap automatically
  and raise at run time if `nil`.

All arithmetic matches Lua bit-for-bit, even where C behaves differently:

- Integer overflow wraps in two's complement (`math.maxinteger + 1 ==
  math.mininteger`, and `-math.mininteger == math.mininteger`).
- Floor division `//` rounds toward negative infinity, with
  `math.mininteger // -1` wrapping to `math.mininteger`.
- Modulo `%` takes the sign of the divisor, preserving
  `m == n * (m // n) + (m % n)`, with `math.mininteger % -1 == 0`.
- Bitwise shifts are logical (zero-filling) and accept any integer count:
  negative counts shift in the opposite direction, and counts of magnitude 64
  or greater yield `0`.
- Exponentiation matches Lua's power semantics, including `x ^ 2.0 == x * x`.
- Integer `// 0` and `% 0` raise runtime errors; float division by zero
  produces IEEE-754 infinities or `NaN`.

```titan
function lua_arithmetic(): boolean
    if -10 // 3 ~= -4 then return false end
    if 10 % -3 ~= -2 then return false end
    if 1 << 100 ~= 0 then return false end
    if 4 >> -1 ~= 8 then return false end
    return true
end
```

## Relational and equality operators

### Relational: `<`, `>`, `<=`, `>=`

Relational operators accept either two numbers or two strings and return
`boolean`:

- **Numbers:** Mixed `integer` and `float` operands compare by **exact
  mathematical value**, without rounding the integer to `float`. For instance,
  `math.maxinteger < 2.0 ^ 63` is `true` and `(1 << 53) + 1 ~= 2.0 ^ 53` is
  `true`. Any comparison involving `NaN` is `false`.
- **Strings:** Byte-by-byte lexicographic order.

Option operands unwrap automatically (raising on `nil`). Comparing booleans,
`value`, containers, nominal types, or mismatched types with relational
operators is a compile-time error.

```titan
function in_bounds(count: integer, low: float, high: float): boolean
    return low <= count and count <= high
end
```

### Equality: `==` and `~=`

Equality compares operands of compatible types without implicit numeric
loss or container conversion:

- **Numbers:** Exact mathematical comparison across `integer` and `float`
  (no rounding). `x ~= x` is `true` when `x` is `NaN`.
- **Strings:** Byte-for-byte content equality.
- **Arrays, records, unions, Interfaces, and function values:** Object
  identity. Two distinct nominal types—including an Interface and its
  implementing record—are incomparable. Each conversion from a record or union
  to an Interface allocates a fresh wrapper, and callable shape adjustment may
  allocate a fresh wrapper (see
  [First-Class Functions and Closures](closures.md) and
  [Interfaces](interfaces.md)).
- **Maps:** Identity first; for distinct tables, Lua's `__eq` metamethod on
  the left operand (or the right if the left defines none) is called and
  interpreted by Lua truthiness. The same rule applies when comparing a Map
  with a `value` whose runtime value is a table.
- **Two `value` operands:** Raw equality, without invoking `__eq` even if
  both hold tables.
- **Options:** `T?` compares with `T` (evaluating to `false` when the option
  is `nil`) and with `nil` in either order. Comparing with `nil` distinguishes
  an absent `boolean?` from a present `false`.

Any other pair of types is a compile-time error.

```titan
function has_explicit_false(flag: boolean?): boolean
    return flag ~= nil and flag == false
end

function matches_name(names: {string}, index: integer, target: string): boolean
    return names[index] == target -- false when names[index] is nil
end
```

## `and`, `or`, and `not`

`not` accepts any type, applies Lua truthiness (only `nil`, `false`, and a C
`NULL` pointer are falsy), and returns `boolean`.

`and` and `or` short-circuit left-to-right: `and` skips its right operand when
the left is falsy, and `or` skips its right operand when the left is truthy.
Their result type follows the operands and surrounding context:

1. **Boolean context.** In an `if`/`while`/`repeat` condition, a `boolean`
   return, or a `boolean`-annotated sink, both operands convert by truthiness
   and the result is `boolean`.
2. **Statically truthy or falsy left operand.** Numbers, strings, Arrays,
   Maps, records, unions, and Interfaces are always truthy: `a and b` has the
   type of `b`, and `a or b` has the type of `a` (except when the right
   operand of `or` is `boolean`; see rule 6). A `nil` left operand flips both
   rules.
3. **Two `boolean` operands.** Both `a and b` and `a or b` have type `boolean`
   with Lua's exact value, so boolean chains infer `boolean` without
   annotations.
4. **Option defaulting with `or`.** With `x: T?` and `d: T`, `x or d` has type
   `T` (returning `x` if truthy, else `d`). With both operands of type `T?`,
   `x or y` has type `T?`, and chains such as `x or y or 0` yield `integer`.
   Because a present `false` in `boolean?` is falsy, `flag or true` returns
   `true` for both `nil` and `false`; use `flag == nil` when `false` must be
   preserved.
5. **`value` in `or`.** When either operand is `value` (and the left is not
   statically truthy), the result is `value`; with `b: boolean` and
   `v: value`, `b or v` returns `true` when `b` is `true` and `v` when `b` is
   `false`.
6. **`boolean` beside another type in `or`.** When one operand is `boolean`
   and the other is neither `boolean` nor `value`, both convert by truthiness
   to `boolean`. For `b: boolean` and `n: integer?` holding `5`, `false or n`
   produces `true`, and `1 or b` produces `true`.
7. **`and` with a `boolean`, Option, or `value` left operand.** Apart from two
   booleans, the result has the right operand's Option type (`T?`), and a
   falsy left operand produces `nil` rather than `false` (`b and 1.0` yields
   `nil` when `b` is `false`).
8. **Mismatched `or` operands.** Any other combination—such as `integer?`
   beside `string`—is a compile-time error.

Because `cond and a` yields `T?` and `T? or T` yields `T`, the Lua ternary
idiom `cond and a or b` works whenever `a` cannot be falsy:

```titan
function get_or_default(items: {integer}, index: integer, fallback: integer): integer
    return items[index] or fallback
end

function pick(use_first: boolean, first: integer, second: integer): integer
    return use_first and first or second
end

function is_alnum_byte(byte: integer): boolean
    local is_lower = byte >= 97 and byte <= 122
    local is_digit = byte >= 48 and byte <= 57
    return is_lower or is_digit
end
```

## Concatenation and length

### Concatenation: `..`

`..` joins strings and numbers (`integer` or `float`) into a `string`. Numbers
format exactly as in Lua's `tostring`; in particular, integral floats keep
`.0` (`"" .. 3.0 == "3.0"` and `1 .. 2 == "12"`). Chained `..` expressions
flatten into a single allocation, and literal chains fold at compile time.

Option operands unwrap automatically (raising on `nil`). Booleans, `nil`,
`value`, and compound types are rejected at compile time. Exceeding Lua's
maximum string length raises a runtime error.

### Length: `#`

`#` returns an `integer` for three operand families:

- **`string`:** length in bytes.
- **Array (`{T}`, `const { T }`, `const? { T }`):** deterministically the
  highest present positive index.
- **Exact `{integer: V}` Map:** invokes `__len` if the table's metatable
  defines one (requiring the metamethod to return an exact Lua integer), and
  otherwise returns a Lua table border.

Maps with other key types, `value`, and all other types are compile-time
errors.

```titan
function format_summary(label: string, words: {string}): string
    local bytes = 0
    for i = 1, #words do
        bytes = bytes + #(words[i] or "")
    end
    return label .. ": " .. #words .. " slots, " .. bytes .. " bytes"
end
```

## Explicit casts and type tests

`exp as T` explicitly converts `exp` to type `T`. `exp is T` evaluates `exp`
once and returns `boolean` reporting whether the matching `as T` conversion
would succeed, without raising on a type mismatch (errors raised while
evaluating `exp` still propagate). Neither operator narrows the static type of
a variable.

Both operators accept the same pairs of source and target types; any other
pair is a compile-time error. Core Titan casts include:

| From | To | Runtime check |
| --- | --- | --- |
| `integer` | `float` | Total (never fails) |
| `float` | `integer` | Checked (must be an exact in-range integer) |
| `T` or `nil` | `T?` | Total |
| `T?` | `T` | Checked (`o is T` is `false` only when `o` is `nil`) |
| Any Titan value | `value` | Total |
| `value` | Concrete `T` or `T?` | Broad dynamic conversion (see below) |
| Satisfying `R` | Interface `I` | Total (`r as I` makes a fresh wrapper; `r is I` allocates nothing) |
| Interface `I` or `I?` | Concrete `R` | Checked exact concrete type inside the wrapper |
| `{T}` | `const { T }` | Explicit shallow snapshot (or in-place freeze when unaliased) |
| `const? { T }` | `{T}` or `const { T }` | Checked exact mutable/const Array qualifier |
| Function `A` | Adjustable Function `B` | Total (`f as B` adjusts; `f is B` allocates nothing) |

Explicit `value as T` performs Lua-style **broad dynamic conversion**, which
is wider than an implicit `value -> T` assignment (see
[Type Aliases, Options, and Dynamic `value`](types.md)):

- `value as integer` accepts both Lua integers and exact in-range integral
  floats (`2.0`); `value is integer` returns `true` for both.
- `value as float` accepts either numeric representation.
- `value as boolean` applies Lua truthiness and never fails (`value is
  boolean` is always `true`).
- `value as function (...)` stores the boxed value and defers checking
  callability until the value is called (`value is function (...)` is always
  `true`).
- `value as T?` accepts `nil` first and otherwise converts to `T` (`value is
  boolean?` is always `true`).
- `value as I` accepts an existing `I` wrapper or a bare concrete value whose
  concrete-to-`I` conversion was compiled into an initialized module.

```titan
function unbox_integer(candidate: value): integer
    return candidate as integer -- accepts integers and exact integral floats
end

function inspect_value(candidate: value): string
    if candidate is integer then
        return "integer: " .. (candidate as integer)
    elseif candidate is string then
        return "string: " .. (candidate as string)
    end
    return "other"
end
```

Scalar conversions do not lift through compound types, and number-to-string
conversion happens only through `..`:

```text
-- compile error: cannot cast '{integer}' to '{float}'
local floats = ints as {float}

-- compile error: cannot cast 'function (): integer' to 'function (): float'
local g = f as function (): (float)

-- compile error: cannot cast 'function (): integer' to 'function (): integer?'
local h = f as function (): (integer?)

-- compile error: cannot cast 'integer' to 'string' (use "" .. count)
local text = count as string
```

For C numeric, pointer, `owned`, and string casts, see [Calling C](ffi.md).
The full type conversion table is collected in [Appendix C](grammar.md).

## Constructors and calls

Brace constructors `{ ... }` build Arrays, Maps, and records according to the
expected type and field syntax:

- **Arrays** take positional elements (`{1, 2, 3}`). Without context, the
  element type is inferred from the first element, and `{}` defaults to
  `{integer}`.
- **Maps** write keyed entries in brackets (`{ ["ana"] = 9.5 }`). An exact
  `{integer: V}` context also accepts all-positional entries (`{10, 20, 30}`),
  stored at keys `1`, `2`, `3`. The bare `name = value` syntax is for records,
  never for string-keyed Maps.
- **Records** write fields as `name = value` inside a context that names the
  record type (`local p: Point = { x = 1.0, y = 2.0 }`); omitted fields
  receive `nil` when their type accepts it. Fields may be separated by `,` or
  `;`, with an optional trailing separator.

Calls use parentheses (`f(a, b)`), single-string sugar (`greet "world"`), or
bare braces for direct [named calls](functions.md#named-calls)
(`clamp { upper = 10, number = 17, lower = 0 }`). To pass a brace constructor
as a single positional argument, keep the call parentheses:
`consume({ 1, 2 })` or `consume({ x = 1 })`.

A call in an operand position contributes its first result, and parentheses
`(f())` always request one value—including turning a zero-return call into a
single `nil`. Calling a `value` directly synthesizes a temporary positional
function signature from the supplied arguments and expected results:

```titan
record Point
    x: float
    y: float
end

local function log(message: string)
end

function constructor_and_call_examples(dynamic_fn: value): (float, value)
    local grades: {string: float} = { ["ana"] = 9.5, ["bia"] = 8.0 }
    local origin: Point = { x = 0.0, y = 0.0 }
    local ignored: value = (log("started"))     -- adjusts zero results to nil
    local doubled: float = dynamic_fn(2.5)      -- contextual call on value
    return origin.x + (grades["ana"] or 0.0) + doubled, ignored
end
```

For the full rules on calls, multiple returns, variadics, and spreads, see
[Chapter 4](functions.md); for first-class function values and lambdas, see
[Chapter 5](closures.md); for Arrays, Maps, records, and unions, see
[Chapters 6–8](arrays-maps.md).
