# Closure adjustment wrappers

## Status and resolved design choices

This plan replaces the original sketch preserved in commit `3916db5`. It is the
coordination contract for the implementation; work is complete only when every
checklist below has been audited.

The maintainer resolved the two user-visible questions before implementation:

* an evaluated non-exact callable adjustment may produce a **fresh function
  identity**; wrappers are never cached, interned, flattened, or made equal to
  their source; and
* a function with no corresponding result may adjust to a callable whose missing
  fixed result accepts nil. The result is supplied by a named nil-fill action,
  not by broadening consistency or lifting an ordinary coercion.

Manual macOS CI is waived for this change. The normal push-triggered Linux graph
must still pass before merge.

## Objective

A first-class Titan call is native-fast only when its runtime function tag is
exactly the call site's static `Type.Function`. Today an admitted directional
callable adjustment retains the source value and tag, so every call through the
adjusted view takes the strict generic path. Change the checker to make the
adjustment explicit and the coder to clone an eligible exact Titan closure with
the target tag and a synthetic target-ABI native entry. Calls through the target
view then use the existing exact path while Lua behavior and erased/non-Titan
fallbacks remain sound.

This is not a new subtyping relation, syntax feature, or general function
coercion. The checker-authorized `CallablePlan` remains the sole semantic
authority. The coder must consume a closed lowering plan and must never rediscover
compatibility from endpoint types.

## Semantic contract and trust model

Let `A` be the actual/source function type and `B` the expected/target function
type.

1. `A == B` remains identity, performs no allocation, and preserves the original
   function value.
2. Evaluating an admitted non-exact `A -> B` edge evaluates its operand exactly
   once. When the runtime value is an exact branded Titan `A` closure with room
   for one extra upvalue, it constructs a fresh branded wrapper tagged `B`.
3. The wrapper's target-native entry adapts `B` arguments to `A`, invokes the
   immediate source closure through its exact native entry, then adapts `A`
   results to `B`. It executes only the checker-frozen callable actions.
4. A runtime operand that is a Lua closure/C function/`__call` object, a
   differently tagged Titan closure, a deferred non-callable value, or a closure
   already at Lua's upvalue ceiling is left unchanged. It retains the existing
   branded/non-Titan generic call behavior and deferred callability failure.
   This guarded fallback is required because a static Function value is not
   runtime proof of Titan's private CClosure layout.
5. Every wrapper actually constructed has a fresh identity: it differs from its
   source and from a separately evaluated adjustment. Wrapper chains therefore
   have one fresh identity per realized non-exact edge. Fallback values keep
   their existing identity. There is no registry cache or equality unwrapping.
6. Lua calls the copied source `CClosure.f`, so Lua continues to observe `A`'s
   arity, dynamic conversions, and result behavior. Titan calls at exact `B` use
   the adapter. A later non-exact Titan call uses a consumer-generated strict
   relay for `B` and then the adapter; it must not depend on an older provider's
   declaration-specific strict-tag check.
7. Callable components admit only identity, nested callable adjustment, and the
   existing strict gradual inject/project/structural operations. Numeric,
   ordinary Option, C, Interface-wrapper, or other scalar coercions do not lift
   through Function structure. Once a direct static adjustment realizes a `B`
   wrapper, `B`'s fixed and typed-tail requirements are enforced on its exact
   path; update the historical test that relied on a runtime tag mismatch to let
   non-integer `...: value` elements bypass a static `...: integer` view.
8. The supported trust boundary is unchanged. Once the existing exact
   tag/brand/private-header predicate succeeds, generated code may trust Titan's
   CClosure slots. Debug/C mutation of private upvalues opts out. Arbitrary Lua
   callables remain outside that trust boundary. Do not add adversarial-AST or
   registry hardening unrelated to an actual untrusted boundary.

## Relation and checker contract

### 1. Add the missing-result action

