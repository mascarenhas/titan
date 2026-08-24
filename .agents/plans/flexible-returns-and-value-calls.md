# Flexible returns and contextual `value` calls — implementation plan

Status: implemented and locally verified (2026-07-16)

Primary feature brief: `/home/mascarenhas/.codex/attachments/57647ba4-d653-4f73-9b92-f2f076248975/pasted-text-1.txt`

Implementation note: source-matched Lua 5.5 lowering exposed a second bound
independent of the 200-element Titan descriptor limit: finite generic
function-value requests are encoded in `CallInfo.callstatus` and may contain at
most `MAXRESULTS = 250` results. The implementation checks that boundary only
for genuinely finite generic calls. Every statically open generic producer uses
`LUA_MULTRET`, preserves its raw count on the Lua stack, and is trimmed or
checked by the Titan sink afterward. Direct native Titan calls are exempt.

## 1. Outcome and scope

Add the return-side analogue of variadic parameters to Titan. A callable may end
its declared result list with `...: T`, meaning that it returns a fixed prefix
followed by a runtime-sized sequence of `T` values:

```titan
function names(): (...: string)
    return "Ada", "Grace", "Edsger"
end

function lookup(): (boolean, ...: integer)
    return true, 10, 20, 30
end

local ok: boolean, head: integer, next: integer? = lookup()
local all: {string} = { names() }
```

The same syntax belongs in function types and in every Titan callable
declaration that already supports a fixed result list: module functions,
record functions, methods, and anonymous functions. Input and output tails may
coexist:

```titan
local f: (...: string) -> (boolean, ...: integer)
```

The feature also makes calls through `value` context-sensitive. The checker
will cast a `value` callee to a synthesized function type whose parameters come
from the argument expression list and whose results come from the surrounding
expression-list demand. This lets ordinary Lua functions retain their
multiple-result behavior through `value`:

```titan
local f: value = lua_function
local one: integer = f()
local maybe: integer? = f()
local many: {integer} = { f() } -- synthesize () -> (...: integer)
```

This work also deliberately changes the fixed-arity boundary for Titan
functions:

- Surplus arguments are evaluated once, from left to right, and ignored by a
  non-variadic Titan callee. The same is true when Lua calls a Titan wrapper.
- Surplus returned values are ignored by finite consumers.
- Missing fixed arguments keep the existing nil-padding behavior: option and
  `value` parameters accept nil, while forcing nil into a non-option parameter
  may fail at runtime.
- A finite projection from a flexible result tail has type `T?`, because the
  requested slot may be absent. `value?` is normalized to `value`.
- An open consumer receives only results that actually exist, so its element
  type is the raw tail type `T`, not `T?`.
- C functions, C function pointers, and C pseudo-constructors retain strict C
  arity. Titan expression-list adjustment may provide exactly their declared
  arguments, but the compiler must never silently pass a different C ABI
  shape.

The implementation must preserve Titan's exact native call paths. Direct
module/record calls, methods, bound methods, anonymous functions, and
first-class Titan closures whose runtime tag exactly matches the static
function type must continue to call the generated native entry point. Only
non-exact compatible function values and genuinely dynamic Lua callables use
the Lua-stack path.

## 2. Semantic decisions

### 2.1 Type and syntax model

Represent a flexible return tail separately from the fixed `rettypes` list.
Use `flexrettype = false` when absent and a `Type.*` value when present. Do not
encode the tail as a sentinel inside `rettypes`; fixed result indices are used
throughout checker and coder logic and should remain ordinary dense arrays.

Extend these shapes:

- `Ast.TypeFunction`: add `flexrettype` after `varargtype`.
- Callable declarations (`TopLevelFunc`, `TopLevelMethod`,
  `TopLevelStatic`) and `Ast.ExpFunction`: add the parsed flexible result type
  alongside their fixed `rettypes`.
- `Type.Function`: add `flexrettype` after `varargtype`.
- `Type.Method` and `Type.StaticMethod`: add `flexrettype` before
  declaration-only `paramnames` metadata.

The canonical spelling is a trailing `...: T` inside the parenthesized return
list:

```titan
function a(): (...: integer)
function b(): (string, ...: integer)
local c: () -> (...: integer)
local d: (integer, ...: string) -> (boolean, ...: value)
```

It is illegal before a fixed result, more than once, or without its type. A
flexible return tail is not an ordinary variadic parameter and should have a
return-specific parser error label/message rather than reusing wording that
says “variadic parameter.”

`...: value` is stored canonically as `Type.Value`; projecting it into a
finite slot remains `value`. Centralize or reuse the checker’s optionization
rule that maps `Type.Value` to itself rather than constructing `value?` (there
is not currently a public `types.optionize` helper).

Because the native ABI reuses the seven `TitanVargX` layouts, a flexible tail
must have one of the same supported element representations as an input
vararg. Refactor `check_vararg_elem` into a role-aware shared validator and use
it for both directions. Keep the current bans on `nil` and foreign/C pointers
(and reject any other type for which `varg_struct_name` has no representation),
but give flexible returns return-specific diagnostics rather than calling them
parameters.

### 2.2 One expression-list adjustment model

Replace the checker’s duplicated multiple-result expansion at declarations,
assignments, returns, calls, and array construction with one internal
result-demand abstraction. It should describe:

- A finite fixed prefix: an ordered list of expected slot types. A slot may be
  unknown during inference, but its count is still known.
- An optional open tail: the expected element type for every remaining result.

Only the final expression in an expression list can expand. Earlier expressions
are scalar contexts and contribute their first result. While fixed demand
slots remain, those scalar results fill them; after the fixed prefix, each
scalar expression contributes one element to an open tail. With no open tail,
expressions beyond finite demand are checked/evaluated under a zero-result
discard demand. The final expression contributes one scalar result and may
additionally expand its remaining fixed/flexible results. Every written
expression must remain in the elaborated AST so discarded expressions still
execute exactly once in source order.

Finite adjustment follows these rules:

1. Consume fixed results from the trailing call first.
2. If the call has a flexible tail and more slots are demanded, project each
   tail slot as `optionize(T)`; absence is represented by nil.
3. Ignore produced results beyond the finite demand.
4. Preserve the existing error for too few fixed results when no flexible tail
   can provide them.
