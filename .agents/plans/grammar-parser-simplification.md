# Titan grammar and parser simplification

Status: implementation, independent reviews, and canonical full local validation
are complete. PR #162 is the delivery record; final-head Linux/Codecov evidence
is maintained in its checks and description. Do not dispatch macOS or merge.

Issue: https://github.com/mascarenhas/titan/issues/161

PR: https://github.com/mascarenhas/titan/pull/162

Branch: `codex/grammar-parser-simplification`

Research baseline: `51592fec` on 2026-09-16. The issue plus the maintainer's
clarifications in this session are authoritative over the old grammar and skills.
Keep this file updated with implementation decisions, checks, and delivery status.

## Objective and delivery boundary

Simplify the grammar to use limited, bounded token lookahead and incremental
fold captures; implement the agreed surface syntax and semantic changes; migrate
the repository; update both manuals and all relevant skills. Review and validate
locally before opening a PR, then monitor and repair Linux CI until green.
macOS CI is expressly waived: do not dispatch it. Do not merge the PR.

Keep the language version unchanged, `driver.LANGUAGE_SERVER_API_VERSION` at 1,
and the generated-code ABI at 2. The maintainer explicitly requires retaining
the ABI marker during this prerelease change, including the new rendered type
identities. Persisted cache schemas remain separate contracts and must invalidate
incompatible declaration/header payloads. No legacy-syntax or old-provider
compatibility layer is requested.

## Agreed syntax and semantics

- Titan function types use `function (parameters): results`; omitting the
  return annotation means zero results. A colon immediately following a
  function type's parameter list is consumed greedily as its return annotation.
  Thus `{function(): T}` is an Array of functions, while `{(function()): T}` is
  a Map with zero-return function keys.
- Generic parameter/application delimiters are `<|` and `|>`. Preserve owner
  application before member selection, including `Box<|integer|>.new(...)`.
- Union variants use `none()` and `some(T)`; case arms use
  `when none() then` and `when some(binding) then`. Optional record-field-name sugar
  (`field?: T`) is removed intentionally; use an optional field type instead.
- Titan and foreign types have distinct syntactic/name-resolution categories.
  Write `foreign` before a foreign type where both categories are admitted.
  Inside a foreign type, names are unqualified and never use `ffi.`.
- `foreigntype` includes the omitted bare `baseforeign` alternative. Nested
  pointers deliberately require grouping, for example `*(*int)`.
- `owned foreigntype` belongs to `basetitan`, not the foreign grammar. Its
  operand must resolve to a raw C pointer or array; ownership strips that outer
  constructor to select a scalar or counted payload. Ordinary Titan aliases may
  name owned types, subject to the usual embedded-foreign export rules. Source
  foreign functions reject owned parameters and block-local declarations.
  An outer `const` on the resolved operand is rejected, including through
  aliases: Titan cannot allocate and initialize const owned storage together.
- Foreign function type syntax denotes a function pointer, not a direct C
  function type. Source-defined foreign variadics remain unsupported. Do not
  expand callback capability as part of this grammar rewrite.
- `foreign type Name = foreigntype` is always module-local and has no `local`
  modifier. Its RHS must be a raw C type: reject `owned` anywhere in its
  semantic type graph, including through an alias or callable component.
- Foreign aliases emit real C typedef declarations in the module's `.ffi.h`.
  An explicit source import (`import "other.titan"`) includes that header and
  brings its typedefs into the importing module's unqualified foreign namespace.
  Ordinary Titan imports do not acquire these aliases. Existing transitive C
  header inclusion applies; this does not extend ordinary private Titan-member
  visibility beyond a direct explicit source import.
- Allocation/layout pseudo-expressions move out of the term namespace:
  `foreign T.new()`, `foreign T.new_array(n)`, `foreign T.sizeof`, and
  `foreign T.alignof`. The absence of dots in foreign types provides the
  pseudo-operation boundary. Retain `foreign Packet.new(count)` for existing
  flexible-array-member allocation, with semantic arity checks.
- Remove written fixed-size local C-array annotations. Keep inferred fixed C
  arrays: an eligible direct local initialized with a positive constant count
  has automatic C-array storage, whereas an explicit `owned T[]` target
  forces GC-owned storage. Preserve current pointer-borrow and array-copy rules.
  Extend constant selection to eligible integer `#define` macros. The maintainer
  explicitly selected preservation of existing types with macro support, not a
  new allocation-size threshold. Zero/dynamic counts retain existing ownership
  rules; FAM allocation retains its distinct nonnegative-count rule.
