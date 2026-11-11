# The AST and the `typedecl` convention

The whole compiler operates on one abstract syntax tree made of plain
Lua tables: the parser builds it, the checker decorates *and mutates* it
in place, and the code generator decorates it further while rendering C
from it. This chapter documents the `typedecl` constructor factory, the
`_tag` dispatch convention, the node inventory of `ast.lua`, the cross-pass
decoration fields, and what it costs to add a new node or type, because
every dispatch point is written out by hand.

## `typedecl.lua`: constructor generation

`titan-compiler/typedecl.lua` is the entire object model. Calling it with a
prefix and a two-level table `GroupName = { ConsName = {field, ...} }`
returns a *flat* table of constructor functions. Each constructor:

* takes its fields **positionally**, in declared order;
* is **arity-checked** with `table.pack`, so explicit `nil` arguments count
  toward the arity, and a wrong count raises `missing arguments for
  <ConsName>` (even when there are too many);
* returns a plain table whose only non-field key is
  `_tag = prefix .. "." .. ConsName`.

So `ast.ExpBinop(loc, lhs, "+", rhs)` builds
`{_tag = "Ast.ExpBinop", loc = loc, lhs = lhs, op = "+", rhs = rhs}`.
There are no metatables, no methods, and no validation of field *values*.

**Group names are documentation only.** The loop discards them, so nothing
in the compiler can ask "is this an expression?" except by enumerating tags.
This chapter follows the same grouping.

Ordinary optional fields use Lua `nil`; `false` is a boolean value, never a
missing node, type, name, or list. Parser captures retain nil positions, so no
placeholder sentinel is needed. Empty lists stay distinct from absent lists
where the distinction matters, such as an explicitly zero-result lambda.

Computed annotations that must distinguish "not yet computed" from "computed,
no result" use `titan-compiler/maybe3.lua`:

```lua
{ tag = "unknown" }                 -- initialized, not computed
{ tag = "none" }                    -- completed without a result
{ tag = "just", value = result }    -- completed with a result
```

