# Work log: reconstructing the Titan documentation

A running record of how the language reference (`doc/language/`) and the
implementation documentation (`doc/implementation/`) were produced, kept
outside the Agent session as requested. Newest entries last.
Companion document: [documentation-questions.md](documentation-questions.md)
records the questions that came up, the assumption taken for each, and
space for inline answers.

## 2026-06-12 — setup and ground truth

* Created `doc/language/` and `doc/implementation/`.
* Downloaded the Lua Workshop 2017 presentation (Gualandi,
  "Titan — a new programming language for Lua") for the design-philosophy
  background.
* Read `titan-compiler/ast.lua` end to end to fix the inventory of language
  constructs that the documentation must cover. Confirmed there is **no**
  try/catch-style construct in the AST: the "error handling" the manual
  never documented is the runtime error model (typed-boundary checks that
  raise Lua errors, `pcall` interop, the generated error handler and
  `titan.backtrace()`), not new syntax. Option types (`t?`,
  `Ast.TypeOption`/`Type.Option`) are confirmed present and undocumented in
  the manual.
* No `gh` CLI on this machine; GitHub PR history will be fetched once via
  the REST API (search endpoints return PR bodies in bulk), cached to disk,
  and mined from the cache to stay inside unauthenticated rate limits.

## 2026-06-12 — research kickoff and orchestrator-written chapters

