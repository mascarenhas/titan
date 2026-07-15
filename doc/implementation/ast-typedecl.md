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

The same factory builds the checker's semantic types:
`types.lua` calls `typedecl("Type", ...)`, producing tags like
`"Type.Integer"` and `"Type.Record"`. Some type values are
*not* made through `typedecl` and break its conventions:
`types.Module` is a hand-written function (its `members` table is both
an array and a name-keyed map), and the FFI's `Type.Pointer`,
`Type.Typedef` and `Type.Unknown` are ad-hoc table literals built in
`foreigntypes.lua` (which also emits `Struct`/`Union`
placeholder tables that drop the `Type.` prefix entirely).
Code that walks types must tolerate all of them. See
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
| `checkstat` | `Ast.Stat*` | boolean "this statement always returns", used by the return-path analysis |
| `checkvar` | `Ast.Var*` lvalues | nothing (annotates the node) |
| `checkexp` | `Ast.Exp*` | nothing (annotates the node) |
| `toplevel_visitor` | `Ast.TopLevel*` | nothing (pass 1 of the checker) |

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
`P <- {} => get_loc` captures the byte position at the start of every
node-producing production and converts it with `location.from_pos`,
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
| `TypeName` | `name` | a bare name in type position (records) |
| `TypeQualName` | `module`, `name` | `mod.Name` (both strings) |
| `TypeArray` | `subtype` | `{T}` |
| `TypeMap` | `keystype`, `valuestype` | `{K: V}` |
| `TypeFunction` | `argtypes`, `rettypes` | `t -> t`, `(t, t) -> (t, t)` (both lists) |
| `TypeOption` | `basetype` | the `?` suffix, `T?` |

### Top-level nodes

| Constructor | Fields | Notes |
| --- | --- | --- |
| `TopLevelFunc` | `islocal`, `name`, `params`, `rettypes`, `block` | `params` is a list of `Decl` |
| `TopLevelMethod` | `class`, `name`, `params`, `rettypes`, `block` | `function Class:name(...)`; parser decorates `islocal` |
| `TopLevelStatic` | `class`, `name`, `params`, `rettypes`, `block` | `function Class.name(...)`, plus synthesized `Class.new`; parser decorates `islocal` |
| `TopLevelVar` | `islocal`, `decl`, `value` | module variable |
| `TopLevelTypeAlias` | `islocal`, `name`, `type` | compile-time-only `[local] type Name = T` |
| `TopLevelRecord` | `name`, `fields` | `fields` is a list of `Decl`; parser decorates `islocal` |
| `TopLevelImport` | `localname`, `modname` | `local m = import "x.y"` |
| `TopLevelForeignImport` | `localname`, `headername` | `local c = foreign import "x.h"` |

`TopLevelStatic` covers record functions. The parser creates one directly for
`function Class.name(...)`, and also creates one from the `record` desugaring
(`defs.recorddecl` in `parser.lua`), which turns each record into *two*
top-level nodes — the `TopLevelRecord` plus a synthesized `new` record function
with one parameter per field, in field order. The parser copies `local record`
to both the record and `new`, and also makes `new` local when any field is
local:

```lua
record Point
    x: float
    y: float
end
-- parses as if the program also contained:
-- function Point.new(x: float, y: float): Point
--     return { x = x, y = y }
-- end
```

### Declarations and the `option` flag

`Decl = {loc, name, type, option}` is used for locals, numeric and
generic `for` control variables, function parameters, record fields, and
`TopLevelVar`. The
`type` field is an `Ast.Type*` node *or `false`* (type to be inferred),
and `option` is a boolean marking the bare-`?` inference form:

| Source | `type` field | `option` field |
| --- | --- | --- |
| `x: integer` | `TypeInteger` node | `false` |
| `x?: integer` | `TypeOption(TypeInteger)` node | `false` |
| `x?` | `false` | `true` |
| `x` | `false` | `false` |

