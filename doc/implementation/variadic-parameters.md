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
[checker](#checker-varargtype-scope-and-the-explist-loops) (`checker.lua`,
`types.lua`), the [code generator](#code-generator-the-seven-structs-and-the-native-abi)
(`coder.lua`, the seven `TitanVarg*` structs in `titan-runtime/titan.h`), and
the [GC discipline](#gc-discipline-an-untraced-payload) the descriptor and
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
to `Ast.TypeFunction` (`{"loc","argtypes","rettypes","varargtype"}`), `false`
when absent.

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
bare `typelist` (a return-type list) deliberately does not accept a vararg.
`defs.typefunc` reorders the captures `(loc, argtypes, varargtype, rettypes)` so
the element type lands in the `Ast.TypeFunction.varargtype` slot.

### Spread and `...[e]`; `#...` as a unop

A trailing `...` spread is admitted as the last item of an explist (call args,
`return`, assignment/decl RHS) and of an array constructor:

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

## Checker: `varargtype`, scope, and the explist loops

The checker carries the vararg element type on a **new `varargtype` slot** on
the function-like types, resolves `...` uses through a depth-stamped pseudo-
symbol, and — its central job — turns every spread into either synthesized
`...[k]` reads (adjust-up) or a kept `ExpDots` marker (whole-tail).

### `Type.Function.varargtype` vs. the C-FFI `vararg` boolean

`types.lua` adds `varargtype` to `Type.Function`
(`{"params","rettypes","vararg","varargtype"}`) and to `Type.Method` /
`Type.StaticMethod`. It is **distinct** from the pre-existing `vararg` boolean,
which marks a *C-FFI* variadic (`foreigntypes.lua` sets `vararg = true`,
`varargtype = false`). A Titan variadic sets `varargtype = t`, `vararg = false`.
Consumers test `varargtype`; the two never mix. Four relations change:

* **`compatible`** (the `Type.Function` arm — only function *values* are
  compared structurally; `Type.Method`/`Type.StaticMethod` have no
  `compatible`/`equals` arm): after the fixed params and rettypes, the vararg
  *presence* must match (a variadic is never compatible with a non-variadic —
  they are structurally distinct), and when both are Titan-variadic the element
  types must be `compatible`. Because that is gradual, `(integer, ...: integer)`
  is compatible with `(integer, ...: value)` **both ways** (through `value`). The
  check is `if (v1 and true) ~= (v2 and true) then return false end`, then
  `compatible(v1, v2)`.
* **`equals`** (the `Type.Function` arm): the same presence rule, but element
  types compared with `equals`. So `...: integer` and `...: value` are **not** equal
  — which is exactly what gives them different runtime type tags and makes the
  first-class fast path fall back correctly on a gradual mismatch.
* **`serialize`**: emits the `varargtype` for Function and Method (so `.so`
  imports rehydrate it — part of the 0.9 ABI), keeping the C-FFI `vararg`
  boolean serialized and disjoint.
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
shares the same validation. Validation is `check_vararg_elem`, which enforces the
two **bans** (applied to the inferred/explicit lambda vararg element too):

* `...: nil` → `a variadic parameter cannot have type nil` (a typed `...: t` cannot
  hold nil, except where `t` is `value`/an option that already includes nil);
* a foreign-C-pointer element → `a variadic parameter cannot have a foreign
  pointer type` (no `TitanVarg*` struct exists for it).

Both return `types.Invalid()` so checking continues. `check_vararg_elem` also
validates the first-class-annotation element type, in `typefromnode`.

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

The resolved element is then run through `check_vararg_elem` (the same `nil` /
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
  return, an assignment, or an array constructor` — a *bare* `...` outside a
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

### The four explist loops: adjust-up vs. whole-tail

`StatDecl`, `StatAssign`, `StatReturn` and `checkargs` each detect a trailing
`Ast.ExpDots` and dispatch. The two outcomes:

* **Adjust-up** (into a `local`, an assignment, a `return`, or a call to a
  **non-variadic** callee) is *slot-driven*. With `deficit = nslots − nstatic`:
  `deficit < 0` is an over-supply error; `deficit == 0` drops the marker (a
  no-op); otherwise the trailing `ExpDots` is replaced by `deficit` synthesized
  `Ast.ExpDotsIndex` reads `...[1..deficit]`, each typed by the **consuming
  slot's** optionality — a non-optional slot gets `_nilfill = false`, `_type = t`
  (out-of-range **raises** — `local a, b, c = ...` requires `#... >= 3` at run
  time but type-checks), and an optional slot `s?` gets `_nilfill = true`,
  `_type = optionize(elem)`. The synthesized read is typed as the *real element
  wrapped*, not the slot type, so the caller's `trycoerce`/`checkmatch` inserts
  the genuine element→base conversion (e.g. `integer? → float?`) and rejects an
  incompatible element (e.g. `integer` into a `string?` slot). `StatDecl` and
  `StatReturn` inline this; `StatAssign` uses the shared
  `expand_dots_adjustup(exps, nslots, slottype, term, errors)`. `return ...`
  is therefore **adjust-up into the function's fixed return arity** [§2.E] —
  not a runtime-sized spread (returns 2..n lower to compile-time-indexed
  out-params, which have no variable-count mechanism); `return ...` from a
  zero-return function is an error.
* **Whole-tail** (a call to a **variadic** callee, dispatched on
  `ftype.varargtype` read before the multi-return `_types` expansion): the
  trailing `ExpDots` is **kept** as a marker for codegen. The caller's `...`
  element type must be `compatible` (gradual) with the callee's. Over-supplied
  static args (beyond the callee's fixed params) are each `trycoerce`d to the
  callee's element type. `checkargs` additionally handles the **start-adjust**
  shape, where the static prefix is *shorter* than the callee's fixed params:
  the missing fixed params are borrowed from the caller's own `...`; each
  borrowed fixed-param type must accept or coerce the caller's element type
  (`cannot borrow a '...' element of type %s for fixed parameter %d`). Codegen
  lowers those borrowed reads with `ExpDotsIndex` plus an ordinary `ExpCast`
  when needed, and uses nil-fill mode only for fixed parameter types that can
  accept nil. Passing `...` into a C-FFI variadic (`ftype.vararg`) is rejected
  (`cannot pass '...' to a foreign (C) variadic function`).

`...` is always the sole, last trailer; a list ending in both a multi-return
call and `...` is structurally impossible (`f(g(), ...)` truncates `g()` to one
value).

### Array `{...}`: backward typing

`ExpInitList`'s Array arm finds a trailing key-less `ExpDots` field
(`find_dots_field`, which also rejects `{..., 1}`: `'...' must be the last field
in an array constructor`). A `...` field in a map/record constructor is an
error (`'...' can only appear in an array constructor`). The element type is
**seeded from the vararg element first** — `etype = econtext or
deoptionize(dots_elem) or ...` — so `{...}` is `Array(t)`, **not** `Array(t?)`,
and a no-context `{...}` is `{t}`. The kept `ExpDots` marker carries through to
codegen. When a context overrides `etype` (e.g. `{...: integer}` in a `{float}`
context), the vararg element type must be `equals` or `coerceable` to `etype`,
else `'...' element type %s is not coerceable to array element type %s`.

### The coercion guarantee for codegen

After checking, every element destined for a `TitanVarg*` struct has been
`trycoerce`d to the element type, so each struct store is a plain
`setwrapped`/`setslot` of a value already of `ctype(t)`. The one gradual
boundary that needs a `value → t` check lives in `genluaentry` (below), not the
struct store.

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
record (`Type.Nominal`) gets its own `Udata*` struct with **no boxing**. The
coder picks the struct with `varg_struct_name(elemtype)`, keyed on the
`ctype(elemtype)` string via `varg_struct_by_ctype` (the Lua-side mirror of the
seven typedefs); a Pointer element has no entry and would `error`, but the
checker bans it first. Because the structs live in `titan.h` (which every
generated unit `#include`s), the coder emits no struct definitions.

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
params and before the out-params**:

```c
lua_Integer mod_f_titan(lua_State *L, Udata *_mod, CClosure *_fn,
                        lua_Integer _param_x,
                        TitanVargInteger *_varargs, int _start,   /* trailing, before out-params */
                        lua_Integer *_outparam_2);
```

They are not `ftype.params` entries; `ctype` is untouched. Instead all **four**
signature emitters special-case `ftype.varargtype` and must agree byte-for-byte:
`function_sig` (which also feeds the value-call fast-path typedef and so the
type-tag), `codefuncdec`'s cparams, `codelambdadec`'s cparams, and
`codemethodtrampoline` (a variadic method's bound trampoline forwards
`_varargs` + `_start` verbatim). `fixed_params` strips the trailing
`name == false` marker so the per-name param loop never emits a C parameter for
it. Each of `codefuncdec` and `codelambdadec` then threads the context:

```lua
ctx.varargs = { cname = "_varargs", start = "_start", elem = ftype.varargtype }
```

A lambda's `ctx` is fresh (`newcontext`), so `ctx.varargs` starts nil and is set
only for a variadic lambda — an inner lambda **never inherits** the enclosing
function's `...` (scope rule 4 enforced a second time, in codegen).

### `genluaentry` builds GC-anchored element storage plus a C-stack descriptor

The Lua entry wrapper (`genluaentry`), reached from `require`/Lua and the
generic value-call path, captures the incoming arg count *before* the
error-slot/errorhandler pushes inflate `L->top.p`, relaxes the arity check to
*at least* `nfixed` (`calling Titan function %s with %d arguments, but expected
at least %d`), then builds the struct from the surplus args:

1. `_vcount = _nargs − nfixed`; **cap-check** `_vcount <= TITAN_VARARG_MAX`,
   else raise; `lu_byte _nvarargs = (lu_byte)_vcount`.
2. Allocate the **element array** as a 0-uservalue `Udata` payload
   (`sizeudata(0, n * sizeof(elem))`), with `nuvalue = 0` and
   `metatable = NULL`, and **anchor it on the Lua stack**. The payload is
   runtime-sized and must survive any GC the per-element coercion triggers.
3. Build a small `TitanVarg*` descriptor on the C stack:
   `{ _nvarargs, (ElemCT *)getudatamem(_varargs_ud) }`.
4. Read each surplus arg `s2v(_vfunc + nfixed + 1 + j)` through the same
   `checkandget` coercion the fixed params use, into `_varargs->args[j]`; this
   is where the gradual `value → t` boundary check lives. Pass `_start = 0`.

The arg-base pointer (`_vfunc`) is recomputed after the `lua_checkstack`/push
that may have relocated the stack.

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

**`{...}` / `{e1, ..., ...}` (`codearray`)** detects a trailing `ExpDots` field
and switches to a runtime-sized build: the table is anchored, the static prefix
fields are evaluated into reserved slots, the array part is sized at runtime
from `nprefix + (n_args − _start)`, and a runtime loop stores each
`args[_start + j]` with `obj2arr` plus a **`luaC_barrierback`** per collectable
element (the table traces its array part). The driving struct/stride uses the
**real** vararg element type `va.elem` (the struct actually allocated), not the
array's declared element type, which a context may have overridden; when they
differ, each element is converted via a synthetic `ExpCast` before the wrapped
store. `return ...` needs no new codegen: the checker already expanded it into
`ExpDotsIndex` reads that lower to `*_outparam_i`.

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
   `TITAN_VARARG_MAX`, anchor the `Udata0` on a reserved slot, copy the static
   prefix (each gc prefix value anchored on its own slot first — §2.D) then each
   incoming `...` element converted to the callee element type (identical ctype →
   raw copy; a `value` widening → `setwrapped`; a `value` narrowing →
   `checkandget`), set `n_args`, pass `_start = 0`. The fresh allocation can
   relocate the Lua stack, so the function records
   `ctx.uses_base_off` and `_base` is recomputed from `_base_off` after the
   call.

### First-class value calls: dispatch by tag

A variadic function is an ordinary first-class value; `codevaluecall` dispatches
it exactly like a non-variadic value. The runtime function-type tag (a
`static const void *` published/recovered through the Lua registry, keyed by
`types.tostring(ftype)` so two modules agree) **folds in the vararg element**,
because `function_type_tag` keys on the full type string and `equals`
distinguishes `...: integer` from `...: value`. So:

* **Tag matches the static type** → the **native fast path**: build the struct
  (the same `emit_vararg_struct` cases 1–3, including a forwarded `...`) and
  call the native pointer through the fast-path typedef (`function_sig`, which
  includes the trailing `_varargs` + `_start`), with `_fn = _vc_callee`. The
  struct build is spliced into the *fast branch only* (`$VARGSTATS`), so a
  gradual mismatch never allocates it (and a case-3 `checkandget` cannot raise
  spuriously before the generic path runs).
* **Tag does not match** (a gradual `value` difference — e.g. a
  `(integer, ...: value)`-typed value holding a `(integer, ...: integer)` function)
  → the **generic Lua-stack path**: push the function and every fixed and
  surplus static arg, then (when forwarding) each `...` element one by one
  start-relative, and `luaD_callnoyield`; the callee's `genluaentry` coerces
  each surplus arg to its real element type and rebuilds the struct. This is the
  gradual boundary, same as for non-variadic value params.

`luaD_callnoyield` can relocate the stack, so `codevaluecall` sets
`ctx.uses_base_off` and recomputes `_base` afterward on both paths.

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

The current ABI is newer than this variadic change. It is bumped when other
separate-compilation surfaces change, such as record interface serialization.

The `.so`-only import path round-trips `varargtype` through serialize and is
covered by `spec/coder/so_import_spec.lua` and
`spec/checker/so_rehydration_spec.lua`. `spec/abi_spec.lua` pins the current
compiler/runtime ABI constants.

## GC discipline: descriptor pointers and untraced payloads

Runtime-sized element arrays live in a `Udata` raw payload (`getudatamem`), and
`traverseudata` marks only a userdata's `metatable` and its `uv[0..nuvalue-1]`
user values — **never `getudatamem`**. A 0-uservalue `Udata` (`nuvalue == 0`)
therefore has a payload that is *invisible* to the collector. The invariant the
codegen maintains [§2.D]:

> Every collectable element reachable through any vararg descriptor is
> independently anchored on a live Lua-stack slot for the descriptor's lifetime;
> an anchored `Udata0` only keeps the element buffer itself alive.

The descriptor may be a C-stack local. That is not a moving-GC hazard: Lua's GC
does not move objects, so a pointer to a `TString`, `Table`, `Udata`, or a
payload buffer remains valid across collection. Only pointers into Lua stack
locations need rebasing after stack growth/shrink.

This holds without per-element re-materialization, by LIFO stack discipline and
the fact that Lua's GC is **non-moving** (the *object* addresses an element
points to never change; only the stack array can relocate):

* **Pass-through elements** (the incoming `...`) stay alive via the *original
  caller's* stack anchors — for a native call the caller anchors gc args; for a
  Lua-originated call they *are* the Lua-stack arg slots — and those slots sit
  below every nested frame for the whole call chain.
* **Newly-introduced prefix elements** in a case-3 forward are ordinary
  arguments anchored by the normal "caller anchors gc args" path (the coder
  anchors each gc prefix value on a reserved slot *before* the `Udata0`
  allocation that may GC).
* **The `Udata0` itself** is stack-anchored so its *buffer* survives a GC during
  the copy/call; it has no `__gc`, no metatable, no `uv[]`. The descriptor that
  points at that buffer can stay on the C stack because it stores no Lua stack
  slot addresses.

Two more mechanical points:

* **`{...}` uses `luaC_barrierback`** per collectable element, because the table
  traces its array part and the fresh elements are old→young stores. Scalars
  skip the barrier.
* **Stack relocation across struct allocation / `luaH_resizearray`.** A fresh
  `Udata0` allocation (case-3, `genluaentry`) or a `luaH_resizearray` (in
  `{...}`) can shrink or grow and thus **relocate** the Lua stack, dangling the
  raw `_base` pointer. The codegen saves `_base` as an offset
  (`ctx.uses_base_off` makes the preamble declare `_base_off`) and rebases with
  `_base = restorestack(L, _base_off);` after the allocation/resize, so the
  subsequent reserved-slot reads and `obj2arr` stores use the live stack.
