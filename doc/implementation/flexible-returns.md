# Flexible returns and contextual `value` calls

Flexible returns add a runtime-sized homogeneous tail after a callable's fixed
result prefix. They also make a call through `value` contextual: the checker
synthesizes a structural function type from the call's positional arguments
and from the result demand imposed by its consumer. The language semantics are
in [Flexible return tails](../language/functions.md#flexible-return-tails).

The implementation is not a second multiple-return subsystem. The checker
reduces declarations, assignments, returns, calls, positional
Array/integer-Map constructors, generic `for`, input `...`, and contextual
calls to one finite/open expression-list demand. The coder then keeps two
shapes distinct:

* the callable's declared fixed/flexible shape, which determines its native
  ABI and exact first-class tag; and
* the result shape visible to this consumer, which determines truncation,
  option projection, open-result handling, and discarded effects.

That separation is the central invariant: consumer annotations never replace
the callee's `Type.Function` as the source of native ABI truth.

## Representation in the AST and type graph

The flexible element is stored separately from the dense fixed `rettypes`
array. `nil` means no flexible tail; an AST node or resolved `Type.*` means a
tail is present.

| Node | Result-shape fields |
| --- | --- |
| `Ast.TypeFunction` | `argtypes, rettypes, varargtype, flexrettype` |
| `Ast.TopLevelFunc` | `params, rettypes, flexrettype, block` |
| `Ast.TopLevelStatic` | `params, rettypes, flexrettype, block` |
| `Ast.TopLevelMethod` | `params, rettypes, flexrettype, block` |
| `Ast.ExpFunction` | `params, rettypes, flexrettype, block` |

The checked constructors in `types.lua` are:

```text
Type.Function(params, rettypes, false, varargtype, flexrettype)
Type.Method(fqtn, name, params, rettypes,
            varargtype, flexrettype, paramnames)
Type.StaticMethod(fqtn, name, params, rettypes,
                  varargtype, flexrettype, paramnames)
```

The third `Type.Function` position is the reserved-false sentinel.
`varargtype` is the typed input tail and `flexrettype` the typed output tail;
they may coexist. Direct C declarations use
`Type.CFunction(params, ret, vararg, abi)`, which has no flexible tail and no
conversion to `Type.Function`; see
[Variadic parameters](variadic-parameters.md#typefunctionvarargtype-vs-typecfunctionvararg).

Every recursive type operation descends through `flexrettype`: C-FFI leakage
checks, nominal-record recovery, local-record interface checks, string
rendering, equality, consistency/adjustment planning, and serialization.
Record walkers also visit public record functions and methods, so a nominal
used only in a flexible tail is still recovered from a compiled dependency.

### Parser carriers and disambiguation

Input and output tails use separate `parser.lua` productions: `flextail`
supplies a function type's input `...: T`, and `returntail` supplies an output
tail with return-specific error labels. Fold captures append fixed types and
the optional tail; `split_types` removes the private `_type_tail` carrier and
returns the dense fixed list plus the tail.

`resulttypes` requires a comma before a tail that follows fixed results:
`(integer, ...: string)` is valid, `(integer ...: string)` is not. A flex-only
result is `(...: string)`, so every flexible return annotation is a
parenthesized result list. `parenthesized_returns` and `singlereturn` build the
same transient `{ rettypes = fixed_dense_list, flexrettype = type_node_or_nil }`
carrier, and `functiontype` combines input and result captures into
`Ast.TypeFunction`. Function types start with `function`, so a leading
parenthesis in return position is always a result list or grouped type. Return
and type lists do not inherit the 100-item written-parameter and
expression-list guard.

The syntax labels `FlexRetColon` (missing `:`), `FlexRetType` (missing element
type), `FlexRetLast` (a fixed result follows the tail) and `FlexRetParens`
(tail outside a parenthesized list) keep return diagnostics separate from
variadic-parameter diagnostics.

During signature checking, `flexible_return_type` (`checker/common.lua`)
resolves the AST type and validates it with
`check_varg_elem(..., "return")`. Output tails use the same seven descriptor
families as input varargs, so `nil`, foreign pointers, and types with no
descriptor representation are rejected with return-specific diagnostics.
`COwned` uses the nominal `Udata **` family; `value` stays `Type.Value`; finite
option projection never constructs an artificial `value?`.

An unannotated lambda in an expected function context copies both the fixed
`rettypes` and `flexrettype`. An explicit `: ()` keeps an empty fixed list and
`flexrettype = nil`. The `main` contract requires `varargtype = nil` and
`flexrettype = nil`, preserving the exact `main(args: {string}): integer`
shape.

## One finite/open result demand

`checker/expression_lists.lua` represents every expression-list consumer with
`result_demand(fixed, tail, opts)`:

* `fixed` is a dense sequence of demanded positions. `UNKNOWN_SLOT` is a known
  position whose type is inferred rather than supplied by context.
* `tail` is `nil` for a finite consumer, a resolved `Type.*` for a typed open
  consumer, or `INFER_OPEN` for an open consumer whose element type is inferred
  from its inputs.
* `missing` selects ordinary arity failure, call-argument nil padding, or the
  narrow recovery used by strict C calls.
* `explicit_surplus` selects discard for Titan expression lists and error for
  explicit C surplus.
* `dots_nilfill` is `nil`, a boolean, or a predicate `(slot, target_type)`
  that forces nil-filling `...` projections. Only generic-`for` setup sets it;
  ordinary fixed calls keep raising reads for targets that reject nil.
* the remaining options carry diagnostic terms, locations, open-tail
  adjustment policy, `dots_limit`, and the expression checker used by
  specialized sites.

`adjust_explist(exps, demand, st, errors)` performs the elaboration and
returns:

```text
exps                   every written expression, plus synthesized finite projections
fixed                  values delivered to the finite prefix, indexed by demand slot
tail_scalars           statically known scalar values delivered after the prefix
discards               retained expressions evaluated only for effects
open_source            the sole possible runtime-sized final producer, or nil
open_type              that producer's element type
open_target            the sink's element type
open_start             the first still-unconsumed element of the dynamic run
open_adjustment        the checker-selected element adjustment for the run
open_callable_adapter  the frozen adapter plan when that adjustment is callable
missing, explicit_surplus  counts kept for error recovery
```

The enclosing node keeps the complete adjustment:

| Consumer | Annotation |
| --- | --- |
| local declaration or assignment | `_result_adjustment` |
| `return` | `_result_adjustment` |
| call arguments | `_arg_adjustment` |
| positional Array/integer-Map constructor | `_positional_adjustment` |

Only the final expression can expand. Every earlier expression is checked
under a one-result scalar demand while a fixed slot or open tail remains. Once
a finite consumer is full, later written expressions are checked under a
zero-result demand, kept in `exps`, and marked `_discard_results`; a discarded
call also gets `_voidok`. Source-order effects are preserved without exposing
or passing a surplus value.

The final expression is checked under the complete remaining demand. For a
call, `finite_result_expressions` turns each statically visible result after
the first into an `Ast.ExpExtra`. A projected flexible slot carries
`_from_flex`, `_possibly_absent`, and `_result_source`. Ordinary `trycoerce`
attaches the `assignment_adjustment` plan for each option widening, strict
projection, direct coercion, or non-option nil force the sink requires;
`checkmatch` verifies the result. A trailing bare `...` and a spread carrier
follow the same record; their projection rules are in
[Variadic parameters](variadic-parameters.md#shared-finiteopen-expression-list-demand)
and [Spread expressions](spread-expressions.md#checker-planning).

### Declared call shape versus visible call shape

`annotate_call_results` (`checker/variables.lua`) records both sides of a
call:

| Annotation | Meaning |
| --- | --- |
| `_callee_type` | complete checked callable type; `Type.Function` for Titan/Lua or authoritative `Type.CFunction` for a C call |
| `_types` | declared fixed result prefix |
| `_flexrettype` | declared flexible element, or `nil` |
| `_visible_types` | finite and statically visible results for this consumer |
| `_result_sources` | `{kind="fixed", index=i}` or `{kind="flex", index=i, may_absent=true}` per visible slot |
| `_finite_flex_prefix` | number of flexible slots projected by a finite demand |
| `_flex_result_demand` | finite projected count, `"open"`, or `nil` |
| `_open_results` | dynamic source/target/start descriptor for an open sink, or `nil` |

`_type` remains the first visible type, or `Type.Void` when the demand exposes
none. A flexible projection is `optionize(flexrettype)`: Options and `value`
stay unchanged, every other element becomes `T?`. A finite demand above
`TITAN_VARARG_MAX` flexible positions is rejected
(`finite flexible-result demand is N value(s), maximum is 200`).

An open demand first exposes any declared fixed results its finite prefix has
not consumed. `_open_results` is present only when the callable's static type
has `flexrettype`; it records the source element type, sink element type, and
first unconsumed flexible index. An open sink therefore never turns a fixed
static function type into `LUA_MULTRET` and cannot reveal results hidden behind
a narrower adjusted callable type.

Call arguments also receive `_npassed_args`, the count of statically passed
fixed/tail scalars, and `_open_args = {source, source_type, target_type, start}`
when a final dynamic run feeds a Titan input vararg. Direct C calls use the
same engine with `explicit_surplus = "error"`: a trailing producer can be
truncated to the exact C formal count, but a runtime-open Titan run never
crosses a C variadic boundary.

Generic `for` uses a finite four-slot demand; see
[Generic `for` tuple elaboration](checker.md#generic-for-tuple-elaboration).

## Contextual calls through `value`

The `Ast.ExpCall` checker treats a `Type.Value` callee as an unknown callable
whose structural type comes from the call context.
`synthesize_value_call_inputs` (`checker/variables.lua`) checks the positional
arguments once under an open `INFER_OPEN` demand:

* scalar arguments and all statically visible fixed results of the trailing
  producer become fixed parameter types;
* a final runtime-open input run becomes `varargtype`;
* an empty argument list produces an empty fixed parameter list.

`synthesize_function_type` (`checker/expression_lists.lua`) builds the result
side from the consumer demand. Known finite slots use their expected types,
unknown finite slots become `value`, a statement call produces no results, and
an open demand becomes `flexrettype` with its known element type, or `value`
for `INFER_OPEN`.

The checker inserts an `Ast.ExpCast` from `value` to that resolved
`Type.Function` without redispatching it through the `ExpCast` visitor: the
target is already resolved and the callee and arguments have been checked
once. The origin is marked for the coder and diagnostics:

```text
cast._contextual_value_cast = true
call._contextual_value_call = true
call._contextual_function_type = synthesized_type
```

The call then follows normal structural-function argument and result
annotation. In nested `outer(inner())` calls an open outer argument demand
synthesizes an open `value` result for the inner call, while a known fixed
outer signature gives it finite demands.

Named syntax is rejected before synthesis because an arbitrary `value` has no
`paramnames`. At run time a non-callable value reaches Lua's ordinary
non-callable diagnostic. A Titan closure stored in `value` still takes the
native path when the synthesized type exactly matches its runtime tag.

## Identity and callable adjustment

`types.equals` is strict structural identity. For a valid `Type.Function` it
requires the reserved slot to be false and compares every fixed parameter and
result, input-vararg presence and element, and flexible-result presence and
element. `Type.CFunction` uses separate C compatibility rules; equality,
consistency and callable adjustment never relate the two kinds. `Type.Method`
and `Type.StaticMethod` carry the same tails; binding or selecting either
produces a `Type.Function` whose identity includes them. Parameter names do
not participate in equality.

`types.tostring` renders every flexible result in a parenthesized list, so
`function (): (T)`, `function (): (T, ...: U)`, and `function (): (...: U)`
stay distinct. Function-tag keys use `types.runtime_identity`, which preserves
the same distinctions and adds defining C scopes to named foreign components.
Two merely consistent types never share a native-entry cast.

`types.callable_adjustment(source_actual, target_expected)` is the directional
operation used when a callable is stored or called through another callable
type. It returns a plan of kind `"callable"` recording fixed/tail argument
alignment, missing-argument nil fill, ignored surplus, finite/open result
demand, the `nil_fill_result` action, and one component adjustment per
aligned slot. It uses gradual consistency recursively and never lifts numeric,
Option, nominal-to-Interface or other automatic coercions through the function
type. The input and result rules are in
[Callable adjustment rules](type-relations-and-boundaries.md#callable-adjustment-rules).
The checker freezes a relation-free adapter plan (`"callable_adapter_plan"`,
`checker/interfaces.lua` `freeze_callable_adapter_plan`) for each finite
non-exact edge; its realization is described in
[Closure adjustment wrappers](closure-adjustment-wrappers.md).

## Generated result runs and the native ABI

Flexible outputs reuse the input-vararg descriptor families described in
[Variadic parameters](variadic-parameters.md#seven-titanvarg-structs-one-per-ctype).
An input descriptor describes upstream-owned backing and travels with a
separate `_start`. A flexible output descriptor points at storage owned by the
caller; it has no start parameter, and the callee writes the produced count
into `n_args`.

### Native signature

A flexible native entry has this parameter order:

```c
RET f(lua_State *L, Udata *_mod, CClosure *_fn,
      /* method self, fixed parameters, */
      /* optional TitanVargX *_varargs, int _start, */
      /* fixed result out-pointers 2..m, */
      TitanVargY *_flexout, int _flexwant);
```

The first fixed result remains the C return value and fixed results 2 to `m`
remain out-pointers. The flexible pair comes last. A flex-only function returns
`void`.

`_flexwant` is both demand and capacity:

| Value | Contract |
| --- | --- |
| `0` | produce no stored tail values; no writable element is required |
| positive `n` | write at most `n` tail values and set `n_args` to the count actually present |
| `LUA_MULTRET` | preserve the complete actual tail, up to `TITAN_VARARG_MAX` |

Finite callers allocate a right-sized typed array; a zero-demand site may pass
a one-element placeholder that is never written. Open callers reserve
`TITAN_VARARG_MAX` elements. The callee never returns backing from its own C
frame and never replaces `_flexout->args`; nested or forwarded runs are copied
into the outer caller's buffer.

Every exit sets `_flexout->n_args`, including bare return, flex-only
fallthrough, a fallthrough whose fixed prefix is exactly one `nil`, and
pending-return dispatch after `finally`, so a stale count from a previous call
is never visible. A producer still evaluates expressions beyond a finite
`_flexwant`; it discards their values.

### The coder's result-run abstraction

The coder carries a dynamic sequence as a result run: typed descriptor, first
element/start, element type, finite or open extent, ownership, stack
restore/cleanup point, and an optional parallel Lua root range. Borrowed input
and non-GC runs need no range; every live open GC-bearing native call result
uses one until its sink consumes it, including identity source runs in
adapters. A non-contiguous reader sets `retain_read_results` when each raw VM
result needs its own indexed slot. An allocating cast may use that indexed slot
as its final anchor; a nonallocating adjustment gets no destination root. An
open expression list is an ordered scalar prefix followed by at most one
dynamic run.

The same abstraction (`coder._code_open_source`,
`coder._convert_result_run_element`, `coder/calls.lua`) feeds:

* forwarding an input vararg;
* receiving a flexible call result;
* forwarding a flexible return; and
* appending a final producer to a positional Array or exact integer-Map
  constructor.

[Spread expressions](spread-expressions.md#generated-carrier-and-result-run)
add a non-contiguous producer whose `read` operation replaces
`args[start + i]`.

Fixed results stay in their C temporaries and out-parameters; the dynamic run
starts after the declared fixed prefix. Sink conversions are element-wise and
use the normal boxing/unboxing, `checkandget`, container-growth and barrier
paths. See [Dense Arrays](dense-arrays.md#exact-and-generic-call-paths) for
Array sinks.

A flexible function's `return` is statically open, but its native entry
inherits the caller's runtime `_flexwant`. `codereturn` and
`coder._lower_return_to_destination` (`coder/statements.lua`) thread the
remaining budget through the scalar prefix and the final run: each scalar
written into the tail decrements a finite budget, and after it reaches zero the
remaining expressions run under discard demand. An exact nested flexible call
receives that remainder, or `LUA_MULTRET` only when the inherited budget is
open. A generic nested flexible call always uses `LUA_MULTRET`, keeps the raw
count on the Lua stack, and copies only the permitted remainder; the inherited
`_flexwant` is never encoded as the Lua result request.

The checker marks every adjustment it synthesizes. For an explicit tail scalar,
return lowering evaluates and stabilizes the source unconditionally, then
applies only the sink-inserted adjustment inside the remaining-budget guard, so
a discarded strict `value` guard or option unwrap cannot raise. A user-written
`as` cast has its own `_written_cast` plan and stays part of source
evaluation, so its failure is observable even when the result is discarded.

Every typed output descriptor Titan materializes is capped at 200 elements. A
finite consumer requesting more is rejected by the checker; a runtime request
over 200 is rejected by a Lua-stack entry; more than 200 actual values raise
`too many flexible return values` only when the materialized descriptor is
effectively open. A smaller finite inherited budget materializes only the
requested prefix and ignores surplus raw Lua results.

### Immediately called literals

[Immediately called anonymous functions](immediate-functions.md) use the same
finite/open demand and inherited budget within an inline scoped block. Finite
demand writes outer result holders directly at each return; open demand
preserves the actual run, count and traced ownership. The return conversion
still precedes the literal's cleanup, and caller-side adjustments that can
raise or allocate stay outside its protected boundary. The optimization does
not change the flexible-result ABI or its limits.

## Exact and generic calls

Direct module functions, record statics, methods, bound methods, lambdas, and
exact first-class Titan closures use the native entry. The rooting of inputs
and results follows
[Calls: C-only inputs, immediate result roots, and VM transport](values-and-gc.md#calls-c-only-inputs-immediate-result-roots-and-vm-transport).
The flexible-specific steps are:

* the caller reserves raw storage for every declared fixed result, even when
  the consumer hides some, and a source-typed flexible buffer sized by the
  finite/open demand, plus a parallel traced range for an open GC-bearing tail;
* after the call it exposes only `_visible_types` and the permitted dynamic
  run to the sink;
* each finite flexible projection tests its index against `_flexout->n_args`
  before reading; an absent element becomes nil, after which the
  checker-inserted option conversion or non-option force applies;
* an open consumer iterates only the actual `n_args` range, starting at the
  `_open_results.start` recorded after any finite projections.

First-class calls go through `codevaluecall`; its exact, branded-strict and
unbranded branches are described in
[Calling function values](codegen-overview.md#calling-function-values-codevaluecall),
and callable-cast wrapper construction in
[Closure adjustment wrappers](closure-adjustment-wrappers.md). The flexible
tail is part of the exact tag, so a differently shaped closure cannot enter
the native path unless a static non-exact edge realized that target tag. A
contextual `value` call reaches the same three-way split after synthesis; it
has no static source→target edge to wrap.

### Choosing the Lua VM result request

The generic path derives `nresults` from the consumer demand and the callee's
static type:

* A finite demand requests exactly its visible result count. Lua truncates
  surplus and pads absent positions with nil before Titan applies its result
  checks.
* An open sink requests `LUA_MULTRET` only for a statically flexible producer
  marked `_open_results`.
* An open sink consuming a fixed-only static callable requests that callable's
  remaining declared fixed count, so a wider runtime closure cannot leak
  results through a narrower static type.

After `LUA_MULTRET`, the coder derives the raw count from the restored stack top
before resetting it. If fewer than the static fixed prefix arrived, it supplies
nil for the missing fixed positions before conversion; options and `value`
accept it, non-options use the ordinary runtime force. The flexible count is
the remaining raw count, capped at 200 for an effectively open consumer.

A trailing generic flexible call inside a flexible return is a statically open
producer even when the outer native caller supplied a finite `_flexwant`. It is
called with `LUA_MULTRET` whatever the runtime callable is; the Lua stack owns
and roots the complete run, and Titan copies at most the remaining finite
budget. No finite `_flexwant` is passed through `CallInfo`: a branded exact-tag
mismatch enters its strict entry or wrapper relay with `LUA_MULTRET`, which
treats its native call as open and enforces the 200-value bound. An exactly
tagged realized wrapper receives `_flexwant` through its native target
signature. A non-Titan callable's results are dynamically coerced.

Lua 5.5 encodes a finite result count in `CallInfo.callstatus`, bounded by
`MAXRESULTS` (250, `LUA_VM_MAX_RESULTS` in the compiler). That bound applies only
to an ordinary finite generic function-value call: `check_generic_result_limit`
(`checker/variables.lua`) rejects a finite visible request above 250. Direct
Titan calls use typed out-parameters and statically open generic producers use
`LUA_MULTRET`, so both are exempt.

The generic branch keeps the Titan error handler active and stores stack
positions as offsets across `luaD_callnoyield`. The error-handler slot is
excluded from raw result counts. On success `L->top.p` is restored after live
results have been converted and anchored.

## Lua-stack entries

The coercive and strict entries are described in
[Lua interop internals](lua-interop-internals.md#the-two-lua-stack-entries-genluaentry).
For flexible results, `genluaentry` (`coder/declarations.lua`) reads Lua's
requested result count with `get_nresults(L->ci->callstatus)`:

* a finite request passes `max(requested - fixed_count, 0)` as `_flexwant`;
* a finite flexible demand over 200 raises
  `too many flexible results requested from Titan function …` before entering
  the native body;
* `LUA_MULTRET` passes an open `_flexwant` and reserves `TITAN_VARARG_MAX`
  elements;
* the entry returns every fixed result plus the actual flexible count, and
  Lua performs the caller's final truncation or padding.

The entry reserves all destination stack slots before the native call, so it
can anchor fixed and flexible GC-bearing results during the allocation-free
handoff, and recomputes stack pointers from saved offsets after any operation
that can relocate the stack.

## GC, errors, and pending returns

`TitanVargX` and its `args` array are raw C storage and never roots; the
general rules are in
[Calls: C-only inputs, immediate result roots, and VM transport](values-and-gc.md#calls-c-only-inputs-immediate-result-roots-and-vm-transport).
For flexible outputs: exact-call fixed holders and output buffers belong to the
caller but are untraced, so after return and rebase every live GC-bearing
fixed result is rooted immediately and every live open prefix is copied into a
parallel traced range until consumed. The output buffer needs no write barrier
because it is not a Lua heap owner. Direct `luaF_newCclosure` wrapper
construction allocates and can raise but does not relocate the stack.

### `finally` and flexible pending returns

A pending return saved across `finally` consists of:

```text
fixed return saves
flexible descriptor and produced count
parallel flexible root base/count
```

`make_return_frame` (`coder/statements.lua`) reserves traced slots for
GC-bearing pending elements and volatile C storage for non-GC state that
crosses a longjmp. `codereturn` fills those saves before setting `PA_RETURN`
and jumping to the innermost `finally`. A normal `finally` completion routes
the saved run through `dispatch_return_epilogue`; nested `finally` frames copy
into the outer pending return, preserving roots and count. A raise from
`finally` replaces the pending return. See
[pending actions](error-handling.md#pending-actions-for-finally).

Flexible roots stay live throughout the `finally` body because cleanup may
allocate, call, grow the stack, or raise. Dispatch reads rooted values before
lowering the stack top, then copies into the caller-owned output buffer. An
empty pending return resumed after `finally` records a zero flexible count.

## Serialization and ABI boundary

The interface serializer includes `flexrettype` in every callable shape:

```text
Function(params, rettypes, false, varargtype, flexrettype)
Method(fqtn, name, params, rettypes,
       varargtype, flexrettype, paramnames)
StaticMethod(fqtn, name, params, rettypes,
             varargtype, flexrettype, paramnames)
```

The reserved Function position and an absent tail serialize as `false`; the
validator in `driver.lua` rejects a non-false reserved value and a
`flexrettype` on a record or union constructor. The flexible field precedes
declaration-only `paramnames`. Interface recovery and all recursive nominal
walkers read the same position (`sourceinterface.lua`).

The [compiled-module ABI](codegen-overview.md#compiled-module-abi) covers both
flexible surfaces: the serialized constructor payloads and the trailing
`_flexout, _flexwant` native pair. Import loading checks the ABI marker before
interface rehydration, so exact function tags and imported native
declarations are rebuilt only for providers with the current callable schema.