* Fetched and cached the full merged-PR history (33 PRs by mascarenhas,
  28 by hishamhm, search API with bodies) plus the comment threads of the
  16 design-heaviest PRs and the two closed-but-merged ones (#40 module
  system → merged via #44; #233 no-global-C-state → merged via #235).
  Cache: `/tmp/titan-prs/`.
* Read the Lua Workshop 2017 slide deck end to end. Key material for the
  philosophy chapter: the "two ways to go fast" framing (JIT vs second
  language), the scripting/system pairing table, "fail early — avoid
  expensive fallback paths", "structs instead of hash tables, C types for
  FFI", and the explicit trade-off of bypassing the C API ("measurably
  faster, allows more specialization… tying each Titan version to a minor
  version of Lua"). Also two historical syntax artifacts worth recording:
  records were `struct`, and the FFI was an inline `foreign C [[...]]`.
* Launched the facts-pack mining workflow: eight parallel agents reading
  the compiler source, the spec suite, and the PR cache, each producing a
  citable facts pack under `/tmp/titan-docpacks/` (lexer-parser, typing,
  codegen-values, codegen-constructs, interop, ffi-driver,
  spec-behaviors, pr-history).
* Wrote the writers' style guide + document map
  (`/tmp/titan-docpacks/style-and-outlines.md`): 14 language documents,
  10 implementation documents, audience/voice/example/citation rules.
* Wrote the three chapters that needed primary-source synthesis by hand:
  `doc/language/philosophy.md` (slides + PR arc + Pallene fork history),
  `doc/language/index.md`, `doc/implementation/index.md`.

## 2026-06-12 — facts packs complete; drafting started

* All eight facts packs landed (≈3,800 lines total under
  `/tmp/titan-docpacks/`). Highlights that shaped the documents:
  * **Option types:** indexing arrays/maps always yields `T?`; annotated
    element/value option types are silently de-optionized; `local x? =`
    is the inference opt-in; `==` between `T?` and `T` works by lifting
    (PR #250) with an `integer?`/`float?` carve-out; `t? or t` defaults
    to bare `t`. PR #239 rationale quote captured ("not bother the
    programmer with having to prove that the value is always there…").
  * **Error handling:** PR #257 (Jan 2019, the last feature PR) is "an
    experiment towards integrating Lua's error handling into Titan" —
    error handler + `titan.backtrace()`; the reserved "error slot" in
    every Lua wrapper is written but never read (recorded honestly).
  * **Interop ground truth:** boolean parameters accept any Lua value by
    truthiness and never error; container contents are *not* checked at
    the boundary (deferred to access inside Titan); arity from Lua is a
    run-time error, not adjustment; `import` vs `require` rationale
    quote (hishamhm: "different semantics should be visually
    distinguishable in the source code").
  * **Stale-manual catalogue:** the old EBNF is wrong/stale in 13+ ways
    (no methods, no `?`, no `as`, no multi-assign/returns, …) — the new
    grammar chapter is written from the implemented grammar instead.
  * The miners also flagged a handful of likely latent bugs (driver
    `.so`-vs-source mtime comparison, a swapped `typeerror` call in the
    foreign-import error path, duplicate `ExpAssign` label) — recorded
    in the implementation docs as known quirks, not silently fixed.
* Launched the drafting workflow: 21 writer agents (12 language chapters,
  9 implementation chapters), each given the style guide, its facts
  packs, and a per-document content specification; orchestrator-written
  chapters (indexes, philosophy) excluded.
* Replaced `doc/manual.md` with a redirect stub; updated `CLAUDE.md` to
  point at the new documentation.

## 2026-06-12 — fact-checking (interrupted and resumed)

* Launched the verification workflow: one empirical fact-checker per
  chapter (24 chapters), instructed to *run* every example through the
  real compiler (`titanc --tree /tmp/check-*`) and provoke every claimed
  error, then a cross-document consistency critic. Eleven checkers
  completed before the session usage limit cut the rest off; resumed once
  credits returned (completed checkers served from the workflow cache).
* Results from the first eleven: ~350 examples/claims tested, ~48
  corrections applied in place. The largest: the `index.md` limitations
  entry about record constructors and module variables was wrong in both
  directions — *initializers* work fine (spec-covered); what crashes the
  compiler is a record constructor expression *assigned* to a module
  variable inside a function body. `index.md`, `records.md` and
  `modules.md` now state the verified behavior.
* **New compiler bug discovered by the records checker** (not introduced
  by any doc work — found while exercising constructor contexts): a
  function that combines an array-of-records constructor, a
  map-of-records constructor, *and* element assignments to both compiles
  silently and corrupts memory at run time (deterministic
  `free(): invalid size` abort; a function declared to return `float`
  returned a table). Each context works in isolation; the bisected
  trigger needs both constructors plus both element assignments.
  Recorded in [documentation-questions.md](documentation-questions.md)
  (Q8) rather than fixed, since fixing the code generator is outside the
  documentation task.
* The checkers left ~170 compiled `.so`/executable artifacts in the
  repository root (module outputs land in the compiler's working
  directory); removed them all and tightened the cleanup instructions.

## 2026-06-12 — verification complete; documentation finished

* The fact-check workflow finished after two interruptions (a session
  usage limit, then a manual pause that stopped in-flight checkers). On
  the final resume the verification was restructured into batches of
  four concurrent checkers at the user's request. A lesson recorded for
  next time: the workflow resume cache matches on the script's
  call-structure prefix, so restructuring `parallel(24)` into chunked
  batches invalidated the cache and re-verified the already-checked
  chapters — harmless (they came back nearly clean) but not free.
* Final tally: 24 chapters, ~860 examples and claims tested through the
  real compiler across the runs, ~130 corrections applied in place, plus
  a consistency pass that fixed 12 cross-document disagreements,
  normalized terminology, resolved every remaining `<!-- VERIFY -->`
  marker into either confirmed text or an honest "Unverified (intent
  only)" note, and machine-checked every relative link and anchor
  (0 broken).
* The honest-documentation policy paid off: rather than papering over
  prototype gaps, the verification surfaced and precisely characterized
  nine compiler defects (memory corruption with combined record
  container constructors; bare multi-return forwarding miscompiling;
  the `T?`→`T` unwrap ICE; `while`/`repeat` condition truthiness gaps;
  foreign-pointer truthiness ICE; typedef'd-enum constant ICE;
  `local a, b = (f())` ICE; float `%`; two latent error-path bugs).
  All are listed in [documentation-questions.md](documentation-questions.md)
  Q8 for triage, and the user-visible ones are documented as limitations
  in the affected chapters.
* Deliverables, final state:
  * `doc/language/` — index + 13 chapters (philosophy, types, option
    types, expressions, statements, functions, records, arrays/maps,
    modules, Lua interop, error handling, FFI, grammar).
  * `doc/implementation/` — index + 9 chapters (AST/typedecl,
    lexer/parser, checker, codegen overview, values & GC, codegen
    constructs, Lua interop internals, FFI internals, driver/toolchain).
  * ≈9,900 lines total; `doc/manual.md` is a redirect stub; `CLAUDE.md`
    points at both indexes; the Lua 5.5 migration reports are linked
    from the implementation index.
* Sources used end to end: the compiler source and spec suite (primary),
  the Lua Workshop 2017 slides (philosophy), the cached merged-PR
  history with discussion threads (design rationale and quotes), and
  empirical compilation/execution of every testable example.

## 2026-06-14 — compiler bug-fix pass (Q8) and limitation reconciliation (Q5)

After the documentation questions were answered, two follow-ups were
actioned in this session.

**Q8 — fix the nine recorded defects.** A read-only diagnosis workflow
(nine parallel analysts, one per bug, plus two documentation-limitation
auditors) produced a root cause, a concrete patch, and a regression test
for each. The fixes were then applied and verified one at a time in the
main loop (the Titan build environment is a shared singleton — one
`lua-5.5.0` tree, one installed rock, `titanc` writes artifacts into the
repo root — so edits and compilation can't be parallelized; only the
analysis was). Each repro was compiled and run before and after the fix.

* Bug 1 (memory corruption): the Lua-entry wrapper `genluaentry` captured
  `StkId _firstret` *before* the native call; the callee's
  `lua_checkstack` can relocate the stack, leaving it dangling. Fixed with
  `savestack`/`restorestack` — this hardens **every** entry point.
* Bug 2 (multiple-return forwarding): `codereturn` deferred the first call
  into the trailing `return`, so the `ExpExtra` out-param copies ran before
  the call. The same C-unspecified-argument-evaluation-order hazard existed
  in `codecall` for a trailing multi-return call in an **argument** list
  (`add3(10, divmod(7,2))`). Both were fixed the same way — hoist the call
  into a temp so it executes before the `ExpExtra` arguments that read its
  out-params. All multi-return positions now match Lua: a trailing call
  expands (argument list, array constructor, multiple assignment,
  `return`), a non-trailing call is adjusted to one value, and the type
  checker already enforced exactly that contract (`checkargs` expands only
  the last argument) — confirmed empirically (over-/under-supply give clean
  arity errors; an ill-typed expanded value gives a clean type error).
* Bug 3 (`T?`→`T` unwrap): the unwrap template filled `node.loc.file`
  (nil) instead of `c_string_literal(node.loc.filename)`, `$GETSLOT`
  lacked a `;`, and the string-cast no-target path dropped `$CSTATS`.
  While reconciling the docs a further case surfaced — unwrapping an
  option returned **directly by a call** took `&<rvalue>` — fixed by
  materializing the option into a `TValue` temp first. The unwrap now
  works in every position (variable, parameter, module variable, record
  field, call result, array/map index, arithmetic, argument, concat).
* Bug 4 (`while`/`repeat` truthiness): `codewhile`/`coderepeat` now wrap
  the condition in `toboolean`, like `codeif`.
* Bug 5 (foreign-pointer truthiness): added a `Type.Pointer` case to
  `toboolean` (`(ptr != NULL)`).
* Bug 6 (typedef'd-enum constant `impossible: Enum`): `convert_enum` now
  returns `types.Integer()` (enum constants are integer-like).
* Bug 7 (`local a, b = (f())`): the checker now error-recovers the surplus
  declarations' type, turning the ICE into a clean arity error.
* Bug 8 (float `%`): implemented `generate_binop_mod_flt` faithful to
  Lua's `luai_nummod` (verified against the in-tree interpreter, including
  sign-divergent cases).
* Bug 9 (latent): the driver's source-vs-`.so` mtime guard no longer
  compares a number with `nil` (so `.so`-only imports now work end to
  end), and the foreign-import error path passes `node.loc` and routes the
  message through `%s`.

Thirteen regression tests were added (`spec/coder_spec.lua`,
`spec/checker_spec.lua`); the full suite is green (**817** successes, 0
failures). The shared-build shell-quoting gotcha (double quotes inside the
`call` helper's `-e "…"`) bit two new tests once and was fixed with single
quotes.

**Q5 — cross-link and reconcile the limitations.** Because the nine fixes
resolved nine of the documented limitations, those were removed from the
affected chapters and omitted from the indexes (per the answer: don't
advertise former bugs). A reconciliation workflow (one editor per chapter,
sixteen chapters, driven by a verified fixed/partial/unchanged manifest)
removed or narrowed the now-fixed items while keeping every still-valid
limitation; the two index limitation lists were then rebuilt to reference
and link the remaining ones (a new "Known limitations and quirks" section
was added to `doc/implementation/index.md`, which had none).

## 2026-06-15 — limitation audit: which "limitations" were really bugs

A follow-up pass, on the rule that *anything that passes the typechecker
and then crashes the compiler, generates C that fails to compile, or
generates code that crashes/misbehaves at run time is a **bug** to fix*,
whereas a genuine limitation produces a **clean compile-time error**.

**Audit.** A read-only workflow of ten classifiers each took a batch of
documented limitations, built minimal repros, ran them through the real
compiler, and labelled each `LIMITATION_CLEAN`, `BUG_ICE` (passes
typecheck then a Lua-traceback crash), `BUG_INVALID_C` (generates
non-compiling C), `BUG_RUNTIME_CRASH` (segfault/abort), or
`BUG_SILENT_WRONG` (diverges from Lua) with a root cause and a recommended
fix (implement correctly, or convert to a clean error). 35 items; ~24
classified as bugs, ~11 as genuine clean-error limitations.

**Fixes** (applied and verified one at a time; full suite green, **836**
successes, 0 failures, with new regression tests):

* *Implemented correctly* — string `==`/`<` (were TString* pointer
  comparisons → now `luaS_eqstr` / `luaV_lessthan`-`lessequal`, content
  and lexicographic); the value uses of `and`/`or` (ternary, boolean-left
  chains, `option-call or default` — were invalid C → materialize the lhs
  and test via `toboolean`); the numeric `for` (rewritten to Lua's
  `forprep`/`forloop` — overflow-safe unsigned count, separate internal
  index so the visible control variable is a read-only copy);
  `repeat`/`until` referencing a body local (coder ordering); a bare
  `return` in a nil function; assigning a record constructor to a
  module variable / field / never-read local (the `coderecord` target
  guard); forward-referenced / mutually-recursive record fields (hoisted
  tag forward-declarations); float→integer range + double precision
  (both the `ExpCast` and the entry-wrapper paths); an `integer?`
  boundary now converts an integral float; the early-return stack-top
  reset (the preamble always declares `_base`, every `return` resets it);
  the `?` marker honored on module vars and multi-return tails; `.so`-only
  record imports registered.
* *Converted to a clean compile/run-time error* — a zero `for` step
  ("'for' step is zero"); assignment to the `for` control variable; a
  written function-type annotation ("first-class function types are not
  supported yet"); assignment to a foreign C variable; an unsupported C
  type in a foreign signature (the member is now skipped, so referencing
  it is a clean "not a member" rather than an `impossible: Type.Unknown`
  crash); a NULL `char*` foreign result (a run-time error, not a
  segfault); and the `coerceable` clause-12 swapped-args bug (an option
  coerced to a non-coercible base is now a clean type error).
* *Follow-up* — the cross-base option conversion `t1? → t2?` (e.g.
  `integer? → float?`) was first left as a clean error, then implemented
  properly on review: `nil` propagates and a present value is unwrapped,
  converted base-to-base, and re-wrapped (a narrowing one can still raise
  on a present value). The conversion reuses the ordinary base-cast codegen
  via a synthetic cast of the extracted value.
* *Left as documented limitations* — first-class functions, `break`/
  `goto`, the FFI's unsupported aggregate types and **lack of memory
  safety** (passing a Titan `string` to a C function that frees or stores
  it still corrupts the heap — there is no `void*` type to require an
  explicit cast against, and string→`void*` is also the legitimate
  read-only-bytes pattern, so this stays a real FFI caveat), and the
  wrong-arity-to-a-multi-return-callee message crash.

Files touched: `coder.lua` (most), `checker.lua`, `types.lua`,
`foreigntypes.lua`. The chapters and both index limitation lists were then
reconciled (a per-chapter workflow) to drop the now-fixed items and reword
the now-clean-error ones.

## 2026-06-15 — smaller gaps and rough edges

Acting on the *"Smaller gaps and rough edges"* list in the language index,
fixing all of it except `goto` and `for ... in` (which stay roadmap
items). Each fix was applied to the compiler, verified end-to-end with
`./titanc` + the Lua 5.5 interpreter, and locked in with regression
tests. Full suite green, **855** successes, 0 failures (+18 tests).

* **`break` statement.** New `Ast.StatBreak` node and a `(P BREAK) ->
  StatBreak` alternative in the `statement` production (the `BREAK`
  terminal already existed but was unused). The checker tracks loop-
  nesting depth (incremented around `while`/`repeat`/`for` bodies) and
  rejects a `break` outside any loop with the clean error `'break'
  outside a loop`; codegen emits a C `break;`, which correctly exits the
  innermost generated loop in all three loop shapes.
* **Option receiver auto-unwrap for method calls.** `p:m()` on a
  `Point?` no longer errors at compile time. The checker materializes an
  option→base `ExpCast` on the receiver, reusing the cast codegen's
  run-time nil check, so a method call through a `nil` option raises a
  clean `expected mod.Point but found nil` instead of being rejected.
* **Explicit option `as` casts.** `e as T` when `e: T?` (with `T` the
  option's base) is now accepted by the `ExpCast` checker and unwraps
  with the same run-time nil check (`expected T but found nil`). The
  codegen for `t? -> t` already existed; three earlier `ExpCast` codegen
  arms (array-index fold, and the to-`string` arm) were guarded so an
  option source falls through to it, while the to-`boolean` arm keeps
  using truthiness (so option-valued conditions are unchanged).
* **Wrong-arity call to a multiple-return callee.** Was an ICE in
  `types.tostring`: the multi-return arm called `table.insert(out,
  table.concat(rtypes), ", ")` — `insert(t, pos, v)` with a string
  `pos`. Fixed to `table.concat(rtypes, ", ")` (both the `Function` and
  `Method`/`StaticMethod` arms); the arity error now formats the type as
  `(integer) -> (integer, integer)` and is reported cleanly.
* **Field selection on a call result (`f().x`).** Already worked (read
  and assign) after the earlier codegen fixes; added regression tests and
  removed the stale "aborts the compiler" note from the grammar chapter.

Files touched: `ast.lua`, `parser.lua`, `checker.lua`, `coder.lua`,
`types.lua`; tests in `parser_spec`, `types_spec`, `checker_spec`,
`coder_spec`. Docs reconciled: the index *"Smaller gaps"* list now lists
only `goto`/`for ... in`; the statements, option-types, records,
functions, expressions and grammar chapters were updated to document the
new behaviour (and the cast table gained an option→base row). All
internal doc links re-verified.

## Plan

1. **Ground truth pass** (source + specs): catalogue every construct,
   typing rule, and codegen strategy as implemented today, including the
   undocumented ones (option types, methods/statics details, multiple
   returns/assignment, the runtime error model).
2. **External research**: the 2017 workshop slides (design philosophy,
   pre-Pallene history) and the merged PR history of mascarenhas and
   hishamhm on titan-lang/titan (including closed-but-merged #233 and #40)
   for design rationale.
3. **Outline + style guide**, then parallel drafting of the individual
   documents (one file per section, two index documents).
4. **Adversarial fact-check**: every document verified against the actual
   compiler source and spec suite by independent reviewers; corrections
   applied.
5. **Integration**: `doc/manual.md` becomes a redirect stub, `CLAUDE.md`
   pointers updated, cross-links checked.

## 2026-06-17 — first-class functions and the zero-return `()` default

Implemented first-class function values and a changed default return type,
then brought the documentation in line.

* **Language change — implementation.** Function values are now first-class:
  a top-level function, a `local` function, an imported `mod.f`, or a record
  static `Rec.new` can be referenced as a value, stored, passed, returned,
  and called. Function-type annotations are accepted everywhere. A value is a
  boxed `TValue`; a Titan function value is a `CClosure` with upvalue[0]=`_mod`,
  upvalue[1]=a function-type tag (light userdata), upvalue[2]=native entry
  pointer. Each referenced function has one canonical closure in a dedicated
  module upvalue slot (stable identity); exported functions always get one, so
  importers reference them by upvalue index (no hash lookup). Function-type
  tags are shared across modules via the Lua registry (publish-or-recover),
  keyed by the canonical type string. Calls take an exact-type fast path
  (direct native call) or a generic path (`luaD_callnoyield` through the Lua
  stack); the callability check is deferred to the call. Titan can now call
  Lua functions directly. Methods, foreign/FFI functions, and
  anonymous/nested/closure functions remain non-values.
* **Language change — zero-return default.** An unannotated function is now
  `(...) -> ()` and returns nothing (`select('#', f())` is 0), matching Lua,
  rather than one `nil`. `return` (bare) is the only return; `return nil`
  becomes an arity error; `: nil` is the explicit one-`nil` form; a
  `()`-returning call is an error in expression position except `(f())`, which
  adjusts up to a single `nil`. A new `Type.Void` sentinel models "no value"
  in the checker.
* **Docs updated** (this pass): `functions.md` ("Functions are not values
  (yet)" → "Functions as values"; the no-annotation/`return` rules rewritten),
  `lua-interop.md` (rewrote "Calling Lua from Titan" to the now-supported
  case; added the unannotated-returns-nothing note), `types.md`, `grammar.md`,
  `expressions.md`, `statements.md`, `records.md`, `modules.md`,
  `option-types.md`, `ffi.md` (FFI functions still not values), `index.md`,
  `philosophy.md`, `implementation/checker.md`, `implementation/index.md`, and
  a status preface on `first-class-functions-spec-v1.md`.
* **Tests added.** `spec/first_class_functions_spec.lua` (end-to-end + checker:
  the `()` default, referencing/storing/passing/returning/calling, fast and
  slow paths, identity, Lua interop both directions, cross-module references,
  `Rec.new` as a value, containers, `value`↔function coercion, GC stress) and
  function-type cases in `spec/types_spec.lua` (zero-return `-> ()` rendering,
  higher-order tostring, exact-vs-compatible, serialize round-trip, nested
  `is_gc`). Full suite green.

## 2026-06-19 — anonymous functions, closures, and bound methods

Documented the anonymous-functions / closures feature (branch
`anonymous-functions`), a docs-only pass against the shipped behavior in
`titan-compiler/{parser,checker,coder}.lua` and the new specs
(`spec/checker/closures_spec.lua`, `spec/coder/closures_spec.lua`,
`spec/coder/bound_methods_spec.lua`). Design source:
`.agents/plans/anonymous-functions.md`.

* **Language feature shipped.** A `function (...) ... end` expression is a
  fresh function value that closes over the enclosing function's locals —
  reading captured-immutable ones by value, sharing captured-and-mutated
  ones through a box. Lambda parameter and return annotations are optional
  and **inferred** (params from the expected function type, return from the
  body, unified), framed as the same checking-vs-synthesis inference as
  `local x = exp`. A lambda is a `simpleexp`, so direct application needs
  parentheses; equality is object identity (each evaluation is a fresh
  value); a `local f = function … end` self-reference is a clean "not
  declared" error; a top-level `local x = function … end` is the existing
  "must be constant" error. Bound instance-method references `obj:method`
  (no call) are also values — the method's type with `self` removed and the
  receiver bound — including across a `.so` boundary. Only foreign/FFI
  functions remain non-values.

* **New language chapter.** Added `doc/language/closures.md` (syntax,
  inference, lexical capture, fresh-per-evaluation/equality, the recursion
  limitation, and bound method references). Reconciled the "not
  first-class" list in `index.md` (now only FFI functions), the chapter
  header and "Functions as values" in `functions.md`, the method/field
  notes in `records.md`, and added the `funcexp`/bare-`obj:m` productions
  and a note to `grammar.md`. Linked the new chapter from the index
  reading guide.

* **Implementation docs.** `codegen-overview.md`: documented the `_fn`
  native-ABI parameter (after `_mod`; `NULL` on static calls, the callee on
  fast value calls, the called closure in the Lua entry), updated the
  example signatures and the dynamic-wiring typedef, and added a "Closures
  and captured variables" section (the trap-stub `CClosure`-cell box and
  its uniform forward `luaC_barrier`, the `3 + N` upvalue layout, capture
  lists, file-scope lambda hoisting, transitive capture, bound-method
  trampolines, and the `TITAN_VER` 0.5 → 0.6 ABI bump). `checker.md`: added
  a "Closures: capture analysis and lambda inference" section (the
  `func_stack`, `_funcdepth`, `_captured`/`_assigned`/forced-`_used`, the
  inclusive transitive capture interval, and checking-vs-synthesis
  inference incl. return collection) and reconciled the first-class-
  functions contributor note. Added a pointer from
  `first-class-functions-spec-v1.md`'s scope note (it had excluded
  nested/anonymous functions).

## 2026-07-07 — optional function parameters by nil adjustment

Documented the relaxation of Titan function call arity: under-supplied
Titan calls now adjust upward by synthesizing `nil` arguments, while
over-supplied calls remain errors. The same nil-padding happens in each
exported function's Lua entry wrapper before boundary type checks, so Lua
callers can pass fewer arguments too.

* **Language docs.** Updated `functions.md` with the new argument
  adjustment rule, including the distinction between omitted parameters
  whose types accept `nil` and omitted required parameters that still fail
  type checking. Reconciled constructor and Lua-boundary wording in
  `records.md`, `lua-interop.md`, `variadic-parameters.md`,
  `error-handling.md`, `index.md`, and `philosophy.md`.
* **Implementation docs.** Updated `checker.md` for `checkargs`
  synthesis of `Ast.ExpNil` and the C/FFI strict-arity escape hatch;
  updated `codegen-overview.md`, `codegen-constructs.md`, and
  `lua-interop-internals.md` for Lua-entry stack padding, surplus-argument
  errors, and the revised wrapper excerpt.
* **Tests added.** `spec/checker/optional_parameters_spec.lua` covers
  direct calls, methods, function values, missing non-nil parameters,
  surplus arguments, and foreign C calls staying strict.
  `spec/coder/optional_parameters_spec.lua` covers direct and method
  native calls, first-class exact and generic calls, short trailing `...`
  spreads into fixed and variadic callees, Lua entry padding, surplus Lua
  arguments, and missing required parameters at the boundary.

## 2026-07-15 — flexible returns and contextual `value` calls

Implemented and documented Titan's return-side analogue of typed variadic
parameters. A callable may now declare a fixed result prefix followed by
`...: T`; finite consumers see possibly absent tail projections as `T?`, while
open array, variadic-argument, and flexible-return sinks preserve exactly the
results that exist. Calls through `value` synthesize a positional function type
from their argument list and surrounding finite/open result demand, so Lua
multiple results remain available without weakening an already typed callable.

* **Unified adjustment semantics.** The checker now elaborates declarations,
  assignments, returns, call arguments, arrays, and generic `for` through one
  finite/open expression-list demand. Titan surplus arguments and results are
  evaluated once in source order and discarded when the static signature or
  finite consumer does not observe them; foreign C calls remain ABI-strict.
  This supersedes the 2026-07-07 entry's then-current statement that Titan
  surplus arguments were errors; that entry remains as historical context for
  the earlier nil-padding change.
* **Native and Lua call paths.** Flexible native entries receive caller-owned
  typed output backing plus a finite/open budget. Exact module, static, method,
  bound-method, lambda, and exactly tagged first-class calls retain the native
  path. Non-exact Titan values and Lua callables use the generic stack path;
  statically open producers uniformly request `LUA_MULTRET`, preserve their raw
  count on the Lua stack, and are trimmed or checked by the Titan sink.
* **Lifetime and interface work.** Flexible result backing is paired with
  traced roots for GC-bearing elements, including pending returns that cross
  allocating or nested `finally` blocks. Callable serialization, compiled
  symbols, installed module paths, and `TITAN_PATH_0_14` now use compiled-module
  ABI 0.14; ABI 0.13 modules fail through the normal mismatch diagnostic.
* **Manuals and tests.** Added and indexed
  `language/flexible-returns.md` and
  `implementation/flexible-returns.md`, reconciled the surrounding language
  and implementation chapters, and added topical parser/type/checker/coder,
  `.so` rehydration, ABI, open-count, GC, and error/finally coverage.
* **Generic-for close follow-up.** A contextual `value` factory still exposes
  the finite four-slot iterator tuple, but a nil-padded or explicit `nil`
  fourth result now means that the optional close is absent. Non-nil values
  retain the ordinary callable/error behavior, and the nil guard remains
  inside the synthesized `finally` so pending actions keep their precedence.

## 2026-07-16 — folder modules and semantic `titan.uv` contributors

Implemented and documented folder modules: one logical module may now combine
a canonical main source with deterministic immediate contributor files while
retaining one namespace, checker/codegen pass, initializer, interface, and
artifact identity.

* **Language and implementation manuals.** Added and indexed the folder-module
  chapters, then reconciled module lookup, parsing, checking, code generation,
  output paths, and libuv build documentation. Contributor-local diagnostics
  and generated `#line` directives retain each physical source filename.
* **`titan.uv` dogfood.** Replaced the monolithic source with a seven-file
  ensemble. The main source owns the shared prelude and sole initializer;
  filesystem, OS, process, runtime, task, and TCP contributors own their
  exported records and API beside the related implementation.
* **Compatibility boundary.** Moving public declarations changes ordered
  module-member and canonical-closure slots, so compiler/runtime constants,
  install/search paths, tests, and CI advance from ABI 0.14 to 0.15. The exact
  deterministic 0.15 `titan_uv_types` interface is pinned as a fixture.
* **Declaration-order follow-up.** Generalized the checker from a source-order
  signature sweep to dependency-staged collection without rearranging the AST.
  The parser marks synthesized record `new`; the checker records each root's
  combined order, premarks duplicate winners, precollects aliases, reserves
  ordinary names, then visits imports, resolves aliases, and collects
  records/constructors, callables, and record members before checking module
  variables under their source frontier. Only imports and module variables are
  mutually order-sensitive; records, aliases, methods, record functions, and
  ordinary functions may precede one another. Foreign name/type histories and
  aggregate definition-order checks prevent the early import pass from leaking
  a later C declaration into an earlier module-variable initializer.
* **Private ownership.** Moved every remaining local uv record from the main
  into its filesystem, OS, process, runtime, task, or TCP contributor, and
  moved the private `FS` constants instance beside `FsConstants` in
  `file.titan`. The main now retains shared imports, shared constants, module
  state, bootstrap, program-argument setup, and the sole initializer. These changes
  alter private slot/initialization order, but the exact `titan_uv_types`
  fixture and importer-visible slots are unchanged and the ABI remains 0.15.
* **Build and packaging.** `UV_TITAN_SOURCES` explicitly owns the ensemble,
  nested generated artifacts clean correctly, the delayed-FS variant patches
  an isolated folder copy, and bundled/system modes still produce one
  canonical `titan/uv.so`.
