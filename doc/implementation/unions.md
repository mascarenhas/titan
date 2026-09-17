# Union implementation

Unions add one nominal tagged-value family and one statement form without
introducing first-class variant types. The implementation spans the parser's
constructor synthesis, the declaration-frontier checker, generated userdata
layout and tag dispatch, Lua exposure, and compiled-module serialization.

The language contract is in [Unions](../language/unions.md). The important
cross-cutting invariants are:

* `Type.Union` is a nominal owner; `Type.Variant` is owner metadata only;
* every variant has an absolute, zero-based declaration-order tag;
* empty values have only a tag user value, payload values have one additional
  user value;
* `case` coverage is optional, while complete coverage of the closed static
  union can prove non-fallthrough without an `else`;
* arms and `else` are ordinary full blocks, so existing
  `catch`/`finally`/`defer` machinery applies unchanged; and
* imported first-class nominal statics require the ABI-visible public module
  prefix described below.

## AST and parser lowering

`ast.lua` declares these written nodes:

```text
Ast.TopLevelUnion(loc, name, variants)
Ast.UnionVariant(loc, name, payload)
Ast.StatCase(loc, exp, arms, elseblock)
Ast.CaseArm(loc, name, binding, block)
```

and one parser-synthesized expression:

```text
Ast.ExpUnionInit(loc, owner, variant, value)
```

`payload`, `binding`, `elseblock`, and an empty constructor's `value` use
`false` for absence, following the existing AST convention.

The grammar makes `union`, `case`, and `when` reserved keywords. A union
declaration has one or more variants; the parser accepts an optional
semicolon after each variant:

```text
["local"] "union" Name union-variant+ "end"
union-variant ::= ["local"] AnyName "(" [type] ")" [";"]
```

A case parses its sequence of arms before the optional else block:

```text
"case" expression
    ("when" AnyName "(" [Name] ")" "then" block)*
    ["else" block]
"end"
```

The `block` after `then` and `else` is the same grammar production used by
other compound statements. It may therefore become either a plain
`Ast.StatBlock` or the `Ast.StatTry` wrapper produced by a trailing `catch`
clause. Source `finally` remains reserved and unused; internal cleanup
lowering may populate the existing finally representation. No restricted
"case body" grammar exists.

`defs.uniondecl` returns the `Ast.TopLevelUnion` followed immediately by one
synthesized `Ast.TopLevelStatic` per variant. An empty variant produces a
zero-parameter function. A payload variant receives one deliberately hidden
parameter named `__union_payload`. Its body returns `Ast.ExpUnionInit`, and
the static is annotated with:

```lua
constructor._union_constructor = true
constructor._union_variant = variant
```

The checker uses those markers rather than the function spelling to identify
genuine constructors. This is the union counterpart of
`_record_constructor`, but its published `paramnames` is always `false`, so
named-call checking cannot reinterpret the hidden parameter as source API.
The module-constant classifier accepts only a constructor whose nominal
metadata validates against its owner/variant projection, with recursively
constant arguments. It does not use the broad heuristic “static returns its
owner,” so user-written owner-returning functions remain nonconstant.

The ordinary type grammar has at most one qualifier component. A local
`Message.move` written as an `as`/`is` target therefore reaches
`Ast.TypeQualName` and receives the semantic “variant is not a type” error.
An imported `m.Message.move` has three components and is rejected by the
parser. Both outcomes enforce the same v1 boundary without adding a
variant-type AST node.

`lexer.CNAME` is the raw-identifier token used only in contextual C member and
qualified-type positions. It allows imported C symbols whose spelling is a
Titan keyword, including the new `when`, while `lexer.NAME` continues to
reject keywords in ordinary Titan declarations and expressions. It
generalizes the same separation already used by `NAMEDLABEL` for C prototype
parameter labels.

## Type descriptors

`types.lua` adds:

```text
Type.Union(name, variants, functions, methods, nvariants)
Type.Variant(fqtn, name, payload, index)
```

`Type.Union.variants` has both a dense source-order array and name keys that
point at the same `Type.Variant` objects. `nvariants` is the total declared
count, including private variants. `Type.Variant.payload` is either a checked
type or `false`; `index` is the absolute zero-based source-order tag.

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

Private unions and variants remain in the local registry and keep their
absolute tag positions. Serialization omits them while preserving public
variant indices and the owner's total `nvariants`.

Before locality metadata is discarded, the producer calls
`types.validate_union_source_projection` over the exact
`types.public_union_projection`. It proves that every local/public variant is
omitted/published together with its matching constructor, that constructor
arity/payload/result and `paramnames=false` agree with the variant, and that a
local union publishes no nominal member.