Extend `types.callable_adjustment` with an ordered result action named
`nil_fill_result` (use one spelling consistently). It is emitted when `B`
requires a fixed result for which `A` has neither a fixed result nor a flexible
result source, and only when the expected result passes the same
`accepts_missing_nil` policy already used for absent fixed arguments:

* admitted: `nil`, `value`, `T?`, Titan pointer, and C pointer;
* rejected: boolean, numbers, strings, records/unions/Interfaces, and every edge
  that would require an ordinary coercion.

The action records the expected index and type, has no source adjustment, and is
non-exact. Source-flex actions still take precedence. The shared relation means
Interface method satisfaction receives the same rule and action.

Update all raw-plan validators and truth tables. This action is shape adjustment,
not a `Nil -> T` component adjustment, so it cannot create a transitive coercion.

### 2. Elaborate finite callable sinks as existing `Ast.ExpCast`

For a non-exact callable plan returned by `types.assignment_adjustment`,
`checker.trycoerce` constructs the existing node:

```lua
local cast = ast.ExpCast(source.loc, source, target)
cast._implicit_coercion = true
cast._adjustment = adjustment       -- the exact CallablePlan object already queried
cast._type = target
```

The child keeps type `A`; the cast has type `B`. Do not also attach
`_assignment_adjustment`. Remove callable plans from `checkmatch`'s
same-representation exception; retain that exception for structural Array/Map
views. Exact pairs remain unchanged.

This central route covers declarations, assignments, fixed arguments and named
arguments, returns, record/union/container slots, and other ordinary finite
sinks. It performs no second relation query and adds no AST tag.

Written non-exact `f as B` already is `Ast.ExpCast` with
`_written_cast.op == "callable"`; lower its stored `callable` plan identically.
`f is B` checks the same admission relation but remains allocation-free.
Dynamic `value -> Function` projection is not a statically known `A -> B` edge
and remains on the generic path.

### 3. Freeze one reusable callable-adapter action graph

Generalize the checker-owned Interface callable freezer rather than creating a
second relation in the coder. A frozen `CallableAdapterPlan` must contain:

* normalized source `A`, target `B`, exactness, dense ordered argument/result
  actions, and recursive component operations;
* the new `nil_fill_result` action;
* fixed and open GC-root inventories for argument sources/destinations and
  result sources/destinations;
* all stack-rebase points, including wrapper construction/nested callable
  operations and the source native call;
* target flexible-result demand calculations and the 200-element ABI cap;
* real cast location and stable trace name; and
* `relation_free = true` plus the no-nested-Interface-conversion invariant.

Attach that frozen plan to finite cast nodes without replacing the raw
`_adjustment` authority. Runtime-open expression-list/`...`/constructor runs have
no per-element AST node; retain their existing shared run-level adjustment and
freeze/register the adapter when `coder._code_adjustment_value` consumes it.
Nested callable component actions likewise recurse through the same freezer.

Interface method adapters keep their existing exact-slot versus adapter path but
consume the generalized action representation. Refactor and validate their
behavior unchanged before using the shared emitter for closure adapters.

## Wrapper representation and construction

For an eligible exact source CClosure with `n` upvalues, construct `n + 1`
upvalues in this order:

```
0                       source module Udata (copied)
1                       exact target-B function tag (replaced)
2                       target-B synthetic native adapter (replaced)
3                       Titan function brand (copied)
4 .. n-2                source captures/bound receiver/private wrapper links (copied)
n-1                     immediate source closure TValue (new traced upvalue)
n                       target-B wrapper strict relay (final light C function)
CClosure.f              source coercive Lua entry (copied)
```

The immediate source closure—not merely its native pointer—is mandatory. The
adapter reads that closure's module/native slots and passes that same closure as
`A`'s `_fn`; an `A -> B -> C` chain therefore delegates layer by layer without
misreading a later wrapper's penultimate slot or losing captures.

Use stack-based `lua_pushcclosure` construction:

