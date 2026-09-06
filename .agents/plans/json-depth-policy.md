# JSON depth policy for the language-server migration

Consumer: vscode-titan issue #47, branch `refactor/stdlib-json`.
Titan branch: `fix/json-depth-policy`, from pristine master
`65523fa1e0bcc23b411f956b967c3a3b17dbc581` in the isolated checkout.

## Problem and intended behavior

The language server currently accepts JSON nesting through 128 containers.
The stdlib option rejects every max_depth above 64 independently of PEG
capacity. Lifting only that validation exposes an unnecessary delayed-capture
layer in object members: object nesting reaches native capture recursion earlier
than equivalent arrays. Private experiments establish that flattening those
member captures lets arrays and objects at depth 128 use the default PEG stack.

Allow positive max_depth values without an arbitrary upper JSON policy ceiling.
Preserve default depth 32 and explicit per-call depth accounting. Native PEG
matching/capture exhaustion remains an independent resource error; JSON never
mutates the shared PEG stack or relabels unexpected engine failures.

## Implementation

- Remove the object-member function-capture wrapper. Let the existing delayed
  object fold consume constant-size alternating key/value node captures and
  retain one pending key in fresh, private, typed per-object parse state.
- Retain duplicate-name checking, exact key positions, one-pass string decoding,
  delayed folds, bounded callback arity, and linear parsing/node construction.
  Do not eagerly finalize and retain a match-time result for every child.
- Validate max_depth as positive while keeping defaults and node/byte policy
  unchanged. Update language/implementation documentation and JSON guidance to
  distinguish configured container budgets from independent PEG limits and
  post-parse/encoder traversal.
- Keep public metadata types and APIs unchanged. No native engine or compiler
  semantic changes are planned.

## Verification and delivery

- Test single-child arrays/objects at 128 using the default engine stack and
  mixed nesting with sibling values at 128 under an explicitly owned stack of
  2048, restoring the suite default afterward. Sibling repetitions retain more
  matching-stack entries than single-child chains; the server owns its startup
  PEG stack policy. Test configured depth acceptance/rejection, defaults, and
  invalid nonpositive settings. Do not treat a larger allowed option as a
  guarantee against engine resource exhaustion.
- Test wide objects/arrays, duplicate decoded names and exact positions, repeated
  calls/isolated parse state, numeric/Unicode/null behavior, and GC pressure.
- Root owns shared provider/SDK builds. Experiments use private source/build
  staging and read the production SDK only.
- Run focused native JSON/PEG checks and the complete Titan gate in an isolated
  test prefix. Refresh the extension's isolated SDK and pass its full gate.
- Independently review before committing. Open this Titan PR only after the
  extension is locally wrapped and verified, pin the exact commit in its new PR,
  and leave both PRs open for review. Run Linux CI only; never macOS CI.

## Focused implementation evidence

- Lifting only the JSON ceiling lets a single-child Array chain at depth 128
  use PEG's default stack of 400. The equivalent object chain exhausts that
  stack; raising it exposes the separate delayed-capture recursion guard.
  Replacing the member function capture with an anonymous key/value group
  retains the extra capture layer and does not solve that problem.
- Flat sibling key/value captures let both single-child shapes at depth 128
  use the default stack. The stronger mixed shape, with siblings before and
  after each nested value, needs more matching-stack space and passes at 2048.
  Its depth-129 variant is rejected by an explicit JSON budget of 128.
- Positive options do not remove native limits: with stack 2048 and a large
  JSON budget, single-child Array/object chains at depth 192 pass while depth
  200 and 256 raise the unchanged native capture-recursion error. A separate
  regression verifies that a high JSON option does not relabel matching-stack
  exhaustion under an explicitly selected stack of 400.
- A private native executable built from the complete production JSON source
  and test suite, with only module identities rewritten for isolation, passed
  all 149 tests. Coverage includes the new depth policies, existing 32768-wide
  folds, duplicate decoded names and exact positions, repeated parse state,
  Unicode/numeric/null behavior, reflected mappings, and collection checks.
  No shared provider or SDK artifacts were written by these experiments.
- Independent source review found no issues with capture order, pending-key
  ownership, duplicate checking, decoder compatibility, or error propagation.
  `git diff --check` passed. Canonical provider refresh, focused/full Titan
  gates, extension verification, and publication remain with the root owner.

## Canonical verification

- Rebuilt the extension's isolated SDK from these exact production sources,
  then passed its complete gate: 236 native server tests, 56 JavaScript tests,
  12 extension-host tests, native stdio/Codex transcripts, VSIX packaging,
  SDK-free JSON/reflection/SQLite semantic analysis, plugin and install checks.
  A paired 53-file source-index run completed without diagnostics and retained
  unchanged-generation reuse; startup initialization was measured separately.
- `make -j4 test` in the isolated compiler test prefix passed 129 retained
  build/runtime checks, all four compiler shards (878 + 676 + 744 + 995 =
  3293 tests), and all 455 native stdlib tests. Focused canonical selections
  passed 149 JSON tests and 16 PEG tests. An initial combined regex selection
  matched zero tests because the runner uses Lua patterns; the separate
  selections above verified nonzero counts and all intended tests.
- Final independent review and whitespace checks are clean. Public compiler
  APIs, serialized metadata versions, and the native PEG engine are unchanged.
  The extension is locally wrapped and verified before this PR is opened.
  Linux CI evidence will be added to the PR after publication.
