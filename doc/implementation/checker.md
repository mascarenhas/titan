# The type checker

The checker takes the AST the parser built (see
[Lexer and parser](lexer-parser.md)) and produces the typed, *elaborated* AST
the [code generator](codegen-overview.md) consumes. The small
`titan-compiler/checker.lua` facade exposes the production checker API and
eagerly assembles the implementation slices under `titan-compiler/checker/`.
`core.lua` owns their one shared private lexical environment and mutable checker
state. Generic helpers stay with their semantic slices under `generic_`-prefixed
private names rather than a `checker._generic` table. The remaining slices group
C types and probes, common type operations, Interfaces, type syntax, expression
lists, statements, variables, calls, expressions, declarations, imported
interfaces, generic lowering, and the final check lifecycle. `types.lua` still
owns type values and relations, while
`symtab.lua` owns scoping. Above all: the checker
does not merely *check* — it **rewrites** the AST so that every implicit
conversion, every finite extra call projection, and every defaulted loop step
exists as an explicit node, while finite/open list demand is recorded on its
consumer. The code generator relies on that completely; it
never decides to coerce anything on its own.

## Entry point and contract

```lua
function checker.check(modname, ast, subject, filename, loader, options)
```

(`checker/entry.lua`, exported directly by the `checker.lua` facade.) It
builds a fresh symbol table with
`symtab.new(modname)`, runs staged top-level declaration collection followed by
body checking (below), computes the module's interface type with
`makemoduletype`, stores it in `ast._type`, and returns **`ast._type, errors`**
— a `Type.Module` and the error list. Callers test `#errors == 0` (as
`spec/checker_spec.lua` does). `loader` is
the import callback (see [Imports](#imports-and-the-loader-protocol)); if
omitted, a stub that fails every import is used. `options` is optional
invocation context; the driver uses it to share the resolver-owned C probe
service and source directory through dependency checks.

For a [folder module](folder-modules.md), `driver.defaultloader` independently
parses all source files and calls this entry point once with one dense combined
AST, the logical module name, and the canonical main's subject/filename. The
checker does not know or create file scopes; contributor filenames remain only
on the existing node locations.

Errors accumulate: nothing aborts on the first problem. The `errors` table is
an array of formatted strings that also carries `subject` and `filename`
fields. Every error goes through `checker.typeerror`, which formats via
`location.format_error`, so every message a user sees has the shape
`FILENAME:LINE:COL: type error: <message>`. When an expression cannot be
given a type, the helper `invalid(errors, loc, ...)` logs the error and
returns `types.Invalid()`, the error-recovery type, so checking continues.
When a duplicate refers to an earlier node, `location.format` adds that
node's complete `filename:line:col`; this is essential when the declarations
come from different contributors.

## The symbol table (`symtab.lua`)

The symbol table is a stack of blocks plus separate side tables for Titan
aliases and C declarations:

* `blocks` starts as `{ {} }`; `open_block`/`close_block` push and pop, and
  `with_block(body, ...)` wraps a call in a scope. `add_symbol(name, decl)`
  writes into the innermost block; `find_symbol(name)` searches innermost-out.
* Ordinary top-level duplicate winners are marked by an AST-order prepass
  before names are reserved in the outer block. `find_dup(name)` still checks
  only the innermost block; local declarations call `add_symbol`, so
  re-declaring a name in the same inner block silently overwrites it, except
  for read-only compiler-synthesized locals such as `L`, which `declare`
  rejects before adding the new symbol.
* `foreign_types` and `foreign_names` are separate namespaces populated by
  `foreign import`, so C typedef and ordinary C names never collide with Titan
  symbols. Their `foreign_type_history` and `foreign_name_history` lists retain
  `{order, decl}` entries for module-variable frontier lookup. Completed
  canonical C struct/union owners also carry `_definition_order`;
  `foreign_definition_visible` prevents an in-place completion performed by a
  later header from exposing fields or allocation eligibility at an earlier
  frontier. A third checker-owned registry holds module-wide file-scope C tags
  by base name/kind/provenance. It reuses same-kind owners across imports,
  rejects cross-import kind conflicts, and stays distinct from both ordinary C
  names and prototype-local tag scopes.
* During a `TopLevelVar`, `initializer_order` makes `find_symbol` hide the
  current and later module variables and later Titan/foreign imports. The C
  lookup helpers scan their histories backward for the last declaration whose
  recorded order is at or before that frontier. Outside this narrow mode,
  lookups return the final module-wide declarations collected by the staged
  passes.
* `st.modname` is stored at construction and used by `typefromnode` to fully
  qualify nominal type names: the written type `Point` inside module `geo`
  becomes `types.Nominal("geo.Point")`.

One combined folder AST creates one such symbol table. Top-level `local`
declarations are consequently private to the logical module but visible from
every contributor; the checker introduces no file-private block.

One pseudo-symbol uses the table as a side channel: `checkfunc` binds
`"$function"` (not a legal identifier, so it cannot clash) to the enclosing
function node, and the `StatReturn` handler looks it up to find the declared
return types.

## Staged top-level collection and body checking

`checker.check` runs `mark_toplevel_duplicates`, `collect_type_aliases`,
`checktoplevel`, and finally `checkbodies`. The AST remains in its original
flat or deterministic combined folder order throughout; the checker changes
visitation order, not node order.

`mark_toplevel_duplicates` assigns every root node its 1-based
`_toplevel_order`, chooses the first ordinary declaration of each name in that
order, reports later duplicates with the first node's full location, and marks
them `_ignore`.

`collect_type_aliases` enters aliases and Interface declarations in the
separate module-wide type namespace. It chooses the first alias/Interface by
AST order and keeps a surviving record or union authoritative over either
same-named type-only declaration regardless of relative placement. This makes
forward aliases and Interface spellings available without creating value
symbols. Lazy alias resolution stores the exact RHS type on the declaration
and detects cycles with a `resolving` state.

`checktoplevel` then performs these stages:

1. `reserve_toplevel_names` publishes every surviving ordinary name before any
   signature needs it.
2. `collect_nominal_constructors` recognizes parser-marked synthesized
   `TopLevelStatic` nodes: one `new` immediately after each `TopLevelRecord`,
   and one positional constructor per variant immediately after each
   `TopLevelUnion`. A duplicate nominal owner also suppresses its constructors,
   preventing secondary namespace diagnostics.
3. All Titan and foreign imports are visited in AST order. This establishes
   module and C type environments before non-variable declarations, while
   `current_toplevel_order` records the origin of each C declaration in its
   symbol-table history.
4. Aliases are resolved, then every record and union is built and registered
   in `types.registry`. Interfaces are built next in declaration order, so all
   nominal owners are available while their method signatures are checked.
   Each synthesized constructor is then attached to its complete nominal
   namespace. Record fields and union payloads share
   `types.has_tvalue_representation`: Titan function values are legal, while
   direct C aggregates, C arrays, direct C functions, and C function pointers
   are rejected.
5. Ordinary function and module-initializer signatures are collected, followed
   by explicit methods and nominal functions. Because names, imports, aliases,
   nominal owners, and synthesized constructors are already available, these
   declarations are independent of their relative AST order.
6. Module variables are checked in AST order. For each node the checker sets
   `st.initializer_order` to its `_toplevel_order`; symbol lookup then exposes
   only earlier Titan/foreign imports and earlier module variables, while all
   other declaration kinds remain module-wide. The type annotation and RHS are
   checked under the same frontier, followed by the ordinary constant-expression
   validation.

Methods and nominal functions still perform their own conflict checks against
fields, variants, and one another. Every failed or duplicate top-level declaration is
marked `_ignore`; everything downstream — body checking, `makemoduletype`, and
the coder — must skip it.

`checkbodies` walks the unchanged AST order. It checks ordinary function,
method, nominal-function, and synthesized-constructor bodies (`checkfunc`, each
in a fresh scope; `checkmethod` first synthesizes a `self` declaration typed as
the owner's `Type.Nominal`). It also validates resolved record fields, union
payloads, and alias targets after all nominal owners have entered the registry;
that is what permits recursive and mutually recursive nominal declarations while still reporting an unresolved
nominal. Module-variable annotations are instead resolved and validated in the
module-variable stage, where every record is already registered but the
import/module-variable frontier is still active. `checkfuncbody` also
synthesizes a read-only local `L` in every function-like body. Its type is
`lua_State *` in the C FFI type family. Ordinary top-level callable bodies see
the complete foreign environment and reuse an imported `lua_State` identity
regardless of the import's placement. A lambda checked inside a module-variable
initializer retains that initializer's frontier, so it reuses only an earlier
`lua_State` declaration and otherwise receives the same opaque fallback type.

After declaration and body checking, `makemoduletype` builds the module's
interface by traversing the original AST order from the
non-`islocal`, non-`_ignore`, non-import top levels (`TopLevelVar` →
`Type.ModuleVariable`; `TopLevelFunc`/`TopLevelRecord`/`TopLevelUnion` →
`Type.ModuleMember`). Public `TopLevelTypeAlias` and `TopLevelInterface` nodes
instead populate the module's separate `type_members` map with resolved RHS
types and canonical Interface descriptors respectively. Interfaces have no
run-time module member or public module-userdata slot. Local aliases and local
nominal members are left out of serialized public interfaces. Private union
variants are omitted while retaining their absolute tags and the owner's total
`nvariants`. See [Type aliases](type-aliases.md) and
[Interfaces](interfaces.md) for the resolution and publication details.

`checker.has_main(ast)` is a post-check used by `titanc` to decide between
building a paired library provider and a standalone executable: it looks for a
`TopLevelFunc` named `main` with exactly one parameter whose checker type is
`{string}` and one return type whose checker type is `integer`. Both the input
vararg and flexible-result tail must be absent. Resolving the fixed types before
this test lets transparent aliases satisfy the entrypoint contract.
Because it examines the one combined list, a valid `main` may be declared in
the folder main or any contributor and still belongs to the same logical
module.

## The relations and plans in `types.lua`

The checker no longer asks one boolean relation to stand for consistency,
automatic conversion, callable assignment, written casts, and equality.
The normative definitions and boundary matrix are in
[Type relations and boundary plans](type-relations-and-boundaries.md).
The checker-facing summary is:

- `types.normalize` cycle-safely removes transparent aliases/typedef wrappers;
- `types.consistent` is symmetric gradual consistency and never calls a
  conversion classifier;
- `types.coercion(source, target)` returns one direct automatic
  `CoercionPlan`, including named Option operations;
- `types.callable_adjustment(source_actual, target_expected)` returns a
  directional shape/component plan, including the narrow `nil_fill_result`
  action when a wholly missing expected result accepts nil;
- the generalized callable freezer turns that raw authority into a closed,
  relation-free adapter graph with component operations, minimal lifetime
  roots, only genuine stack rebases, demand math, location, and trace name;
- `types.assignment_adjustment(source, target)` selects identity, direct
  coercion, gradual view, callable adjustment, or rejection;
- `types.dynamic_coercion(target)` describes the broader conversion authorized
  by written `value as/is T` and genuine Lua boundaries;
- `types.written_cast` and `types.comparable` own written-cast and symmetric
  equality policy; and
- `types.gradual_guard`/`types.has_sound_gradual_guard` keep boxability
  separate from a type that can actually be re-established later.

`types.equals` remains the exact structural/nominal identity test used inside
these classifiers. It does not answer whether an operation is permitted.
The retired `types.compatible`, `types.coerceable`, and
`types.explicitly_coerceable` APIs have no checker callers.

The callable freezer also owns lowering-time lifetime facts. A nested
`callable_view` is `may_raise = true` because `luaF_newCclosure` can allocate,
but `may_relocate = false`: direct construction performs no stack API operation
or ordinary GC poll. Native adapter input-source roots are empty because native
callees/arguments remain C values and the call never publishes tracing-only
copies. Fixed/range destination roots are selected only for newly allocated
wrappers; fixed/open result-source roots cover every live GC-bearing native
result immediately after return. Raw descriptors and C buffers are explicitly
non-roots. Top-level wrapper
construction records only a conditional result root for an eligible exact
Titan clone—never a duplicate construction source root—and the rebase ledger
still always includes the source native call.

Conversion edges are deliberately not consistency leaves. Integer-to-float,
`T`-to-`T?`, C numeric/address conversions, truthiness, and
record/union-to-Interface wrapper construction can be direct coercions without
making the corresponding Arrays, Maps, or callable components consistent.
Conversely, an `integer`/`value` pair is consistent but still needs an
injection or strict projection plan because their representations differ.

### `checkmatch` — consuming the original decision

`trycoerce` returns both the adjusted expression and the exact
`assignment_adjustment` object obtained from the original source/target pair.
`checkmatch(term, expected, adjusted, ..., decision)` consumes that object and
never asks the relation again. Rejection emits the ordinary contextual
mismatch; a checked C conversion that already emitted a qualifier/category/probe
diagnostic carries an explicit marker that suppresses only the duplicate
generic mismatch.

Identity and gradual Array/Map structural views may reach `checkmatch` without
changing the producer's representation. A finite non-exact directional callable
plan must already have produced `Ast.ExpCast`; `checkmatch` consumes its same
raw plan object and does not retain a same-representation callable exception.
Open runs retain the shared plan on their sink. The `term` string still names
the diagnostic context (`assignment`, `return`,
`array indexing`, call argument, and so on). Numeric `for` bounds are not
assignment sinks: after Option forcing they use a dedicated exact-type check,
so neither numeric conversion nor a gradual `value` view can reach the C
control representation.

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

`trycoerce(source, target, errors)` is the workhorse. It calls
`assignment_adjustment(source._type, target)` once:

- identity returns the original expression;
- a same-representation Array/Map structural gradual view leaves the source
  carrier intact and stores `_assignment_adjustment`;
- a non-exact callable decision becomes `Ast.ExpCast` with the child at source
  type A, the cast at target type B, `_implicit_coercion = true`, and the exact
  raw `_adjustment`; the checker also freezes its callable-adapter lowering;
- a `value` injection/projection becomes `Ast.ExpCast` with `_adjustment =
  gradual_view`;
- a direct conversion becomes `Ast.ExpCast` with `_adjustment =
  direct_coercion(CoercionPlan)`; and
- rejection returns the original node so `checkmatch` emits the contextual
  error (with the separate checked C-address path retaining its precise
  diagnostic).

Every synthesized semantic cast also has `_implicit_coercion = true`. The
marker distinguishes a demanded sink conversion from a written `as` cast when
a finite flexible-return budget discards a tail result after evaluating its
source carrier.

Option types retain their explicit lowering shapes, but the relation result
names what happens: `option_map` propagates nil while converting a present
base, `option_force` checks nil before its inner plan, `option_wrap` converts a
present source then boxes it, `option_nil` supplies nil, and
`to_c_tvalue` copies a whole slot without forcing an option first. The checker
emits one outer `Ast.ExpCast` carrying that complete decision. Code generation
consumes its recorded inner identity/conversion plan when lowering the
present-value branch; it does not ask the relation again or infer Option
behavior from source and target tags.

The coder also consumes a same-representation Option view at its sink.
Unlike an Array or Map, an Option has no mutable backing whose element
observations can remain deferred: nil passes, while a present payload is
strictly guarded as the target base before the source base view is forgotten.
Array and Map structural views keep their ordinary deferred component
behavior. Callable components are instead executed by a realized wrapper's
frozen adapter or, on conditional fallback, by the strict generic path.

`tryforce(node)` wraps any Option-typed node in a cast to its base — the
implicit "must not be nil here" check. It is applied at: `for` bounds;
un-annotated `local` and top-level-variable inference (so inference never
produces an option); `VarDot` receivers (`p.x` on a `Point?` forces it);
`VarBracket` indexees (indexing an `{t}?`); and the operands of `#`, unary
`-`, `~`, `..`, relational comparisons, arithmetic, `/`, `^`, and bitwise
operators — but *not* to method-call receivers or `==`/`~=` operands
(equality keeps options, below). `trytostr(node)` wraps Integer- or
Float-typed nodes in a cast to String; only `..` concatenation uses it.

The contexts that call `trycoerce` are: declaration initializers, assignment
RHS, returns, call arguments, index expressions, initializer-list entries,
record fields, top-level variable initializers, generic-`for` tuple slots
and visible variables, plus the operator-specific promotions (catalogued in
the [type system chapter](../language/types.md)). A contributor adding a
context must preserve the selected plan through `checkmatch` and code
generation. The raw/frozen callable contract and conditional allocation are
specified in
[Closure adjustment wrappers](closure-adjustment-wrappers.md#checker-elaboration).

### `ExpExtra` — materializing finite call results

A checked call keeps its declared fixed ABI shape in `_types`, its optional
tail in `_flexrettype`, and the complete callable in `_callee_type`. For a
Titan/Lua call that authority is `Type.Function`; for a direct or indirect C
call it is the authoritative `Type.CFunction`, while C `void` projects to an
empty `_types` list. The consumer-facing finite projection lives separately in
`_visible_types` and
`_result_sources`. Wherever finite demand consumes a trailing call beyond its
first visible result, `finite_result_expressions` synthesizes
`ast.ExpExtra(loc, exp, index, _type)` nodes, each coerced and matched like any
expression:

```lua
local a, b = f()   -- f(): (integer, integer)
-- node.exps becomes { ExpCall(f), ExpExtra{exp = <that call>, index = 2} }
```

For a declared fixed result the coder reads the corresponding out-parameter.
For a position reached through `flexrettype`, `_result_sources` marks the
projection as possibly absent and its type is `optionize(T)` (`value` remains
`value`). Open consumers do not synthesize an unbounded `ExpExtra` list: the
call instead receives
`_open_results = {source_type, target_type, start, adjustment}`.
Computed Map/record fields and named arguments are scalar finite consumers.
The `?`
inference marker still applies per finite declaration slot. When an open-run
element adjustment is callable, there is no per-element `Ast.ExpCast`; the
checker freezes and attaches the shared adapter at the owning source location,
and the coder later validates, registers, and emits that already frozen graph.

### Shared finite/open expression-list demand

`result_demand(fixed, tail, opts)` and
`adjust_explist(exps, demand, st, errors)` own declarations, assignments,
returns, positional calls, positional container constructors, and the
generic-for tuple. `fixed` is dense
(`UNKNOWN_SLOT` means inferred), while `tail` is false, a typed open element,
or `INFER_OPEN`. The result retains every written expression in lexical order,
records delivered `fixed` and `tail_scalars`, marks effect-only `discards`, and
identifies at most one runtime-sized final `open_source` with source/target
types, start index, and the checker-selected element adjustment.

The demand options also carry the deliberately narrow `dots_nilfill` policy.
Generic-for tuple setup sets it so missing state/control positions borrowed
from a trailing input `...` adjust upward to nil. Ordinary fixed call
arguments leave it false: a borrowed variadic element still uses the normal
target-driven raising read unless that destination itself accepts nil.

Only the last expression may expand. A finite sink truncates producer surplus;
written surplus expressions remain checked and marked `_discard_results`, and
a discarded call receives `_voidok`. A fixed-only deficit still reports the
ordinary arity error. A declared flexible producer projects `T?` into finite
slots, while an open sink preserves the actual `T` run. The three open sinks
are an input-vararg call tail, a flexible return tail, and the final positional
field of an Array or exact integer-keyed Map. Such a constructor stores the
shared result as `_positional_adjustment`; its open call/`...` producer also
receives the same `.adjustment`. Constructor open-element checking is
deliberately deferred until inference/context has selected the final element
type: the checker then classifies that edge once and shares the one plan,
rather than creating and overwriting a provisional plan. Computed Maps remain
scalar and do not use it.
An Array constructor additionally records its final context-adjusted element
type and `DynamicCoercionPlan` for the construction-selected Lua writer. A
raw-pointer element, or compound element containing an unguardable
raw-pointer leaf, has no such plan and is rejected at construction. See
[Flexible returns](flexible-returns.md#one-finiteopen-result-demand).

Named-call fields are the exception among call arguments: each field owns
exactly one formal slot, so even the last field consumes only the first result
of its expression and never receives `ExpExtra` expansion.

### Call argument adjustment

`call_signature` is a checker-private adapter rather than a type conversion.
A `Type.Function`/method view exposes fixed params/results plus Titan
`varargtype` and `flexrettype`; a `Type.CFunction` view exposes C parameters,
zero or one visible result, and a separate `c_vararg` flag. The adapter never
enters the type algebra or code generator. The direct-C call branch is selected
by C-module member provenance, and the C-pointer branch by
`CPointer(CFunction)`; neither branch can reach callable adjustment, gradual
callable guards, branding, or generic Lua dispatch.

`checkargs` applies the shared demand to that view's fixed parameters and
optional input tail. A Titan fixed-parameter deficit is filled with synthesized
`Ast.ExpNil` nodes, then coerced and matched exactly like written nils. Surplus
Titan expressions are retained for effects but are not passed to a fixed
callee; an input-variadic callee receives them in its tail. A trailing
flexible-result producer can therefore supply a finite fixed prefix or feed an
open input tail.

The positional nil-padding/downward-adjustment rule is deliberately limited to
Titan function calls. Parenthesized foreign C calls and C pseudo-constructors
pass `allow_missing=false` to `checkargs`, preserving C-style explicit arity.
A trailing producer may be truncated to the exact remaining C formal count,
but an open runtime-sized run cannot cross the C-vararg boundary. A supported
named direct-C call has its own per-name omission path described below. A
trailing `...` into a
non-variadic Titan call is still expanded with `ExpDotsIndex` nodes; for
call argument slots that can accept nil, the synthesized indexed read uses
the nil-fill mode so an under-supplied runtime variadic tail behaves like
the same short call written without `...`. The variadic-callee start-adjust
path applies the same present-element coercion and nil-fill decision when
it borrows fixed parameters from a forwarded `...`.

### Named-call elaboration

The parser preserves brace calls as `ArgsNamedFunc` or `ArgsNamedMethod` until
the `Ast.ExpCall` checker has resolved the callee. `named_function_metadata`
uses declaration provenance—not merely a callable shape—to accept direct
top-level/module functions, record statics, methods, and fixed direct C members.
A foreign member is recognized only when its `Type.ModuleMember.type` is the
authoritative `Type.CFunction`; its names remain on the member descriptor.
Function values, lambdas, bound-method values, C function pointers, C pseudo
constructors, input-variadic Titan declarations, and C variadic declarations
are rejected. A flexible result tail does not prevent a declaration from using
named arguments. A direct C member
whose prototype did not preserve one complete unambiguous name list gets a
separate unavailable-metadata diagnostic.

`check_named_args` visits written fields in lexical order, maps each name to a
formal index, checks/coerces the expression under a finite one-result demand in
that formal's context (so a demand that reaches a flexible tail projects
`T?`), and
reports unknown or repeated names. For every unsupplied formal it synthesizes
an `ExpNil`, requires `nil_can_adjust_to`, applies `trycoerce`, and marks the
result `_named_omitted`. It returns a dense formal-order list plus the lexical
sequence of explicit formal indexes. The checker replaces the temporary named
payload with `ArgsFunc`/`ArgsMethod` and writes `_named_arg_order` and
`_named_call_kind` on the call for codegen. The full metadata and lowering
contract is in [Named arguments](named-arguments.md).

### Default `for` step

`checkfor` synthesizes a literal `ExpInteger(loc, 1)` or `ExpFloat(loc, 1.0)`
(matching the control variable's type) into `node.inc` when the step is
missing, so the coder always sees three bound expressions. The bounds
themselves are `tryforce`d but **never `trycoerce`d** — they are
`checkmatch`ed directly against the control type, so `for i = 1, 10.0` is a
compile-time error rather than a promotion (the old manual claimed
otherwise; this describes the implementation).

### Generic `for` tuple elaboration

`checkforin` turns `for decllist in explist do block end` into an
elaborated `Ast.StatForIn` that codegen can lower without type decisions.
It checks the written expressions under a finite four-slot demand, adjusts a
trailing call or `...` through the shared machinery, discards values beyond
four, and pads missing slots with typed `Ast.ExpNil` nodes.
The four slots are iterator, state, initial control, and close.
Consequently, when a sole call through `value` supplies the tuple, it receives
the contextual result type `(value, value, value, value)` before the individual
slots are elaborated.

For `iter, ...`, the vararg spread is adjusted only through the tuple slots
the iterator needs (state and initial control), then the remaining tuple
slots are padded with static nil. This tuple demand sets `dots_nilfill = true`,
so absent state/control values borrowed from `...` become nil instead of using
the raising read retained by ordinary fixed call arguments. Writing
`iter, state, init, ...` reaches
the fourth slot and can supply the close function from the spread.

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

The parser wraps a parenthesized *call* in `Ast.ExpAdjust`. The checker passes a
one-result demand explicitly to the inner call and exposes only that scalar
type. This keeps `(f())` finite even inside an open sink; a flex-only producer
therefore projects its first `T?` rather than forwarding its run.

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
the ordinary `option_nil` direct-coercion plan. This preserves nil as a boxed
option value instead of constructing an incomparable `nil?`. The checker then
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
Frozen callable adapters reuse those component guards plus explicit minimal
root/rebase and action records. Incoming native values stay in C and borrow their
existing provenance; newly allocated wrappers get immediate destination roots;
every live GC-bearing native source result gets an immediate fixed/open source
root; and direct nested wrapper allocation is not a rebase point. Consumer-local target relays reuse
the strict stack shell. These annotations are distinct from the dynamic plans
used by genuine Lua entries and non-Titan callable results.

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
boundaries, so the checker keeps its own. `checker.check` initialises
`func_stack = {}` at the top (it is reset per check, unlike the
module-global `loop_depth`). A frame `{ depth, captures = {}, capture_set
= {} }` is pushed at the **very top** of the body-check for `checkfunc`,
`checkmethod`, and the `Ast.ExpFunction` handler — *before* the
parameters/`self` are declared, so they are stamped at the function's own
depth — and popped after the body. Every local/param/`self` `Decl` records
`decl._funcdepth = #func_stack` (locals in the single `declare` helper;
params/`self` in `checkfunc`/`checkmethod`).

The lambda handler must additionally open its **own** `with_block` and
`add_symbol("$function", node)` inside it before checking the body (and set
the lambda node's `_type` first, so `StatReturn` can find the return
types). `checkfunc` gets away with adding `$function` to the caller's block
only because `checkbodies` wraps it in `with_block`; a lambda has no such
wrapper, so a naïve copy would leak `$function` into the enclosing scope.

### The capture flags

For each in-function local/param `Decl`:

* `decl._assigned` — set when the variable is assigned after declaration
  (the pre-existing flag, set in `checkvar`). The numeric-`for` control
  variable's implicit increment does **not** set it, so a captured `for`
  variable stays immutable (and thus by-value, fresh per iteration).
* `decl._captured` — set when the variable is referenced (read or write)
  from a function nested inside its declarer.
* `decl._used` — **forced true** when a decl is captured, so a variable
  only *written* (never read) by an inner function still passes
  `StatDecl`'s `_used` gate and gets its box allocated.

Capture detection lives in **one place**, the `VarName` visitor, which
uniformly covers reads and assignment targets. When a resolved name is a
local/param (`decl._tag == "Ast.Decl"` — `TopLevelVar`/`TopLevelFunc`/
module members resolve to other node tags and are therefore never
captured) and `decl._funcdepth < #func_stack`, it is a capture: set
`_captured`/`_used`, and add the decl (first-seen order, deduped via
`capture_set`) to the `captures` list of **every frame in the inclusive
range `[decl._funcdepth + 1 .. #func_stack]`** — every function from the
one just inside the declarer up to *and including* the current innermost
one. The inclusivity is what threads a transitively-captured variable
through the intervening lambdas all the way to the deepest one that uses
it; a "strictly between" interval would drop the innermost frame and miss
the actual user. The pass is a single in-order traversal, so by the end of
`checkbodies` every flag and capture list is final, before codegen.

Lua caps a C closure at 255 upvalues. Titan reserves four header slots and the
final strict Titan-generic entry trailer, so the checker accepts at most
250 source-level captures. The first larger closure receives
`function captures too many variables (251, max 250)` during checking rather
than reaching `lua_pushcclosure`. Callable wrapper realization needs one
additional traced source-closure upvalue, but this does not lower the source
capture limit: a 255-upvalue source (or full wrapper chain) remains admissible
and takes the generic fallback at the next non-exact edge.

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
  receives `cannot infer type of parameter 'x'`.
* **Input vararg.** An explicit `...: T` wins. A bare trailing `...` takes
  `expected.varargtype`; a non-variadic expected type or synthesis mode receives
  the corresponding clean inference error.
* **Result shape.** An explicit `node.rettypes`/`node.flexrettype` pair is used
  as written. In particular, the parser's empty-list representation of explicit
  `: ()` is truthy and therefore fixes the zero-result shape. With syntactic
  omission (`node.rettypes == false`), checking mode copies both
  `expected.rettypes` and `expected.flexrettype`; synthesis mode defaults to
  empty/false, exactly like an unannotated named function.

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
  existing countable C forms, or a Map whose resolved key type is exactly
  `Type.Integer`. Other Map key types receive the dedicated
  “not an integer-keyed map” diagnostic. This is exact resolved-type
  classification, not `types.compatible`; code generation gives Arrays their
  maintained length and gives integer Maps Lua table length: an inline ordinary
  border when `__len` is absent, or metamethod dispatch followed by an exact
  integer result guard when it is present. The metatable behavior changes no
  checker type or admissibility rule.
* **Record constructor omissions.** In a Nominal record context, explicit
  visible fields are checked in source order. Each absent field then gets the
  same `nil_can_adjust_to` test as an omitted named formal; an accepted field is
  appended as a coerced `ExpNil` marked `_named_omitted` with its `Type.Field`
  in `_field`. A record with any local field remains wholly unconstructible by
  `{...}` outside its defining module, before per-field omission is considered.
* **First-class functions, closures, and bound methods.** These are now
  *implemented*, so the points that historically rejected them are acceptance
  points. Referencing a name whose type is `Type.Function` as a value
  (`Ast.ExpVar`) yields a function value; calling a function *value* — a callee
  that is not a `VarName`/`VarDot` resolving to a top-level function, module
  member or static (`Ast.ExpCall`) — typechecks against the function type;
  a callee whose static type is `value` instead receives a synthesized
  positional function type from its arguments and surrounding result demand,
  then rejoins the same call path;
  writing a function *type* in an annotation (`g: (integer) -> integer`) is
  handled by `typefromnode`'s `Ast.TypeFunction` handler and produces a
  `Type.Function`; and assigning a value into a function-typed variable is
  allowed. An `Ast.ExpFunction` (an anonymous function) typechecks to a
  `Type.Function`, with parameter and return types inferred where annotations
  are omitted, and its body captures enclosing locals (see
  [Closures: capture analysis and lambda inference](#closures-capture-analysis-and-lambda-inference)).
  A bare `obj:method` (no call) typechecks to a *bound method reference*: the
  method's `Type.Function` with the implicit `self` removed. What the checker
  **still rejects**, all clean type errors: assigning to a function *name* (you
  cannot rebind a function); taking a *foreign* (C FFI) function as a value or
  binding a foreign method (it can only be called by name — see
  [the FFI chapter](../language/ffi.md)); a method reference on a non-record
  receiver, or to a non-existent method; using a record type or a module as a
  value; and a top-level `local x = function … end` (its initializer is not a
  constant, so `isconst` rejects it as `top level variable initialization must
  be constant`).
* **Conditions are not coerced.** `if`/`while`/`repeat` conditions are
  checked with a Boolean context but never `trycoerce`d or `checkmatch`ed:
  any type is a legal condition, and truthiness is the coder's problem.
  `repeat`'s condition is checked inside the body's scope, so it can see the
  body's locals.
* **Union construction and dispatch.** Synthesized variant statics are
  ordinary first-class `Type.StaticMethod` values, but publish
  `paramnames = false`; fixed-call adjustment still nil-fills a missing
  payload and evaluates/discards surplus arguments. `Ast.StatCase` applies
  ordinary `tryforce` to its scrutinee, so `Union?` dispatches after the
  normal nil check. It then requires a union owner, rejects duplicate arms and
  bindings on empty variants, and opens a sibling scope per arm. Payload
  bindings are installed outside the arm's possible `StatTry`, making them
  visible to its body, `catch`, and `finally` while keeping body locals out of
  the sibling clauses. Missing variants are permitted and an unmatched case
  without `else` is a no-op.
  `isconst` recognizes a record/union constructor only after its synthesized
  nominal metadata validates against the owner projection, and only when all
  arguments are recursively constant. An arbitrary static whose result is the
  owner is not accepted as a module constant.
* **Written `as` casts and `is` tests.** Both visitors call
  `check_explicit_cast_relation`: it resolves the target, checks the operand
  under that target context, and stores a complete `_written_cast`.
  `types.written_cast(source, target)` supplies every type-only case.
  Expression-dependent C operations are completed here instead: mutable
  address-taking requires a local/formal operand, while an unrelated
  object-pointer cast embeds the successful toolchain probe annotation itself.
  A candidate without its probe is never a complete written plan. Identity,
  direct coercion, gradual/callable view, and explicit C conversions remain
  distinct plan operations. A `value` source embeds the target's canonical
  `DynamicCoercionPlan`; `as` lowers its converting form and `is` lowers the
  same plan's non-raising predicate. Other gradual/callable written views
  retain their view/adjustment plan, and direct coercions retain the complete
  recursive `CoercionPlan`; `is` therefore mirrors failing
  float-to-integer/Option compositions instead of treating every admitted
  cast as total. Option targets recurse through the selected plan, including
  truthiness for a present `boolean?`. The separately annotated
  `value`-to-raw-C-pointer operation is written/unsafe and is unavailable to
  implicit adjustment. `ExpCast._type` is the target; `ExpIs._type` is always
  `Type.Boolean`. `is` does not alter the operand or symbol-table type, so
  there is no flow narrowing. A rejected test ordinarily uses
  `cannot cast '%s' to '%s'`; a mutable-address attempt on a C rvalue reports
  that the expression is not addressable. A `Type.Variant` descriptor is
  never a source-resolvable type, so annotations, aliases, `as`, and `is` may
  name `Message` but not `Message.move`; `case` is the only v1 variant test.

## Non-fallthrough analysis

Every `checkstat` handler returns whether control is guaranteed not to reach
the following statement. `StatReturn` and `StatRaise` return `true`; `StatIf`
returns `true` only if every then-block is non-fallthrough *and* an `else`
exists and is non-fallthrough. `StatCase` can additionally use the closed
variant set of its statically resolved `Type.Union`. It checks every arm block,
counts each unique valid visible variant, and compares that count with
`union.nvariants`. Its result is:

```text
every arm is non-fallthrough
and (covered variants == union.nvariants
     or the else block is non-fallthrough)
```

`nvariants` retains the total declaration count in compiled interfaces even
when local variants are omitted from the public variant map. An importer
therefore cannot get a false complete-coverage proof by listing every visible
variant. When the arms do cover the full closed set, an optional `else` is
unreachable and its fallthrough does not change the result, although the
checker still visits it. This is a control-flow proof, not an exhaustiveness
requirement or diagnostic. `StatTry` uses its body/catch/finally rule from
[Error handling](error-handling.md#checker-rules). The result is cached on
every statement as `_always_returns`, which is the shared checker-to-coder
reachability fact for direct terminators and compound `StatBlock`, `StatIf`,
`StatTry`, and `StatCase` nodes. The field retains its historical name even
though raising and a proven infinite loop also satisfy it. A bare `do … end`
propagates its own fold, so `do return 1 end` is non-fallthrough.

`StatWhile` is non-fallthrough only when its condition is the literal `true`
and no reachable `break` targets that loop. The checker maintains one flow
frame per enclosing loop, so a break in a nested loop marks only that nested
frame. Since statement-list checking stops after a proven terminator, a break
in a dead tail is not recorded. Other `while` conditions and every other loop
form remain fallthrough. The ordinary `StatTry` composition is essential: if a
catch covers the loop, a falling-through catch keeps the construct fallthrough,
while a non-fallthrough catch preserves the proof.

`checkblock` folds
the results with `ret = ret or checkstat(stat, st, errors)` — and note the
short-circuit: once `ret` is true, **later statements in the block are not
visited at all**. A plain `return` can only be a block's final statement (the
grammar enforces it), but a non-fallthrough `if`/`else` mid-block makes the
case reachable. The same now applies to proven non-fallthrough literal-true
`while` loops. *Limitation:* statements in such a dead tail go completely
unchecked — a type error placed there is not reported. The checker performs no
dead-code analysis to flag or prune them.

`checkfuncbody` consumes the result. Zero-return and flex-only functions may
fall through, as may a function whose complete fixed prefix is exactly one
`Type.Nil`; a flexible tail on that last shape is independently empty. Every
other fixed-result shape must be non-fallthrough. A single non-nil result uses
`function can return nil but return type is not nil`; a multi-result shape uses
`function can fall through but return type requires N fixed values`. The same
one-fixed-`nil` predicate tells `adjust_explist` to synthesize an ordinary nil
source for a bare `return`. It never nil-fills a multi-result prefix. Functions
declared without a return annotation default to **zero results** (`() -> ()`).

## Imports and the loader protocol

`Ast.TopLevelImport` is checked by `checker.checkimport(modname, loader)`.
The loader contract is:

```lua
loader(modname)  -->  ok, moduletype_or_error, errors
```

The staged declaration pass invokes every import in AST order before resolving
records and callable signatures. Its alias is therefore available to every
non-module-variable declaration even when the import node occurs later in the
AST. This early loading does not erase the language's sequential frontier:
while checking a module variable, `symtab.find_symbol` masks later
`TopLevelImport` and `TopLevelForeignImport` nodes by `_toplevel_order`.

On success, the import node's `_type` is the returned `Type.Module`, and
errors found while checking the dependency propagate into this module's
error list. `checkimport` first registers direct `Type.Interface` descriptors
from `type_members`, then walks both namespaces and registers referenced
nominal owners in `types.registry`. Value members unwrap their
`Type.ModuleMember` wrapper; records and unions are stored under their fqtn.
For each complete recovered module interface it also derives the deterministic
public module-userdata prefix and stamps public nominal static descriptors with
their closure slots. A later record/union selector through a type alias can
therefore use the original owner's constructor or public static as either a
direct call or first-class function without creating an alias-side value slot.
This is what makes a record, union, or Interface
imported through a compiled interface — one with no `.titan` source to
re-check — usable by nominal type. For a dependency *with* source the same
registration also happens as a side effect of the dependency's own
`checker.check`, which the loader runs recursively: the
`TopLevelRecord`/`TopLevelUnion`/`TopLevelInterface` visitors write into the
process-global `types.registry`. A `Type.Nominal`
carries *only* its fqtn string and
resolves through the registry at every use, so the qualified type
`geo.Point` (parsed as `Ast.TypeQualName`, converted by `typefromnode` to
`types.Nominal("geo.Point")`) means something only because checking module
`geo` registered `"geo.Point"`. Union visibility follows this same record
frontier, including the module-variable/lambda restriction and alias bridge.
On loader failure the import errors with
`problem loading module '%s': %s`.

Two real loaders exist in `driver.lua`:

* `driver.defaultloader` caches results in `driver.imported` and detects
  cycles by planting a `CIRCULAR_MARK` sentinel in the cache before recursing
  (a re-entry finds the mark and fails with `circular reference to module`).
  Dependencies with flat or folder source are recursively parsed and checked
  once per logical module. Compiled dependencies run the invocation's complete
  DSO/archive preference passes before source. A DSO recovers its interface
  from the callable `<mangled>_types`; a static provider recovers the same
  serialized bytes from its validated per-object metadata section. Both are
  strings of nested constructor calls produced by `types.serialize` and are
  evaluated with
  `load("return " .. s, modname, "t", types)`, the `types` module itself
  serving as the environment. C FFI types are *not* serializable
  (`types.serialize` raises on any type tree containing one), so imported C
  types cannot cross a compiled-interface boundary. Local nominal declarations
  and members are omitted from the serialized interface; exported records
  still serialize their total `nfields` count and each public
  `Field.index`, so public fields keep their real `Udata` slot even when local
  fields were skipped. `Type.Module.type_members` is serialized as a separate,
  deterministically ordered map, so aliases rehydrate without becoming runtime
  members. Exported `ModuleMember`, `Method`, and `StaticMethod` descriptors
  likewise serialize callable tail shape and formal `paramnames`; names remain
  absent from structural `Type.Function` values. In ABIs 0.23 through 0.25 the
  five-position
  `Function(params, rettypes, false, varargtype, flexrettype)` constructor keeps
  its third position as a required reserved-false sentinel; C variadicity never
  occupies it. The constructor schema includes `flexrettype`; ABI 0.14 gates
  that serialized arity so 0.13 modules
  are rejected before rehydration. ABI 0.19 additionally serializes
  `Type.Union`/`Type.Variant` schemas, preserving absolute private-skipping
  tags and `nvariants`; variant descriptors remain metadata, not type members.
* `driver.tableloader` is the in-memory variant for tests; it deliberately
  serializes and re-loads every module type, so the round-trip is exercised
  by every import test in the suite.

`foreign import` is checked separately (`Ast.TopLevelForeignImport`): it runs
the C parser pipeline and converts each declaration with
`foreigntypes.convert`. C values become members of a `Type.CModule`; a direct
function member retains `Type.CFunction`, while a function-pointer value retains
`Type.CPointer(Type.CFunction)` and neither is projected to `Type.Function`. C
type declarations become `type_members` plus entries in the symbol table's
`foreign_types` namespace, which is what lets local annotations such as
`c.size_t` resolve (see [FFI internals](ffi-internals.md)). Before conversion,
the `TypeList` supplies complete syntactic typedef-name and file-scope tag
metadata. A named tag-only struct/union with no same-name real typedef is
published directly in `type_members` through its canonical `struct@T` /
`union@T` owner; it is not wrapped in a fake `CTypedef`. Ordered conversion
binds a prototype tag to an already-visible file tag when appropriate and
otherwise keeps it prototype-local.
Every converted C type and accepted ordinary C name is also recorded with the
foreign-import node's `_toplevel_order`. Although the final foreign namespaces
are available to later declaration stages, a module variable asks those
histories for the last declaration at its `initializer_order`, so a later
header cannot leak C names or types backward through early import collection.
Because C aggregate owners are canonical objects completed in place,
`foreigntypes` additionally stamps a completed struct/union with
`_definition_order`; field lookup and allocation call
`foreign_definition_visible` so that later completion is treated as absent or
incomplete at an earlier module-variable frontier.
The same frontier-aware complete-object predicate protects by-value
parameters/results/locals/casts, fixed-array elements, allocation,
`sizeof`/`alignof`, and field lookup. Expression lookup on `Type.CModule` is
value-first; when an ordinary member collides with a type spelling, type
pseudo-members are rejected with a collision-specific diagnostic instead of
stealing the real function/variable.

The checker also receives the resolver's `cprobe.Service`. Rich probe results
remain session-scoped, while production services may reuse an exact-probe-text
successful marker from the configured prefix cache. After all foreign imports
establish a module's ordered header context,
contextual object-pointer conversions and C operators ask that service to
compile their exact `cdeclarator` spelling. The checker records complete
conversion/operator traits and coercion plans on the AST; the coder consumes
them without repeating target-C reasoning. See
[C FFI declarations and expressions](c-ffi-expressions.md).
The checker derives its C include `source_dir` from the canonical main
filename. Folder contributors are immediate siblings of that main, so quoted
headers imported from a contributor use the same directory without a
per-file checker invocation.

After the module interface is built, export validation rejects any public type
tree, including an exported alias target, that mentions a local nominal type
or a C FFI type. For records and unions, the walkers skip private
fields/variants, methods, and functions before applying the C-type check, so
an exported owner may keep a private C-typed member that never enters its
interface.

## Process-global state

Two pieces of mutable state outlive a `checker.check` call, and any test or
tool that checks more than one module (or the same module twice) must reset
them: `types.registry`, the fqtn → `Type.Record`/`Type.Union`/
`Type.Interface` map (stale entries make nominal types from a previous run
resolve in the next one), and
`driver.imported`, the import cache, including any `CIRCULAR_MARK` sentinels
left by a failed run. The suite's helpers do exactly this
(`types.registry = {}` and `driver.imported = {}` at the top of
`run_checker`-style functions); new specs must follow the pattern. The parser
adds a non-reentrancy hazard of its own (`THIS_FILENAME`), described in
[Lexer and parser](lexer-parser.md).
