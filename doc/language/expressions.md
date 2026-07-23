# Expressions

Titan's expressions look like Lua's: the same literals, the same
operators with the same precedences, the same `and`/`or`/`not`, the same
table-constructor syntax. The differences are the ones static typing
demands — every expression has a type, a few operators are restricted to
the types where they make sense, and Titan adds one operator of its own,
the explicit cast `as`. Where this chapter says an operation "matches
Lua", it means bit-for-bit (upstream PR #216): reproducing Lua's
arithmetic exactly, even where C's operators disagree, is a stated
design principle (see [the design philosophy](philosophy.md)).

## Literals

### nil and booleans

`nil` is the sole value of type `nil`; `true` and `false` are the
`boolean` literals. As in Lua, `nil` and `false` are the only falsy
values — `0`, `0.0` and `""` are all true in conditions.

### Numbers

Numeric literals follow Lua's syntax, including hexadecimal integers and
hexadecimal floats. A literal is an `integer` if its value is an integer
in Lua's sense, and a `float` otherwise — a decimal point or an exponent
makes it a float:

```lua
function numbers(): float
    local a: integer = 0x1abcdef    -- hexadecimal integer
    local b: float = 3.0
    local c: float = .5             -- digits optional on either side: .5, 4.
    local d: float = 1.0e-1         -- decimal exponent
    local e: float = 0x1ap2         -- hex float: 26 * 2^2 = 104.0
    return b + c + d + e
end
```

`10` is always an `integer`; it becomes a float only through implicit
coercion where the context expects one (see [the type system](types.md)).
A numeral must end where the digits end: like Lua, Titan rejects
`1337require`, `1e2e3` and `1.2.3.4`, with the syntax error
`Malformed number.`

### Strings

Short string literals are delimited by `"` or `'`; either kind may
contain the other quote freely. A literal newline inside a short string
is a syntax error (use an escape or a long string). The full escape list:

| Escape | Meaning |
| --- | --- |
| `\a` `\b` `\f` `\n` `\r` `\t` `\v` | bell, backspace, form feed, newline, carriage return, tab, vertical tab |
| `\\` `\"` `\'` | backslash, double quote, single quote |
| `\` followed by a real line break | a newline in the string |
| `\ddd` | the byte with decimal value `ddd` — up to three digits, value < 256, taken greedily: `"\12340"` is `{` followed by `40` |
| `\xXX` | the byte with hexadecimal value `XX` (exactly two digits) |
| `\u{XXX}` | the UTF-8 encoding of code point `XXX` (one or more hex digits, at most `10FFFF`) |
| `\z` | skips the following run of whitespace, including line breaks |

Any malformed escape is a compile-time syntax error: a decimal escape of
256 or more (`Decimal escape too large`), a `\x` without exactly two hex
digits, a `\u` naming a code point above `0x10FFFF` (Titan enforces the
real Unicode range, where Lua 5.5 accepts up to `0x7FFFFFFF`), or an
unknown escape character (`Invalid escape character in string.`).

Long strings work exactly as in Lua: `[[ ... ]]`, or `[=[ ... ]=]` with
any matching count of `=` signs to allow `]]` inside. No escape
processing happens inside a long string, and one line break immediately
after the opening bracket is skipped.

```lua
function escapes(): string
    local s1: string = "col1\tcol2\n"
    local s2: string = "\65\66\67" .. "\x41"   -- "ABCA"
    local s3: string = "\u{2603}"              -- a snowman, three UTF-8 bytes
    local s4: string = "one \z
                        line"                  -- \z eats the break and indent
    local s5: string = [[verbatim: no \escapes, "quotes" fine]]
    return s1 .. s2 .. s3 .. s4 .. s5
