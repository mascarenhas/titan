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
* minimal fixed/open GC-root inventories: native input-source inventories are
  empty, newly allocated destinations receive immediate roots, and every live
  GC-bearing fixed/open native source result is rooted immediately after return;
* only genuine stack-rebase points—operations that can move the Lua stack and
  the source native call; nested wrapper allocation is raising but
  non-relocating;
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
has Titan's private CClosure layout. The operand is evaluated exactly once into
a C value while its existing allocation/home root remains live. The guarded
realization checks exactly:

* the carrier is a non-null `CClosure`;
* `5 <= nupvalues < MAXUPVAL`;
* upvalue 1 is lightuserdata equal to the exact source-`A` function tag; and
* upvalue 3 is lightuserdata equal to `TITAN_FUNCTION_CLOSURE_BRAND`.

Once the exact tag and brand establish the private Titan carrier, generated code
trusts the remaining branded layout. Construction deliberately does not probe
upvalue 0's module shape, upvalue 2's native-pointer shape, or the final strict
trailer. Debug-library or C-API mutation of private upvalues opts out. The
implementation adds no registry hardening, adversarial-AST defenses, or extra
shape probes beyond this supported boundary.

A Lua closure, light C function, foreign/unbranded C closure, `__call` object,
deferred non-callable value, differently tagged Titan closure, or closure with
`n == MAXUPVAL` is returned unchanged. Any failed count/tag/brand guard takes
this same fallback. It keeps the existing branded or non-Titan generic call
behavior and its identity. Titan's source capture limit is not reduced merely
to reserve the optimization's extra slot.

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

Construction allocates the final object directly with
`luaF_newCclosure(L, n + 1)`. While that closure is fresh-white, generated code:

1. copies `source->f`;
2. copies source upvalues `0 .. n-2` with `setobj2n`, substituting the target tag
   and target adapter in slots 1 and 2 with `setpvalue`;
3. installs the immediate source link at `n-1` with `setclCvalue`;
4. installs the target strict relay at `n` with `setfvalue`; and
5. publishes the finished closure directly into the assigned traced result slot
   with `setclCvalue`.

There is no transient Lua-stack assembly, `lua_pushcclosure`, construction
barrier, local `luaC_checkGC`, construction-only source root, or construction
rebase. The source's ordinary traced provenance remains live; fallback is only
a C copy of that carrier. A successfully allocated wrapper is a new object and
receives its own root immediately.

Lua 5.5's collector does not move heap objects. A Lua stack reallocation can
relocate stack slots and invalidate `StkId`/`TValue *` pointers, but it preserves
values in existing traced homes and leaves their heap addresses unchanged.
`luaF_newCclosure` may allocate or raise, including after an emergency
collection, but it does not perform an ordinary GC poll; an emergency cycle does
not shrink the stack. Direct construction therefore does not relocate the
stack. Nested callable conversion has the same allocation/raising behavior and
is not a rebase point, although its fresh destination root is
allocation-sensitive.

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
2. reserve and nil-initialize only the scratch selected by the frozen root
   inventory, saving stack positions as offsets where a real rebase is needed;
3. keep fixed/static `B` arguments and forwarded open values in C, borrowing
   their existing allocation/result/semantic/VM provenance without input roots;
4. realize contravariant argument actions into A's fixed and tail storage,
   immediately rooting each newly allocated nested wrapper;
5. recover the penultimate source closure, then obtain its authoritative module
   and exact native pointer and call `function_sig(A)` with `_fn = source`;
6. rebase after that native call, then root every live GC-bearing fixed/open A
   source result immediately, including identity results;
7. realize covariant result actions into B, immediately rooting each newly
   allocated destination and applying `nil_fill_result`;
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
projection precedes absence fill. Raw `TitanVargX` descriptors and C arrays are
never roots. Every live GC-bearing source result run receives an immediate
parallel traced range; a destination range is reserved only for newly allocated
converted values. Borrowed native inputs and allocation-free destination copies
use none.

## Source Lua entry and target strict relay