* materialize and anchor the operand before any stack growth/allocation;
* copy upvalues 0 through `n - 2`, substituting tag/native;
* push the source closure and the generated target strict relay;
* construct with `source->f`, anchor the result immediately, pop scratch, and
  restore `_base` from `_base_off`;
* treat wrapper construction and nested callable conversion as relocating;
* rely on the new white CClosure's traced upvalues; add no manual forward/back
  barrier and no untraced C storage for the source.

If `n == MAXUPVAL`, leave the value unchanged and use the generic path. Do not
lower Titan's existing capture limit, add registry state, or invent a side
object solely for this extreme optimization case. Test and document this narrow
fallback.

Generate one deterministic site entry (and recursively discovered component
entries) per frozen adapter plan, registered in AST discovery order like lambdas.
Drain the list dynamically because emitting one adapter may discover nested
callable adapters. A plan object may map to one site entry within a translation
unit; do not globally intern by type strings.

## Synthetic entry points

### Target native adapter

The private `static TITAN_NOINLINE` adapter has exactly `function_sig(B)`. It:

1. validates target input/flexible-output descriptor bounds;
2. reserves and nil-initializes its complete traced scratch frame and saves
   `_base_off`;
3. anchors every incoming GC-bearing fixed/open `B` argument before an operation
   may allocate;
4. realizes contravariant argument actions into `A` fixed/tail storage;
5. recovers the immediate source CClosure from the penultimate wrapper upvalue,
   obtains its authoritative module and native pointer, and calls it as exact
   `A` with `_fn = source`;
6. immediately anchors every GC-bearing fixed/flexible `A` result before any
   allocating conversion;
7. realizes covariant result actions into `B`, including nil-initializing the
   first return or an out-parameter for `nil_fill_result`;
8. publishes caller-owned flexible output subject to `_flexwant`,
   `LUA_MULTRET`, and `TITAN_VARARG_MAX`; and
9. restores the root frame, writes out-parameters, and returns `B`'s first result
   or `void`.

Parameterize/generalize the existing Interface adapter engine for these steps.
Only the invocation backend differs: Interface adapters call a known method with
self; closure adapters call a captured source closure through its recovered
function pointer. Keep the proven demand formulas, nil-fill helper, identity
prelude, roots, and rebase logic in one implementation.

Component `callable_view` operations must invoke the same wrapper-construction
helper recursively rather than silently retaining a mismatched tag. The helper
still performs the runtime exact-Titan guard and generic fallback.

### Source Lua entry and target strict relay

Copy `source->f`; it directly calls its statically baked source native entry and
therefore preserves source Lua behavior and copied capture indices. Do **not**
generate or advertise a target Lua coercive entry.

Do not copy or weaken the source provider's strict trailer. Generate a small
consumer-local strict relay for `B`, using the existing strict-entry shell and
checker-provided strict boundary plans. Its carrier validation requires the
wrapper's target tag, target adapter pointer/header shapes, brand (already
selected by the caller), and its own final trailer, but deliberately does not
require one declaration-specific `CClosure.f`. It invokes the target native
adapter with the wrapper as `_fn`.

This relay avoids two bad alternatives:

* relaxing every declaration strict entry to accept arbitrary tags; and
* cloning an old ABI-0.22 provider's strict entry, whose compiled source-tag
  check would reject a consumer-created target-tagged wrapper.

The fixed CClosure header and native signatures remain ABI 0.22; no serialized
schema, provider symbol, or module-state slot changes. Add fresh-process
source/DSO/archive coverage to prove new consumers work with ordinary providers.
If implementation reveals a required fixed-slot/layout change, stop and
coordinate an ABI bump rather than silently extending 0.22.

## Error attribution and effects

* Wrapper allocation is an expression effect emitted in `stats`, never a
  multiply evaluated expression template. Preserve left-to-right argument and
  result evaluation.
* Synthetic adapter `#line` directives and component conversion diagnostics use
  the real cast node's filename/line/column. Open-run adapters use the owning
  consumer expression's location. Honor `--no-line-directives`.
