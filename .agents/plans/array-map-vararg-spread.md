# Array, Map, and vararg spread: research and working plan

Date started: 2026-08-27

Branch: `codex/array-map-vararg-spread`

Issue: <https://github.com/mascarenhas/titan/issues/112>

This file is the durable scratchpad for the implementation. It records the
initial research and current decisions so that work can survive context
compaction. It is deliberately a working plan: update it when source evidence,
tests, or review invalidate an assumption rather than following stale steps.

## Delivery constraints

- Implement the full issue on a new branch and publish it only after local
  implementation review, documentation review, and relevant tests pass.
- Keep `TITAN_VERSION` at `0.6.0`, `TITAN_ABI_VERSION` at `2`, and the derived
  installed-library version at `0.6`.
- Do not generate a new auxiliary function that generated C calls. If a new
  reusable runtime operation is necessary, it must be exclusively `static
  inline` in `titan-runtime/titan.h`. Prefer inline statements in the owning
  generated function.
- Add both user-facing and implementation documentation and link each new
  chapter from its index.
- Give the human-facing `doc/language` changes a separate review from the
  implementation review.
- The manual macOS workflow is explicitly waived. Do not dispatch it.
- Push and open the PR only after local completion. Then monitor every regular
  PR check and Codecov until green.
- Preserve the pre-existing, unrelated working-tree edit in `titan-config.lua`
  and exclude it from this branch's commits.

## Issue contract (source of truth)

The issue adds a tail-only expression-list spread for:

- exact Arrays, `{T}`;
- exact integer-key Maps, `{integer: T}`;
- the current function's varargs, whose element type is `T`.

Basic forms:

```titan
...array
...integer_map
...
```

Closed, one-based, inclusive slices:

```titan
...subject[, last]
...subject[first,]
...subject[first, last]

...[, last]
...[first,]
...[first, last]
```

Comma-bearing bracket suffixes are parsed as a distinct subset/slice AST node
in the general suffix grammar. The checker rejects such a node outside a
spread. An ordinary single-index suffix remains ordinary indexing, so
`...subject[index]` spreads the result of `subject[index]` when that result is
itself a valid subject, while `...[index]` remains the existing scalar vararg
projection.

The subject must not receive a target-directed conversion, because the checker
must distinguish Array from Map. Per the maintainer clarification below, the
ordinary automatic `T? -> T` force still applies when `T` is an Array or exact
integer-keyed Map. Slice bounds must be integers or implicitly convertible to
integers. Subject and supplied/default bounds are evaluated once and in source
order. Missing lower and upper bounds default to 1 and the subject's length.
The finite part behaves like a sequence of `T?` projections; an open tail
behaves like a potentially open sequence of `T`, following the same
demand/adjustment rules as varargs and flexible call results. Array/Map elements
use ordinary indexing semantics; vararg elements use the existing vararg-index
semantics.

The issue specifies a fast capacity check (likely `TITAN_LIKELY`) before an
open loop, followed by a loop over the inclusive selected range. It also states
that spread values should not gain a spread-specific GC-root buffer: roots that
already own the subject and ordinary expression results are meant to carry the
lifetime.

## Repository state captured before edits

- Starting commit: `43089f19` (`Persist deterministic positive and negative C
  probe results (#110)`).
- Starting branch: `master`; feature branch now exists as
  `codex/array-map-vararg-spread`.
- The only pre-existing dirty file is `titan-config.lua`; it adds local include
  and `source_module_roots` settings and belongs to the user.
- `Makefile`, `titan-compiler/version.lua`, and `titan-runtime/titan.h` agree on
  ABI 2 and compiler/runtime version 0.6.0.
- No issue comments refine the issue body.

## Existing architecture and implementation seams

### Parser and AST

- `titan-compiler/ast.lua` currently owns `ExpDots`, `ExpDotsIndex`,
  `ExpDotsLen`, and `ExpExtra`; it has no subset or general spread node.
- `titan-compiler/parser.lua` builds all ordinary postfix operations through
  `expsuffix`. Add the comma-bearing bracket alternatives there before the
  ordinary `[exp]` alternative so the grammar remains unambiguous and the
  subset node can be diagnosed later by the checker.
