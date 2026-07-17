# Flexible returns and contextual `value` calls

Flexible returns add a runtime-sized homogeneous tail after a callable's fixed
result prefix. They also make a call through `value` contextual: the checker
synthesizes a structural function type from the call's positional arguments
and from the result demand imposed by its consumer. The language semantics are
described in the [flexible returns chapter](../language/flexible-returns.md).

The implementation is deliberately not a second multiple-return subsystem.
The checker reduces declarations, assignments, returns, calls, array
constructors, generic `for`, input `...`, and contextual calls to one
finite/open expression-list demand. The coder then keeps two shapes distinct:

* the callable's declared fixed/flexible shape, which determines its native
  ABI and exact first-class tag; and
* the result shape visible to this consumer, which determines truncation,
  option projection, open-result handling, and discarded effects.

That separation is the central invariant of the feature. In particular,
consumer annotations never replace the callee's `Type.Function` as the source
of native ABI truth.

This chapter describes the completed implementation, including the generic
open-consumer and pending-`finally` lifetime paths. Flexible returns introduced
compiled-module ABI 0.14; current installed-module paths use ABI 0.16.

## Representation in the AST and type graph

The flexible element is stored separately from the dense fixed `rettypes`
array. `false` means that no flexible tail is present; a parsed AST node or a
resolved `Type.*` value means that it is present.

The relevant `ast.lua` constructor fields are:

| Node | Result-shape fields |
| --- | --- |
| `Ast.TypeFunction` | `argtypes, rettypes, varargtype, flexrettype` |
| `Ast.TopLevelFunc` | `params, rettypes, flexrettype, block` |
| `Ast.TopLevelStatic` | `params, rettypes, flexrettype, block` |
| `Ast.TopLevelMethod` | `params, rettypes, flexrettype, block` |
| `Ast.ExpFunction` | `params, rettypes, flexrettype, block` |

The corresponding checked constructors in `types.lua` are:

```text
Type.Function(params, rettypes, vararg, varargtype, flexrettype)
Type.Method(fqtn, name, params, rettypes,
            varargtype, flexrettype, paramnames)
Type.StaticMethod(fqtn, name, params, rettypes,
                  varargtype, flexrettype, paramnames)
```

`vararg` is the disjoint C-FFI variadic bit. `varargtype` is Titan's typed
input tail, while `flexrettype` is Titan's typed output tail. The two Titan
tails may coexist. C-derived function types always set `flexrettype = false`,
and conversion of a flexible-return Titan function type to a C function
pointer is rejected.

Every recursive type operation descends through `flexrettype`: C-FFI leakage
checks, nominal-record recovery, local-record interface checks, string
rendering, equality, compatibility, and serialization. Record walkers also
visit public record functions and methods, so a nominal used only in a
flexible tail is still recovered from a compiled dependency.

### Parser carriers and disambiguation

The parser uses a return-specific production rather than reusing the input
vararg production:

```text
flexrettypeann        <- DOTS COLON type (!COMMA / FlexRetLast)
flexrettypeafterfixed <- (COMMA flexrettypeann)?
flexrettypeonlyopt    <- flexrettypeann?
resulttypelist        <- LPAREN
                           (fixed-result-types flexrettypeafterfixed
                            / empty-list flexrettypeonlyopt)
                         RPAREN
```

The separate alternatives enforce the comma before a tail following fixed
results: `(integer, ...: string)` is valid, while
`(integer ...: string)` is not. The comma-less path exists only for the
flex-only shape `(...: string)`.

`defs.flexrettype` drops the position capture and returns the element type
node. `defs.returnshape` wraps the two captures in an untagged carrier:

```lua
{ rettypes = fixed_dense_list, flexrettype = type_node_or_false }
```

`defs.singlereturn`, `defs.functionreturnshape`, and `defs.typefunc` produce the
same shape for bare fixed returns, nested function-return types, and arrow
types. This carrier exists only while parsing; no sentinel enters the numeric
`rettypes` sequence.

