# Closure adjustment wrappers

A first-class Titan call can use the native fast path only when the closure's
run-time function tag equals the call site's static `Type.Function`. A
non-exact directional callable adjustment therefore cannot become fast merely
by retaining the source value under a new static type. The compiler makes that
edge explicit and, when the run-time value proves to be the expected Titan
source closure, constructs a fresh target-tagged wrapper with a synthetic native
adapter.

This chapter specifies that lowering. The raw checker-produced `CallablePlan`
is the sole semantic authority. Wrapper code consumes a closed frozen action
graph; neither the coder nor generated C rediscovers consistency, coercion, or
Interface satisfaction from endpoint types.

## Relation contract: `nil_fill_result`

`types.callable_adjustment(A, B)` remains directional, with `A` the
actual/source function type and `B` the expected/target function type. Its
ordered result actions include `nil_fill_result` when all of the following
hold:

1. `B` demands a fixed result position;
2. `A` has neither a fixed result at that position nor a flexible-result source
   that can project it; and
3. the expected result passes the same `accepts_missing_nil` predicate already
   used for an absent fixed argument.

That policy admits Nil, Value, Option, Titan Pointer, and CPointer targets. It
rejects required booleans, numbers, strings, nominal records/unions/Interfaces,
and any target that would need an ordinary coercion. The action records the
expected index and normalized target type but has no source adjustment. It is
non-exact. A source-flex projection takes precedence when available.

`nil_fill_result` is a callable shape action, not an invented `Nil -> T`
component adjustment. It must appear in raw-plan validation, freezing, coder
validation, Interface method matching, and every fixed/open demand truth table,
but it must not change `consistent`, `coercion`, or create a transitive path.
Aligned callable components remain limited to identity, nested callable
adjustment, and the existing strict gradual inject/project/structural
operations. Numeric, ordinary Option, C, Interface-wrapper, and other scalar
coercions still do not lift through Function.

## Checker elaboration

### Finite sinks use `Ast.ExpCast`

For an ordinary finite sink, `types.assignment_adjustment(source, target)` is
queried once. Exact Function pairs retain the original expression. A non-exact
callable result is represented with the existing cast node:

```lua
local cast = ast.ExpCast(source.loc, source, target)
cast._implicit_coercion = true
cast._adjustment = adjustment       -- the original CallablePlan authority
cast._type = target
```

The child retains source type `A`; the cast has target type `B`. The callable
plan is not also stored as `_assignment_adjustment`. Accordingly,
`checkmatch`'s same-representation exception remains for Array/Map structural
views but not for a callable edge: wrapper allocation is a real expression
effect even though source and target use the same boxed `TValue` carrier.

This one path covers finite declarations, reassignments, fixed and named
arguments, returns, module/record/union/container slots, generic-for scalar
slots, and other ordinary target-typed sinks. `checkmatch` consumes the exact
object returned by `trycoerce`; there is no second relation query.

A written non-exact `f as B` is already `Ast.ExpCast`. Its
`_written_cast.op == "callable"` record contains the raw callable plan and uses
the same freezer/lowering. `f is B` validates the same written relation but is
allocation-free: it evaluates the operand once and emits the nonraising
admission result without registering or constructing a wrapper. A dynamic
`value -> Function` plan has no statically known source Function endpoint and
remains an unchanged boxed carrier on generic dispatch.

Runtime-open result/`...`/positional-constructor runs have no separate AST node
per element. They retain the existing shared run-level adjustment. The checker
freezes and attaches the shared callable-adapter graph at the owning source
location; `coder._code_adjustment_value` validates and registers that already
frozen graph when it reaches an element.

### One frozen `CallableAdapterPlan`

The checker generalizes the existing Interface callable-adapter freezer. A
frozen plan is relation-free data containing at least:

* normalized source `A` and target `B`, exactness, and dense ordered argument
  and result actions;
* recursively frozen component operations, including nested callable views and
  `nil_fill_result`;
* fixed and open GC-root inventories for argument and result sources and
  destinations;
* every stack-rebase point, including nested wrapper construction and the
  source native call;
* target flexible-result demand formulas and the `TITAN_VARARG_MAX == 200`
  bound;
* the real cast/owning-expression location and stable trace name; and
* `relation_free = true`, with nested Interface conversion forbidden.

