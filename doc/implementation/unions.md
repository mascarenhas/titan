# Union implementation

Unions add one nominal tagged-value family and one statement form without
introducing first-class variant types. The implementation spans the parser's
constructor synthesis, the checker's union and `case` passes, generated
userdata layout and tag dispatch, Lua exposure, and compiled-module
serialization. The language contract is in [Unions](../language/unions.md).

The cross-cutting invariants are:

* `Type.Union` is a nominal owner; `Type.Variant` is owner metadata only;
* every variant has a zero-based tag, public variants first and private
  variants afterward, each group in relative source order;
* each active variant has a native tag header and native members, plus dense
  uservalues only for GC-bearing parts;
* `case` coverage is optional, while complete coverage of the closed union can
  prove non-fallthrough without an `else`; and
* arms and `else` are ordinary full blocks, so `catch` and `defer` apply
  unchanged.

## AST and parser lowering

`ast.lua` declares these written nodes:

```text
Ast.TopLevelUnion(loc, name, variants, typeparams)
Ast.UnionVariant(loc, name, parts)
Ast.StatCase(loc, exp, arms, elseblock)
Ast.CaseArm(loc, name, bindings, block, named)
```

and one parser-synthesized expression:

```text
Ast.ExpUnionInit(loc, owner, variant, values)
```

`parts`, `bindings`, and `values` are dense lists, empty when absent.
`elseblock` is `nil` when absent. Each part and binder is an `Ast.Decl`; a
named binder carries `.part`, the selected source part name. The arm records
`.named` even when its braces are empty.

The grammar makes `union`, `case`, and `when` reserved words. A union
declaration has one or more variants, each optionally followed by a semicolon:

```text
["local"] "union" Name union-variant+ "end"
union-variant ::= ["local"] AnyName "("
    ( ")" | &(AnyName ":") part {"," part} ")" | type ")" ) [";"]
part ::= AnyName ":" type
```

A case parses its arms before the optional else block:

```text
"case" expression
    ("when" AnyName ("(" [Name {"," Name}] ")"
        | "{" {namedbinder [fieldsep]} "}") "then" block)*
    ["else" block]
"end"
```

The payload form is chosen by the two-token lookahead `&(ANYNAME COLON)`,
which cannot begin a Titan type. The chosen list or single-type branch then
descends into the type grammar once, with committed labels for missing names,
colons, types, and closing parentheses. Neither branch admits a flexible tail.
Named binders use `NAME` on the left and `ANYNAME` after `=`.
`defs.namedcasebindings` rejects a part selected twice (`DuplicateCasePart`).

The `block` after `then` and `else` is the ordinary compound-statement
production, so it becomes either a plain `Ast.StatBlock` or the `Ast.StatTry`
produced by a trailing `catch`. There is no restricted case-body grammar.

`defs.uniondecl` (`parser.lua`) returns the `Ast.TopLevelUnion` followed by
one synthesized `Ast.TopLevelStatic` per variant. An empty variant produces a
zero-parameter function. Other variants receive one parameter per part, with
the declared name and type; `defs.unionpayload` names the single-type
shorthand's part `value`. The body returns an `Ast.ExpUnionInit` of the
parameters in declaration order, and the static is marked:

```lua
constructor._union_constructor = true
constructor._union_variant = variant
```

The checker identifies genuine constructors by these markers, not by spelling;
they are the union counterpart of `_record_constructor`. The constructor's
`StaticMethod` publishes the ordered part names as `paramnames` (an empty list
for an empty variant), so ordinary named-call checking supplies evaluation
order, omissions, coercion, and generic inference. The module-initializer
dependency check (`isconstructor` in `checker/declarations.lua`) treats a call
as generated construction only when its nominal metadata validates against the
owner/variant projection. Such a call stores its arguments, which are still
checked by the dependency rule, rather than exposing them to a callee. A
user-written static that merely returns its owner is an ordinary call; an own
one is an own-function dependency.

The type grammar allows at most one qualifier component. A local
`Message.move` written as an `as`/`is` target reaches `Ast.TypeQualName` and
reports "union member '%s.%s' is not a type; use union type '%s' or a case
statement". An imported `m.Message.move` has three components and is a parse
error. Both enforce the boundary without a variant-type AST node.

## Type descriptors

`types.lua` defines:

