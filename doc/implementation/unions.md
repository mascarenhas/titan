# Union implementation

Unions add one nominal tagged-value family and one statement form without
introducing first-class variant types. The implementation spans the parser's
constructor synthesis, the declaration-frontier checker, generated userdata
layout and tag dispatch, Lua exposure, and compiled-module serialization.

The language contract is in [Unions](../language/unions.md). The important
cross-cutting invariants are:

* `Type.Union` is a nominal owner; `Type.Variant` is owner metadata only;
* every variant has a zero-based tag, public variants first and private
  variants afterward, preserving relative source order within each group;
* each active variant has a native tag header and native members, plus dense
  uservalues only for GC-bearing parts;
* `case` coverage is optional, while complete coverage of the closed static
  union can prove non-fallthrough without an `else`;
* arms and `else` are ordinary full blocks, so existing
  `catch`/`finally`/`defer` machinery applies unchanged; and
* imported first-class nominal statics require the ABI-visible public module
  prefix described below.

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
`elseblock` uses `false` for absence. Each part and binder is an `Ast.Decl`;
a named binder carries `.part`, the selected source part name. The arm
records `.named` even when its braces are empty.

The grammar makes `union`, `case`, and `when` reserved keywords. A union
declaration has one or more variants; the parser accepts an optional
semicolon after each variant:

```text
["local"] "union" Name union-variant+ "end"
union-variant ::= ["local"] AnyName "("
    ( ")" | &(AnyName ":") part {"," part} ")" | type ")" ) [";"]
part ::= AnyName ":" type
```

A case parses its sequence of arms before the optional else block:

```text
"case" expression
    ("when" AnyName ("(" [Name {"," Name}] ")"
        | "{" {namedbinder [fieldsep]} "}") "then" block)*
    ["else" block]
"end"
```

The payload decision uses only the positive two-token lookahead
`&(ANYNAME COLON)`: that prefix cannot begin a Titan type. The chosen list or
single-type branch then descends into the type grammar once, with committed
labels for missing names, colons, types and closing parentheses. Neither branch
admits a flextail. Folded captures retain linear flat-list construction.
Named binders use ordinary `NAME` on the left and `ANYNAME` after `=`;
the parser rejects duplicate selected part names before checking.

The `block` after `then` and `else` is the same grammar production used by
other compound statements. It may therefore become either a plain
`Ast.StatBlock` or the `Ast.StatTry` wrapper produced by a trailing `catch`
clause. Source `finally` remains reserved and unused; internal cleanup
lowering may populate the existing finally representation. No restricted
"case body" grammar exists.

`defs.uniondecl` returns the `Ast.TopLevelUnion` followed immediately by one
synthesized `Ast.TopLevelStatic` per variant. An empty variant produces a
zero-parameter function. Other variants receive one parameter for each part,
using the declared name and type; the single-type shorthand becomes the part
`value`. Its body returns `Ast.ExpUnionInit` with the corresponding variable
expressions in declaration order, and
the static is annotated with:

```lua
constructor._union_constructor = true
constructor._union_variant = variant
```

The checker uses those markers rather than the function spelling to identify
genuine constructors. This is the union counterpart of
`_record_constructor`. Published `paramnames` now contains the ordered part
names (including an empty list), so ordinary named-call checking supplies
evaluation order, omissions, coercion and generic inference.
The module-constant classifier accepts only a constructor whose nominal
metadata validates against its owner/variant projection, with recursively
constant arguments. It does not use the broad heuristic “static returns its
owner,” so user-written owner-returning functions remain nonconstant.

The ordinary type grammar has at most one qualifier component. A local
`Message.move` written as an `as`/`is` target therefore reaches
`Ast.TypeQualName` and receives the semantic “variant is not a type” error.
An imported `m.Message.move` has three components and is rejected by the
parser. Both outcomes enforce the same boundary without adding a
variant-type AST node.

