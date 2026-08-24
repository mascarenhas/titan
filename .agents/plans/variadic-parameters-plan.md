# Variadic parameters — implementation plan

**UPDATE (post-implementation):** the surface syntax shipped as `...: <type>` (with a colon,
matching the `name: type` declaration style), NOT the no-colon `...t` this plan describes —
the [OWNER §2 / §8] no-colon decision was reversed during review. Anonymous functions may also
write a bare untyped `...` whose element type is inferred from context. The grammar/checker
sections below that say "no colon" are superseded; everything else (semantics, runtime
representation, GC discipline) stands. See `doc/language/variadic-parameters.md` and
`doc/implementation/variadic-parameters.md` for the as-built reference.

Status: plan for owner review (no code written yet). Expands the sketch at
`doc/variadic-parameters.md` into a full implementation plan, grounded in the current tree
with `file:line` citations from a seam-mapping pass (parser/checker/coder + Lua 5.5
internals). All open questions have been resolved by the owner (§2 / §8). Points the owner
decided that override a conservative-review default are marked [OWNER].

Intent preserved: a *lightweight* `...` mechanism that avoids a full slice type. `...` (the
expression/parameter) is **not** first-class — it cannot be captured, stored, or escape its
declaring function — but the **function that declares it is** a normal first-class value.

---

## 1. Summary & scope

### Surface

A typed variadic parameter `...t` (no colon, no name; always the **last** parameter, mandatory
type; divergence from Lua), on top-level functions, lambdas, record statics, and methods.
Usable only inside the declaring function (rule 4), in:

- **Spread (trailing only):** `f(a, ...)`, `return a, ...`, `{a, ...}`, `{...}`.
- **Length:** `#...` → `integer`.
- **Indexing:** `...[e]` (1-based) → **`t`** (bounds-checked; out-of-range raises). [OWNER §2.A]

The same `...t` token is the **function-type annotation** syntax: `local f: (integer, ...integer): integer`.

### Runtime