* Register a stable trace name such as
  `[callable adapter A -> B at file:line:col]`; do not expose generated C paths.
* Preserve catch/longjmp spill rules, stack rebasing after calls/allocations, and
  the existing finite Lua VM result limit on fallback paths.

## Scope and non-goals

In scope:

* implicit non-exact Function-to-Function adjustments and written callable `as`;
* every existing fixed/input-tail/flexible-result CallablePlan action plus
  `nil_fill_result`;
* nested callable components and runtime-open adjusted runs;
* top-level/local/imported functions, lambdas/captures, bound methods, wrapper
  chains, and source/DSO/archive providers;
* exact-Titan optimization with sound generic fallback; and
* the small standard-library cleanup motivated below.

Out of scope:

* dynamic `value -> Function` retagging, Array/Map carrier retagging, C function
  pointer adaptation, new syntax, subtyping, or lifted scalar coercions;
* wrapper caching/interning/flattening, equality unwrapping, escape analysis,
  registry identity tricks, or a new public Waiter/Task protocol;
* changing public `async.run`/`uv.run_internal` callback signatures merely to
  land the optimization; and
* cross-ABI migration or historical provider cleanup.

## Test plan

### Pure relation tests (`spec/types_spec.lua`)

* exact and asymmetric direction;
* all existing argument/result/tail/flex actions and canonical indexes;
* nested callable direction;
* `nil_fill_result` acceptance for Nil/Value/Option/Titan pointer/C pointer and
  rejection for required scalar/nominal results;
* rejection of numeric, Option-introduction, C, Interface-wrapper, and other
  forbidden component coercions;
* non-exact untyped C-vararg rejection and malformed/recursive plan failures.

### Checker tests (new topical `spec/checker/closure_adjustment_wrappers_spec.lua`)

* exact edge has no cast; non-exact finite edge has one target-typed
  `Ast.ExpCast`, child type `A`, the same raw plan object, frozen plan, source
  location, and no `_assignment_adjustment`;
* declaration, reassignment, return, positional/named argument, module/field,
  and representative container sinks;
* one relation query per edge; contextual exact lambda versus explicitly typed
  non-exact lambda;
* written `as` annotation and allocation-free `is`;
* dynamic `value` projection remains unwrapped;
* open result/`...`/constructor plans retain one shared run-level authority;
* Interface exact/adapter slots, including missing nil result.

### Coder/runtime tests (new topical `spec/coder/closure_adjustment_wrappers_spec.lua`)

* exact assignment allocates nothing; adjusted wrapper has target tag/fast call;
* wrapper differs from source and two evaluations differ;
* top-level/local/imported function, captured/mutated lambda, bound record and
  Interface methods, GC stress, and stack relocation;
* wrapper chains and wrapper -> `value` -> another Function view;
* genuine Lua closure/C function/`__call`/deferred non-callable and max-upvalue
  fallbacks;
* every fixed/ignored/nil-filled/input-tail/flexible-output action, finite/open
  demand, 200 cap, first-return versus out-parameter nil fill, nested callable
  arguments/results, and exactly-once side effects;
* strict `value`-hole failures, catch/finally/defer behavior, cast-site `#line`,
  traceback trace name, and no generated-path leakage;
* Lua calls preserve source `A` behavior while exact/non-exact Titan calls use
  the target wrapper protocol;
* malformed/missing/wrong frozen endpoints/actions/root/rebase annotations fail
  closed in coder integrity tests.

Extend the owning provider suites rather than duplicate scaffolding:
`so_import_spec.lua`, checker/coder static-provider specs, and
`multi_module_libraries_spec.lua`. Run all Interface suites after refactoring the
shared adapter engine.

### Standard-library behavior

After compiler tests pass, audit `async.run`/`uv.run_internal` callers whose
callbacks semantically return no value. Remove only workaround annotations and
`return nil` statements that exist solely to force an exact `() -> value` call;
make the zero-result function type explicit where contextual inference would
otherwise infer the expected result. Keep public callback signatures unchanged.
Exercise the public result through the owning native async/uv Titan tests, not a
LuaCov Busted library wrapper.