`lexer.ANYNAME` admits keyword spellings in member selectors, named argument
labels, and declaration positions that permit them, including union variants.
`lexer.NAME` still rejects reserved words in bare expression-name positions.
These rules apply to Titan and C members without a C-only selector token.

## Type descriptors

`types.lua` adds:

```text
Type.Union(name, variants, functions, methods, nvariants)
Type.Variant(fqtn, name, parts, index)
```

`Type.Union.variants` has both a dense source-order array and name keys that
point at the same `Type.Variant` objects. `nvariants` is the total declared
count, including private variants. `Type.Variant.parts` is a dense ordered
list of `Type.Field(fqtn, name, type, index, false)` descriptors. Here the
field index is the **1-based logical payload-part index**, and names are unique
within the variant. Parts have no independent locality or const qualifier.
The variant index is the zero-based runtime tag. Public variants occupy the
initial range in relative source order; private variants follow in relative
source order. The dense array itself remains in source order, so its position
must not be confused with the tag.

`Type.Nominal(fqtn)` remains the source-level value type for both records and
unions. A `Type.Variant` is never returned by `typefromnode` as a legal source
type. A qualified lookup that reaches a variant diagnoses that the union
member is not a type, including from type annotations, aliases, `as`, and
`is`. The identity, consistency, coercion, written-cast, and comparison
operations also reject `Type.Variant` explicitly instead of allowing it to
participate through a generic same-tag or `value` rule.

Union equality checks the owner name and complete variant/function/method
schema. Variant equality checks owner, name, absolute index, and payload
schema. Run-time value identity is still nominal-metatable identity; schema
equality is for checked and rehydrated interface descriptors.

## Declaration staging and visibility

`checktoplevel` reserves a `TopLevelUnion` with the other nominal
declarations. The union pass resolves every payload and registers the
`Type.Union` under its fully qualified name before constructor, callable,
module-variable, and body checking proceeds. The synthesized constructors are
then checked as nominal statics. User-declared union methods and functions
share the existing `TopLevelMethod` and `TopLevelStatic` nodes and namespaces
with record members.

The complete staging order remains one pass over the unreordered combined
AST:

1. mark ordinary duplicate winners and `_toplevel_order`;
2. precollect aliases;
3. reserve imports, records, unions, functions, and module variables;
4. visit imports in AST order;
5. resolve aliases;
6. resolve record fields and union variants;
7. check synthesized constructors;
8. check ordinary callable and initializer signatures;
9. check record/union methods and statics;
10. check module variables in AST order; and
11. check bodies.

This gives unions record parity. The current module's unions are module-wide.
Imported unions may appear in aliases, fields, payloads, signatures, and
bodies even when the written import is later. Module-variable initializers
retain their earlier-import frontier, including qualified constructor uses
nested inside a lambda evaluated by the initializer. A type alias may bridge
to a later import because alias resolution is a placement-independent type
frontier.

Private unions and variants remain in the local registry. Tag assignment
counts public variants first without reordering declarations or payload
checking. Serialization omits private variants while preserving public variant
indices and the owner's total `nvariants`. A private addition therefore cannot
shift a public tag.

Before locality metadata is discarded, the producer calls
`types.validate_union_source_projection` over the exact
`types.public_union_projection`. It proves that every local/public variant is
omitted/published together with its matching constructor, that constructor
arity, part types, result and ordered parameter names agree with the variant, and that a
local union publishes no nominal member.

## Payload eligibility

The checker uses nominal storage eligibility separately from general TValue
boxability. Complete fixed non-GC C aggregates and fixed arrays may be copied
into a record or variant; their projections borrow interior pointers. Unsized
array declarations become uncounted pointer views. GC-bearing content, including
exact C TValue and Udata pointers, always remains traced. Public foreign-type
export restrictions still apply. See [Native nominal storage](nominal-storage.md)
for recursive eligibility and fresh tail plans.

Titan Array parts store their internal backing Table in a traced UV slot.
Projection reads the backing directly; a real Lua/value boundary boxes it into
its canonical proxy. Native C numbers stay exact until an actual conversion or
boxing boundary.