- Ordinary `type` aliases may contain foreign types inside actual Titan type
  constructors but may not alias a direct foreign type. Enforce the resolved
  outer category semantically: a two-token parenthesis guard is incomplete and
  would reject useful grouped foreign Options. Parentheses alone do not turn a
  foreign type into a Titan type; `owned` is an actual Titan type constructor.
- Use the corrected `prefixexp ::= baseexp {suffixexp}`. Base names and dot/colon
  members may have type arguments. Calls accept positional parentheses, named
  braces, and literal-string sugar. Factor bracket indexing and partial/full
  ranges using the next delimiter.
- Power chains remain right-associative and allow unary RHS operands, including
  `2^-3`. Accumulate the chain and unary prefixes, then fold it from the right.
  Concatenation remains right-associative. `as`/`is` are non-associative as
  specified in the issue. Unary pointer `*` is omitted; use `[0]`.
- Bare module-variable declarations require either `: type` or `= expression`.
  Module-name `?` sugar is absent from the revised rule. Both mutable and const
  declarations may omit an initializer only with an
  explicit type. Omission supplies nil, subject to the existing nil-admission
  rules. Preserve const initialization authority in the module initializer.
  Recognize keyword-named variables by their `:`/`=` suffix before committing
  modifier/declaration keywords; no bare keyword variables remain.
- Primitive Titan type words become contextual identifiers rather than lexer
  reserved words. Apply `Name` versus `AnyName` exactly at the selected grammar
  boundaries. `ffi` becomes a shadowable readonly builtin binding rather than
  a reserved spelling. `L` remains the ordinary-function Lua-state pointer;
  `M` becomes the current-module marker supporting private/public selection and
  the specified cast to a foreign Udata pointer.
- Preserve existing collection-spread, vararg-index/range, `#...`, parenthesized
  one-result adjustment, and block-level `local const` behavior. These are
  conservative scope assumptions where the issue omitted productions; the
  maintainer explicitly removed optional field names and unary `*` instead.
  Make all preserved productions explicit in the rewritten grammar chapter.

## Implementation sequence

### 1. Freeze the executable grammar contract

- [x] Turn the issue and agreed corrections into a syntax acceptance/rejection
  matrix, with representative diagnostics and source locations.
- [x] Review FIRST-token decisions, shared recursive prefixes, keyword-named
  declarations, greedy function returns, and committed error labels.
  Final audit requirements from the maintainer: every negative/positive
  lookahead inspects a constant number of terminals, and alternatives never
  share a prefix containing a syntactic nonterminal. Factor such prefixes
  rather than relying on observed timing or input limits.
  Stronger commitment rule: every syntactic nonterminal appearing in an
  alternative must carry `^ErrorLabel`; after a bounded terminal prefix chooses
  the alternative, a nonterminal failure reports that error rather than
  backtracking. Convenience nonterminals expanding to a bounded token count
  are the sole exception. Inventory and justify those helpers explicitly.
- [x] Explicitly specify collection spread versus bare varargs and their suffixes;
  preserve existing operand binding, count/index semantics, and adjustment.
  After `...`, a following `[` selects vararg indexing/ranging; otherwise a
  token in FIRST(expression) commits to one full spread-subject expression,
  and other tokens leave bare varargs. Never probe the expression itself.
  Preserve the existing dedicated `#...` count atom using the bounded
  `LEN DOTS !LBRACKET` distinction: `#... - 1` is count minus one, while
  `#...[1]` applies length to the indexed value.
- [x] Correct editorial errors (missing `Name`, `suffixexp`, `baseforeign`, and
  separators/spellings) without widening unrelated language semantics.

### 2. Rewrite lexer/parser and move semantic ownership

Primary files: `titan-compiler/{lexer,parser,ast,syntax_errors}.lua`;
`checker/{expressions,statements,type_syntax,declarations}.lua`.

- [x] Add longest-match generic tokens; remove the old arrow/type-angle machinery
  and obsolete primitive-word/ffi binding restrictions.
