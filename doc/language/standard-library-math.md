# Mathematical standard library

The `math` standard module provides typed numeric functions, Lua 5.5's
xoshiro256** pseudo-random generator, and numeric-string conversion. It is one
of the qualified-only standard modules:

```titan
local math = import "titan.math"
```

Lua loads the same module with `require "titan.math"`. Loading it does not
replace Lua's global `math` table.

## Typed numeric surface

Titan keeps `integer` and `float` distinct and does not overload functions by
parameter type. Operations whose Lua result can dynamically switch between
integer and float therefore use an explicitly float-typed interface:

```titan
function abs(number: float): float
function acos(number: float): float
function asin(number: float): float
function atan(y: float, x: float?): float
function ceil(number: float): float
function cos(number: float): float
function deg(radians: float): float
function exp(number: float): float
function floor(number: float): float
function fmod(numerator: float, denominator: float): float
function frexp(number: float): (float, integer)
function ldexp(mantissa: float, exponent: integer): float
function log(number: float, base: float?): float
function log2(number: float): float
function log10(number: float): float
function max(first: float, ...: float): float
function min(first: float, ...: float): float
function modf(number: float): (float, float)
function rad(degrees: float): float
function sin(number: float): float
function sqrt(number: float): float
function tan(number: float): float

function tointeger(candidate: value): integer?
function ult(left: integer, right: integer): boolean

pi: float
huge: float
maxinteger: integer
mininteger: integer
```

An integer argument is accepted where a `float` is required through Titan's
ordinary integer-to-float coercion. Results from `abs`, `ceil`, `floor`,
`fmod`, `max`, `min`, and the integral result of `modf` are nevertheless
always floats. This is the principal difference from Lua's dynamically tagged
math API: Lua sometimes returns an integer from those operations. Keeping the
Titan signatures fixed avoids returning a `value` from every ordinary numeric
calculation.

`max` and `min` accept one or more numeric operands and return a float. They do
not accept arbitrary Lua values or invoke a `<` metamethod. Their comparison
order otherwise matches Lua: `max` replaces the current result only when it is
strictly below the next operand, and `min` replaces it only when the next
operand is strictly below it.

`ceil` and `floor` remain total for finite values outside Titan's integer
range because they return floats. `fmod` always uses C floating remainder,
including its NaN result for a zero denominator; it does not select Lua's
integer-only zero-denominator error. `modf` returns the integral part followed
by the fractional part, both as floats.

`atan` defaults `x` to `1.0`. `log` defaults to the natural logarithm. With an
explicit base it always computes `ln(number) / ln(base)`, including bases 2
and 10. Use `log2` or `log10` to call the corresponding faster C math-library
operation directly.
`frexp` returns a mantissa and integer exponent; `ldexp` reconstructs their
product. The `ldexp` exponent must fit the target C `int`, and raises Titan's
ordinary checked-FFI range error otherwise.

`ult` compares two integers as unsigned 64-bit values. Thus `ult(0, -1)` is
true and `ult(-1, 0)` is false.

The constants have the Lua 5.5 meanings: `pi` is pi, `huge` is positive
infinity, and `mininteger`/`maxinteger` bound Titan's 64-bit integer range.

`math.type` is intentionally absent. Titan already represents integer and
float as distinct static types, while its public dynamic numeric cast accepts
an exactly integral float as an integer. Implementing Lua's raw numeric-tag
query would require inspecting Lua internal values, contrary to this module's
direct-C, no-Lua-API boundary.

## Pseudo-random numbers

```titan
function random(lower: integer?, upper: integer?): value
function randomseed(first: integer?, second: integer?): (integer, integer)
```

`random` implements the same xoshiro256** state transition, float extraction,
and unbiased integer projection as Lua 5.5:

* `random()` returns a float in `[0, 1)`;
* `random(0)` returns an integer containing all 64 random bits;
* `random(upper)` returns an integer in `[1, upper]`;
* `random(lower, upper)` returns an integer in the inclusive interval.

The result type is `value` because the no-argument form returns a float and
the bounded forms return integers. A typed Titan caller casts according to the
form it used:

```titan
local unit = math.random() as float
local die = math.random(6) as integer
```

An empty interval raises `random interval is empty`. Supplying `upper` while
omitting `lower` raises `random lower limit is required`; as with other option
parameters, omission and an explicit nil are otherwise equivalent.

`randomseed(first, second)` resets the state and returns the two effective
components. `second` defaults to zero. Reusing the returned pair reproduces
the same sequence exactly, including sequences produced by Lua 5.5 on the same
64-bit configuration. Calling `randomseed()` makes a weak default seed from
the C wall and process-CPU clocks plus the preceding generator state. This is
not a cryptographic random-number generator. Supplying a second component
without a first raises.

Each loaded `titan.math` module has independent state. As with every Titan
module variable, separate Lua states do not share it.

## Numeric conversion

```titan
function tonumber(candidate: value, base: integer?): value?
function tointeger(candidate: value): integer?
```

With no base, `tonumber` returns an existing integer or float unchanged, so
its numeric representation is preserved without inspecting an internal Lua
tag. A string is validated over its exact byte length before conversion. It
accepts leading and trailing ASCII whitespace, an optional sign, decimal and
hexadecimal integers, decimal floats and exponents, and hexadecimal floats
with binary exponents. It rejects embedded NUL, trailing junk, `nan`, and
`inf`. Decimal integers are returned as integers when they fit; overflow and
written float syntax produce floats. Hexadecimal integer accumulation follows
Lua's 64-bit wrapping behavior.

With a base, `candidate` must be a string and `base` must be in `2..36`.
Digits are case-insensitive, surrounding ASCII whitespace and a sign are
accepted, and an invalid digit returns nil. Accumulation wraps over 64 bits in
the same way as Lua. An invalid base or a non-string base conversion raises.

The parser recognizes Lua's `.` decimal byte independently of the process
locale, then substitutes the active C locale byte only for the final validated
`strtod` call. It never passes unvalidated or NUL-containing input to C.

`tointeger` returns an integer for an integer, an exactly integral in-range
float, or a numeric string with such a value. Every other value returns nil.
