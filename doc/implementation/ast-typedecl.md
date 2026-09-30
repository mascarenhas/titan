# The AST and the `typedecl` convention

The whole compiler operates on one abstract syntax tree made of plain
Lua tables: the parser builds it, the checker decorates *and mutates* it
in place, and the code generator decorates it further while rendering C
from it. This chapter documents the `typedecl` constructor factory, the
`_tag` dispatch convention, the full node inventory of `ast.lua`, the
decoration fields each pass adds, and — because every dispatch point is
written out by hand — exactly what it costs to add a new node or type.

## `typedecl.lua`: constructor generation

`titan-compiler/typedecl.lua` is the entire object model, and it is small
enough to quote in full:

```lua
-- Create a constructor for each type
-- See also: ast.lua

return function(prefix, types)
    local constructors = {}
    for typename, conss in pairs(types) do
        for consname, fields in pairs(conss) do
            local tag = prefix .. "." .. consname
            constructors[consname] = function(...)
                local args = table.pack(...)
                if args.n ~= #fields then
                    error("missing arguments for " .. consname)
                end
                local node = { _tag = tag }
                for i, field in ipairs(fields) do
                    node[field] = args[i]
                end
                return node
            end
        end
    end
    return constructors
end
```

Calling it with a prefix and a two-level table of
`GroupName = { ConsName = {field, field, ...} }` returns a *flat* table
of constructor functions. Each constructor takes its fields
**positionally**, in declared order; is **arity-checked** with
`table.pack`, so explicit `nil` arguments count toward the arity and a
wrong count raises `missing arguments for <ConsName>` (the message says
"missing" even when there are too many); and produces a plain table
whose only non-field key is `_tag = prefix .. "." .. ConsName`. So
`ast.ExpBinop(loc, lhs, "+", rhs)` builds
`{_tag = "Ast.ExpBinop", loc = loc, lhs = lhs, op = "+", rhs = rhs}`.
There are no metatables, no methods, and no validation of field
*values* — a constructor will happily accept a string where a node was
expected.

**Group names are documentation only.** The `Type`, `Stat`, `Exp`, ...
group names in `ast.lua` never appear on the nodes and are erased by the
flattening; nothing in the compiler can ask "is this an expression?"
except by enumerating tags. They exist solely to organize the source
file (and this chapter follows the same grouping below).

Ordinary optional fields use Lua `nil`; `false` is a boolean value, never a
missing node, type, name, or list. Explicit nil arguments still count toward
constructor arity. Parser captures retain these nil positions, so no placeholder
sentinel is necessary. Empty lists remain distinct from absent lists where that
distinction is meaningful, such as an explicitly zero-result lambda.

Computed annotations that distinguish an unchecked operation from a completed
miss use the shared `titan-compiler.maybe3` representation:

```lua
{ tag = "unknown" }                 -- initialized, not computed
{ tag = "none" }                    -- completed without a result
{ tag = "just", value = result }    -- completed with a result
```

The relevant AST constructors initialize scalar annotations with fresh
`unknown` values. Dense plan lists retain one wrapper per slot, including
unavailable plans. `maybe3.get_checked` rejects unknown or malformed state;
only a checked `none` unwraps to nil. A `just` payload may itself be false.
This wrapper is separate from `_tag`-dispatched AST/type nodes. Array constness
is another tagged value: `{tag="no"}`, `{tag="yes"}`, or `{tag="maybe"}`.
Its tags are compared structurally; all three wrapper tables are truthy.

The same factory builds the checker's semantic types:
`types.lua` calls `typedecl("Type", ...)`, producing tags like
`"Type.Integer"` and `"Type.Record"`. Some type values are
*not* made through `typedecl` and break its conventions:
`types.Module` is a hand-written function (its `members` table is both
an array and a name-keyed map). See
[the type checker](checker.md) for the type language itself.