end
```

## Operators and precedence

Titan implements Lua's operator set with Lua's precedences and
associativities, plus the cast operator `as`, which binds tighter than
everything else:

| Precedence | Operators | Associativity |
| --- | --- | --- |
| 1 (lowest) | `or` | left |
| 2 | `and` | left |
| 3 | `<` `>` `<=` `>=` `~=` `==` | left |
| 4 | `\|` | left |
| 5 | `~` (binary, exclusive or) | left |
| 6 | `&` | left |
| 7 | `<<` `>>` | left |
| 8 | `..` | right |
| 9 | `+` `-` | left |
| 10 | `*` `/` `//` `%` | left |
| 11 | `not` `#` `-` `~` (unary) | prefix |
| 12 | `^` | right |
| 13 (highest) | `as` | does not chain |

As in Lua, `^` binds tighter than the unary operators on its *left*,
its right operand may itself start with unary operators, and it
associates to the right: `-2 ^ 2 ^ 3` means `-(2 ^ (2 ^ 3))`, that is
`-256.0`, and `2 ^ -1` is legal (`0.5`).

`as` applies to the single primary expression on its left and consumes a
full type, so `2 + v as integer` means `2 + (v as integer)`. A cast
cannot be chained directly — `v as value as float` is a syntax error —
but a parenthesized cast is an ordinary expression, so
`(x as value) as float` parses (see [Explicit casts](#explicit-casts-as)).

Parentheses group, as usual, with one extra meaning: parentheses around
a *call* truncate it to its first value (see
[Calls in expressions](#calls-in-expressions)); around anything else
they change nothing.

## Arithmetic

The arithmetic operators are `+ - * / // % ^` and unary `-`; the bitwise
operators are `& | ~ << >>` and unary `~`. Their typing rules:

* `+`, `-`, `*`, `%`, `//`: if both operands are `integer`, the result
  is `integer`; if either is `float`, the other is implicitly converted
  and the result is `float`.
* `/` and `^` are **always float**: integer operands are converted, and
  the result is `float` even for `6 / 3`.
* The bitwise operators and unary `~` are **always integer**: `float`
  operands are converted to `integer` (a run-time check — the float must
  have an exact integer value), and the result is `integer`.
* Operands must be numbers. Using a `value` in arithmetic is a
  compile-time error (`... is a value instead of a number`) — cast it
  first. Option-typed operands are implicitly unwrapped, with a run-time
  error if they are nil.

### Lua-faithful results

Titan guarantees exactly Lua's arithmetic results, including where C's
native operators differ: integer overflow wraps around two's-complement
style (`math.maxinteger + 1` is `math.mininteger`, and unary minus of
`math.mininteger` is `math.mininteger`); floor division `//` rounds
toward minus infinity, with `math.mininteger // -1` wrapping; `%` is
Lua's modulo, taking the sign of the divisor and preserving
`m == n * (m // n) + (m % n)`, with `math.mininteger % -1` equal to `0`;
and shift amounts can be any integer — negative amounts shift the other
way, amounts at or beyond the 64-bit width yield `0`, and shifts are
logical (zero-fill), as in Lua. Exponentiation `^` reproduces Lua's
`luai_numpow`, including that `x ^ 2.0` is computed as `x * x` (not
`pow(x, 2)`), so its result matches Lua's to the last bit.

```lua
function lua_not_c(): boolean
    if -10 // 3 ~= -4 then return false end  -- C's '/' would give -3
    if 10 % -3 ~= -2 then return false end   -- C's '%' would give 1
    if 1 << 100 ~= 0 then return false end   -- C: undefined behavior
    if 4 >> -1 ~= 8 then return false end    -- C: undefined behavior
    return true
end
```

Integer `//` and `%` by zero raise run-time errors, as in Lua
(`error at line N, divide by zero`, `error at line N, % by zero`).
Float division by zero does not raise; it follows IEEE floating-point
rules (infinities and NaN), as in Lua.

## Comparisons

### Equality: `==` and `~=`

Equality is defined between operands of the same type, and across a few
type pairs:

* **Numbers** compare across `integer`/`float` by **mathematical
  value**, with *no* promotion of the integer to float — exactly Lua's
  numeric equality. An `integer` and a `float` are equal only when they
  denote the same mathematical value, so the float side never loses the
  integer to rounding. In particular `math.maxinteger == 2.0^63` is
  **false** (and `math.maxinteger < 2.0^63` is **true**), because
  `math.maxinteger` (2^63 − 1) is *not* promoted to the float 2^63;
  likewise `(1 << 53) + 1 ~= 2.0^53`. NaN follows IEEE 754, as in Lua:
  any comparison with NaN is false, so `x ~= x` is true when `x` is NaN.
* **Strings** compare by content (lexicographically for the relational
  operators), exactly as in Lua.
* **Arrays, maps and records** compare by identity. Arrays and records use
  canonical userdata identities; maps use ordinary table identities.
  Metamethods are never involved.
* **Two `value`s** (or a `value` and anything else, which is promoted to
  `value`) compare with Lua's *raw* equality — `__eq` metamethods on
  tables that arrived from Lua are not consulted.
* **An option and its base type** can be compared: `s1 == s2` works for
  `s1: string?`, `s2: string`, and is false when `s1` is nil. See
  [option types](option-types.md).

Anything else is the compile-time error
`trying to compare values of incomparable types: T1 and T2`. Notably,
**comparing an option against the `nil` literal is rejected** — the
idiomatic nil test in Titan is truthiness:

```lua
function found(t: {integer}, i: integer): boolean
    -- not (t[i] == nil): that is a compile-time error.
    if t[i] then return true else return false end
end
```

### Relational: `<` `>` `<=` `>=`

The relational operators accept two numbers (a mixed `integer`/`float`
comparison compares mathematical values exactly, with *no* promotion of
the integer to float — matching Lua) or two strings. Everything else — booleans,
`value`, arrays, maps, records, mixed types — is a compile-time error
(`left/right hand side of relational expression is a ... instead of a
number`, or `trying to use relational expression with ...`).

```lua
function in_range(x: integer, lo: float, hi: float): boolean
    return lo <= x and x <= hi    -- x compared to each float bound by exact mathematical value (no promotion)
end
```

String comparisons are by content: `==` and `~=` test byte-for-byte
equality regardless of length, and `<` `<=` `>` `>=` order strings
lexicographically, exactly as in Lua.

## `and`, `or` and `not`

`not` accepts an operand of any type and produces a `boolean`: the
operand is tested for truthiness (only `nil` and `false` are false; an
option is false when it is nil — and a `boolean?` also when it holds
`false`; a foreign pointer is false when it is NULL).

`and` and `or` keep Lua's value-returning, short-circuiting semantics,
and the static type of the result depends on what the checker knows:

* **Boolean context.** When the surrounding context expects a `boolean`
  (a condition of `if`/`while`/`repeat`, a `boolean` return type, a
  `boolean`-annotated variable), both operands are implicitly converted
  to `boolean` and the result is `boolean`, whatever the operand types.
* **Statically truthy/falsy left operand.** Integers, floats, strings,
  arrays, maps and records can never be falsy, so for these `a and b`
  has the type of `b`, and `a or b` the type of `a` (the right side is
  dead); a `nil` left operand flips both rules. At run time this is
  Lua's behavior: with two integers, `a and b` returns `b` and
  `a or b` returns `a`.
* **`or` defaulting.** `x or d` where `x: t?` and `d: t` has type `t`:
  the option is unwrapped if non-nil, the default used otherwise. This
  is the main idiom for reading containers — see
  [option types](option-types.md):

  ```lua
  function get(t: {integer}, i: integer, default: integer): integer
      return t[i] or default
  end
  ```
* **`value` operands.** `x or v` and `v or x` where either side is a
  `value` produce a `value`. With `and`, a left operand that is a
  `boolean`, option, or `value` makes the result the right operand's
  type marked optional (`b and f` with `f: float` has type `float?`);
  in that case a falsy left operand makes the whole `and` evaluate to
  `nil` at run time — even when the falsy value was `false`, where Lua
  would produce `false`: with `c: value`, `c and a` returns `nil`, not
  `false`, when `c` holds `false`. A plain `boolean` left operand
  typechecks and behaves the same way.
* Any other combination in `or` is the compile-time error
  `left hand side of 'or' is a T1 but right hand side is a T2`.

The Lua ternary idiom `cond and a or b` works as expected when `a`
cannot be falsy, including with a `boolean`-typed condition — a
comparison, say:

```lua
function pick(use_first: boolean, a: integer, b: integer): integer
    return use_first and a or b
end
```

Long all-boolean `and`/`or` chains and `and`/`or` used for their value —
`x == 1 and y == 2 and z == 3` as a condition, `return b and x` with
`b: boolean` — compile and run as expected.

## Concatenation: `..`

`..` produces a `string`. Operands may be strings, integers or floats;
numbers are converted with exactly Lua's `tostring` formatting — in
particular, integral floats keep their `.0`:

```lua
function describe(name: string, n: integer, x: float): string
    return name .. ": " .. n .. " of " .. x
end
-- "" .. 3.0  == "3.0"    (not "3")
-- 1 .. 2     == "12"
```

A chain of `..` is flattened into a single n-ary concatenation, so
`a .. b .. c .. d` allocates one result string, not three; when all
operands are literals the compiler folds them into a single string
constant at parse time. Concatenating anything else — booleans, `nil`,
arrays, maps, records — is a compile-time error
(`cannot concatenate with boolean value`, etc.), as is concatenating a
`value` directly (`cannot concatenate with value of type 'value'` —
cast it to `string` first). Option operands are implicitly unwrapped,
with a run-time error if they are nil.

## Length: `#`

`#` accepts an array, an exact integer-keyed map, or a string and produces an
`integer`. On a string it is the length in bytes. On an Array it is
deterministically the highest present positive index, so deleting a middle
element does not shorten it while deleting the last present element does. On
an exact `{integer: V}` Map it uses Lua's ordinary table-border result; for a
holed Map any valid border may be selected. See
[arrays and maps](arrays-maps.md). Other Map key types and other values are
compile-time errors.

```lua
function total_len(words: {string}): integer
    local n: integer = 0
    for i = 1, #words do
        n = n + #(words[i] or "")
    end
    return n
end
```

## Explicit casts: `as`

The cast expression `exp as type` converts a value to another type. It
binds tighter than every operator and does not chain (parenthesize for
two steps). In Titan, ordinary conversions — `integer` to `float`, a
type to and from its option, anything to `boolean` in a condition —
happen *implicitly* wherever a typed context calls for them (see
[the type system](types.md)). `as` is **not** for those; the casts the
checker accepts are deliberately few:

| From | To | Can fail at run time? |
| --- | --- | --- |
| option `T?` | base `T` | yes — checked (raises on `nil`) |
| any type (including options) | `value` | never |
| `value` | any type (including options) | yes — checked |
| C integer | `integer` | no |
| C float | `float` | no |
| `integer` | C integer | no |
| `integer` or `float` | C float | no |
| C numeric type | another C numeric type | no |
| C `char *` or `void *` (FFI) | `string` | yes — raises on `NULL` |
| `string` | C `char *` or `void *` (FFI) | no |
| C integer, C float, ordinary C pointer, C array-as-pointer, or owned C userdata | `value` | never — ordinary pointers become lightuserdata; owned objects stay full userdata |
| `value` | C integer, C float, ordinary C pointer, C array-as-pointer, or owned C userdata | yes — checked |
| Lua-internal `Udata *` | `value` | never — non-NULL becomes that same full userdata; NULL becomes nil |
| `value` | Lua-internal `Udata *` | yes — accepts full userdata or nil, not lightuserdata |
| C `TValue` | `value` | no |
| `value` | C `TValue` | no |

A `value` cast to a concrete type is checked at run time and raises an
error of the shape `file:line:col: type error, expected T but found U`
on mismatch. Casting a `value` holding a float to `integer` accepts
exact integral values and raises
`... number '2.5' has no integer representation` otherwise. Casts *to*
`value`, and from `value` *to* `boolean`, never fail — any value
converts. An option cast `o as T` unwraps the option, raising
`expected T but found nil` when `o` is `nil` (the explicit form of the
implicit option unwrap; see [option types](option-types.md)). The C rows belong
to the FFI; see [the C FFI](ffi.md).

```lua
function unbox(v: value): integer
    return v as integer        -- run-time checked
end

function box(n: integer): value
    return n as value          -- never fails
end

function unwrap(o: integer?): integer
    return o as integer        -- unwraps; raises if o is nil
end
```

For non-FFI types, other casts are the compile-time error
`cannot cast 'T1' to 'T2'` — in the current compiler all of these are rejected:

```lua
function rejected(i: integer, x: float)
    local a = i as float       -- cannot cast 'integer' to 'float'
    local b = x as integer     -- cannot cast 'float' to 'integer'
    local d = i as integer?    -- cannot cast 'integer' to 'integer?'
    local e = i as integer     -- cannot cast 'integer' to 'integer'
end
```

Use the implicit coercions instead: `local a: float = i` converts, and
`local b: integer = x` converts with the run-time exactness check. If
you genuinely need an explicit two-step conversion, going through
`value` works: `(i as value) as float`. For an expression whose imported C type
is, say, `c.size_t`, use the ordinary FFI cast: `n as integer`.

## Constructor expressions

The brace constructor `{ ... }` builds arrays, maps and records. Which
one it builds is decided by the **context** — the type the surrounding
position expects — and, failing that, by the shape of the first field:

* **Array**: positional fields only. With no context, a constructor with
  positional fields is an array whose element type is inferred from the
  first element, and the empty `{}` defaults to `{integer}`.
* **Map**: computed entries write their key **in brackets** — `[k] = v`.
  An exact integer-keyed Map may instead use an all-positional constructor;
  its first value is stored at key 1, its second at key 2, and so on. The
  two forms cannot be mixed. The `name = v` form is *never* a map entry,
  even for string-keyed maps:
  `{ x = 10 }` in a `{string: integer}` context is the compile-time
  error `initializing field 'x' when expecting map`; write
  `{ ["x"] = 10 }`.
* **Record**: every field must be written as `name = v`, every field of
  the record must be present, and the constructor must appear in a
  context that names the record type (without one it is the compile-time
  error `no context to provide type for record constructor`).

```lua
record Point
    x: float
    y: float
end

function constructors(): float
    local xs: {integer} = {1, 2, 3}
    local empty = {}                                 -- {integer}
    local grades: {string: float} = { ["ana"] = 9.5, ["bia"] = 8.0 }
    local counts: {integer: integer} = {10, 20, 30}
    local p: Point = { x = 1.0, y = 2.0 }
    return p.x + (grades["ana"] or 0.0)
end
```

Fields are separated by `,` or `;` interchangeably, and a trailing
separator is allowed. A call as the *last* positional element of an Array or
exact integer-keyed Map constructor is an open result sink: it contributes all
statically visible fixed results and, when declared, the complete run-time
[flexible tail](flexible-returns.md). In any other position a call contributes
one value, and in a computed Map or record field position surplus results are
dropped.
See
[arrays and maps](arrays-maps.md) and [records](records.md) for the full
story on each constructor, including what `nil` elements mean.

## Function values

Functions are first-class values in Titan. **Referencing a function name
is an expression** that yields a function value of the corresponding
[function type](types.md#function-types): a top-level or `local`
function name, an imported `mod.f`, and a record function like `Rec.new`
all denote values you can store in a variable, pass as an argument,
return, and call. The conversion between a function value and `value` is
implicit: a function flows into a `value` for free, and a `value` flows
back into a function type with the callability check deferred to the
actual call.

```lua
function inc(n: integer): integer return n + 1 end

function apply(f: (integer) -> integer, x: integer): integer
    return f(x)               -- call a function value
end

function use(): integer
    local g: (integer) -> integer = inc   -- a function name is a value
    return apply(g, 41)                    -- pass it along: 42
end
```

Indexing an array or map of functions yields an *option* (`T?`), like any
container read, and that option is auto-unwrapped when the result is
called directly — `arr[i](x)` works, raising cleanly if the slot is nil
(see [option types](option-types.md)).

## Calls in expressions

Function calls, method calls and record-function calls are expressions, and
so is calling a function value. The callable things are module-level
functions (local or imported), record methods (`r:move(...)`), record
functions (`Point.new(...)`, `Point.origin(...)`), and any function value held in a
variable, parameter, field, or container slot.
For Titan functions, too few positional arguments are padded with `nil` and
then type-checked against the missing formals. Surplus argument expressions
are evaluated, but a non-variadic Titan function ignores their values; a
variadic one receives them in its tail. Direct C calls made with parentheses
keep strict C arity. Calls coming *from* Lua are adjusted and checked at run
time instead; see
[Functions](functions.md#argument-adjustment) and
[Lua interoperability](lua-interop.md).

A bare string retains Lua-style one-argument call sugar:

```lua
function greet(name: string): string return "hello " .. name end
function sugar(): string return greet "world" end
```

Bare braces instead select Titan's [named-argument](named-arguments.md) form:
`move { dy = 2, dx = 1 }` maps labels to a direct declaration. To pass a
constructor as one positional argument, enclose it in the call parentheses:
`consume({ x = 1 })`, `consume({ 1, 2 })`, or `consume({})`.

A call used as an operand contributes its **first requested** result. A call in
the *last* position of an expression list may expand to fill the consumer's
remaining finite slots. A variadic argument tail, flexible `return` tail, or
final positional Array/exact integer-Map field is open and consumes the
complete visible run instead.
Wrapping the call in parentheses always requests exactly one value, as in Lua:

```lua
function divmod(a: integer, b: integer): (integer, integer)
    return a // b, a % b
end

function use(): integer
    local q, r = divmod(7, 2)     -- both values: q = 3, r = 1
    local just_q = (divmod(7, 2)) -- parentheses keep only the first
    return q + r + just_q
end
```

When a finite request reaches into a declared `...: T` result tail, each such
position has type `T?`, because that result may be absent. Open sinks receive
only the `T` values that actually exist. See
[Flexible returns](flexible-returns.md) for projection, forwarding, and the
last-position rule.

A callee whose static type is `value` is also callable. Titan synthesizes a
temporary positional function type from the supplied arguments and the results
requested by the surrounding context, then performs the ordinary run-time
callability and boundary checks. Named braces remain unavailable because a
`value` carries no formal parameter names:

```lua
function apply_dynamic(f: value, x: integer): integer
    return f(x)       -- context treats f as (integer) -> integer
end
```

The same parentheses-adjust rule rescues a **zero-return** call. An
unannotated function returns nothing (its type is `(...) -> ()`; see
[the type system](types.md#function-types)), and using such a call where
a value is expected is a compile-time error — *except* when wrapped in
parentheses, which adjust the empty result up to a single `nil`:

```lua
function log(s: string) end       -- returns nothing: (string) -> ()

function use_log(): value
    -- local x = log("hi")        -- error: call returns no value
    local x = (log("hi"))         -- (f()) adjusts up to a single nil
    return x
end
```

See [functions](functions.md) for multiple returns in full, and
[statements](statements.md) for calls as statements.
