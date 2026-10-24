# The type checker

The checker takes the AST the parser built (see
[Lexer and parser](lexer-parser.md)) and produces the typed, *elaborated* AST
the [code generator](codegen-overview.md) consumes.
`titan-compiler/checker.lua` is a facade over the implementation slices in
`titan-compiler/checker/`; `checker/core.lua` owns their shared private
environment and mutable checker state. Generic helpers live in the slice of
the construct they serve, under `generic_`-prefixed names. `types.lua` owns
type values and relations, and `symtab.lua` owns scoping.

The checker does not merely *check*: it **rewrites** the AST so that every
implicit conversion, every finite extra call projection, and every defaulted
loop step exists as an explicit node, while finite/open list demand is
recorded on its consumer. The code generator relies on that completely; it
never decides to coerce anything on its own.

## Entry point and contract

```text
function checker.check(modname, ast, subject, filename, loader, options)
    --> module_type, errors
```

`checker/entry.lua` `checker.check` builds a fresh symbol table with
`symtab.new(modname)`, resets the per-check function stack and the
loop/`catch`/`finally` counters, and runs staged top-level collection and
body checking (below). It then runs these whole-module steps in order:

1. record the C header dependency closure in `ast._c_header_dependencies`;
2. if there are no errors, `select_linear_array_freezes` and
   `validate_union_source_projections`;