5. Let ordinary `trycoerce`/`tryforce` handle the projected option: assigning
   to `T?` is safe, assigning to `T` inserts the existing runtime nil unwrap,
   and assigning to an incompatible type is a compile-time error.

Open adjustment keeps the fixed prefix and then consumes every result that
actually exists from the statically visible producer shape. This includes
ordinary scalar expressions and remaining declared fixed results before an
optional flexible tail. It does not synthesize absent tail slots.
There are three initial open sinks:

- a variadic call-argument tail;
- a flexible function-return tail;
- the expanding final expression of an array constructor.

These are instances of the same result-demand rule, not array-specific
exceptions. In particular, `return f()` in a function with a flexible return
tail is an open consumer just as the final `f()` in `{ f() }` is: when `f` is
a generic callable whose static type has a flexible result tail, generated C
must request `LUA_MULTRET`, recover the actual result count from the restored
stack top, and forward or append exactly the results that exist. A finite VM
request would instead truncate surplus results and nil-pad missing results,
destroying that count. The array case is called out only because the brief’s
`{ f() }` example makes array construction a third open context even though it
is not itself variadic syntax. Map entries, record fields, named arguments,
conditions, parenthesized expressions, and other scalar sites demand one
result. A call used as a statement demands zero results.

Give all these sites a shared checker API, for example a demand value with a
`fixed` sequence and optional `tail`, rather than adding another family of
per-site `expand_*` helpers. The API should return:

- the elaborated expressions, including explicit discarded expressions;
- the visible finite result types;
- whether the final call is consumed as an open run;
- the source type of that open run; and
- enough discard metadata for code generation to avoid passing surplus values
  while still evaluating their expressions.

After the demand’s fixed slots have been filled, its open element type applies
both to any remaining fixed results from the final producer and to that
producer’s flexible tail. This is what lets a call with fixed results feed a
variadic parameter/flexible return/array tail without losing its remaining
fixed prefix. Reuse `Ast.ExpExtra` for finite projected slots where practical,
with an annotation distinguishing a possibly absent flexible-tail projection;
an open run should stay as one annotated trailing producer rather than being
expanded into a statically unbounded family of AST nodes.

An open *consumer* does not by itself make a fixed producer dynamically open.
The call mode is the intersection of consumer demand and the producer’s static
result shape:

- A fixed-only callable contributes exactly its statically declared fixed
  results, even in an open array/vararg/flexible-return sink.
- A compatible runtime function hidden behind a narrower fixed static type
  cannot leak its additional actual results.
- Only a statically flexible callable—including a contextual `value` cast
  synthesized with `flexrettype`—has a runtime-unknown tail.

This distinction is part of the exact/generic contract, not merely an
optimization.

Keep the callable’s declared ABI result shape separate from the result shape
visible to the consumer. In particular, an exact native call must still
provide storage for all declared fixed out-parameters even when its context
uses only the first result. Consumer annotations such as `_types`, a finite
flex count, and an `_open_results` marker must not replace the callee’s
`Type.Function` as the source of ABI truth.

### 2.3 Contextual calls through `value`

When the callee has `Type.Value`, synthesize a `Type.Function`, insert an
`Ast.ExpCast`, and then continue through the ordinary non-method call checker.
Follow the existing generic-for precedent in
`synthesize_forin_iterator_type` rather than adding a second dynamic-call
implementation. Factor the post-callee call work into a helper so the callee
and arguments are checked exactly once: `trycoerce` the already-checked Value
to the already-resolved synthesized `Type.Function`, then continue argument
checking and call annotation. Do not blindly redispatch that cast through the
current `Ast.ExpCast` visitor, which assumes its target is an unresolved AST
type and calls `typefromnode` again (unless that visitor is deliberately taught
and tested to accept resolved `Type.*` targets).

Build the synthesized input type from the positional argument expression list:

- Scalar arguments contribute fixed parameter types.
- Fixed results expanded from the final argument call contribute fixed
  parameter types.
- A final input `...` or flexible call result contributes `varargtype` for an
  open argument tail.
- If the final argument producer is itself a call through `value` and the
  outer callee has no fixed signature, synthesize that inner call with an open
  `value` result tail and give the outer synthesized function a `value`
  vararg. This preserves Lua’s `outer(inner())` multi-result chaining rather
  than arbitrarily collapsing the inner call to one result.
- A zero-argument call has an empty fixed parameter list.

Build its result type from the consumer’s demand:

- A finite demand produces that many fixed results.
- A finite slot with a known expected type uses that type.
- An unknown finite slot uses `value`, matching the existing generic-for
  synthesis convention. Thus `local x = f()` for `f: value` yields one
  `value` result rather than inventing a concrete type.
- A zero-result statement call synthesizes no results.
- An open demand synthesizes `flexrettype` from the sink element type. In
  particular, `local xs: {integer} = { f() }` synthesizes
  `() -> (...: integer)`.

Thread a known expected type into call checking where the checker already has
one (typed declarations/assignments/returns, known call parameters, array
elements, and similar sites). An unknown scalar context synthesizes one
`value`; this feature need not add reverse inference for operators merely to
guess whether `f() + 1` meant an integer or float call.

Do not resynthesize or recast a callee that already has `Type.Function`; its
declared type and runtime tag determine whether it is exact. A Titan closure
that was stored in `value` may still recover the native path when the
synthesized type exactly matches its closure tag. Otherwise the cast is a
normal compatible dynamic call through the Lua stack.

Calls through `value` remain positional. Named arguments require declaration
parameter-name metadata that an arbitrary Lua callable does not have, so keep
the existing named-call rejection. For statically known Titan functions,
surplus-argument relaxation is positional only: unknown, duplicate, or excess
named labels remain checker errors.

### 2.4 Surplus arguments and results

For a Titan call, check and coerce the formal prefix normally. Check every
surplus explicit argument expression, retain it in the AST, and mark its
result as discarded. A non-variadic exact native call evaluates those
expressions but passes only the fixed prefix. A variadic call feeds its open
tail to the existing vararg descriptor.

