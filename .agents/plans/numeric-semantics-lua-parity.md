# Numeric semantics: Lua 5.5 parity for arithmetic, bitwise, and relational operators

Status: design + implementation spec. Branch: `numeric-semantics-lua-parity`.

## Goal

Make Titan's compilation of operations on `integer`/`float` reproduce **exactly**
the semantics of the corresponding Lua 5.5.0 operations, as Titan's language
reference already promises (`doc/language/expressions.md`: "implementing Lua's
arithmetic exactly, even where C's operators disagree, is a stated [goal]").

Scope: arithmetic (`+ - * / // % ^`, unary `-`), bitwise (`& | ~ << >>`, unary
`~`), relational (`== ~= < <= > >=`) on numbers, and the number coercion rules
(§3.4.3 of the Lua manual). Out of scope: string→number coercion in arithmetic
(Titan is statically typed; a string in arithmetic is a compile error — an
intentional deviation the manual itself says not to rely on), and metamethod
dispatch (numbers have none).

## Ground truth (Lua 5.5.0)

Authoritative sources (paths under `lua-5.5.0/src/`):

* `llimits.h:236-280` — `luai_num*` primitives and `intop`-free float ops.
* `lvm.h:73` — `intop(op,v1,v2) = l_castU2S(l_castS2U(v1) op l_castS2U(v2))`
  (the op is done in the **unsigned** domain, giving defined two's-complement
  wraparound; `l_castS2U`/`l_castU2S` are casts, `llimits.h:146,155`).
* `lobject.c:115-180` — `intarith`/`numarith`, the constant-fold path:
  `+ - *` → `intop`; `& | ~`(xor) → `intop(& | ^)`; unary `-` → `intop(-,0,v1)`;
  `~`(bnot) → `intop(^, ~l_castS2U(0), v1)`.
* `lvm.c:766-827` — `luaV_idiv`, `luaV_mod`, `luaV_modf`, `luaV_shiftl`.
* `lvm.c:417-560` — `LTintfloat`/`LEintfloat`/`LTfloatint`/`LEfloatint`,
  `LTnum`/`LEnum`, `luaV_lessthan`/`luaV_lessequal`.
* `lvm.c:122` (decl in `lvm.h:122`) — `luaV_flttointeger(n,p,mode)`; modes
  `F2Ieq`/`F2Ifloor`/`F2Iceil` (`lvm.h:44-47`).
* `lvm.c:54-80` — `l_intfitsf`/`MAXINTFITSF` (mantissa-fit fast path; **only in
  the .c file**, so Titan must replicate them).
* `llimits.h:293-296` — `lua_numbertointeger(n,p)` (header macro, range-checked).
* Manual `doc/manual.html` §3.4.3 (coercions) and §3.4.4 (relational): numeric
  comparisons compare **mathematical values across int/float subtypes**, with no
  precision loss; `==` between number and non-number is false (Titan rejects such
  mixes at compile time instead — stricter, acceptable).

`intop`, `l_floor` (`luaconf.h`), `lua_numbertointeger`, `luai_numlt/le`,
`F2Imod` and friends are all reachable from generated C (it `#include`s
`lvm.h`, `llimits.h` via `lobject.h`, `luaconf.h`, `<math.h>`; see
`coder.lua` include block ~3743-3759). The build uses
`driver.CFLAGS = "--std=c99 -O2 -Wall -fPIC"` — **no `-fwrapv`**, so signed
integer overflow is genuine UB the optimizer may exploit.

## Findings

| # | Operator | Titan today | Lua 5.5 | Verdict |
|---|----------|-------------|---------|---------|
| D1 | integer `+ - *` | raw signed `(x op y)` | `intop` (unsigned wrap) | **bug**: signed-overflow UB under `-O2`; violates documented wrap guarantee |
| D2 | unary `-` integer | `(-x)` | `intop(-,0,x)` | **bug**: UB for `math.mininteger` |
| D3 | binary `~` (xor) | checker `error()` crash; coder would emit invalid C `(x~y)` | `intop(^,x,y)` | **bug**: documented operator unimplemented |
| D4 | `^` | `pow(x,y)` | `(b==2)?x*x:pow(x,y)` | **bug**: observable last-ULP divergence for `x^2` |
| D5 | `<< >>` | `-Y` / `l_castS2U(-Y)` | guards `y<=-NBITS` first | **bug**: UB for shift amount `INT64_MIN` |
| D6 | float literal | `string.format("%f", n)` | full precision | **bug**: 6-digit truncation (`3.14159265358979`→`3.141593`); `+inf` literal emits invalid `inf` |
| D7 | `== ~= < <= > >=` mixed int/float | checker promotes int→float, then raw C compare | exact `LTnum`/`LEnum`/`equalobj` | **bug**: silent wrong result for magnitudes > 2^53 (`maxint == 2.0^63` true in Titan, false in Lua) |
| DE | integer `// %`, `<< >>` | operands spliced 2–4× into the template | each operand evaluated once | **bug**: side-effecting operand (`f() // g()`) runs multiple times |
| — | float `+ - * / // %`, unary `~`, integer `& |`, idiv/mod arithmetic & div-by-zero | — | — | **already faithful** (verified) — leave unchanged |
| — | mod-by-zero `"% by zero"` format | unescaped `%` | — | cosmetic only (Lua 5.5 `luaO_pushvfstring` copies `% ` verbatim); apply harmless `%%` cleanup |

Coercion audit (manual §3.4.3) — all **faithful**, no change: bitwise float→int
with exact-integer runtime check (`checkandget`/native `ExpCast`); `/` and `^`
int→float; mixed-arith int→float; int→float lossless cast; float→int exact-or-
fail. Numeric-`for` with mixed int/float bounds is rejected at compile time
(Lua clamps) — a clean error, not a miscompile; left as a documented deviation.

Known limitation NOT addressed (documented, not introduced here): the general
arithmetic/comparison fall-through evaluates its two operands in C's unspecified
order rather than Lua's strict left-to-right, observable only when **both**
operands have side effects. DE (idiv/mod/shift) is fixed because it
*multiply*-evaluates; fixing single-eval ordering for every binop is a separate,
broader change.

## Implementation

All edits on branch `numeric-semantics-lua-parity`. After editing compiler
sources run **both** `luarocks make` and `luarocks make --local` (busted loads
from `~/.luarocks`, `titanc` from `~/.local`) before testing.

### 1. `titan-runtime/titan.h` — inlined int/float comparison helpers

Mirror Lua's `l_sinline` comparators but on unboxed scalars (no `TValue`). Add
near the other helpers. These replicate `l_intfitsf` (replicated because it
lives only in `lvm.c`) and inline `luaV_flttointeger` per fixed mode:

```c
/* Whether a lua_Integer converts to lua_Number with no rounding — replicated
** from lvm.c (l_intfitsf lives only in the .c file). NBM = float mantissa bits. */
#define TITAN_NBM (l_floatatt(MANT_DIG))
#if ((((LUA_MAXINTEGER >> (TITAN_NBM / 4)) >> (TITAN_NBM / 4)) >> (TITAN_NBM / 4)) \
        >> (TITAN_NBM - (3 * (TITAN_NBM / 4)))) > 0
#define TITAN_MAXINTFITSF ((lua_Unsigned)1 << TITAN_NBM)
#define titan_intfitsf(i) ((TITAN_MAXINTFITSF + l_castS2U(i)) <= (2 * TITAN_MAXINTFITSF))
#else
#define titan_intfitsf(i) 1
#endif

/* i < f  (mirrors LTintfloat): i < f  <=>  i < ceil(f) when i doesn't fit a float */
static l_inline int titan_lt_intfloat(lua_Integer i, lua_Number f) {
  if (titan_intfitsf(i)) return luai_numlt(cast_num(i), f);
  else {
    lua_Integer fi; lua_Number ff = l_floor(f);
    if (ff != f) ff += 1;                       /* F2Iceil */
    if (lua_numbertointeger(ff, &fi)) return i < fi;
    else return f > 0;                          /* f beyond integer range */
  }
}
/* i <= f  (LEintfloat): i <= floor(f) */
static l_inline int titan_le_intfloat(lua_Integer i, lua_Number f) {
  if (titan_intfitsf(i)) return luai_numle(cast_num(i), f);
  else {
    lua_Integer fi; lua_Number ff = l_floor(f);  /* F2Ifloor */
    if (lua_numbertointeger(ff, &fi)) return i <= fi;
    else return f > 0;
  }
}
/* f < i  (LTfloatint): floor(f) < i */
static l_inline int titan_lt_floatint(lua_Number f, lua_Integer i) {
  if (titan_intfitsf(i)) return luai_numlt(f, cast_num(i));
  else {
    lua_Integer fi; lua_Number ff = l_floor(f);  /* F2Ifloor */
    if (lua_numbertointeger(ff, &fi)) return fi < i;
    else return f < 0;
  }
}
/* f <= i  (LEfloatint): ceil(f) <= i */
static l_inline int titan_le_floatint(lua_Number f, lua_Integer i) {
  if (titan_intfitsf(i)) return luai_numle(f, cast_num(i));
  else {
    lua_Integer fi; lua_Number ff = l_floor(f);
    if (ff != f) ff += 1;                        /* F2Iceil */
    if (lua_numbertointeger(ff, &fi)) return fi <= i;
    else return f < 0;
  }
}
/* i == f  (luaV_equalobj int/float case, F2Ieq): equal iff f is integral,
** in range, and equals i. */
static l_inline int titan_eq_intfloat(lua_Integer i, lua_Number f) {
  lua_Integer fi; lua_Number ff = l_floor(f);
  if (ff != f) return 0;                         /* non-integral */
  if (!lua_numbertointeger(ff, &fi)) return 0;   /* out of range */
  return i == fi;
}
```

NaN is handled correctly in every branch (the fast path goes through
`luai_numlt`/`luai_numle` = C `<`/`<=`, false for NaN; the slow path's
`lua_numbertointeger` fails on NaN and falls to `f>0`/`f<0`, both false).
`l_inline` (`llimits.h`) is `inline`; `static l_inline` matches Lua's
`l_sinline`, avoiding multiple-definition across TUs.

### 2. `titan-compiler/coder.lua`

**D6 — `c_float_literal` (~line 44):**
```lua
local function c_float_literal(n)
    if n ~= n then return "NAN" end            -- nan (unreachable from a literal, defensive)
    if n == math.huge then return "HUGE_VAL" end   -- +inf, e.g. the literal 1e400
    if n == -math.huge then return "(-HUGE_VAL)" end
    return string.format("%.17g", n)           -- round-trips every finite double
end
```

**D2 — `codeunaryop` (~line 2154):** add a case before the catch-all `else`:
```lua
    elseif op == "-" and node.exp._type._tag == "Type.Integer" then
        -- Integer negation wraps two's-complement like Lua (intop(-,0,x));
        -- raw (-x) is signed-overflow UB for math.mininteger.
        local estats, ecode = codeexp(ctx, node.exp)
        return estats, "intop(-, 0, " .. ecode .. ")"
```
(Float `-` and unary `~` stay in the catch-all `(op .. ecode)` — both correct.)

**D5 — `generate_binop_shift` (~line 2196-2197):** replace BOTH `-${Y}`
occurrences (the guard at 2196 is the one unconditionally evaluated for
`INT64_MIN`) with `intop(-, 0, ${Y})`:
```
            if (l_castS2U(intop(-, 0, ${Y})) < TITAN_LUAINTEGER_NBITS) {
                ${R} = intop(${SHIFT_NEG}, ${X}, intop(-, 0, ${Y}));
```
Also materialize `${Y}` (and `${X}`) into integer temps at the top of the
template so a side-effecting shift amount/operand is evaluated once (DE).

**D4 — `^` case (~line 2461):** hoist BOTH operands into float temps (the
exponent appears in the test and the `pow` arm; the base in `T*T`), then:
```lua
    elseif op == "^" then
        local lstats, lcode = codeexp(ctx, node.lhs)
        local rstats, rcode = codeexp(ctx, node.rhs)
        local bdecl, bname = newtmp(ctx, types.Float())
        local edecl, ename = newtmp(ctx, types.Float())
        local cstats = render([[
            $LSTATS
            $RSTATS
            $BDECL
            $EDECL
            $B = $LCODE;
            $E = $RCODE;
        ]], { LSTATS=lstats, RSTATS=rstats, BDECL=bdecl, EDECL=edecl,
              B=bname, E=ename, LCODE=lcode, RCODE=rcode })
        -- luai_numpow: exponent 2 is a*a, not pow(a,2) (differs by 1 ULP).
        return cstats, "((" .. ename .. " == 2) ? (" .. bname .. " * " .. bname
                       .. ") : pow(" .. bname .. ", " .. ename .. "))"
```

**D3 — binary `~` (xor):** add a case (place near `<<`/`>>`):
```lua
    elseif op == "~" then
        -- Lua's binary '~' is bitwise exclusive-or; C's binary xor is '^'
        -- (Titan's '^' is exponentiation). Wrap like Lua's intop(^,...).
        local lstats, lcode = codeexp(ctx, node.lhs)
        local rstats, rcode = codeexp(ctx, node.rhs)
        return lstats .. rstats, "intop(^, " .. lcode .. ", " .. rcode .. ")"
```

**DE — `generate_binop_idiv_int` / `generate_binop_mod_int`:** after emitting
`M_STATS`/`N_STATS`, materialize each operand into an integer temp once and
substitute the temp names for `${M}`/`${N}` throughout the template (operands
are otherwise spliced 3–4×). Keep `intop(-, 0, <m-temp>)` for the `n==-1` idiv
case. Pattern as in the `and`/`or` arms (~2358-2365).

**D7 — mixed int/float comparison:** add a branch BEFORE the arithmetic
fall-through (after the `TValue ==/!=` branch ~2535). Gate on op in
`{<,<=,>,>=,==,!=}` with one operand `Type.Integer` and the other `Type.Float`.
Materialize lhs then rhs into typed temps (left-to-right order, single eval),
then emit the helper from §1:
```lua
    elseif (op == "<" or op == "<=" or op == ">" or op == ">="
            or op == "==" or op == "!=")
           and ((node.lhs._type._tag == "Type.Integer" and node.rhs._type._tag == "Type.Float")
             or (node.lhs._type._tag == "Type.Float"   and node.rhs._type._tag == "Type.Integer")) then
        local lstats, lcode = codeexp(ctx, node.lhs)
        local rstats, rcode = codeexp(ctx, node.rhs)
        local ldecl, lname = newtmp(ctx, node.lhs._type)
        local rdecl, rname = newtmp(ctx, node.rhs._type)
        local cstats = render([[
            $LSTATS
            $LDECL
            $LNAME = $LCODE;
            $RSTATS
            $RDECL
            $RNAME = $RCODE;
        ]], { LSTATS=lstats, LDECL=ldecl, LNAME=lname, LCODE=lcode,
              RSTATS=rstats, RDECL=rdecl, RNAME=rname, RCODE=rcode })
        local lint = node.lhs._type._tag == "Type.Integer"
        local cmp
        if op == "==" or op == "!=" then
            cmp = lint and ("titan_eq_intfloat(" .. lname .. ", " .. rname .. ")")
                        or ("titan_eq_intfloat(" .. rname .. ", " .. lname .. ")")
            if op == "!=" then cmp = "(!" .. cmp .. ")" end
        elseif op == "<" then
            cmp = lint and ("titan_lt_intfloat(" .. lname .. ", " .. rname .. ")")
                        or ("titan_lt_floatint(" .. lname .. ", " .. rname .. ")")
        elseif op == "<=" then
            cmp = lint and ("titan_le_intfloat(" .. lname .. ", " .. rname .. ")")
                        or ("titan_le_floatint(" .. lname .. ", " .. rname .. ")")
        elseif op == ">" then           -- a > b  ==  b < a
            cmp = lint and ("titan_lt_floatint(" .. rname .. ", " .. lname .. ")")
                        or ("titan_lt_intfloat(" .. rname .. ", " .. lname .. ")")
        else                            -- ">=":  a >= b  ==  b <= a
            cmp = lint and ("titan_le_floatint(" .. rname .. ", " .. lname .. ")")
                        or ("titan_le_intfloat(" .. rname .. ", " .. lname .. ")")
        end
        return cstats, cmp
```
(`int==int`/`float==float` and `int<int`/`float<float` keep using the raw-C
fall-through — both correct.)

**mod0 cosmetic:** `"error at line %d, % by zero"` → `"... %% by zero"`
(~line 2302). Renders identically; removes the unescaped `%`.

### 3. `titan-compiler/checker.lua` — `ExpBinop` (~line 1031)

**D3 — binary `~`:** add `"~"` to the bitwise group condition (~line 1218):
`elseif op == "|" or op == "&" or op == "~" or op == "<<" or op == ">>" then`
(integer-only operands, float→integer coercion, integer result — already what
that branch does). `~=` is handled earlier so it cannot reach here.

**D7 — stop promoting int→float in comparisons:**

`==`/`~=` branch (~1038-1067): **remove** the "coerce to float if either side is
float" block (currently ~1053-1058). Add a mixed-numeric exception to the
comparability guard so `integer`/`float` is allowed without coercion:
```lua
        local mixed_numeric =
            (tlhs._tag == "Type.Integer" and trhs._tag == "Type.Float") or
            (tlhs._tag == "Type.Float"   and trhs._tag == "Type.Integer")
        if not mixed_numeric and
           (tlhs._tag ~= "Type.Option" or trhs._tag ~= "Type.Option" or
            ((tlhs.base._tag ~= "Type.Integer" or trhs.base._tag ~= "Type.Float") and
             (tlhs.base._tag ~= "Type.Float" or trhs.base._tag ~= "Type.Integer"))) and
           not types.compatible(tlhs, trhs) then
            checker.typeerror(errors, loc,
                "trying to compare values of incomparable types: %s and %s",
                types.tostring(tlhs), types.tostring(trhs))
        end
```
(Value/option coercion blocks above are unchanged; for plain int/float neither
fires, so operands keep their natural types into codegen.)

`<`/`>`/`<=`/`>=` branch (~1068-1109): **remove** the float-promotion block and
rewrite the type check to allow both-number (any int/float mix) and both-string,
preserving the existing error messages (verified against
`spec/checker/checker_spec.lua:1320-1429`):
```lua
        node.lhs = tryforce(node.lhs); tlhs = node.lhs._type
        node.rhs = tryforce(node.rhs); trhs = node.rhs._type
        local lnum = tlhs._tag == "Type.Integer" or tlhs._tag == "Type.Float"
        local rnum = trhs._tag == "Type.Integer" or trhs._tag == "Type.Float"
        local lstr, rstr = tlhs._tag == "Type.String", trhs._tag == "Type.String"
        if (lnum and rnum) or (lstr and rstr) then
            -- ok: numbers compare to numbers (int vs float exactly), strings to strings
        elseif rnum and not lnum then
            checker.typeerror(errors, loc, "left hand side of relational expression is a %s instead of a number", types.tostring(tlhs))
        elseif lnum and not rnum then
            checker.typeerror(errors, loc, "right hand side of relational expression is a %s instead of a number", types.tostring(trhs))
        elseif rstr and not lstr then
            checker.typeerror(errors, loc, "left hand side of relational expression is a %s instead of a string", types.tostring(tlhs))
        elseif lstr and not rstr then
            checker.typeerror(errors, loc, "right hand side of relational expression is a %s instead of a string", types.tostring(trhs))
        elseif types.equals(tlhs, trhs) then
            checker.typeerror(errors, loc, "trying to use relational expression with two %s values", types.tostring(tlhs))
        else
            checker.typeerror(errors, loc, "trying to use relational expression with %s and %s", types.tostring(tlhs), types.tostring(trhs))
        end
        node._type = types.Boolean()
```

## Tests — `spec/coder/numeric_semantics_spec.lua` (new)

Require `spec.support.helpers` (like the sibling coder specs). **Migrate** out of
`spec/coder/coder_spec.lua` (delete there): the whole
`describe("Lua vs C operator semantics")` block (unary `-`, `+` overflow, `//`,
`%`, `>>`), "computes float modulo with Lua-faithful sign", "generates code for
exponentiation", "formats integral floats with a .0 suffix like Lua", "emits
LUA_MININTEGER instead of an out-of-range C literal", "range-checks an
out-of-range float-to-integer conversion". **Add** new coverage, comparing Titan
results against reference Lua (`assert(test.f(a,b) == (a OP b))`), not hardcoded
values:

* integer `+ - *` overflow/wrap at `maxinteger`/`mininteger`.
* unary `-` of `mininteger`.
* `<<` (mirror the existing `>>` cases) incl. amounts `100`, `-100`,
  `maxinteger`, `mininteger`.
* `& | ~`(xor) incl. negative operands and `mininteger`; unary `~`.
* `^`: assert `x^2.0 == x*x` for a value where `pow(x,2.0)` differs (e.g. derived
  by scanning), plus general `^`.
* float literal precision round-trip (`3.14159265358979`, `0.1`, a denormal),
  and the documented `expressions.md` examples (`-10//3==-4`, `10%-3==-2`,
  `1<<100==0`, `4>>-1==8`).
* **Mixed int/float comparisons across the full range** (the headline fix):
  `maxinteger`/`mininteger` vs `2.0^63`, `2.0^53±1`, integral vs non-integral
  floats, NaN (all comparisons false), for every operator, each asserted
  `== (lua expression)`.
* div/mod by zero raise (integer); float `/` by zero is `inf`/`nan` (no raise);
  bitwise on a non-integral float operand raises "no integer representation".

## Docs

* `doc/language/expressions.md`: state that arithmetic/bitwise/relational
  operators on numbers follow Lua 5.5 exactly; correct the now-false claim that
  comparisons promote the integer to float — they compare mathematical values
  (so `math.maxinteger ~= 2.0^63`); list the gotchas (two's-complement wrap,
  floor `//` and divisor-signed `%`, `x^2` via `x*x`, shift amounts any integer,
  float→int needing an exact integral value, `==` across number/non-number being
  a compile error in Titan).
* `doc/implementation/codegen-constructs.md`: remove the stale *Limitation* note
  about `+ - *`/unary-`-` UB; document the `intop` wrapping, binary `~`→`intop(^)`,
  the `^` `b==2` special case, the shift `intop(-,0,y)` negation, the float
  literal `%.17g`/`HUGE_VAL`, and the inlined `titan_*_intfloat`/`titan_eq_intfloat`
  comparison helpers (chosen by static operand types — no `TValue` boxing).

## Verification

`make test` (runs `luarocks make` + full busted suite) must be green, plus the
new spec. Spot-check generated C for a mixed comparison and `x^2` with
`helpers.verbose`.