The finite cast keeps the raw `_adjustment` object as authority in addition to
its frozen lowering annotation. Open runs keep their shared raw authority.
Interface exact-versus-adapter selection is unchanged, but non-exact method
mappings consume this same action representation and engine rather than a
second callable relation.

The coder validates endpoints, exactness, dense action ordering, recursive
operations, root ranges, rebase annotations, demand math, and the relation-free
marker before emission. Missing, unknown, unavailable, or endpoint-mismatched
records are compiler-integrity errors. Representation emitters run only after
that validation.

## Adapter-site discovery

Each frozen non-exact plan used by a translation unit receives one deterministic
private site entry, keyed by the plan object rather than globally interned type
strings. Sites are registered in checked-AST discovery order, like lambdas.
Emission drains the list dynamically because registering or emitting one
already recursively frozen adapter can discover nested callable component
sites.

The site owns:

* a target-native adapter with exactly `function_sig(B)`;
* a consumer-local strict Lua-stack relay for `B`; and
* the wrapper-construction metadata/helper call that installs those entries.

A recursive `callable_view` component invokes the same conditional construction
helper. It must not preserve a mismatched tag silently.

## Runtime eligibility and fallback

A static Function carrier is a boxed `TValue`, not proof that its run-time value
has Titan's private CClosure layout. Wrapper construction therefore begins only
after evaluating and anchoring the operand exactly once, then uses the existing
trusted Titan-closure predicate. Realization requires:

* a C closure with Titan's fixed private header/trailer shape and brand;
* exact source-`A` function-tag identity; and
* an upvalue count strictly below Lua's `MAXUPVAL` ceiling.

Once that predicate succeeds, generated code may trust the private slots under
the same supported boundary as exact function dispatch. Debug-library or C-API
mutation of those slots opts out. The implementation must not add registry
hardening, adversarial-AST defenses, or shape probes for arbitrary Lua values
beyond this actual boundary.

A Lua closure, light C function, foreign C closure, `__call` object, deferred
non-callable value, differently tagged Titan closure, or closure with
`n == MAXUPVAL` is returned unchanged. It keeps the existing branded or
non-Titan generic call behavior and its identity. Titan's source capture limit
is not reduced merely to reserve the optimization's extra slot.

## Wrapper layout

Let the immediate source CClosure have `n` upvalues. The wrapper has `n + 1`:

```text
0                       source module Udata (copied)
1                       exact target-B function tag (replaced)
2                       target-B native adapter pointer (replaced)
3                       Titan function brand (copied)
4 .. n-2                source captures/bound receiver/older wrapper links (copied)
n-1                     immediate source closure TValue (new traced link)
n                       target-B consumer-local strict relay (new trailer)
CClosure.f              source coercive Lua entry (copied)
```

The immediate source closure link is essential. The adapter reads that
closure's module and native-entry slots and passes the same closure as `A`'s
`_fn`. For an `A -> B -> C` chain, the C adapter therefore calls the immediate B
wrapper; B in turn delegates to A. Each layer keeps its own private links and
capture indexing instead of treating a later wrapper as if it had A's trailer
position.

Construction uses stack-based `lua_pushcclosure` rather than writing a closure
array manually:

1. materialize and anchor the source before any stack growth or allocation;
2. save stack positions as offsets and ensure capacity;
3. push source upvalues `0 .. n-2`, substituting target tag and adapter in slots
   1 and 2;
4. push the source closure itself and the generated target strict relay;
5. call `lua_pushcclosure` with `source->f`;
6. anchor the new wrapper immediately, discard scratch, and restore `_base`
   from `_base_off`.

Construction and every nested callable conversion are relocating operations.
The new white CClosure traces all copied/new upvalues once constructed; no
manual forward/back barrier and no untraced side object is required for its
source link.

Every realized wrapper is fresh. It is not equal to its source or to a wrapper
from another evaluation. Chains allocate once per realized non-exact edge.
There is no registry cache, interning, flattening, or equality unwrapping.

## Target-native adapter

The private `static TITAN_NOINLINE` adapter has exactly `function_sig(B)`. It is
a parameterization of the proven Interface adapter engine with a different
invocation backend: Interface adapters call a known concrete method with
`self`, while a closure adapter calls its captured immediate source closure.

Its order is fixed:

1. validate target input and flexible-output descriptor bounds;
2. reserve and nil-initialize the complete traced scratch frame, save
   `_base_off`, and establish its rebase ledger;
3. anchor every incoming GC-bearing fixed/open `B` argument before an action
   may allocate;
