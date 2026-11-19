# Mathematical standard library

The `math` standard module provides float-typed mathematical functions,
unsigned integer comparison, Lua 5.5's xoshiro256** pseudo-random number
generator, and numeral parsing. Titan imports it with
`local math = import "math"` (parser sugar for `import "titan.math"`); Lua
loads the same module with `require "titan.math"`.

**Target availability:** Native & Browser (complete). Loading `titan.math` does
not replace Lua's global `math` table.

## Example

The following module parses numeric text inputs with `math.tonumber`, computes
summary statistics using `math.min`, `math.max`, and `math.sqrt`, and draws a
reproducible bootstrap sample using `math.randomseed` and `math.random`:

```titan
local math = import "math"

record Stats
  count: integer
  minimum: float
  maximum: float
  mean: float
  stddev: float
end

function summarize(inputs: {string}): Stats?
  local samples: {float} = {}
  local sum = 0.0
  local low = math.huge
  local high = -math.huge

  for i = 1, #inputs do
    local parsed? = math.tonumber(inputs[i])
    if parsed ~= nil then
      local x = parsed as float
      samples[#samples + 1] = x
      sum = sum + x
      low = math.min(low, x)
      high = math.max(high, x)
    end
  end

  if #samples == 0 then return nil end
  local mean = sum / #samples
  local variance = 0.0
  for i = 1, #samples do
    local delta = samples[i] - mean
    variance = variance + delta * delta
  end
  return Stats(#samples, low, high, mean, math.sqrt(variance / #samples))
end

function roll_dice(seed: integer, rolls: integer): {integer}
  math.randomseed(seed)
  local results: {integer} = {}
  for i = 1, rolls do
    results[i] = math.random(6) as integer
  end
  return results
end
```

## Constants and numeric types

```text
pi: float
huge: float
const maxinteger: integer
const mininteger: integer
```

- `pi` is the circle constant π as a `float`.
- `huge` is positive floating-point infinity (`+inf`).
- `maxinteger` (`2^63 - 1`) and `mininteger` (`-2^63`) are read-only
  64-bit integer bounds on both native and browser targets. Assigning to them
  is a compile-time error in Titan and raises an error from Lua.

Titan keeps `integer` and `float` statically distinct. Integer arguments coerce
implicitly to `float` parameters, and functions such as `abs`, `ceil`, `floor`,
`fmod`, `max`, `min`, and `modf` always return `float` rather than switching
dynamically between integer and float. To test or convert a dynamic `value`,
use Titan's `is integer` / `as integer` operators (there is no `math.type`).

## Trigonometry and exponentials

```text
function sin(number: float): float
function cos(number: float): float
function tan(number: float): float
function asin(number: float): float
function acos(number: float): float
function atan(y: float, x: float?): float
function deg(radians: float): float
function rad(degrees: float): float

function exp(number: float): float
function log(number: float, base: float?): float
function log2(number: float): float
function log10(number: float): float
function sqrt(number: float): float
```

- `sin`, `cos`, `tan`, `asin`, `acos`, and `atan` operate in radians. `atan(y)`
  defaults `x` to `1.0`; `atan(y, x)` returns the quadrant-aware angle in
  `[-π, π]`.
- `deg` converts radians to degrees; `rad` converts degrees to radians.
- `exp(x)` computes `e^x`; `sqrt(x)` computes the square root of `x`.
- `log(number)` computes the natural logarithm. With an explicit `base`,
  `log(number, base)` computes `ln(number) / ln(base)`. Use `log2` and `log10`
  for direct base-2 and base-10 library operations.

## Rounding, remainders, parts, and bounds

```text
function abs(number: float): float
function ceil(number: float): float
function floor(number: float): float
function fmod(numerator: float, denominator: float): float
function modf(number: float): (float, float)
function frexp(number: float): (float, integer)
function ldexp(mantissa: float, exponent: integer): float
function min(first: float, ...: float): float
function max(first: float, ...: float): float
```