## Case checking and control flow

The `Ast.StatCase` checker:

1. checks the scrutinee and calls the ordinary `tryforce`, so `Union?`
   auto-unwraps to `Union`;
2. resolves the resulting nominal owner and requires `Type.Union`;
3. resolves each visible arm name to a variant;
4. rejects repeated variants;
5. opens one sibling block scope per arm;
6. resolves each positional or named binder to its part, rejects nonexistent
   parts and excess positional binders, and declares it at the exact part type;
7. checks the arm's full block; and
8. checks the optional `else` block.

The option force happens before dispatch. Nil therefore raises through the
ordinary option-cast path and never selects `else`.

The arm binding is declared outside the arm's `StatTry`, so it is visible to
the protected body and sibling `catch`/`finally` clauses. Locals declared
inside the protected body retain the error-handling rule that keeps them out
of those sibling clauses.

`checkstat` records its boolean result on every statement as
`node._always_returns`. The case checker counts unique valid visible arms and
compares them with `Type.Union.nvariants`, which is the total declaration count
and includes variants hidden from an imported interface. A case returns true
when every arm returns true and either the count covers that closed set or the
optional `else` returns true. Complete coverage makes a redundant `else`
unreachable, so its fallthrough does not defeat the result; the block is still
checked. Conversely, an importer cannot name hidden variants and therefore
needs a non-fallthrough `else` to establish the same fact. This proof does not
require case coverage or diagnose omitted variants. The coder consumes the
shared decoration for direct terminators and compound `StatBlock`, `StatIf`,
`StatTry`, and `StatCase` nodes rather than re-deriving reachability from their
immediate tags.