4. realize contravariant argument actions into A's fixed and tail storage;
5. recover the penultimate source closure, then obtain its authoritative module
   and exact native pointer and call `function_sig(A)` with `_fn = source`;
6. immediately anchor every GC-bearing fixed/flexible A result before a nested
   conversion can allocate;
7. realize covariant result actions into B, including `nil_fill_result`;
8. publish B's caller-owned flexible output under `_flexwant`, `LUA_MULTRET`,
   and the 200-element cap; and
9. restore the root frame, write secondary out-parameters, and return B's first
   fixed result or `void`.

For `nil_fill_result`, the first B result is initialized to its nil
representation when it is the C return value; later fixed results are
nil-initialized through their out-parameters. The action never reads an A
result or performs a component coercion.

The adapter retains the Interface engine's demand formulas: finite consumers
request only the required source prefix/tail capacity; an open target demand is
bounded; hidden source results are not converted; and source flexible
projection precedes absence fill. All raw `TitanVargX` buffers remain untraced,
with parallel Lua roots for GC-bearing live elements.

## Source Lua entry and target strict relay

A wrapper does not get a target coercive Lua entry. `CClosure.f` is copied from
the immediate source value, so genuine Lua preserves whatever Lua surface that
value already carries—ultimately the original source declaration's statically
baked arity, source-directed dynamic parameter conversions, and result
behavior. In a wrapper chain this inherited entry need not match the immediate
edge's static source tag. It also passes the wrapper as `_fn`; copied
capture/bound-receiver slots and layered source links preserve the source
body's expectations.

The source declaration's strict trailer cannot simply be copied. ABI-0.22
providers compile a declaration-specific source-tag check, which would reject a
consumer-created target-tagged wrapper. Instead the creating translation unit
emits a strict relay for B using the existing strict-entry arity/tail/result and
error shell plus checker-frozen strict boundary plans.

The relay validates the wrapper's target tag, target adapter pointer/header
shape, fixed brand (already selected by `codevaluecall`), and its own final
trailer. Deliberately, it does not require one declaration-specific
`CClosure.f`: that field must remain the source Lua entry. It then invokes the
B native adapter with the wrapper as `_fn`. Thus a later non-exact branded call
uses the target B protocol and delegates layer by layer, without relaxing every
ordinary declaration strict entry or depending on which provider built A.

## Roots, relocation, and errors

Wrapper allocation is emitted in expression `stats`, never duplicated in a C
expression template. Operand and call evaluation remain left-to-right and
exactly once.

The frozen plan owns all lifetime facts. Incoming and produced GC-bearing fixed
values have reserved stack anchors; each open descriptor has a parallel traced
range; the immediate source and new wrapper are anchored across construction;
and source results are published before an allocating conversion. Raw
descriptors, C arrays, and native locals are never treated as roots. Every
stack pointer live across stack growth, wrapper construction, nested callable
conversion, or the source native call is represented as an offset and restored
before use.

Synthetic adapter line directives and component-conversion diagnostics use the
real cast node's filename, line, and column. An open-run site uses the owning
consumer expression. `--no-line-directives` suppresses those directives as it
does elsewhere. Tracebacks use a stable source-facing name such as:

```text
[callable adapter A -> B at file:line:col]
```

Generated C paths are not exposed. Catch/longjmp spills, pending `finally`
actions, and the generic fallback's finite Lua-VM result limit retain their
existing rules.

## ABI and ownership rationale

The wrapper uses the ABI-0.22 closure header, function tags, native signatures,
and strict stack shell already present. It adds no serialized descriptor field,
provider symbol, module-state slot, or fixed header position. Its target adapter
and strict relay are consumer-private translation-unit artifacts. A new
consumer can therefore adjust source-linked, DSO, or archive functions from an
ordinary ABI-0.22 provider without requiring that provider to export a target
adapter.

Consequently this feature does **not** bump the ABI. If implementation ever
requires a new fixed slot, changed native signature, or serialized/provider
contract, that is an ABI change and must not be hidden under 0.22.

See [Type relations and boundary plans](type-relations-and-boundaries.md),
[The type checker](checker.md), [Code generator: overview](codegen-overview.md),
[Lua interop internals](lua-interop-internals.md),
[Flexible returns](flexible-returns.md), [Variadic parameters](variadic-parameters.md),
[Interfaces](interfaces.md), and [Values and the GC](values-and-gc.md) for the
surrounding machinery.
