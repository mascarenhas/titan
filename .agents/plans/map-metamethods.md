# Map metamethod-aware code generation

Status: preliminary implementation plan, grounded in issue #86, the current
compiler lowering, Lua 5.5.1 sources/manual, and the existing coder tests.

## Objective

Make Titan Map reads, writes, equality, inequality, and exact integer-keyed Map
length follow the applicable Lua table metamethod rules without changing
parsing, checking, surface types, or Map representation.

The generated code must keep Titan's existing inlined/specialized table access
as its fast path. It must not replace Map access with `lua_gettable`,
`lua_settable`, or another public Lua API call for the whole operation.

The existing strict typed-read guard remains authoritative: a value produced by
`__index` is checked exactly like a raw value found in the Map, including exact
integer/float/nominal tags.

## Source-grounded current state

- `titan-compiler/coder/statements.lua:get_table_key` selects
  `luaH_getshortstr`, `luaH_getint`, or `luaH_get` from the static key type and
  currently turns every miss directly into nil.
- `titan-compiler/coder/statements.lua:set_table_entry` selects
  `luaH_setint` or `luaH_set`, invalidates the metamethod cache for generic
  keys, and leaves the value barrier to its caller. It is shared by assignment
  and Map constructors.
- `titan-compiler/coder/expressions.lua:codeindexmap` roots the Map and boxed
  key, calls `get_table_key`, and only then runs
  `_strictcheckandgetmixed(..., "typed Map read")`.
- `titan-compiler/coder/statements.lua:_materialize_assignment_lvalue` already
  freezes and roots the Map and key before the right-hand side is evaluated.
- `titan-compiler/coder/expressions.lua:codebinaryop` currently lowers Map/Map
  equality to `Table *` identity and Map/`value` equality to
  `luaV_rawequalobj`. Its validated `ComparisonPlan.left/right` retain the
  original static types even after the checker boxes the Map operand for a
  Map/`value` comparison.
- `titan-compiler/coder/expressions.lua:codeunaryop` accepts `#` only for an
  exact integer-keyed Map and currently emits `luaH_getn` directly; the
  checker and result type stay unchanged when the later `__len` clarification
  is implemented.

Lua 5.5.1 supplies the exact slow paths to reuse:

- `luaV_finishget` (`lua-5.5.1/src/lvm.c`) implements function, table, and
  recursively metamethod-aware `__index` chains with Lua's loop bound.
- `luaV_finishset` implements existing-slot bypass plus function, table, and
  recursively metamethod-aware `__newindex` chains, including its required
  anchoring and barriers.
- `luaV_equalobj(L, ...)` performs primitive identity first, then selects the
  left `__eq` or, if absent, the right one and converts its result by Lua
  truthiness. Passing `NULL` is raw equality and must remain the behavior for
  unrelated `value`/`value` comparisons.
- `checknoTM`, `fasttm`, the `luaH_*pset*` result protocol, and
  `luaH_fastseti` are the VM's cached fast-path machinery.

## Implementation plan

### 1. Preserve a constructor/raw-store helper

Split the present raw `set_table_entry` rendering from metamethod-aware
assignment rendering. Map constructors continue to use the raw helper because
a newly allocated Map cannot already have a metatable. This keeps constructor
code and cost unchanged.

### 2. Make Map reads metamethod-aware only after a raw miss

Extend the read helper to receive the code-generation context and a real
`StkId` for the rooted key slot.

1. Run the current static-key-specialized raw lookup unchanged.
2. On a hit, continue immediately to the existing strict guard.
3. On a miss, use the cached metatable check with the no-metamethod/no-metatable
   case marked likely and produce nil exactly as today.
4. Only when `__index` may be present, box the original `Table *`, call
   `luaV_finishget`, and leave its result in a real reserved Lua stack slot.
   Reuse the boxed key slot as the result slot, as Lua's own `lua_gettable`
   implementation does; the raw getters leave it untouched on a miss.
5. Restore `_base` after the potentially stack-relocating call. Expose the
   `StackValue *` paired with a reserved temporary slot without deriving it
   from rendered C text.
6. Point `_s` at that result and run the unchanged
   `_strictcheckandgetmixed` logic.

### 3. Make Map assignment use the VM partial-set protocol on the slow path

For assignment (not construction):

1. If the Map has no metatable, or cached lookup proves no `__newindex`, emit
   the existing raw setter verbatim; make the no-metatable branch likely.
2. Otherwise run the matching partial setter. Preserve the integer/integral
   float specialization with `luaH_fastseti`; never call `luaH_psetint`
   directly for a key that may reside in the array part. Other keys use
   `luaH_pset`.
3. `HOK` means an existing entry was updated and the metamethod is bypassed.
   A non-`HOK` result goes to `luaV_finishset` with a boxed original table.
4. Restore `_base` after the slow helper. Preserve cache invalidation and the
   current caller-owned original-table barrier on raw/`HOK` stores;
   `luaV_finishset` remains responsible for the actual chained target's
   barriers.

This retains the existing lvalue/RHS evaluation order: Map, key, RHS, then
mutation or metamethod dispatch.

### 4. Add narrowly scoped metamethod-aware equality

Recognize the new path from `ComparisonPlan.left/right`, not from the adjusted
operand C types.