- `simpleexp` currently parses bare `...` and `...[index]`. The four vararg
  subject/slice forms need ordering before the existing projection form.
- `explist` currently gives bare `...` special tail treatment. It is the seam
  for `...<exp>` at the tail while retaining scalar `...` elsewhere.
- positional constructor fields have their own tail-vararg production rather
  than reusing `explist`; they must recognize general spread as well.
- The parser's `LIST_LIMIT` is a syntax-complexity guard, not the runtime
  result cap.

Tentative AST representation:

- `ExpSubset(loc, subject, first, last)` for a comma-bearing suffix, with
  `false` for an omitted bound;
- `ExpSpread(loc, subject)` for a valid tail spread marker;
- checker-generated `ExpSpreadIndex` projections that reference one shared
  spread plan and carry an ordinal, rather than duplicating subject or bound
  expressions.

The shared plan needs a compiler-unique identifier for C temporaries. Generic
instantiation/lowering must preserve or deliberately rebuild this sharing; a
naive recursive copy could duplicate evaluation.

### Checker and expression-list adjustment

- `titan-compiler/checker/expression_lists.lua:adjust_explist` is the central
  fixed/open demand planner. It already synthesizes finite `ExpDotsIndex`
  projections, retains an optional open vararg source, and does parallel work
  for flexible calls.
- The implementation must generalize the current exact `ExpDots`/`ExpCall`
  forks to an open-source descriptor that can also represent spread. Search
  all `_open_dots`, `_open_results`, and `_tag == "ExpDots"` branches before
  considering the checker complete.
- Check a spread subject once without a contextual conversion. Accept only an
  Array type (including its const qualifiers) or a Map whose declared key type
  is exactly Integer; accept `ExpDots` only in a variadic function. Before that
  kind dispatch, preserve the ordinary Option force when its base is one of
  those containers. Reject `value`, C arrays, and non-integer Maps.
- Check and implicitly convert each explicit bound once to Integer. A default
  upper bound must use the existing Array/Map/vararg length semantics once.
- Finite consumers get checker-generated `T?` projections and existing
  nil-fill/coercion behavior. Open consumers retain a spread source typed `T`
  and therefore force missing optional reads under the normal rules.
- Even a zero-demand/truncated use must evaluate the subject and bounds once;
  optimization must not erase their side effects.
- Calls, assignments, returns, constructors, generic argument/result
  inference, erased annotations, and C-call restrictions all consume the same
  adjusted expression-list protocol and must be covered.
- `titan-compiler/checker/lowering.lua` currently recognizes only calls and
  dots as generic open descriptors. Add spread with explicit shared-plan
  handling and refresh the generated projection annotations after erasure.

### C generation and runtime boundary

- `titan-compiler/coder/calls.lua:_code_open_source` currently produces a
  borrowed contiguous vararg descriptor or a caller-owned contiguous result
  run. `_convert_result_run_element` assumes indexed access into that run.
- Array/Map constructors in `titan-compiler/coder/expressions.lua` and return,
  assignment, and call sinks reuse those run abstractions.
- A spread run is non-contiguous. Extend the internal Lua-side run descriptor
  with an inline element-reader strategy/kind, rather than copying elements to
  a new C buffer or emitting a callable helper. Existing sinks can then request
  element `i` while keeping all emitted C inside their current function.
- Emit subject setup, lower-bound setup, and upper-bound/length setup once, in
  that order, under one unique prefix. A finite projection reuses this setup.
  The open tail emits an inclusive loop and converts/assigns each value through
  the same sink code used for contiguous runs.
- Check the selected range against the destination's remaining capacity before
  computing a signed inclusive count, avoiding overflow in `last - first + 1`.
  Use the existing likely/unlikely conventions. Variadic-argument and flexible
  return descriptors retain `TITAN_VARARG_MAX` (200), including any fixed
  prefix. Array and positional-Map constructors retain
  `TITAN_ARRAY_MAX_CAPACITY`; existing constructor open runs are not globally
  limited to 200. Keep counts unsigned until the sink-specific preflight has
  succeeded. The parser's 100-item guard and generic VM's 250-result bound are
  separate limits.