Do not confuse the two layers with similar names: `Ast.Type*` nodes
(`Ast.TypeInteger`, `Ast.TypeArray`, ...) are *syntax* — annotations as
written in the source — while `Type.*` values are checker types; the
checker's `typefromnode` visitor maps the former to the latter.

## `_tag` dispatch and `util.make_visitor`

All dispatch in the compiler is string comparison on `_tag`. The checker
wraps its dispatch tables in `util.make_visitor` (`util.lua`):

```lua
function util.make_visitor(functions)
    return function(node, ...)
        assert(type(node) == "table")
        assert(node._tag)
        local f = assert(functions[node._tag])
        return f(node, ...)
    end
end
```

The third `assert` is the load-bearing one: **a visitor with no handler
for a tag crashes** with a bare assertion failure, not a compile-time
error. The checker has five such visitors (`checker.lua`):

| Visitor | Dispatches over | Returns |
| --- | --- | --- |
| `typefromnode` | `Ast.Type*` annotation nodes | the corresponding `Type.*` value |
| `checkstat` | `Ast.Stat*` | boolean "this statement cannot fall through", stored in the historical `_always_returns` field and used by control-flow analysis |
| `checkvar` | `Ast.Var*` lvalues | nothing (annotates the node) |
| `checkexp` | `Ast.Exp*` | nothing (annotates the node) |
| `toplevel_visitor` | `Ast.TopLevel*` | nothing (called by the staged declaration collector) |