`ast.lua` wraps the relevant constructors (`analysis_fields`) so they
initialize those fields with fresh `unknown` values; the list is in
[Decorations](#decorations-who-writes-what-who-reads-it). Dense plan lists
keep one wrapper per slot, including unavailable plans. `maybe3.get_checked`
rejects unknown or malformed state; only a checked `none` unwraps to nil, and
a `just` payload may itself be false. Array constness is another tagged value:
`{tag="no"}`, `{tag="yes"}`, or `{tag="maybe"}`, compared by tag; all three
tables are truthy.

The same factory builds the checker's semantic types: `types.lua` calls
`typedecl("Type", ...)`, producing tags like `"Type.Integer"` and
`"Type.Record"`. `types.Module(modname, members, type_members)` is instead a
hand-written function that fills `name`, `prefix`, `file`, `members` (both an
array and a name-keyed map), and `type_members`. `typedecl` constructors do
not validate conventions such as the reserved `false` third position of
`Type.Function`; callers must respect them.

Do not confuse the two layers: `Ast.Type*` nodes (`Ast.TypeInteger`,
`Ast.TypeArray`, ...) are *syntax*, annotations as written, while `Type.*`
values are checker types. The checker's `typefromnode` visitor maps the former
to the latter.

## `_tag` dispatch and `util.make_visitor`

All dispatch in the compiler is string comparison on `_tag`. The checker
wraps its dispatch tables in `util.make_visitor` (`util.lua`), which asserts
that the argument is a table with a `_tag` and that a handler exists. **A
visitor with no handler for a tag crashes** with a bare assertion failure,
not a compile-time error. The checker has five such visitors:

| Visitor | Defined in | Dispatches over | Returns |
| --- | --- | --- | --- |
| `typefromnode` | `checker/type_syntax.lua` | `Ast.Type*` annotation nodes | the corresponding `Type.*` value |
| `checkstat` | `checker/statements.lua` (wraps `checkstat_visitor`) | `Ast.Stat*` | the non-fallthrough boolean, also stored in `_always_returns` ([Non-fallthrough analysis](checker.md#non-fallthrough-analysis)) |
| `checkvar` | `checker/variables.lua` | `Ast.Var*` lvalues | annotates the node with `_type` |
| `checkexp` | `checker/expressions.lua` | `Ast.Exp*` | annotates the node with `_type` |
| `toplevel_visitor` | `checker/declarations.lua` | `Ast.TopLevel*` | nothing; called by the staged declaration collector |

The code generator does not use `make_visitor`. `codestat` and `codeexp`
wrap hand-written `if tag == ... elseif ...` chains, `codestat_dispatch`
(`coder/statements.lua`) and `codeexp_dispatch` (`coder/expressions.lua`),
which end in `error("invalid node tag ...")`; `codevalue` ends in `invalid tag
for a literal value`. The lvalue cases of `codeassignment` and the top-level
cases of `codefuncdec`/`coder.generate` have no terminal `error`, so a
missing case is not caught there. Either way, every
dispatch point must be updated by hand when a tag is added (see
[the checklist below](#the-cost-of-adding-a-node-or-type)).

## Locations

Every AST node's first constructor field is `loc`, a plain table
`{filename, line, col}` (1-based) built by `location.new`; how the parser
captures and interns locations is in
[Location tracking](lexer-parser.md#location-tracking). Locations feed
`location.format_error`, which renders the `file:line:col: <message>` prefix
shared by syntax and type errors, and the coder embeds `node.loc.line` in
generated run-time error messages. Checker-synthesized nodes reuse the
location of the node that triggered them.

## The AST inventory

Everything below is `titan-compiler/ast.lua`, prefix `"Ast"`. Every
node additionally has `_tag` and `loc` as described above; `loc` is
omitted from the field lists for brevity.

### Type annotations

| Constructor | Fields | Produced by |
| --- | --- | --- |
| `TypeNil`, `TypeBoolean`, `TypeInteger`, `TypeFloat`, `TypeString`, `TypeValue` | — | the primitive type keywords |
| `TypeParam` | `name`, `constraint` | declaration binder syntax; `constraint` is a named Interface type or nil |
| `TypeName` | `name`, `typeargs` | a bare or applied Titan type name |
| `TypeForeignName` | `name` | an unqualified foreign name or contextual C primitive, including multiword names such as `unsigned long` |
| `TypeQualName` | `module`, `name`, `typeargs` | `mod.Name` or `mod.Name<\|...\|>` in the Titan type namespace |
| `TypeCPointer` | `subtype`, `const` | `*T` or `const *T` inside foreign syntax; nested pointer constructors require grouping |
| `TypeCArray` | `base`, `length` | `T[]` inside foreign syntax; parsed `length` is nil, and `.const` records the array element qualifier; fixed extents are inferred semantic types rather than written annotations |
| `TypeOwned` | `subtype` | Titan `owned foreigntype`; the checker resolves the complete operand to a foreign pointer or array and selects scalar/counting ownership |
| `TypeArray` | `subtype`, `isconst` | `{T}`, `const { T }`, or `const? { T }`; `isconst.tag` is `"no"`, `"yes"`, or `"maybe"` |
| `TypeMap` | `keystype`, `valuestype` | `{K: V}` |
| `TypeFunction` | `argtypes`, `rettypes`, `varargtype`, `flexrettype` | dense fixed lists plus independent optional input/output tail element types (nil when absent) |
| `TypeForeignFunction` | `argtypes`, `rettypes`, `varargtype`, `flexrettype` | raw foreign signature syntax, resolved to a C function pointer; unsupported source variadics are rejected semantically |
| `TypeOption` | `basetype` | the `?` suffix, `T?` |

### Top-level nodes

| Constructor | Fields | Notes |
| --- | --- | --- |
| `TopLevelFunc` | `islocal`, `name`, `params`, `rettypes`, `flexrettype`, `block`, `typeparams` | fixed result list plus a separate optional output tail |
| `TopLevelMethod` | `class`, `name`, `params`, `rettypes`, `flexrettype`, `block`, `typeparams` | `function Class:name(...)`; parser decorates `islocal` |
| `TopLevelStatic` | `class`, `name`, `params`, `rettypes`, `flexrettype`, `block`, `typeparams` | `function Class.name(...)`, synthesized record `Class.new`, and synthesized union variant constructors; parser decorates `islocal` and marks synthesized forms |
| `TopLevelVar` | `islocal`, `isconst`, `decl`, `value` | module variable; `value == nil` preserves an omitted initializer until checking |
| `TopLevelTypeAlias` | `islocal`, `name`, `type` | compile-time-only `[local] type Name = T` |
| `TopLevelForeignTypeAlias` | `name`, `type` | always-local raw C alias; emits a typedef in the module's generated FFI header |
| `TopLevelForeignFunc` | `name`, `params`, `rettypes`, `flexrettype`, `block` | source foreign function with raw C parameters/results and a restricted body |
| `TopLevelInterface` | `name`, `members`, `fields`, `methods`, `typeparams` | top-level, non-local, nonempty Interface declaration; `members` preserves mixed source order and the other lists are ordered projections |
| `TopLevelRecord` | `name`, `fields`, `typeparams` | `fields` is a list of `Decl`; parser decorates `islocal` |
| `TopLevelUnion` | `name`, `variants`, `typeparams` | `variants` is a source-order list of `UnionVariant`; parser decorates `islocal` |
| `TopLevelImport` | `localname`, `modname`, `source_required` | `modname` is canonical; a terminal `.titan` marker is stripped and recorded separately in `source_required` |
| `TopLevelForeignImport` | `headername` | `foreign import "x.h"` |

`TopLevelStatic` covers record and union functions. The parser creates one directly for
`function Class.name(...)`, and also creates one from the `record` desugaring
(`defs.recorddecl` in `parser.lua`), which turns each record into *two*
top-level nodes — the `TopLevelRecord` plus a synthesized `new` record function
with one parameter per field, in field order. The parser copies `local record`
to both the record and `new`, and also makes `new` local when any field is
local. It sets `new._record_constructor = true`, which lets the checker
distinguish this adjacent desugaring from an explicit `function Class.new`
while collecting every record namespace before ordinary record members:

```titan
record Point
    x: float
    y: float
end
-- parses as if the program also contained:
-- function Point.new(x: float, y: float): Point
--     return { x = x, y = y }
-- end
```

`defs.uniondecl` similarly emits a `TopLevelUnion` followed by one
`TopLevelStatic` per variant. `UnionVariant {name, parts}` stores a dense list
of `Decl` nodes, each with its payload name and type annotation; an empty
variant has an empty list. The single unnamed type normalizes to a part named
`value`. A local variant carries `islocal = true`.
Each synthesized static is marked `_union_constructor` and points back to its
variant through `_union_variant`. Its body returns
`ExpUnionInit {owner, variant, values}`, whose dense expression list reads the
generated parameters in declaration order. The parameter names match the
payload parts and are published as ordinary named-call metadata.

`TopLevelInterface.fields` and `.methods` are independent declaration-order
lists projected from `.members`. A field is a const `Decl`; a method is an
`InterfaceMethod {name, params, rettypes, flexrettype, typeparams}` node. An Interface
method reuses the ordinary parameter and fixed/flexible result carriers but
has no body, receiver declaration, locality flag, or per-method `end`. The
checker turns these nodes into ordered `Type.Method` metadata; see
[Interfaces](interfaces.md#frontend-representation).

### Declarations and the `option`/`isconst` flags

`Decl = {loc, name, type, option, isconst}` is used for locals, numeric and
generic `for` control variables, function parameters, record fields, and
`TopLevelVar`. The
`type` field is an `Ast.Type*` node or nil (type to be inferred),
`option` is a boolean marking the bare-`?` inference form, and `isconst` is an
exact boolean for ordinary declarations:

| Source | `type` field | `option` field |
| --- | --- | --- |
| `x: integer` | `TypeInteger` node | `false` |
| `x?: integer` | `TypeOption(TypeInteger)` node | `false` |
| `x?` | nil | `true` |
| `x` | nil | `false` |

That is, `x?: T` is eagerly desugared into an option *annotation*,
while a bare `x?` defers to the checker, which infers the initializer's
type and optionizes it (`local y? = arr[1]` gives `y : integer?` where
`local y = arr[1]` gives `y : integer`). Parameters require an annotation and
admit no `?` mark on the name. Record fields and module variables require
`field: T?` rather than `field?: T`; their name-suffix sugar is absent from
the grammar. A record field `Decl` may carry `islocal = true`, set by the
parser for `local field: T`. A module variable needs an annotation or an
initializer, and only an explicitly nil-bearing annotation permits omission
of its initializer. The checker supplies the nil expression for mutable and
const module variables alike.

### Statements

| Constructor | Fields | Notes |
| --- | --- | --- |
| `StatBlock` | `stats` | also used for `do ... end` and every block body |
| `StatWhile` | `condition`, `block` | |
| `StatRepeat` | `block`, `condition` | note the field order: block first |
| `StatIf` | `thens`, `elsestat` | `thens` is a flat list of `Then {condition, block}` (one per `if`/`elseif`); `elsestat` is a `StatBlock` or nil |
| `StatCase` | `exp`, `arms`, `elseblock` | `arms` is a list of `CaseArm {name, bindings, block, named}`; `bindings` is a dense `Decl` list and `named` distinguishes braces from positional parentheses; absent `elseblock` is nil |
| `StatFor` | `decl`, `start`, `finish`, `inc`, `block` | `inc` is nil when the step is omitted; the checker fills in a literal `1`/`1.0` |
| `StatForIn` | `decls`, `exps`, `block` | generic `for decllist in explist`; the checker pads/elaborates `exps` as the iterator tuple |
| `StatAssign` | `vars`, `exps` | parser candidates have expression nodes in `vars` and `_parsed_candidates = true`; checking validates and extracts their `Var*` nodes |
| `StatDecl` | `decls`, `exps` | mutable `local` may have an empty `exps` list for checked nil synthesis; const declarations always have a nonempty initializer list |
| `StatCall` | `callexp` | a parsed prefix-expression statement candidate; checking requires an actual call |
| `StatReturn` | `exps` | zero or more; `return` can only be the last statement of a block |
| `StatBreak` | — | `break`; the checker tracks it per loop frame for non-fallthrough analysis |
| `StatRaise` | `exp` | `raise <exp>`; nil `exp` is a bare re-raise ([Error handling](error-handling.md#frontend-representation)) |
| `StatTry` | `block`, `catchblock`, `finallyblock` | built by the parser's `do ... catch` and `defer` lowering; see [Error handling](error-handling.md#frontend-representation) |

### Variables (lvalues)

`VarName {name}`, `VarBracket {exp1, exp2}` for `e1[e2]`, and
`VarDot {exp, name}` for `e.name`. An `Ast.ExpVar {var}` wraps a `Var`
to use it as an expression.

### Expressions

| Constructor | Fields | Notes |
| --- | --- | --- |
| `ExpNil` | — | |
| `ExpBool`, `ExpInteger`, `ExpFloat`, `ExpString` | `value` | literal values, already decoded by the lexer |
| `ExpInitList` | `fields` | `{...}` constructors: arrays, maps, records |
| `ExpCall` | `exp`, `args`, `typeargs` | parser output may carry any of the four `Args*` forms below; successful named calls are normalized before codegen |
| `ExpVar` | `var` | |
| `ExpForeignType` | `type` | foreign type operand of `.new`, `.new_array`, `.sizeof`, or `.alignof`; never an ordinary first-class value |
| `ExpUnop` | `op`, `exp` | `op` ∈ `"not"`, `"#"`, `"-"`, `"~"` |
| `ExpBinop` | `lhs`, `op`, `rhs` | `op` is the literal operator string (`"+"`, `"=="`, `"and"`, ...) |
| `ExpConcat` | `exps` | `..` is flattened to one n-ary node at parse time; all-literal operands are constant-folded into an `ExpString` |
| `ExpCast` | `exp`, `target` | written `as` casts **and** every checker-materialized implicit coercion |
| `ExpIs` | `exp`, `target` | written `is` type test; the checker resolves `target` and gives the expression type `boolean` |
| `ExpAdjust` | `exp` | parenthesized call, varargs, spread, or subset; checking requests one result, including nil padding for an empty run |
| `ExpExtra` | `exp`, `index`, `_type` | synthesized by the checker only: the index-th (> 1) value of a multi-return call |
| `ExpSubset` | `exp`, `first`, `last` | parser-built comma-bearing bracket suffix; either bound may be nil, and checking accepts it only as spread range syntax |
| `ExpSpread` | `exp`, `first`, `last` | unique parser/checker carrier for one collection or ranged-vararg spread; owns subject/bound evaluation |
| `ExpSpreadIndex` | `spread`, `index`, `_type` | checker-synthesized finite projection; every projection points to the same `ExpSpread` carrier |
| `ExpFunction` | `params`, `rettypes`, `flexrettype`, `block` | anonymous function; the raw AST keeps an omitted result annotation as `rettypes = nil`, distinct from explicit `: ()`; a matching expected Function may supply missing fixed/bare-variadic inputs and the complete result shape |
| `ExpUnionInit` | `owner`, `variant`, `values` | parser-synthesized variant-constructor result; `values` is a dense expression list in payload declaration order, empty for an empty variant |
| `ExpMethodRef` | `exp`, `name` | bound method reference `obj:m` without a call |
| `ExpDots` | — | bare `...` |
| `ExpDotsIndex` | `exp` | `...[e]`, and checker-synthesized vararg projections; the checker sets `_nilfill` and `_type` |
| `ExpDotsLen` | — | `#...` |

The parser records written type arguments on the expression that carries
them as `_nominal_typeargs`/`_nominal_typeargs_loc` (`defs.name_with_types`,
`defs.dot_with_types`, `defs.method_with_types`). When a call follows
immediately, `defs.call_suffix` moves them into `ExpCall.typeargs`, the
callable-local list. Otherwise, as for the namespace in
`Owner<|T|>.member(...)`, they stay on the expression; the checker resolves
that owner application before selecting the member, and erased-core lowering
removes both fields before coder entry. Explicit arguments on a first-class
expression candidate are rejected by the checker's direct-call-only rule
rather than ignored.

Structural facts about the elaborated expression forms (their checking rules
are in [Rewriting the AST](checker.md#rewriting-the-ast)):

* **`ExpAdjust`** is created by `defs.adjust_exp` when a call, `...`,
  spread, or subset is parenthesized; `defs.adjust_exp` sets `_parenthesized`
  on whatever node it returns, which the checker uses for lvalue rejection. A
  parenthesized spread owns `_adjusted_spread` and one `ExpSpreadIndex`
  projection, so its subject and bounds execute once; flow analysis visits
  that carrier for reads and writes, including catch-visible local mutations.
* **`ExpExtra.exp`** points at the call node occurring earlier in the same
  list, so the tree is a DAG there, and codegen relies on the call being
  generated first (see `_extras` below). `_type` is a declared constructor
  field on `ExpExtra` and `ExpSpreadIndex`.
* **`ExpSpreadIndex.spread`** points at the one `ExpSpread` carrier already
  present in lexical order, and every sibling projection shares that object
  identity. Generic lowering memoizes the carrier and redirects every lowered
  projection to the same lowered carrier, preserving once-only subject and
  bound evaluation.
* **`ExpCast`** is both a written `x as T` and the node the checker
  synthesizes for every implicit coercion (marked `_implicit_coercion =
  true`). The code generator emits conversions **only** from `ExpCast`
  nodes.
* **`ExpIs`** is always written source. It shares the written-cast helper,
  its `_type` is `Type.Boolean`, and it never rewrites or narrows its
  operand's `_type`.

### Call arguments and constructor fields

`ArgsFunc {args}` and `ArgsMethod {method, args}` (`method` is the name string
after `:`) are positional. The parser's brace-delimited call paths produce
`ArgsNamedFunc {fields}` and `ArgsNamedMethod {method, fields}` instead. The
checker uses those tags to enforce declaration provenance and label matching,
then replaces a successful named node with `ArgsFunc`/`ArgsMethod` carrying a
dense formal-order list. See
[named-argument internals](named-arguments.md).

`Field {name, exp}` is one named-call entry or one entry of an `ExpInitList`.
For a named call, `name` is always a raw label string. In an initializer it
encodes three field forms:

| Source form | `name` |
| --- | --- |
| `exp` (positional) | nil |
| `name = exp` | the name string |
| `[keyexp] = exp` | the key *expression node* |

At the semantic-type layer a Titan/Lua `Type.Function` has the fields
`params`, `rettypes`, `vararg`, `varargtype`, and `flexrettype`; the third
constructor position is a reserved `false` by convention. A direct foreign
member keeps the independent `Type.CFunction` shape and a C function pointer
is `Type.CPointer(Type.CFunction)`; no C signature is projected into
`Type.Function` ([`Type.Function.varargtype` vs.
`Type.CFunction.vararg`](variadic-parameters.md#typefunctionvarargtype-vs-typecfunctionvararg)).
Parameter names live only on declarations: `Type.ModuleMember`,
`Type.Method`, and `Type.StaticMethod` carry `paramnames`, so names never
affect equality, callable adjustment, or native tags.

## Decorations: who writes what, who reads it

Passes communicate by adding underscore-prefixed fields to nodes. Most are
decorations assigned after construction; `_type` is also a declared constructor
field on `ExpExtra` and `ExpSpreadIndex`. This table inventories the durable
cross-pass fields (short-lived state used wholly inside one pass is omitted);
the linked chapters own the mechanisms.

The `analysis_fields` wrapper in `ast.lua` initializes these `Maybe3` fields
to `unknown`:

| Constructors | Fields |
| --- | --- |
| `TopLevelFunc`, `TopLevelMethod`, `TopLevelStatic`, `TopLevelForeignFunc`, `ExpFunction`, `InterfaceMethod` | `_lua_vararg_dynamic_plan`, `_strict_vararg_guard_plan`, `_bound_strict_vararg_guard_plan` |
| `TopLevelVar` | `_lua_write_dynamic_plan` |
| `Decl` | `_dynamic_plan` |
| `VarBracket` | `_read_guard` |
| `ExpInitList` | `_array_writer_plan` |
| `ExpSpread` | `_spread_optional_guard`, `_spread_open_guard` |
| `ExpCall` | `_lua_open_result_dynamic_plan`, `_strict_open_result_guard_plan` |
| `ExpCast`, `ExpIs` | `_written_cast` |
| `ExpBinop` | `_comparison` |

Successful checking publishes `none` or `just`, and consumers unwrap through
`get_checked`. Parallel fixed-parameter/result plan arrays use one wrapper per
slot. `Type.Field.dynamic_plan` and frozen strict relay slot guards follow the
same contract. Genuine boolean facts such as `_always_returns` and `_nilfill`
remain booleans.

| Field | On | Written by | Read by | Meaning |
| --- | --- | --- | --- | --- |
| `_type` | every Exp, Var, Decl, TopLevel node; the AST root | checker (on `ExpExtra` it is a positional constructor field) | checker, coder | the node's checker type (`Type.*`); on the root it is the `Type.Module` interface |
| `_types`, `_flexrettype`, `_callee_type`, `_visible_types`, `_result_sources` | `ExpCall` | checker | checker, coder | declared and consumer-visible call shape ([Flexible returns](flexible-returns.md#declared-call-shape-versus-visible-call-shape)) |
| `_finite_flex_prefix`, `_flex_result_demand`, `_open_results` | `ExpCall` | checker | coder | finite projected tail count, finite/open demand marker, and the dynamic source/target/start description for an open sink |
| `_result_adjustment`, `_arg_adjustment`, `_positional_adjustment`, `_tuple_adjustment` | expression-list consumers | checker | coder | shared finite/open elaboration ([One finite/open result demand](flexible-returns.md#one-finiteopen-result-demand)) |
| `_spread_checked`, `_spread_kind`, `_spread_elem`, `_spread_optional_type`, `_spread_optional_guard`, `_spread_open_guard`, `_spread_subject_force`, `_open_spread` | `ExpSpread` (the subject-force marker also reaches its checker-built cast) | checker | checker generic finalization/lowering, coder | once-only spread classification, finite/open element views and guards ([Spread expressions](spread-expressions.md#checker-planning)) |
| `_nilfill` | `ExpSpreadIndex`, `ExpDotsIndex` | checker | coder | the projection is absence-aware and yields nil for a missing element |
| `_coder_spread` | `ExpSpread` | coder | coder | prepared subject/range/count/result-run state shared by every generated projection and open sink |
| `_adjusted_spread` | `ExpAdjust` | checker | flow analysis, coder | the evaluated-once carrier for the scalar projection of a parenthesized spread |
| `_parenthesized` | node returned by `defs.adjust_exp` | parser | checker | the expression was parenthesized; rejects it as an lvalue |
| `_numeral` | parsed `ExpInteger` and `ExpFloat` | parser | checker | validated source spelling; preserves radix and exact integer digits for [C99 literal typing](c-ffi-expressions.md#c-operator-traits), independently of the Lua numeric value |
| `_c_literal` | C-typed numeric literals, including contextual signed `ExpUnop` | checker | coder, C operator probe | exact typed C literal expression selected by [C99 or contextual typing](c-ffi-expressions.md#c-operator-traits); floating values are rendered from the lexer's double value |
| `_c_operator` | C-mode `ExpUnop` and `ExpBinop` | checker | coder | validated operator, operand conversions, result type, literal expressions, and probe key ([C operator traits](c-ffi-expressions.md#c-operator-traits)) |
| `_parsed_candidates` | `StatAssign` | parser, cleared by checker | checker | `vars` still contains prefix expressions awaiting lvalue validation |
| `_current_module_member` | normalized `VarName` | checker | checker | an `M.member` selection resolved against the module root rather than lexical shadows |
| `_ffi_scope` | C type descriptors | C declaration conversion | runtime identity rendering, source declaration persistence | declaration origin retained through typedef and pointer/array/function wrappers; anonymous aggregates keep distinct sites |
| `_allocation_result_root` | coder-synthesized `ExpCast` used by an open adjustment | coder adjustment dispatcher | coder cast lowering | optional sink-selected indexed slot into which the allocating cast publishes its final GC object exactly once |
| `_discard_results`, `_voidok` | expressions/calls | checker | checker, coder | evaluate under zero-result demand; calls may legally expose no result |
| `_npassed_args`, `_open_args` | `ExpCall` | checker | coder | statically passed argument count and a final dynamic run feeding an input-vararg tail |
| `_contextual_value_call`, `_contextual_function_type` | `ExpCall` | checker | checker, specs | the callee began as `value` and was checked against a function shape synthesized from argument/result demand |
| `_c_pointer_call` | `ExpCall` | checker | coder | authoritative `Type.CFunction` pointee for an indirect C call, including synthesized generic-for iterator/close calls |
| `_implicit_coercion` | checker-synthesized `ExpCast` | checker | coder | distinguishes a demanded sink conversion from a written `as` ([`trycoerce`](checker.md#trycoerce-tryforce-trytostr)) |
| `_adjustment`, `_assignment_adjustment`, `_callable_adapter`, `_c_conversion`, `_operator_conversion` | `ExpCast` (structural views: the source expression) | checker | coder | the checker's frozen conversion decision ([`trycoerce`](checker.md#trycoerce-tryforce-trytostr)) |
| `_written_cast` | `ExpCast`/`ExpIs` | checker | coder, linear-use pass | frozen written-cast plan; mutable-to-const Array casts carry `array_freeze` with `copy` or proven `freeze` mode ([linear-use analysis](const-values.md#array-relations-and-linear-use-analysis)) |
| `_linear_array_freeze` | mutable-to-const `ExpCast` | post-typecheck linear-use pass (`checker/linear.lua`) | specs | marks the last-use proof; the coder reads the `freeze` mode of `_written_cast` instead |
| `_decl` | `VarName`, `VarDot`, and other source-tooling sites | checker | checker, coder, semantic tooling | what the name resolved to: an `Ast.Decl` (local/param/`self`), a top-level AST node, a `Type.ModuleMember`/`Type.ModuleVariable`, a `Type.Field`/`Type.StaticMethod`, or the `Checker.CPseudoNew` allocation descriptor ([Source semantic bindings](checker.md#source-semantic-bindings)) |
| `_used` | `Decl`, top-level nodes (via `_decl`) | checker: on every read, on capture, and on assignment to a GC-bearing local or parameter | coder | "this variable needs storage"; a local without it gets no C variable, and its initializer is evaluated and cast to `(void)` ([Locals and assignment](codegen-constructs.md#locals-and-assignment)) |
| `_assigned`, `_captured` | `Decl` (via `_decl`) | checker (`checkvar`, `Ast.VarName` visitor) | coder | reassigned and captured variables ([The capture flags](checker.md#the-capture-flags)); stack homes for GC-bearing parameters are in [values and the GC](values-and-gc.md) |
| `_record_constructor` | synthesized `TopLevelStatic` | parser record desugaring | checker | identifies the adjacent synthesized `Rec.new`; an explicit `Rec.new` does not carry it |
| `_union_constructor`, `_union_variant` | synthesized `TopLevelStatic` | parser union desugaring | checker | identify an adjacent variant constructor and its `UnionVariant` |
| `_interface_conversion` | coercion-bearing expression, call adjustment, or written cast/test | checker | coder | frozen concrete-to-Interface wrapper plan; the coder must not rerun structural matching ([Interfaces](interfaces.md)) |
| `_interface_test`, `_interface_downcast` | `ExpIs`/`ExpCast` | checker | coder | a statically proven concrete-to-Interface test, and an exact Interface-wrapper-to-concrete payload check |
| `_interface`, `_interface_method`, `_interface_method_index`, `_interface_bound` | Interface method call/reference | checker | coder | resolved Interface descriptor, method descriptor, declaration-order payload slot, and bound-reference marker |
| `_interface_field`, `_interface_field_index` | Interface field read | checker | coder | resolved target field descriptor and declaration-order snapshot user-value index |
| `_toplevel_order` | every AST root node | checker duplicate prepass | checker, symbol table | 1-based AST position; drives duplicate winners and the module-variable visibility frontier |
| `_ignore` | top-level nodes | checker declaration stages | body checker, `makemoduletype`, coder (`generate`, `allocate_upvalues`) | "pretend this node does not exist"; every later traversal must skip it |
| `_alias_state` | `TopLevelTypeAlias` | checker alias resolver | checker | `resolving`/`resolved` state for lazy forward resolution and cycle detection ([Type aliases](type-aliases.md)) |
| `_self` | `TopLevelMethod` | checker | checker, coder | synthesized `Ast.Decl` for `self`, typed as the owner's nominal type; becomes the C parameter `__self__` |
| `_nominal_owner`, `_owner_decl` | `TopLevelStatic`, `TopLevelMethod` | checker nominal-member declaration stages | checker lowering and type syntax, coder, `documentation.lua` | the owning record/union node, and the owner descriptor for documentation and tooling |
| `_union` | `StatCase` | checker | coder | the resolved `Type.Union` owner of the case scrutinee |
| `_variant`, `_variant_index` | `CaseArm` | checker | coder | the resolved `Type.Variant` and its absolute zero-based dispatch tag |
| `part`, `_part_loc` | `Decl` in a named `CaseArm.bindings` list | parser | checker, source analysis | selected source part name and location; the declaration's own `name` is its local alias |
| `_part`, `_part_index` | checked case-binding `Decl` | checker | generic lowering, coder | resolved `Type.Field` and its one-based logical part index |
| `_always_returns` | every statement | checker (`checkstat`) | checker, coder | cached non-fallthrough result ([Non-fallthrough analysis](checker.md#non-fallthrough-analysis)) |
| `_method` | `ExpCall` (method calls) | checker | coder | the resolved `Type.Method` |
| `_paramnames` | `TopLevelFunc`, `TopLevelForeignFunc` | checker callable-signature stage | checker, module-interface builder | dense names of fixed declared parameters, kept on the declaration rather than the function type |
| `_named_arg_order`, `_named_call_kind`, `_surface_named_args` | checked named `ExpCall` | checker | coder (`_surface_named_args`: semantic tooling only; `coder.generate` skips it) | named-call lowering order and the retained written fields ([Named arguments](named-arguments.md#checker-elaboration)) |
| `_named_omitted` | synthesized nil fill in a named call or record constructor | checker | coder assertions for named calls; specs | distinguishes checked omissions from explicit expressions |
| `_field` | `Field` (record constructors) | checker | coder | the resolved `Type.Field`, including synthesized omitted fields; `index` is the zero-based logical declaration position |
| `_initializerless_const` | const `TopLevelVar` | checker | assignment authorization, coder | the source omitted the module initializer; only the owner root initializer may assign it |
| `_forcontrol` | `Decl` | checker | checker | numeric and generic `for` control variables are read-only assignment targets |
| `_tuple_decls`, `_result_decls`, `_init_call`, `_next_call`, `_close_call`, `_visible_stat`, `_has_close`, `_runtime_optional_close` | `StatForIn` | checker | coder | the elaborated iterator protocol ([Generic `for` tuple elaboration](checker.md#generic-for-tuple-elaboration)) |
| `_forin_nil_guard` | `StatCall` synthesized by `codeforin` | coder | coder | the hidden close declaration whose `TValue` must be non-nil before the close call in the generated `finally` |
| `_readonly` | synthesized `Decl` (`L`, `M`) and the `ffi` namespace | checker | checker | read-only built-in binding; non-`_builtin` ones cannot be shadowed ([The symbol table](checker.md#the-symbol-table-symtablua)) |
| `_cvar` | `Decl` | coder | coder | name of the C local holding the value, such as `_local_<name>`, `_param_<name>`, `__self__`, or `_forin_<name>` |
| `_slot` | `Decl`, `TopLevelVar` | coder | coder | the `TValue` slot anchoring a GC-able value: a depth-allocated Lua stack slot from `newslot` (`coder/flow.lua`), or `&_mod->uv[N].uv` for module variables |
| `_upvalue`, `_closure_upvalue` | `TopLevelVar`, `TopLevelImport`, public module-member and static descriptors | coder (`allocate_upvalues`, imports) and `checker.register_module_interface` | coder | the module `Udata` user-value slot ([User-value allocation](codegen-overview.md#user-value-allocation)) |
| `_body`, `_sig`, `_luabody` | `TopLevelFunc`/`Static`/`Method` | coder (`codefuncdec`) | coder (`generate`) | rendered C strings: the native function definition, its prototype, and the Lua-stack entry wrapper |
| `_extras` | `ExpCall` | coder (`coder/calls.lua`, `coder/immediate.lua`) | coder (`ExpExtra` in `codeexp`, generic-for hidden assignment) | maps return-value index (≥ 2) to the C temporary that received that out-parameter |

Two practical consequences of this scheme:

* **Post-checker ASTs are self-referential.** `_decl` makes uses point
  at declarations, `_nominal_owner` points across the top-level list, and
  `ExpExtra.exp` points at a sibling. Printing such a tree at unlimited
  table depth (a luassert failure diff) does not terminate usefully; see the
  `TableFormatLevel` rule in
  [Preserve fixture and shared-output ownership](repository-workflow.md#preserve-fixture-and-shared-output-ownership).
* **Decorations are invisible to arity checks.** They are added by
  plain field assignment after construction, so nothing validates them:
  a misspelled decoration name (`node._typ` for `node._type`) fails only
  when read.

Records, unions, and Interfaces all use `Type.Nominal(fqtn)` as their
value-facing type; `Type.Record`, `Type.Union`/`Type.Variant`, and
`Type.Interface` are registry and serialized-module descriptors, described in
[Native nominal storage](nominal-storage.md),
[Union type descriptors](unions.md#type-descriptors), and
[Interfaces](interfaces.md#frontend-representation).

## The cost of adding a node or type

All dispatch is hand-enumerated, so adding a tag is a cross-cutting
change. This is the checklist.

### Adding an `Ast.*` node

1. **`ast.lua`**: add the constructor entry (the group has no semantic
   effect). If the node carries a computed plan, add it to the
   `analysis_fields` list.
2. **`parser.lua`**: if the node has surface syntax, add the grammar
   production. Every `ast` constructor is copied into the grammar's `defs`
   table by name, so `-> YourNode` works immediately. Every new error label
   the production uses (`^Label`, `%{Label}`) **must** have an entry in
   `syntax_errors.errors` ([The error-label system](lexer-parser.md#the-error-label-system)).
3. **Checker**: add a handler to every `make_visitor` table the node can
   reach (`checkstat`, returning the correct non-fallthrough boolean;
   `checkexp`; `checkvar`; `typefromnode`; `toplevel_visitor`). A new
   top-level kind must also be placed in the correct declaration stage and
   body-validation path ([Staged top-level collection](checker.md#staged-top-level-collection-and-body-checking)),
   with `_ignore` handling in every later traversal, and in generic lowering
   (`checker/lowering.lua`) if it can contain generic terms. A missing
   visitor handler is an assertion crash.
4. **Coder**: extend `codestat_dispatch`, `codeexp_dispatch`/`codevalue`, the
   lvalue cases of `codeassignment` (shared by single and multiple
   assignment), and `codefuncdec`/`coder.generate` for top levels. The two
   dispatch chains crash on a missing tag only when a program reaches codegen
   with the new node; the others do not check at all.
5. **Specs**: add parser/checker cases. Because specs compare with the
   subset assertion (next section), existing tests do not break from new
   decorations, only from changed fields.

### Adding a `Type.*` type

1. **`types.lua`**: the constructor entry, plus every relevant operation:
   `types.equals`, `types.normalize`, `types.consistent` and
   `types.gradual_guard`, `types.coercion`, `types.dynamic_coercion`,
   `types.written_cast`, callable/assignment adjustment where applicable,
   `types.tostring` (the name users see in errors), and `types.serialize`,
   which raises on unknown tags, so a non-serializable type breaks module
   interfaces (`<mangled>_types`) the moment it appears in an exported
   signature. The driver's closed interface validator must also accept it
   ([Interface recovery and the closed validator](driver.md#interface-recovery-and-the-closed-validator)).
2. **Predicates**: classify the type in `types.is_basic`, `types.is_gc`
   (getting this wrong produces GC bugs, not type errors), and
   `types.is_truthy`/`types.is_falsy`.
3. **Checker**: teach `typefromnode` to produce it (if it has annotation
   syntax) and every context that inspects type tags (operators, indexing,
   calls, ...).
4. **Coder**: the per-type C-rendering functions dispatch on type tags.
   `ctype` (via `coder._raw_ctype`), `checkandget`, and `setslot`
   (`coder/values.lua`), and `getslot` and `toboolean` (`coder/names.lua`)
   raise on an unknown tag; `checkandset` delegates, and `initval` and the
   semantically typed boxed conversion helpers have broader defaults that
   may be silently wrong for a new type. Array shows why the C type alone is
   insufficient. See [values and the GC](values-and-gc.md) for what each must
   produce.
5. **Interop**: if values of the type cross the Lua boundary, the
   entry-wrapper checks in `genluaentry` (`coder/declarations.lua`) and the
   record/module metatable paths need cases too
   ([Lua interop internals](lua-interop-internals.md)).

No compiler-enforced exhaustiveness exists anywhere in this list; the
enforcement is the test suite plus the `assert`/`error` crash on first
contact.

## How specs compare ASTs

AST specs compare trees with a *subset* assertion rather than deep equality.
`restrict(expected, actual)` projects the actual tree onto the keys present
in the expected table, recursively, and the assertion compares the
projection with `assert.are.same`. `spec/parser_spec.lua` has its own local
`restrict`/`assert_is_subset` (which also wraps expected assignment
candidates in `ExpVar`); checker specs use `M.restrict`/`M.assert_ast` from
`spec/support/helpers.lua`. A test therefore asserts exactly the fields it
cares about:

```lua
assert_program_ast([[ local x = 17 ]], {
    { _tag = "Ast.TopLevelVar", islocal = true,
      decl = { name = "x" },
      value = { _tag = "Ast.ExpInteger", value = 17 } }
})
```

and stays silent about `loc`, untested `_tag`s, and every decoration. Adding
a new `_whatever` field therefore breaks no existing test. The flip side is
that wrong *extra* fields also pass unnoticed, so new behavior needs its own
positive assertions. New specs must follow this pattern; full-tree
`assert.are.same` on a post-checker AST is brittle and risks the
self-reference printing hang described above.
