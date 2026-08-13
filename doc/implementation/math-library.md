# Mathematical-library implementation

The public `titan.math` module is implemented in `titan/math.titan`. It does
not call Lua functions or the Lua C API. Ordinary calculations use direct C99
FFI declarations from `math.h`; numeric text uses validated input followed by
`strtod`; weak default seeding uses `time.h`. `titan/ffi.h` contributes only
portable C scalar typedefs for out-parameters and temporary buffers.

## Fixed numeric signatures and C calls

Titan has separate static `integer` and `float` types and no function
overloading. Lua's single math functions can instead preserve or choose a
numeric tag dynamically. The implementation resolves that mismatch at the
public interface:

* ordinary mixed numeric operations take and return `float`;
* `frexp` returns `(float, integer)` and `ult` is integer-only;
* `tointeger` returns `integer?`;
* `random` alone returns `value`, because its documented call forms genuinely
  select between a float and an integer;
* `tonumber` returns `value?`, preserving an existing number or the
  integer-first result of parsing.

`fabs`, the trigonometric operations, `atan2`, `ceil`, `floor`, `exp`, `fmod`,
`frexp`, `ldexp`, `log2`, `log10`, `modf`, and `sqrt` are direct FFI calls.
`log` uses the C natural logarithm directly when no base is supplied and
computes `log(number) / log(base)` for every explicit base. It deliberately
does not reproduce Lua's base-2/base-10 dispatch; callers select the dedicated
direct wrappers when that optimization matters. The `frexp` exponent and
`modf` integral part are mutable C scalar locals, so the FFI materializes their
addresses for the call. No native helper object or Lua stack slot is involved.

`max` and `min` are short Titan loops over a typed variadic tail. `deg` and
`rad` use the exported pi constant. Unsigned comparison flips each operand's
sign bit and then uses signed comparison; this is the ordinary order-preserving
mapping between unsigned and two's-complement signed 64-bit integers.

An infinite Titan literal initializes `huge`; generated C lowers that literal
to the target C infinity constant. The integer bounds come from
`LLONG_MIN`/`LLONG_MAX` in `limits.h`, matching Titan's configured Lua integer
representation without duplicating the target constants in Titan source.
Because a foreign macro is not a Titan constant expression, the module's
one-time root initializer assigns both exported bounds before seeding the
random generator.

## xoshiro256**

`RandomState` contains four local Titan integers and therefore belongs to one
module instance in one Lua state. Titan integer addition, multiplication,
shifts, and bitwise operations already have Lua's defined 64-bit wrapping
semantics, so the xoshiro256** transition can be translated directly from
Lua 5.5's `lmathlib.c` without unsigned-C helper calls.

`next_random` performs the four-word xor/shift/rotate transition and returns
the `rotl(second * 5, 7) * 9` output. Float generation takes the high 53 bits
and multiplies by `2^-53`. Those integers are at most `2^53 - 1`, so their
conversion to the configured double-precision Titan float is exact.

Bounded integers use Lua's rejection projection. The requested unsigned span
is spread into the smallest covering Mersenne mask; masked words beyond the
span are rejected until one falls inside it. `ult` supplies the unsigned
comparison, while ordinary wrapping subtraction and addition handle intervals
that cross the signed boundary. This preserves Lua's unbiased result and its
sequence for explicit two-component seeds.

Seeding writes `{first, 0xff, second, 0}` and discards sixteen transitions.
The no-argument form combines ISO C wall and process-CPU clocks for its weak
first component and the previous generator state for its second. No entropy
or cryptographic guarantee is claimed.

## Length-bounded numeral parsing

`tonumber` first distinguishes three cases without reading a raw Lua tag:

1. with no base, `candidate is float` recognizes either numeric
   representation and the original boxed `value` is returned unchanged;
2. a string is parsed over indices `1..#text`;
3. other values fail, while an explicit-base non-string raises.

The lexical pass strips only ASCII whitespace and then consumes every byte of
the candidate grammar. Decimal and hexadecimal digit recognition is explicit,
so C never sees embedded NUL, trailing characters, `nan`, or `inf`. A base
conversion accepts bases 2 through 36 and accumulates with Titan's defined
integer wrap.

Default decimal integers use separate positive and negative overflow cutoffs,
including the asymmetric minimum integer. A fitting result is returned as an
integer. Hex integers deliberately wrap during accumulation, like Lua. Written
floats and overflowing decimal integers reach `strtod` only after the complete
lexical pass.

Lua numeral syntax always uses `.`. Before `strtod`, the implementation reads
`localeconv().decimal_point`; when the active C locale differs, it copies the
validated Titan string into owned C storage and replaces only the known decimal
point. The copy is explicitly NUL-terminated. Thus `strtod` supplies the target
libc's correctly rounded conversion without becoming the lexical recognizer.

`tointeger` reuses the same parser for strings. Titan's written
`value is integer` predicate is appropriate here: unlike `math.type`, this
operation asks whether a numeric value is exactly convertible to integer, so
accepting an integral float is the intended behavior.

## Boundary and GC properties

The module allocates no persistent C owners. Random state is an ordinary local
record; temporary locale-normalized numeral buffers are owned FFI arrays rooted
for the duration of the `strtod` call. Returned `value` numbers use ordinary
Titan gradual injection. The implementation never imports `lua.h`, unwraps a
`TValue`, or calls a Lua API function.

`math.type` is intentionally not implemented: its raw integer-versus-float tag
query is different from Titan's public numeric convertibility predicate and
would violate that boundary. This is a library API choice, not new compiler or
ABI machinery; the standard provider follows the current ABI 0.24 namespace.