- Do not add a generated C helper function. Any genuinely shared C operation
  must be a `static inline` header routine, but no such routine is currently
  expected.
- Audit AST walkers in coder flow/call detection and checker declaration/
  lowering passes so the new nodes are traversed exactly once.

### Existing rooting behavior and the resolved open-Map lifetime invariant

- Array and Map indexing currently materialize traced subjects and results in
  GC-visible slots. The run descriptors for varargs/flexible results borrow
  upstream roots rather than publishing a root for every incoming element.
- Ordinary Map reads intentionally go through `get_table_key`, so `__index`
  may run. On a raw miss, generated Titan calls `luaV_finishget`, which reaches
  `luaT_callTMres` and, from the generated C frame, `luaD_callnoyield`.
- `get_table_key` passes its reserved key stack slot as `luaV_finishget`'s
  result slot. `luaT_callTMres` saves/restores that address across stack growth
  and writes the metamethod result back into the Lua stack. A fresh collectable
  returned by `__index` is therefore already rooted even though the Map itself
  does not own it.
- Preserve ordinary `__index` behavior. For a sink that immediately copies an
  element into traced destination storage, the inline spread reader can keep
  that existing result slot live, rebase pointers after the call, and then
  reuse it for the next lookup. It must not add a spread-wide copy/root buffer.
- Ordinary `codeindexmap` additionally publishes a typed result root because a
  standalone expression can outlive its lookup block. An inline spread read
  consumed immediately by its sink does not need that extra root.
- A sink that first accumulates several native values and consumes them only
  after the lookup loop is different: repeatedly overwriting one VM result slot
  would leave earlier fresh collectables returned by function-valued `__index`
  reachable only through an untraced C buffer. Such a sink must either consume
  each value immediately or leave every still-live ordinary lookup result in a
  distinct Lua stack result slot until consumption. The implementation now does
  exactly that for native variadic descriptors and direct flexible-output
  buffers. These are the lookups' result destinations, not a second copied
  `TValue` buffer. Immediate constructor/VM-push loops reuse one slot only after
  the prior value has reached traced destination storage.

## Semantic interpretations to lock down with tests

Unless source evidence or maintainer feedback says otherwise:

- ranges are inclusive and 1-based;
- omitted lower is 1; omitted upper is the subject length;
- `first > last` is empty;
- finite consumers expose optional projections, so absent/out-of-range entries
  nil-fill or undergo existing optional adjustments;
- an open consumer exposes `T`, so a missing Array/Map entry raises when the
  value is forced, consistent with ordinary strict indexing;
- exact Arrays with const qualifiers are valid subjects; maintainer review
  clarified that ordinary Option `tryforce` still applies before subject-kind
  dispatch, while target-directed Array/Map coercion remains disabled;
- Map length and element access retain ordinary Map metamethod semantics and
  the per-sink result-slot lifetimes above;
- the 200-result cap includes fixed expressions before an open spread when the
  sink is a variadic-argument or flexible-return descriptor; constructors use
  their existing container-capacity limit instead;
- supplied subject, lower, and upper expressions are evaluated left to right
  once even when the sink demands no spread values;
- scalar per-element adjustment follows existing flexible-result/vararg rules;
- a finite number of spread projections can fill the formal positions of a
  nonvariadic C call. C variadic operands use a disjoint explicit-scalar ABI
  path and cannot be supplied by a spread.

## Tests

Add focused, covered compiler tests rather than standard-library tests:

- Extend `spec/parser_spec.lua` for every array/Map/vararg spelling, omitted
  bounds, chained suffix disambiguation, ordinary `...[index]`, indexed spread
  subjects, tail-only rejection, and subset-outside-spread AST/error behavior.
- Add `spec/checker/spread_expressions_spec.lua` for accepted/rejected subject
  types, integer coercions, vararg scope, all fixed/open expression-list sinks,
  generics, C-call boundaries, result caps, and side-effect preservation.
