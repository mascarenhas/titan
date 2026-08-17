# Dynamic Interface discovery implementation plan

Status: **preliminary, source-grounded plan independently reviewed before
implementation**. The two-slot call-capacity finding was incorporated, while
the suggested two-state discovery duplication was rejected because the
state-local module registry already forces initialization once per Lua state.
This file preserves that pre-implementation plan; implementation subsequently
proceeded from it.
Work is isolated on `codex/dynamic-interface-discovery`, based on
`6eec22e` (`master` when research began). The maintainer has waived macOS CI
for this PR. Do not dispatch it manually; exact-head Linux CI and the merged
Codecov report remain completion gates.

Primary request: [GitHub issue #90, Dynamic interface discovery](https://github.com/mascarenhas/titan/issues/90).

## 1. Intended behavior

Titan already inventories a canonical concrete record/union-to-Interface pair
when code generation emits an actual static wrapping conversion. Extend that
inventory into a per-Lua-state discovery protocol:

1. Emit one private `lua_CFunction` witness for each inventoried pair. The
   witness captures the emitting module, accepts the bare concrete Udata in
   stack slot 1, constructs the same two-uservalue Interface wrapper used by a
   static conversion, replaces slot 1 with the wrapper, and returns one value.
2. During either module-initialization path, after the nominal metatables and
   pair vtable have been recovered/filled, raw-register the witness in the
   concrete metatable under the canonical target Interface metatable. If a
   non-nil entry is already present, leave it untouched.
3. At a dynamic or strict Interface boundary, retain the exact-wrapper fast
   path. Otherwise, for a full Udata with a metatable, raw-read that metatable
   using the target Interface metatable as the key. If present, call the value
   with the candidate Udata and consume its single result as the Interface
   wrapper; if absent, raise the existing nominal type error.
4. For `value is I`, return true for either the exact Interface metatable or a
   non-nil raw witness entry. Do not call or validate the entry.

This is compiler-witnessed nominal discovery, not runtime structural method
matching. Merely declaring a conforming record/union or evaluating `r is I`
does not create a pair. Once code generation has seen a real wrapping site,
module initialization advertises the pair whether or not that path executes.

The deliberately permissive protocol follows the issue literally: do not
prove that the candidate metatable belongs to a Titan record/union and do not
prove that the raw entry is callable. Debug/foreign code that forges the entry
is outside Titan's safety boundary; `is` observes presence, while conversion
attempts an ordinary call and inherits its errors or side effects.

## 2. Non-goals and compatibility boundary

- Do not change parsing, type checking, relation planning, conformance rules,
  or the serialized module type graph. Existing `DynamicCoercionPlan` and
  `GuardPlan` nominal leaves already identify every affected boundary.
- Do not add structural lifting for Array, Map, Option, callable, or generic
  types. Existing plans decide when their immediate Interface component is
  observed; only that nominal leaf gains discovery.
- Do not alter the Interface Udata layout, method vtable ABI,
  `TitanInterfaceMethod`, exported symbols, module public prefix, or runtime
  headers. The new function and closure/cache state are compiler-private, so
  this change does not require an ABI bump.
- Do not add a runtime provider search or mutate a bare record/union into an
  Interface globally. Each successful conversion creates a fresh wrapper.
- Do not trigger macOS CI for this PR.

An older same-ABI object remains loadable but cannot advertise a pair it was
not compiled to witness. Cross-DSO/archive discovery begins when a newly
generated module containing the pair initializes. Canonical per-state
metatables make equivalent witnesses interchangeable; first registration wins.

## 3. Source-grounded implementation

### 3.1 Pair inventory and witness identity

`titan-compiler/coder/interfaces.lua::_interface_pair` already deduplicates
actual wrapping sites by the canonical concrete and Interface qualified names,
records exact/adjusted method mappings, and assigns deterministic private pair
and adapter symbols. Extend that entry with a deterministic private witness
symbol in the issue's module/concrete/Interface `\u2133`/`\u2131` hierarchy.
Use the existing injective source-name encoding where arbitrary qualified names
would otherwise make private symbols collide.

The inventory trigger remains `_code_interface_wrapper`; no checker-side
registration annotation and no scan of all structurally conforming types is
needed.

### 3.2 Emit the witness wrapper once

Refactor or share the allocation body used by
`coder._code_interface_wrapper` so static conversions and generated witnesses
cannot drift. The witness must:

- recover its captured emitting `_mod` from upvalue 0;
- read the input Udata directly from slot 1;
- obtain the concrete-owner module and target Interface metatable from the
  emitting module's existing cached uservalues/import slots;
- allocate a two-uservalue Udata with the existing vtable size;
- replace slot 1 with the fresh Udata before publishing its metatable and
  uservalues;
- publish Interface metatable, concrete-owner module in uservalue 0, and
  concrete self in uservalue 1 with the existing barriers;
- copy the already-filled pair vtable and return 1; and
- use Lua internals/direct stack manipulation, with no public `lua_*` or
  `luaL_*` API calls in the wrapper body.

No additional GC root scheme is required. The source is the incoming stack
argument, the result replaces that traced slot, the witness closure roots its
captured module, and the module's uservalues retain the cached metatables and
imported owner. Lua GC objects do not move. Stack addresses still must be
expressed through saved offsets across `luaS_newudata` if it grows the stack.

### 3.3 Register witnesses in both initialization paths

`titan-compiler/coder/generate.lua` already sorts pair obligations, emits
private adjusted adapters and the static `TitanInterfaceMethod[]`, and builds
`INITPAIRS`. Extend this phase to emit the witness declaration/body and
registration statements alongside that pair.

`titan-compiler/coder/module.lua` invokes `INITPAIRS` after nominal records,
imported metatables/functions, and function tags have been established on both
the fresh-state and recovered-module paths. Keep pair filling there, then:

- raw-read `concrete_metatable[target_interface_metatable]`;
- if nil, create a C closure for the pair witness with the current emitting
  module as its one upvalue and raw-store it under that key;
- otherwise discard the recovered entry without overwriting it; and
- leave the Lua stack balanced.

Registration may use ordinary Lua API operations; the issue's no-Lua-API
constraint applies to the generated witness function itself.

### 3.4 Centralize exact-or-witnessed Interface conversion

`titan-compiler/coder/values.lua::checkandget` is the shared nominal leaf for
written `value as I`, implicit gradual projection, Lua-facing formals and
results, typed container observations, branded generic calls, and the strict
guard path. Specialize only nominal targets whose resolved descriptor is an
Interface:

- keep the exact metatable comparison as the likely branch;
- require a full Udata and non-null candidate metatable for discovery;
- raw-read the candidate metatable with the target Interface metatable TValue
  as key, treating every non-nil entry as present;
- save the prior top, call `titan_ensure_stack(L, 2)`, then reacquire stack
  positions before writing the entry and original Udata into the required
  callable-plus-one-argument transaction;
- invoke it through `luaD_callnoyield`, request one result, consume that result
  while its ordinary VM result slot remains traced, and restore the prior top
  after publishing the result;
- address the argument/result slot by a saved stack offset and restore `_base`
  in native functions after the call can grow the stack; and
- load the returned Udata pointer from the result slot without a second
  metatable or callability validation.

Option helpers already recurse into this nominal leaf for present values and
retain nil unchanged. Audit top-level Lua entry emitters separately because
they do not own a native `_base`; their argument/result expressions must be
recomputed from the current `CallInfo` after a relocating call instead of
retaining a stale local stack pointer. This is offset/rebase hygiene, not new
root inventory.

Review all callers of `_dynamiccheckandget`, `_dynamiccheckandset`,
`_strictcheckandget`, and their mixed/set variants after centralizing the leaf.
In particular, verify Lua fixed/variadic entries, Interface method receivers,
module/record/container writes, fixed/flexible value-call results, and emitted
Interface adapters. Remove the stale comment in `coder/calls.lua` that assumes
every successful structural Option guard is nonallocating.

### 3.5 Make `is` observe witness presence without calling

Update the nominal branches of
`titan-compiler/coder/numerics.lua::_code_dynamic_predicate` and its strict
twin for Interface targets. The predicate is:

```text
full Udata && (candidate metatable == target Interface metatable
               || raw candidate-metatable[target metatable] is non-nil)
```

Use the internal raw table lookup, guard a null candidate metatable, leave no
stack effects, and never allocate or invoke the witness. Non-Interface nominal
predicates keep exact identity. A statically known concrete `r is I` continues
to use the checker's static result and must not inventory a pair.

## 4. Test plan

Keep all new cases in existing covered compiler files, so
`spec/support/ci_compiler_test_groups.txt` does not change:

- shard 1: `spec/coder/interfaces_spec.lua`;
- shard 3: `spec/coder/so_import_spec.lua`.

### 4.1 Same-module behavior and generated C

Extend `interfaces_spec.lua` to cover both record and union witnesses whose
static wrapping sites are compiled but never executed. Through a bare
concrete value erased to `value`, prove:

- `is I`, explicit `as I`, implicit `value -> I`, and dispatch;
- a genuine Lua call into an Interface-typed formal and Lua-facing Interface
  receiver;
- present `I?` discovery and unchanged nil behavior;
- the existing formerly failing bare-`Box` assertions now succeed; and
- a structurally conforming concrete type with no wrapping site still returns
  false/raises normally.

Exercise the trusted raw protocol with synthetic full Udata metatables:

- a copied legitimate witness is found without a Titan-record identity check;
- a non-function entry makes `is` true but conversion raises Lua's ordinary
  non-callable error; and
- a missing entry remains false/the normal Interface type error.

Add generated-C assertions for the deterministic record and union witness
symbols, one definition/registration per deduplicated pair, direct slot/upvalue
manipulation, exact wrapper layout/barriers/vtable copy, absence of public Lua
API calls in the witness, conditional no-overwrite registration, and correct
initialization order. Preserve the existing no-pair test for code that never
constructs an Interface wrapper.

### 4.2 Compiled provider discovery

Extend the existing four-module `.so` Interface topology in
`so_import_spec.lua` instead of adding a new fixture file:

- export a bare concrete value from its provider;
- consume it as `value` in a module that does not import the concrete owner;
- prove `is`, explicit conversion, and an Interface formal after a bridge
  module containing the static pair has initialized;
- cover both exact and adjusted vtables;
- preseed one concrete/interface key with a sentinel witness and prove bridge
  initialization does not overwrite it; and
- have that sentinel return a real wrapper so conversion proves that the
  preexisting entry, rather than the generated replacement, was called.

The static archive path links the same generated objects and already exercises
the surrounding Interface topology, so do not duplicate this protocol test
unless the `.so` case exposes an archive-specific gap.

No checker spec should change; the unchanged checker suite is evidence that
type checking did not move.

## 5. Documentation and skill updates

Update the existing Interface/dynamic-boundary chapters rather than creating
new manual chapters.

Language manual audit:

- `doc/language/interfaces.md`
- `doc/language/types.md`
- `doc/language/expressions.md`
- `doc/language/option-types.md`
- `doc/language/lua-interop.md`
- `doc/language/arrays-maps.md`
- `doc/language/generics.md`
- `doc/language/philosophy.md`
- `doc/language/index.md`

Implementation manual audit:

- `doc/implementation/interfaces.md`
- `doc/implementation/type-relations-and-boundaries.md`
- `doc/implementation/lua-interop-internals.md`
- `doc/implementation/codegen-constructs.md`
- `doc/implementation/codegen-overview.md`
- `doc/implementation/values-and-gc.md`
- `doc/implementation/flexible-returns.md` if its relocation commentary is
  affected.

Document exact-wrapper fast paths, witnessed lookup/call, initialization and
first-writer behavior, fresh wrapper identity, Option/container/callable/Lua
boundary consequences, trusted forged entries, GC edges, separate-compilation
compatibility, and the deliberate no-ABI-bump result.

Although the Titan programming cartridges are not implementation guides for
this compiler change, keep their user-facing contracts current:

- revise `.agents/skills/titan-programmer/SKILL.md`;
- revise `.agents/skills/titan-ffi/SKILL.md` for the Lua/debug boundary; and
- add a focused evaluation scenario to
  `.agents/skills/titan-programmer/EVALUATION.md`.

Validate each modified skill directory with the repository/system skill
validator. `titan-tester` and the narrower standard-library skills have no
stale exact-wrapper-only claim and need no edit.

## 6. Verification, review, and delivery

1. Run the focused `interfaces_spec.lua` and `so_import_spec.lua` cases with
   persistent probes disabled, then their complete owning files.
2. Inspect representative generated C and compile with ordinary warnings; run
   focused repetition under the sanitizer if the call/rebase path exposes a
   lifetime concern.
3. Run the complete covered compiler shard command so the exact test partition
   and LuaCov merge are exercised locally.
4. Run the canonical full mixed suite from a clean, isolated absolute prefix,
   with ambient provider-selection/build-policy variables removed.
5. Run skill validation and documentation/link/reference checks available in
   the repository.
6. Ask independent reviewers to audit semantics, generated-C/GC/rebase safety,
   tests, docs/skills, absence of checker/ABI/shard drift, and the final diff;
   resolve every actionable finding and rerun affected gates.
7. Commit intentionally, push `codex/dynamic-interface-discovery`, and open a
   PR closing #90 with local evidence and the explicit macOS waiver.
8. Monitor the exact PR head until all three push-triggered Linux jobs and the
   final merged Codecov project/patch gates are green. Do not infer success
   from an interim coverage upload, and do not dispatch macOS manually.

The goal is complete only after the PR is open at the reviewed head, Linux CI
is green, and Codecov's final gates pass.
