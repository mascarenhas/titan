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
  error if they are nil (but see the option limitation under
  *Comparisons* below).

*Limitation:* `%` between floats typechecks but is not implemented: the
compiler aborts during code generation with an internal
`not implemented yet` error. Only all-integer `%` works. This is listed
among the [known limitations](index.md#status-and-limitations).

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
logical (zero-fill), as in Lua.

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

* **Numbers** compare across `integer`/`float` with Lua's numeric
  equality (the integer side is promoted to float).
* **Strings** compare by content for ordinary (short) strings — but see
  the limitation below.
* **Arrays, maps and records** compare by identity, exactly like Lua's
  raw table and userdata equality; metamethods are never involved.
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

The relational operators accept two numbers (mixing `integer` and
`float` promotes to float) or two strings. Everything else — booleans,
`value`, arrays, maps, records, mixed types — is a compile-time error
(`left/right hand side of relational expression is a ... instead of a
number`, or `trying to use relational expression with ...`).

```lua
function in_range(x: integer, lo: float, hi: float): boolean
    return lo <= x and x <= hi    -- x promoted to float on each side
end
```

*Limitation:* the current compiler compiles string comparisons to
pointer comparisons. For `==` this is right for short strings (Lua
interns strings up to 40 bytes) but two separately created equal *long*
strings can compare unequal; for `<` the result is not lexicographic
order at all. Do not rely on either for long strings or ordering.

*Limitation:* an option-typed operand of a relational or arithmetic
operator is implicitly unwrapped, which works when the operand is an
array or map access (`t[i] + 1`, `t1[1] ~= t2[1]`), but a plain
option-typed *variable* in that position currently aborts the compiler
with an internal error. Unwrap through `or` defaulting instead (see
[option types](option-types.md)).

## `and`, `or` and `not`

`not` accepts an operand of any type and produces a `boolean`: the
operand is tested for truthiness (only `nil` and `false` are false; an
option is false when it is nil — and a `boolean?` also when it holds
`false`). The one exception is foreign pointer types, whose truthiness
tests crash the compiler — see [the C FFI](ffi.md).

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
  `false`, when `c` holds `false`. (A plain `boolean` left operand
  typechecks the same way but trips the codegen limitation below, so
  the nil-not-false behavior is only observable through option and
  `value` operands.)
* Any other combination in `or` is the compile-time error
  `left hand side of 'or' is a T1 but right hand side is a T2`.

The Lua ternary idiom `cond and a or b` works as expected when `a`
cannot be falsy *and* `cond` is an option or a `value`; with a
`boolean`-typed condition — a comparison, say — the nested `and` trips
the limitation below and the module fails to compile.

*Limitation:* the boolean context reaches only the *outermost*
`and`/`or` — their operands are typechecked without it. For `or` this is
harmless (an `or` with a boolean on either side is treated as boolean
anyway), but an `and` whose left operand is boolean-typed and which does
not itself see the boolean context — because it is used for its value,
or sits nested inside a longer chain — generates invalid C in the
current compiler. Concretely: `x == 1 and y == 2` works as a condition,
as do `or` chains and `and` chains over never-falsy operands, but the
three-clause `x == 1 and y == 2 and z == 3` fails to compile, as do
`return b and x` with `b: boolean` and the ternary `x == 1 and a or b`.
Split long conjunctions into nested `if`s for now.

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
cast it to `string` first). Option operands are implicitly unwrapped
when they are array or map accesses; a plain option-typed *variable*
operand aborts the compiler with an internal error, as under
*Comparisons*.

## Length: `#`

`#` accepts an array or a string and produces an `integer`. On a string
it is the length in bytes; on an array it is the table length, with
Lua's usual border semantics if you have created nil holes (see
[arrays and maps](arrays-maps.md)). Taking the length of anything else,
**including a map**, is the compile-time error
`trying to take the length of a ... instead of an array or string`.

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
| any type (including options) | `value` | never |
| `value` | any type (including options) | yes — checked |
| void pointer (FFI) | `string` | no run-time check |