- Add `spec/coder/spread_expressions_spec.lua` for inclusive/default/reversed
  ranges, Array/Map/vararg subjects, finite and open sinks, evaluation order and
  exactly-once behavior, holes/out-of-range behavior, Map metamethods, GC stress,
  cap edges, multiple spreads with unique temporaries, and generated-C evidence
  that no auxiliary callable helper was introduced.
- Add both topical files exactly once to
  `spec/support/ci_compiler_test_groups.txt`; measure their runtime and
  rebalance the longest-processing-time groups if needed. Do not add a stress
  manifest entry unless a deliberately tagged `#stress` oracle is introduced.
- Keep compiler coverage in the existing Busted shards; do not put this
  language feature under LuaCov through the native stdlib suite.

Focused validation while iterating:

```sh
TITAN_PROBE_CACHE_DISABLE=1 busted spec/parser_spec.lua --filter='spread'
TITAN_PROBE_CACHE_DISABLE=1 busted spec/checker/spread_expressions_spec.lua
TITAN_PROBE_CACHE_DISABLE=1 busted spec/coder/spread_expressions_spec.lua
```

Then run the complete relevant compiler group and the repository's full mixed
suite from a clean, isolated absolute `/tmp` prefix, with ambient
`ROCKS_TREE`, `TITAN_ROCKS_ROOT`, `TITAN_EXTRA_CPPFLAGS`, and
`TITAN_NO_LINE_DIRECTIVES` unset. Record exact commands and results below.

## Documentation

- Add `doc/language/spread-expressions.md`, describing grammar, allowed
  subjects, tail demand, inclusive slices/defaults, evaluation order,
  optional-vs-open behavior, cap/error behavior, and examples. Link it from
  `doc/language/index.md` and cross-reference the existing expression,
  function-call, Array/Map, variadic-parameter, and flexible-return chapters
  where those chapters define the relevant expression-list behavior.
- Add `doc/implementation/spread-expressions.md`, describing AST ownership,
  checker planning, finite projections/open runs, generic lowering, emitted-C
  setup/loop/cap checks, and GC ownership. Link it from
  `doc/implementation/index.md` and update closely related implementation
  chapters where needed.
- Run a separate human-facing documentation review over `doc/language` after
  the prose is complete; record findings and fixes below independently from
  code review.

## Working phases

1. Add AST and parser support plus parser tests.
2. Generalize expression-list adjustment and generic lowering; add checker
   tests.
3. Add inline non-contiguous run emission and all sink integration; add coder
   tests.
4. Write and cross-link both documentation chapters.
5. Run focused tests, inspect generated C, run the complete relevant compiler
   group, and run the full mixed suite under an isolated prefix.
6. Obtain an independent code/semantic review and a separate human-facing
   language-doc review; fix findings and rerun affected gates.
7. Verify version/ABI files and the unrelated `titan-config.lua` remain outside
   the diff; commit, push, open the PR, then monitor Linux CI and Codecov to
   green. Record that macOS was waived and not dispatched.

## Durable progress log

- 2026-08-27: Read the GitHub Project item through the project API and resolved
  it to issue #112. Read the full issue and confirmed there are no comments.
- 2026-08-27: Read the mandatory `titan-programmer` and `titan-tester` skills,
  repository instructions, existing variadic/flexible-result implementation,
  parser/checker/coder seams, relevant tests/docs, CI shard manifest, and
  version/ABI declarations.
- 2026-08-27: Created `codex/array-map-vararg-spread` from `43089f19` without
  touching the user's existing `titan-config.lua` edit.
- 2026-08-27: Parallel read-only reviews of parser/checker, codegen/runtime, and
  test/documentation ownership all identified the Map metamethod/rooting
  conflict recorded above. The codegen review also distinguished the parser,
  variadic/flexible, generic-VM, and container capacity limits; this file was
  corrected to require sink-specific preflights.
- 2026-08-27: Maintainer discussion identified the missing fact in the initial
  GC analysis: `luaD_callnoyield` returns the `__index` result into the Lua
  stack slot already supplied to `luaV_finishget`. That settles one lookup: its
  result is already rooted and needs no duplicate root. A follow-up audit found
  that a sink buffering several native values cannot overwrite that one slot
  before it consumes earlier fresh collectables. Immediate-consumption sinks
  reuse it; buffered native-vararg and direct-flexible-output sinks now retain
  distinct still-live lookup result slots. A weak-value/forced-GC regression
  proves earlier function-valued `__index` results remain live across later
  lookups in exact native calls, function-value Lua calls, constructors, and
  flexible returns.