`rettype` tries `resulttypelist !RARROW` before the arrow alternatives. The
negative lookahead is what distinguishes `(...: T)` as a flexible result list
from `(...: T) -> R` as a function with an input vararg. A bare `...: T`
return is rejected: every flexible result tail is parenthesized.

The four dedicated syntax labels keep return diagnostics separate from
variadic-parameter diagnostics:

* `FlexRetColon` — missing `:`;
* `FlexRetType` — missing element type;
* `FlexRetLast` — a fixed result follows the tail;
* `FlexRetParens` — the tail is not in a parenthesized result list.

During signature checking, `flexible_return_type` resolves the AST type and
passes it through the role-aware `check_varg_elem(..., "return")` validator.
The output descriptor families are the same seven representation families as
input varargs, so `nil`, foreign pointers, and any type without a supported
descriptor representation are rejected with return-specific diagnostics.
`value` is retained as `Type.Value`; finite option projection never constructs
an artificial `value?`.

An unannotated lambda in an expected function context copies both the fixed
`rettypes` and `flexrettype`. An explicit `: ()` keeps an empty fixed list and
`flexrettype = false`. The main-function contract requires both
`varargtype = false` and `flexrettype = false`, preserving the exact one-fixed-
parameter `main(args: {string}): integer` shape.

## One finite/open result demand

`checker.lua` represents every expression-list consumer with
`result_demand(fixed, tail, opts)`:

* `fixed` is a dense sequence of demanded positions. `UNKNOWN_SLOT` represents
  a known position whose type is inferred rather than supplied by context.
* `tail` is `false` for a finite consumer, a resolved `Type.*` for a typed open
  consumer, or `INFER_OPEN` for an open consumer whose element type is inferred
  from its inputs.
* `missing` selects ordinary arity failure, call-argument nil padding, or the
  narrow recovery behavior used by strict C calls.
* `explicit_surplus` selects discard for Titan expression lists and error for
  explicit C surplus.
* `dots_nilfill` is a specialized policy flag: generic-for tuple setup enables
  it so missing state/control positions projected from trailing input `...`
  become nil; ordinary fixed calls leave it disabled and retain raising reads
  for non-nil-compatible targets.
* the remaining options carry diagnostic terms, source locations, open-tail
  coercion policy, `dots_limit`, and the expression checker used by specialized
  sites.

`adjust_explist(exps, demand, st, errors)` performs the elaboration. Its result
has these stable fields:

```text
exps          every written expression, plus synthesized finite projections
fixed         values delivered to the finite prefix, indexed by demand slot
tail_scalars  statically known scalar values delivered after the prefix
discards      retained expressions evaluated only for effects
open_source   the sole possible runtime-sized final producer, or false
open_type     that producer's element type
open_target   the sink's element type
open_start    the first still-unconsumed element of the dynamic run
```

`missing` and `explicit_surplus` are also recorded when error recovery needs
their counts. The enclosing node keeps the complete adjustment:

| Consumer | Annotation |
| --- | --- |
| local declaration or assignment | `_result_adjustment` |
| `return` | `_result_adjustment` |
| call arguments | `_arg_adjustment` |
| array constructor | `_array_adjustment` |

Only the final expression can expand. Every earlier expression is checked
under a one-result scalar demand while a fixed slot or open tail remains. Once
a finite consumer is full, later written expressions are checked under a
zero-result demand, retained in `exps`, and marked `_discard_results`; a
discarded call also receives `_voidok`. This preserves source-order effects
without exposing or passing a surplus value.

The final expression is checked under the complete remaining demand. For a
call, `finite_result_expressions` turns each statically visible result after
the first into an `Ast.ExpExtra`. A projected flexible slot carries
`_from_flex`, `_possibly_absent`, and its `_result_source`. Ordinary
`trycoerce` and `checkmatch` then insert any option widening, element
conversion, or non-option nil force required by the sink.