For a non-exact function value, push the arguments belonging to its static
function type: the fixed prefix plus a declared vararg tail. Explicit
arguments beyond a non-variadic static type are still evaluated but are not
pushed. This is distinct from a compatible shorter *runtime* Titan closure:
arguments that are part of the wider static expected type are pushed, and the
actual Lua/Titan stack entry wrapper ignores the positions beyond its own true
signature. Remove the current “too many arguments” rejection from generated
Lua wrappers for non-variadic Titan functions; retain missing-argument
nil-padding and let variadic wrappers continue to capture their surplus.

A discarded call expression has a zero-result demand, even if it is the final
written argument/return expression; do not request one result merely because
it occupies an expression-list position. This permits a zero-return function
to be used purely for its effects and prevents a discarded call through
`value` from being synthesized with a fictitious result.

Do not relax C ABI calls. If a Titan expression list supplies more results
than a C call needs, adjust the list to the exact C formal count and discard
the rest before entering the C call. Explicitly surplus C arguments remain a
checker error. The same strict rule applies to direct foreign functions,
function pointers, and pseudo-constructors.

Finite result consumers ignore surplus values, including:

- declarations and assignments;
- fixed return lists;
- fixed call arguments;
- record/map/named-value slots;
- generic-for’s fixed iterator tuple; and
- scalar or parenthesized expressions.

A fixed-return function may therefore write more return expressions than its
signature declares; the extras are evaluated for side effects and discarded.
Generic-for retains its existing maximum iterator-tuple width, but a producer
returning more than that width is truncated instead of rejected.

### 2.5 Directional function compatibility

Function assignment is directional: an `actual`/`found` callable is being used
where an `expected` callable type controls future calls. Keep exact equality
strict—fixed arities, input vararg presence/type, flexible return
presence/type, and every element type must match. Runtime function tags use
this exact identity and must include the flexible tail in their canonical
string without ambiguity.

Extend the existing `types.compatible(expected, found)` operation directly;
do not introduce a parallel `types.assignable` relation. `checkmatch` already
uses this argument order, and `types.compatible` is not commutative in general.
Its special handling of `value` deliberately permits compatibility in both
directions because `value` stands in for any Titan value type, but that local
rule must not be generalized by checking whole function types in both
directions. Keep exact equality separate from compatibility.

Input compatibility is based on what callers of the expected type may send:

- An actual function may have fewer fixed parameters than expected. Shared
  positions must accept the expected caller’s values using the checker’s
  ordinary compatible/coerceable rules in the input direction. Additional
  expected arguments are either ignored by a non-variadic actual function or
  checked against the actual vararg element type.
- An actual function with additional fixed parameters is compatible only when
  every additional position accepts nil from ordinary call adjustment. If the
  expected type has an input vararg, each such position must also accept that
  tail's element type because callers may supply or omit it. This admits
  unmatched option/`value` positions without hiding a non-nilable requirement.
- When the expected type has an input vararg, an actual non-variadic function
  may ignore that tail. If the actual function also observes a vararg tail,
  the expected tail type must be acceptable at the actual input position.
- When a shorter actual fixed prefix moves expected fixed arguments into the
  actual vararg tail, validate each moved type against that tail.

Result compatibility is based on what consumers of the expected type may
observe:

- An actual function may return more fixed values than expected; compare the
  expected prefix with the checker’s ordinary compatible/coerceable rules in
  the result direction and ignore the rest.
- If expected fixed slots extend beyond the actual fixed prefix, the actual
  must have a flexible tail. Compare those projected positions as
  `optionize(actual.flexrettype)` so an expected non-option may use the normal
  runtime unwrap while an expected option remains safe.
- If the expected type has a flexible tail, compare every remaining actual
  fixed result against that element type. If the actual also has a flexible
  tail, compare its element type too. An actual fixed-only function may simply
  end; an expected flexible tail is allowed to contain zero values.
- If the expected type is finite, an actual flexible tail need not be consumed
  beyond the expected fixed width.

Give the implementation executable directional predicates instead of relying
on prose at the comparison sites. In pseudocode:

```text
accepts(actual_param, expected_param)
    = types.compatible(expected = actual_param, found = expected_param)

produces(expected_result, actual_result)
    = types.compatible(expected = expected_result, found = actual_result)

produces_with_absence(expected_result, actual_flex_elem)
    = produces(expected_result, optionize(actual_flex_elem))
      or (produces(expected_result, actual_flex_elem)
          and record that a missing runtime slot must fail the normal unwrap)
```

The pseudocode names the role of each argument; it does not define a second
public type relation. Where a projected flexible result needs an implicit
coercion or nil unwrap, reuse the checker’s existing `trycoerce`/`checkmatch`
flow around `types.compatible`. The last case deliberately allows a non-option
expected result: a generic call through the expected type checks the padded
nil and raises at the usual unwrap site. Compare all statically visible actual
results beyond an expected fixed prefix against the raw expected flexible
element type.

Parameter checks are contravariant in the ordinary assignment sense, while
results are covariant. Concretely, the `Type.Function` arm reverses the
recursive `types.compatible` argument order for parameter types and preserves
it for result types. Do not implement function compatibility as a forward-or-
reverse test, and do not change unrelated callers of `types.compatible` merely
to make them symmetric.

## 3. Current implementation seams

The implementation should begin with focused characterization tests around
these existing control points:

- `titan-compiler/ast.lua`: `TypeFunction` and all callable declaration node
  schemas.
- `titan-compiler/parser.lua`: `rettypeopt`, lambda return parsing, callable
  declarations, `varargtypeann`, and `typelist`.
- `titan-compiler/syntax_errors.lua`: grammar-label coverage and diagnostic
  wording.
- `titan-compiler/types.lua`: `Type.Function`, `Type.Method`,
  `Type.StaticMethod`, all recursive type walkers (including C-FFI detection),
  `tostring`, `equals`, directional `compatible`, and serialization.
- `titan-compiler/checker.lua`: `expand_dots_adjustup`,
  `expand_trailing_multireturn`, declaration/assignment/return handlers,
  `check_vararg_elem`, `checkargs`, array initialization,
  `synthesize_forin_iterator_type`, generic-for elaboration, `typefromnode`,
  and `ExpCall`.
- `titan-compiler/coder.lua`: `function_sig`, vararg descriptor emission,
  `codevaluecall`, `codecall`, `codereturn`, return saves/finally dispatch,
  `codearray`, `genluaentry`, `codefuncdec`, bound-method trampolines,
  `codelambdadec`, imported declarations, closure construction, and every
  function-type-tag site.
