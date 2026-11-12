# Closure adjustment wrappers

A first-class Titan call can use the native fast path only when the closure's
run-time function tag equals the call site's static `Type.Function`
([calling function values](codegen-overview.md#calling-function-values-codevaluecall)).
A non-exact directional callable adjustment therefore cannot become fast merely
by keeping the source value under a new static type. The compiler makes that
edge explicit and, when the run-time value proves to be the expected Titan
source closure, constructs a fresh target-tagged wrapper with a synthetic native
adapter.

This chapter is the canonical home for that lowering: wrapper eligibility,
layout, construction, the adapter and strict relay, and their rooting rules.
The raw checker-produced callable plan (the `callable(CallablePlan)` relation in
[type relations](type-relations-and-boundaries.md)) is the sole semantic
authority. Wrapper code consumes a closed frozen action graph; neither the coder
nor generated C rediscovers consistency, coercion, or Interface satisfaction
from endpoint types.

## Relation contract: `nil_fill_result`

`types.callable_adjustment(A, B)` is directional, with `A` the actual/source
function type and `B` the expected/target function type. Its ordered result
actions include `nil_fill_result` when all of the following hold:

1. `B` demands a fixed result position;
2. `A` has neither a fixed result at that position nor a flexible-result source
   that can project it; and
3. the expected result passes the same `accepts_missing_nil` predicate used for
   an absent fixed argument.

That policy admits Nil, Value, Option, and CPointer targets. It rejects
required booleans, numbers, strings, nominal records/unions/Interfaces, and any
target that would need an ordinary coercion. The action records the expected
index and normalized target type but has no source adjustment, and it is
non-exact. A source-flex projection takes precedence when available.

`nil_fill_result` is a callable shape action, not a `Nil -> T` component
adjustment. It must appear in raw-plan validation, freezing, coder validation,
Interface method matching, and every fixed/open demand truth table, but it must
not change `consistent` or `coercion` or create a transitive path. Aligned
callable components are limited to identity, nested callable adjustment, and
the strict gradual inject/project/structural operations. Numeric, ordinary
Option, C, Interface-wrapper, and other scalar coercions do not lift through
Function.

## Checker elaboration

### Finite sinks use `Ast.ExpCast`

For an ordinary finite sink, `types.assignment_adjustment(source, target)` is
queried once. Exact Function pairs keep the original expression. A non-exact
callable result is represented with the cast node:

```lua
local cast = ast.ExpCast(source.loc, source, target)
cast._implicit_coercion = true
cast._adjustment = adjustment       -- the raw callable plan (authority)
cast._type = target
```

The child keeps source type `A`; the cast has target type `B`. The callable plan
is not also stored as `_assignment_adjustment`. Accordingly, `checkmatch`'s
same-representation exception applies to Array/Map structural views but not to
a callable edge: wrapper allocation is a real expression effect even though
source and target share the boxed `TValue` carrier.

This one path covers finite declarations, reassignments, fixed and named
arguments, returns, module/record/union/container slots, generic-for scalar
slots, and other ordinary target-typed sinks. `checkmatch` consumes the exact
object returned by `trycoerce`; there is no second relation query.

A written non-exact `f as B` is already `Ast.ExpCast`. Its
`_written_cast.op == "callable"` record holds the raw plan and uses the same
freezer and lowering. `f is B` validates the same written relation but is
allocation-free: it evaluates the operand once and emits the nonraising
admission result without registering or constructing a wrapper. A dynamic
`value -> Function` plan has no statically known source Function endpoint and
stays an unchanged boxed carrier on generic dispatch.

Runtime-open result, `...`, and positional-constructor runs have no AST node per
element and keep their shared run-level adjustment. The checker freezes and
attaches the shared adapter graph at the owning source location;
`coder._code_adjustment_value` (`titan-compiler/coder/calls.lua`) validates and
registers that frozen graph when it reaches an element.

### One frozen callable-adapter plan

`freeze_callable_adapter_plan` (`titan-compiler/checker/interfaces.lua`,
exported as `checker.freeze_callable_adapter`) is shared with Interface method
adapters. It produces a relation-free record with
`kind = "callable_adapter_plan"` containing:

* normalized source `A` and target `B`, exactness, and dense ordered argument
  and result actions;
* recursively frozen component operations, including nested callable views and
  `nil_fill_result`;
* minimal fixed/open GC-root inventories: native input-source inventories are
  empty, newly allocated destinations receive immediate roots, and every live
  GC-bearing fixed/open native source result is rooted immediately after return;
* `rebase_points`: only operations that can move the Lua stack and the source
  native call (nested wrapper allocation raises but does not relocate);
* target flexible-result demand formulas and the `TITAN_VARARG_MAX` (200) bound;
* the real cast or owning-expression location and the stable trace name;
* `relation_free = true`, with nested Interface conversion forbidden; and
* the frozen strict-relay plan (`kind = "callable_strict_relay"`).

A finite cast keeps the raw `_adjustment` as authority alongside its frozen
lowering annotation; open runs keep their shared raw authority. Interface
exact-versus-adapter selection is unchanged, but non-exact method mappings use
this same action representation and engine.

`coder._validate_callable_adapter_plan` and
`coder._validate_callable_strict_relay` (`titan-compiler/coder/interfaces.lua`)
check endpoints, exactness, dense action ordering, recursive operations, root
ranges, rebase annotations, demand math, and the relation-free marker before
emission. Missing, unknown, or endpoint-mismatched records are
compiler-integrity errors.

## Adapter-site discovery

`coder._callable_adapter_site` (`titan-compiler/coder/calls.lua`) gives each
frozen non-exact plan used by a generated module one deterministic private site,
keyed by the plan object rather than by interned type strings, in checked-AST
discovery order. Emission drains the site list dynamically, because emitting
one recursively frozen adapter can discover nested component sites.

The site owns:

* a target-native adapter whose signature is `coder._callable_adapter_signature`
  for `B`;
* a consumer-local strict Lua-stack relay for `B`; and
* the wrapper-construction call that installs those entries.

`coder._emit_callable_adapter` (`titan-compiler/coder/declarations.lua`) emits
the adapter and relay. A recursive `callable_view` component uses the same
conditional construction; it must never silently preserve a mismatched tag.

## Runtime eligibility and fallback

A static Function carrier is a boxed `TValue`, not proof that its run-time value
has Titan's private CClosure layout. `coder._emit_callable_adapter_value`
(`coder/calls.lua`) evaluates the operand exactly once into a C value while its
existing home root stays live, and constructs a wrapper only when:

* the carrier is a `CClosure`;
* `5 <= nupvalues < MAXUPVAL`;
* upvalue 1 is lightuserdata equal to the exact source-`A` function tag; and
* upvalue 3 is lightuserdata equal to `TITAN_BRAND`.

Once the exact tag and brand establish the private Titan carrier, generated code
trusts the rest of the branded layout; it does not probe upvalue 0's module,
upvalue 2's native pointer, or the strict trailer. Debug-library or C-API
mutation of private upvalues opts out of the guarantee, and no further
hardening is added.

A Lua closure, light C function, foreign or unbranded C closure, `__call`
object, deferred non-callable value, differently tagged Titan closure, or
closure with `MAXUPVAL` upvalues is returned unchanged. That fallback keeps the
existing branded or non-Titan generic call behavior and identity. Titan's
source capture limit is not reduced to reserve the wrapper's extra slot.

## Wrapper layout

Let the immediate source CClosure have `n` upvalues. The wrapper has `n + 1`:

```text
0                       adapter module Udata (the module creating the wrapper/cast)
1                       exact target-B function tag (replaced)
2                       target-B native adapter pointer (replaced)
3                       Titan function brand (copied)
4 .. n-2                source captures/bound receiver/older wrapper links (copied)
n-1                     immediate source closure TValue (new traced link)
n                       target-B consumer-local strict relay (new trailer)
CClosure.f              source coercive Lua entry (copied)
```

The immediate source link is essential. The adapter reads that closure's module
(`uvalue(&source->upvalue[0])`) and native-entry slots and passes the same
closure as `A`'s `_fn`. For an `A -> B -> C` chain, the C adapter calls the
immediate B wrapper, which in turn delegates to A. Each layer keeps its own
private links and capture indexing.

Construction allocates the final object directly with
`luaF_newCclosure(L, n + 1)`. While that closure is fresh-white, generated code:

1. copies `source->f`;
2. sets slot 0 to `_mod` (the module creating the adapter) with `setuvalue`;
3. copies source upvalues `3 .. n-2` with `setobj2n`, writing the target tag and
   target adapter into slots 1 and 2 with `setpvalue`;
4. installs the immediate source link at `n-1` with `setclCvalue`;
5. installs the target strict relay at `n` with `setfvalue`; and
6. publishes the finished closure into its assigned traced result slot with
   `setclCvalue`.

There is no transient Lua-stack assembly, `lua_pushcclosure`, construction
barrier (the object is fresh-white), local `luaC_checkGC`, construction-only
source root, or construction rebase. The source's traced provenance stays live;
fallback is only a C copy of that carrier. A successfully allocated wrapper is a
new object and receives its own root immediately.

`luaF_newCclosure` may allocate or raise, including after an emergency
collection, but it does not perform an ordinary GC step, and an emergency cycle
does not shrink the stack. Direct construction, and nested callable conversion,
therefore raise but never relocate the stack.

Every realized wrapper is fresh. It is not equal to its source or to a wrapper
from another evaluation. Chains allocate once per realized non-exact edge;
there is no cache, interning, flattening, or equality unwrapping.

## Target-native adapter

The private `static TITAN_NOINLINE` adapter has exactly `B`'s native signature.
It is the Interface adapter engine with a different invocation backend:
Interface adapters call a known concrete method with `self`, while a closure
adapter calls its captured immediate source closure. At entry, `_mod` is the
module that compiled the cast and adapter (from `wrapper->upvalue[0]`), so all
Array, nominal, and owned-C metatables resolve from `_mod->uv[slot]` without a
registry query.

Its order is fixed:

1. validate target input and flexible-output descriptor bounds;
2. reserve and nil-initialize only the scratch selected by the frozen root
   inventory, saving stack positions as offsets where a real rebase is needed;
3. keep fixed `B` arguments and forwarded open values in C: the wrapper's
   caller keeps them reachable, so they get no input roots;
4. realize contravariant argument actions into A's fixed and tail storage,
   immediately rooting each newly allocated nested wrapper;
5. recover the source closure from slot `n-1`, read its authoritative module
   (`uvalue(&source->upvalue[0])`) and exact native pointer, and call A's
   native entry with `L, source_mod, source, ...`;
6. rebase after that call, then root every live GC-bearing fixed/open A result
   immediately, including identity results;
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

The adapter keeps the Interface engine's demand formulas: finite consumers
request only the required source prefix/tail capacity, an open target demand is
bounded, hidden source results are not converted, and source flexible projection
precedes absence fill.

## Source Lua entry and target strict relay

A wrapper gets no target coercive Lua entry. `CClosure.f` is copied from the
immediate source value, so genuine Lua sees whatever surface that value already
had: ultimately the original declaration's baked arity, source-directed dynamic
parameter conversions, and result behavior. In a wrapper chain this inherited
entry need not match the immediate edge's static source tag. Before recovering
`_mod`, the genuine Lua entry (`genluaentry`, see
[Lua interop internals](lua-interop-internals.md#the-two-lua-stack-entries-genluaentry))
follows adapter source links and passes the original source closure as `_fn`.
It recognizes a view by its changed native entry and guarded source trailer;
each link must preserve `CClosure.f` and reduce the upvalue count by exactly
one, so ordinary captures and bound receivers never look like adapter links.
Source captures, module variables, and per-state native caches therefore stay
owned by the source provider even when another module created the view.

The source declaration's strict trailer cannot be copied: providers compile a
declaration-specific source-tag check, which would reject a target-tagged
wrapper. The creating module instead emits a strict relay for B from
the shared strict-entry arity/tail/result and error shell plus the
checker-frozen strict boundary plans.

The relay validates the wrapper's target tag, target adapter pointer and header
shape, brand (already selected by `codevaluecall`), and its own trailer. It
deliberately does not require one declaration-specific `CClosure.f`, because
that field must remain the source Lua entry. It recovers
`Udata *_mod = uvalue(&_fn->upvalue[0])` and invokes the B native adapter with
the wrapper as `_fn`. A later non-exact branded call thus uses the target B
protocol and delegates layer by layer, without relaxing any declaration's
strict entry or depending on which provider built A.

## Roots, relocation, and errors

The general native-call rooting protocol (inputs rooted by the caller,
immediate result roots, rebase after native calls, non-moving heap) is
canonical in
[Values and the GC](values-and-gc.md#calls-c-only-inputs-immediate-result-roots-and-vm-transport).
An adapter, strict relay or bound-method trampoline roots none of its inputs:
they are its own parameters, which its caller keeps reachable, or immutable
upvalues of its `_fn`. Wrapper-specific rules:

* Wrapper allocation is emitted in expression `stats`, never duplicated in a C
  expression template. Operand and call evaluation stay left-to-right and
  exactly once.
* An adapter whose frozen graph can allocate a nested callable view begins with
  `luaC_checkGC(L)`, before stack reservation, `_base`, or any raw stack
  pointer. That gives collector progress across repeated adapter calls without
  a poll between `luaF_newCclosure` and immediate publication.
* After the source native call and rebase, every live GC-bearing fixed result
  and flexible source prefix is rooted immediately, even when its action is
  identity. Each successfully created nested wrapper (or Interface value from a
  general open conversion) is published immediately into its own fixed slot or
  parallel traced destination range. Raw `TitanVarg*` descriptors, C arrays,
  and native C locals are never roots, and borrowed or allocation-free input and
  destination runs get no parallel traced copies.
* Only operations that can grow or shrink the Lua stack and native calls are
  rebase points; direct and nested wrapper construction are not.

Synthetic adapter line directives and component-conversion diagnostics use the
real cast node's filename, line, and column; an open-run site uses the owning
consumer expression. Tracebacks use a stable source-facing name built by the
freezer:

```text
[callable adapter A -> B at file:line:col]
```

Catch/longjmp spills, pending `finally` actions, and the generic fallback's
finite Lua-VM result limit keep their ordinary rules.

## ABI and ownership rationale

The wrapper uses only the closure header, function tags, native signatures, and
strict stack shell already covered by the
[compiled-module ABI](codegen-overview.md#compiled-module-abi); its adapter and
strict relay are consumer-private translation-unit artifacts, so a consumer can
adjust functions from any same-ABI provider without that provider exporting
anything. A change that needs a new fixed slot, a changed native signature, or a
serialized or provider contract is an ABI change.