### Declared call shape versus visible call shape

`annotate_call_results` records both sides of a call:

| Annotation | Meaning |
| --- | --- |
| `_callee_type` | complete checked callable type; native ABI authority |
| `_types` | declared fixed result prefix; retained for existing coder paths |
| `_flexrettype` | declared flexible element, or `false` |
| `_visible_types` | finite and statically visible results for this consumer |
| `_result_sources` | `{kind="fixed", index=i}` or `{kind="flex", index=i, may_absent=true}` per visible slot |
| `_finite_flex_prefix` | number of flexible slots projected by a finite demand |
| `_flex_result_demand` | finite projected count, `"open"`, or `nil` |
| `_open_results` | dynamic source/target/start descriptor for an open sink, or `false` |

`_type` remains the first visible type, or `Type.Void` when the demand exposes
none. A flexible projection is `optionize(flexrettype)`: existing option types
and `value` remain unchanged, while every other element becomes `T?`.

An open demand first exposes any declared fixed results not already consumed
by its finite prefix. `_open_results` is present only when the callable's
static type itself has `flexrettype`; it records the source element type, sink
element type, and first unconsumed flexible index. Thus an open sink does not
turn a fixed static function type into `LUA_MULTRET` and cannot reveal results
hidden behind a narrower compatible type.

Call arguments also receive `_npassed_args`, the count of statically passed
fixed/tail scalars, and `_open_args = {source, source_type, target_type,
start}` when a final dynamic run feeds a Titan input vararg. Direct C calls use
the same adjustment engine but set `explicit_surplus = "error"`; a trailing
producer can be truncated to the exact C formal count, while a runtime-open
Titan run never crosses a C variadic boundary.

Generic `for` uses a finite demand for its at-most-four iterator tuple. Extra
results truncate, and missing positions can be supplied by optionized
flexible projections. Its tuple demand also sets `dots_nilfill = true`, so a
trailing input vararg follows Lua's nil-adjustment for missing state/control;
ordinary fixed call borrowing does not inherit that exception. Its synthesized
iterator type uses the same function result-shape constructor as contextual
calls, preventing a separate dynamic call rule from drifting away from
ordinary expression-list semantics. If a sole call through `value` produces
the tuple, that finite demand synthesizes four fixed `value` results: iterator,
state, initial control, and close. A missing fourth result is therefore a
nil-padded, run-time-absent close rather than an open result tail.

## Contextual calls through `value`

The `Ast.ExpCall` checker treats a `Type.Value` callee as an unknown callable
whose structural type is derived from the already known call context.
`synthesize_value_call_inputs` checks the positional arguments once under an
open `INFER_OPEN` demand:

* scalar arguments and all statically visible fixed results of the trailing
  producer become fixed parameter types;
* a final runtime-open input run becomes `varargtype`;
* an empty argument list produces an empty fixed parameter list.

`synthesize_function_type` builds the result side from the consumer demand.
Known finite slots use their expected types, unknown finite slots become
`value`, a statement call produces no results, and an open demand becomes
`flexrettype` with its known element type or `value` for `INFER_OPEN`.

The checker inserts an `Ast.ExpCast` from `value` to that resolved
`Type.Function`. It deliberately does not redispatch the cast through the
ordinary `ExpCast` visitor: the target is already resolved and the callee and
arguments have already been checked exactly once. The following annotations
make the origin explicit to the coder and diagnostics:

```text
cast._contextual_value_cast = true
call._contextual_value_call = true
call._contextual_function_type = synthesized_type
```

The call then follows normal structural-function argument and result
annotation. Nested `outer(inner())` calls preserve the same last-expression
rule: an open outer argument demand synthesizes an open `value` result for the
inner call, while a known fixed outer signature gives it finite demands.