## Payload eligibility

The checker applies `types.has_tvalue_representation` to both record fields
and union payloads. This is an intentional shared rule, not a separate union
whitelist: both locations are stored in a Lua-traced user-value slot.

The predicate permits ordinary Titan values, including `Type.Function`, and
the supported boxable C scalars/object pointers, exact `TValue`, `Udata *`,
and owned-storage forms. It rejects direct C aggregates, C arrays, direct C
functions, and C function pointers. Applying the predicate to records as part
of this feature closes the
older mismatch in which a field could be declared even though no safe
user-value representation existed.

Array payloads are a representation-sensitive case. Generated Titan code
stores the internal `Table *` backing in the payload `TValue`, not the
Lua-facing proxy userdata. Extraction reads that backing directly. Boxing to
a proxy still happens only at an actual Lua/value boundary, preserving the
one-proxy-per-backing invariant.

## Case checking and control flow

The `Ast.StatCase` checker:

1. checks the scrutinee and calls the ordinary `tryforce`, so `Union?`
   auto-unwraps to `Union`;
2. resolves the resulting nominal owner and requires `Type.Union`;
3. resolves each visible arm name to a variant;
4. rejects repeated variants;
5. opens one sibling block scope per arm;
6. declares an optional payload binder at the variant payload type, rejecting
   a binder for an empty variant;
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

The case checker annotates:

```text
StatCase._union
CaseArm._variant
CaseArm._variant_index
CaseArm.binding._type
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
qualified union type:

```text
empty variant:   luaS_newudata(L, 0, 1)
payload variant: luaS_newudata(L, 0, 2)

uv[0] = integer absolute variant tag
uv[1] = payload, when present
```

There is no reserved raw payload and no hidden user value beyond these slots.
The empty representation's absence of `uv[1]` is why binding an empty variant
must be rejected statically.

`coder._codeunioninit` roots the new userdata immediately, installs the
union's metatable, writes the integer tag, lowers the payload with the normal
internal `setslot` conversion, and emits `luaC_barrierback` when the payload
may be collectable. The ordinary `Type.Nominal` C representation remains
`Udata *`.

The metatable is separate from every record metatable and from other unions.
`value` boxing stores the userdata, checked conversion back to the union
compares the exact metatable, and an explicit C `void *` cast exposes only the
userdata identity. There is no Titan-union/C-union structural lowering.

## Generated case dispatch

`coder._codecase` evaluates and materializes the scrutinee once, reads
`ivalue(&u->uv[0].uv)`, and emits a tag-only `switch`. The switch contains
only `case tag: goto arm_label;` dispatch entries:

```c
switch (_case_1_tag) {
    case 0: goto _case_1_arm_0;
    case 2: goto _case_1_arm_1;
    default: goto _case_1_else;
}
```

The labeled arm bodies live **outside** the C switch. Each body extracts
`uv[1]` when it has a binder, emits the normal checked block, and jumps to the
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
`CClosure`s. Constructor descriptors force `paramnames=false`; user functions
retain their declared parameter-name metadata.

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
* `TITAN_MT_PAYLOAD`: lightuserdata key holding the generated typed payload reader used by reflection; its tag switch covers public and private variants and boxes their payloads normally;
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

Variant(fqtn, name, payload-or-false, absolute_index)
```

Variants retain source order. Static and method maps are serialized in
`util.bytewise_less` name order. Private variants and members are omitted,
while `absolute_index` and `total_nvariants` preserve the producer's native
layout. The recursive compiled-interface validator accepts these constructors
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
total count, constructor projection, and collisions among variant, function,
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

The union schemas, userdata/tag protocol, and public-prefix layout are part of
ABI 2 together with Array and function representations, Interface and generic
metadata, source-private provider identity, callable symbol hierarchy, and
serialized const/member state. A mismatched interface is rejected before type
rehydration or native linking.

`TITAN_VERSION` is `0.6.0`; its derived `0.6` library version selects
`TITAN_PATH_0_6`, `lib/titan/0.6`, and `stdlib_0_6`. Build preparation replaces
only exact known active artifacts and establishes ABI-keyed caches. Earlier
Titan installations are not migrated or cleaned up.

## Standard-library dogfooding

The regex parser in `titan.string` uses private unions for its internal
regex-AST alternatives. Constructors replace the former record-plus-kind
convention, and compiler passes dispatch with `case`. This is intentionally a
private implementation conversion: the public string/regex API and provider
key set do not change.

The conversion is useful coverage for payloads containing records and Arrays,
nested cases, local variants, and case use across the folder-module
contributors. It must not expose tags or payloads through an auxiliary public
API merely to simplify the implementation.