```text
Type.Union(name, variants, functions, methods, nvariants, scope, typeparams)
Type.Variant(fqtn, name, parts, index)
```

`Type.Union.variants` has a dense source-order array plus name keys pointing at
the same `Type.Variant` objects. `nvariants` is the total declared count,
including private variants. `Type.Variant.parts` is a dense ordered list of
`Type.Field(fqtn, name, type, index, false)`, where `index` is the **1-based
logical part index** and names are unique within the variant. Parts have no
independent locality or const qualifier. `Type.Variant.index` is the zero-based
runtime tag. Because public variants take the low tags, the position in the
dense array is not the tag.

`Type.Nominal(fqtn)` is the value type for both records and unions.
`typefromnode` never returns a `Type.Variant` as a source type, and the
identity, consistency, coercion, written-cast, and comparison operations reject
it explicitly instead of letting it through a same-tag or `value` rule.

Union equality compares the owner name and the complete variant, function, and
method schema. Variant equality compares owner, name, absolute index, and part
schema. Run-time identity is still the nominal metatable; schema equality
serves checked and rehydrated interface descriptors.

## Declaration checking and visibility

Unions are staged with records in `checktoplevel`; the order of passes is in
[staged top-level collection](checker.md#staged-top-level-collection-and-body-checking).
The `Ast.TopLevelUnion` handler of `toplevel_visitor`
(`checker/declarations.lua`) resolves every part, assigns tags, and registers
the `Type.Union` under its fully qualified name before constructors, callables,
module variables, and bodies are checked. The synthesized constructors are
then checked as nominal statics. User methods and functions share the record
`TopLevelMethod`/`TopLevelStatic` nodes and namespaces. As with records, the
current module's unions are module-wide and imported unions may appear in
aliases, fields, payloads, signatures, and bodies even when the import is
written later; module-variable initializers keep their earlier-import frontier.

The handler reports:

| Diagnostic | Cause |
| --- | --- |
| "union '%s' must declare at least one variant" | empty declaration |
| "redeclaration of variant '%s' in union '%s'" | duplicate variant name |
| "redeclaration of payload part '%s' in variant '%s.%s'" | duplicate part name |
| "variant '%s.%s' declares %d payload parts but at most 65534 are supported" | logical arity limit; `driver.lua` applies the same bound to recovered variants |

Tag assignment counts public variants from 0 and private variants from the
public count, without reordering declarations or part checking. Serialization
omits private variants but keeps the public tags and the owner's total
`nvariants`, so adding a private variant cannot shift a public tag.

Before locality metadata is discarded, `validate_union_source_projections`
(`checker/declarations.lua`, called from `checker/entry.lua` when there are no
errors) runs `types.validate_union_source_projection` over
`types.public_union_projection`. It proves that each variant is published or
omitted together with its constructor, that constructor arity, part types,
result, and ordered parameter names match the variant, and that a local union
publishes no nominal member. A failure reports "invalid public projection for
union '%s': %s".

## Payload eligibility

Nominal storage eligibility is separate from general TValue boxability.
Complete fixed non-GC C aggregates and fixed arrays may be copied into a
variant, and their projections borrow interior pointers. GC-bearing content,
including exact C TValue and Udata pointers, stays traced. Public foreign-type
export restrictions still apply. A Titan Array part stores its backing `Table`
in a traced UV slot; projection reads the backing directly and only a real Lua
or `value` boundary boxes it into its proxy. Native C numbers stay exact until
a conversion or boxing boundary. [Native nominal storage](nominal-storage.md)
owns recursive eligibility and fresh tail plans.

## Case checking and control flow

The `Ast.StatCase` handler (`checker/statements.lua`):

1. checks the scrutinee and calls `tryforce`, so `Union?` is forced to
   `Union`;
2. requires the resulting nominal to be a visible `Type.Union` ("case
   expression must have a union type, but found '%s'", "union type '%s' is
   local to module '%s'");
3. resolves each arm name to a variant ("variant '%s' not found in union
   '%s'") and rejects repeats ("duplicate case arm for variant '%s', previous
   one at %s");
4. opens one sibling block scope per arm;
5. resolves each positional or named binder to its part and declares it at the
   exact part type ("payload part '%s' not found in variant '%s.%s'", "empty
   variant '%s.%s' has no payload to bind", "variant '%s.%s' has only %d
   payload parts to bind");
6. checks the arm's full block; and
7. checks the optional `else` block.

The force happens before dispatch, so nil raises through the ordinary option
force and never selects `else`.

It annotates:

```text
StatCase._union
CaseArm._variant, CaseArm._variant_index
CaseArm.bindings[i]._type, ._part, ._part_index
```

No variant value type is introduced.

**Binder visibility.** A binder is declared in the arm scope, outside the
arm's `StatTry`, so the protected body and the sibling `catch` see it. Locals
declared inside the protected body keep the
[error-handling rule](error-handling.md#checker-rules) that hides them from the
`catch`. A `defer` is lowered within its arm's block by the ordinary
[defer lowering](defer.md) and cannot cross into another arm; `return`,
`break`, and `raise` take the same cleanup path as from an `if` branch.

**Non-fallthrough.** The handler's boolean result, which `checkstat` stores
as `_always_returns`, is

```text
every arm is non-fallthrough
and (unique valid visible arms == union.nvariants
     or the else block is non-fallthrough)
```

`nvariants` counts every declared variant, including those hidden from an
imported interface, so an importer cannot prove complete coverage by listing
every visible variant and needs a non-fallthrough `else` instead. With complete
coverage an `else` is unreachable and its fallthrough does not affect the
result, although it is still checked. This is a control-flow proof only: it
neither requires coverage nor diagnoses omitted variants. The rules for other
statements are in [non-fallthrough analysis](checker.md#non-fallthrough-analysis).

When complete coverage supplies the proof and an explicit `else` does not
terminate on its own, the handler also sets `_binary_closed_union` to the
union name. `checker/binary_usage.lua` then adds the union's total variant
count to the consumer's compatibility requirements, so a provider that adds a
private variant rejects that unchanged consumer at load time. Cases still fall
through on no match; no trap is generated. See [Construction and closed-union
proofs](binary-compatibility.md#construction-and-closed-union-proofs).

## Run-time representation

A union value is one Lua `Udata *` whose metatable is the exact identity of
its fully qualified union type, separate from every record and other union.
Each variant has its own generated payload struct, which begins with a
`_titan_union_header` subobject holding the unsigned tag and is followed by the
variant's native parts. Only traced parts occupy dense UV slots. Allocation
uses the active variant's generated size and traced count, so an empty variant
has only a tag header and no UV. Logical 1-based part indices are independent
of native member names and UV indices. The physical layout plans are in
[Native nominal storage](nominal-storage.md#traced-and-native-regions).

`coder._codeunioninit` (`coder/expressions.lua`) allocates with
`luaS_newudata`, roots the userdata, installs the metatable, writes the tag,
and stores each part through `coder._nominal_store` and the variant's
`coder._nominal_plan`. Traced stores use `luaC_barrierback`; native members are
untraced.

Boxing into `value` keeps the same userdata, and checked conversion back
compares the exact union metatable, as for records. An explicit C `void *`
cast exposes only the userdata address. There is no structural lowering
between Titan unions and C unions.

## Generated case dispatch

`coder._codecase` (`coder/statements.lua`) materializes the scrutinee once,
reads the header tag with `coder._nominal_tag`, and emits a `switch` that
contains only `goto` entries:

```c
switch (_case_1_tag) {
    case 0: goto _case_1_arm_0;
    case 2: goto _case_1_arm_1;
    default: goto _case_1_else;
}
```

The labeled arm bodies live **outside** the C switch. Each body initializes
its binders with `coder._nominal_read` through the variant's storage plan and
`coder._codeinitializeddecl`, emits the checked block, and jumps to the common
end label. A binder is therefore an ordinary local: unboxed scalars copy, while
records, unions, Arrays, Maps, and functions keep their identity or backing,
with no `value` boxing; closure capture and catch spills use the ordinary local
machinery. This shape means that:

* Titan arms cannot fall through;
* an absent `else` lowers to an empty default body; and
* Titan `break` targets the enclosing Titan loop, not the dispatch switch.

Case labels use `ctx.case_id`, a per-function counter, so nested cases get
distinct labels. Each arm and the else body push their own declaration and
spill scopes. Statement-list generation stops after a statement whose
`_always_returns` is true, as described in
[codegen constructs](codegen-constructs.md#unions-and-case).

For generic code, `generic_lower_case` (`checker/lowering.lua`) projects each
bound part to its erased carrier in a `StatBlock` placed before the arm's
original block, outside any `StatTry`, so a trailing `catch` sees every binder.

## Functions, namespaces, and Lua exposure

Variant constructors, user union functions, and union methods use the ordinary
native function convention and canonical first-class `CClosure`s. Lua calls
are positional; constructor `paramnames` serve only Titan named calls.

Every nominal owner gets a private namespace-table module slot. For an
exported union, the module's read-only member map exposes that table as
`m.Union`, with public constructors and user statics installed from their
canonical closure slots. Private variants and statics are absent.

`coder._codeuniondec` (`coder/module.lua`) builds the instance metatable:

* `__index` checks the receiver against the exact union metatable, then serves
  the public method map, reporting "member '%s' not found in union '%s'"
  otherwise, so methods cannot be borrowed onto another nominal;
* `__newindex` always raises "cannot assign member '%s' in union '%s'";
* no variant, tag, or payload member is present; and
* `__metatable` is the protected string `"Titan union <fqtn>"`.

The same function publishes the reflection metadata keys, including the
`TITAN_MT_PAYLOAD` reader that boxes parts of public and private variants. The
key inventory is in [Discoverable runtime type
information](lua-interop-internals.md#discoverable-runtime-type-information),
and reflection's use of each key is in
[Reflection: metadata ownership](standard-library-reflect.md#metadata-ownership).

A union can satisfy an Interface when every required name resolves to a
visible union method with an adjustable self-removed callable shape; variants
and union functions never count as methods, and an Interface with fields needs
a record. The wrapper keeps the union `Udata` in user value 1 and exposes no tag
or payload. See [Interfaces](interfaces.md#direct-structural-satisfaction).

## Serialized interfaces and ABI boundary

`types.serialize` writes canonical schemas:

```text
Union(fqtn, { public Variant... },
      { public static-name = StaticMethod... },
      { public method-name = Method... },
      total_nvariants)

Variant(fqtn, name, { Field(fqtn, part_name, type, part_index, false)... },
        absolute_index)
```

It serializes `types.public_union_projection`: variants keep source order,
statics and methods are sorted with `util.bytewise_less`, private variants and
members are omitted, `absolute_index` keeps the public-first tag, and
`total_nvariants` keeps the full count. Physical storage plans travel in a
separate native layout inventory.

`validate_union_interface` (`driver.lua`) treats recovered unions as part of a
closed descriptor language. `Variant` is legal only in its owner's variant
list, never as a value type. The validator checks the variant count, the dense
variant list and name map, strictly increasing in-range unique tags, dense
uniquely named parts with canonical owner and index, recursive part
eligibility, one matching constructor per variant (parameter names and types
equal to the parts, one owner result, no tails or generic binders), and
collisions among the variant, function, and method namespaces. The shared
value-graph rules (no wrapper descriptors, nonlocal members, dense `paramnames`)
are in [Interfaces: separate compilation and schema
validation](interfaces.md#separate-compilation-and-schema-validation).

Public union constructors and statics occupy the module userdata's public
prefix ([user-value allocation](codegen-overview.md#user-value-allocation)),
so a consumer obtains the exact canonical closure without loading a Lua
namespace table. The union schemas, the userdata and tag protocol, and that
prefix are part of the compiled-module ABI; a mismatched interface is rejected
before type rehydration or native linking. Load-time compatibility is separate:
a replacement provider is checked only for the used callables, the referenced
public variant shape, and any closed-inventory proof, so unrelated methods and
private variants may change.

## Standard-library use

The regex parser (`titan/string/regex_parser.titan`) stores variant-specific
syntax data directly in named `RegexNode` parts, and its passes bind only the
parts they need. The private `SpawnSlot.merged` variant in `titan/os/process.native.titan`
holds its child/parent stream pair directly. Records that own behavior,
mutable shared state, or a reused domain type remain records, including libuv
request owners and TCP state.

Reflection's `Value` and `Type` unions use parts for simple data alternatives;
[union payloads](standard-library-reflect.md#union-payloads) describes the
indexed reader. JSON maps union part names directly into the discriminator
object, and the unnamed `value` part keeps the single-payload format; see
[JSON](json-library.md).