A `value` cast to a concrete type is checked at run time and raises an
error of the shape `file:line:col: type error, expected T but found U`
on mismatch. Casting a `value` holding a float to `integer` accepts
exact integral values and raises
`... number '2.5' has no integer representation` otherwise. Casts *to*
`value`, and from `value` *to* `boolean`, never fail — any value
converts. The void-pointer row belongs to the FFI; see
[the C FFI](ffi.md).

```lua
function unbox(v: value): integer
    return v as integer        -- run-time checked
end

function box(n: integer): value
    return n as value          -- never fails
end
```

Everything else is the compile-time error `cannot cast 'T1' to 'T2'` —
in the current compiler all of these are rejected:

```lua
function rejected(i: integer, x: float, o: integer?)
    local a = i as float       -- cannot cast 'integer' to 'float'
    local b = x as integer     -- cannot cast 'float' to 'integer'
    local c = o as integer     -- cannot cast 'integer?' to 'integer'
    local d = i as integer?    -- cannot cast 'integer' to 'integer?'
    local e = i as integer     -- cannot cast 'integer' to 'integer'
end
```

Use the implicit coercions instead: `local a: float = i` converts, and
`local b: integer = x` converts with the run-time exactness check. If
you genuinely need an explicit two-step conversion, going through
`value` works: `(i as value) as float`.

## Constructor expressions

The brace constructor `{ ... }` builds arrays, maps and records. Which
one it builds is decided by the **context** — the type the surrounding
position expects — and, failing that, by the shape of the first field:

* **Array**: positional fields only. With no context, a constructor with
  positional fields is an array whose element type is inferred from the
  first element, and the empty `{}` defaults to `{integer}`.
* **Map**: every key must be written **in brackets** — `[k] = v`. The
  `name = v` form is *never* a map entry, even for string-keyed maps:
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
    local p: Point = { x = 1.0, y = 2.0 }
    return p.x + (grades["ana"] or 0.0)
end
```

Fields are separated by `,` or `;` interchangeably, and a trailing
separator is allowed. A multiple-return call as the *last* positional
element of an array constructor expands into all of its values; in any
other position it contributes only its first value, and in a map
constructor's value position extra return values are dropped. See
[arrays and maps](arrays-maps.md) and [records](records.md) for the full
story on each constructor, including what `nil` elements mean.

## Calls in expressions

Function calls, method calls and record-static calls are expressions.
The callable things are module-level functions (local or imported),
record methods (`r:move(...)`), and record static functions
(`Point.new(...)`); Titan has no first-class function values yet, so
calling through a variable or parameter is the compile-time error
`first-class functions are not supported in this version of Titan`.
Arity is strict at compile time: the wrong number of arguments is the
compile-time error `function 'f' called with N arguments but expects M`
— no Lua-style padding with nil, no dropping of extras. (Calls coming
*from* Lua are checked at run time instead; see
[Lua interoperability](lua-interop.md).)

Lua's call sugar works — a single string or constructor argument needs
no parentheses:

```lua
function greet(name: string): string return "hello " .. name end
function sugar(): string return greet "world" end
```

A call used as an operand contributes its **first** return value. A
multiple-return call in the *last* position of an argument list, array
constructor, multiple assignment or `return` expands into all of its
values; wrapping the call in parentheses adjusts it to exactly one
value, as in Lua:

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

*Limitation:* the argument-list position currently miscompiles: with a
three-parameter `add3`, `add3(10, divmod(7, 2))` passes the arity check
(the call counts as two arguments) but the generated C reads the extra
return values before the call has produced them, so every value after
the first arrives as `0`/garbage. The same happens to a `return` whose
expression list is *just* the multi-return call: `return divmod(13, 2)`
from a `(integer, integer)` function returns `6, 0`. Route the values
through a multiple assignment instead. The array-constructor and
multiple-assignment positions work, as does a `return` that mixes the
call with other expressions (`return 10, divmod(13, 2)`).

See [functions](functions.md) for multiple returns in full, and
[statements](statements.md) for calls as statements.