Named syntax is rejected before synthesis because an arbitrary `value` has no
declaration `paramnames`. At run time, a value that is not callable reaches
Lua's ordinary non-callable diagnostic. A Titan closure stored in `value` can
still recover the native path when the synthesized function type exactly
matches its runtime tag.

## Strict identity and directional compatibility

`types.equals` remains strict structural identity. For `Type.Function`, it
compares the C `vararg` bit, every fixed parameter and result, input-vararg
presence and element type, and flexible-result presence and element type.
`Type.Method` and `Type.StaticMethod` carry the same tail in their declaration
and serialized shapes; binding or selecting either produces a
`Type.Function` whose exact identity includes that tail. Parameter names are
declaration metadata and do not participate in structural function equality.

`types.tostring` renders every flexible result in a parenthesized list, even
when it is the only result. This gives function-type tags a collision-free
canonical key: `() -> T`, `() -> (T, ...: U)`, and `() -> (...: U)` are all
distinct. `function_type_tag` uses that exact key, so two merely compatible
types never share a native-entry cast by accident.

`types.compatible(expected, actual)` is directional. Its function arm uses
`slot_compatible(target, source)`, which accepts ordinary compatibility or an
implicit source-to-target coercion, with these rules:

### Inputs

* The actual callable may have fewer fixed parameters than the expected type;
  the actual ignores the expected suffix.
* The actual may not have more fixed parameters, because those positions would
  be hidden requirements that callers of the expected type need not supply.
* Shared fixed parameters reverse the recursive relation: the actual parameter
  must accept values admitted by the expected parameter.
* If a shorter actual callable has an input vararg, every expected fixed value
  moved into that tail is checked against its element type.
* An expected input tail may be ignored by a non-variadic actual. When both
  tails are observed, the actual tail must accept the expected tail element.
* The untyped C-FFI `vararg` bit remains strict and is compatible only through
  prior exact equality.

### Results

* Shared fixed results preserve the recursive relation: the actual result must
  be acceptable to the expected consumer.
* Extra actual fixed results are hidden by a finite expected type.
* When expected fixed slots extend into an actual flexible tail, the checker
  first compares against the optionized projection. A non-option target may
  alternatively accept the raw element type and receive the ordinary runtime
  nil force when that slot is absent.
* An expected flexible tail checks every remaining actual fixed result and the
  actual flexible element, when present, against its element type.
* An actual fixed-only result list may end under an expected flexible tail;
  zero trailing values is a valid run.

This is parameter contravariance and result covariance expressed through
Titan's existing gradual/coercion relations. The local two-way `value` rule
does not make whole function types symmetric. Compatibility controls storage
and generic calls; equality alone licenses the exact native function-pointer
path.

## Generated result runs and the native ABI

The runtime already defines seven exact-layout descriptor families in
`titan-runtime/titan.h`: integer, float, boolean, string, array/map, `TValue`,
and nominal userdata. Each is a pair:

```c
typedef struct {
    lu_byte n_args;
    ElementType *args;
} TitanVargX;
```

Input varargs and flexible outputs reuse those layouts but assign ownership
differently. An input descriptor describes upstream-owned backing and travels
with a separate `_start` offset. A flexible output descriptor points at
storage owned by the caller; it has no separate start parameter, and the
callee writes the produced count into `n_args`.

### Native signature

A flexible native entry has this parameter order:

```c
RET f(lua_State *L, Udata *_mod, CClosure *_fn,
      /* method self, fixed parameters, */
      /* optional TitanVargX *_varargs, int _start, */
      /* fixed result out-pointers 2..m, */
      TitanVargY *_flexout, int _flexwant);
```

`TitanVargX` and `TitanVargY` are placeholders for the real element-specific
types; input and output directions reuse the same seven struct names.

The first fixed result remains the C return value; fixed results 2 through
`m` remain caller-supplied out-pointers. The input-vararg pair follows all
fixed inputs and precedes fixed result out-pointers. The flexible-output pair
comes last, after every fixed out-pointer. A flex-only function has C return
type `void` plus `_flexout, _flexwant`.