- 2026-08-27: Maintainer clarification refined the subject rule: the spread
  checker still has no target-directed Array-versus-Map conversion, but it must
  preserve Titan's ordinary `T?` to `T` force when `T` is an Array or exact
  integer-keyed Map. The carrier now checks, `tryforce`s, and then dispatches;
  present and absent indexed-subject regressions pin the behavior.
- 2026-08-27: Final LuaCov-mode profiling measured the new checker and coder
  specs at 6.136 s and 12.444 s. Deterministic longest-processing-time
  assignment places them in shards 4 and 2 and rebalances all four manifest
  totals to 238.772-238.775 s, with shard counts 29/29/29/28.
- 2026-08-27: The first independent code/runtime review found one post-call
  cleanup gap: the distinct ordinary result slots used while materializing
  buffered Map arguments were not cleared after consumption. The call-site
  descriptor now owns that separate range and direct/exact-value paths clear
  it after result publication. Weak-value tests prove both live-during-later-
  lookups and dead-after-call behavior; focused re-review found the fix sound.
- 2026-08-27: The separate human-facing documentation review found six initial
  issues (indexed Option semantics, the core functions cross-reference,
  six-dot grammar, parser-limit wording, maybe-const visibility, and list
  grammar). Maintainer clarification changed the indexed-subject resolution to
  ordinary auto-force; all findings were fixed. Re-review found two remaining
  formal grammar/limit wording mismatches, which were also corrected.
- 2026-08-27: A broader semantic review then found four uncovered seams before
  publication: strict C consumers must lower adjusted projections rather than
  the lexical carrier; Array Interface discovery needs the same finite/open
  result ownership discipline as Map; finite generic evidence is `T?` while
  only the open run uses `T`; and generic positional-constructor finalization
  must refresh spread annotations with the active inference context. All four
  are now repaired. Direct fixed C calls, C function pointers, and allocation
  pseudo-calls evaluate the lexical carrier once but send only fixed
  projections to the C ABI; C variadic `...` remains a disjoint explicit-scalar
  path and does not consume Titan spreads. Delayed Array Interface views
  use reusable or distinct ordinary result slots according to the sink, and
  forced-GC regressions cover fixed/open calls, constructors, and returns.
- 2026-08-27: Follow-up checker review found that a generic producer returning
  `Array?` or integer-Map `?` retained its provisional Option-force adjustment.
  Finalization now rebuilds that ordinary force only after the same-kind
  container base closes, and erased lowering performs force then structural
  view as two existing operations. Explicit, inferred, parenthesized, Array,
  Map, checker-erasure, and native run-time regressions pass. `value` and
  non-integer Maps remain rejected without target-directed subject conversion.
- 2026-08-27: The `titan-ffi` guidance was loaded when review reached fixed C
  expression-list consumers. The resulting implementation and documentation
  explicitly keep finite fixed-formal projection separate from C variadic ABI
  and default promotions; no Titan vararg descriptor enters an FFI call.
- 2026-08-27: Maintainer follow-up made the FFI wording stricter: C variadic
  functions do not consume Titan varargs or spread runs at all. The docs now
  describe nonvariadic finite-formal projection separately and the checker
  regression includes a ranged input-vararg spread rejected as C variadic
  operands.
- 2026-08-27: Final language-doc review generalized Option forcing to every
  accepted container `S?`, distinguished absent implicit subject conversion
  from an explicit written cast, enumerated all positional expression-list
  consumers, and separated the 200-value homogeneous tail limit from fixed
  formals/results and whole-container capacity.
- 2026-08-27: Documentation re-review caught one stale bare-`...` diagnostic
  and a call-list phrase that could be mistaken for C-vararg support. The
  manual now matches the generic-`for` diagnostic and explicitly says Titan
  calls in that context list.