## Documentation

This is user-visible and must update both manuals in the same change.

Add and link:

* `doc/language/closure-adjustment-wrappers.md`: directional shape/actions,
  missing nil result, fresh/conditional identity, Lua and fallback behavior,
  `as`/`is`, examples, limits and non-goals;
* `doc/implementation/closure-adjustment-wrappers.md`: checker/frozen-plan
  contract, runtime predicate and layout, native/strict entries, roots/rebases,
  tails/flex, trace attribution, trust model, ABI rationale.

Audit existing statements with:

```sh
rg 'non-exact|callable adjustment|canonical value|companion adapter|strict generic' doc
```

At minimum update language `functions.md`, `closures.md`, `types.md`, flexible
returns/variadics/Lua interop/Interfaces as applicable, and implementation type
relations, checker, codegen overview, Lua interop internals, values/GC,
flexible-results/variadics/Interfaces. Link the new chapters from both indexes.

## Implementation order and ownership

1. **Coordinator:** commit this replacement plan after independent checker,
   coder, tests/docs, and adversarial plan review.
2. **Relation/checker owner:** add `nil_fill_result`, refactor/freeze the shared
   action graph, insert finite casts, and add pure/checker tests. Run Interface
   tests before handing off.
3. **Coder owner:** generalize adapter validation/emission without changing
   Interface behavior, implement wrapper construction/native adapter/strict
   relay, then fixed, tail/flex, nested, GC, and integrity tests. Only one owner
   edits the shared Interface engine at a time.
4. **Tests/docs owner:** after semantics stabilize, add provider cases and both
   manuals; do not parallel-edit compiler files.
5. **Coordinator:** audit and simplify only justified Task callback workarounds,
   run local validation, review the complete diff, then push/open the PR and
   monitor required Linux CI.

Each owner must stop near 90% context, write a durable handoff, explicitly invoke
compaction, and resume rather than relying on automatic compaction.

## Local validation

Use one isolated absolute prefix and clear ambient policy/module paths:

```sh
export PREFIX="/tmp/titan-$USER-callable-adjustment"
export PATH="$PREFIX/bin:$PATH"
unset ROCKS_TREE TITAN_ROCKS_ROOT TITAN_EXTRA_CPPFLAGS \
      TITAN_NO_LINE_DIRECTIVES LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5
make lua
make luarocks

$PREFIX/bin/luac -p titan-compiler/types.lua \
    titan-compiler/checker.lua titan-compiler/coder.lua
$PREFIX/bin/luarocks make titan-dev-1.rockspec
busted spec/types_spec.lua
busted spec/checker/closure_adjustment_wrappers_spec.lua
busted spec/coder/closure_adjustment_wrappers_spec.lua
busted spec/checker/interfaces_spec.lua spec/coder/interfaces_spec.lua
busted spec/coder/type_relations_soundness_spec.lua
busted spec/coder/so_import_spec.lua \
    spec/coder/static_compiled_modules_spec.lua \
    spec/coder/multi_module_libraries_spec.lua
bash spec/support/ci_test_groups.sh compiler
make stdlib-test
make test
```

Re-run `luarocks make` after every compiler-source edit because the installed rock
shadows the working tree. Library/runtime tests remain outside LuaCov. Do not run
the waived manual macOS dispatch.

## Definition of done

* Original draft is preserved in git and this plan is committed separately.
* Raw/frozen plans, finite/open/nested/Interface paths, wrapper protocol, fresh
  identity, missing nil results, Lua/fallback behavior, and upvalue ceiling are
  implemented and covered.
* Both manuals and indexes are current; justified Task workarounds are removed.
* Touched Lua chunks parse, targeted suites and complete local tests pass in the
  isolated prefix, and the final diff receives independent review.
* Branch is pushed, PR is open, and all required push-triggered Linux checks are
  green (manual macOS waived).