- [x] Factor declarations, types, suffixes, calls, brackets, and expression levels.
  Remove whole-source generic candidate scanning, recursive type probes, and
  full-expression diagnostic lookahead. No packrat cache or alternate scanner.
- [x] Use fold captures with fresh accumulators for lists and left-associative
  trees. Collect and iteratively right-fold power/concatenation; preserve token
  locations. Do not solve flat-list growth by increasing LPeg's stack limit.
- [x] Preserve existing explicit list/capacity limits unless the implementation
  establishes that a parser-only guardrail must move; document the distinction
  between width, genuine nesting, and runtime/calling-convention limits.
- [x] Parse prefix-expression assignment/call candidates once. Reject non-lvalues
  and non-call statements in semantic analysis, safely normalizing accepted ASTs.
- [x] Move remaining bare-vararg/spread position checks into the checker. Preserve
  finite/open consumer elaboration and parentheses' one-value adjustment.
- [x] Audit every AST visitor and tooling location/decl edge affected by node
  changes. Keep public language-server API marker 1 and preserve useful source
  ranges for errors, navigation, and folding.

### 3. Foreign types, headers, and allocation

Primary files: `checker/{common,c_types,type_syntax,declarations,imports}.lua`,
`symtab.lua`, `foreigntypes.lua`, `cdeclarator.lua`, `ffiheaders.lua`,
`driver.lua`, `coder/{module,names,generate,statements}.lua`.

- [x] Separate Titan and foreign alias resolution, duplicate checks, and cycles.
  Resolve foreign dependencies before emitting typedefs in dependency order;
  do not reorder the semantic module AST or variable initialization.
- [x] Integrate raw alias declaration/emission with the existing foreign-header
  environment, including C tag-versus-typedef spelling and imported C identity.
  Use normal C naming/redeclaration diagnostics; do not mangle alias names to
  conceal collisions or introduce qualified foreign-name syntax.
- [x] Include aliases in modules with no direct foreign imports/functions, in
  folder contributors, and in explicit source-import header graphs. Preserve
  header guards, native validation, cleanup ownership, and generated sidecars.
- [x] Extend the currently include-only persisted `.ffi.h` plan and its closed
  schema/validation/digest to retain typedef declarations and dependencies.
  Ensure warm/restored source-import manifests reproduce the same environment.
- [x] Implement the dedicated foreign pseudo-expression AST/checker path and
  remove type pseudo-members from ordinary `ffi`/alias term lookup.
- [x] Preserve fixed-array/owned/pointer/FAM allocation plans and lifetime checks.
  Extend constant recognition to proven integral object-like macros using the
  existing C macro/target-profile machinery; no host-width guesses or arbitrary
  expression evaluation. Test count sign, width, representability, and extents.
- [x] Implement `M.member`, current-module visibility, pointer cast, and readonly
  binding behavior; verify captures, initializer ordering, and shadowing of `ffi`.

### 4. Compatibility and repository migration

- [x] Update type rendering contextually. Audit `types.tostring` consumers:
  `coder/names.lua` uses it for owned metatables and function-tag identity, and
  `coder/generate.lua` publishes the function registry key. A cosmetic syntax
  change can therefore affect runtime identity. The maintainer has explicitly
  chosen to keep ABI 2 for this prerelease; rebuild the tested provider consistently.
- [x] Audit type serialization, declaration schemas, provider validators, source
  manifests, and cache versions. Foreign aliases are header typedefs, not a new
  exported Titan module alias map. Preserve raw imported-C export restrictions.
- [x] Migrate all affected real sources, generated snippets, diagnostics, and
  examples with syntax-aware edits. Inventory: 168 tracked Titan files (49
  stdlib, 86 native tests, 27 fixtures, 6 examples/testfiles) and 147 spec Lua
  files. Counts are audit scope, not a claim that all files need modification.
- [x] Include hidden generators: `titan-compiler/test_runner.lua`,
  `spec/support/ci_libuv_mode_smoke.sh`, and
  `spec/support/ci_peg_string_sanitizer_smoke.sh`. Do not globally replace arrow,
  angle, or variant-like text inside Lua/C/relabel/string literals.
- [x] Rewrite `doc/language/grammar.md`; update affected chapters in both manuals,
  quick-tour/style material, AGENTS guidance, all eight Titan skills and their
  relevant evaluation/support material. Load each peer skill before reviewing
  or changing its specialized source; use skill-creator for skill edits.