The code generator does not use `make_visitor`: `coder.lua` dispatches
with hand-written `if tag == ... elseif ...` chains (`codestat`,
`codeexp`, `codevalue`, the lvalue switch in `codeassignment`,
...), each ending in `error("invalid node tag " .. tag)` or similar.
Either way, every dispatch point must be updated by hand when a tag is
added, and forgetting one crashes on the first program that exercises
it (see [the checklist below](#the-cost-of-adding-a-node-or-type)).

## Locations

Every AST node's first constructor field is `loc`, a plain table
`{filename, line, col}` (1-based) from `location.lua`. The grammar rule
`P` captures the byte position at the start of every node-producing production
and converts it with an ordinary location capture and `location.from_pos`,
which is why `loc` is always the first argument of every constructor
call in the parser (see [lexer and parser](lexer-parser.md)). Line
lookup is lazy: the first query for a source string builds a sorted
list of newline offsets (cached in a weak-keyed table) that later
queries binary-search. Locations feed `location.format_error`, which
renders the `file:line:col: <message>` prefix shared by syntax and type
errors; the coder also embeds `node.loc.line` into generated run-time
error messages. Checker-synthesized nodes reuse the location of the
node that triggered them, so error positions stay sensible.

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
`InterfaceMethod {name, params, rettypes, flexrettype}` node. An Interface
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

For `Owner<|T|>.member(...)`, the parser temporarily decorates the namespace
`ExpVar` with `_nominal_typeargs` and `_nominal_typeargs_loc`. The checker
resolves that owner application before selecting the member, and erased-core
lowering removes both fields before coder entry. `ExpCall.typeargs` remains the
callable-local list after a function or method name. The broader suffix grammar
also represents explicit arguments on a first-class expression candidate;
checking retains the existing direct-call-only restriction rather than silently
ignoring those arguments.

Three elaborated expression forms merit special attention:

* **`ExpAdjust`** is created by `defs.adjust_exp` when a call, vararg marker,
  spread, or subset is parenthesized. `(f())` adjusts the call to exactly
  one value, mirroring Lua; the checker propagates its scalar type but not its
  multiple-result `_types`. For `(...)`, the checker replaces the child with a
  nil-filling `ExpDotsIndex(1)` whose type is the optional vararg element.
  A parenthesized spread owns `_adjusted_spread` and one `ExpSpreadIndex`
  projection, so its subject and bounds execute once. Flow analysis visits that
  carrier for reads and writes, including catch-visible local mutations.
  Other parenthesized nodes retain `_parenthesized` for semantic lvalue
  rejection; they do not need an adjustment node.
* **`ExpExtra`** is created by the checker wherever a trailing call is
  consumed under a finite demand with more than one visible slot:
  `StatDecl`/`StatAssign` right-hand sides, `StatReturn` lists, call
  positional argument lists, and the finite prefixes of other consumers.
  Its `_type` may be a declared fixed result or an optionized projection from
  a flexible result tail. Open array/variadic/return tails are represented by
  call decorations rather than an unbounded list of `ExpExtra` nodes. A named
  argument is always one value. For
  `local a, b = f()` the
  checker appends `ExpExtra(loc, <the ExpCall>, 2, <type of value 2>)`
  to `node.exps`. Its `_type` is an underscore-prefixed constructor field
  declared in `ast.lua`, as is `ExpSpreadIndex._type`. Its `exp` points at a
  node occurring earlier in the same list: the tree is a DAG here, and codegen
  relies on the call being generated first (see `_extras` below).
* **`ExpSpreadIndex`** is created by finite expression-list demand. Its
  `spread` backreference points at the one `ExpSpread` carrier already present
  in lexical order, and every sibling projection shares that object identity.
  Generic lowering memoizes the carrier before descending and redirects every
  lowered projection to the same lowered carrier, preserving once-only subject
  and bound evaluation.

`ExpCast` likewise leads a double life: it is the AST for a written
`x as T`, and the checker's `trycoerce`/`tryforce`/`trytostr` synthesize
the same node for every legal implicit coercion. The code generator
emits conversions **only** from `ExpCast` nodes — see
[the type checker](checker.md). Casts synthesized by `trycoerce` additionally
carry `_implicit_coercion = true`; written `as` casts do not.

`ExpIs` is always written source. Its source/target relation is checked by the
same helper as a written `ExpCast`, but its own `_type` is `Type.Boolean` and
it never carries `_implicit_coercion`. It also does not rewrite or narrow its
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

At the semantic-type layer every Titan/Lua `Type.Function` shape carries a
separate `flexrettype` and keeps its ABI-2 third constructor position as a
required reserved `false`; Titan input tails live in `varargtype`. A direct
foreign module member instead retains the independent `Type.CFunction` shape,
with C's single-result model and `vararg` bit, and a C function pointer is
`Type.CPointer(Type.CFunction)`. No C signature is projected into
`Type.Function`. `Type.ModuleMember`, `Type.Method`, and `Type.StaticMethod`
also carry declaration-only `paramnames`. Structural `Type.Function` and
`Type.CFunction` deliberately do not carry parameter spellings: names must not
affect equality, callable adjustment, or native tags.

## Decorations: who writes what, who reads it

Passes communicate by adding underscore-prefixed fields to nodes. Most are
decorations assigned after construction; `_type` is also a declared constructor
field on `ExpExtra` and `ExpSpreadIndex`. This table inventories the durable
cross-pass fields (short-lived state used wholly inside one pass is omitted).

The computed scalar annotations `_read_guard`, `_array_writer_plan`,
`_spread_optional_guard`, `_spread_open_guard`, `_lua_write_dynamic_plan`,
`_dynamic_plan`, `_lua_vararg_dynamic_plan`, `_strict_vararg_guard_plan`,
`_bound_strict_vararg_guard_plan`, `_lua_open_result_dynamic_plan`,
`_strict_open_result_guard_plan`, `_written_cast`, and `_comparison` carry
`Maybe3` wrappers. Their constructors initialize `unknown`; successful checking
publishes `none` or `just`, and consumers unwrap through `get_checked`.
Parallel fixed-parameter/result plan arrays use one wrapper per slot, preserving
arity even when a slot has no plan. `Type.Field.dynamic_plan` and frozen strict
relay slot guards follow the same contract. Genuine boolean facts such as
`_always_returns` and `_nilfill` remain booleans.

| Field | On | Written by | Read by | Meaning |
| --- | --- | --- | --- | --- |
| `_type` | every Exp, Var, Decl, TopLevel node; the AST root | checker (on `ExpExtra` it is a positional constructor field) | checker, coder | the node's checker type (`Type.*`); on the root it is the `Type.Module` interface |
| `_types`, `_flexrettype`, `_callee_type` | `ExpCall` | checker | checker, coder | declared fixed results, declared flexible element, and complete callable type; `_callee_type` is `Type.Function` for Titan/Lua or the authoritative `Type.CFunction` for a direct/pointer C call |
| `_visible_types`, `_result_sources` | `ExpCall` | checker | checker, coder | finite results exposed to this consumer and whether each came from a fixed position or a possibly absent flexible projection |
| `_finite_flex_prefix`, `_flex_result_demand`, `_open_results` | `ExpCall` | checker | coder | finite projected tail count, finite/open demand marker, and the dynamic source/target/start description for an open sink |
| `_result_adjustment`, `_arg_adjustment`, `_positional_adjustment`, `_tuple_adjustment` | expression-list consumers | checker | coder | shared finite/open elaboration: delivered fixed/tail scalars, retained effect-only expressions, and at most one dynamic final source; `_positional_adjustment` serves both Arrays and exact integer-keyed Maps |
| `_spread_checked`, `_spread_kind`, `_spread_elem`, `_spread_optional_type`, `_spread_optional_guard`, `_spread_open_guard`, `_spread_subject_force` | `ExpSpread` (the subject-force marker also reaches its checker-built cast) | checker | checker generic finalization/lowering, coder | once-only subject classification, finalized finite/open element views and guards, and deferred rebuilding of an ordinary Option-container force |
| `_open_spread` | `ExpSpread` | checker | checker generic lowering, coder | raw-element open-run descriptor: source/target types and first projection not consumed by the finite prefix |
| `_nilfill` | `ExpSpreadIndex` | checker | coder | finite spread projection is absence-aware; its declared `spread` field retains the shared-carrier origin through target adjustment |
| `_coder_spread` | `ExpSpread` | coder | coder | prepared subject/range/count/result-run state shared by every generated projection and open sink |
| `_adjusted_spread` | `ExpAdjust` | checker | flow analysis, coder | the evaluated-once carrier for the scalar projection of a parenthesized spread |
| `_parsed_candidates` | `StatAssign` | parser, cleared by checker | checker | `vars` still contains prefix expressions awaiting lvalue validation |
| `_current_module_member` | normalized `VarName` | checker | checker | an `M.member` selection resolved against the module root rather than lexical shadows |
| `_ffi_scope` | C type descriptors | C declaration conversion | runtime identity rendering, source declaration persistence | retains declaration origin through typedef and pointer/array/function wrappers independently of the importing Titan module; anonymous aggregates retain distinct sites, and ordinary source display remains unqualified |
| `_allocation_result_root` | coder-synthesized `ExpCast` used by an open adjustment | coder adjustment dispatcher | coder cast lowering | optional sink-selected indexed slot into which the allocating cast publishes its final GC object exactly once |
| `_discard_results`, `_voidok` | expressions/calls | checker | checker, coder | evaluate under zero-result demand; calls may legally expose no result |
| `_npassed_args`, `_open_args` | `ExpCall` | checker | coder | statically passed argument count and a final dynamic run feeding an input-vararg tail |
| `_contextual_value_call`, `_contextual_function_type` | `ExpCall` | checker | coder, specs | the callee began as `value` and was checked against a function shape synthesized from argument/result demand |
| `_foreign_function_pointer` | `ExpVar` | checker | coder | a direct C declaration was contextually decayed to its exactly compatible `CPointer(CFunction)` target; stores the bare C spelling to cast |
| `_c_pointer_call` | `ExpCall` | checker | coder | authoritative `Type.CFunction` pointee for an indirect C call, including synthesized generic-for iterator/close calls |
| `_implicit_coercion` | `ExpCast` synthesized by `trycoerce` | checker | coder | distinguishes a demanded sink conversion from a user-written `as`; finite flexible-return lowering may suppress only the sink conversion after its result budget is exhausted |
| `_written_cast` | written `ExpCast`/`ExpIs` | checker | coder, linear-use pass | frozen written-cast plan; mutable-to-const Array casts carry `array_freeze` with `copy` or proven `freeze` mode |
| `_linear_array_freeze` | mutable-to-const `ExpCast` | post-typecheck linear-use pass | coder, specs | marks the conservative last-use proof that authorizes in-place retagging; absence means shallow copy |
| `_decl` | `VarName`, `VarDot` | checker | checker, coder | what the name resolved to: an `Ast.Decl` (local/param/`self`), a top-level AST node, a `Type.ModuleMember`/`Type.ModuleVariable`, a `Type.Field`/`Type.StaticMethod`, or the syntax-bound `Checker.CPseudoNew` allocation descriptor |
| `_used` | `Decl`, top-level nodes (via `_decl`) | checker, on every read: `ExpVar`, `VarDot` receivers, call callees | coder | "this variable is read somewhere"; unused locals get no C variable — their initializer is evaluated and cast to `(void)` |
| `_assigned` | `Decl` (via `_decl`) | checker, in `StatAssign` on `VarName` targets | coder | "this variable is reassigned"; GC-bearing parameters and `self` get a semantic local stack home only when assignment/spill requires it (otherwise they remain C formals and borrow existing allocation/result/semantic/VM provenance—native callers add no argument root; see [values and the GC](values-and-gc.md)) |
| `_record_constructor` | synthesized `TopLevelStatic` | parser record desugaring | checker | identifies the adjacent synthesized `Rec.new`; explicit record functions, including an explicit `Rec.new`, do not carry it |
| `_union_constructor`, `_union_variant` | synthesized `TopLevelStatic` | parser union desugaring | checker | identify an adjacent variant constructor and its `UnionVariant`; explicit union functions do not carry the markers |
| `_interface_conversion` | coercion-bearing expression, call adjustment, or written cast/test | checker | coder | frozen concrete-to-Interface wrapper plan, including ordered field snapshots, method mappings, and adapter graphs; the coder must not rerun structural matching |
| `_interface_test`, `_interface_downcast` | `ExpIs`/`ExpCast` | checker | coder | respectively a statically proven concrete-to-Interface test and an exact Interface-wrapper-to-concrete payload check |
| `_interface`, `_interface_method`, `_interface_method_index`, `_interface_bound` | Interface method call/reference | checker | coder | resolved Interface descriptor, method descriptor, declaration-order payload slot, and bound-reference marker |
| `_interface_field`, `_interface_field_index` | Interface field read | checker | coder | resolved target field descriptor and declaration-order snapshot user-value index |
| `_toplevel_order` | every AST root node | checker duplicate prepass | checker, symbol table | 1-based position in the unchanged flat/combined AST; drives duplicate winners and the module-variable import/variable visibility frontier |
| `_ignore` | top-level nodes | checker declaration stages: duplicate declarations, a duplicate record's synthesized constructor, and record functions/methods whose declaration fails (missing record, name clash, redeclaration) | body checker, `makemoduletype`, coder (`generate`, `allocate_upvalues`) | "pretend this node does not exist"; every later traversal must skip it |
| `_alias_state` | `TopLevelTypeAlias` | checker alias resolver | checker | `resolving`/`resolved` state used for lazy forward resolution and cycle detection; `_type` is the resolved RHS type itself |
| `_self` | `TopLevelMethod` | checker (`checkmethod`) | checker, coder | a synthesized `Ast.Decl` for `self`, typed as the record's nominal type; becomes the C parameter `__self__` |
| `_record` | `TopLevelStatic`, `TopLevelMethod` | checker nominal-member declaration stages | checker (`checkmethod`, for `self`'s type) | the `Ast.TopLevelRecord` or `Ast.TopLevelUnion` node the member belongs to; the historical field name is retained |
| `_union` | `StatCase` | checker | coder | the resolved `Type.Union` owner of the case scrutinee |
| `_variant`, `_variant_index` | `CaseArm` | checker | coder | the resolved `Type.Variant` and its absolute zero-based dispatch tag |
| `part`, `_part_loc` | `Decl` in a named `CaseArm.bindings` list | parser | checker, source analysis | selected source part name and location; the declaration's own `name` is its local alias, and positional bindings omit `part` |
| `_part`, `_part_index` | checked case-binding `Decl` | checker | generic lowering, coder | resolved `Type.Field` and its one-based logical part index; the variant's separate storage plan selects the native member or dense UV slot |
| `_always_returns` | every statement | checker | checker, coder | historical name for cached non-fallthrough analysis; a case is true when every arm is true and either its arms cover all `Type.Union.nvariants` or its reachable else is true, a literal-true `while` is true only when no reachable `break` targets it, and statement-list generation stops after any direct or compound true result |
| `_method` | `ExpCall` (method calls) | checker | coder | the resolved `Type.Method` |
| `_paramnames` | `TopLevelFunc` | checker callable-signature stage | checker, module-interface builder | dense names of fixed declared parameters; kept on the declaration rather than `Type.Function` |
| `_named_arg_order`, `_named_call_kind` | checked named `ExpCall` | checker | coder | formal indexes of explicit expressions in lexical order, plus `"titan"` or `"foreign"`; the `Args*` payload itself has already been normalized to formal order |
| `_named_omitted` | synthesized nil fill in a named call or record constructor | checker | coder assertions for named calls; specs | distinguishes checked omissions from explicit expressions while source-order lowering runs first |
| `_field` | `Field` (record constructors) | checker | coder | the resolved `Type.Field` descriptor, including synthesized omitted fields; its `index` is the zero-based logical declaration position, mapped independently to a native member or dense UV slot |
| `_omitted_initializer` | mutable `StatDecl` | checker | specs | the source omitted the expression list; checked nil expressions were synthesized for all declared slots |
| `_initializerless_const` | const `TopLevelVar` | checker | assignment authorization, coder | the source omitted the module initializer and passed the explicit nil-bearing-type rule; only its owner root initializer frame may assign it |
| `_forcontrol` | `Decl` | checker | checker | marks numeric and generic `for` control variables as read-only assignment targets |
| `_tuple_decls` | `StatForIn` | checker | coder | four hidden `Decl`s for iterator, state, initial control and close slots |
| `_result_decls` | `StatForIn` | checker | coder | hidden `Decl`s for the iterator return tuple, reused by the initial and update calls |
| `_init_call`, `_next_call`, `_close_call` | `StatForIn` | checker | coder | synthesized calls for the initial iterator call, update iterator call and optional close call; C function-pointer calls carry `_c_pointer_call` |
| `_visible_stat` | `StatForIn` | checker | coder | synthesized `StatDecl` that initializes the user-written loop variables from `_result_decls` each iteration |
| `_has_close` | `StatForIn` | checker | coder | whether a close may be present at run time; drives the generated `finally` wrapper |
| `_runtime_optional_close` | `StatForIn` | checker | coder | the close slot originated as `value`, so an exact run-time nil skips the synthesized close call while non-nil values use the ordinary callable path |
| `_forin_nil_guard` | `StatCall` synthesized by `codeforin` | coder | coder | the hidden close declaration whose `TValue` must be non-nil before emitting the ordinary close call inside the generated `finally` |
| `_cvar` | `Decl` | coder | coder | name of the C local holding the value: `_local_x_1`, `_param_x`, `__self__` |
| `_readonly` | synthesized `Decl` | checker | checker | marks compiler-built locals such as `L`; `declare` rejects shadowing them and assignment reports a read-only built-in local error |
| `_slot` | `Decl`, `TopLevelVar` | coder | coder | the `TValue` slot anchoring a GC-able value for the collector: a Lua stack slot (`_localslot_x_2` — the per-name counter is shared with `_cvar`, so the suffix is one past the `_cvar`'s — `_paramslot_x`, `__selfslot__`) or `&_mod->uv[N].uv` for module variables |
| `_upvalue` | `TopLevelVar`, `TopLevelImport`, imported `Type.ModuleVariable` members | coder (`allocate_upvalues`, `import_module`) | coder | index of the node's slot in the module `Udata`'s user-value array (see [the code generator overview](codegen-overview.md)) |
| `_body`, `_sig`, `_luabody` | `TopLevelFunc`/`Static`/`Method` | coder (`codefuncdec`) | coder (`generate`) | rendered C strings: the native function definition, its prototype, and the Lua-stack entry wrapper; `generate` concatenates them into the translation unit |
| `_extras` | `ExpCall` | coder (`codecall`) | coder (`ExpExtra` case of `codeexp`) | maps return-value index (≥ 2) to the C temporary that received that out-parameter; this is how an `ExpExtra` finds the value its call already produced |

Two practical consequences of this scheme:

* **Post-checker ASTs are self-referential.** `_decl` makes uses point
  at declarations, `_record` points across the top-level list,
  `ExpExtra.exp` points at a sibling. Naively printing such a tree
  (e.g. a luassert failure diff at unlimited table depth) does not
  terminate usefully — the `TableFormatLevel` hazard described in the
  test-suite notes of the repository `CLAUDE.md`.
* **Decorations are invisible to arity checks.** They are added by
  plain field assignment after construction, so nothing validates them:
  a misspelled decoration name (`node._typ` for `node._type`) fails only
  when read.

At the semantic layer, both records and unions use `Type.Nominal(fqtn)` as
their source-level value type. A union's registry entry is
`Type.Union(name, variants, functions, methods, nvariants)`, whose hybrid
dense/name map contains
`Type.Variant(fqtn, name, parts, index)` descriptors. Each `parts` list contains
ordered `Type.Field` entries with names, types, and one-based indexes within
that variant. A variant descriptor
is declaration and serialized-interface metadata only: `typefromnode` never
returns it as a source type, so annotations, aliases, `as`, and `is` may name
the union but not `Union.variant`.

Interfaces likewise use `Type.Nominal(fqtn)` in value-facing positions.
`Type.Interface(name, fields, methods, scope, typeparams)`, its ordered const
`Type.Field` entries, and its ordered `Type.Method` entries are registry and
serialized-module descriptors, not structural value types. This
keeps nominal Interface identity separate from the direct structural
satisfaction predicate.

## The cost of adding a node or type

All dispatch is hand-enumerated, so adding a tag is a cross-cutting
change. This is the checklist.

### Adding an `Ast.*` node

1. **`ast.lua`** — add the constructor entry (pick the group by
   documentation taste; it has no semantic effect).
2. **`parser.lua`** — if the node has surface syntax: add the grammar
   production. Constructors are auto-injected into the grammar's defs
   table by name, so `-> YourNode` works immediately. Every new error
   label the production uses (`^Label`, `%{Label}`) **must** get an
   entry in `syntax_errors.errors`, or error formatting crashes (see
   [lexer and parser](lexer-parser.md)).
3. **`checker.lua`** — add a handler to every `make_visitor` table the
   node can reach: `checkstat` (returning the correct non-fallthrough
   boolean), `checkexp`, `checkvar`, `typefromnode`, or
   `toplevel_visitor`. A new top-level kind must also be placed in the correct
   declaration stage and body-validation path, with `_ignore` handling in
   every later traversal. The visitors *assert* a handler exists, so a miss is
   a crash.
4. **`coder.lua`** — extend the relevant `if`/`elseif` chains
   (`codestat`, `codeexp`/`codevalue`, the lvalue cases of
   `codeassignment` — shared by single and multiple assignment —,
   `codefuncdec`/`generate` for top levels). The chains end in
   `error("invalid node tag ...")`,
   so a miss again crashes — but only when a program reaches codegen
   with the new node.
5. **Specs** — add parser/checker cases; because specs compare with the
   subset assertion (next section), existing tests will not break from
   new decorations, only from changed fields.

### Adding a `Type.*` type

1. **`types.lua`** — the constructor entry, plus every relevant operation:
   `types.equals`, `types.normalize`, `types.consistent` and
   `types.gradual_guard`, `types.coercion`,
   `types.dynamic_coercion`, `types.written_cast`, callable/assignment
   adjustment where applicable, `types.tostring` (the name users
   see in errors), and `types.serialize`, which raises
   `error("invalid tag ...")` for unknown tags — a non-serializable
   type breaks module interfaces (`<mangled>_types`) the moment it
   appears in an exported signature.
2. **Predicates** — classify the type in `types.is_basic`,
   `types.is_gc` (getting this wrong produces GC bugs, not type
   errors), and `types.is_truthy`/`is_falsy`.
3. **`checker.lua`** — teach `typefromnode` to produce it (if it has
   annotation syntax) and every context that inspects type tags
   (operators, indexing, calls, ...).
4. **`coder.lua`** — every per-type C-rendering function dispatches on
   type tags: `ctype`, `getslot`, `setslot`, `toboolean`, `checkandget`
   and `checkandset` end in `error("invalid type ...")`, so a miss
   crashes; `initval` and the semantically typed internal/boxed conversion
   helpers instead have broader defaults that may be silently wrong for a new
   type. Array demonstrates why C type alone is insufficient. See
   [values and the GC](values-and-gc.md) for what each must produce.
5. **Interop** — if values of the type cross the Lua boundary, the
   entry-wrapper checks in `genluaentry` and the record/module
   metatable paths need cases too
   ([Lua interop internals](lua-interop-internals.md)).

There is no compiler-enforced exhaustiveness anywhere in this list; the
enforcement is the test suite plus the `assert`/`error` crash on first
contact.

## How specs compare ASTs

`spec/parser_spec.lua` (and `spec/checker_spec.lua`, with its own copy)
compare trees with a *subset* assertion rather than deep equality:

```lua
-- Return a version of t2 that only contains fields present in t1 (recursively)
local function restrict(t1, t2)
    if type(t1) == 'table' and type(t2) == 'table' then
        local out = {}
        for k,_ in pairs(t1) do
            out[k] = restrict(t1[k], t2[k])
        end
        return out
    else
        return t2
    end
end
```

`assert_is_subset(expected, ast)` is then just
`assert.are.same(expected, restrict(expected, ast))`: the actual AST is
projected onto the keys present in the expected table — recursively —
before comparison. A test can therefore assert exactly the fields it
cares about:

```lua
assert_program_ast([[ local x = 17 ]], {
    { _tag = "Ast.TopLevelVar", islocal = true,
      decl = { name = "x" },
      value = { _tag = "Ast.ExpInteger", value = 17 } }
})
```

and stay silent about `loc`, `_tag`s it does not test, and every
decoration. This is what makes the decoration scheme evolvable: adding
a new `_whatever` field breaks **zero** existing tests — which is how
the checker grew `_type`, `_decl`, `_types` and the rest without
rewriting the parser specs. The flip side is that wrong *extra* fields
also pass unnoticed, so new behavior needs its own positive assertions.
New specs must follow this pattern; full-tree `assert.are.same` on a
post-checker AST would be brittle and risks the self-reference printing
hang described above.
