# Linear-time parser traversal and per-parse source-location interning

Status: implementation and local verification complete; publication pending.
This plan implements
[mascarenhas/titan#99](https://github.com/mascarenhas/titan/issues/99) and
[mascarenhas/titan#100](https://github.com/mascarenhas/titan/issues/100). The
work was discovered while profiling the Titan language server, but it belongs
in the compiler because it improves ordinary compilation and every compiler
client.

## Problem and measured baseline

Relabel/LPegLabel ordered choice is not memoized. Several grammar alternatives
share a complete recursive prefix and decide between branches only afterward.
When the suffix fails, LPeg rewinds and reparses that prefix; immediate
match-time captures such as `P <- {} => get_loc` have already executed and run
again on the speculative branch.

The dominant production is currently:

```text
castexp <- P unopexp AS type
         / P unopexp IS type
         / unopexp
```

An ordinary expression traverses `unopexp` three times. Nested calls therefore
multiply the deepest location captures by exactly three per level. The same
structural defect appears independently in prefix/suffix expressions,
simple-versus-function types, Map-versus-Array types, owned C payloads, and
assignment/call statement classification.

Parse-only measurements before changes:

| vscode-titan source | bytes | `get_loc` calls | distinct positions | CPU |
|---|---:|---:|---:|---:|
| `application.titan` | 41,652 | 3,112,881 | 5,106 | 3.03s |
| `application_test.titan` | 53,908 | 16,287,023 | 6,507 | 19.46s |

Six hot positions in nested calls in `application_test.titan` each execute
151,632 location captures. A disposable `castexp` factor alone reduced the
files to 83,390 and 437,523 captures and about 0.18s and 0.62s, while retaining
deep-equal ASTs. A per-parse location cache then reduced them further to about
0.046s and 0.111s. Grammar correction and interning are therefore separate,
complementary changes.

The audit also found a separate failed-generic-call recurrence. In a valid
comparison chain such as `f < Box < Box < ...`, every name retried the complete
remaining suffix as a possible generic type argument list. Capture counts grew
quadratically and LPegLabel exhausted its backtrack stack around depth 38.

## Semantic invariants

- Preserve every public AST constructor, field, source location, and private
  semantic-tooling location.
- Preserve expression/type precedence and associativity, including casts,
  type tests, powers, arrows, Options, C pointers, and owned Arrays.
- Preserve existing labeled syntax failures at the same language boundary,
  especially `CastMissingType`, `IsMissingType`, `TypeType`, `RCurlyType`,
  `COwnedShape`, `OwnedPayload`, `RBracketCOwned`, `AssignNotLValue`,
  `ExpVarList`, and `ExpStat`. The one deliberate exception is malformed
  recursively nested `owned` payloads: without the old recursive quiet
  lookahead, their error is reported at the more-local inner failure. A
  malformed expression statement whose parsed prefix is followed by an
  incomplete suffix can likewise now reach the enclosing statement/function
  boundary instead of being retried solely to produce `ExpStat`; preserve its
  failure position. Preserve exact diagnostics for valid and malformed
  nonnested owner shapes.
- Keep the parser deliberately non-reentrant. Per-parse mutable state must be
  installed and cleared transactionally on success, labeled failure, and Lua
  error; no source string or location table may escape through parser globals.
- Interned location records may be shared only inside one parse. Compiler
  consumers must continue treating locations as immutable.
- Do not replace recursive-prefix factoring with wall-clock heuristics,
  packrat memoization, or a global cross-file cache.

## Implementation

### 1. Factor expression paths

- Parse `unopexp` once in `castexp`, followed by a repetition of committed
  `as type` or `is type` tails. Consuming either operator commits immediately
  to its missing-type label. Fold each contiguous cast chain from right to left
  so `as` remains right-associative and each contiguous test chain from left to
  right so `is` remains left-associative. Mixed chains remain parser syntax;
  their type validity belongs to the checker. Use one finalizer and preserve
  the original expression when the tail is empty.
- Express every binary-operator precedence level as an operand followed by a
  repetition of committed operator/operand tails. Fold left-associative levels
  from the left and right-associative concatenation and power from the right,
  preserving power/unary/cast precedence and concatenation constant folding.
- Introduce one prefix-or-suffixed expression production using
  `prefixexp {| expsuffix* |} -> fold_suffixes`, and use it as the single
  prefix-expression branch of `simpleexp`. Retain a one-or-more suffix form
  only at sites whose semantic predicate requires a suffix, if needed for
  diagnostics or statement classification.
- Rework assignment/call statement parsing so the successful path parses its
  expression prefix/list once and classifies the captured AST as an assignable
  variable list or a call statement. Keep bounded diagnostic fallbacks for an
  invalid assignment lvalue and a non-call expression statement; those may
  duplicate work on invalid input but must not recursively amplify valid code.

### 2. Factor type paths

- Parse function types as a flat operand followed by zero or more committed
  `-> operand` tails. Right-fold the captured chain so `a -> b -> c` remains a
  function from `a` to a function from `b` to `c`; preserve parenthesized fixed
  and flexible argument/result carriers and foreign-function nodes. A focused
  recursive fixture proved the former `resulttypelist !RARROW` / `arglist
  RARROW` split doubled at every nested return-function layer.
- Parse `{ type` once, then select either `: type }` for `Ast.TypeMap` or `}`
  for `Ast.TypeArray`. Preserve `TypeType` and `RCurlyType` labels on both
  forms and the current rejection of const Maps.
- Parse the recursive `cownedpayload` once after `owned`, then select `[]` for
  a counted owner or require the scalar ownership marker without recursively
  looking through the payload. The chosen grammar/helper must retain the exact
  accepted spellings: `owned T[]` and `owned *T`, including nested pointer
  payloads, while rejecting bare `owned T` with `COwnedShape`.

### 3. Audit remaining ordered choices

Review every alternative and lookahead that contains a recursive grammar rule.
Factor any path whose repeated prefix can contain the production itself. For
the remaining probes, document in code or the PR why work is bounded (for
example, reparsing only a flat token/name or one successful generic argument
list) and avoid widening this change into unrelated diagnostic refactors.

- Bound direct generic-call probing to a constant number of ambiguous angle
  starts. For denser sources, scan comments, strings, arrows, comparison/shift
  tokens, and balanced raw angles once, recording only starts whose matching
  close is followed by a possible call/member delimiter. Use that conservative
  set only as a guard; the existing PEG type probe remains authoritative, so
  scanner false positives cannot change accepted syntax or ASTs.
- Build the conservative candidate set before installing parser-global state,
  and clear the set with the other per-parse globals after every grammar match.

### 4. Intern locations per parse

- Add a parser-private position-to-location table installed alongside
  `THIS_FILENAME` and `PROGRAM_NODES`.
- `get_loc` returns the same immutable location record for repeated byte
  positions in one parse, calling `location.from_pos` only on a miss.
- Wrap `grammar:match` so all parser globals are cleared before returning or
  propagating an unexpected Lua error. A labeled syntax failure computes its
  public error location after cleanup.
- Confirm by repository-wide audit that location records are not mutated. If a
  mutation exists, copy at that consumer boundary rather than weakening cache
  isolation.

## Deterministic regressions

Add Busted tests in `spec/parser_spec.lua`, beside the existing grammar tests:

- AST and precedence cases for casts/type tests, nested parentheses and calls,
  nested callback call statements, assignments, simple/generic/function types,
  chained right-associative arrows, concatenation and powers, nested Arrays and
  Maps, and nested owned pointer/Array payloads.
- Existing diagnostic-label cases plus focused malformed forms at every newly
  factored decision point.
- A non-wall-clock traversal guard for recursively nested fixtures, including
  the parenthesized-result/function ambiguity. Prefer a
  parser-private test counter or a debug instruction budget whose threshold
  clearly separates linear traversal from the old exponential recurrence;
  do not assert machine timing.
- Instrument `location.from_pos` to prove repeated positions are interned per
  parse, the cache resets between filenames and after syntax failure/error, and
  non-ASCII bytes retain the existing byte-based columns.
- Compare complete pretty-printed ASTs for representative real modules before
  and after the grammar change in the profiling harness; unit tests may use
  focused structural assertions rather than checking generated metadata.

## Verification and delivery

1. Run the focused parser Busted spec against an installation refreshed from
   this worktree so an older installed compiler cannot shadow checkout files.
2. Run compiler/checker/coder specs affected by parser AST shapes, then the
   complete Titan test gate.
3. Re-run deterministic scaling probes and record capture growth by nesting
   depth for each formerly nonlinear family.
4. Re-run parse-only profiles on
   `vscode-titan/src/server/application.titan` and
   `vscode-titan/src/server/application_test.titan`, recording final location
   calls, distinct positions, CPU, and AST equivalence.
5. Install the fixed compiler into vscode-titan's isolated `.titan` toolchain,
   rebuild the language server, and benchmark cold indexing plus a saved
   `application.titan` refresh. Record compiler/check versus bridge/index time
   separately and confirm protocol requests remain responsive.
6. Commit and push the Titan branch, open a PR linked to #99 and #100, and move
   both Project 2 cards to In review only after all local acceptance gates pass.
   Do not modify or publish the existing `codex/indexing-file-progress` branch
   as part of this work.

## Final measurements and verification

The final grammar and per-parse location cache retain deep-equal ASTs for both
profiled language-server modules. Parse-only results after 101 warm, CPU-pinned
runs were:

| vscode-titan source | `get_loc` calls | distinct positions | median CPU |
|---|---:|---:|---:|
| `application.titan` | 59,349 | 5,112 | 0.017967s |
| `application_test.titan` | 71,695 | 6,514 | 0.028226s |

The dense failed-generic fixture is linear after the bounded direct-probe
threshold: 33 nested angles take 966 captures, 100 take 2,641, and 1,000 take
25,141. The former grammar exhausted LPegLabel's backtrack stack around depth
38.

The real standalone vscode-titan server was benchmarked against a disposable
copy of the repository. The baseline used the current PR #98 compiler parser;
the optimized side used the same native executable and compiler API with only
this parser installed. The optimized figures are medians of three fresh server
processes; the expensive baseline is one uncontended process.

| cycle | baseline wall / CPU | optimized wall / CPU | speedup | baseline / optimized peak RSS |
|---|---:|---:|---:|---:|
| cold 47-file index | 203.180s / 202.480s | 17.909s / 17.800s | 11.35x | 886,276 / 834,312 KiB |
| saved `application.titan` refresh | 28.065s / 27.970s | 1.653s / 1.650s | 16.98x | 1,040,820 / 866,188 KiB |

Before the change, saved-refresh compiler analysis consumed 27.638s of the
28.065s wall time. Afterward its three-run median is approximately 0.691s;
semantic-index construction is approximately 0.866s and becomes the largest
remaining phase. These nested `os.clock` phase readings are approximate across
yields, while the external cycle and child-process CPU measurements above are
direct.

All periodic protocol probes completed before each index became ready. Their
cold p95 latency fell from 55.851s to a 0.641s three-run median; saved-refresh
p95 fell from 22.211s to 0.086s. Hover returned immediately with no data while
the initial index was unavailable, and the saved change produced exactly one
watcher chain and one pass in every run. All disposable workspaces preserved
the original source hash.

Verification completed:

- focused parser suite: 206/206;
- full isolated `make test`: Busted 124/124, all four compiler shards, and
  native aggregate 197/197;
- CI-equivalent LuaCov shards: all four passed; parser file 99.06%, executable
  patch additions 99.64% (276/277), with the sole missed addition an
  unreachable defensive return behind a positive long-bracket guard;
- vscode-titan native server suite with the combined compiler: 156/156;
- standalone LSP transcript and Codex native adapter smoke tests: passed;
- exact differential checks: 38,461 concat/power cases, 7,605 cast/test/power
  cases, 442 arrow cases, and 390 forced generic-prescan cases;
- `git diff --check`: clean.

## Out of scope

- Changing Titan source syntax, type semantics, or compiler diagnostics beyond
  the explicitly requested `as`/`is` chains and more-local malformed nested
  `owned` diagnostics described above.
- Making the parser reentrant or concurrent.
- Language-server invalidation, stale-index serving, persistent-index storage,
  or watcher filtering; those conclusions are tracked independently in the
  vscode-titan issues and remain actionable after this compiler speedup.
- Embedding compiler Lua modules in the language-server executable.