- 2026-08-27: Final frontend review found two blockers. The spread grammar was
  claiming unary `-`/`~` after `...`, misclassifying the established illegal
  scalar uses `... - rhs` and `... ~ rhs` as spread-subject errors; those tokens
  now retain their ordinary parse and checker diagnostic unless a unary-leading
  spread subject is parenthesized. Generic-`for` inference was
  also the lone finalization path that refreshed spread projections without
  its inference context; it now passes that context, with parser and erased-AST
  regressions for both fixes.
- 2026-08-27: The first binary-vararg parser regression exposed a second local
  commitment: a redundant sole-bare-`...` explist shortcut succeeded before
  the later operator could be observed. It was removed; bare `...` already
  parses through `simpleexp`, so a failed constant-token spread probe now falls
  directly into the one ordinary expression parse without recursive lookahead.
- 2026-08-27: Maintainer clarification corrected the review terminology:
  unparenthesized `... - rhs` and `... ~ rhs` are not valid binary vararg
  operations. They must parse ordinarily and receive the existing bare-`...`
  placement type error; only `(...)` explicitly adjusts varargs to a scalar.
- 2026-08-27: A further maintainer clarification superseded that last parser
  conclusion: bare `...` is not a general expression at all. It is parsed only
  as an expression-list/positional-constructor tail marker. Exact `(...)`,
  `#...`, scalar `...[index]`, and the comma-bearing `...[subset]` spellings
  have bounded dedicated parser paths; `... - rhs`, `1 + ...`, `f(..., 1)`,
  and `{..., 1}` are syntax errors rather than checker diagnostics. `(...)`
  becomes one nil-filling optional projection, while an explicit subset node
  outside a tail still reaches the checker-specific "only in a spread"
  diagnostic. This uses ordered token branches and closing-delimiter
  lookaheads, not recursive backtracking.
- 2026-08-27: The generic-`for` fix is pinned at both layers: the checker case
  leaves the producer parameter unresolved until the iterator context closes,
  while the coder case runs generic iterator/producer setup with the spread
  supplying state, control, and the close value, then observes close execution.
- 2026-08-27: The maintainer's final parser boundary supersedes the two prior
  unary-dot entries above. Bare `...` alone remains parser-tail-only, but an
  explicit collection form `... <exp>` is allowed to parse in a fixed
  expression-list or constructor position and is rejected there by checking.
  Consequently `... - 1` and `... ~1` parse as collection spreads whose unary
  subjects are then ordinary type errors, while `1 + ...` still cannot parse.
  Direct `...[subset]` follows the same parse-then-check rule outside the tail;
  a tail classifier alone promotes that direct syntax to a spread.
- 2026-08-27: Parser lowering now factors every bracket body and every written
  list item once. A named capture is classified from its following delimiter,
  avoiding recursive negative probes while preserving complete binary, cast,
  power, and suffix continuations after a DOTS-started scalar expression. The
  full parser suite passes 231/231; depth-17 ordinary indexes and depth-7
  nested vararg indexes remain within tight match-time budgets and would catch
  the former exponential reparse.
- 2026-08-27: Strict nonvariadic FFI dispatch now enters adjusted lowering only
  when the checker-frozen ABI projections differ from the lexical arguments.
  Selected fixed arguments still use the ordinary foreign conversion path;
  carriers and discarded values are evaluated only for effects. This restores
  the exact generated-C shape of unchanged calls while keeping Titan spreads
  completely outside the C-vararg path. The focused C pointer conversion suite
  passes 6/6.
- 2026-08-27: A forced-GC control run established the allocating-adjustment
  lifetime boundary. One syntactic cast inside an open-spread loop normally
  reuses its one static root; without redirection, a later iteration overwrites
  that root while an earlier converted Interface wrapper remains buffered, and
  the regression fails. The sink therefore selects a distinct dynamic result
  slot, but the cast's own allocation path publishes directly into it exactly
  once; spread lowering emits no duplicate post-cast anchor. The same focused
  regression passes with this cast-owned-anchor/sink-selected-slot contract.
