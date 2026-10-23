# Variadic parameters

A Titan function, lambda, method or record function may end its parameter list
with one **variadic parameter** `...: t`: a nameless `name: type` declaration
that is always last. Its element type is mandatory on top-level functions,
methods and function-type annotations; an anonymous function may write a bare
untyped `...` whose element type is [inferred from context](#untyped-lambda-vararg-inference).
Inside the declaring function the parameter is reached through `#...` (count),
`...[e]` (1-based element), and a trailing spread (`f(a, ...)`, `return a, ...`,
`{a, ...}`). The same `...: t` syntax annotates a first-class function type
(`function (integer, ...: string): (integer)`). The language rules are in the
[variadic parameters chapter](../language/variadic-parameters.md).

There is no slice type. `...` is **not first-class**: it cannot be captured,
stored, or escape its declaring function, and it is invisible to inner lambdas.
The function that declares it is an ordinary first-class value. This chapter
covers the [parser](#parser-and-ast-encoding), the
[checker](#checker-varargtype-scope-and-shared-result-demand), the
[code generator](#code-generator-the-seven-structs-and-the-native-abi), and the
[GC discipline](#gc-discipline-descriptor-pointers-and-untraced-payloads) for
the descriptor and its backing storage. The calling convention is in the
[code generator overview](codegen-overview.md#the-titan-native-function-and-its-calling-convention);
value representation and collector invariants are in
[values and the GC](values-and-gc.md). Flexible *output* tails reuse the same
descriptors; see [flexible-return internals](flexible-returns.md).

## Parser and AST encoding

`DOTS` (`...`) is an ordinary lexer token
([Lexer and parser](lexer-parser.md#one-grammar-no-token-stream)).

### `Exp` nodes and the nameless `Decl`

`ast.lua` has three variadic `Exp` constructors:

```text
ExpDots         = {"loc"},          -- bare `...`
ExpDotsIndex    = {"loc", "exp"},   -- `...[e]`  (checker sets _nilfill, _type)
ExpDotsLen      = {"loc"}           -- explicit `#...`
```

There is no parameter node. A variadic parameter is an ordinary trailing
`Ast.Decl` whose `name` is `nil` (`parser.lua` `defs.varargdecl`), so a function
is variadic exactly when `params[#params].name == nil`. An untyped lambda vararg
additionally has `type == nil`. The checker (`param_types`, the
`Ast.ExpFunction` visitor) and the coder (`fixed_params`) detect and strip that
marker. The `foreignvararg` production reuses the same nameless, untyped
marker for C `...` in a source `foreign function`.

A function-type annotation stores its input tail in
`Ast.TypeFunction.varargtype` (`{"loc","argtypes","rettypes","varargtype","flexrettype"}`),
`nil` when absent. The independent `flexrettype` is the output tail.

### Parameter and function-type lists

The `varargparam` production requires `...: T`; `lambdavararg` makes the
annotation optional. The fixed-parameter loop stops at `...`, so an input tail
is last-only. Parameter lists keep the 100-item written-parameter guard, which
is unrelated to the runtime vararg capacity.

Function types begin with `function`. Their `typelist` and `resulttypes`
productions collect fixed types plus an optional final `...: T`, and
`split_types` separates the fixed list from the tail. Type and result lists do
not inherit the declaration-parameter count guard; the checker and calling
convention apply result limits at their consumers.

### Vararg atoms, spreads, and semantic placement

Bare `...` is a `baseexp` atom, so `...[index]`, `...[first, last]`, `#...`,
and collection spreads share one dispatch, described in
[Spread expressions](spread-expressions.md#parser-and-ast-ownership). The
parser preserves markers in every expression-list position. Shared checker
adjustment, not the parser, rejects an unparenthesized vararg or spread before
the final expanding position. A parenthesized `(...)` requests exactly one
value.

## Checker: `varargtype`, scope, and shared result demand

The checker carries the vararg element type in a `varargtype` slot on the
function-like types and resolves `...` uses through a depth-stamped
pseudo-symbol. A trailing bare `...` becomes either synthesized `ExpDotsIndex`
reads (finite demand) or a kept `ExpDots` marker (open demand). Collection and
ranged spreads use a retained `ExpSpread` carrier instead; see
[Spread expressions](spread-expressions.md#checker-planning).

### `Type.Function.varargtype` vs. `Type.CFunction.vararg`

`types.lua` has `varargtype` on `Type.Function`
(`{"params","rettypes","vararg","varargtype","flexrettype"}`) and on
`Type.Method` / `Type.StaticMethod`, whose declaration descriptors also carry
`paramnames`. The third `Type.Function` field `vararg` is a required reserved
`false` sentinel that keeps the serialized constructor arity stable; it has no
variadic meaning. A Titan variadic sets `varargtype = T`. A direct foreign
declaration instead has `Type.CFunction(params, ret, vararg, abi)`, whose
boolean `vararg` means C `...`; it is never projected to `Type.Function`.
Consumers of boxed Titan/Lua callables test only `varargtype`; the checker's
private C call view exposes the C bit as `c_vararg` (`checker/c_types.lua`).

The tail participates in every structural type operation:

* **`callable_adjustment(source_actual, target_expected)`** may move
  parameter positions between the fixed prefix and the actual input tail. The
  directional rules are in
  [Type relations](type-relations-and-boundaries.md#callable-adjustment-rules);
  wrapper realization is in
  [Closure adjustment wrappers](closure-adjustment-wrappers.md).
* **`equals`** is exact structural identity, including input-tail presence and
  element. `...: integer` and `...: value` are therefore unequal and get
  different runtime function tags, even where a directional adjustment is
  legal.
* **`serialize`** emits `varargtype` and `flexrettype` for Function, Method,
  and StaticMethod, and `false` in the reserved Function position. The
  validator in `driver.lua` rejects a non-false reserved value on recovery.
  The serialized form is described in
  [Lua entries and ABI metadata](codegen-overview.md#lua-entries-and-abi-type-and-layout-metadata).
* **`tostring`** appends `, ...: t` to the parameter list.

`typefromnode`'s `Ast.TypeFunction` handler validates `node.varargtype` and
sets `Type.Function.varargtype`.

### The signature pass and the bans

The signature visitors for `TopLevelFunc`, `TopLevelStatic` and
`TopLevelMethod` call `param_types(params, st, errors)` (`checker/common.lua`),
which returns `ptypes, varargtype, paramnames`: it drops the trailing nameless
`Decl` from the fixed list and validates its element type. The lambda checker
(`Ast.ExpFunction`) detects the tail inline because it also needs `nfixed` for
context matching. Both validate with
`check_varg_elem(typ, loc, errors, "parameter")` (`checker/common.lua`), which
rejects, with `types.Invalid()` so checking continues:

* `...: nil`: `a variadic parameter cannot have type nil`;
* a foreign C pointer: `a variadic parameter cannot have a foreign pointer type`;
* any type with no `TitanVarg*` family:
  `a variadic parameter cannot use type T because it has no supported
  variadic-value representation` (`types.valid_varg_element`).

The same helper with role `"return"` validates flexible result elements.

### Untyped lambda vararg inference

The `Ast.ExpFunction` visitor (`checker/expressions.lua`) first counts the
fixed parameters, takes the context as `expected` only when it is a
`Type.Function` with `#params == nfixed`, and then resolves the vararg:

* explicit `...: t`: `typefromnode` (context ignored);
* untyped `...`, variadic context: `expected.varargtype`;
* untyped `...`, non-variadic context: `cannot infer the type of '...'; the
  lambda is variadic but the expected type is not`;
* untyped `...`, no usable context: `cannot infer the type of '...'; annotate
  it or use the lambda where its type is known`.

The result then goes through `check_varg_elem`. Top-level functions, methods
and function-type annotations never reach this path because the parser
requires their annotation.

### Depth-stamped `$vararg` and scope rule 4

`...` is invisible to inner lambdas, which ordinary lexical scoping would not
give (`find_symbol` walks every enclosing block). `checkfuncbody`
(`checker/declarations.lua`) installs a `$vararg` symbol
`{ elem = varargtype, funcdepth = #func_stack }` for a variadic function. Every
`...`, `#...` and `...[e]` resolves through `resolve_vararg`
(`checker/common.lua`), which reports `'...' is not visible inside an inner
function` when the stamped depth differs from the current `#func_stack`, and
`'...' can only be used inside a variadic function` when no symbol exists. A
variadic lambda installs its own `$vararg` at its own depth. The depth matches
`_funcdepth`; see
[closures](checker.md#closures-capture-analysis-and-lambda-inference).

### The variadic expression checker arms

* **`Ast.ExpDots`** is consumed by a legal tail consumer through
  `check_dots_marker`, or by `ExpAdjust` for `(...)`. Its direct visitor only
  diagnoses synthesized or malformed ASTs.
* **`Ast.ExpDotsLen`** resolves `$vararg` and has type `integer`.
* **`Ast.ExpDotsIndex`** coerces the index to `integer` (term
  `"variadic index"`), defaults `_nilfill = false`, and has type `t`, or `t?`
  when `_nilfill` is set. Unlike `a[i]` on an Array, a source `...[i]` is `t`:
  the run is dense, and the generated read raises when out of range.
* **`Ast.ExpAdjust(ExpDots)`** is rewritten to `ExpDotsIndex(1)` with
  `_nilfill = true`, so `(...)` always contributes one `t?` value and an empty
  run yields nil.

### Shared finite/open expression-list demand

All expression-list consumers use `result_demand` plus `adjust_explist`;
[Flexible returns](flexible-returns.md#one-finiteopen-result-demand) is the
canonical description. The `ExpDots`-specific rules are:

* **Finite demand.** A trailing `ExpDots` becomes one synthesized
  `ExpDotsIndex` per still-needed slot. A read nil-fills (type `t?`) when the
  demand's `dots_nilfill` policy says so or when the target passes
  `nil_can_adjust_to`; otherwise it keeps the raising bounds check. If the
  finite demand is already full, `...` is not read, so `return ...` in a
  zero-result function is a no-op rather than an arity error.
* **Generic `for`.** The tuple demand sets `dots_nilfill` to a predicate that
  is true for slots 1–3 (`checker/statements.lua`): missing state and control
  become nil as Lua requires, while a close function projected into slot 4
  keeps the raising read. See
  [Generic `for` tuple elaboration](checker.md#generic-for-tuple-elaboration).
* **Open demand.** The marker stays the single runtime-sized `open_source`. An
  input-variadic call receives the remaining run, a function with
  `flexrettype` can forward it from `return ...`, and a final positional Array
  or exact integer-Map field appends it.
* **C variadics.** A runtime-open run cannot reach a C `...`: the C call view's
  `c_vararg` has no typed descriptor contract. Written finite arguments still
  use C default promotions.

`...` is always the sole, last trailer, so `f(g(), ...)` truncates `g()` to one
value.

### Positional `{...}`: backward typing

`ExpInitList` accepts a trailing key-less `ExpDots` in an all-positional Array
or exact integer-keyed Map. A non-final `...` field is rejected by the checker
(`'...' must be the last field in a positional constructor`,
`checker/expression_lists.lua`); a `...` field in a computed Map or record
constructor is a type error. The element type is the context element if
present, else the de-optioned open-source element, else the first tail scalar,
else `integer` (`generic_positional_constructor_element_type`). A no-context
`{...}` is therefore `Array(t)`, not `Array(t?)`. A contextual target must
accept the vararg element type. The kept `ExpDots` reaches the coder as the
`_positional_adjustment` open source, which can also be a trailing
flexible-result call.

### The adjustment guarantee for codegen

After checking, every static element destined for a `TitanVarg*` descriptor
carries an `assignment_adjustment` to the element type, and run-to-run
conversion uses the same per-element plan. A strict `value → t` guard can
therefore appear in a callable wrapper's native adapter, the branded generic
fallback, a fresh forwarding copy, or a flexible result-run consumer, and is
never replaced by a representation cast. The genuine-Lua entry consumes the
corresponding `DynamicCoercionPlan`.

An adjusted Interface method uses the same descriptor ABI for an input tail.
Its checker-frozen adapter records the run actions, element guard or
injection, roots and rebases in advance; the coder renders that closed plan
without re-deciding coercions. A scalar concrete-to-Interface coercion is not
lifted into a variadic component. See
[Interfaces](interfaces.md#frozen-conversion-and-adapter-plans).

## Code generator: the seven structs and the native ABI

### Seven `TitanVarg*` structs, one per `ctype`

`titan-runtime/titan.h` declares one descriptor struct per element `ctype`, so
`args` has the exact element pointer type:

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

Scalars are unboxed; strings and containers are raw object pointers; `value`,
ordinary Options and functions use `TValue`; nominal values (`Type.Nominal`)
and owned C values (`Type.COwned`) use `TitanVargNominal`. `varg_struct_name`
(`coder/flow.lua`) picks the family from `ctype(elemtype)` through
`varg_struct_by_ctype`, selecting `COwned` semantically. A C pointer element has
no entry and raises a compiler error, but the checker bans it first. Native
foreign numeric Options additionally get generated
`titan_native_option_N_varg` descriptors with the same pair shape
(`coder/nativeoption.lua`; see [Native nominal storage](nominal-storage.md)).

An input descriptor is a borrowed view of the caller's arguments. A flexible
output descriptor points at caller-supplied capacity and the callee sets
`n_args` to the count produced.

Two layout decisions:

* **`n_args` is `lu_byte`**, capped by `TITAN_VARARG_MAX = 200`. Static counts
  are bounded by the parser's 100-item list limit; runtime counts from
  forwarding and the Lua entries are checked and raise past 200. Callers that
  need more elements use an explicit `{T}` parameter.
* **`start` is not a field.** It travels as a separate `int _start` parameter;
  `n_args` is the total backing count and the callee's view is
  `args[_start .. n_args-1]`. Forwarding therefore passes a different `_start`
  against the same immutable descriptor.

At a static call site with a compile-time count `N`, the coder emits a typed C
array and a named descriptor pointing at it:

```c
lua_Integer _vargargs_3[N] = { a, b };
TitanVargInteger _varg_3 = { N, _vargargs_3 };
f(L, _mod, _fn, /* params... */ &_varg_3, /* _start = */ 0, /* out... */);
```

Both are C-stack locals. The descriptor stores only a count and a pointer to
element storage, and the elements are values or pointers to Lua heap objects,
which the GC does not move. An empty static run still emits a one-element
array with `n_args == 0`.

### The native ABI: trailing `_varargs` and `_start`

A variadic function's native signature gains the pair after the declared
parameters and before the fixed result out-parameters. A flexible result's
`_flexout`/`_flexwant` pair comes last:

```c
lua_Integer mod_\u2133_f_titan(lua_State *L, Udata *_mod, CClosure *_fn,
                        lua_Integer _param_x,
                        TitanVargInteger *_varargs, int _start,
                        lua_Integer *_outparam_2,
                        TitanVargString *_flexout, int _flexwant);
```

The pair is not part of `ftype.params`. Four emitters add it from
`ftype.varargtype` and must agree byte for byte: `function_sig`
(`coder/flow.lua`, which also defines the value-call fast-path typedef), and
the inline `cparams` of `codefuncdec`, `codelambdadec`, and
`codemethodtrampoline` (`coder/declarations.lua`). A bound-method trampoline
forwards `_varargs`/`_start` and `_flexout`/`_flexwant` verbatim.
`fixed_params` strips the nameless marker so no C parameter is emitted for it.
`codefuncdec` and `codelambdadec` then set
`ctx.varargs = { cname = "_varargs", start = "_start", elem = varargtype }`
(immediately called lambdas set it in `coder/immediate.lua`). A lambda's
context is fresh, so an inner lambda never inherits the enclosing `...`; the
coder enforces scope rule 4 a second time.

### Lua-entry vararg collection

The Lua-stack entries are described in
[Lua interop internals](lua-interop-internals.md#the-two-lua-stack-entries-genluaentry).
For a variadic function, `genluaentry` (`coder/declarations.lua`) builds the
descriptor from every argument beyond `nfixed`, after padding a short fixed
prefix with nil:

1. `_vcount = _nargs − nfixed`; above `TITAN_VARARG_MAX` it raises
   `too many variadic arguments to Titan function …`.
2. `titan_ensure_stack` reserves a slot, then the element array is allocated
   as a zero-user-value `Udata` payload (`titan_new_udata_object`, `nuvalue = 0`,
   `metatable = NULL`) and anchored on the Lua stack, because per-element
   conversion can allocate.
3. A C-stack `TitanVarg*` descriptor points at `getudatamem` of that payload;
   `_start = 0`.
4. Each surplus argument is converted into `args[j]` with the parameter
   policy of that entry: `DynamicCoercionPlan` in the genuine-Lua entry, strict
   guards in the strict entry. Every read is addressed from the current
   `L->ci->func.p` because a conversion (for example an Interface witness
   call) can relocate the stack between iterations. The strict entry excludes
   its hidden carrier argument from `_vcount`.

### Lowering index, count, and constructor forms

All three forms read `ctx.varargs`; the callee's view has length
`n_args − _start`.

**`...[i]`** (`codedotsindex`, `coder/expressions.lua`) materializes the index
once, then checks `1 <= i <= n_args − _start`:

```c
lua_Integer _vi = $INDEX;
if (TITAN_UNLIKELY(_vi < 1 || _vi > ((lua_Integer)_varargs->n_args - _start)))
    luaL_error(L, "%s:%d:%d: variadic index %I out of range [1, %d]", ...);   /* _nilfill == false */
$RESULT = _varargs->args[_start + _vi - 1];
```

With `_nilfill == false` an out-of-range index raises and the result is the
unboxed `t`. With `_nilfill == true` it yields nil in the exact `t?` carrier:
a native presence/value struct for foreign numeric Options, otherwise the boxed
representation.

**`#...`** (`codeexp`, `Ast.ExpDotsLen`) is
`((lua_Integer)_varargs->n_args - _start)`.

**`{...}` / `{e1, ...}`** (`codearray`, positional `codemap`) receives the
trailing `ExpDots` as the adjustment's open source and switches to a
runtime-sized build. The static prefix is evaluated into reserved roots, then
the run count sizes the container. Array lowering creates the backing/proxy
pair with `titan_array_new`, stores into positive backing slots, and records
the highest non-nil position as the length; positional Map lowering pre-sizes
and fills an ordinary Table. The loop strides by the real element type and
converts each element when the target element differs.

`return ...` projects finite result slots through `ExpDotsIndex` and, when the
function has `flexrettype`, forwards the remaining run as the output open
source; `codereturn` copies at most the inherited `_flexwant` and sets
`_flexout->n_args`.

### Static call sites

At a static native call to a variadic callee whose arguments are a static
list, `codecall` inserts the `_varargs`/`_start` pair through
`emit_vararg_struct` (`coder/calls.lua`): the surplus arguments, already
adjusted to the callee's element type, go into a C-stack array with an exact
`TitanVarg*` descriptor, and `_start` is 0. No allocation is involved.

A call whose argument list ends in `...` never reaches that emitter. The
checker gives it an open-input plan (`open_source`, see [shared finite/open
expression-list demand](#shared-finiteopen-expression-list-demand)), and the
call lowers through the open-run path (`inputrun`, `coder._code_open_source`):
any static prefix and each remaining `...` element, converted by the
checker-frozen per-element adjustment, are copied into a bounded C-stack
`_open_vargs` array of the callee's element type, whose descriptor the callee
receives with `_start = 0`. Both call paths assert that invariant.

### First-class value calls

A variadic function is dispatched by `codevaluecall` exactly like any other
function value; the three branches, tags, and wrapper construction are in
[Calling function values](codegen-overview.md#calling-function-values-codevaluecall).
The variadic deltas are:

* The function-type tag key (`types.runtime_identity`) includes `varargtype`
  and `flexrettype`, so `...: integer` and `...: value` callables never share
  the exact path.
* On the exact path the caller builds the descriptor as a static call site
  does (`emit_vararg_struct`, or the open-run array for a forwarded `...`) and calls through
  the `function_sig` typedef. For a realized wrapper the pointer is the target
  adapter, which builds the source's fixed/tail view, so the target's typed
  tail is enforced there.
* On the branded strict path the caller pushes every fixed and surplus static
  argument plus any forwarded `...` elements; the strict entry rebuilds the
  descriptor with strict guards.
* On the unbranded Lua path the arguments are already adjusted to the static
  shape and boxed.

## The ABI boundary

Variadic shapes are covered by the compiled-module ABI
([Compiled-module ABI](codegen-overview.md#compiled-module-abi)) in two places:
the trailing `TitanVargX *` plus `int _start` native pair, and the
`varargtype` element in serialized callable types. Each `TitanVargX` is a
`{ lu_byte n_args; T *args; }` descriptor, not an inline flexible-array
object. `TitanVargArrayOrMap` is `Table **`: exact Array elements are internal
backing Tables, while generic or Lua-visible runs box them as proxies (see
[Dense Arrays](dense-arrays.md#internal-and-boxed-representations)). Closure
adjustment wrappers reuse the same descriptors and signatures and add only
private consumer artifacts.

Compiled-interface imports round-trip `varargtype` through the same
serialization from DSO callables or an archive metadata section;
`spec/coder/so_import_spec.lua` and `spec/checker/so_rehydration_spec.lua`
cover the DSO path.

## GC discipline: descriptor pointers and untraced payloads

The rooting protocol for native calls is in
[Calls: C-only inputs, immediate result roots, and VM transport](values-and-gc.md#calls-c-only-inputs-immediate-result-roots-and-vm-transport):
descriptors and their `args` arrays are never roots, and every collectable
element stays reachable from an independent traced owner (a semantic home, an
allocation or native-result root, a Lua VM argument slot, or a flexible result
range) for the descriptor's lifetime. The variadic-specific points are:

* **Raw payloads are not traced.** `traverseudata` (Lua's `lgc.c`) marks only a
  userdata's metatable and `uv[0..nuvalue-1]`, never `getudatamem`. A
  zero-user-value `Udata` used for element storage (the Lua entry) is
  rooted only so that its *buffer* survives; it has no metatable, `__gc`, or
  user values and owns none of the elements copied into it.
* **C-stack descriptors are safe.** Lua's GC does not move heap objects, so
  pointers to `TString`, `Table`, `Udata` or payload buffers stay valid across
  collection. Only pointers into the Lua stack need rebasing.
* **`{...}` uses `luaC_barrierback`** per collectable element against the Array
  backing or the positional Map Table. Scalars skip the barrier.
* **Stack relocation.** A fresh `Udata` (the Lua entry) or a
  `titan_array_new`/Table resize in `{...}` can grow or shrink the Lua stack.
  The coder saves `_base` as `_base_off` (`ctx.uses_base_off`) and rebases with
  `_base = restorestack(L, _base_off)` before later reserved-slot reads and
  stores.