`_flexwant` is both demand and capacity:

| Value | Contract |
| --- | --- |
| `0` | produce no stored tail values; no writable element is required |
| positive `n` | write at most `n` tail values and set `n_args` to the count actually present |
| `LUA_MULTRET` | preserve the complete actual tail, up to `TITAN_VARARG_MAX` |

Finite callers allocate a right-sized typed array; a zero-demand site may use
a one-element placeholder that is never written. Open callers reserve
`TITAN_VARARG_MAX` elements. The callee never returns backing that belongs to
its own C frame and never replaces `_flexout->args`. Nested or forwarded runs
are copied into the outer caller's buffer.

Every exit initializes `_flexout->n_args`, including bare return,
flexible-only fallthrough, a fallthrough whose fixed prefix is nil-compatible,
and pending-return dispatch after `finally`. A producer still evaluates
expressions beyond a finite `_flexwant`; it discards their values instead of
materializing them in the output buffer.

### The coder's result-run abstraction

The coder carries a dynamic sequence as a result run containing the typed
descriptor, first element/start, element type, finite or open extent, parallel
Lua root range, ownership, and stack restore/cleanup point. An open expression
list is an ordered scalar prefix followed by at most one such dynamic run.

The same abstraction feeds four paths:

* forwarding an input vararg;
* receiving a flexible call result;
* forwarding a flexible return; and
* appending a final producer to an array constructor.

Fixed results stay in their existing C temporaries and out-parameters. The
dynamic run starts only after the declared fixed result prefix. Sink
conversions are element-wise and use the normal `setwrapped`, `checkandget`,
array-growth, and write-barrier paths rather than a flexible-only conversion
system.

A flexible function's return statement is statically open, but its native
entry inherits the caller's runtime `_flexwant`. `codereturn` threads the
remaining budget through its scalar prefix and final run. A finite budget is
decremented by each scalar written into the tail; after it reaches zero,
remaining expressions execute under discard demand. An exact nested flexible
call receives that remainder, or `LUA_MULTRET` only when the inherited budget
is open. A generic nested flexible call always uses `LUA_MULTRET`, preserves
the raw result count on the Lua stack, and copies only the permitted remainder.
The inherited `_flexwant` is a Titan copy budget; it is not encoded as the Lua
call's requested result count.

The checker marks every coercion it synthesizes. For an explicit tail scalar,
return lowering evaluates and stabilizes the source carrier unconditionally,
then performs only that sink-inserted coercion inside the remaining-budget
guard. This preserves effects and lexical order without letting a discarded
`value` check or option unwrap raise. A user-written `as` cast is unmarked and
remains part of source evaluation, so its failure is still observable even
when the caller does not retain that result.

The 200-element cap applies to every typed output descriptor that Titan
materializes. A finite consumer requesting more than 200 flexible positions is
rejected by the checker; a runtime requested count over 200 is rejected by a
Lua wrapper. When a Titan boundary materializes an effectively open descriptor,
more than 200 actual tail values raise. A smaller finite inherited copy budget
materializes only the requested prefix and ignores surplus raw Lua results
without spuriously applying the open overflow rule.

## Exact and generic calls

Direct module functions, record statics, methods, bound methods, lambdas, and
exact first-class Titan closures use the native entry. At each exact call,
the coder:

1. evaluates every explicit argument once in lexical order and passes only
   the fixed prefix plus an input-vararg run when declared;
2. reserves storage for every declared fixed result, even when the consumer
   hides some of them;
3. allocates a source-typed flexible buffer matching the finite/open demand;
4. invokes the native entry with the complete declared signature;
5. anchors every GC-bearing result before an allocation can occur; and
6. exposes only `_visible_types` plus the permitted dynamic run to the sink.

