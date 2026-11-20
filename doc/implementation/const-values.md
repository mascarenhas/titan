# Const-value implementation

Const bindings, const record and Interface fields, and const-qualified Arrays
cross the parser, semantic descriptors, checker, generated C, Lua boundary,
and compiled-module metadata. The language contract lives across
[`const` locals](../language/statements.md#const-locals),
[`const` module variables](../language/modules.md#const-module-variables),
[`const` record fields](../language/records.md#const-fields),
[Interface field snapshots](../language/interfaces.md#field-snapshots), and
[read-only Arrays](../language/arrays-maps.md#read-only-and-maybe-const-arrays).
This chapter records the
cross-pass invariants that must stay aligned when the implementation changes.

## Frontend and AST contract

`const` qualifies bindings and Titan Arrays. Inside a raw foreign type it
qualifies the C pointer or array; ordinary mixed type positions spell that
boundary explicitly, for example `foreign const *T`.

The relevant AST constructors (`titan-compiler/ast.lua`) are:

```lua
Ast.TypeArray(loc, subtype, isconst)
Ast.Decl(loc, name, type, option, isconst)
Ast.TopLevelVar(loc, islocal, isconst, decl, value)
Ast.TopLevelInterface(loc, name, members, fields, methods, typeparams)
```

`TypeArray.isconst` is exactly `{tag="no"}`, `{tag="yes"}`, or
`{tag="maybe"}`; declaration `isconst` flags remain exact booleans.
`TopLevelVar.value == nil` preserves an omitted module initializer until the
checker validates and normalizes it. `TopLevelInterface.members` retains
source order, while `fields` and `methods` are independent ordered
projections. Interface fields reuse `Ast.Decl` and are created with
`isconst == true`.

The parser admits:

- `[local] [const] decl [= exp]` at module scope, with an annotation or RHS;
- `(local? const) decllist = explist` in a statement block;
- `local decllist [= explist]` for mutable locals;
- `[local] [const] name : type` in records; optionality belongs to the type;
- `name: type` and bodyless method signatures in Interface bodies; and
- `const { type }` and `const? { type }` as qualified Array types.

The Titan `const { T }` production is separate from foreign pointer parsing
and rejects Map syntax. `{ foreign const *T }` is a mutable Titan Array
whose element type is a const C pointer, subject to its normal representation
and operation restrictions. Const-local grammar always commits to
`= explist`; only mutable `local` uses the optional expression-list
production.

`parser.lua` `defs.recorddecl` synthesizes `Record.new` with one ordinary
(non-const) parameter per field, in field order, and the body
`return { field = field, ... }` as an `Ast.ExpInitList`. Construction
therefore populates const fields through an initializer list, never through
assignment, so later assignment checks need no constructor exemption.

## Semantic descriptors and serialization

The descriptor constructors (`titan-compiler/types.lua`) require their
qualifier axes rather than defaulting absent metadata to mutable:

```lua
Type.Array(elem, isconst)
Type.Field(fqtn, name, type, index, isconst)
Type.ModuleVariable(modname, name, type, isconst)
Type.Interface(name, fields, methods, scope, typeparams)
```

The Array qualifier is part of type equality, consistency, guard and
dynamic-plan identity, rewriting, substitution, erasure, stringification, and
serialization. `types.tostring` renders mutable `{ T }`, const `const { T }`,
and maybe-const `const? { T }`. The Array constructor, serializer, and
compiled-interface validator accept exactly `{tag="no"}`, `{tag="yes"}`, and
`{tag="maybe"}` (`types.valid_array_constness`), including Arrays nested in
public fields, callable signatures, Options, and containers. An absent or
otherwise malformed qualifier is rejected rather than defaulted. Compare the
`tag` field, never wrapper identity or truthiness. Serialized constructors
retain the tagged table, for example `Array(Integer(),{tag="maybe"})`. A
maybe-const descriptor introduces no third runtime Array representation.

Interface `fields` and `methods` are separately dense, source-ordered
list/name-map projections. Their names share one namespace. A field is a
canonical `Type.Field` owned by the Interface, has its zero-based target slot,
and must carry `isconst == true`. Record fields and module variables retain
their own required boolean. The closed validator rejects a missing/non-boolean
field or module-variable qualifier, sparse or keyed input, duplicate or
cross-kind member names, incorrect owners or indices, and descriptors placed
outside their allowed owner graph. Validator placement and the ABI check that
precedes it are in
[Interface recovery and the closed validator](driver.md#interface-recovery-and-the-closed-validator).

## Checker rules for declarations

`types.accepts_missing_nil` is the shared narrow predicate for omitted local
initializers, initializer-less module variables, callable missing-result
fill, and other missing-slot rules. It admits Nil, Value, Option, and CPointer
targets: the actual nil-bearing representation domain, not general assignment
adjustment. In particular, truthiness cannot make a Boolean declaration
initializer-less.

For a mutable `StatDecl` with no expression list
(`checker/statements.lua`, the `Ast.StatDecl` visitor), the checker:

1. requires every declaration to have a written type;
2. resolves and validates each type;
3. requires `accepts_missing_nil` for each slot;
4. synthesizes one `Ast.ExpNil` per declaration; and
5. runs the ordinary finite expression-list adjustment so the coder sees the
   same normalized shape as an explicit nil list.

Const locals arrive only with an expression list. Their `Decl.isconst` flag is
checked after lvalue resolution and before `_assigned` bookkeeping, which keeps
rejected closure and direct writes from incorrectly selecting mutable capture
storage.

Initialized const and mutable `TopLevelVar` nodes share the
[initializer dependency check](checker.md#staged-top-level-collection-and-body-checking)
in `checker/declarations.lua`. This is a runtime initialization-safety rule,
not constant folding: foreign values/calls and earlier imported members/calls
are valid, while evaluating a reference to an own-module variable, function,
or method is not. Lambdas, bound own methods, own Interface implementations,
and own method-bearing record/union values may be stored because creating them
runs no body; they are rejected where an explicit or implicit call evaluated
by the initializer could invoke them. The shared check classifies Map index,
equality, length, and spread dispatch; an operation whose dispatching operands
all have fixed origins creates no Map exposure. Constness adds no separate
exception or exposure state.

Every initializer-less `TopLevelVar` requires an explicit nil-bearing type;
the checker replaces `value == nil` with a checked `ExpNil`. A const one also
receives `_initializerless_const` and its owning `_module_name`
(`checker/declarations.lua`). `checkfuncbody` records the owning module name
as `module_initializer` on the synthetic root-initializer frame.
`const_module_write_authorized` (`checker/statements.lua`) admits a write to
that slot only when the innermost function frame is that marked frame and the
owners match: nested blocks remain in the frame, while a nested
lambda/function or an importing module does not inherit permission. The rule
does not count assignments or implement definite assignment.

`check_const_assignment` (`checker/statements.lua`) is the central lvalue
check. It rejects writes to const locals, const module variables (local and
imported), const record and Interface fields (`Type.Field.isconst`), and
elements of const or maybe-const Arrays, and marks the lvalue
`_const_write_rejected`. C lvalue analysis also rejects mutation reached
through a const local's inline struct/union/array storage and excludes that
declaration from mutable address-taking and decay. Encountering a pointer or
owned value ends the inline-storage walk, preserving shallow pointee
mutability.

## Interface fields

Interface fields are const snapshots. Satisfaction requires the visible
same-name concrete field to be const, then freezes an ordinary assignment plan
from its type to the Interface field type; unions fail any field-bearing
Interface. Applied generic Interfaces substitute owner arguments through
fields exactly as through methods, and a constrained type parameter exposes
the applied Interface's field reads as well as its methods. Field access on an
Interface resolves to the target descriptor and wrapper snapshot slot and is a
read-only lvalue category. The mapping, diagnostics, pair-inventory worklist,
and wrapper layout are in
[Interfaces](interfaces.md#direct-structural-satisfaction) and
[Wrapper representation](interfaces.md#wrapper-representation).

## Array relations and linear-use analysis

The three static Array qualifiers share one runtime representation; the
proxy metatable distinguishes the two concrete tags
([Runtime Array pair](#runtime-array-pair)). The relations
(`types.lua` `assignment_adjustment` and `written_cast`) are:

| Source → target | Implicit sink | Written `as` | Runtime effect |
| --- | --- | --- | --- |
| `{S}` → `const { T }` | only when the source type is `linear` | `array_freeze` | `copy`: shallow copy; `freeze`: in-place freeze |
| `const { S }` → `{T}` | rejected | rejected | — |
| `{S}` or `const { S }` → `const? { T }` | identity or gradual view | `maybe_array_cast_upcast` | none; the carrier is preserved |
| `const? { S }` → `{T}` / `const { T }` | rejected | `maybe_array_cast_mutable` / `_const` | exact metatable check of the target qualifier |

Every cross-qualifier row requires equal or gradually consistent element
types. Written casts and freezes attach an `element_view` when the elements
differ. Ordinary `consistent` requires matching qualifier tags; assignment
widening admits the outer qualifier change separately and uses consistency
only to check the element types.

The widening never copies or freezes the Array. With equal elements the
checker emits an identity plan for both bare Array and Option-to-Option
widening. A gradually consistent element change instead keeps the strict
target guard on a structural view; for an Option, this checks only the
present payload's outer representation before deferring element checks to
reads. At an implicit sink either form of Array widening can be the inner
operation of `option_wrap` or `option_force`. The coder validates that plan
and reuses the Array backing without a payload conversion. The outer
operation still introduces presence or checks for `nil`.
Static `is` for `array_freeze` and the upcast is allocation-free
(`allocation_free_test`) and reports admission without converting; the
maybe-const downcasts test the runtime metatable. A `value is/as` Array plan
tests the target qualifier's metatable, and a `const? { T }` target accepts
either. The predicate also recognizes the corresponding backed Array in
mixed internal slots. No `is` test allocates or retags an Array.

`array_freeze` copies by default. `titan-compiler/checker/linear.lua`
selects `freeze` only when it proves that the cast consumes the allocation's
last mutable reference. There are two proofs, and the coder trusts their
result without recomputing escape or liveness facts.

**Builder local.** `select_linear_array_freezes` runs once after the module
is checked (`checker/entry.lua`). In each block, a candidate is a
single-name `local` declaration of a mutable Array type that is not
`_captured`, initialized from a fresh constructor or a `linear` call result
(`fresh_mutable_array_declaration`). A later statement in the same block must
be a `local` declaration or `return` whose single expression is a copy-mode
`array_freeze` cast of exactly that local, with no other use in that
statement (`sole_consuming_cast`). Every statement in between may use the
local only as a non-escaping builder (`builder_uses_are_non_escaping`):
`#array`, indexed reads and writes, and arbitrary control flow, calls, and
closures that neither receive nor reference it. No statement after the cast
may name the local. On success the plan's `mode` becomes `freeze` and the cast
is marked `_linear_array_freeze` (read only by specs). Passing, returning,
storing, aliasing, capturing, or rebinding the Array, a cast nested in a call
argument or wrapped by an implicit sink conversion such as `value` injection,
or any use the classifier does not recognize keeps `copy`.

**Linear function results.** `annotate_linear_function_returns` runs at the
end of `checkfuncbody` for error-free top-level functions, methods, and
statics. When every `return` supplies a mutable Array result position with a
fresh constructor, a non-escaping builder local returned by its sole use, or
an already `linear` value (`is_linear_returned_value`), it replaces that
result type with a mutable Array type carrying `linear = true`. Bodies are
checked in declaration order, so only later direct callers in the same module
see the mark: `written_cast` then selects `freeze` immediately, and
`assignment_adjustment` admits the call result at an implicit `const { T }`
sink. A first-class reference strips the mark
(`checker/expressions.lua` `strip_linear_from_type`), so a function value
never carries it. The protobuf decoder relies on both proofs
([decoding](protobuf-library.md#decoding)).

The positional constructor checker selects a concrete qualifier when it
assigns the expression's type, including during delayed generic inference.
An expected const or maybe-const Array builds directly with the const tag
and no freeze; an unqualified or mutable context builds a mutable Array.
The wider view belongs to the consuming edge; the coder uses the concrete
expression type to choose the allocator and writer.

## Runtime Array pair

Mutable and const Arrays share the representation in
[Dense Arrays](dense-arrays.md#representation-contract): the same backing
`Table *`, logical `lenhint`, key-0 reverse link, and zero-payload proxy with
two traced user values. Only the proxy metatable and the second user value
differ:

```text
mutable proxy: TITAN_ARRAY_METATABLE
  uv[0] backing Table
  uv[1] construction-selected writer CClosure
  metatable[TITAN_BRAND] = TITAN_ARRAY (1)

const proxy: TITAN_CONST_ARRAY_METATABLE
  uv[0] backing Table
  uv[1] nil
  metatable[TITAN_BRAND] = TITAN_CONST_ARRAY (2)
```

`titan_array_metatables` (`titan-runtime/titan.c`) creates or recovers both
canonical metatables as one pair. The registry entry
`"Titan array metatable pair"` is the publication point; the named
`TITAN_ARRAY_METATABLE` and `TITAN_CONST_ARRAY_METATABLE` registry entries are
projections repaired from it. Each callback closes over both metatables before
publication, so no callback can observe one identity while the other is only
partly initialized. The mutable metatable has `__index`, `__newindex`, and
`__len`; the const metatable has `__index` and `__len` only
(`titan_array_initialize_metatable`). Array boxing and validation accept
exactly the requested canonical tag (or either, for `const? { T }`, through
`titan_array_try_backing_either`) and never a structurally similar userdata.

`titan_array_new` and `titan_const_array_new` are the two inline entry points
over one constructor; a const call passes no writer. `titan_array_shallow_copy`
implements copy mode and `titan_array_freeze` implements freeze mode by
writing the const metatable directly and clearing `uv[1]`. Their stack, root,
and barrier contracts are in
[Runtime construction](dense-arrays.md#runtime-construction) and
[Mutable-to-const lowering](dense-arrays.md#mutable-to-const-lowering).

Every generated module reserves two consecutive private cache slots,
`array_metatable_upvalue` and `const_array_metatable_upvalue`
(`coder/module.lua`). Names, boxing/unboxing, strict guards, dynamic
conversions, numerics, generic entries, Interface adapters, module
initialization, and standalone startup select the slot by
`Type.Array.isconst`. Exact native signatures remain `Table *` for every
qualifier; the semantic type, never the C carrier alone, chooses the tag.

## Generated storage and Lua writes

Checker-synthesized nil values keep local/module declaration lowering uniform.
The coder asserts that a rejected const assignment cannot reach a native store
(`coder/statements.lua`). Generated Lua write dispatch keeps an explicit arm
for each const member that raises instead of omitting the setter, which would
risk an unknown-member or silent behavior mismatch:

- record `__newindex`: "cannot assign const field '%s' in record '%s'"
  (`coder/module.lua`; see
  [`__newindex`](lua-interop-internals.md#__newindex-checked-mutable-writes-and-const-rejection));
- module `__newindex`: "cannot assign const variable '%s' in Titan module
  '%s'" (`coder/declarations.lua`).

Imported metadata drives the same generated behavior. Interface wrappers store
each field as a target-typed snapshot user value; native field reads unbox it,
Lua `__index` boxes it, and the wrapper's `__newindex` rejects every write
([Wrapper representation](interfaces.md#wrapper-representation)).

## GC and ABI review points

The const-specific edges use stock Lua reachability:

- a const Array proxy's `uv[1]` is nil and adds no writer edge;
- shallow copies barrier each copied collectable into the new backing;
- in-place freeze writes the proxy metatable directly with
  `luaC_objbarrier` and `luaC_checkfinalizer` before clearing the old writer
  edge;
- Interface wrappers strongly trace every snapshot in addition to concrete
  module/self; and
- nested field conversions root their sources and destinations across every
  allocation or Lua call.

Run forced full and generational collections around shallow Array copy/freeze
and adjusted Interface snapshot construction when changing these paths. The
required descriptor booleans, Interface member schema, wrapper user-value
count, two-slot Array-metatable cache, and second runtime tag are part of the
[compiled-module ABI](codegen-overview.md#compiled-module-abi).

## Focused evidence

Parser and type-shape coverage lives in `spec/lexer_spec.lua`,
`spec/parser_spec.lua`, `spec/types_spec.lua`, and
`spec/union_interface_spec.lua`. Checker policy is covered by
`spec/checker/const_values_spec.lua` plus the Interface and C-FFI checker
suites. Generated behavior, Lua boundaries, GC, and compiled-provider recovery
are covered by `spec/coder/const_values_spec.lua`, the existing dense-Array and
Interface coder suites, and the DSO/archive/static-metadata suites.