- `titan-runtime/titan.h`: the seven `TitanVarg*` descriptor families and
  `TITAN_VARARG_MAX`.
- `titan-compiler/driver.lua`, `Makefile`, CI, and path-sensitive specs: the
  compiled-module ABI version plus the independently release-versioned
  installed-module path.

The existing input-variadic finite projection in `expand_dots_adjustup` is the
behavioral model: a demanded non-option slot gets the raw value plus a bounds
check/force, an option slot is nil-filled safely, and `value` accepts nil.
Preserve it and add parity tests rather than redesigning input `...` as part of
this work.

## 4. Native ABI and generated-code design

### 4.1 Reuse the vararg descriptors as output buffers

Reuse the existing typed `TitanVargX` descriptor families as caller-owned
flexible-result buffers. A flexible-return native function gains a trailing
pair after all fixed result out-parameters:

```c
RET f(lua_State *L, Udata *_mod, CClosure *_fn,
      /* fixed inputs, input-vararg pair, fixed result out-parameters */,
      TitanVargX *_flexout, int _flexwant);
```

`_flexwant >= 0` is the maximum number of flexible-tail values demanded by a
finite consumer. `LUA_MULTRET` denotes an open consumer. The caller owns
`_flexout->args`; the callee writes at most the requested/capacity count and
sets `_flexout->n_args` to the number actually present. A zero demand is valid
and must not require a writable element buffer.

The explicit `_flexwant` is preferable to overloading `n_args`: it keeps input
descriptors’ meaning unchanged, distinguishes capacity from produced count,
and distinguishes “want none” from “want every result.” A function with only
flexible returns has native C return type `void` plus this pair. In other words,
`n_args` remains a backing-count field while a descriptor is used as an input,
and becomes the produced-count field after the same layout is used as a
flexible output; `_flexwant` supplies the output capacity during the call.

For finite demand, the caller may use a right-sized C stack array (with a
one-element placeholder when the requested count is zero). For open demand,
reserve `TITAN_VARARG_MAX` typed slots. Enforce the existing limit of 200:
finite consumers truncate beyond their requested count, while an open
effective consumer (`_flexwant == LUA_MULTRET`) whose producer actually exceeds
200 raises a clear runtime error rather than silently losing values or
overflowing `lu_byte n_args`.

The count limit also bounds finite flexible-tail demand. Reject a statically
known finite demand above 200; a Lua entry whose requested flexible count is
above 200 raises the corresponding runtime error. A producer may evaluate and
discard values beyond a smaller finite demand without materializing them, but
no output descriptor may ever represent more than 200 values.

Never return a descriptor whose `args` points into callee-owned C storage.
Forwarding and nested returns copy into the outer caller’s buffer.

### 4.2 A shared generated-code “result run”

Generalize the coder’s existing vararg-run representation into a shared
runtime sequence abstraction carrying at least descriptor expression, start
offset, element type, finite/open extent, parallel Lua root base/count,
ownership (borrowed versus caller-owned), and stack cleanup/restore point. Use
it for:

- input vararg forwarding;
- flexible call results;
- flexible return forwarding; and
- array-constructor expansion.

Keep fixed results in their existing C locals/out-parameters. The shared run
begins only after the callable’s declared fixed result prefix. Refactor
`codearray` to consume the abstraction through its existing conversion,
barrier, and growth logic rather than inventing a flexible-return-only array
path. An open expression list is an ordered scalar prefix plus at most one
dynamic final run; a sink may stream those parts directly or materialize one
combined descriptor, but it must preserve order, cap accounting, roots, and
ownership across either strategy.

A flexible function’s return statement is statically an open sink, but its
native entry also receives the caller’s runtime `_flexwant`. Thread that as a
remaining tail budget through `codereturn`:

- `LUA_MULTRET` means the inherited consumer is genuinely open.
- A finite budget is decremented by each scalar/fixed result already emitted
  into the flexible tail. Once it reaches zero, later expressions still run
  under discard demand but produce no stored tail values.
- An exact nested flexible producer receives the computed finite remainder;
  it receives `LUA_MULTRET` only when the inherited budget is open.
- A generic nested flexible producer always receives `LUA_MULTRET`, even when
  the enclosing native entry has a finite `_flexwant`. Preserve its raw stack
  count, copy only the finite remaining budget, and apply the 200-value
  overflow check only when that enclosing budget is open.

No inherited finite `_flexwant` crosses a statically open generic Lua-call
boundary. (An ordinary statically finite generic call still passes its concrete
result count to Lua.) In particular, a compatible-but-non-exact Titan closure
in a statically open call enters through its Lua wrapper with an open result
request; that wrapper applies its own open flexible-result bound before
returning to the outer caller.

### 4.3 Exact native calls

Extend `function_sig`, direct calls, closure native calls, bound-method
trampolines, declarations, and lambdas with the flexible output pair. At an
exact call:

1. Evaluate every explicit argument once from left to right.
2. Pass only the fixed prefix plus an input vararg descriptor when the callee
   declares one.
3. Allocate storage for every declared fixed result, even if the consumer will
   discard some of it.
4. Allocate a flexible output buffer for the finite demanded tail or the open
   maximum.
5. Call the native entry point directly.
6. Anchor GC-bearing results before any operation that may allocate, then
   expose only the consumer’s requested fixed/tail shape.

`codevaluecall` must retain its current exact-tag split: an exact Titan
`CClosure` uses the native entry point, while a non-exact compatible closure,
Lua function, C function, or `__call` value uses `luaD_callnoyield`. Add the
flexible return field to the canonical tag so differing result shapes cannot
accidentally take the native ABI path.

### 4.4 Generic Lua-stack calls

Use the Lua VM’s requested-result adjustment instead of always requesting all
results. Choose the VM request from both consumer demand and the callee’s
static type:

- For finite demand, call `luaD_callnoyield` with the exact visible result
  count. Lua then truncates surplus results and pads absent results with nil.
- Use `LUA_MULTRET` only when the demand is open *and* the statically visible
  callee type has a flexible result tail: a variadic call-argument tail,
  flexible return tail, or expanding array tail consuming that producer. An
  enclosing native `_flexwant` limits the later copy; it does not turn this
  generic Lua call into a finite request.