- [x] Treat sibling vscode-titan source migration as outside this repository's
  requested delivery; report compatibility implications without editing it.

## Validation and independent review

- [x] Lexer/parser AST, longest-token, precedence, generic-owner, foreign helper,
  keyword-name, malformed-input, EOF, and diagnostic-location tests.
- [x] Deterministic instruction/capture growth checks for nested expressions,
  wide lists, long operator chains, repeated comparison names, malformed
  generics, and type nesting. Reuse the existing parser scaling regressions.
- [x] Checker tests for invalid lvalues/call statements/non-tail spreads,
  nil initialization, alias categories/cycles, ffi shadowing, M selection,
  forbidden old syntax, and foreign functions without variadic support.
- [x] Foreign typedef tests for dependency order, ordinary/source/transitive
  imports, header diamonds/conflicts, reserved C identifiers, raw-only aliases,
  source-private boundaries, restored caches, and native C compilation.
- [x] Allocation regressions for literal/macro/dynamic/zero counts, explicit
  owners, fixed-array bounds, borrowed pointers, copying, and FAM constructors.
- [x] Provider and cross-module callable/owned-type tests for rendering identity,
  source/DSO/archive behavior, schemas, and the explicitly unchanged ABI marker.
- [x] Focused checkout-profile compiler tests with the selected isolated SDK;
  refresh the installed compiler/provider before installed/native consumers.
- [x] Canonical complete `make test` with an isolated absolute `/tmp` prefix,
  no ambient ROCKS_TREE/TITAN_ROCKS_ROOT/TITAN_EXTRA_CPPFLAGS/
  TITAN_NO_LINE_DIRECTIVES, and correct streamed stdio semantics. Preserve the
  existing compiler shards and 25-root native aggregate. Add new specs to the
  exhaustive compiler manifest when necessary.
- [x] Independent exhaustive parser review: inventory every lookahead and ordered
  choice, explain the constant token bound or consumed-prefix factoring, and
  remove redundant semantic work. If arbitrary lookahead appears necessary,
  stop and ask the maintainer rather than introducing another scanner.
- [x] Verify both manuals, skills/examples, repository syntax migration, and
  `git diff --check`; record exact local test outcomes before publication.
- [x] Commit/push and open the issue-linked PR only after local implementation,
  documentation, tests, and review are complete. Monitor Linux producer,
  compiler/coverage, and sanitizer results for the actual PR head; fix failures.
  Include enabled Codecov project/patch checks in that same head verification.
  Do not dispatch macOS and do not merge.

## Research notes

The old parser already has useful source-location interning and deterministic
scaling tests; preserve those rather than starting from an unmeasured parser.
The earlier `.agents/plans/parser-linearization.md` explains the old speculative
generic/type paths; its compatibility requirements do not override this issue's
intentional syntax changes.

Upstream LPeg capture reference: https://www.inf.puc-rio.br/~roberto/lpeg/
Use the repository's installed LPegLabel/relabel capabilities and the requested
fold-capture approach; no dependency migration is implied.

## Recorded parser audit

Reviewed parser SHA-256:
`d45bc8ed6a66e761f1707546c26468f18224cf19b27d687849feba5ab763e1bb`.
Reviewed lexer SHA-256:
`6ff88d2fcd10e1c0203cbd90bc24ee49371cfb099e070715e97ce19062b1bd2a`.
Recheck this inventory if either file changes before publication.

| Predicate/helper family | Maximum inspected syntax |
| --- | --- |
| Rejected legacy bound foreign import | 5 terminals: local, name, equals, foreign, import |
| Ordinary import head | 4 terminals |
| Variable/field/top-level declaration heads | At most 4 terminals |
| Optional local plus declaration keyword | 2 terminals |
| Foreign declaration heads and name plus dot/colon/equals | 2 terminals |
| Function-type head | 2 terminals |
| Const Array head | At most 3 terminals |
| Variant/interface-member heads | At most 3 / 2 terminals |
| Type/expression/statement/call/suffix FIRST helpers | One lexical terminal; string-opening classification checks at most two bytes |
| Special vararg count atom | At most 3 terminals: length, dots, bracket exclusion |
| Delimiter presence/exclusion | One terminal |
| EOF / any-byte existence | At most one byte |