3. [export validation](#export-validation);
4. `makemoduletype` (`checker/imports.lua`), stored in `ast._type`;
5. if there are no errors, prove that the public interface is recoverable by
   passing it through `checker.register_module_interface`, the path importers
   use;
6. if there are still no errors, collect binary usage and finish generics:
   with `options.analysis_only`, `generic_freeze_declared_core` returns the
   detached declared module type; otherwise `generic_lower_erased_core` erases
   generics for the coder and returns the erased module type
   ([Generics](generics.md));
7. `completion_finish` ([Completion](completion.md)).

The function returns that module type (plain `ast._type` when checking
failed) and the error list; callers test `#errors == 0`. `loader` is the
import callback (see [Imports](#imports-and-the-loader-protocol)); if
omitted, a stub that fails every import is used. The other `options` fields
are `completion`, `cache_adapter`, `prepare_ffi_header`,
`target_profile_provider`, `probe_service_provider`, and `reparse`; the driver
uses the two providers to share the resolver-owned target profile and C probe
service with dependency checks, and supplies `reparse` only when the resolver
may batch C probes ([below](#speculative-probe-barrier-and-authoritative-recheck)).
The body runs under `xpcall`, so an owned probe service and
C header bundle are closed even when a checker invariant throws; the error is
rethrown after cleanup.

For a [folder module](folder-modules.md), `driver.defaultloader` independently
parses all source files and calls this entry point once with one dense combined
AST, the logical module name, and the canonical main's subject/filename. The
checker does not know or create file scopes; contributor filenames remain only
on the existing node locations.

Errors accumulate: nothing aborts on the first problem. The `errors` table is
an array of formatted strings that also carries `subject` and `filename`
fields. Every error goes through `checker.typeerror` (`checker/common.lua`),
which formats via `location.format_error`, so every message has the shape
`FILENAME:LINE:COL: type error: <message>`. When an expression cannot be
given a type, the helper `invalid(errors, loc, ...)` logs the error and
returns `types.Invalid()`, the error-recovery type, so checking continues.
When a duplicate refers to an earlier node, `location.format` adds that
node's complete `filename:line:col`; this is essential when the declarations
come from different contributors.

### Speculative probe barrier and authoritative recheck

With `options.reparse`, a resolver-owned `probe_service_provider`, and
neither `analysis_only` nor a completion request, `checker.check` runs a
speculative pass. Its symbol table carries `probe_speculation`; while
`checkbodies` runs, eligible acceptance probes defer into the check's probe
batch ([C FFI](c-ffi-expressions.md#speculative-batched-acceptance-probes)).
Top-level checking, including imports, foreign environments and module
variable initializers, stays synchronous.

Immediately after `checkbodies`, before step 1 above, the batch flushes.
Nothing that can publish a fact precedes this barrier: header dependencies,
export validation, `makemoduletype`, interface registration, lowering,
completion and the return to the loader all follow it. A nested import is
checked by its own `checker.check` during the importer's top level, so it
passes its own barrier before the importer receives its interface. If every
verdict accepts, the pass continues unchanged: each deferred call returned
exactly the fields a real success gives its consumer, so the pass executed
the synchronous operation sequence.

If any verdict rejects or fails, the pass stops at the barrier after its
ordinary cleanup, and the check runs again authoritatively:

1. `options.reparse()` assembles a fresh root from the same inputs; the
   caller's root table is refilled so its reference stays valid.
2. A fresh symbol table and error list rerun every step. Each top-level
   import unit (`checker._checkimport_for`) replays the speculative pass's
   recorded module type, errors and provenance, plus the `binary_modules`
   entries and profile acquisition the unit added to the importer's state,
   instead of calling the loader again. Nested checks, `driver.imported`
   entries, dependency frames and loader registry writes therefore happen
   once, as on the synchronous path. A diverging import sequence is an
   internal compiler error.
3. At the end of the import phase (`checker._finish_import_phase`) the
   rerun asserts that every unit was replayed and restores `types.registry`
   in place to the speculative pass's snapshot taken at that same point.
   Every deferral follows the import phase, so that snapshot is the
   synchronous registry; all later writes of the abandoned pass are discarded.
4. Probes answer from completed results: published verdicts from memory,
   nonpublishable runs from the batch's answers. The rerun never defers.

The rerun is the synchronous check from the synchronous state, so its AST,
diagnostics (text, location, order) and generated C are the synchronous
path's. The remaining shared objects touched after the import phase are
imported type graphs, which importer checks only normalize or memoize
deterministically (portable C numeric metadata, owner prefix slots, enum
carrier metadata from synchronous probes); this is the same invariant that
lets several importers, and analysis followed by compilation, reuse one
imported interface graph. An exception from the speculative pass propagates
unchanged.

## The symbol table (`symtab.lua`)

`symtab.new` returns a stack of lexical blocks plus side tables:

| Field | Holds |
| --- | --- |
| `blocks` | lexical scopes, starting as `{ {} }`; `open_block`/`close_block`/`with_block` manage them, `add_symbol` writes the innermost block, `find_symbol` searches innermost-out |
| `type_aliases` | the module-wide Titan alias and Interface namespace |
| `foreign_aliases`, `foreign_types`, `foreign_names` | C typedef, type, and ordinary names, kept apart from Titan symbols; the `*_history` tables order each declaration by `current_toplevel_order` |
| `c_file_tags`, `c_prototype_tags` | canonical file-scope aggregate tags and prototype-local tags from the combined C parse |
| `source_imports` | modules imported explicitly from source ([Source-import visibility](source-import-visibility.md)) |
| `generic_type_scopes`, `generic_scope_bindings` | the separate lexical namespace of generic type parameters |
| `modname` | the module prefix `typefromnode` uses to qualify nominal names: `Point` in module `geo` becomes `types.Nominal("geo.Point")` |

Scoping rules an engineer must keep:

* Top-level duplicate winners are decided by an AST-order prepass (below)
  before names are reserved in the outer block. `find_dup` checks only the
  innermost block, and a local re-declared in the same inner block silently
  overwrites the earlier symbol.
* A local or parameter may not shadow a read-only, non-`_builtin` binding
  (`L`, `M`): `declare` (`checker/expression_lists.lua`) and `checkfuncbody`
  report `cannot declare ... because it shadows a built-in local`. The `ffi`
  namespace is read-only but `_builtin`, so a local named `ffi` may shadow it.
  Foreign type lookup uses its own namespace and never depends on a value
  binding named `ffi`.
* `ffi` refers to one `Type.CModule` whose value and type-member maps are
  built from the module's complete C translation unit.
* While a `TopLevelVar` is checked, `st.initializer_order` makes
  `find_symbol` hide declarations through `Symtab:hidden_from_initializer`:
  module variables at or after the frontier, and `TopLevelImport` or
  `TopLevelForeignImport` bindings after it. The complete `ffi` environment
  remains visible, including macros and aggregate completion from later
  foreign directives. Outside this mode all ordinary module names are visible.
* A combined folder AST creates one symbol table, so top-level `local`
  declarations are private to the logical module but visible from every
  contributor; there is no file-private block.
* `checkfuncbody` binds the pseudo-symbol `"$function"` (not a legal
  identifier) to the enclosing function node, and `StatReturn` looks it up to
  find the declared result shape.

## Staged top-level collection and body checking

`checker.check` runs `mark_toplevel_duplicates`, `collect_type_aliases`,
`checktoplevel`, and finally `checkbodies`. Apart from the removal of
superseded synthesized constructors (stage 2), the AST keeps its original
flat or combined folder order; the checker changes visitation order, not node
order.

`mark_toplevel_duplicates` assigns every root node its 1-based
`_toplevel_order`, chooses the first ordinary declaration of each name in that
order, reports later duplicates with the first node's full location, and marks
them `_ignore`.

`collect_type_aliases` enters foreign aliases first, then Titan aliases, and
records Interface declarations in `st.interface_declarations`. It chooses the
first alias/Interface by AST order and keeps a surviving record or union
authoritative over a same-named type-only declaration regardless of
placement. Forward aliases and Interface spellings are therefore available
without creating value symbols. Alias resolution and cycle detection are in
[Type aliases](type-aliases.md).

`checktoplevel` (`checker/declarations.lua`) then performs these stages:

1. `reserve_toplevel_names` publishes every surviving ordinary name before any
   signature needs it.
2. `collect_nominal_constructors` recognizes parser-marked synthesized
   `TopLevelStatic` nodes: one `new` immediately after each `TopLevelRecord`,
   and one positional constructor per variant immediately after each
   `TopLevelUnion`. A duplicate nominal owner also suppresses its
   constructors. An explicit record static `new` removes the synthesized node
   from the AST and marks the record's `custom_constructor` metadata; see
   [record constructors](record-constructors.md).
3. All Titan imports are visited in AST order, establishing module
   environments before any non-variable declaration.
4. `check_foreign_environment` builds the `ffi` namespace from the ordered
   header environment ([FFI internals](ffi-internals.md)); foreign aliases are
   resolved, `check_imported_c_declarations` validates imported C
   declarations, and `generic_reserve_generic_owner_headers` reserves generic
   owner descriptors.
5. Titan aliases are resolved; every record and union is built and registered
   in `types.registry`; Interfaces follow in declaration order, so all nominal
   owners exist while their members are checked; each synthesized constructor
   is then attached to its nominal namespace. Field and payload storage
   eligibility is described in [Native nominal storage](nominal-storage.md).
6. Function, foreign-function, and module-initializer signatures are
   collected, then explicit methods and nominal functions, then
   `generic_validate_pending_generic_constraints` checks constraints that had
   to wait for complete owner descriptors. Because names, imports, aliases,
   owners, and constructors already exist, these declarations are independent
   of their relative AST order.
7. Module variables are checked in AST order. For each node the checker sets
   `st.initializer_order` to its `_toplevel_order`, so the annotation and RHS
   see only earlier imports and module variables (see the symbol-table rules
   above), followed by the ordinary constant-expression validation.

Constness is an exact boolean on local declarations, record fields, module
variables, and Array types. An omitted mutable initializer (local or module
variable) is normalized to a checked nil expression list only when every
written type passes `types.accepts_missing_nil`; const locals always arrive
with an RHS. A const module variable may be assigned only by the directly
executing root initializer of its owning module. See
[Const-value implementation](const-values.md#checker-rules-for-declarations).

Methods and nominal functions perform their own conflict checks against
fields, variants, and one another. Every failed or duplicate top-level
declaration is marked `_ignore`; everything downstream (body checking,
`makemoduletype`, and the coder) must skip it.

`checkbodies` walks the AST in order. It checks function, method,
nominal-function, and synthesized-constructor bodies, each in a fresh scope
through `checkfuncbody` (methods first get a `self` declaration typed as the
owner's `Type.Nominal`). It also validates resolved record fields, union
payloads, and alias targets after all nominal owners are registered, which is
what permits recursive and mutually recursive nominal declarations while still
reporting an unresolved nominal. Module-variable annotations are validated in
the module-variable stage instead, under the import/module-variable frontier.

`checkfuncbody` synthesizes two read-only bindings in every function-like body
except foreign functions and synthesized record/union constructors: `L`, typed
as the complete foreign environment's canonical `lua_State` pointer, and `M`,
the current-module marker. Member selection on `M` resolves owner
declarations, including source-private ones; qualified type syntax `M.Type`
uses the same owner namespace rather than a lexical or generic shadow; and an
explicit `as foreign *Udata` lowers it to the native module pointer.

After checking, `makemoduletype` (`checker/imports.lua`) builds the module's
interface by traversing the AST in order, skipping `_ignore` and import
nodes. Public `TopLevelVar` becomes `Type.ModuleVariable`;
`TopLevelFunc`, `TopLevelForeignFunc`, `TopLevelRecord`, and `TopLevelUnion`
become `Type.ModuleMember`. Public `TopLevelTypeAlias` and
`TopLevelInterface` nodes populate the separate `type_members` map with
resolved RHS types and canonical Interface descriptors; Interfaces have no
run-time module member or module-userdata slot. Local variables and functions
go to `source_members` and local aliases to `source_type_members`, which are
compiler-only state that never enters a serialized interface. Private union
variants are omitted while the owner keeps their absolute tags and its total
`nvariants`. See [Type aliases](type-aliases.md) and
[Interfaces](interfaces.md) for publication details.

`checker.has_main(ast)` (`checker/declarations.lua`) is a post-check `titanc`
uses to choose between a paired library provider and a standalone executable.
It looks for a `TopLevelFunc` named `main` with no input vararg, exactly one
parameter whose checked type has tag `Type.Array` with a `Type.String`
element and the mutable (`no`) const qualifier, exactly one result with tag
`Type.Integer`, and no flexible tail. It compares the raw tags of the checked
types, so `const { string }` and `const? { string }` parameters leave `main`
an ordinary function. Non-generic Titan aliases have no
type descriptor of their own (the checked type is the alias target), so an
alias-annotated `main` still qualifies. Because it examines the one combined list, `main` may be
declared in the folder main or in any contributor.

## Syntax candidates and semantic validation

The parser admits prefix-expression candidates for assignments and call
statements. Before ordinary variable checking, the checker rejects non-lvalues
and normalizes valid name/member/index receivers to the `Var*` nodes. A
statement candidate must be a call; an arbitrary value expression is not an
expression statement. The parser therefore needs neither full-expression
lookahead nor parse-time semantic predicates.

Bare varargs and collection/ranged spreads may also appear syntactically in
any expression-list position. Shared list adjustment and constructor checking
reject an unparenthesized non-tail expansion. Parenthesized markers request
one value, including a parenthesized input-vararg range. The established
finite/open plans and evaluation-once carriers remain the codegen boundary.

## The relations and plans in `types.lua`

The checker never asks one boolean relation to stand for consistency,
automatic conversion, callable assignment, written casts, and equality. The
definitions, the boundary matrix, and the plan records are in
[Type relations and boundary plans](type-relations-and-boundaries.md). The
entry points the checker calls are:

| Function | Role in the checker |
| --- | --- |
| `types.normalize` | cycle-safe collapse of `Type.CTypedef` chains |
| `types.equals` | exact structural/nominal identity inside the classifiers; never an admissibility answer |
| `types.consistent` | symmetric gradual consistency |
| `types.coercion(source, target)` | one direct automatic `CoercionPlan`, including named Option operations |
| `types.callable_adjustment(actual, expected)` | directional callable shape/component plan |
| `types.assignment_adjustment(source, target)` | identity, direct coercion, gradual view, callable adjustment, or rejection; the decision `trycoerce` consumes |
| `types.dynamic_coercion(target)` | conversion authorized by written `value as/is T` and genuine Lua boundaries |
| `types.written_cast`, `types.comparable` | written-cast and symmetric equality policy |
| `types.gradual_guard`, `types.has_sound_gradual_guard` | strict guards, kept separate from boxability |

Conversion edges are not consistency leaves. Integer-to-float, `T`-to-`T?`,
C numeric/address conversions, truthiness, and record/union-to-Interface
wrapping are direct coercions that do not make the corresponding Arrays,
Maps, or callable components consistent. Conversely, `integer` and `value`
are consistent but still need an injection or strict projection plan because
their representations differ. Array consistency requires equal qualifiers.
Qualifier changes are limited: assignment admits `{T}` or `const {T}` into
`const? {T}`, and a `linear` mutable call result into `const {T}`; a written
mutable-to-const cast is an `array_freeze` plan. All of these are specified in
[Array relations and linear-use analysis](const-values.md#array-relations-and-linear-use-analysis).
The checker freezes each callable adjustment into a relation-free adapter
graph; its lifetime facts (raise/relocate flags, root inventories, rebase
ledger) are in
[Closure adjustment wrappers](closure-adjustment-wrappers.md#checker-elaboration).

### `checkmatch`: consuming the original decision

`coerce_and_check(source, target, term, errors, loc)`
(`checker/type_syntax.lua`) is the usual sink entry. It calls `trycoerce`,
asserts that an accepted non-identity decision is stored on the returned
node, and passes that decision to
`checkmatch(term, expected, exp, errors, loc, prepared, precise_error)`
(`checker/common.lua`), which never asks the relation again. Rejection emits
the contextual mismatch named by `term` (`assignment`, `return`, call
argument, and so on). `precise_error` is set when a C
qualifier/category/probe diagnostic or an Interface satisfaction failure was
already reported, and suppresses only the duplicate generic mismatch. Open
runs keep their shared plan on the list consumer instead.

Numeric `for` bounds are not assignment sinks: after Option forcing they use
`check_exact_match`, so neither numeric conversion nor a gradual `value` view
can reach the C control representation.

## Rewriting the AST

This is the load-bearing design. **Invariant:** after `checker.check`
succeeds, every accepted nonidentity semantic edge has a plan. A
representation-changing fixed conversion and every finite non-exact callable
edge is an annotated `Ast.ExpCast`; only same-representation Array/Map gradual
views retain `_assignment_adjustment`; every finite consumed call result beyond
the first is an explicit `Ast.ExpExtra`; and each shared list consumer carries its
finite/open element adjustment. Numeric `for` loops have explicit steps and
generic `for` loops have hidden iterator tuple/call declarations. The coder
consumes these decisions and does not call a semantic relation.

### `trycoerce`, `tryforce`, `trytostr`

`trycoerce(source, target, errors, use, precomputed_adjustment)`
(`checker/type_syntax.lua`) returns `(exp, adjustment, precise_error)`. After
the C mutable-address special cases, it obtains one decision from
`checker_assignment_adjustment` (`assignment_adjustment` plus Interface
satisfaction), unless the caller passes a precomputed `Maybe3` decision, and
reifies it:

| Decision | Returned expression |
| --- | --- |
| identity | the original expression |
| structural `gradual_view` (Array/Map) | the original expression, with `_assignment_adjustment` |
| `callable` | `Ast.ExpCast` with `_adjustment` and `_callable_adapter` from `checker.freeze_callable_adapter` |
| `gradual_view` inject/project | `Ast.ExpCast` with `_adjustment` (and `_interface_conversion` for Interface wrapping) |
| `direct_coercion` | `Ast.ExpCast` whose `_adjustment` carries the complete `CoercionPlan` |
| `written_cast` | `Ast.ExpCast` with `_adjustment` and `_written_cast` |
| none | the original node, or a checked unsafe C-pointer conversion carrying `_c_conversion`; `checkmatch` reports a rejection |

Every synthesized cast has `_implicit_coercion = true`. The marker
distinguishes a demanded sink conversion from a written `as` cast when a
finite flexible-return budget discards a tail result after evaluating its
source carrier. An Option plan (`option_map`, `option_force`, `option_wrap`,
`option_nil`, `to_c_tvalue`) is one outer `ExpCast` whose plan records the
inner operation, and the coder lowers the present-value branch from that
record rather than from source and target tags. A same-representation Option
view is consumed at its sink: nil passes, and a present payload is strictly
guarded as the target base.

`tryforce(node)` wraps an Option-typed node in an `ExpCast` to its base,
carrying the `assignment_adjustment` projection: the implicit "must not be nil
here" check. It is applied to:

* numeric `for` bounds and step, and the generic-`for` iterator slot;
* unannotated `local` and module-variable inference, so inference never
  produces an option;
* `VarDot` receivers, `VarBracket` indexees, and spread subjects;
* method-call and method-reference receivers whose type is an Option of a
  nominal, and callees whose type is an Option of a function;
* the `case` scrutinee;
* the operands of `#`, unary `-`, `~`, `..`, relational comparisons,
  arithmetic, `/`, `^`, and bitwise operators.

`==`/`~=` operands are not forced ([Option-type machinery](#option-type-machinery)).
`trytostr(node)` wraps an Integer or Float node in a cast to String with
`_operator_conversion` `number_to_string`; only `..` uses it. `truthiness`
records the `truthiness` operator conversion for logical operators.

The contexts that call `trycoerce` are: declaration initializers, assignment
RHS, returns, call arguments, index expressions, initializer-list entries,
record fields, top-level variable initializers, generic-`for` tuple slots
and visible variables, plus the operator-specific promotions (catalogued in
the [type system chapter](../language/types.md)). A contributor adding a
context must preserve the selected plan through `checkmatch` and code
generation.

### `ExpExtra` — materializing finite call results

Wherever finite demand consumes a trailing call beyond its first visible
result, `finite_result_expressions` (`checker/expression_lists.lua`)
synthesizes `ast.ExpExtra(loc, exp, index, _type)` nodes, each coerced and
matched like any expression:

```lua
local a, b = f()   -- f(): (integer, integer)
-- node.exps becomes { ExpCall(f), ExpExtra{exp = <that call>, index = 2} }
```

For a declared fixed result the coder reads the corresponding out-parameter.
A position reached through `flexrettype` is possibly absent and typed
`optionize(T)`. Open consumers do not synthesize `ExpExtra` lists; the call
instead receives `_open_results`. When an open-run element adjustment is
callable there is no per-element `ExpCast`: the checker freezes one shared
adapter at the owning source location. The call annotations behind this
(`_types`, `_flexrettype`, `_callee_type`, `_visible_types`,
`_result_sources`) are listed in
[Declared call shape versus visible call shape](flexible-returns.md#declared-call-shape-versus-visible-call-shape).

### Shared finite/open expression-list demand

Declarations, assignments, returns, positional calls, positional
Array/integer-Map constructors, and the generic-`for` tuple all go through
`result_demand(fixed, tail, opts)` and `adjust_explist(exps, demand, st,
errors)` (`checker/expression_lists.lua`). Only the final expression may
expand into a runtime-sized `open_source`; surplus written expressions stay
checked and are marked `_discard_results`; finite projections of flexible
producers, `...`, and spreads are typed `T?`. The demand record and its
options (including the generic-for-only `dots_nilfill`), the result fields,
and the per-consumer annotations are specified in
[Flexible returns](flexible-returns.md#one-finiteopen-result-demand);
`...` and spread projections are in
[Variadic parameters](variadic-parameters.md#shared-finiteopen-expression-list-demand)
and [Spread expressions](spread-expressions.md#checker-planning).

The three open sinks are an input-vararg call tail, a flexible return tail,
and the final positional field of an Array or exact integer-keyed Map. A
positional constructor classifies its open element edge once, after inference
has selected the final element type, so no provisional plan is overwritten.
An Array constructor also records the element `DynamicCoercionPlan` for its
Lua writer and rejects raw-pointer elements that have none
([Dense arrays](dense-arrays.md)). Computed Map/record fields and named-call
fields are scalar finite consumers: each consumes only its expression's first
result and never receives `ExpExtra` expansion.

### Call argument adjustment

`call_signature` (`checker/c_types.lua`) is a checker-private view of a
callable, not a type conversion. A `Type.Function`/method view exposes fixed
params/results plus Titan `varargtype` and `flexrettype`; a `Type.CFunction`
view exposes C parameters, zero or one visible result, and a separate
`c_vararg` flag. The view never enters the type algebra or code generator.
The direct-C call branch is selected by C-module member provenance, and the
C-pointer branch by `CPointer(CFunction)`; neither can reach callable
adjustment, gradual callable guards, branding, or generic Lua dispatch.

`checkargs` (`checker/variables.lua`) applies the shared demand to that view's
fixed parameters and optional input tail. A Titan fixed-parameter deficit is
filled with synthesized `Ast.ExpNil` nodes, then coerced and matched exactly
like written nils. Surplus Titan expressions are retained for effects but are
not passed to a fixed callee; an input-variadic callee receives them in its
tail. A trailing flexible-result producer can therefore supply a finite fixed
prefix or feed an open input tail.

Nil padding and downward adjustment apply only to Titan function calls.
Parenthesized foreign C calls and C pseudo-constructors pass
`allow_missing=false` to `checkargs`, preserving C-style explicit arity. A
trailing producer may be truncated to the exact remaining C formal count, but
an open runtime-sized run cannot cross the C-vararg boundary. A trailing `...`
into a non-variadic Titan call is expanded with `ExpDotsIndex` nodes; for slots
that accept nil, the indexed read uses nil-fill mode, so an under-supplied
runtime tail behaves like the same short call written without `...`. The
variadic-callee start-adjust path applies the same present-element coercion
and nil-fill decision when it borrows fixed parameters from a forwarded `...`.

### Named-call elaboration

Brace calls stay `ArgsNamedFunc`/`ArgsNamedMethod` until the `Ast.ExpCall`
checker has resolved the callee. `named_function_metadata`
(`checker/variables.lua`) accepts targets by declaration provenance, and
`check_named_args` (`checker/calls.lua`) maps fields to formals, synthesizes
`_named_omitted` nils for absent nil-accepting formals, and replaces the
payload with dense `ArgsFunc`/`ArgsMethod` plus `_named_arg_order` and
`_named_call_kind`. Eligibility (including union-variant part names),
omission, the `_surface_named_args` tooling edge, and lowering are specified in
[Named arguments](named-arguments.md#checker-elaboration).

### Source semantic bindings

The checked AST retains a narrow set of private source-tooling edges alongside
ordinary `_type` annotations. `_decl` binds variable uses, declarations,
record/Interface fields, union variants and case arms, method/static names,
alias namespaces, type spellings, and retained named labels to a canonical
source or `Type.*`/`Checker.*` descriptor. Qualified type and alias spellings
also carry `_module_decl`; method/static declarations carry `_owner_decl`.
With `checker.check(..., { analysis_only = true })`, checking preserves
source-level expression types and the written `typeparams`/`typeargs` lists,
including applied constructor selectors such as `Packet<|integer|>.moved`.
The driver forwards this option for analysis resolver contexts, and the AST
carries `_analysis_only = true` even when checking reports errors. Successful
checks still freeze the declared module/node annotations and the declared
owner registry for semantic clients and compact manifests. Native compilation
omits the option; generic lowering then moves written binders and
applications to `_surface_typeparams` and `_surface_typeargs`, clears the
public lists, and produces the erased registry the coder requires. These
descriptors and lists are neither serialized ABI nor codegen input; the
driver's language-server API version guards consumers that rely on them
([Language-server compiler API](driver.md#language-server-compiler-api)).

### Default `for` step

`checkfor` (`checker/statements.lua`) synthesizes a literal `ExpInteger` or
`ExpFloat` of value 1, matching the control variable's type and located at the
finish bound, into `node.inc` when the step is missing, so the coder always
sees three bound expressions. The bounds are `tryforce`d but never
`trycoerce`d: `check_exact_match` compares them with the control type, so
`for i = 1, 10.0` is a compile-time error rather than a promotion.

### Generic `for` tuple elaboration

`checkforin` turns `for decllist in explist do block end` into an
elaborated `Ast.StatForIn` that codegen can lower without type decisions.
It checks the written expressions under a finite four-slot demand, adjusts a
trailing call, `...`, or spread through the shared machinery, discards values
beyond four, and pads missing slots with typed `Ast.ExpNil` nodes.
The four slots are iterator, state, initial control, and close.
Consequently, when a sole call through `value` supplies the tuple, it receives
the contextual result type `(value, value, value, value)` before the individual
slots are elaborated.

For `iter, ...`, the vararg spread is adjusted only through the tuple slots
the iterator needs (state and initial control), then the remaining tuple
slots are padded with static nil. This tuple demand sets `dots_nilfill` to a
predicate that is true for slots 1–3 (`checker/statements.lua`), so absent
state/control values borrowed from `...` become nil instead of using the
raising read retained by ordinary fixed call arguments. Writing
`iter, state, init, ...` reaches the fourth slot and can supply the close
function from the spread; that close projection keeps the raising read.

The iterator slot may itself be an optionized projection from a flexible
tuple producer, so it is forced before callable resolution. It must then
resolve to a callable shape: a non-variadic `Type.Function`, a `value` coerced
to a synthesized function type, or a `CPointer(Type.CFunction)`. A direct
foreign iterator or close name is contextually decayed to the exact pointer in
the hidden tuple slot before this resolution; a pre-existing C pointer remains
unchanged. Both C forms use the checker-private signature view and retain the
`Type.CFunction` in `_c_pointer_call`. The synthesized type for a `value`
iterator uses the non-`nil` state/init slots
as zero, one, or two parameter types, and uses the visible declaration list
as return types, filling unannotated positions with `value`. A statically
typed iterator may satisfy later visible declarations from optionized flexible
projections. The iterator returns at least one visible value. Its first return
is the control result and must be nil-capable: an option type, `value`, a
nullable C pointer, or a raw C `TValue`; `nil` alone and non-nil-capable
concrete types are rejected. State and initial control are coerced and
matched against the iterator's first and second parameters when those
parameters exist.

The close slot must be `nil` or another callable shape. A `value` close slot
is coerced to a synthesized close type using the state slot as its single
parameter when the state is not statically `nil`, otherwise to a zero-arg
close type; the synthesized close has no returns. Statically typed close
functions and C function pointers may accept zero or one parameter. If they
accept one, the state value must coerce to it. Any close returns are
accepted but discarded. Before coercion, the checker remembers whether the
slot originated as `value`. Such a slot is a potential close, so `_has_close`
remains true, while `_runtime_optional_close` tells codegen that run-time
`nil` is the absent-close sentinel. A statically function-typed close does not
receive that sentinel rule.

The checker then synthesizes:

* `_tuple_decls`: hidden declarations holding the four adjusted tuple
  values, so `<explist>` is evaluated once.
* `_result_decls`: hidden declarations holding every iterator return value.
* `_init_call` and `_next_call`: synthesized calls through the hidden
  iterator. Function values go through the ordinary function-value path; C
  function pointers carry `_c_pointer_call` so codegen uses the FFI pointer
  path. The update call forces the previous control result before coercing it
  to the iterator's second parameter, because loop entry has already proved
  it is not nil.
* `_close_call`: an optional synthesized call through the hidden close
  function, marked `_voidok` because close returns are ignored.
* `_visible_stat`: a synthesized `StatDecl` that initializes the
  user-written variables from `_result_decls` on each iteration.

The visible variables are declared in the loop body's scope and marked
`_forcontrol`, making assignment to them the same compile-time error as for
numeric `for` variables. The first visible variable is initialized from a
forced control result. Later variables are initialized from matching return
positions; if a position is missing, only an explicitly annotated variable
can receive the synthesized `nil`, because an unannotated declaration would
have no type to infer.

### `ExpAdjust` — truncation to one value

The parser wraps a parenthesized *call* or exact input-vararg `(...)` in
`Ast.ExpAdjust`. For a call, the checker passes a one-result demand explicitly
to the child and exposes only that scalar type. This keeps `(f())` finite even
inside an open sink; a flex-only producer therefore projects its first `T?`
rather than forwarding its run. For `(...)`, the checker replaces the child
with a nil-filling `ExpDotsIndex(1)` of type `optionize(T)`. It therefore also
contributes exactly one scalar: the first input argument, or nil when absent;
an ordinary required `T` context applies the standard Option force.

## Option-type machinery

Two helpers maintain the option invariants:

* `optionize(t)` returns `t` unchanged when it is already an Option **or is
  `Type.Value`** (so `value?` ≡ `value` — a `value` already includes nil);
  otherwise `types.Option(t)`.
* `deoptionize(t)` unwraps one level and *asserts* that the base is not
  itself an Option. Because options are only ever constructed through
  `optionize`, `Option.base` is never an Option — code may rely on it.

De-optionization is applied silently where nil-tolerance lives in the
operation, not the type: Array element types (`{integer?}` means
`{integer}`), Map value types, and initializer-list context types. Map *key*
types reject Nil and Option with errors. In the other direction, every
array/map indexing **read** is optionized: `arr[i]` has type `elem?` and
`m[k]` has type `values?` — and since the same type is used when the element
is an assignment target, writing `nil` into an element (deletion) typechecks.

Inference never produces an option unless asked: in an un-annotated `local`,
the initializer is `tryforce`d before its type is copied; the parsed `?`
marker (`local y? = arr[1]`) flips that to `optionize(exp._type)`:

```lua
local x = arr[1]   -- x : integer  (forced)
local y? = arr[1]  -- y : integer?
```

Equality keeps options rather than forcing them. In `==`/`~=`, if either side
is an Option, each side is first lifted to the option of its own type (`s? ==
s` lifts the right side to `string?`). The exception is Nil opposite an
Option: the Nil expression is coerced directly to that existing Option with
the ordinary `option_nil` direct-coercion plan. This preserves an absent Option
in its selected carrier instead of constructing an incomparable `nil?`. The checker then
calls the symmetric `types.comparable` classifier on the adjusted pair. A
successful ComparisonPlan may carry a gradual injection when exactly one
comparable operand is Value; only
then is the other operand boxed into the common equality representation. Code
generation normally compares that representation raw, but retains the plan's
original operand types so a Map/`value` pair can add Lua table `__eq` after a
failed raw check. A `value`/`value` pair remains raw. The checker never uses a
directional assignment or coercion to make any other incomparable original
pair comparable. Numbers are **not** promoted: a mixed Integer/Float pair (either
order, and likewise two options over Integer/Float) is compared by
mathematical value, exactly as Lua does. Any remaining incomparable pair
errors, and the result is always Boolean.

Every Array/Map `Ast.VarBracket` read also carries `_read_guard` for its
optionized result type. Function declarations, methods, bound-method
trampolines, and lambdas carry parallel strict GuardPlan arrays for fixed and
variadic parameters; generic call nodes carry strict fixed/open result guards.
Computed plan annotations use explicit `Maybe3` states (`titan-compiler/maybe3.lua`):
constructors start with `unknown`, checking records `none` or `just`, and
dense arrays retain a state for every slot. Code generation requires a checked
state before unwrapping a plan. These strict annotations are distinct from
the dynamic plans used by genuine Lua entries and non-Titan callable results;
frozen callable adapters reuse them as described in
[Closure adjustment wrappers](closure-adjustment-wrappers.md#checker-elaboration).

`or` implements option defaulting: when the left side is `t?` and the right
side's type equals `t`, the whole expression has type `t` (`of or 1.0` with
`of: float?` is a `float`). The full `and`/`or` case ladders (Boolean
contexts, statically truthy/falsy left sides, optionizing the right side of
`and`, Value mixing) live in `checkexp`'s `Ast.ExpBinop` handler and are
specified case-by-case in [option types](../language/option-types.md).

## Closures: capture analysis and lambda inference

Anonymous functions (`Ast.ExpFunction`) add two pieces of work to the
checker: deciding which enclosing variables each lambda **captures** (and
whether each captured variable is mutated, which the coder needs to choose
the boxed representation), and **inferring** a lambda's missing parameter
and return types.

### Function-nesting tracking

The symbol table is a flat block stack with no notion of function
boundaries, so the checker keeps its own `func_stack`, reset by
`checker.check`. `checkfuncbody` (`checker/declarations.lua`) pushes a frame
`{ depth, captures, capture_set, node, module_initializer }` before it
declares `L`, `M`, `self`, and the parameters, so they are stamped with the
function's own depth, and pops it after the body. Every local, parameter, and
`self` `Decl` records `decl._funcdepth = #func_stack` (locals in `declare`,
the rest in `checkfuncbody`).

`checkfuncbody` adds `$function` to the current block. `checkbodies` wraps
each top-level body in `with_block`, and the `Ast.ExpFunction` handler
(`checker/expressions.lua`) opens its own block around `checkfuncbody` and
publishes the lambda's `_type` first, so `StatReturn` finds the result shape
and `$function` never leaks into the enclosing scope.

### The capture flags

For each in-function local/param `Decl`:

* `decl._assigned` is set when the variable is assigned after declaration
  (in `checkvar`). The numeric-`for` control variable's implicit increment
  does **not** set it, so a captured `for` variable stays immutable (and
  thus by-value, fresh per iteration).
* `decl._captured` is set when the variable is referenced (read or write)
  from a function nested inside its declarer.
* `decl._used` is **forced true** when a decl is captured, so a variable
  only *written* (never read) by an inner function still passes
  `StatDecl`'s `_used` gate and gets its box allocated.

Capture detection lives in **one place**, the `Ast.VarName` visitor
(`checker/variables.lua`), which covers reads and assignment targets. A
resolved `Ast.Decl` (top-level variables, functions, and module members have
other tags and are never captured) with `decl._funcdepth < #func_stack` is a
capture. A C aggregate variable, or a variable whose mutable C address was
taken, is rejected instead. Otherwise the visitor sets `_captured`/`_used` and
adds the decl (first-seen order, deduped via `capture_set`) to the `captures`
list of **every frame in the inclusive range
`[decl._funcdepth + 1 .. #func_stack]`**. The inclusivity threads a
transitively captured variable through the intervening lambdas to the deepest
one that uses it. The pass is a single in-order traversal, so by the end of
`checkbodies` every flag and capture list is final.

The lambda handler copies the frame's list to `node._captures` and rejects
more than 250 captures (`function captures too many variables (%d, max
250)`); the closure layout that sets this limit is in
[Closures and captured variables](codegen-overview.md#closures-and-captured-variables).

### Lambda contextual inference: checking vs synthesis mode

The `Ast.ExpFunction` handler reads the fourth `context` argument received by
`checkexp`. It selects a usable expected type only when `context` is a
`Type.Function` whose fixed arity matches the lambda's `nfixed` count (the
trailing input-vararg declaration is excluded). With that expected type the
lambda is in **checking mode**; otherwise it is in **synthesis mode**. This is
the `local x: T = exp` versus `local x = exp` distinction lifted to lambdas.
Inference is context-only: the checker never reverse-engineers a type from the
lambda body's `return` statements.

* **Fixed parameters.** An annotated parameter uses its annotation. An
  unannotated one takes `expected.params[i]` in checking mode and otherwise
  receives `cannot infer type of parameter '%s'; annotate it or use the
  lambda where its type is known`.
* **Input vararg.** An explicit `...: T` wins. A bare trailing `...` takes
  `expected.varargtype`; a non-variadic expected type or synthesis mode
  receives a `cannot infer the type of '...'` error.
* **Result shape.** An explicit `node.rettypes`/`node.flexrettype` pair is used
  as written. In particular, the parser's empty-list representation of explicit
  `: ()` is truthy and therefore fixes the zero-result shape. With syntactic
  omission (`node.rettypes == nil`), checking mode copies both
  `expected.rettypes` and `expected.flexrettype`; synthesis mode defaults to
  empty/nil, exactly like an unannotated named function.

The complete result shape is installed before the body is checked. `StatReturn`
checks and coerces body results against that finite/open demand. In a
synthesis-mode zero-result lambda, `return <expr>` evaluates the expression
under discard demand and exposes no result. For an inferred non-nil result, the
ordinary all-paths-return rule still rejects a body that may fall through.

After the handler publishes the lambda's `Type.Function`, the surrounding sink
runs its ordinary `trycoerce`/`checkmatch` path. Usually an omitted annotation
makes the lambda exact for its context and needs no callable wrapper. An
explicit `: ()` may instead create a zero-result source that is adjusted to a
nil-accepting result-bearing target through the checker-frozen callable plan.

## Per-construct notes for contributors

* **The `context` parameter.** `checkexp(node, st, errors, context)` threads
  an *expected type* down the tree. It is not inference: literals ignore it
  (`10` in a float context is still an Integer that then gets a cast), but
  `Ast.ExpInitList` needs it to decide what `{ ... }` *is* — the context is
  `deoptionize`d, its tag picks the Array/Map/record branch, and only a
  Nominal context permits a record constructor (`no context to provide type
  for record constructor`). With no useful context the shape decides
  (computed keys → Map, named fields → record error, otherwise Array; an
  empty `{}` defaults to `{integer}`). A nonempty positional Map requires an
  exact integer key type from context. Mixed field categories are rejected
  before elaboration; an all-positional Array or integer Map then runs
  `adjust_explist` exactly once, classifies its deferred open edge exactly
  once after selecting the final element type, and records
  `_positional_adjustment`.
  A Boolean context also switches
  `and`/`or` into plain boolean mode.
* **Length classification.** `Ast.ExpUnop` accepts `#` for an Array, a String,
  countable C forms, or a Map whose resolved key type is exactly
  `Type.Integer`; other Map key types get `trying to take the length of a map
  with key type %s instead of an integer-keyed map`. Map length lowering is in
  [Length (`code_map_length`)](codegen-constructs.md#length-code_map_length).
* **Const lvalues.** `check_const_assignment` (`checker/statements.lua`)
  rejects assignment to const locals, const module variables (outside the
  owning root initializer), const record or Interface fields, and indices of
  `const { T }`. The raw record constructor remains the initialization path
  for const fields, including inside an explicit `new` override. C lvalue
  analysis also rejects mutation or mutable address/decay through a const
  binding's inline aggregate or array storage; pointer and owner pointees
  remain shallowly mutable.
* **Record constructor omissions.** In a Nominal record context, explicit
  visible fields are checked in source order. Each absent field that accepts
  nil (`types.assignment_adjustment(Nil, field)`) is appended as a coerced
  `ExpNil` marked `_named_omitted` with its `Type.Field` in `_field`. A record
  with any local field is wholly unconstructible by `{...}` outside its
  defining module, before per-field omission is considered. Overriding `new`
  imposes the same module-only rule independently of field visibility,
  including through an explicit source import.
* **Function values.** A name of type `Type.Function` used as an expression
  yields a function value. A callee that is not a `VarName`/`VarDot` resolving
  to a top-level function, module member, or static is a function-value call
  checked against its type; a callee of static type `value` receives a
  synthesized positional function type from its arguments and surrounding
  result demand, then rejoins the same path. `typefromnode` turns
  `Ast.TypeFunction` annotations into `Type.Function`. A bare `obj:method`
  is a bound method reference: the method's `Type.Function` without `self`.
  The checker rejects assigning to a function *name*, taking a foreign
  function as a value or binding a foreign method
  ([the FFI chapter](../language/ffi.md)), a method reference on a non-record
  receiver or to a missing method, and using a record type or a module as a
  value. A top-level `local x = function … end` passes `isconst` because
  constructing the closure does not read the body; `x` is a reassignable
  module variable.
* **Conditions are not coerced.** `if`/`while`/`repeat` conditions are
  checked with a Boolean context but never `trycoerce`d or `checkmatch`ed:
  any type is a legal condition, and truthiness is the coder's problem.
  `repeat`'s condition is checked inside the body's scope, so it can see the
  body's locals.
* **Union construction and dispatch.** Synthesized variant statics are
  ordinary first-class `Type.StaticMethod` values whose published
  `paramnames` are the ordered part names, so named calls work through the
  ordinary path ([Named arguments](named-arguments.md#checker-elaboration)).
  `Ast.StatCase` checking, including binding scope, is specified in
  [Case checking and control flow](unions.md#case-checking-and-control-flow);
  missing variants are permitted, an unmatched `case` without `else` is a
  no-op, and its non-fallthrough result is below. `isconst` recognizes a record/union
  constructor only after its synthesized nominal metadata validates against
  the owner projection, and only when all arguments are recursively constant;
  an arbitrary static returning the owner is not a module constant.
* **Written `as` casts and `is` tests.** Both visitors call
  `check_explicit_cast_relation` (`checker/calls.lua`): it resolves the
  target, checks the operand under that target context, and stores a complete
  `_written_cast`. `types.written_cast(source, target)` supplies every
  type-only case. Expression-dependent C operations are completed here:
  mutable address-taking requires a local/formal operand, and an unrelated
  object-pointer cast embeds its successful toolchain probe annotation; a
  candidate without its probe is never a complete written plan. A `value`
  source embeds the target's `DynamicCoercionPlan`; `as` lowers its converting
  form and `is` the same plan's non-raising predicate. Other written views
  keep their view/adjustment plan, and direct coercions keep the complete
  recursive `CoercionPlan`, so `is` mirrors failing float-to-integer/Option
  compositions instead of treating every admitted cast as total. The
  `value`-to-raw-C-pointer operation is written-only. `ExpCast._type` is the
  target; `ExpIs._type` is `Type.Boolean`, and `is` does not narrow the
  operand or symbol-table type. A rejected cast uses `cannot cast '%s' to
  '%s'`; a mutable-address attempt on a C rvalue reports that the expression
  is not addressable. `Type.Variant` is never a source-resolvable type, so
  annotations, aliases, `as`, and `is` may name `Message` but not
  `Message.move`; `case` is the only variant test.

## Non-fallthrough analysis

Every `checkstat` handler returns whether control is guaranteed not to reach
the following statement. `StatReturn` and `StatRaise` return `true`; `StatIf`
returns `true` only if every then-block is non-fallthrough *and* an `else`
exists and is non-fallthrough. `StatCase` can also prove non-fallthrough from
the closed variant set of its `Type.Union` (all arms terminate and either
cover `nvariants` or a terminating `else` exists); the rule is in
[Case checking and control flow](unions.md#case-checking-and-control-flow).
`StatTry` uses its body/catch/finally rule from
[Error handling](error-handling.md#checker-rules). The result is cached on
every statement as `_always_returns` by `checkstat`
(`checker/statements.lua`), and it is the shared checker-to-coder
reachability fact for direct terminators and compound `StatBlock`, `StatIf`,
`StatTry`, and `StatCase` nodes. Despite its name it is also true after a
`raise` and a proven infinite loop. A bare `do … end` propagates its own
fold, so `do return 1 end` is non-fallthrough.

`StatWhile` is non-fallthrough only when its condition is the literal `true`
and no reachable `break` targets that loop. The checker maintains one flow
frame per enclosing loop, so a break in a nested loop marks only that nested
frame. Since statement-list checking stops after a proven terminator, a break
in a dead tail is not recorded. Other `while` conditions and every other loop
form remain fallthrough. The ordinary `StatTry` composition is essential: if a
catch covers the loop, a falling-through catch keeps the construct fallthrough,
while a non-fallthrough catch preserves the proof.

`checkblock` folds the results with `ret = ret or checkstat(stat, st,
errors)`. Because of the short-circuit, once `ret` is true **later statements
in the block are not visited at all**. A plain `return` can only be a block's
final statement (the grammar enforces it), but a non-fallthrough `if`/`else`,
`case`, `try`, or literal-true `while` mid-block makes the case reachable.
*Limitation:* statements in such a dead tail go completely unchecked, so a
type error placed there is not reported. The checker performs no dead-code
analysis to flag or prune them.

`checkfuncbody` consumes the result. Zero-return and flex-only functions may
fall through, as may a function whose complete fixed prefix is exactly one
`Type.Nil`; a flexible tail on that last shape is independently empty. Every
other fixed-result shape must be non-fallthrough. A single non-nil result uses
`function can return nil but return type is not nil`; a multi-result shape uses
`function can fall through but return type requires N fixed values`. The same
one-fixed-`nil` predicate tells `adjust_explist` to synthesize an ordinary nil
source for a bare `return`. It never nil-fills a multi-result prefix. Functions
declared without a return annotation default to **zero results** (`function (): ()`).

## Imports and the loader protocol

`Ast.TopLevelImport` is checked by
`checker.checkimport(modname, loader, request)`. The parser has already removed
a terminal `.titan` marker from `modname`; `checker/declarations.lua` passes
`{ kind = "source-import" }` only when the AST's separate `source_required` bit
is true.
The loader contract is:

```lua
loader(modname, request)
    --> ok, moduletype_or_error, errors, import_info
```

The staged declaration pass invokes every import in AST order before resolving
records and callable signatures, so an import alias is available to every
non-module-variable declaration even when the import node occurs later. The
sequential frontier still holds for module variables (see
[the symbol table](#the-symbol-table-symtablua)).

On success, the import node's `_type` is the returned `Type.Module`, and
errors found while checking the dependency propagate into this module's
error list. On loader failure the import reports `problem loading module
'%s': %s`. `_source_import` is set only when the import was written as a
source import, `import_info.kind == "source"`, and the module type carries
`_source == true`; neither half alone grants private visibility
([Source-import visibility](source-import-visibility.md)).

`checker.checkimport` (`checker/imports.lua`) hands the recovered module to
`checker.register_module_interface`, which registers direct `Type.Interface`
descriptors from `type_members`, then walks both namespaces and registers
referenced records and unions in `types.registry` under their fqtn. For a
complete interface it also derives the public module-userdata prefix
([User-value allocation](codegen-overview.md#user-value-allocation)) and
stamps public static descriptors with `_upvalue`/`_closure_upvalue`, so a
record/union selector reached through a type alias can use the owner's
constructor or static as a direct call or first-class function without an
alias-side slot. This registration is what makes a nominal type from a
compiled dependency (no `.titan` source to re-check) usable. A dependency with
source registers the same owners as a side effect of its own recursive
`checker.check`.

A `Type.Nominal` carries *only* its fqtn string and resolves through the
process-global registry at every use, so the qualified type `geo.Point`
(`Ast.TypeQualName`, converted by `typefromnode` to
`types.Nominal("geo.Point")`) means something only because checking or
importing module `geo` registered `"geo.Point"`.

The loaders are `driver.defaultloader` (production; caching in
`driver.imported`, `CIRCULAR_MARK` cycle detection, provider selection, and
interface recovery) and `driver.tableloader` (specs; it round-trips every
checked module's public type through `types.serialize` and `load`). See
[`driver.defaultloader`](driver.md#driverdefaultloaderstatic_deps-options),
[Interface recovery and the closed validator](driver.md#interface-recovery-and-the-closed-validator),
and [`driver.tableloader`](driver.md#drivertableloadermodtable-imported-deps-options).
The serialized form is described in
[Lua entries and ABI, type, and layout metadata](codegen-overview.md#lua-entries-and-abi-type-and-layout-metadata).

### The foreign environment

An unbound `Ast.TopLevelForeignImport` contributes a header directive to the
module C environment. After loading explicit source dependencies,
`check_foreign_environment` (`checker/declarations.lua`) prepares the ordered
`A.ffi.h` environment, including source foreign typedefs, validates its final
declarations through `cdriver.process_module`, converts them with
`foreigntypes.convert`, and builds the one `Type.CModule("ffi", members,
type_members)`. Direct functions keep `Type.CFunction`; function-pointer
values keep `Type.CPointer(Type.CFunction)`; neither is projected to
`Type.Function`. C type declarations become `type_members`, which allows
annotations such as `foreign size_t` ([FFI internals](ffi-internals.md)).

Before conversion, the complete TypeList supplies syntactic typedef-name and
file-scope tag metadata. A named tag-only struct/union with no same-name real
typedef is published directly through its canonical `struct@T` / `union@T`
owner, without a fake `CTypedef`. Actual C declaration order determines whether
a prototype refers to a file-scope tag or owns a prototype-local tag. Include
guards and macros determine which declarations occur; the checker does not
merge independent header snapshots.

All final C names and complete aggregates are available even to earlier
module-variable initializers. The complete-object predicate protects by-value
parameters/results/locals/casts, fixed-array elements, allocation,
`sizeof`/`alignof`, and field lookup. Expression lookup on `Type.CModule` is
value-first: a value/type spelling collision rejects type pseudo-members with
a specific diagnostic while preserving the real function or variable.

The checker also receives the resolver's `cprobe.Service`. After the combined
`.ffi.h` establishes the module C environment, contextual object-pointer
conversions and C operators ask that service to compile their exact
`cdeclarator` spelling; the complete raw probe source keys the cached
acceptance or rejection. The checker records complete conversion/operator
traits and coercion plans on the AST, and the coder consumes them without
repeating target-C reasoning. See
[C FFI declarations and expressions](c-ffi-expressions.md). The checker
derives its C include `source_dir` from the canonical main filename; folder
contributors are immediate siblings of that main, so quoted headers imported
from a contributor resolve against the same directory.

### Export validation

After body checking, `reject_exported_c_ffi_types` and
`reject_exported_local_nominal_types` reject any public type tree, including
an exported alias target, that mentions a local nominal type or a
nonexportable C descriptor. Contextual primitives, portable
pointer/function/owned graphs, and named header-dependent C graphs with a
valid declaration origin are accepted; enum identities, unnamed aggregates,
and flexible-array aggregates are not. For records and unions the walkers skip
private fields/variants, methods, and functions, so an exported owner may keep
a private C-typed member that never enters its interface.

## Process-global state

Two pieces of mutable state outlive a `checker.check` call:

* `types.registry`, the fqtn → `Type.Record`/`Type.Union`/`Type.Interface`
  map. After a non-analysis check, `checker.check` leaves the declared
  (surface) registry installed so the resolver can check further roots; each
  erased AST carries the detached registry its coder invocation installs.
* `driver.imported`, the import cache, including any `CIRCULAR_MARK`
  sentinels left by a failed run.

Any test or tool that checks more than one module (or the same module twice)
must reset them, or nominal types from a previous run resolve in the next one.
`spec/support/helpers.lua` resets `types.registry = {}` (and
`driver.imported = {}` when imports are involved); new specs must follow the
pattern. The parser adds a non-reentrancy hazard of its own, described in
[Non-reentrancy](lexer-parser.md#non-reentrancy).