- An open sink consuming a fixed-only static function type requests exactly
  that type’s remaining fixed result count. A wider compatible runtime closure
  may not expose hidden extra results.
- After a `LUA_MULTRET` call, derive and save the raw count from the restored
  stack top. Explicitly nil-pad any missing statically fixed prefix slots
  before validation/coercion—`LUA_MULTRET` does not perform this adjustment.
  Never read above the restored top: option/`value` fixed slots accept padded
  nil and non-options fail through the usual runtime unwrap. The open-tail
  count is `max(raw_count - static_fixed_count, 0)`; convert only those
  remaining live results into the typed result-run representation before
  releasing their roots.
- Enforce `TITAN_VARARG_MAX` on the open tail.
- Keep the installed Titan error handler, saved stack offsets, and stack-top
  restoration correct on both success and conversion/call errors; the error
  slot is never part of the observed result count.

This path must cover transparent Lua functions, Lua C functions, callable
values with `__call`, and compatible-but-non-exact Titan closures. Preserve
the existing non-callable diagnostic.

### 4.5 Lua entry wrappers

Generated Lua entry wrappers must accept surplus stack arguments for all Titan
functions. Fixed wrappers ignore them after coercing/padding their declared
parameters; variadic wrappers collect them as today.

For a flexible-return function, inspect Lua 5.5’s requested result count from
the current `CallInfo` (`get_nresults(L->ci->callstatus)`):

- A finite Lua caller requests only `max(requested - fixed_count, 0)` flexible
  values, with a runtime error if that tail demand exceeds 200.
- A `LUA_MULTRET` caller requests the open tail.
- The wrapper returns its fixed results and the actual flexible values; the Lua
  VM remains responsible for final finite truncation/padding.

Pre-reserve Lua stack space before calling the native function so anchoring
results cannot trigger a stack relocation or collection after native result
roots are released.

### 4.6 GC and error/finally invariants

The typed `TitanVargX.args` backing is not a Lua GC root. Every collectable
flexible result must therefore also remain in a live Lua stack slot (or another
already traced Titan object) across any possible allocation. Reuse the coder’s
existing return-save/root machinery; do not add a process-global root list.

Required invariants:

- Evaluate return expressions into GC-safe saves before filling output
  descriptors.
- Keep source roots live while copying a nested/open result run.
- Have callers reserve destination root slots before the native call and
  anchor received values without allocation.
- Permit no allocating operation in the narrow handoff between a callee
  releasing its temporary roots and the caller anchoring the corresponding
  descriptor values.
- Keep flexible result roots and count live across `finally` bodies, because a
  `finally` block may allocate, call again, or raise while a body/catch return
  remains pending.
- Apply the usual forward/back barriers when flexible values are subsequently
  stored into closures, module/record userdata, tables, or arrays.

Extend the pending-return frame construction (`make_return_frame` in the
completed implementation), `codereturn`, and
`dispatch_return_epilogue` so a pending return consists of its fixed saves plus
the flexible descriptor/count/root range. Preserve the existing language
invariant that `return` is illegal inside `finally`: a normal finally completion
resumes the pending body/catch return, while a `raise` in finally overrides it.
A flexible-only function may fall through with a zero-length tail; existing
always-return analysis remains tied to required fixed non-nil results.
Set `_flexout->n_args = 0` on every legal exit that produces no flexible tail,
not only flex-only fallthrough: cover bare `return`, flexible-only fallthrough,
`(nil, ...: T)` fallthrough, and finally dispatch of a pending empty tail in
both named-function and duplicated lambda epilogues.

## 5. Implementation phases

### Phase A — Characterize and extend syntax/type schemas

1. Add parser tests for sole and trailing flexible returns in module
   functions, record functions, methods, anonymous functions, and function
   types. Cover simultaneous input/output tails and all malformed placements.
2. Extend `ast.lua` constructors and update every constructor call; let
   typedecl arity assertions expose missed sites.
3. Extend the grammar’s fixed result-list parsing with an optional trailing
   flexible tail and add return-specific syntax errors.
4. Extend `Type.Function`, `Type.Method`, and `Type.StaticMethod`, then update
   all manual constructors, recursive walkers, `typefromnode` branches, and
   field copies. Include the C-derived `types.Function` construction in
   `titan-compiler/foreigntypes.lua` (with `flexrettype = false`) and use a
   repo-wide constructor inventory covering compiler sources and specs.
5. Give `types.tostring` a canonical collision-free rendering, and extend
   equality, serialization/deserialization, visitor/debug output, method
   binding, and module interface recovery.
6. Make main-function and synthesized record-constructor recognition require
   no flexible return tail. Reject conversion of a flexible-return Titan type
   to a C function pointer.
7. Share the vararg element-representation validator with flexible returns and
   give its `nil`, foreign-pointer, and unmapped-representation failures
   return-specific diagnostics.
8. Preserve lambda return-inference distinctions: an absent lambda annotation
   copies both fixed and flexible results from an expected function type,
   explicit `: ()` remains fixed-empty/flex-false, and `checkfuncbody`
   validates an explicit/inferred tail at its own source location.

Phase exit: parser/type specs pass; fixed-only source rendering and runtime tags
remain stable, while the deliberately changed serialized constructor layout
round-trips an explicit absent tail; every flexible callable type round-trips
its tail.

### Phase B — Centralize checker expression-list demand

1. Add a checker-local finite/open demand representation and a single
   expression-list adjustment helper.
2. Migrate local declarations and assignments first, including inference,
   option projection, incompatible targets, and explicit surplus-expression
   discards. A discard demand must set the existing void-ok behavior so a
   zero-return call is legal when used only for effects.
3. Migrate call arguments, preserving strict C calls and current named
   argument diagnostics.
4. Migrate fixed/flexible return statements, scalar sites, record/map/named
   values, and array construction. Preserve every scalar expression after a
   fixed prefix as an open-tail element before appending the final expansion.