Seven homogeneous `TitanVarg*` structs, one per `ctype` so the struct always matches the
element C type exactly [OWNER §2.F]. Struct shape is `{ lu_byte n_args; T args[]; }` —
**`start` is NOT in the struct**; it is a separate `int _start` native parameter [OWNER §2.G/#6],
so forwarding never mutates a shared struct. `n_args` is the total backing count; a callee's
logical length is `n_args − start`. A statically-sized call builds the struct on the **C
stack**; the generic/Lua entry and the "fresh copy" forwarding case build it as a GC-anchored
**`Udata0`**. This change advances the module ABI.

### First-class

Variadic functions **are** first-class values and methods [OWNER §2.B]. They dispatch exactly
like non-variadic first-class functions: the **native fast path** builds the struct and calls
the native pointer when the runtime tag matches the static type; the **generic path**
(Lua-stack push + the callee's `genluaentry`, which coerces and rebuilds the struct) handles a
tag mismatch (a gradual `value` difference) or a call from Lua. The vararg only adds the struct
+ `start` to the native ABI; the dispatch logic is unchanged.

### Out of scope for v1

- Runtime-sized returns — `return ...` is adjust-up into the function's *fixed* return arity (§2.E).
- `...` in map/record constructors — a checker error (`...` is array-shaped).
- Passing `...` into a foreign (C FFI) function — a checker error; the C-FFI `vararg = true`
  meaning stays disjoint from the Titan `varargtype` slot (§4.1).

---

## 2. Resolved design decisions

### 2.A `...[i]` and adjust-up hydration are `t`, not `t?` — [OWNER]

`...[i]` has type **`t`**; the generated code bounds-checks and **raises** a Titan runtime
error on out-of-range (and on `i <= 0`); it never yields nil-from-out-of-range. A typed `...t`
cannot hold a nil element (rejected at the call site, except when `t` is `value`/an option type
which already include nil), so an in-range access is always a valid `t`. The raise is what
licenses the non-optional type. Deliberate divergence from array `a[i]` (which is `t?` because
Lua arrays have holes); the vararg struct is dense and out-of-range is an error.

**Adjust-up follows the consuming slot's optionality** (the same principle, generalized). When
a trailing `...` expands into a *fixed-arity* context (a non-variadic call, an assignment, a
`return`, a `local` hydration), each filled position pulls `...[k]` and:

- target non-optional `t` → bounds-checked, type `t`, **runtime error** if `...` under-supplies
  it (`local a, b, c = ...` with `...integer` requires `#... >= 3`);
- target optional `s?` → out-of-range **nil-fills**, type `s?` (`local a: integer? = ...`).

One AST node, `Ast.ExpDotsIndex`, with a checker-set boolean `_nilfill`: user-written `...[i]`
has `_nilfill = false` (raise/`t`); a synthesized adjust-up access into an optional slot has
`_nilfill = true` (nil/`s?`). Supersedes the sketch's blanket "`...` produces `t?`".

### 2.B Variadic functions are first-class; dispatch is tag-based — [OWNER]

A variadic function is a normal first-class value; a variadic method's bound ref (`obj:m`) is a
normal value. "Non-first-class" constrains only the `...` expression/parameter.

**Calling is identical to non-variadic first-class functions:**

- **Static (direct) call site** — native struct fast path; the three forwarding cases (§5.7).
- **First-class value call, tag matches the static type** — **native fast path**: build the
  struct (C-stack for a fresh static arg list; cases 1–3 for forwarding `...`) and call the
  native pointer with `_varargs` + `_start`, no different from a static native call. There is
  no `CClosure`-ABI obstacle: the struct is an ordinary trailing native parameter.
- **First-class value call, tag does NOT match** (a gradual `value` difference between the
  static type and the runtime function — e.g. a `(integer, ...value)`-typed value holding a
  `(integer, ...integer)` function) — **generic Lua-stack path**: push all args (expanding `...`
  element-by-element), do the dynamic call; the callee's `genluaentry` (§5.4) coerces each
  surplus arg to its real element type and rebuilds the struct. This is the gradual boundary;
  the coercion lives in `genluaentry`, exactly as for non-variadic value params today.
- **Call from Lua / `require`** — the `genluaentry` path (§5.4).

**Performance:** tag-matching static and value calls pay nothing on the heap (C-stack struct);
the generic path pays one `Udata0` allocation — the slow-path cost of a gradual mismatch or a
Lua-originated call.

**Requirement (open-q #2):** both `function_sig` (the fast-path typedef, `coder.lua:1512`) and
the **type-tag computation** that `codevaluecall` matches against MUST fold in the vararg
element type and the trailing `_start` param. Two function types that differ only in vararg
element get **different tags** — which is exactly what makes the fast path correctly fall back
to the generic path when a `...value` slot holds a `...integer` function.

**Compatibility is structural (gradual), tag identity is exact** [OWNER]:

- `types.compatible` (Function/Method): fixed params + rettypes compatible as today, **and**
  vararg *presence* matches (a variadic is never compatible with a non-variadic — structurally
  distinct), **and** when both variadic the element types are `compatible` (gradual — so
  `(integer, ...integer)` is compatible with `(integer, ...value)` **both ways**, via `value`).
- `types.equals` (drives the runtime tag): same, but element types compared with `equals`
  (so `...integer` and `...value` are *not* equal → different tags → correct fast/generic split).

Methods may be variadic: add a `varargtype` slot to `Type.Method`/`Type.StaticMethod`
(`types.lua:19,23`) and to their serialize; `obj:m(a, ...)` is a static callee
(`is_static_callee`, `coder.lua:1385`); `obj:m` as a value dispatches like any value.

### 2.C `lu_byte` count is an intentional cap; `TITAN_VARARG_MAX = 200` — [OWNER]

`n_args` stays `lu_byte`. The small cap is a feature (keeps the struct small, bounds static
sizing); functions needing very large homogeneous arg counts use an explicit array/`{T}` param.
Obligation is **enforcement, not widening**: `TITAN_VARARG_MAX = 200` [OWNER §8.1].
- Statically-known counts are bounded by the parser `LIST_LIMIT = 100` (< 200), so they never trip.
- Runtime counts from forwarding/merge (§5.7 cases 2–3) and the generic entry (§5.4) are
  bounds-checked: a resulting count `> TITAN_VARARG_MAX` **raises a clean Titan error**.

`LIST_LIMIT = 100` is a parse-time guardrail only, not a runtime bound. (`start` is also bounded
by `n_args ≤ 200`, but it travels as an `int` parameter, so its arithmetic never wraps.)

### 2.D Case-3 `Udata0` anchors only itself; elements borrow upstream provenance — [OWNER]

`traverseudata` (`lgc.c:631-638`) marks only `metatable` + `uv[0..nuvalue-1]`, never
`getudatamem`; a `Udata0` has `nuvalue == 0`, so its payload is invisible to the GC. Invariant:

> Every collectable element reachable through a vararg struct remains reachable through its
> existing allocation, result, semantic, or VM provenance for the struct's lifetime; the struct
> object anchors only its own storage.

This requires no per-element input publication:
- **Pass-through elements** from an incoming native `...` borrow the same upstream provenance as
  the current function's other native inputs; a genuine Lua/generic entry instead already has
  real VM argument slots.
- **Newly introduced static-prefix elements** retain the root installed by a fresh allocation or
  native-result handoff, or an established semantic home. Lexical C freezes and the raw payload
  do not become roots.
- The fresh `Udata0` is immediately stack-rooted so its **buffer** survives a GC during the
  copy/call. It has no `__gc`, metatable, or `uv[]` backing.

Case-3 ordering is therefore: evaluate C values while borrowing their upstream provenance →
allocate the `Udata0` (sources remain reachable) → root it immediately → copy → call. A
conditional callable conversion writes a separate destination root only when it actually
allocates a wrapper; its identity fallback stays C-only. The no-copy model intentionally does
not preserve a raw C formal after the program destroys that value's sole traced provenance.

### 2.E `return ...` is adjust-up into fixed return arity

`return ...` / `return e1, ..., ...` fills the function's **fixed** `rettypes` by the §2.A
adjust-up rule (`#rettypes − #static_exps` positions, each `...[k]` with raise/nil-fill per the
declared return slot). Error when return arity is 0, or `t` not coerce-compatible with a slot.
Rationale: returns 2..n lower to compile-time-indexed out-params (`function_sig`
`coder.lua:577-579`; `codereturn` `:1701-1705`) — no runtime mechanism for a variable count, so
`return ...` cannot be a spread.

### 2.F Seven structs, one per `ctype` — [OWNER]

Helper `varg_struct_name(elemtype)` keyed on the `ctype(elemtype)` **string**; the struct always
matches the element C type exactly (a record gets its own `Udata*` struct [OWNER #3], no boxing):

| `ctype(elem)` | Struct | Element C type | Note |
|---|---|---|---|
| `lua_Integer` (Integer) | `TitanVargInteger` | `lua_Integer` | unboxed |
| `lua_Number` (Float) | `TitanVargFloat` | `lua_Number` | unboxed |
| `int` (Boolean) | `TitanVargBoolean` | `int` | Nil cannot occur (`...nil` banned) |
| `TString*` (String) | `TitanVargString` | `TString*` | collectable |
| `Table*` (Array, Map) | `TitanVargArrayOrMap` | `Table*` | collectable |
| `TValue` (Value, Option, Function) | `TitanVargValue` | `TValue` | collectable, tagged 16B |
| `Udata*` (Nominal/record) | `TitanVargNominal` | `Udata*` | collectable, no boxing [OWNER #3] |
| `foreignctype` (Pointer) | — | — | **forbidden** (checker error) |
| `ctype(typ._type)` (Typedef) | resolve underlying, recurse | — | use the resolved variant |

### 2.G FAM struct is never a sized stack local; `start` is a separate param — [OWNER]

The seven typedefs use a C99 flexible array member (`T args[];`) **only** as the
pointer/parameter ABI. At a static call site where the count `N` is a compile-time constant,
emit a **concrete-array local** and pass its address through the FAM pointer, with `_start` as a
separate argument:

```c
struct { lu_byte n_args; lua_Integer args[N]; } _varg_3 = { N, { a, b } };
f(L, _mod, _fn, /* params... */ (TitanVargInteger *)&_varg_3, /* _start = */ 0, /* out-params... */);
```

The concrete-array element type comes from the **same** `ctype` map (no punning); `args` is
reached only via member access so padding after the single `lu_byte n_args` (≈7 bytes before an
8-aligned `args` on LP64) is authoritative and identical between write-type and read-type
(common-initial-sequence). The literal FAM type cannot be a stack local (hard ISO C constraint
violation), hence the indirection. **`N == 0` (empty vararg):** ISO C forbids `args[0]`, so emit
`args[1]` with `n_args == 0` [OWNER #4]; the bounds checks guarantee `args` is never read.

Removing `start` from the struct [OWNER #6] makes forwarding mutation-free: a callee's view is
`args[start .. n_args-1]` and `start` is just an argument each call computes and passes.

---

## 3. Surface syntax & grammar changes

Files: `ast.lua`, `parser.lua`, `syntax_errors.lua`. `lexer.lua` needs no change.

### 3.1 `lexer.lua` — no change

`DOTS = "..."` already lexes (`lexer.lua:213`); the longest-match loop (`:221-229`) makes
`CONCAT`/`DOT` subtract it. The terminal `DOTS <- %DOTS SKIP*` (`parser.lua:564`) exists and is
currently dead.

### 3.2 `ast.lua` — new Exp constructors

Add to the `Exp` group (`ast.lua:56-73`):

```lua
ExpDots         = {"loc"},            -- bare `...`
ExpDotsIndex    = {"loc", "exp"},     -- `...[e]` (checker sets _nilfill, _type)
ExpDotsLen      = {"loc"},            -- `#...` (checker-normalized, §3.5)
```

Auto-inject into the grammar `defs` (`parser.lua:26-28`); ripple into `checkexp` (§4) and the
`codeexp` chain (§5) per the `_tag` convention. They never appear in `types.lua` (the vararg
element type lives on `Type.Function.varargtype`).

**Vararg parameter encoding:** a trailing `Ast.Decl` with `name == false`, `type` = the element
type. No new param node / no owner-node flag — `defs.typeddecl` already builds
`ast.Decl(pos, name, type, false)`. Detect a variadic function by `params[#params].name == false`.

### 3.3 `parser.lua` — `defs.*` helpers

```lua
local LIST_LIMIT = 100   -- near THIS_FILENAME (:14); parse-time guardrail only

function defs.varargdecl(pos, type)  return ast.Decl(pos, false, type, false) end
function defs.dots_field(pos)        return ast.Field(pos, false, ast.ExpDots(pos)) end
-- defs.checklist(list): list if #list <= LIST_LIMIT else %{ListTooLong}
```

### 3.4 `parser.lua` — productions to modify

**Parameter lists** (`paramlist` `:311`, `lambdaparamlist` `:317`) — trailing vararg, last-only
structural (the vararg always requires `: type`, even in lambdas):

```
varargparam     <- (P DOTS COLON^ParamSemicolon type^TypeDecl) -> varargdecl
paramlist       <- {| (param (COMMA param^DeclParList)* (COMMA varargparam)?)? / varargparam |}
lambdaparamlist <- {| (lambdaparam (COMMA lambdaparam^DeclParList)* (COMMA varargparam)?)? / varargparam |}
```

(Surface is `...t`; the grammar still consumes a `DOTS type`. Whether the colon is written —
`...integer` vs `...: integer` — is a lexical choice; the owner picked `...t` (no colon), so the
`varargparam` production drops `COLON`: `(P DOTS type^TypeDecl) -> varargdecl`. Apply the same
no-colon form to the function-type annotation below.)

**Trailing `...` in explists** (`explist` `:470`) — reaches call args (`funcargs` `:466`),
`returnstat` (`:403`), assignment/decl RHS (`:389,391`):

```
explist <- {| (P DOTS) -> ExpDots |}
         / ({| exp (COMMA exp^ExpExpList)* ((COMMA (P DOTS) -> ExpDots))? |}) -> checklist
```

**Trailing `...` in array constructors** (`field` `:481`):

```
field   <- (P DOTS) -> dots_field
         / (P (key ASSIGN)? -> opt exp) -> Field
```

"`...` last only" and "no `...` in map/record constructor" are checker-enforced.

**Function-type annotation** (`typelist` `:350`, feeding `Ast.TypeFunction`) — accept a trailing
`...t` and carry the element type into `typefromnode` (§4.2). Required for first-class variadic
function types [OWNER §2.B / #2].

### 3.5 `parser.lua` — `simpleexp` cases

Add to `simpleexp` (`:451-459`), before `suffixedexp`/`prefixexp`, index form before bare:

```
/ (P DOTS LBRACKET exp^ExpExpSuf RBRACKET^RBracketExpSuf) -> ExpDotsIndex
/ (P DOTS)                                                -> ExpDots
```

`#...` is **not** a `simpleexp` rule — the `unop` cascade (`:416,430`) takes `#` greedily, so
`#...` parses as `ExpUnop("#", ExpDots)`. The checker's `#` arm (`checker.lua:973`) special-cases
`node.exp._tag == "Ast.ExpDots"` and rewrites it to `ExpDotsLen`, bypassing the array/string `#`
path that would crash on a non-value operand.

### 3.6/3.7 `LIST_LIMIT` and `syntax_errors`

Apply `defs.checklist` to `paramlist`/`lambdaparamlist`/`explist` via a `%{ListTooLong}` failure.
New label: only **`ListTooLong`**. Reuse `ParamSemicolon`/`TypeDecl`/`ExpExpSuf`/`RBracketExpSuf`.
Optional: `VarargType`, `VarargNotLast`.

---

## 4. Type-checking changes

Files: `checker.lua`, `types.lua`. `symtab.lua` needs no change.

### 4.1 `types.lua` — a NEW `varargtype` slot — [OWNER #5]

Add a new field `varargtype` to `Type.Function` (`types.lua:13` → `{"params","rettypes","vararg","varargtype"}`)
distinct from the existing `vararg` boolean. The **C-FFI** path keeps `vararg = true`
(`foreigntypes.lua:64`), `varargtype = false`. A **Titan** variadic sets `varargtype = t`
(`vararg = false`). Consumers test `varargtype` for Titan varargs — never confused with the
C-FFI boolean. Add `varargtype` to `Type.Method`/`Type.StaticMethod` (`:19,23`).

This is a typedecl arity change: update the `types.Function`/`Method`/`StaticMethod` constructors
and **every call site** (positional). Update:

- **`compatible`** (`:176-197`): after fixed params + rettypes, require vararg *presence* match
  and, when both Titan-variadic, `compatible(varargtype1, varargtype2)` — gradual, so
  `(integer, ...integer)` ↔ `(integer, ...value)` both ways [OWNER §2.B].
- **`equals`** (`:214-235`): same, but `equals(varargtype1, varargtype2)` — drives the tag.
- **`serialize`** (`:349-380`): emit `varargtype` for Function and Method (ABI-format change,
  gated on §5.8), so `.so` imports rehydrate; keep the C-FFI `vararg` boolean serialized as
  today and disjoint.
- **`tostring`** (`:269-293`): append `, ...t`.

### 4.2 `typefromnode["Ast.TypeFunction"]` (`checker.lua:145-158`)

Accept the trailing `...t` from the type grammar (§3.4); set `varargtype = t`.

### 4.3 Signature pass — three visitors + `...nil` ban

`["Ast.TopLevelFunc"]` (`checker.lua:1744`), `["Ast.TopLevelStatic"]` (`:1781`),
`["Ast.TopLevelMethod"]` (`:1833`): detect the trailing vararg `Decl` (`name == false`), resolve
its element type, **drop it from `ptypes`**, pass it as `varargtype` to the type constructor.
Bans here (cf. map-key-nil, `checker.lua:134-136`): `...nil` → error; foreign-`Pointer` element
→ error (§2.F). Option element types are fine (options don't nest; `optionize` idempotent,
`:69-75`); `...value` keeps `...[i] : value`.

### 4.4 `checkfuncbody` — depth-stamped `$vararg`; scope rule 4

In `checkfuncbody` (`:1488`), for a variadic function install `$vararg = { elem = t, funcdepth = #func_stack }`
beside `$function` (`:1490`). Rule 4 (`...` invisible to inner lambdas) is **not** plain scoping
(`find_symbol` walks all enclosing blocks, `symtab.lua:35-44`): stamp `$vararg` with the current
`#func_stack` (mirroring `_funcdepth`, `:241,568`); when resolving any `...`/`#...`/`...[e]`,
reject if `funcdepth ~= #func_stack` ("'...' is not visible inside an inner function"). No
`symtab.lua` change.

### 4.5 New `checkexp` arms

- **`Ast.ExpDots`** — resolve `$vararg`; set `node._vararg_elem = t`. Its type is fixed by the
  consuming loop (§4.6). A bare `...` in a non-explist position errors.
- **`Ast.ExpDotsLen`** — `node._type = Integer`.
- **`Ast.ExpDotsIndex`** — check the index against `integer`, `trycoerce`, `checkmatch`;
  **`node._type = t`** [OWNER §2.A], default `_nilfill = false`. Adjust-up synthesis (§4.6) sets
  `_nilfill = true`, `_type = s?` for optional slots.

The `#` arm (`:973`) rewrites `#<ExpDots>` → `ExpDotsLen`.

### 4.6 The four explist loops — adjust-up and whole-tail

`StatDecl` (`:340`), `StatAssign` (`:437`), `StatReturn` (`:497`), `checkargs` (`:691`): detect a
trailing `Ast.ExpDots`. Dispatch:

- **Adjust-up** (`StatDecl`/`StatAssign`/`StatReturn`, and a non-variadic callee): deficit
  `d = #slots − (#exps − 1)`. `d < 0` → rule-1 error; `d == 0` → legal no-op. Else replace the
  trailing `ExpDots` with `d` synthesized `ExpDotsIndex` (`exp = ExpInteger(k)`), each with OOB
  mode from the **target slot** [OWNER §2.A] (optional → `_nilfill = true`, `_type = s?`;
  non-optional → `_nilfill = false`, `_type = t`), then `trycoerce`/`checkmatch`.
- **Whole-tail** (a **variadic** callee, dispatched on `ftype.varargtype` read before the
  `_types` loop at `:704`): keep the trailing `ExpDots` as a marker; check this function's `...`
  element type against the callee's `varargtype` via `compatible` (gradual). Over-supplied static
  args to a variadic callee are each `trycoerce`d to `varargtype` (§4.8).

`...` is always the sole, last trailer; a list ending in both a multi-return call and `...` is
structurally impossible (`f(g(), ...)` truncates `g()` to one value).

### 4.7 `ExpInitList` Array arm — `{...}` / `{e1, ..., ...}`

In the Array arm (`:768-804`): detect a trailing key-less `ExpDots` field. Seed the element type
from `t` first (`etype = econtext or vararg_elem_t`), check static fields against it, result
**`Array(t)`** (whole-tail; not `Array(t?)`). No-context `{...}` → `Array(t)`. Errors here: `...`
last-only (reject `{..., 1}`); `...` in a map/record constructor → error.

### 4.8 Coercion guarantee for codegen

After checking, every element destined for a `TitanVarg*` struct has been `trycoerce`d to the
element type `t`, so each store is a plain `setwrapped`/`setslot` of a value already of
`ctype(t)`. (At a gradual boundary that needs a `value`→`t` check, the check lives in
`genluaentry`, §5.4, not the struct store.)

---

## 5. Runtime representation & codegen

Files: `coder.lua`, `titan-runtime/titan.h`, `CLAUDE.md`.

### 5.1 `titan.h` — struct typedefs (seven, no `start`, `lu_byte n_args`)

```c
typedef struct { lu_byte n_args; lua_Integer args[]; } TitanVargInteger;
typedef struct { lu_byte n_args; lua_Number  args[]; } TitanVargFloat;
typedef struct { lu_byte n_args; int         args[]; } TitanVargBoolean;
typedef struct { lu_byte n_args; TString*    args[]; } TitanVargString;
typedef struct { lu_byte n_args; Table*      args[]; } TitanVargArrayOrMap;
typedef struct { lu_byte n_args; TValue      args[]; } TitanVargValue;
typedef struct { lu_byte n_args; Udata*      args[]; } TitanVargNominal;
#define TITAN_VARARG_MAX 200   /* forwarding/entry guard, §2.C */
```

Emitted by `preamble` (`coder.lua:3853`). FAM `args[]` is the pointer/ABI form only;
concrete-array locals at call sites (§2.G). `n_args` = total backing count; `start` is a separate
native param (§5.2). Coder helper `varg_struct_name(elemtype)` → one of the seven (§2.F).

### 5.2 Native signature — trailing struct pointer + `start`, pinned before out-params

Pinned **after declared params, before out-params**, as two items: `TitanVargX *_varargs, int _start`.
Not `ftype.params` entries; appended when `ftype.varargtype` is a type. `ctype`
(`coder.lua:535-555`) untouched — special-cased at the four signature emitters, which must agree
byte-for-byte:

1. `function_sig` (`:564-590`) — also feeds the value-call fast-path typedef (`:1512`) **and** the
   type-tag computation [OWNER §2.B/#2]; both must include the trailing struct + `_start`.
2. `codefuncdec` cparams (`:3295-3333`) — between the param loop and out-param loop.
3. `codelambdadec` cparams (`:3705-3722`).
4. `codemethodtrampoline` (`:3419-3431`) — variadic methods.

```c
lua_Integer mod_f_titan(lua_State *L, Udata *_mod, CClosure *_fn,
                        lua_Integer _param_x,
                        TitanVargInteger *_varargs, int _start,   /* trailing, before out-params */
                        lua_Integer *_outparam_2);
```

### 5.3 Thread into the per-function context

`newcontext` (`:593-610`) / `codefuncdec` / `codelambdadec`:
`ctx.varargs = { cname = "_varargs", start = "_start", elem = ftype.varargtype }` when variadic.
**`codelambdadec` (`:3681-3783`) must reset `ctx.varargs`** to its own (or nil) — never inherit
the enclosing function's (scope rule 4).

### 5.4 Generic entry builds the struct (`genluaentry`)

`genluaentry` (`:3155-3250`), reached from `require`/Lua and the generic value-call path:

1. Arg-count check (`:3233`) `!=` → `>= nfixed`.
2. `count = (top - func - 1) - nfixed`; **cap-check `count <= TITAN_VARARG_MAX`** else raise (§2.C);
   `lu_byte _nvarargs = (lu_byte)count`.
3. Allocate the struct as a GC-anchored `Udata0` (`newbox`(N), `:751-763`), sized
   `sizeof(TitanVargX) + _nvarargs*sizeof(elem)` — not a C-stack VLA (must survive the
   error-handler frame, `:3236-3241`).
4. Read each surplus `s2v(func + nfixed + j)` via the same `checkandget`/coercion as fixed params
   into `getudatamem(udata)->args[j]`; set `n_args = _nvarargs`.
5. Pass the struct pointer at the pinned position with **`_start = 0`**.

GC: the source slots stay below `L->top.p` for the whole native call, so they remain the anchors
(§2.D); the payload need not be `uv[]`-backed. Verify `NRET`/errorslot juggling (`:3181-3214`)
doesn't drop those slots before the call.

### 5.5 `...[i]` and `#...` lowering (start-relative)

A callee's view is `args[_start .. n_args-1]`, length `n_args − _start`.

**`...[i]` (`Ast.ExpDotsIndex`)** — materialize the index into a temp (multiple-evaluation
gotcha); bounds-check `1 <= i <= n_args − _start`:

```c
lua_Integer _vi = $INDEX;
if (TITAN_UNLIKELY(_vi < 1 || _vi > (lua_Integer)_varargs->n_args - _start))
    /* _nilfill == false */  luaL_error(L, "variadic index %d out of range [1, %d]", ...);
    /* _nilfill == true  */  /* yield nil */;
$RESULT = _varargs->args[_start + _vi - 1];   /* in range */
```

- `_nilfill == false` (user `...[i]`, non-optional adjust-up): OOB **raises** via the existing
  Titan runtime-error path (eventually the roadmap's backtrace work); result is the unboxed
  `ctype(t)` value — **type `t`** [OWNER §2.A].
- `_nilfill == true` (optional adjust-up): OOB yields nil; result `t?` (model `codeindexarray`
  option branch, `:2647-2669`).

**`#...` (`Ast.ExpDotsLen`)** — `(lua_Integer)_varargs->n_args - _start` (model `codeunaryop` `#`,
`:2154-2160`).

### 5.6 `{...}` / `{e1, ..., ...}` and `return ...`

**`{...}` array build** — `codearray` (`:1938-2009`) assumes a compile-time count; add a vararg
path. The struct elements are **already anchored upstream** (§2.D) and the GC is non-moving, so
no pre-copy to stack slots is needed [OWNER]; reading `args[]` across a `luaH_resizearray` GC is
safe. It is the same copy as case-3 (§5.7) plus the **table** back barrier:

1. Build the table anchored in a stack slot (`:1949`).
2. Size from `#static_fields + (_varargs->n_args − _start)` at runtime.
3. Runtime loop `j in [0, n_args − _start)`: `obj2arr(_t, prefix + j, &slot)` from
   `_varargs->args[_start + j]`, then **`luaC_barrierback`** per GC element (mandatory — the table
   traces its array part; mirror `:1992-2007`; skip for integer/float/boolean).

**`return ...`** — the checker (§4.6) already expanded `...` into the right `ExpDotsIndex` reads,
so `codereturn` (`:1672-1720`) needs no new structure; each lowers via §5.5 to `*_outparam_i`.

### 5.7 Static call sites; three nested-pass cases; value calls

**Static native call site** (`codecall`, `:1538-1670`): when the arg list ends in `...` and the
callee is variadic, insert `_varargs` + `_start` into `caexps` after the arg loop (`:1629`) and
before the out-param loop (`:1630`). Three cases (all mutation-free now that `start` is a param):

1. **Pass-through** (caller static count == callee static-param count, element type matches): pass
   the current `_varargs` and `_start` unchanged. No allocation.
2. **Start-adjust** (caller static args fewer than callee static params, element type matches):
   treat the missing callee-fixed args as `...[i]` reads, then pass the same `_varargs` with
   `_start = _start + delta`. **No struct mutation, no save/restore** [OWNER #6].
3. **Fresh copy** (non-matching element types, or caller static args > callee static params):
   allocate a fresh `Udata0` (`newbox`(N), `:751-763`), **cap-check the count** (§2.C), anchor it,
   copy needed args into `getudatamem(udata)->args[k]`, set `n_args`, pass with `_start = 0`.
   Anchoring/ordering per §2.D.

**First-class value call** (`codevaluecall`, `:1486-1520`): dispatch as for any first-class
function [OWNER §2.B] — **tag matches** the static type → the native fast path builds the struct
(cases 1–3 above) and calls the native pointer with `_varargs` + `_start`; **tag mismatch** (a
gradual `value` difference) → the generic Lua-stack branch (push args, expanding `...`
element-by-element), and the callee's `genluaentry` (§5.4) coerces + rebuilds. The fast-path
typedef and the tag both include the vararg element + `_start` (§5.2 / #2).

### 5.8 Module ABI boundary

Advance `TITAN_ABI_VERSION`, with a rationale that the cross-module native
signature gains a trailing `TitanVargX*` + `int _start` for variadic functions,
and `<mangled>_types` now encodes `varargtype` (§4.1). Update `CLAUDE.md` ABI
notes. The internal `Udata0` reuse does not itself force the bump.

---

## 6. Phased milestones (each independently testable)

- **Phase 0 — Parse-only.** `ast.lua` tags (§3.2), parser productions incl. `...t` type syntax
  (§3.3-3.6), `ListTooLong`. Tests: `spec/parser_spec.lua`.
- **Phase 1 — Typecheck.** `types.lua` `varargtype` slot + compatible/equals/serialize/tostring
  (§4.1), signature pass + bans (§4.3), depth-stamped `$vararg` + rule 4 (§4.4), the three
  `checkexp` arms + `#...` normalization (§4.5), explist loops adjust-up/whole-tail with the
  `t`/`t?` slot rule (§4.6), Array backward typing (§4.7), first-class function-type `...t` +
  structural compat (§2.B). Tests: `spec/checker/checker_spec.lua`.
- **Phase 2 — Codegen scalar.** Seven structs (§5.1), `varg_struct_name`, native signature at all
  four emitters incl. `_start` (§5.2), `ctx.varargs` (§5.3), `genluaentry` build (§5.4),
  `...[i]`/`#...` (§5.5), case-1 static call for integer/float/boolean. Tests:
  `spec/coder/coder_spec.lua`.
- **Phase 3 — Codegen collectable.** Anchoring discipline (§2.D), `setwrapped`/`setslot`,
  `Udata*`/`Nominal` struct (§2.F). Tests: `spec/coder/` (force a GC inside the callee).
- **Phase 4 — Nested passing.** The three cases (§5.7) incl. start-adjust (mutation-free) and
  fresh-`Udata0` + cap guard (§2.C) + recursion. Tests: `spec/coder/` (chained-forward GC,
  overflow-cap at 200).
- **Phase 5 — `{...}` / `return ...` / `#...`.** Runtime-sized array build (§5.6), back barriers.
- **Phase 6 — Lua interop + `.so` ABI + first-class.** ABI boundary (§5.8), `_types` round-trip of
  `varargtype` (§4.1), variadic function called from Lua and as a first-class value (fast path on
  tag match, generic path on gradual mismatch), `.so`-only import. Tests:
  `spec/coder/so_import_spec.lua`, `spec/checker/so_rehydration_spec.lua`.

---

## 7. Test plan (highlights)

`restrict`/`assert_is_subset` for parser/checker specs; reset `types.registry = {}` (and
`driver.imported = {}` for imports).

- **Parser:** `...t` last-param-only (func/lambda/method/static); `...t` function-type annotation;
  typed required; `f(...)`/`f(a,...)`/`return ...`/`{...}`/`{a,...}` positions; `...[e]` →
  `ExpDotsIndex`; `#...` → `ExpUnop("#", ExpDots)`; `LIST_LIMIT` 101 → `ListTooLong`.
- **Checker:** accept `#...` (`integer`), `...[i]` (**`t`**), `{...}` (`{t}`), `{1,2,...}`,
  `f(a,...)` to a variadic callee, `return ...`, deficit-0 no-op; non-optional under-supply is
  *compile-accepted* (raises at runtime), optional slot nil-fills; **a variadic function
  assigned/passed/returned as a value type-checks**, with `(integer,...integer)` compatible with
  `(integer,...value)` both ways, and the two NOT `equals`; reject `...nil`, `...` outside its
  function, `...` in an inner lambda (and confirm a variadic lambda's own `...` resolves),
  `2,3,5,...` into 2 slots, `return ...` from `()->()`, `{...,1}`, `...` in a map/record
  constructor, passing `...` to a foreign function. `.so` rehydration of `varargtype`.
- **Coder:** scalar `#...`/`...[i]`(in-range; **OOB and `i<=0` → runtime error**)/`{...}`/
  `return ...`; collectable varargs with a forced GC in the body; called **from Lua**
  (`genluaentry`) with collectable varargs + GC; **as a first-class value** — tag-match fast path
  *and* a gradual-mismatch case (`(integer,...value)` slot holding a `(integer,...integer)`
  function) exercising the generic path + `genluaentry` coercion; nested forwarding (pass-through,
  start-adjust incl. `g(h1(...), h2(...))`, fresh-copy type-mismatch/prefix-grow, recursion);
  **overflow cap** (forwarding past 200 raises cleanly); `{...}` forcing GC across
  `luaH_resizearray`; `.so`-only import called statically and from Lua; `N == 0` empty vararg
  (`#...` 0, `...[1]` raises, `{...}` is `{}`).

---

## 8. Open questions — all resolved by owner

1. `TITAN_VARARG_MAX = 200`.
2. Ship the first-class function-type `...t` annotation in v1; **the fast-path type-tag builder in
   `codevaluecall` must see the vararg element** (§5.2 / §2.B).
3. Record varargs get their own `TitanVargNominal` (`Udata*`) struct — structs always match
   `ctype` (§2.F).
4. Empty vararg: `args[1]` with `n_args == 0` (§2.G).
5. New `varargtype` slot on `Type.Function`/`Method`/`StaticMethod`, distinct from the C-FFI
   `vararg` boolean (§4.1).
6. `start` is a separate `int _start` native parameter, not a struct field — forwarding is
   mutation-free (§2.G / §5.2 / §5.7).

---

## Appendix — corrections applied to the sketch (`doc/variadic-parameters.md`)

- `...[i]` typed `t?` → **`t`** with a raising bounds check; adjust-up is slot-driven raise/nil-fill (§2.A).
- Silent on first-class → **variadic functions are first-class values/methods**, dispatched by
  tag (fast native path on match, generic path on gradual mismatch); the value-call fast path
  builds the struct like any native call — no `CClosure`-ABI obstacle (§2.B).
- `lu_byte` kept (intentional), guarded by `TITAN_VARARG_MAX = 200` (§2.C).
- `start` removed from the struct → a separate native param; forwarding is mutation-free (§2.G/§5.7).
- Case-3 `Udata0` anchors only its own buffer; elements ride upstream anchors (§2.D).
- `return ...` is fixed-arity adjust-up, not a spread (§2.E).
- `#...` parses as a unop and is normalized in the checker; FAM is never a sized stack local
  (concrete-array + pointer pun, `args[1]` when empty); seven structs, one per `ctype` (record
  gets its own `Udata*`); `{...}` reads upstream-anchored elements directly (no pre-copy), with
  the table back barrier on store (§2.F/§2.G/§3.5/§5.6).
```