No predicate reaches an expression, type, block, declaration list, symbol
table, or source scan. Selected alternatives commit their syntactic descents
with labels. Named types, const Arrays, bracket suffixes, and top-level
function selectors consume shared syntactic prefixes once. Bare alternatives
are restricted to bounded conveniences: zero-width capture helpers; zero/one
modifier selectors; one-token operator/field separators; two-token member
selectors; three-token import names; and the bounded import/head helpers above.
Expectations are not added redundantly to single-sequence wrappers outside
alternatives, preserving genuine-nesting capacity.

The parser uses no match-time captures. Lexical validation-only match-time
captures produce no dynamic results. Regressions pass for 40,000 mixed
name/number constructor fields, 20,000 union variants with constructors, 400
defers, 24 nested function-result types, 17 nested indexes, and cleanup following
structured validation failures. No LPeg limit was increased. Parser/lexer plus
explicit-reference checker validation: 303 successes.

## Implementation progress

- Lexer/parser, checker/coder, raw foreign typedef headers, source/cache schemas,
  macro-count inference, M member/type/pointer handling, and the repository
  syntax migration are implemented. The parser audit above identifies the
  exact reviewed files and preserves existing nesting capacity.
- Runtime owner/callable keys retain the existing C declaration scope through
  `types.runtime_identity`; source-facing `types.tostring` uses the new legal
  spellings. Cross-module owner rejection and inline/generic M-cast regressions
  pass. Bare double-vararg spreading is rejected semantically.
- Both manuals, AGENTS guidance, all eight Titan skills, and the programmer
  evaluation companion are updated. All skills validate. Documentation QA
  covered 331 module examples and 41 body examples without a regression in
  previously parseable fences; host-language and intentional-invalid snippets
  retain their appropriate labels. A separate literal audit covered 1,109
  changed Lua literals and restored non-Titan payloads and graph-arrow titles.
- Sixty-five independent/paired skill examples compiled and linked. A fresh
  cartridge-only evaluator produced a separate module that compiled, linked,
  and passed its positive/empty/negative-count behavior checks.
- Canonical isolated validation completed successfully (exit 0):
  `TITAN_JOBS=4 TITAN_ROCK_TEST_JOBS=4 make -j4 PREFIX=/tmp/titan-161-sdk test`,
  from the private Git verification checkout `/tmp/titan-161-build`, with
  ambient ROCKS_TREE, TITAN_ROCKS_ROOT, TITAN_EXTRA_CPPFLAGS,
  TITAN_NO_LINE_DIRECTIVES, LUA_PATH, and LUA_CPATH cleared. ccache used the
  task-private `/tmp/titan-161-ccache` and temporary directory.
- Final local results: 131 build/runtime/packaging cases; all four compiler
  shards (800 + 869 + 598 + 1,139 = 3,406 cases); and all 455 native standard-
  library cases. Complete log: `/tmp/titan-161-full-r3.log`.
- Implementation/test inputs were compared byte-for-byte with the running
  verification snapshot and matched. Parser/lexer hashes still match the
  recorded audit. `git diff --check` is clean. Subsequent documentation-only
  edits preserve the tested implementation behavior. Final follow-up changes
  add four ownership regression cases and make the existing rejection
  diagnostic definitive; their focused gate passes all 24 cases (22 checker,
  two generated-header cases).
- ABI remains 2, language version 0.6.0, and language-server API marker 1.
  Project-manifest and converted foreign-cache schemas are version 4.
- The maintainer confirmed rejection of `owned const *T` / `owned const T[]`,
  including outer qualification inherited through aliases: the language has no
  construct to allocate and initialize const owned storage together. This
  preserves the tested checker behavior. Both manuals and skills record the
  restriction; focused regressions make the accepted boundary explicit.
- Published PR #162 from the validated implementation commit `147cd01c`.
  The PR checks and description hold the hosted Linux/Codecov results for the
  actual branch head. Completion requires all enabled Linux and Codecov checks
  to pass. Do not dispatch macOS and do not merge.

## Final independent review and validation

The final contract uses nominal C declaration identity: the declaring header
and declaration/site determine owner/callable identity across modules, explicit
source imports, and forced headers. Generated checking paths map to stable
source-header identities; anonymous/prototype sites remain distinct, complete
tags use their definition origin, and intrinsic lua_State remains unscoped.
The maintainer explicitly approved programmer responsibility for compatible C
build settings, as with C itself. No macro-environment scan, layout fingerprint,
compatibility probe, or extra preprocessing pass was added. Compiled-probe keys
remain complete raw probe source only. Cache versions are header 5, converted 6,
and project 4; ABI 2, language 0.6.0, and language-server API 1 remain unchanged.