5. Migrate both generic-for layers. The initial iterator tuple remains a
   finite at-most-four-slot demand with surplus results truncated. For the
   iterator’s `_init_call`/`_next_call`, build an effective finite projection
   for the control result and visible loop declarations: use declared fixed
   results first and `optionize(flexrettype)` for remaining slots. This admits
   flex-only and mixed fixed/flexible iterators, validates the effective first
   control type, and builds `_result_decls`, calls, and visible initializers
   from that projection rather than only `ftype.rettypes`. Iterator close calls
   always use zero flexible-result demand and discard all returns. When the
   finite tuple's sole producer is a contextual `value` call, its fourth fixed
   `value` result is a run-time-optional close: exact nil skips the call inside
   the synthesized `finally`, while every non-nil value uses the ordinary
   callable path.
6. Remove or reduce `expand_trailing_multireturn` and other duplicated paths
   once every consumer uses the common helper.
7. Keep `expand_dots_adjustup` behavior as the input-tail implementation, but
   route it through the same demand vocabulary and add return/input parity
   tests.

Phase exit: checker-only tests prove finite truncation, flexible option
projection, open-tail propagation, side-effect preservation metadata, and C
arity boundaries without relying on code generation.

### Phase C — Synthesize dynamic function types and add compatibility

1. Factor the generic-for synthesis pattern into a helper usable by ordinary
   `value` calls.
2. Synthesize positional fixed/vararg input shapes from adjusted arguments.
3. Synthesize fixed/flexible result shapes from finite/open demand, including
   zero-result statements and unknown finite slots as `value`. Run synthesized
   flexible tails through the same descriptor-representation validator as
   source annotations, reporting an error at the open sink.
4. Factor the non-method call continuation, insert the resolved
   `Ast.ExpCast`, and continue without checking the callee/arguments twice, so
   coercions, diagnostics, and call annotations still have one implementation.
5. Extend the `Type.Function` arm of `types.compatible(expected, found)` with
   the arity and flexible-tail rules, reversing recursive compatibility only
   for parameter positions and preserving the existing two-way `value` rule.
6. Add focused tests for shorter actual input arity, nil-fillable and rejected
   extra actual inputs, extra actual result arity, vararg/flexible-tail
   matrices, exact equality, and incompatible prefixes.

Phase exit: checker tests cover Lua-style dynamic calls and every compatibility
matrix cell; already typed Titan calls are not contextually resynthesized.

### Phase D — Add the native flexible-result ABI and exact call codegen

1. Extend all generated native signatures with the output descriptor/want pair
   only when `flexrettype` is present.
2. Add caller-owned finite/open buffer generation and a shared result-run
   representation.
3. Extend direct module/static/method calls, bound methods, anonymous
   functions, exact first-class closures, imported declarations, and native
   function-address/tag generation.
4. Extend return lowering for fixed values, explicit discarded extras, literal
   flexible tails, input-`...` forwarding, and nested flexible-call
   forwarding.
5. Audit bare-return plus void/nil fallthrough epilogues in both `codefuncdec`
   and `codelambdadec`, initializing a zero flexible count on every empty-tail
   path, including pending returns resumed after finally.
6. Update generated Lua entries to ignore fixed-function surplus arguments and
   request the correct finite/open result count.
7. Inspect generated C in tests to prove exact calls still use native symbols
   and never `luaD_callnoyield`.

Phase exit: exact call paths pass runtime tests, generated C compiles cleanly,
and fixed-only call signatures are unchanged.

### Phase E — Implement generic calls and open consumers

1. Teach `codevaluecall` finite calls to request the exact count, fixed-only
   producers in open sinks to request their static fixed count, and only
   statically flexible producers in open sinks to use `LUA_MULTRET`.
2. Convert live open Lua results into fixed-prefix values plus a typed tail
   run, with coercion, rooting, and the 200-value bound.
3. Feed the result run into variadic calls, flexible returns, and array
   construction.
4. Cover Lua functions, Lua C functions, `__call`, non-exact Titan function
   values, and non-callable errors.
5. Verify that exact synthesized tags can still recover the native path after
   a Titan closure round-trips through `value`.

Phase exit: finite paths and statically fixed producers never use
`LUA_MULTRET`; each of the three open sinks uses it only for a statically
flexible producer; Lua multiple results remain visible through `value` without
leaking results hidden by a narrower static type.

### Phase F — Finish GC, error, and `finally` behavior

1. Extend return-save and pending-return state with flexible count, backing,
   and root range.
2. Exercise flexible results containing strings, arrays, maps, records,
   functions, and `value` through forced collections and stack growth.
3. Test nested forwarding and returns through `try`/`catch`/`finally`, including
   body/catch returns surviving allocating nested finally blocks, a finally
   raise overriding the pending return, and errors during result conversion.
4. Add boundary tests for zero, 200, and 201 open tail values; finite demand
   over a larger exact or ordinary Lua producer must truncate safely, while a
   finite demand of 201 is rejected statically (or at a Lua entry when known
   only at runtime). A non-exact Titan closure entered through its open Lua
   wrapper enforces that wrapper's own open cap before outer truncation.
5. Run an adversarial generated-C review focused on unrooted intervals,
   barriers, descriptor lifetime, stack-top restoration, and error unwinding.

Phase exit: sanitizer-sensitive and forced-GC tests show no stale pointer,
overflow, leaked stack slots, or broken pending return.

### Phase G — Bump and validate the compiled-module ABI

The serialized callable interface and flexible native signature are
incompatible with pre-feature providers. Advance the compiled-module ABI.

1. Update the ABI marker, mangled ABI symbols, generated metadata, and
   ABI-sensitive cache namespaces in `titan-compiler/driver.lua`,
   `titan-runtime/titan.h`, `Makefile`, and `.github/workflows/ci.yml`.
2. Keep compiled lookup paths and versioned environment-variable names derived
   from the independent semantic release; change them only when that release
   changes.
3. Update ABI and path expectations in driver, rockspec, standard-library, and
   support-helper specs, plus README and repository instructions.
4. Preserve the semantic rationale for earlier ABI transitions without
   retaining their historical numbering.
5. Extend serialized `Function`, `Method`, and `StaticMethod` payloads with the
   flexible return field and test `.so` interface rehydration.
6. Verify that importing a pre-boundary module gives the ordinary clear
   mismatch diagnostic before decoding.

Use a targeted inventory such as:

```sh
rg -n 'TITAN_|lib/titan/' \
  titan-compiler titan-runtime spec doc Makefile README.md AGENTS.md \
  .github/workflows
```