That is, `x?: T` is eagerly desugared into an option *annotation*,
while a bare `x?` defers to the checker, which infers the initializer's
type and optionizes it (`local y? = arr[1]` gives `y : integer?` where
`local y = arr[1]` gives `y : integer`). Parameters and record fields
require an annotation and admit no `?` mark on the name. A record field `Decl`
may carry `islocal = true`, set by the parser for `local field: T`.

### Statements

| Constructor | Fields | Notes |
| --- | --- | --- |
| `StatBlock` | `stats` | also used for `do ... end` and every block body |
| `StatWhile` | `condition`, `block` | |
| `StatRepeat` | `block`, `condition` | note the field order: block first |
| `StatIf` | `thens`, `elsestat` | `thens` is a flat list of `Then {condition, block}` (one per `if`/`elseif`); `elsestat` is a `StatBlock` or `false` |
| `StatFor` | `decl`, `start`, `finish`, `inc`, `block` | `inc` is `false` when the step is omitted; the checker fills in a literal `1`/`1.0` |
| `StatForIn` | `decls`, `exps`, `block` | generic `for decllist in explist`; the checker pads/elaborates `exps` as the iterator tuple |
| `StatAssign` | `vars`, `exps` | multiple assignment lists |
| `StatDecl` | `decls`, `exps` | `local` with lists; initializers are mandatory |
| `StatCall` | `callexp` | a call in statement position |
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
| `ExpCall` | `exp`, `args` | `args` is an `ArgsFunc` or `ArgsMethod` |
| `ExpVar` | `var` | |
| `ExpUnop` | `op`, `exp` | `op` ∈ `"not"`, `"#"`, `"-"`, `"~"` |
| `ExpBinop` | `lhs`, `op`, `rhs` | `op` is the literal operator string (`"+"`, `"=="`, `"and"`, ...) |
| `ExpConcat` | `exps` | `..` is flattened to one n-ary node at parse time; all-literal operands are constant-folded into an `ExpString` |
| `ExpCast` | `exp`, `target` | written `as` casts **and** every checker-materialized implicit coercion |
| `ExpAdjust` | `exp` | synthesized by the parser only: a parenthesized *call*, truncated to its first value |
| `ExpExtra` | `exp`, `index`, `_type` | synthesized by the checker only: the index-th (> 1) value of a multi-return call |

Two of these never come from the programmer directly:

* **`ExpAdjust`** is created by `defs.adjust_exp` in the parser when a
  call is parenthesized: `(f())` adjusts the call to exactly one value,
  mirroring Lua, and the checker's handler implements the truncation by
  propagating `exp._type` but deliberately not `_types`. Parentheses
  around anything other than a call vanish from the AST entirely
  (`((1))` is just `ExpInteger 1`).
* **`ExpExtra`** is created by the checker wherever a multi-return call
  is the last item of a list whose remaining slots it fills:
  `StatDecl`/`StatAssign` right-hand sides, `StatReturn` lists, call
  argument lists, and array initializers. For `local a, b = f()` the
  checker appends `ExpExtra(loc, <the ExpCall>, 2, <type of value 2>)`
  to `node.exps`. Its `_type` is a *positional constructor field* — the
  only underscore-prefixed decoration declared in `ast.lua` itself —
  and its `exp` points at a node occurring earlier in the same list:
  the tree is a DAG here, and codegen relies on the call being
  generated first (see `_extras` below).

`ExpCast` likewise leads a double life: it is the AST for a written
`x as T`, and the checker's `trycoerce`/`tryforce`/`trytostr` synthesize
the same node for every legal implicit coercion. The code generator
emits conversions **only** from `ExpCast` nodes — see
[the type checker](checker.md).

### Call arguments and constructor fields

`ArgsFunc {args}` and `ArgsMethod {method, args}` (`method` is the name
string after `:`). `Field {name, exp}` is one entry of an
`ExpInitList`, and `name` encodes the three field forms:

| Source form | `name` |
| --- | --- |
| `exp` (positional) | `false` |
| `name = exp` | the name string |
| `[keyexp] = exp` | the key *expression node* |

## Decorations: who writes what, who reads it

Passes communicate by adding underscore-prefixed fields to nodes. None
of these are declared anywhere; this table is the inventory.