For each finite flexible projection, the caller tests the requested index
against `_flexout->n_args` before reading the backing array. A present element
is converted normally; an absent element is materialized as nil, after which
the checker-inserted option conversion or non-option force applies. An open
consumer iterates only the actual `n_args` range, beginning at the
`_open_results.start` recorded after any finite projections.

`codevaluecall` retains the existing exact-tag branch. A Titan `CClosure` with
the exact canonical function tag loads `_mod` and the native entry pointer
from its standard upvalues, casts the pointer to the full flexible signature,
and calls it directly. The flexible tail is part of the tag, so a compatible
but differently shaped closure cannot enter that branch.

Everything else uses the generic Lua-stack branch: compatible-but-non-exact
Titan closures, Lua closures, Lua C functions, and `__call` values. A
contextual `value` call reaches the same split after synthesis; exact recovery
is therefore possible without a separate dynamic-call implementation.

### Choosing the Lua VM result request

The generic path derives `nresults` from both the consumer demand and the
callee's static type:

* A finite demand requests exactly its visible result count. Lua truncates
  surplus results and pads absent positions with nil before Titan applies its
  normal result checks.
* An open sink requests `LUA_MULTRET` only for a statically flexible producer
  marked `_open_results`.
* An open sink consuming a fixed-only static callable requests that callable's
  remaining declared fixed count. A wider runtime closure cannot leak hidden
  results through a narrower static type.

After `LUA_MULTRET`, the coder derives the raw count from the restored stack
top before resetting it. If fewer than the statically fixed prefix arrived,
it explicitly supplies nil for the missing fixed positions before conversion;
option and `value` positions accept it, while non-options use the ordinary
runtime force. The flexible count is the remaining raw count after the fixed
prefix, capped at 200 for an effectively open consumer.

A trailing generic flexible call inside a flexible return is still a
statically open producer even when the outer native caller supplied a finite
`_flexwant`. Generated code calls every such producer with `LUA_MULTRET`,
regardless of whether the runtime callable is a Titan closure, Lua closure, Lua
C function, or `__call` object. The Lua stack owns and roots the complete result
run. Titan measures its raw count after `luaD_callnoyield`, copies at most the
remaining finite budget, and applies the 200-value overflow error only when the
enclosing sink is effectively open.

No finite `_flexwant` is smuggled through `CallInfo` at a generic boundary. A
compatible-but-non-exact Titan closure therefore enters its Lua wrapper with
`LUA_MULTRET`; the wrapper treats its own native call as open and enforces its
own 200-value descriptor bound before returning.

Lua 5.5's finite result count is encoded in `CallInfo.callstatus` and is
bounded by `MAXRESULTS` (250). That creates a second, independent bound only
for an ordinary finite generic function-value call. The checker rejects a
finite visible request above 250. Direct/static Titan calls are exempt because
they use typed native out-parameters, and statically open generic producers are
exempt because they use `LUA_MULTRET` rather than the finite VM field.

The generic branch keeps the installed Titan error handler active and stores
stack positions as offsets across `luaD_callnoyield`, because the call can
grow or relocate the Lua stack. The error-handler slot is excluded from raw
result counts. Success restores `L->top.p` after live results have been
converted and anchored; failures retain the ordinary non-callable and boundary
diagnostics.

## Lua entry wrappers

`genluaentry` accepts every Lua stack argument. It pads missing fixed
parameters with nil and checks them as before. A fixed Titan function ignores
surplus Lua arguments; an input-variadic function checks and collects them in
its input descriptor.

For flexible results, the wrapper reads Lua 5.5's requested-result count from
the current `CallInfo` with `get_nresults(L->ci->callstatus)`:

* a finite request passes `max(requested - fixed_count, 0)` as `_flexwant`;
* a finite flexible demand over 200 raises before entering the native body;
* `LUA_MULTRET` passes an open `_flexwant` and reserves the maximum tail;
* the wrapper returns every fixed result plus the actual produced flexible
  count, leaving Lua to perform the caller's final finite truncation/padding.