Phase exit: a clean installation contains only canonical active standard DSOs
and all binary-interface/rehydration tests pass.

### Phase H — Documentation and repository guidance

Add and index both required manuals in the same change:

- `doc/language/flexible-returns.md`: syntax, fixed prefix/tail semantics,
  finite option projection, open consumption, dynamic `value` calls, surplus
  arguments/results, compatibility, examples, and the 200-result open bound.
- `doc/implementation/flexible-returns.md`: AST/type fields, checker demand
  elaboration, synthesized function types, exact/generic split, native output
  descriptors, Lua wrapper behavior, GC/rooting, serialization, and the ABI boundary.

Cross-update `doc/language/functions.md`, `expressions.md`, `statements.md`,
`types.md`, `option-types.md`, `closures.md`, `lua-interop.md`, `ffi.md`,
`variadic-parameters.md`, `arrays-maps.md`, `named-arguments.md`, `grammar.md`,
`modules.md`, and `index.md`. Cross-update
`doc/implementation/ast-typedecl.md`, `lexer-parser.md`, `checker.md`,
`codegen-overview.md`, `codegen-constructs.md`, `values-and-gc.md`,
`lua-interop-internals.md`, `ffi-internals.md`, `variadic-parameters.md`,
`named-arguments.md`, `error-handling.md`, `driver.md`, and `index.md`.

Update `README.md` Supported features, `doc/documentation-worklog.md` if still
current, and `AGENTS.md` current ABI/signature/setup text. Explain explicitly
that flexible results reuse typed vararg descriptor layouts but reverse
ownership: the caller owns flexible output storage.

Phase exit: both manuals agree with tests and generated C; no current
documentation still calls fixed argument/result arity strict for Titan
functions.

## 6. Test plan

Create topical suites rather than expanding general checker/coder files:

- `spec/checker/flexible_returns_spec.lua`
- `spec/coder/flexible_returns_spec.lua`

Also extend parser, types, ABI, driver, optional-parameter, function-value,
variadic-parameter, error-handling, generic-for, array, interop, and `.so`
rehydration specs where those own an existing invariant.

The primary existing topical owners include
`spec/checker/{optional_parameters,first_class_functions,variadic,for_in,error_handling,so_rehydration}_spec.lua`,
their applicable `spec/coder/` counterparts, `spec/coder/bound_methods_spec.lua`,
`spec/coder/closures_spec.lua`, `spec/{parser,types,abi,driver}_spec.lua`, and
the C-FFI suites. Keep array cases in the current checker/coder owner unless
they become large enough to justify a separate topical suite.

### Syntax and schema

- Sole/trailing flexible returns for every callable form.
- Input and output tails together.
- Malformed missing type, duplicate tail, or non-trailing tail diagnostics.
- Return-specific rejection of `...: nil`, foreign pointers, and every other
  element representation not covered by a `TitanVargX` descriptor.
- Canonical `tostring`, exact equality, directional compatibility, and nested
  serialize/deserialize for Function/Method/StaticMethod.
- An unannotated lambda inferred from an expected flexible-return function
  type, contrasted with explicit `: ()`, plus an unresolved nominal tail
  diagnostic located at its own annotation.
- Recursive type-walker coverage for a local record leaking through a public
  flexible tail and for transitive imported nominal ownership/interface
  recovery through `flexrettype`.
- No flex tail accepted for `main`, record constructors, or C pointer lowering.

### Finite consumption

- `local x, y = f()` from a flex tail, with non-option runtime nil failure,
  option safety, `value` normalization, and incompatible static target.
- Fixed prefix followed by zero/fewer/exact/more flexible values.
- Declaration, assignment, fixed return, call argument, record/map/named
  value, scalar/parenthesized, and generic-for truncation.
- Flex-only and mixed fixed/flexible generic-for iterators: projected optional
  control, visible declaration initialization, repeated next calls, surplus
  truncation, and zero-demand close results. Cover contextual `value` factories
  with a missing, explicit-nil, callable, and non-callable fourth result, plus
  pending `break`, `return`, and error actions under the nil guard.
- Fixed functions returning surplus expressions: all side effects occur once
  and left to right.
- Zero-return calls in discarded argument/RHS/return positions, proving the
  checker sets the existing void-ok path and synthesizes zero results for a
  discarded `value` call.
- Input `...` absent/present parity with flexible result projection.

### Open consumption

- Flexible call tail passed to input `...`.
- Flexible call tail forwarded by a flexible return.
- `{ f() }` with zero, one, and many results, including calls through `value`.
- Fixed prefix plus open tail and nested open forwarding.
- Literal/scalar elements after a sink’s fixed prefix and before the final
  expanding producer, proving conversion, order, and side effects.
- A generic open call returning zero/fewer-than-prefix results, with safe nil
  padding for option/`value` fixed slots and normal unwrap failure for a
  non-option fixed slot.
- Zero, 200, and 201 actual open values; finite truncation of a producer with
  more than 200 possible values; and finite requested counts of 200/201.
- A flexible `outer()` forwarding a 201-result Lua producer: a small inherited
  finite copy budget truncates after the `LUA_MULTRET` call, while an inherited
  open budget reports the limit cleanly. A non-exact Titan closure crosses its
  own open Lua wrapper and therefore enforces that wrapper's open bound first.

### Contextual `value` calls

- Finite typed demand, inferred finite `value`, zero-result statement, and
  open array demand.
- Positional fixed and variadic input synthesis.
- Nested `outer(inner())` where both are `value`, proving the inner call is an
  open `value` result run and the outer synthesized input is variadic.
- A known finite outer signature giving the inner `value` call finite demands,
  and a known variadic `...: T` sink giving it `() -> (...: T)`.
- Lua function, Lua C function, `__call`, exact Titan closure, non-exact Titan
  closure, and non-callable value.
- Named calls remain rejected.
- Finite generic calls request a concrete result count; generated C contains
  `LUA_MULTRET` only for statically flexible producers in open contexts.

### Surplus arguments and compatibility

- Direct module/static/method/bound/lambda/first-class calls ignore surplus
  arguments after evaluating them once in order.