| Field | On | Written by | Read by | Meaning |
| --- | --- | --- | --- | --- |
| `_type` | every Exp, Var, Decl, TopLevel node; the AST root | checker (on `ExpExtra` it is a positional constructor field) | checker, coder | the node's checker type (`Type.*`); on the root it is the `Type.Module` interface |
| `_types` | `ExpCall` | checker | checker, coder | full return-type list of a call; enables `ExpExtra` expansion and multi-return out-parameters. `ExpAdjust` deliberately does not propagate it |
| `_decl` | `VarName`, `VarDot` | checker | checker, coder | what the name resolved to: an `Ast.Decl` (local/param/`self`), a top-level AST node, a `Type.ModuleMember`/`Type.ModuleVariable`, a `Type.Field`, or a `Type.StaticMethod` |
| `_used` | `Decl`, top-level nodes (via `_decl`) | checker, on every read: `ExpVar`, `VarDot` receivers, call callees | coder | "this variable is read somewhere"; unused locals get no C variable — their initializer is evaluated and cast to `(void)` |
| `_assigned` | `Decl` (via `_decl`) | checker, in `StatAssign` on `VarName` targets | coder | "this variable is reassigned"; GC-able parameters and `self` get their own Lua stack slot only when set (otherwise the caller's anchoring suffices — see [values and the GC](values-and-gc.md)) |
| `_ignore` | top-level nodes | checker pass 1: duplicate declarations, and record functions/methods whose declaration fails (missing record, name clash, redeclaration) | checker pass 2, `makemoduletype`, coder (`generate`, `allocate_upvalues`) | "pretend this node does not exist"; every later traversal must skip it |
| `_alias_state` | `TopLevelTypeAlias` | checker alias resolver | checker | `resolving`/`resolved` state used for lazy forward resolution and cycle detection; `_type` is the resolved RHS type itself |
| `_self` | `TopLevelMethod` | checker (`checkmethod`) | checker, coder | a synthesized `Ast.Decl` for `self`, typed as the record's nominal type; becomes the C parameter `__self__` |
| `_record` | `TopLevelStatic`, `TopLevelMethod` | checker pass 1 | checker (`checkmethod`, for `self`'s type) | the `Ast.TopLevelRecord` node the member belongs to |
| `_method` | `ExpCall` (method calls) | checker | coder | the resolved `Type.Method` |
| `_field` | `Field` (record constructors) | checker | coder | the resolved `Type.Field` descriptor; its `index` is the record `Udata` user-value slot (`uv[index].uv`) the field occupies |
| `_forcontrol` | `Decl` | checker | checker | marks numeric and generic `for` control variables as read-only assignment targets |
| `_tuple_decls` | `StatForIn` | checker | coder | four hidden `Decl`s for iterator, state, initial control and close slots |
| `_result_decls` | `StatForIn` | checker | coder | hidden `Decl`s for the iterator return tuple, reused by the initial and update calls |
| `_init_call`, `_next_call`, `_close_call` | `StatForIn` | checker | coder | synthesized calls for the initial iterator call, update iterator call and optional close call; C function-pointer calls carry `_c_pointer_call` |
| `_visible_stat` | `StatForIn` | checker | coder | synthesized `StatDecl` that initializes the user-written loop variables from `_result_decls` each iteration |
| `_has_close` | `StatForIn` | checker | coder | whether the close slot statically typechecked as a close callable; drives the generated `finally` wrapper |
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
   node can reach: `checkstat` (returning the correct "always returns"
   boolean), `checkexp`, `checkvar`, `typefromnode`, or
   `toplevel_visitor` (remember the pass-1/pass-2 split, and that
   handlers must skip `_ignore`d nodes). The visitors *assert* a
   handler exists, so a miss is a crash.
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

1. **`types.lua`** — the constructor entry, plus *every relation, by
   hand*: `types.equals`, `types.compatible` (and `types.coerceable`
   if the type coerces implicitly), `types.tostring` (the name users
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
   crashes; `initval`, `setwrapped` and `copyslotwrapped` instead have
   catch-all defaults that may be silently wrong for a new type. See
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
      decl = { name = "x", type = false },
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