The wrapper reserves all destination stack space before the native call. It
therefore has stable slots ready to anchor fixed and flexible GC-bearing
results during the allocation-free native-to-wrapper handoff. Stack pointers
are recomputed from saved offsets after any operation that can relocate the
stack.

## GC, errors, and pending returns

The generated C and allocating/nested-`finally` stress coverage enforce the
following lifetime contract.

`TitanVargX.args` is raw typed C storage and is invisible to Lua's collector.
The descriptor is not a root. Every collectable element simultaneously lives
in a traced Lua stack slot or another traced Titan object for its complete
live range.

The ownership/rooting rules are:

* input descriptors borrow backing whose upstream stack roots remain live
  through the call;
* exact-call output buffers belong to the caller, which reserves parallel
  destination roots before entering the callee;
* return expressions first enter GC-safe saves before their raw values are
  copied to output backing;
* source roots remain live while nested and converted runs are copied;
* no allocating operation occurs between releasing the callee's temporary
  roots and anchoring the corresponding caller-owned output values;
* generic Lua results remain rooted in their VM result slots until conversion
  and destination anchoring finish.

All stack locations that survive a possible allocation or call are stored as
offsets and recovered with `restorestack`; raw `StkId` pointers do not cross a
relocation point. The output buffer itself needs no write barrier because it
is not a Lua heap owner. Later stores into closures, module/record userdata,
tables, or arrays use their ordinary forward or back barriers.

### `finally` and flexible pending returns

The pending-action machinery represents a saved return as:

```text
fixed return saves
flexible descriptor and produced count
parallel flexible root base/count
```

`make_return_frame` reserves traced slots for GC-bearing pending elements and
volatile C storage for non-GC state that crosses a longjmp boundary.
`codereturn` fills those saves before setting `PA_RETURN` and jumping to the
innermost finally. A normal finally completion routes the saved run through
`dispatch_return_epilogue`; nested finally frames copy into the outer pending
return while preserving roots and count. A raise from finally replaces the
pending return, exactly as for fixed results.

Flexible roots remain live throughout the finally body because cleanup may
allocate, invoke nested calls, grow the stack, or raise. Dispatch reads rooted
values before lowering the stack top, then copies into the caller-owned output
buffer and performs the allocation-free return handoff. `return` remains
illegal lexically inside `finally`; only body/catch returns can become pending.

Every empty-return path records a zero flexible count. This includes bare
return, flex-only fallthrough, the existing `(nil, ...: T)` fallthrough case,
and an empty pending body/catch return resumed after finally. It prevents stale
descriptor counts from a prior call from becoming visible.

## Serialization and ABI 0.14

The working-tree interface serializer includes `flexrettype` in every callable
shape:

```text
Function(params, rettypes, vararg, varargtype, flexrettype)
Method(fqtn, name, params, rettypes,
       varargtype, flexrettype, paramnames)
StaticMethod(fqtn, name, params, rettypes,
             varargtype, flexrettype, paramnames)
```

An absent tail serializes explicitly as `false`. The field precedes
declaration-only `paramnames` on methods and statics. Interface recovery and
all recursive nominal walkers consume the same position, while
`types.tostring` includes a present tail in the canonical function tag.

These changes define compiled-module ABI **0.14**. The marker, paths, fixtures,
and installed images move together. Two independent incompatibilities require
the bump from 0.13:

* serialized `Function`, `Method`, and `StaticMethod` constructor payloads
  gained the flexible-return field; and
* every native flexible-return entry gained the trailing caller-owned
  `_flexout, _flexwant` pair.

The native signatures of fixed-only functions are unchanged, but a 0.13
module cannot safely be decoded under the new constructor schema. Import
loading must therefore check the new module ABI marker before interface
rehydration and report the ordinary clear mismatch for 0.13 artifacts. Exact function
tags and imported native declarations are reconstructed only after that check,
so no old callable can be cast to the 0.14 flexible ABI.