- 2026-08-27: Focused ownership re-review separated two reasons an open Map
  run can own indexed slots. The reader may need to retain a raw GC-bearing VM
  result even when its following adjustment is nonallocating; only an
  allocating adjustment now receives that slot as its final cast anchor. A
  `{integer: value}` to `(...: integer)` regression pins that distinction.
  Re-review also found and removed one actual duplicate publication in open
  flexible returns: when the cast already writes the selected slot, the
  post-assignment path no longer writes it again. Identity, nonallocating, and
  read-retention paths retain their required publication. Final codegen
  re-review found no remaining duplication or lifetime gap.
- 2026-08-27: The forced-GC allocating-adjustment regression now allocates 500
  same-shaped Interface wrappers after collection and before dereferencing the
  buffered arguments. This reliably overwrites freed payload storage on the
  unfixed lowering instead of relying on stale allocator bytes; it passes for
  Array, Map, required Interface, optional Interface, incremental GC, and
  generational GC with the indexed cast-anchor contract.
- 2026-08-27: Final frontend review found no parser/checker blocker. Added
  erased-AST identity assertions proving two finite generic projections and an
  open generic source all retain the exact single carrier object, plus checker
  regressions proving `... -1` and `... ~1` reach the non-container spread
  diagnostic. The topical checker suite now passes 19/19.
- 2026-08-27: After the final test additions, matching LuaCov-mode profiles are
  7.290 s for the 19-case checker spec and 13.940 s for the 18-case coder spec.
  Deterministic longest-processing-time recomputation moves them to shards 3
  and 4 and rebalances all 115 compiler files to 239.434-239.439 s with shard
  counts 28/29/30/28. The manifest reproduces the assignment with zero
  mismatches, and the CI contract assertion now uses those counts.
- 2026-08-27: Current broad frontend gates pass: parser 231/231, checker
  1193/1193, focused C FFI plus pointer conversions 42/42, and the complete
  topical coder spec 18/18. Lua syntax checks and `git diff --check` also pass.
- 2026-08-27: The final independent human-facing `doc/language` review first
  found stale recap text about finite C projections, runtime sources of the
  200-value cap, `(...)`, and parenthesized subset promotion. All four were
  corrected; the fresh review passes with accurate cross-links and anchors.
- 2026-08-27: A speculative spread-subject retention concern was rejected
  after maintainer clarification. The ordinary generated evaluation already
  establishes any GC provenance required by the subject through its
  allocation/result publication or semantic/VM home. The implicit C temporary
  evaluates the subject exactly once and cannot be mutated by later bound
  evaluation, but is not itself a new traced slot. Spread lowering must neither
  re-root the subject nor add a second lifetime mechanism. The speculative
  regression was removed without a code-generation change.
- 2026-08-27: Explicit vararg expressions in top-level initializers exposed a
  concrete checker crash: `isconst` had no cases for `ExpDots`,
  `ExpDotsIndex`, or `ExpDotsLen`. They now conservatively return false so the
  expression checker emits the normal variadic-scope diagnostic; focused
  regressions for `(...)`, `...[1]`, and `#...` pass.
- 2026-08-27: The stale `!DOTS` guard on a collection-spread subject was
  removed. The deterministic `DOTS !LBRACKET exp` production now accepts the
  explicit scalar `...[index]` as a subject (`... ...[1]`) while a second bare
  `...` still cannot satisfy `exp`. Parser AST and checker acceptance
  regressions pass together with the full parser and topical spread checker,
  252/252.
- 2026-08-27: Final code review found one concrete conditional-allocation gap
  introduced by suppressing the open-return destination publication whenever
  an adjustment may allocate. An inexact callable adapter allocates only for a
  branded exact-Titan source; a Lua/fallback callable preserves identity. The
  adapter now publishes its fresh wrapper in the true branch and publishes the
  unchanged fallback in the mutually exclusive `else`, exactly once per path.
  A weak-value, forced-GC `defer` regression covers Lua closures in both GC
  modes, and a generated-C assertion pins the two branch publications.
- 2026-08-27: The final implementation-documentation review passes after four
  inventory/provenance corrections: top-level lambda initializers, untraced
  frozen-subject temporaries, spread as an adjusted positional producer, and
  spread/subset rejection in source-defined foreign bodies.