- `abs`, `ceil`, and `floor` return floats and therefore stay total even for
  finite numbers outside Titan's 64-bit integer range.
- `fmod(numerator, denominator)` computes the C floating-point remainder with
  quotient rounded toward zero (returning `NaN` for a zero denominator).
- `modf(number)` splits `number` into its integral and fractional parts rounded
  toward zero, both as `float`.
- `frexp(number)` returns `(mantissa, exponent)` such that
  `number = mantissa * 2^exponent` with `|mantissa|` in `[0.5, 1)` (or
  `0.0, 0` for zero).
- `ldexp(mantissa, exponent)` computes `mantissa * 2^exponent`.
  `exponent` must fit in the target C `int`, raising a range error otherwise.
- `min` and `max` accept one or more float operands (without invoking `<`
  metamethods). `max` replaces its result only when `current < candidate`, and
  `min` replaces its result only when `candidate < current`.

## Unsigned integer comparison

```text
function ult(left: integer, right: integer): boolean
```

`ult` compares two 64-bit integer bit patterns as unsigned integers. For
example, `math.ult(0, -1)` is `true` and `math.ult(-1, 0)` is `false`.

## Pseudo-random numbers

```text
function random(lower: integer?, upper: integer?): value
function randomseed(first: integer?, second: integer?): (integer, integer)
```

`random` implements Lua 5.5's xoshiro256** generator and unbiased interval
projection. This generator is non-cryptographic; each loaded Lua state keeps
its own independent generator state.

| Call | Return type and range |
| --- | --- |
| `random()` | `float` in `[0, 1)` |
| `random(0)` | `integer` with all 64 random bits |
| `random(upper)` | `integer` in `[1, upper]` |
| `random(lower, upper)` | `integer` in `[lower, upper]` |

Because the zero-argument form returns a `float` and bounded forms return an
`integer`, the declared return type is `value`. Cast according to the form you
call:

```text
local unit = math.random() as float
local die = math.random(6) as integer
```

An empty interval (`lower > upper`) raises `"random interval is empty"`.
Passing a non-`nil` `upper` with `lower == nil` raises
`"random lower limit is required"`.

`randomseed(first?, second?)` seeds the generator and returns the two effective
integer components:

- With `first` supplied, `second` defaults to `0`. Replaying the returned pair
  reproduces the exact sequence (matching Lua 5.5 on the same 64-bit target).
- With no arguments, `randomseed()` derives a weak default seed from the wall
  clock, process CPU clock, and current generator state.
- Passing `second` without `first` raises `"randomseed first component is required"`.

## Numeral parsing

```text
function tonumber(candidate: value, base: integer?): value?
function tointeger(candidate: value): integer?
```

- `tonumber(candidate)` with no base returns an existing `integer` or `float`
  unchanged. For a `string`, it validates the full byte length (rejecting
  embedded NUL, trailing characters, `"nan"`, and `"inf"`). It accepts optional
  surrounding ASCII whitespace, an optional `+`/`-` sign, decimal and
  hexadecimal integers, decimal floats (`e`/`E`), and hexadecimal floats
  (`p`/`P`), always recognizing `.` as the decimal point regardless of the
  process C locale. Decimal integers that fit in 64 bits return an `integer`;
  overflow or float syntax returns a `float`; hexadecimal integers wrap modulo
  `2^64`. Unrecognized inputs return `nil`.
- `tonumber(candidate, base)` requires `candidate` to be a `string` and `base`
  to be in `2..36` (raising otherwise). Digits are case-insensitive, optional
  whitespace and sign are accepted, invalid digits return `nil`, and integer
  accumulation wraps modulo `2^64`.
- `tointeger(candidate)` returns an `integer` when `candidate` is an `integer`,
  an exact in-range integral `float`, or a numeral string representing such an
  integer; all other values return `nil`.