A wrapper does not get a target coercive Lua entry. `CClosure.f` is copied from
the immediate source value, so genuine Lua preserves whatever Lua surface that
value already carries—ultimately the original source declaration's statically
baked arity, source-directed dynamic parameter conversions, and result
behavior. In a wrapper chain this inherited entry need not match the immediate
edge's static source tag. It also passes the wrapper as `_fn`; copied
capture/bound-receiver slots and layered source links preserve the source
body's expectations.

The source declaration's strict trailer cannot simply be copied. Providers from
ABI 0.22 through 0.25 compile a declaration-specific source-tag check, which
would reject a consumer-created target-tagged wrapper. Instead the creating translation unit
emits a strict relay for B using the existing strict-entry arity/tail/result and
error shell plus checker-frozen strict boundary plans.

The relay validates the wrapper's target tag, target adapter pointer/header
shape, fixed brand (already selected by `codevaluecall`), and its own final
trailer. Deliberately, it does not require one declaration-specific
`CClosure.f`: that field must remain the source Lua entry. Upvalue 0 likewise
remains the source module, so before checking target nominal, Array, or owned-C
values the relay recovers the creating consumer's already initialized
per-state module through its ordinary idempotent init entry. It then invokes
the B native adapter with the wrapper as `_fn`. Thus a later non-exact branded
call uses the target B protocol and delegates layer by layer, without relaxing
every ordinary declaration strict entry or depending on which provider built
A.

## Roots, relocation, and errors

Wrapper allocation is emitted in expression `stats`, never duplicated in a C
expression template. Operand and call evaluation remain left-to-right and
exactly once.

An adapter whose frozen argument/result graph can allocate a nested callable
view begins with `luaC_checkGC(L)`. The poll occurs before stack reservation,
`_base`, or any raw stack pointer. It provides collector progress across repeated
adapter calls without inserting a poll between `luaF_newCclosure` and immediate
publication; callers already treat the later source-native call as the genuine
relocation point.

The frozen plan owns a minimal lifetime inventory. A native fast call keeps its
callee, fixed/static arguments, and forwarded open values in C; lexical freezes
are untraced, and the adapter input-source inventories are empty. Inputs borrow
their existing allocation/result/semantic/VM provenance. Callee parameter homes
remain separate and are needed only when a parameter is assigned or must be
spilled across a catchable call. Genuine Lua and branded-strict slow paths still
push the callee/carrier and actual arguments because Lua-stack transport is their
calling convention.

After a native source call and rebase, every live GC-bearing fixed result and
flexible source prefix is rooted immediately, even when its result action is
identity and cannot allocate. A nested callable conversion can allocate and
raise but cannot relocate the stack; every successfully created wrapper is
published immediately into its own fixed slot or parallel traced destination
range. The same allocation-root rule applies when a general open conversion
creates an Interface value. Raw descriptors, C arrays, and native C locals are
never roots, and borrowed or allocation-free *input/destination* runs do not
acquire parallel traced copies.

Stack offsets and rebases protect only raw stack positions. Operations that can
actually grow/shrink the Lua stack and every native call are rebase points;
direct `luaF_newCclosure` construction and nested wrapper construction are not.
Heap references remain stable because Lua's GC is non-moving.

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

The wrapper uses the closure header, function tags, native signatures, and
strict stack shell retained through ABI 0.25. It adds no serialized descriptor
field,
provider symbol, module-state slot, or fixed header position. Its target adapter
and strict relay are consumer-private translation-unit artifacts. A new
consumer can therefore adjust source-linked, DSO, or archive functions from an
ordinary same-ABI provider without requiring that provider to export a target
adapter.

Consequently this feature does **not** bump the ABI. If implementation ever
requires a new fixed slot, changed native signature, or serialized/provider
contract, that is an ABI change and must not be hidden under 0.25.

See [Type relations and boundary plans](type-relations-and-boundaries.md),
[The type checker](checker.md), [Code generator: overview](codegen-overview.md),
[Lua interop internals](lua-interop-internals.md),
[Flexible returns](flexible-returns.md), [Variadic parameters](variadic-parameters.md),
[Interfaces](interfaces.md), and [Values and the GC](values-and-gc.md) for the
surrounding machinery.