- Lua calls to fixed Titan wrappers ignore surplus stack arguments.
- Variadic Titan functions still observe their surplus.
- C direct/function-pointer/pseudo-constructor calls remain strict.
- Shorter actual input arity assigned to wider expected arity, including
  ignored fixed tail and actual-vararg validation.
- More actual fixed returns assigned to a shorter expected result type.
- Actual flex tail supplying expected fixed options/non-options.
- Expected flex tail consuming remaining actual fixed/flexible results.
- Every incompatible shared prefix/tail direction is rejected.
- Compatibility matrices place `expected` and `found` in their documented
  argument positions for option, `value`, nominal, input-vararg, and
  flexible-return combinations; reversed cases differ where the relation is
  directional, while the deliberate two-way `value` cases pass both ways.
- A wider runtime callable stored behind a narrower fixed static type remains
  narrow in arrays, variadic calls, and flexible returns; its hidden results
  are never exposed by an open consumer.

### Exact path, ABI, and GC

- `DEPTH_PROBE` coverage for direct module functions, record statics, methods,
  bound methods, lambdas, and exact first-class values.
- Generated-C assertions that those paths call native symbols, while
  non-exact/Lua callables use `luaD_callnoyield`.
- Flexible results of every GC-bearing type across forced collection, stack
  relocation, nested calls, module imports, and closure captures.
- Pending flexible body/catch returns through allocating/nested `finally`
  blocks, finally raises, and error handlers; keep the existing rejection of a
  return lexically inside `finally`.
- Zero-count initialization for bare return, flexible-only fallthrough,
  `(nil, ...: T)` fallthrough, and empty pending returns in both named and
  anonymous generated epilogues.
- interface rehydration at the new ABI and clean pre-boundary rejection.

## 7. Diagnostics

Keep errors anchored at the most specific source node and distinguish:

- malformed flexible-return syntax;
- a finite target incompatible with the fixed result or projected option tail;
- an open sink whose element type is incompatible with the producer tail;
- incompatible directional function parameter/result prefixes;
- unsupported flexible returns at a C function-pointer boundary;
- strict surplus arguments at a C ABI call;
- named calls through `value`; and
- runtime overflow of the 200-value open-result limit.

When a finite non-option target is filled from a possibly absent flexible
slot, this is not a checker error: use the existing option-force runtime error
and preserve its source location/traceback behavior.

## 8. Validation and delivery

During implementation, reinstall the compiler snapshot before focused Busted
runs so tests do not load stale installed Lua modules. Use the active prepared
prefix and disable ccache where the sandbox requires it.

Suggested progression:

```sh
CCACHE_DISABLE=1 luarocks make
busted spec/parser_spec.lua spec/types_spec.lua
busted spec/checker/flexible_returns_spec.lua
busted spec/coder/flexible_returns_spec.lua
busted spec/checker spec/coder
bash spec/support/ci_test_groups.sh libraries
CCACHE_DISABLE=1 make test
git diff --check
```

Before publication, run two independent review passes:

1. A semantic review against the feature brief, concentrating on every finite
   and open expression-list context, compatibility direction, and the C ABI
   boundary.
2. A generated-C/runtime review concentrating on exact-call preservation,
   stack/root lifetimes, barriers, `finally`, and the open-count bound.

If the work is pushed for review, wait for push-triggered Linux CI and manually
dispatch the complete macOS pre-merge suite:

```sh
gh workflow run ci.yml --ref <branch>
```

## 9. Acceptance criteria

The feature is complete when all of the following are true:

- Every Titan callable form and function type can declare one trailing
  flexible return tail.
- Finite consumers project missing flexible values as options, use ordinary
  runtime unwrapping for non-options, and discard surplus values.
- Variadic arguments, flexible returns, and array expansion consume open result
  runs, but request `LUA_MULTRET` only from statically flexible producers; a
  fixed static type never exposes hidden runtime results.
- Calls through `value` synthesize their complete positional function type from
  arguments and result demand and transparently preserve Lua multiple results.
- A contextual `value` factory for generic `for` synthesizes four finite
  results; a run-time nil close is absent, while every non-nil close retains
  ordinary callable and error behavior inside the loop's `finally`.
- Surplus Titan arguments/results are evaluated once in order and ignored;
  fixed C ABI calls remain strict.
- Directional function compatibility admits shorter actual input arity and
  longer actual result arity with compatible prefixes, including deliberate
  vararg/flexible-tail interactions.
- All exact Titan call forms still use their native path; only non-exact or Lua
  callables use the generic Lua-stack path.
- Flexible native results reuse caller-owned `TitanVargX` storage, enforce the
  200-value descriptor/demand bound, and keep all collectable values rooted
  across calls, errors, and `finally`.
- Ordinary finite generic function-value requests respect Lua 5.5's independent
  250-result VM bound; open generic and direct native Titan calls remain exempt.
- The compiled-module ABI round-trips the new callable metadata and rejects
  older modules cleanly.
- Checker/coder/runtime/GC/ABI suites pass, the full test suite passes, and both
  manuals plus repository guidance describe the shipped behavior.

## 10. Principal risks and review traps

- **Accidentally making all calls generic.** Keep declared callable type and
  exact runtime tag separate from consumer result demand.
- **Losing side effects while truncating.** Discard annotations must retain
  every explicit expression and preserve source order.
- **Confusing absence with an open element.** Finite projections are `T?`;
  present members of an open run are `T`.
- **Reversing or symmetrizing function compatibility.** Keep `expected` first
  and `found` second at the outer call, reverse the recursive order only for
  parameter positions, and test asymmetric cases alongside the deliberate
  two-way `value` cases.
- **Leaking relaxed Titan arity into C.** Classify the callee before applying
  surplus-argument rules.
- **Using `LUA_MULTRET` as a convenience.** It is permitted only when the
  consumer is open and the producer’s static type has a genuinely unknown
  flexible tail.
- **Treating typed C buffers as GC roots.** Keep parallel live Lua roots and
  pre-reserve all handoff stack space.
- **Returning callee-owned descriptor storage.** All flexible output backing is
  caller-owned, including nested forwarding.
- **Breaking pending returns in `finally`.** Save fixed and flexible pieces as
  one logical return value, preserve them through normal cleanup, and let only
  the existing raise path override them.
- **Partial ABI updates.** Inventory every current ABI claim and generated
  symbol while preserving the feature rationale.