When complete coverage supplies the proof and an explicit `else` does not
independently terminate, the checker also records `_binary_closed_union`.
Per-consumer compatibility requirements then include that union's total
inventory count. An added private variant rejects the unchanged consumer at
load time. Ordinary cases still fall through on no match; no trap or coverage
requirement is introduced. See [Selective binary dependency
verification](binary-compatibility.md#construction-and-closed-union-proofs).

The case checker annotates:

```text
StatCase._union
CaseArm._variant
CaseArm._variant_index
CaseArm.bindings[i]._type
CaseArm.bindings[i]._part
CaseArm.bindings[i]._part_index
```

No variant value type is introduced.

Binder lowering uses the ordinary internal `getslot` conversion into a local,
so it has normal assignment semantics: unboxed scalars copy, while records,
unions, arrays, maps, and function values preserve their existing
identity/backing. It does not insert a Lua/value boxing boundary. Because the
binder is an ordinary arm-local declaration, a nested lambda captures it
through the normal box analysis and catch/finally lowering spills and roots it
through the existing local machinery.

## Defer and error handling

The defer parser transformation operates recursively on every ordinary
`block`. Because case arms and the else clause consume that same production,
no union-specific defer lowering exists. A defer is folded into nested
`Ast.StatTry`/`finally` structure within its containing arm and cannot cross
into a later arm.

The checker and coder likewise treat an arm's `Ast.StatTry` through the
existing pending-action machinery. `return`, `break`, and `raise` take the
same cleanup path they would from an `if` branch. A binding is established
before entering that protected boundary and remains rooted while catch and
finally execute.

## Run-time representation

A union value is a Lua 5.5 `Udata *` whose metatable identifies its fully
qualified union type. Every variant payload begins with an actual common header
subobject containing an unsigned tag, followed by its native parts. Only traced
parts occupy dense UV slots. Allocation uses the active variant's generated C
size and traced count; an empty variant has a tag header and zero uservalues.

The constructor roots the userdata immediately, installs the metatable, writes
the tag and initializes parts through their layout plan. UV writes retain normal
GC barriers; native members are untraced. The existing conservative logical arity
limit remains 65,534, independently of physical UV usage.

The metatable is separate from every record metatable and from other unions.
`value` boxing stores the userdata, checked conversion back to the union
compares the exact metatable, and an explicit C `void *` cast exposes only the
userdata identity. There is no Titan-union/C-union structural lowering.

## Generated case dispatch

`coder._codecase` evaluates and materializes the scrutinee once, reads
the raw common-header tag, and emits a tag-only `switch`. The switch contains
only `case tag: goto arm_label;` dispatch entries:

```c
switch (_case_1_tag) {
    case 0: goto _case_1_arm_0;
    case 2: goto _case_1_arm_1;
    default: goto _case_1_else;
}
```

The labeled arm bodies live **outside** the C switch. Each body extracts
each selected part through its native-member or dense-UV plan, emits the normal checked block, and jumps to the
common end label. This shape has three useful properties:

* Titan arms cannot fall through;
* an absent `else` naturally lowers to an empty default body; and
* Titan `break` still targets the enclosing Titan loop rather than the
  implementation's dispatch switch.

Nested cases use monotonically allocated case IDs. Arm bodies push ordinary
defer and spill scopes, so nested functions, catch/finally boundaries, and GC
roots use the existing machinery.

## Functions, namespaces, and Lua exposure

Generated variant constructors, user union functions, and union methods use
the existing native function convention and canonical first-class
`CClosure`s. Constructor descriptors publish the part names; user functions
retain their declared parameter-name metadata. Lua calls themselves remain positional.

Every nominal owner receives a private namespace-table module slot. For an
exported union, the module's read-only member map exposes that table as
`m.Union`. Public constructors and user statics are installed in it from their
canonical closure slots. Private variants/statics are absent.

A union instance's Lua metatable exposes only public methods:

* `__index` serves the bound method table and reports other names missing;
* `__newindex` rejects every write;
* no variant, tag, or payload member is present; and
* `__metatable` is the protected string `"Titan union <fqtn>"`.

Like records, union metatables carry discoverable runtime reflection metadata:
* `TITAN_BRAND`: lightuserdata key set to integer constant `TITAN_UNION` (4);
* `TITAN_MT_TYPE`: lightuserdata key set to the serialized union type descriptor (`Union(...)`);
* `TITAN_MT_MEMBERMAP`: lightuserdata key holding the public method map table (the `__index` table);
* `TITAN_MT_STATICS`: lightuserdata key holding the union's static-namespace table containing variant constructors and static functions;
* `TITAN_MT_PAYLOAD`: lightuserdata key holding the generated typed payload reader used by reflection; index 0 returns the active tag, -1 returns arity, and positive indices box parts; its switches cover public and private variants;
* Registered in the per-state global metatables table `_titan_metatables[<fqtn>]` (`TITAN_METATABLES_KEY`), alongside the reverse pointer map in the Lua registry (`registry[metatable_pointer] = <fqtn>`).

The `__index` entry first performs the same exact nominal metatable check used
by other Lua entry wrappers. Methods therefore cannot be borrowed onto a
different union or record userdata.

Like a record, a union can directly satisfy an Interface when every required
name resolves to a visible union method with an adjustable self-removed
callable shape. Variants and union functions do not count as methods, even
when their names collide with an Interface slot. The resulting wrapper retains
the original union Udata in user value 1; a written Interface-to-union cast
checks that payload's exact union metatable. No union tag or payload is exposed
through Interface dispatch. See [Interfaces](interfaces.md).

## Serialized interfaces and ABI boundary

`types.serialize` adds canonical schemas:

```text
Union(fqtn, { public Variant... },
      { public static-name = StaticMethod... },
      { public method-name = Method... },
      total_nvariants)

Variant(fqtn, name, { Field(fqtn, part_name, type, part_index, false)... },
        absolute_index)
```

Variants retain source order. Static and method maps are serialized in
`util.bytewise_less` name order. Private variants and members are omitted,
while `absolute_index` preserves the public-first tag and `total_nvariants`
preserves the full inventory count. A separate
native layout inventory carries physical storage plans. The recursive compiled-interface validator accepts these constructors
only as fields of a valid module/nominal schema; it does not make
`Type.Variant` a source type.

Recovered interfaces are treated as a closed descriptor language.
Value-facing type graphs cannot smuggle wrapper descriptors such as
`ModuleMember`, `Field`, `Method`, `StaticMethod`, or `Variant`; the latter is
legal only in its owning union's variant list. Error-recovery/no-value markers,
nested modules, C FFI descriptors, legacy wrappers, and unknown tags are not
value types and are rejected by the same walk. Every callable descriptor's
`paramnames`, when present, must be a dense, unique list exactly matching its
fixed parameter arity. Every recovered module wrapper, public nominal,
listed field or variant, and nominal callable must also be nonlocal: locality
was already removed by the producer's public projection, so a truthy
`islocal` decoration is malformed metadata. Union validation additionally
checks the dense/name variant map, strictly increasing unique absolute tags,
total count, dense uniquely named part lists with canonical owner/slot indices,
recursive part eligibility, matching constructor parameter names/types, and collisions among variant, function,
and method namespaces before the interface can be used. Record validation
requires public fields in increasing absolute-index order. An all-public
record must carry `new`, whose parameter types and names exactly match those
ordered fields; a record with omitted private fields instead omits that
constructor. Field names remain disjoint from the record's static and method
namespaces.

The reconstructible public prefix of every module userdata allocates:

1. exported module variables in module-member order;
2. exported top-level function closures in module-member order; then
3. every exported static closure of each public record or union, walking
   nominal owners in module-member order and their statics in bytewise name
   order.

Private slots follow that prefix. This lets a consumer obtain an imported
record constructor, union constructor, or user nominal static as the exact
canonical first-class closure without loading a Lua namespace table or
inventing another identity.
Separate dynamic consumers resolve the required canonical closure slot from a
provider-owned data symbol; they do not embed the earlier producer's prefix
index. Self-owned and same-binary slots retain constant indices, and direct
native calls do not read closure slots.

The union schemas, userdata/tag protocol, and public-prefix layout are part of
ABI 2 together with Array and function representations, Interface and generic
metadata, source-private provider identity, callable symbol hierarchy, and
serialized const/member state. A mismatched interface is rejected before type
rehydration or native linking. This schema validation is separate from
load-time compatibility: a replacement DSO checks only used concrete callables,
the referenced union's public variant shape, and any relied-upon closed
inventory proof. Its unrelated methods or private variants may change.

`TITAN_VERSION` is `0.6.0`; its derived `0.6` library version selects
`TITAN_PATH_0_6`, `lib/titan/0.6`, and `stdlib_0_6`. Build preparation replaces
only exact known active artifacts and establishes ABI-keyed caches. Earlier
Titan installations are not migrated or cleaned up.

## Standard-library use

The regex parser in `titan.string` stores variant-specific syntax data directly
in named `RegexNode` parts. Named case binders select only each pass's needed
values. Backreference validation returns a node with its final nullability;
it no longer mutates an intermediate wrapper record. The private process
`SpawnSlot.merged` variant similarly holds its child/parent stream pair directly.
Records that own behavior, mutable shared state, or a reused domain type remain
records, including libuv request owners and TCP state.

Reflection exposes ordered public part descriptors and indexed active-value
reads. Its `Value` and `Type` unions use parts for simple data alternatives,
while method-owning accessors and shared nominal/callable descriptors keep
records. The generated reader accepts a 1-based part index and reads its direct
slot; `UnionValue:get(i)` owns bounds checks and keeps the union alive. Generic
lowering converts each initialized part to its erased carrier and projects
each bound part independently, including reordered named bindings. Projections
precede the entire arm block so a trailing `catch` sees every binder.

JSON maps union part names directly into the discriminator object in both
directions. The unnamed `value` part preserves the existing single-payload
format. See the [reflection](standard-library-reflect.md) and
[JSON](json-library.md) chapters for those library contracts.
