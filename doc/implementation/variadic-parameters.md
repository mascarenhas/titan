# Variadic parameters

A Titan function, lambda, method or record function may end its parameter list
with a single **variadic parameter** `...: t` — the `name: type` declaration
style with no name, always the last parameter. Its element type is mandatory on
top-level functions, methods and function-type annotations; an anonymous
function may instead write a bare untyped `...` whose element type is inferred
from context (the [lambda inference](#untyped-lambda-vararg) path). Inside the declaring
function the parameter is reached through three forms — `#...` (count),
`...[e]` (1-based element), and a trailing **spread** (`f(a, ...)`,
`return a, ...`, `{a, ...}`, `{...}`) — and the same `...: t` syntax annotates a
first-class variadic **function type** (`(integer, ...: string) -> integer`).

The feature is deliberately *lightweight*: there is no slice type. The `...`
expression/parameter is **not first-class** — it cannot be captured by a
closure, stored, or escape its declaring function, and it is invisible to inner
lambdas — but the **function that declares it is** an ordinary first-class
value. This chapter walks the implementation across all four layers it touches:
the [parser](#parser-the-t-grammar) (`parser.lua`, `ast.lua`), the
[checker](#checker-varargtype-scope-and-shared-result-demand) (`checker.lua`,
`types.lua`), the [code generator](#code-generator-the-seven-structs-and-the-native-abi)
(`coder.lua`, the seven `TitanVarg*` structs in `titan-runtime/titan.h`), and
the [GC discipline](#gc-discipline-descriptor-pointers-and-untraced-payloads) the descriptor and
backing storage must respect. Background on the calling convention is in the
[code generator overview](codegen-overview.md); value representation and the
collector invariants in [values and the GC](values-and-gc.md).

Variadic support originally bumped the compiled-module **ABI to 0.9**; the
descriptor layout described here then bumped it to **0.10** (see
[the ABI bumps](#the-abi-bumps-09-and-010)).

## Parser: the `...: t` grammar

`lexer.lua` needs no change: `DOTS` (`...`) already lexes (the longest-match
loop makes `CONCAT`/`DOT` subtract it), and was previously a reserved-but-unused
token ([Lexer and parser](lexer-parser.md#one-grammar-no-token-stream)).

### Three new `Exp` nodes, and the no-name `Decl`

`ast.lua` adds three constructors to the `Exp` group:

```lua
ExpDots         = {"loc"},          -- bare `...`
ExpDotsIndex    = {"loc", "exp"},   -- `...[e]`  (checker sets _nilfill, _type)
ExpDotsLen      = {"loc"}           -- `#...`    (checker-normalized, below)
```

There is **no** new parameter node. A variadic parameter is encoded as an
ordinary trailing `Ast.Decl` whose `name` field is `false`
(`defs.varargdecl(pos, type)` builds `ast.Decl(pos, false, type or false, false)`),
so a function is variadic exactly when `params[#params].name == false`. An
**untyped** lambda vararg additionally has `type == false` — the same inverted
encoding an inferred lambda parameter uses (`name` set / `type == false`), but
with `name == false` too. The `false`-name convention threads through the
checker and coder, which detect and strip that marker. The function-type
annotation likewise gains no node flag: the new field `varargtype` is appended
to `Ast.TypeFunction`
(`{"loc","argtypes","rettypes","varargtype","flexrettype"}`), `false` when
absent. The independent final field describes a flexible *output* tail; see
[flexible-return internals](flexible-returns.md).

### Colon, last-only, trailing — the productions

A variadic parameter follows the `name: type` style with no name, so the rule
consumes `DOTS COLON` then a required element type. Two variants:

```
varargparam       <- (P  DOTS COLON^VarargColon type^TypeDecl) -> varargdecl
lambdavarargparam <- (P  DOTS (COLON type^TypeDecl)?)          -> varargdecl
```

`paramlist` uses `varargparam` (the `: t` is mandatory); `lambdaparamlist` uses
`lambdavarargparam`, where the `(COLON type)?` is **optional** — an absent type
yields an untyped vararg `Decl` whose element type the checker infers from
context. There is no ambiguity with the lambda return type: `function(...): T`
parses as an untyped vararg whose `)` precedes the return `:`, while
`function(...: T)` parses as a typed vararg (the `:` precedes the `)`). The
`VarargColon` syntax error fires when a top-level/method/function-type vararg
omits the colon (`...integer` and `function f(...)`).

Both are admitted only in trailing position. Both `paramlist` and
`lambdaparamlist` run the fixed-parameter loop with a `!DOTS` guard so the loop
stops before a `, ...`, letting the optional trailing `(COMMA varargparam)?`
(or a sole `varargparam`) consume that comma itself — which is what makes the
vararg structurally **last-only** (a `..., x` cannot parse). The whole list is
wrapped in a `=> checklist` predicate that throws `%{ListTooLong}` past
`LIST_LIMIT = 100` (a *parse-time* guardrail near `THIS_FILENAME`, distinct from
the runtime `TITAN_VARARG_MAX` cap).

The **function-type annotation** uses a parallel pair, `varargtypeann` /
`varargtypeopt`, inside `arglist` (the arrow productions); `varargtypeann`
requires the colon (`DOTS COLON^VarargColon type`) and defaults to `false`
when absent; `arglist`'s fixed-type loop carries the same `!DOTS` guard. The
bare input `typelist` does not double as a result-tail grammar. Return lists use
their own `...: t` carrier, so input and output tails cannot be confused.
`defs.typefunc` combines the argument carrier and result carrier so the two
element types land in `Ast.TypeFunction.varargtype` and `.flexrettype`
respectively.

### Spread and `...[e]`; `#...` as a unop

A trailing `...` spread is admitted as the last item of an explist (call args,
`return`, assignment/decl RHS) and of a positional container constructor:

```
explist <- {| ((P  DOTS !LBRACKET) -> ExpDots) |}
         / {| exp (COMMA exp^ExpExpList)^-99 (COMMA ((P  DOTS) -> ExpDots))? |}
           (&(COMMA exp) %{ListTooLong})?

field   <- (P  DOTS !LBRACKET)                 -> dots_field   -- `{ a, ... }`
         / (P  (key ASSIGN)? -> opt exp)       -> Field
```

`defs.dots_field` builds a key-less `Ast.Field` wrapping an `ExpDots`. Both
the explist and field forms guard the spread with `!LBRACKET`, because
`...[e]` is an ordinary expression, not a spread; that index form is a
`simpleexp` alternative placed **before** the bare-`...` one:

```
simpleexp <- ...
           / (P  DOTS LBRACKET exp^ExpExpSuf RBRACKET^RBracketExpSuf) -> ExpDotsIndex
           / (P  DOTS)                                                -> ExpDots
           / ...
```

`#...` is **not** a `simpleexp` rule. The `unop` cascade takes `#` greedily, so
`#...` parses as `Ast.ExpUnop("#", Ast.ExpDots)` and is normalized to an
`ExpDotsLen` later, in the checker (below). The only new syntax-error label is
`ListTooLong`; the rest reuse `ParamSemicolon`/`TypeDecl`/`ExpExpSuf`/
`RBracketExpSuf`.

## Checker: `varargtype`, scope, and shared result demand

The checker carries the vararg element type on a **new `varargtype` slot** on
the function-like types, resolves `...` uses through a depth-stamped pseudo-
symbol, and — its central job — turns every spread into either synthesized
`...[k]` reads (adjust-up) or a kept `ExpDots` marker (whole-tail).

### `Type.Function.varargtype` vs. `Type.CFunction.vararg`

`types.lua` adds `varargtype` to `Type.Function`
(`{"params","rettypes","vararg","varargtype","flexrettype"}`) and to
`Type.Method` / `Type.StaticMethod` (whose declaration descriptors also carry
`paramnames`). In the current ABI-0.24 `Type.Function`, the third positional
`vararg` field is a required **reserved `false` sentinel** retained only to keep
serialized constructor arity stable; it has no C or Titan variadic meaning. A
Titan variadic sets `varargtype = T`. A direct foreign declaration instead has
type `Type.CFunction(params, ret, vararg, abi)`, whose `vararg` boolean alone
means C `...`; it is never projected to `Type.Function`. Consumers of boxed
Titan/Lua callables test only `varargtype`, while the checker's private C call
view exposes the C bit as `c_vararg`. Four type operations change:

* **`callable_adjustment(source_actual, target_expected)`** plans the directional callable
  use. Parameter positions may move between the fixed prefix and the actual
  input tail; an actual function may ignore an expected fixed suffix.
  Additional actual fixed parameters receive the callable's enumerated
  missing-nil action; an expected input tail must also be safely observed in
  every such position. The expected output shape then observes
  the actual fixed/flexible results covariantly. No numeric, Option, or other
  automatic coercion is lifted through the callable shape. A missing expected
  fixed result may use the separate `nil_fill_result` action only under the
  shared nil-acceptance policy. See
  [flexible returns](flexible-returns.md#identity-and-callable-adjustment) and
  [closure adjustment wrappers](closure-adjustment-wrappers.md) for the
  complete raw/frozen matrix.
* **`equals`** remains exact structural identity: fixed positions, input-tail
  presence/type, and output-tail presence/type must all match. Thus
  `...: integer` and `...: value` are not equal, which gives them different
runtime tags even if a directional callable adjustment is legal.
* **`serialize`** emits `varargtype` for Function, Method, and StaticMethod (the
  historical 0.9 ABI change), alongside the independent `flexrettype` schema.
  It emits and validates `false` in the reserved Function position; a hostile
  non-false value is rejected. The latter tail is not accepted from compiled
  interfaces until the coordinated flexible-return ABI transition.
* **`tostring`**: appends `, ...: t` to the parameter list.

`typefromnode`'s `Ast.TypeFunction` handler reads `node.varargtype` and sets the
resulting `Type.Function.varargtype` (after validating the element type).

### The signature pass and the bans

The three signature visitors (`TopLevelFunc`, `TopLevelStatic`,
`TopLevelMethod`) all route through one helper, `param_types(params, st,
errors)`: it detects the trailing `name == false` `Decl`, drops it from the fixed
`ptypes` list, and returns its validated element type as the second value, which
the caller passes as `varargtype` to the type constructor. The lambda checker
(`Ast.ExpFunction`) does the same detection inline rather than calling
`param_types` (it also needs the `nfixed` count for context-arity matching), but
shares the same validation. Validation is the role-aware
`check_varg_elem(typ, loc, errors, "parameter")`, which enforces the two
**bans** (applied to the inferred/explicit lambda vararg element too):

* `...: nil` → `a variadic parameter cannot have type nil` (a typed `...: t` cannot
  hold nil, except where `t` is `value`/an option that already includes nil);
* a foreign-C-pointer element → `a variadic parameter cannot have a foreign
  pointer type` (no `TitanVarg*` struct exists for it).

Both return `types.Invalid()` so checking continues. The same helper, with
role `"return"`, validates flexible result elements; `typefromnode` uses it for
both tails in a first-class annotation.

### Untyped lambda vararg inference {#untyped-lambda-vararg}

A lambda's vararg `Decl` may carry `type == false` (the parser's untyped form).
The `Ast.ExpFunction` visitor resolves the vararg element type after it has
computed `nfixed` and the `expected` context type (so the order is: count the
fixed params, derive `expected` from the context iff it is a `Type.Function`
whose `#params == nfixed`, then resolve the vararg). The resolution mirrors the
untyped-fixed-parameter path:

* explicit `...: t` → `typefromnode(varargdecl.type, …)` (context ignored);
* untyped `...`, variadic context → take `expected.varargtype` as the element;
* untyped `...`, context present but **non-variadic** (`expected.varargtype` is
  `false`) → `cannot infer the type of '...'; the lambda is variadic but the
  expected type is not`;
* untyped `...`, **no usable context** → `cannot infer the type of '...';
  annotate it or use the lambda where its type is known`.

The resolved element is then run through `check_varg_elem` (the same `nil` /
foreign-pointer bans). Top-level functions, methods and function-type
annotations never reach this path — their `...: t` is mandatory at the parser.

### Depth-stamped `$vararg` and scope rule 4

`...` is **invisible to inner lambdas**, which is *not* ordinary lexical scoping
(`find_symbol` walks every enclosing block). `checkfuncbody` installs a
side-channel symbol for a variadic function:

```lua
if node._type.varargtype then
    st:add_symbol("$vararg",
        { elem = node._type.varargtype, funcdepth = #func_stack })
end
```

stamped with the current function-nesting depth (`#func_stack`, mirroring
`_funcdepth` — see [closures](checker.md#closures-capture-analysis-and-lambda-inference)).
Every `...`/`#...`/`...[e]` resolves through `resolve_vararg`, which finds the
symbol but rejects it when `vararg.funcdepth ~= #func_stack`: an inner lambda
walking the symbol table finds the enclosing `$vararg` but its stamped depth
differs, so the use is `'...' is not visible inside an inner function`. A use
with no `$vararg` at all is `'...' can only be used inside a variadic function`.
A variadic lambda installs its own `$vararg` at its own depth, so its own `...`
resolves.

### The three `checkexp` arms and the `#...` rewrite

* **`Ast.ExpDots`** resolves `$vararg` (so scope diagnostics fire) and then
  reports `'...' can only be used as the last item of an argument list, a
  return, an assignment, or a positional array/integer-keyed map constructor`
  — a *bare* `...` outside a
  spread position is an error. In the legal spread positions the consuming loop
  intercepts the marker before it reaches this arm, calling `check_dots_marker`
  (which resolves `$vararg` onto `node._vararg_elem` **without** the bare-`...`
  error).
* **`Ast.ExpDotsLen`** sets `node._type = Integer` (after resolving `$vararg`).
  The `#` arm of `Ast.ExpUnop` special-cases `node.exp._tag == "Ast.ExpDots"`:
  it builds an `ExpDotsLen`, checks it, and **rewrites the node in place**
  (`for k in pairs(node) do node[k] = nil end` then copies the `ExpDotsLen`
  fields), bypassing the array/string `#` path that would choke on a bare `...`
  operand.
* **`Ast.ExpDotsIndex`** checks the index against `integer` (`trycoerce` +
  `checkmatch`, term `"variadic index"`), defaults `_nilfill = false`, and types
  the node `t` — **not `t?`** [OWNER §2.A]. This is the deliberate divergence
  from array indexing (`a[i]` is `t?` because Lua arrays have holes): the vararg
  struct is dense, codegen bounds-checks and **raises** on out-of-range, and
  that raise is what licenses the non-optional element type. Adjust-up synthesis
  (next) flips `_nilfill = true` / `_type = s?` for an optional target slot.

### Shared finite/open expression-list demand

Declarations, assignments, returns, calls, positional Array/integer-Map
constructors, and the generic-for setup tuple all use `result_demand` plus
`adjust_explist`; there are no longer four
independent spread loops. The adjustment record keeps every written expression
in lexical order, separates fixed deliveries from scalar/open tail deliveries,
and marks surplus expressions that must still run only for effect.

For a **finite demand**, a trailing `Ast.ExpDots` is projected into only the
needed synthesized `Ast.ExpDotsIndex` reads. Each read follows the consuming
slot: an optional/nil-compatible target can nil-fill and gets an option-shaped
source, while an ordinary non-nil fixed call argument retains the raising
bounds check. The generic-for tuple is the deliberate exception: its
`dots_nilfill = true` option makes missing state/control projections nil, as
Lua's iterator setup requires. If the finite demand is already full, `...` is
not read. Explicit surplus expressions are checked, evaluated, and discarded;
`return ...` in a zero-result function is therefore an effect-free discard,
not an arity error.

For an **open demand**, the final marker remains the single runtime-sized
`open_source`. Input-variadic calls receive the remaining run after any fixed
borrows; a function with `flexrettype` can forward it from `return ...`; and a
final positional Array or exact integer-Map field appends it. Static tail
scalars are coerced to the consumer's element/value type. Codegen can pass an
equal-representation input run by
descriptor/start view, or allocate and convert a fresh run when the static
prefix or element representation changes.

Passing a runtime-open Titan run into a C-FFI variadic remains an error: the
checker-local call view sees `Type.CFunction.vararg` as `c_vararg`, and the
typed Titan descriptor has no C default-promotion contract. Finite written
arguments still use ordinary C default promotions.

`...` is always the sole, last trailer; a list ending in both a multi-return
call and `...` is structurally impossible (`f(g(), ...)` truncates `g()` to one
value).

### Positional `{...}`: backward typing

`ExpInitList` recognizes a trailing key-less `ExpDots` field in an
all-positional Array or exact integer-keyed Map (and rejects `{..., 1}`:
`'...' must be the last field in a positional constructor`). A `...` field in
a computed Map or record constructor is an error. The element/value type is
**seeded from the vararg element first** — `etype = econtext or
deoptionize(dots_elem) or ...` — so a no-context `{...}` is `Array(t)`, not
`Array(t?)`, while an exact `{integer: V}` context selects Map. The kept
`ExpDots` marker carries through to codegen. A contextual target must accept
the vararg element type or checking reports the ordinary positional
initializer coercion error. The shared `_positional_adjustment` can likewise
name a trailing flexible-result call as its open source.

### The adjustment guarantee for codegen

After checking, every static element destined for a `TitanVarg*` struct has
an attached `assignment_adjustment` to the element type, so its store consumes
the ordinary plan lowering. Runtime run-to-run conversion uses the same
per-element plan. A strict `value → t` guard can therefore appear in a realized callable
wrapper's native adapter, the branded generic fallback, a fresh forwarding
copy, or a flexible result-run consumer; it is never replaced by a
representation cast. The genuine-Lua entry instead consumes the corresponding
`DynamicCoercionPlan`.

An adjusted Interface method uses this same descriptor ABI for an input tail.
Its checker-frozen adapter records the run actions, element guard/injection,
roots, and rebases in advance; the coder validates and renders that closed
plan without asking consistency or coercion again. In particular, a scalar
concrete-to-Interface coercion is not lifted into a variadic component.

## Code generator: the seven structs and the native ABI

### Seven `TitanVarg*` structs, one per `ctype`

`titan-runtime/titan.h` declares seven descriptor structs, one per element
`ctype`, so `args` has the exact element pointer type (no punning):

```c
typedef struct { lu_byte n_args; lua_Integer *args; } TitanVargInteger;
typedef struct { lu_byte n_args; lua_Number  *args; } TitanVargFloat;
typedef struct { lu_byte n_args; int         *args; } TitanVargBoolean;
typedef struct { lu_byte n_args; TString    **args; } TitanVargString;
typedef struct { lu_byte n_args; Table      **args; } TitanVargArrayOrMap;
typedef struct { lu_byte n_args; TValue      *args; } TitanVargValue;
typedef struct { lu_byte n_args; Udata      **args; } TitanVargNominal;
#define TITAN_VARARG_MAX 200
```

Scalars are unboxed; collectable elements are raw pointers (`TString*`,
`Table*`); `value`/option/function elements are tagged 16-byte `TValue`s; a
record (`Type.Nominal`) and an owned C value (`Type.COwned`) use the
`Udata*`/`TitanVargNominal` family with **no extra boxing**. The coder normally
picks the struct with `varg_struct_name(elemtype)`, keyed on the
`ctype(elemtype)` string via `varg_struct_by_ctype` (the Lua-side mirror of the
seven typedefs). `COwned` is selected semantically rather than from rendered C
declarator whitespace. A Pointer element has no entry and would `error`, but
the checker bans it first. Because the structs live in `titan.h` (which every
generated unit `#include`s), the coder emits no struct definitions.
The same family serves flexible *output* runs. Ownership distinguishes the
directions: an input descriptor is a borrowed view of caller arguments, while
an output descriptor points at capacity supplied by the caller and the callee
sets `n_args` to the number actually produced.

Two design points [§2.C / §2.G]:

* **`n_args` is `lu_byte`**, an *intentional* cap that keeps the struct small
  and bounds static sizing — `TITAN_VARARG_MAX = 200`. Statically-known counts
  are bounded by the parser's `LIST_LIMIT = 100`, so they never trip; runtime
  counts from forwarding/merge and the generic entry are bounds-checked and
  raise a clean Titan error past 200. Functions needing very large homogeneous
  arg counts use an explicit `{T}` parameter instead.
* **`start` is NOT a struct field** — it travels as a separate `int _start`
  native parameter. `n_args` is the *total backing* count; a callee's logical
  view is `args[start .. n_args-1]`, length `n_args − start`. Keeping `start`
  out of the struct makes forwarding mutation-free: a callee just computes and
  passes a different `_start` against a shared, immutable struct.

At a static call site where the count `N` is a compile-time constant, the coder
emits a typed C array for the elements plus a named descriptor that points at
that array:

```c
lua_Integer _vargargs_3[N] = { a, b };
TitanVargInteger _varg_3 = { N, _vargargs_3 };
f(L, _mod, _fn, /* params... */ &_varg_3, /* _start = */ 0, /* out... */);
```

Both locals are ordinary C-stack objects. That is safe because the descriptor
stores only a count and a pointer to element storage. For collectable element
types, the elements are pointers to Lua GC objects (`TString*`, `Table*`,
`Udata*`) or tagged `TValue`s; Lua's GC does not move those objects. The stack
relocation hazard is pointers to Lua **stack slots**, and the descriptor does
not store those.

For an **empty** static vararg the coder still emits a one-element C array with
`n_args == 0` and `{ 0 }`; the bounds checks guarantee `args` is never read.

### The native ABI: trailing `_varargs` + `_start`

A variadic function's native signature gains the two items **after the declared
params and before the out-params**. If the same function also has a flexible
result, its `_flexout`/`_flexwant` pair follows every fixed out-parameter:

```c
lua_Integer mod_\u2133_f_titan(lua_State *L, Udata *_mod, CClosure *_fn,
                        lua_Integer _param_x,
                        TitanVargInteger *_varargs, int _start,   /* trailing, before out-params */
                        lua_Integer *_outparam_2,
                        TitanVargString *_flexout, int _flexwant); /* output tail is last */
```

They are not `ftype.params` entries; `ctype` is untouched. Instead all **four**
signature emitters special-case `ftype.varargtype` and `ftype.flexrettype` and
must agree byte-for-byte:
`function_sig` (which also feeds the value-call fast-path typedef and so the
type-tag), `codefuncdec`'s cparams, `codelambdadec`'s cparams, and
`codemethodtrampoline` (a variadic method's bound trampoline forwards
`_varargs` + `_start` verbatim and likewise passes `_flexout` + `_flexwant`).
`fixed_params` strips the trailing
`name == false` marker so the per-name param loop never emits a C parameter for
it. Each of `codefuncdec` and `codelambdadec` then threads the context:

```lua
ctx.varargs = { cname = "_varargs", start = "_start", elem = ftype.varargtype }
```

A lambda's `ctx` is fresh (`newcontext`), so `ctx.varargs` starts nil and is set
only for a variadic lambda — an inner lambda **never inherits** the enclosing
function's `...` (scope rule 4 enforced a second time, in codegen).

### `genluaentry` builds GC-anchored element storage plus a C-stack descriptor

The two Lua-stack entries (`genluaentry`) capture the incoming user-argument
count *before* the
error-slot/errorhandler pushes inflate `L->top.p`, pads a short fixed prefix
with nil, then builds the struct from every argument beyond `nfixed`:

1. `_vcount = _nargs − nfixed`; **cap-check** `_vcount <= TITAN_VARARG_MAX`,
   else raise; `lu_byte _nvarargs = (lu_byte)_vcount`.
2. Allocate the **element array** as a 0-uservalue `Udata` payload
   (`sizeudata(0, n * sizeof(elem))`), with `nuvalue = 0` and
   `metatable = NULL`, and **anchor it on the Lua stack**. The payload is
   runtime-sized and must survive any GC the per-element coercion triggers.
3. Build a small `TitanVarg*` descriptor on the C stack:
   `{ _nvarargs, (ElemCT *)getudatamem(_varargs_ud) }`.
4. Read each surplus arg `s2v(_vfunc + nfixed + 1 + j)` through the same
   policy as fixed parameters: `DynamicCoercionPlan` for the genuine-Lua
   entry, strict `GuardPlan` for the branded Titan adapter. Store it in
   `_varargs->args[j]` and pass `_start = 0`. The strict adapter excludes its
   hidden original-closure argument from `_vcount`.

The entry first calls `titan_ensure_stack`, which raises normally if
`lua_checkstack` cannot reserve the payload anchor. The arg-base pointer
(`_vfunc`) is recomputed after that reservation/push because it may have
relocated the stack.

### Lowering `...[i]`, `#...`, and `{...}`

A callee's view is `args[_start .. n_args-1]`, length `n_args − _start`. All
three forms read off `ctx.varargs`.

**`...[i]` (`codedotsindex`)** materializes the index into a temp (the bounds
check and the read both reference it, and the operand may have side effects),
then bounds-checks `1 <= i <= n_args − _start`:

```c
lua_Integer _vi = $INDEX;
if (TITAN_UNLIKELY(_vi < 1 || _vi > ((lua_Integer)_varargs->n_args - _start)))
    luaL_error(L, "%s:%d:%d: variadic index %I out of range [1, %d]", ...);   /* _nilfill == false */
$RESULT = _varargs->args[_start + _vi - 1];
```

For `_nilfill == false` (user `...[i]`, non-optional adjust-up) out-of-range
raises and the result is the unboxed `ctype(t)` value, type `t`. For
`_nilfill == true` (optional adjust-up) out-of-range yields nil and the result
is a `t?` `TValue`, mirroring the `codeindexarray` option branch.

**`#...` (`ExpDotsLen`)** is the bare expression
`((lua_Integer)_varargs->n_args - _start)`.

**`{...}` / `{e1, ..., ...}` (`codearray` or positional `codemap`)** receives
the trailing `ExpDots` as the adjustment's open source and switches to a
runtime-sized build. The static prefix is evaluated into reserved roots, then
the actual run count determines capacity. Array lowering creates the
backing/proxy pair with `titan_array_new`, stores into positive backing slots,
barriers collectable elements, and records the highest non-nil position as
logical length. Positional Map lowering pre-sizes and fills an ordinary Table.
The driving struct/stride uses the **real** vararg element type `va.elem`;
when the contextual target differs, each element uses the ordinary typed
conversion. A final flexible-result call uses the same result-run consumer.

`return ...` uses finite `ExpDotsIndex` projections for fixed result slots and,
when the current function has `flexrettype`, preserves the remaining input run
as the output open source. `codereturn` copies at most the inherited
`_flexwant`, sets `_flexout->n_args`, and leaves surplus unread when the finite
budget has already been satisfied.

### Static call sites: three forwarding cases

At a static native call to a variadic callee (`codecall`, factored into
`emit_vararg_struct`), the `_varargs` + `_start` pair is inserted at the pinned
ABI slot. There are three cases, all mutation-free now that `start` is a
parameter:

1. **Pass-through** — caller static count equals the callee's fixed-param count
   and the element representation matches: pass the current `_varargs` and
   `_start` unchanged. No allocation.
2. **Start-adjust** — caller static args are fewer than the callee's fixed
   params, element types match: synthesize `...[1..delta]` reads for the missing
   fixed params (bounds-checked, raising if too few), then pass the **same**
   struct with `_start + delta`. No struct mutation, no save/restore.
3. **Fresh copy** — element representations differ, or caller static args exceed
   the callee's fixed params (the prefix grows the tail). Allocate fresh
   `Udata0` element storage (with `luaC_newobj` + `getudatamem`), build a
   C-stack descriptor pointing at it, **cap-check** the runtime count against
   `TITAN_VARARG_MAX`, anchor the freshly allocated `Udata0` on a reserved slot,
   copy the C-only static prefix and then each incoming `...` element converted
   to the callee element type (identical ctype → raw copy; a `value` widening →
   `setboxed`; a `value` narrowing → the checker-attached strict guard), set
   `n_args`, and pass `_start = 0`. No native input gets a tracing-only element
   slot; its existing allocation/result/semantic/VM provenance remains live, and
   a conversion that allocates a fresh wrapper roots that destination. The fresh allocation can
   relocate the Lua stack, so the function records
   `ctx.uses_base_off` and `_base` is recomputed from `_base_off` after the
   call.

### First-class value calls: dispatch by tag

A variadic function is an ordinary first-class value; `codevaluecall` dispatches
it exactly like a non-variadic value. The runtime function-type tag is a
`static const void *` published/recovered through the Lua registry. C-free
callable shapes use the full `types.tostring(ftype)` key so different modules
agree. A C-bearing shape uses that diagnostic spelling in the defining module's
private tag namespace, and the module-local cache separately marks C-bearing
keys so a C typedef whose spelling resembles a Titan type cannot alias it. The
tag **folds in the vararg element** because the full callable shape
distinguishes `...: integer` from `...: value`. So:

Before dispatch, a statically known non-exact callable cast may conditionally
construct a fresh target-tagged wrapper. It freezes the source once in C while
borrowing its existing traced provenance, requires an exact branded source tag
and one free upvalue, and otherwise leaves the carrier unchanged. Only the fresh
wrapper branch writes the reserved allocation root.

* **Tag matches the static type** → the **native fast path**: build the struct
  (the same `emit_vararg_struct` cases 1–3, including a forwarded `...`) and
  call the native pointer through the fast-path typedef (`function_sig`, which
  includes the trailing `_varargs` + `_start`), with `_fn = _vc_callee`. For a
  source closure the pointer names its body; for a realized wrapper it names
  the target adapter, which builds A's fixed/tail view and delegates to the
  immediate source. The target typed tail is therefore enforced on the exact
  path. `$VARGSTATS` remains inside the selected native branch.
* **Tag differs but is branded** (a dynamic Function view or wrapper-ineligible
  carrier) → the **strict generic Lua-stack path**: push the closure's final
  strict light C function, the closure as a hidden carrier, every fixed and
  surplus static argument, and any forwarded `...` elements. An ordinary
  source uses its declaration entry; a wrapper uses its consumer target relay.
  The strict shell rebuilds descriptors with `GuardPlan`s before the source or
  target-adapter native call.
* **The value is not a branded Titan closure** → the ordinary Lua generic path
  calls the Lua closure, C function, or `__call` value. A static adjustment
  never wraps it. It receives arguments already adjusted to the static callable
  shape and boxed for Lua; results entering Titan use the canonical
  `DynamicCoercionPlan`, including numeric conversions and truthiness.

`luaD_callnoyield` can relocate the stack, so `codevaluecall` sets
`ctx.uses_base_off` and recomputes `_base` afterward on every stack path.
The same exact tag also folds in `flexrettype`. On a matching native path the
caller supplies the flexible output descriptor directly. On either generic path a
finite sink requests its exact Lua result count; an open sink for a statically
flexible producer uses `LUA_MULTRET`, preserves the actual count, and converts
the suffix into the shared result run with strict guards for branded Titan
values and dynamic conversion otherwise before resetting the Lua stack.
Thus input and output tails share descriptor representations without changing
which branch owns the boundary policy.

## The ABI bumps (0.9 and 0.10)

Variadic support bumped `titan-runtime/titan.h` from `TITAN_VER "0.8"` to
`"0.9"` and `TITAN_VER_SUFFIX "_0_8"` to `"_0_9"` (which also moved the
compiled-module search-path suffix and the `TITAN_PATH_0_9` env var). Two
cross-`.so` ABI surfaces changed: a variadic function's native signature gained
the trailing `TitanVargX *` + `int _start` pair, and `<mangled>_types` began
encoding the `varargtype` element type for variadic functions and methods. A
0.8 module has neither, so 0.8 and 0.9 `.so`s are ABI-incompatible.

The `0.10` ABI (`TITAN_VER_SUFFIX "_0_10"`,
`TITAN_PATH_0_10`) changed the `TitanVargX` family from an inline
flexible-array object (`lu_byte n_args; T args[]`) to a descriptor
(`lu_byte n_args; T *args`). The native parameter type name stayed the same, but
the struct layout did not; mixing 0.9 and 0.10 modules would misread the bytes
after `n_args`, so they must live under different `TITAN_PATH` directories.

The current ABI is **0.24**, newer than this variadic change. Flexible outputs
reuse these descriptors but add `flexrettype` to serialized callable shapes and
`_flexout`/`_flexwant` to native signatures. They shipped as ABI 0.14 rather
than accepting both layouts under one marker. ABI 0.17 introduced the current
Array boundary while leaving `TitanVargArrayOrMap` as `Table **`: exact Array
elements remain internal backing Tables, while generic/Lua-visible runs box
them as proxies. ABI 0.18 and 0.19 preserved that descriptor contract; ABI
0.20 kept it while adding the Array writer user value and callable
strict-entry trailer; 0.21 retained those descriptors while advancing the
embedded Lua contract to 5.5.1, and ABIs 0.22 through 0.24 retain them. ABI
0.24 also retains the historical third `Function` constructor position as
`false`; separating
direct `CFunction` declarations is checker-internal and does not alter that
schema or native convention. Closure adjustment wrappers reuse the same
descriptor/native signature and add only private
consumer adapter/relay artifacts, so this optimization does not advance the
ABI. See [Dense Arrays](dense-arrays.md#internal-and-boxed-representations) and
[Closure adjustment wrappers](closure-adjustment-wrappers.md#abi-and-ownership-rationale).

Compiled-interface import paths round-trip `varargtype` through the same
serialization, whether recovered from DSO callables or an archive metadata
section. The DSO path remains covered by `spec/coder/so_import_spec.lua` and
`spec/checker/so_rehydration_spec.lua`; static compiled-module suites cover the
archive path. `spec/abi_spec.lua` pins the current compiler/runtime ABI
constants.

## GC discipline: descriptor pointers and untraced payloads

Runtime-sized element arrays can live in a `Udata` raw payload
(`getudatamem`), and `traverseudata` marks only a userdata's `metatable` and its
`uv[0..nuvalue-1]` user values—**never `getudatamem`**. A zero-uservalue Udata
therefore keeps its byte buffer allocated but does not trace GC pointers copied
into that buffer. Generated code maintains the stronger provenance invariant:

> Every collectable element reachable through a live vararg descriptor remains
> reachable from an independent traced owner for the descriptor's lifetime. The
> owner may be a semantic variable/container home, an immediate allocation or
> native-result root, an actual Lua VM argument slot, or an explicit flexible
> result/destination range. The descriptor and raw backing are never owners.

A Titan native call keeps fixed/static and forwarded open inputs in C and does
not create per-call element roots. A pass-through input run borrows whatever
provenance already owns each element. A newly evaluated prefix likewise retains
its source home, or the immediate root installed by its allocation/native-result
expression. If element conversion allocates a callable/Interface wrapper, that
fresh destination receives its own fixed/range allocation root. A Lua-originated
entry is different only because its incoming stack slots are the actual VM
arguments.

For flexible outputs the descriptor backing is caller-owned C storage. After a
native call and rebase, every live GC-bearing result prefix is copied immediately
into a parallel traced Lua-stack range and cleared only after its sink consumes
it. This includes identity source runs inside callable/Interface adapters, not
just runs followed by allocating conversion. Finite projected GC results receive
their ordinary immediate caller result roots. A pending return crossing
`finally` separately saves the run count and keeps the saved elements traced
until the pending action resumes or is superseded by a raise.

The descriptor may be a C-stack local. That is not a moving-GC hazard: Lua's GC
does not move objects, so a pointer to a `TString`, `Table`, `Udata`, or payload
buffer remains valid across collection. Only pointers into Lua stack locations
need rebasing after stack growth/shrink. A case-3 `Udata0` itself is immediately
rooted so its *buffer* survives copy/call; it has no `__gc`, metatable, or traced
user values, and therefore does not own collectable elements stored in that
buffer.

Two more mechanical points:

* **`{...}` uses `luaC_barrierback`** per collectable element, against the
  Array backing or ordinary positional-Map Table. Scalars skip the barrier.
* **Stack relocation across struct/container allocation.** A fresh
  `Udata0` allocation (case-3, `genluaentry`) or `titan_array_new`/Table resize
  in `{...}` can shrink or grow and thus **relocate** the Lua stack, dangling the
  raw `_base` pointer. The codegen saves `_base` as an offset
  (`ctx.uses_base_off` makes the preamble declare `_base_off`) and rebases with
  `_base = restorestack(L, _base_off);` after the allocation/resize, so the
  subsequent reserved-slot reads and `obj2arr` stores use the live stack.