- 2026-08-27: Final LuaCov-mode profiles for materially affected rows are:
  checker dense Arrays 3.852 s, checker spread 6.867 s, checker variadics
  0.314 s, coder flexible-return/finally 6.442 s, coder spread 13.588 s,
  coder variadics 18.010 s, and parser 0.413 s. Deterministic
  longest-processing-time recomputation assigns all 115 files with zero
  mismatches at totals 242.520/242.520/242.519/242.520 s and counts
  29/29/29/28; the CI manifest contract passes 1/1.
- 2026-08-27: Latest local gates after the parser and callable fixes pass:
  combined focused frontend 303/303; complete parser/checker 1427/1427 in
  91.13 s; topical spread plus variadic coder 84/84; and the complete four
  affected coder files 114/114 in 42.99 s. Changed Lua sources pass `luac -p`.
- 2026-08-27: Final independent code rereview passes after the callable
  fallback repair; it found no remaining fixed/open arity, FFI separation,
  Map lookup rooting, cleanup-order, or generated-shape issue. The separate
  final human-facing `doc/language` rereview also passes after clarifying
  runtime-open versus finite C-vararg producers, finite C allocation
  pseudo-calls, and generic-`for`'s spread-versus-bare-dots projections.
- 2026-08-27: The complete post-review `spec/coder` suite passes 954/954 in
  507.74 s. Its only compiler output was the pre-existing `fclose` nonnull
  warning in the source-runtime FFI fixture.
- 2026-08-27: After reinstalling the current 0.6.0-1 source rock into the
  isolated prefix, `spec/support/ci_test_groups.sh compiler` passes all 115
  covered compiler/language files, the 13 tagged stress tests from seven files,
  and the separate C-probe stress oracle. The resulting local LuaCov report is
  40,379 hit / 3,481 missed lines, 92.06% total; changed compiler modules are
  individually covered through the same CI-mode command.
- 2026-08-27: A final narrow generated-code audit confirms that the implicit
  Array/Map subject temporary is a write-once evaluate-once snapshot. Its one
  capture assignment is followed only by reads through `state.subject`;
  Array values, Map keys/results, open-run adjustment sources, loop counters,
  casts, and destinations all use distinct temporaries. No spread path mutates
  or reuses the subject capture.
- 2026-08-27: The final unfiltered mixed suite passes from the fresh absolute
  prefix `/tmp/titan-spread-final.XQWKxd` with all ambient provider/build-policy
  overrides removed: `make -j2 test` passes 125/125 retained
  runtime/packaging specs, all four isolated compiler/language shards, and
  197/197 aggregate native Titan tests. The prefix was built and installed
  from this branch as Titan 0.6.0-1.

## Validation and review log

Focused and broad results so far:

- topical parser spread filter: 22/22;
- topical checker after review repairs: 17/17;
- topical coder after review repairs: 16/16;
- existing `spec/coder/c_ffi_spec.lua`: 36/36 after strict fixed-C lowering;
- full `spec/parser_spec.lua spec/checker`: 1406/1406 in 94.45 s;
- full `spec/coder`: 948/948 in 530.85 s.

The two broad passes above establish a pre-review-repair baseline and must be
rerun now that the review findings are fixed. Record subsequent exact commands,
elapsed times, commit/PR IDs, and CI/coverage URLs here as work progresses.

Post-review-repair results:

- `spec/parser_spec.lua spec/checker`: 1427/1427 in 91.13 s;
- `spec/coder/closure_adjustment_wrappers_spec.lua`
  `spec/coder/flexible_returns_finally_spec.lua`
  `spec/coder/spread_expressions_spec.lua`
  `spec/coder/variadic_spec.lua`: 114/114 in 42.99 s;
- complete `spec/coder`: 954/954 in 507.74 s;
- CI compiler-manifest/provider contract filter: 1/1;
- complete covered compiler group: all 115 files plus 13+1 uncovered stress
  oracles pass, with 92.06% local LuaCov coverage;
- fresh-prefix unfiltered mixed suite: 125/125 runtime/packaging specs, all
  four compiler/language shards, and 197/197 native Titan tests.

Local implementation, review, documentation, and validation are complete.
Publication and hosted Linux CI/Codecov closure remain.