A fresh independent code reviewer reproduced the PR's original imported-type
scope defect, then verified the corrected direct/forced/transitive cases,
both orders of independently compiled providers using the same header,
anonymous sites, forward-to-definition identity, and cold/warm/restored cache
identity. No remaining actionable finding was reported. Independently comparing
53,361 operator expressions with the original parser found no unexpected
rejection or AST difference. Parser/lexer hashes above remain unchanged.

Fresh independent documentation reviews checked both manuals, AGENTS, and all
eight Titan skills. Reported stale parser/token descriptions, optional-callable
and lambda-result guidance, FFI initialization/allocation descriptions, runtime
tag claims, placeholders, and legacy spellings were corrected and rechecked.
Final nominal-identity and reflection API descriptions have no outstanding
review findings. All eight skill validators pass.

The requested reflection cleanup renames standalone public val/descriptor
fields to value/type, including field and variant type metadata. Compound
names and unrelated locals/fixture fields remain unchanged. JSON/SQLite
callers, native tests, both reflection manuals, the reflection skill, and the
serialized interface fixture are updated. Independent fixture decoding proves
all 37 reflection records match public names/indexes/constness; the other 20
module entries are unchanged. The new native Lua-boundary case exercises the
renamed fields. The stdlib string aliases are now string. A separate 23-file
pass made 420 binding/reference edits; normalized AST comparison proves no
literal, shadowing, or other structural change. All affected source roots
passed checking before the final integrated build.

Canonical final validation completed with exit 0:

```sh
env -u ROCKS_TREE -u TITAN_ROCKS_ROOT -u TITAN_EXTRA_CPPFLAGS \
  -u TITAN_NO_LINE_DIRECTIVES -u LUA_PATH -u LUA_CPATH \
  CCACHE_DIR=/tmp/titan-161-ccache \
  CCACHE_TEMPDIR=/tmp/titan-161-ccache-tmp \
  PATH=/tmp/titan-161-sdk/bin:$PATH TITAN_JOBS=4 TITAN_ROCK_TEST_JOBS=4 \
  make -j4 PREFIX=/tmp/titan-161-sdk test
```

It ran in `/tmp/titan-161-build`, a private Git verification checkout:
131 build/runtime/packaging checks; all 3,417 compiler tests
(807+872+599+1,139); and all 456 native tests. Complete log:
`/tmp/titan-161-full-r5.log`. Code, tests, manuals and skills match the
verification snapshot; only this plan's completion notes changed afterward.
`git diff --check` passes. Earlier full logs r3/r4 remain diagnostic history,
not substitutes for this final run.

The final identity correction separately passed 313 focused checker/header/
cache/CPP/C-type cases and 4 native scope cases. A small same-host benchmark
compared 1,806 extracted synthetic-header declarations and 3,119 libuv-header
declarations against the published code. Three cold CPU samples stayed in
comparable ranges: synthetic 0.08-0.10s baseline and 0.07-0.10s changed; libuv
0.91-1.04s baseline and 0.95-1.01s changed. Both versions used the same two initial
toolchain commands and zero commands during cold parsing or ten warm hits.
New pathname canonicalization ran once per encountered header on cold parsing
(one synthetic, 125 libuv) and zero times on warm hits. These small local samples
are not a broad performance guarantee. Reproduction script/logs:
`/tmp/titan-161-origin-bench.lua`,
`/tmp/titan-161-origin-bench-baseline.log`,
`/tmp/titan-161-origin-bench-new.log`,
`/tmp/titan-161-origin-bench-uv-baseline.log`,
`/tmp/titan-161-origin-bench-uv-new.log`.

Hosted delivery evidence belongs to PR #162's actual head. Its initial
`1d80bdd4` run 35167331116 passed all Linux jobs and Codecov, but final completion
requires the correction head's checks to pass too. The PR description records
that final run after it completes. macOS is waived and must stay undispatched;
the PR stays unmerged. Tooling bundles must use the revised compiler to read
this syntax; the sibling VS Code repository is outside this change.