- Map/Map: evaluate each operand once and left-to-right, keep pointer identity
  inline, and return false inline for distinct tables with no metatables. Only
  the distinct/metatable case boxes both tables and calls
  `luaV_equalobj(L, ...)`.
- Map/`value` and `value`/Map: keep `luaV_rawequalobj` first. Only a raw-unequal
  pair that is two runtime tables and has at least one metatable calls
  `luaV_equalobj(L, ...)`.
- Materialize the boolean once, restore `_base` after the possible metamethod
  call, and negate that result for `~=`.
- Do not change `value`/`value`, Array, Function, nominal, or Option comparison
  behavior.

This delegates left-versus-right `__eq` selection, callable metamethods, and
truthiness to Lua while retaining Titan's current raw and identity fast paths.

### 5. Honor `__len` for exact integer-keyed Maps

The maintainer clarified this scope after the initial implementation and
before the follow-up implementation began: the already-supported `#m` for an
exact `{integer: V}` Map must also follow Lua's table `__len` behavior.

1. Evaluate and root the Map operand exactly once.
2. Keep `luaH_getn(L, map)` inline behind a likely cached
   `checknoTM(map->metatable, TM_LEN)` fast branch, preserving ordinary Lua
   border semantics and avoiding a public `lua_len` call for the whole
   operation.
3. Only when `__len` may exist, box the same backing table and call internal
   `luaV_objlen` with a real reserved `StkId` result slot.
4. Restore `_base` after the potentially relocating call.
5. Preserve the existing surface result type `integer` by applying an exact
   integer-tag guard to the metamethod result before unboxing it. Do not accept
   an integral Lua float or another coercible value.

The checker continues to reject `#` for every non-integer Map key type. Arrays
keep their separate authoritative-length representation and behavior.

## Regression tests

Add a topical Busted coder spec at
`spec/coder/map_metamethods_spec.lua`, and register it in the exhaustive
`spec/support/ci_compiler_test_groups.txt` partition with its locally observed
runtime.

The spec will cover:

- generated-C shape: specialized `luaH_*` access remains, public
  `lua_gettable`/`lua_settable` is absent, finish helpers occur only after the
  fast checks, and no-metatable branches use the expected likelihood hint;
- `__index`: raw hit bypass, function result, redirect table, recursive
  table/value chain, representative string/integer/float/`value` key paths,
  error propagation, and Lua's chain-loop error;
- strict post-metamethod reads: an integral float or string returned for an
  integer Map value still raises Titan's existing exact-tag error;
- `__newindex`: existing-entry bypass, function interception, redirect table,
  recursive table/value chain, nil assignment, and representative key paths;
- equality/inequality: identity bypass, distinct Map/Map, left precedence,
  right fallback, Lua-truthy results, callable metamethod, both Map/`value`
  orientations, non-table `value`, and unchanged raw `value`/`value` behavior;
- integer-Map length: generated-C raw/VM ordering, no public `lua_len`, raw
  border behavior, function and callable `__len`, exact result-tag failures,
  once-only operand evaluation, and stack relocation/root preservation;
- once-only left-to-right evaluation for reads, writes, and equality; and
- a metamethod that grows/uses the Lua stack followed by use of rooted Titan
  locals, exercising `_base` restoration.

Existing broad Map matrices and ordering tests remain in place and provide the
raw fast-path regression net.

## Documentation updates

This is a code-generation-only change, but existing manuals explicitly state
the old raw semantics. Update the owning text rather than add new chapters:

- `doc/language/arrays-maps.md`: missing-key `__index`/`__newindex`, chained
  Lua behavior, strict result guards, Map equality and integer-Map `__len`,
  and revised performance description;
- `doc/language/types.md`: retain raw `value`/`value` equality while documenting
  the Map/`value` exception;
- `doc/implementation/codegen-constructs.md`: exact raw/partial/finish lowering,
  rooting/rebasing, barriers, equality dispatch, and integer-Map length;
- `doc/implementation/lua-5.5.1-update.md` and
  `doc/implementation/index.md`: remove current statements that Titan never
  reproduces the Map metamethod slow path.

No parser, checker, type, ABI, standard-library, `.titan`, or native-test-runner
change is planned.

## Validation and delivery

1. Run the new topical spec directly with probe caching disabled.
2. Run the existing Map, strict-read, assignment-order, and stack-relocation
   coder regressions.
3. Reinstall into an isolated absolute prefix and run the complete local
   `make test` gate with ambient build-policy variables cleared.
4. Inspect the generated C and full diff, then run an independent adversarial
   code/test/docs review and address every confirmed issue.
5. Commit only the issue-#86 files, push the new branch, and open a ready PR
   referencing issue #86 with local validation recorded.
6. Monitor all push-triggered Linux jobs and the final merged Codecov report
   until green. Do not dispatch macOS; record the explicit waiver in the PR.

## Main risks to audit

- passing a local `TValue *` where `luaV_finishget` requires a real `StkId`;
- keeping a pointer into the Lua stack across a metamethod call;
- failing to rebase `_base` after a relocating slow path;
- mutating an absent entry before deciding `__newindex` applicability;
- using `luaH_psetint` on an array-part integer;
- losing cache invalidation or a GC barrier on raw/partial stores;
- broadening `__eq` to `value`/`value` or other non-Map comparisons; and
- accidentally applying a dynamic conversion instead of the existing strict
  typed-read guard to the `__index` result.
