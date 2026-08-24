# Const variables, fields, Interfaces, and Arrays implementation plan

Status: **preliminary, source-grounded plan written and independently reviewed
before implementation**. Review corrections cover owner-specific initializer
authority, the exact missing-nil domain, required serialized qualifier flags,
allocation-free `is`, recursive Interface-field lowering/pair discovery,
direct-C aggregate mutation, Array metatable publication/barriers, wrapper
index/count bounds, sharding, and mandatory GC/sanitizer gates. The maintainer
then fixed the two remaining surface choices: const locals always require an
initializer expression list, and const Arrays are spelled `const { T }`.
Work is isolated on `agent/const-values`, based on
`b5fb026ad9aded3d869961bb769fc5129bfdcd4e` (`master` when research began).
The maintainer has waived macOS CI for this PR. Do not dispatch it manually;
the three exact-head Linux jobs and Codecov's final merged project/patch report
remain completion gates.

Primary request: [GitHub issue #93, `"const" variables/fields/arrays`](https://github.com/mascarenhas/titan/issues/93).

## 1. Normative reading of the issue

The implementation will use these rules consistently in the parser, checker,
generated ABI, Lua boundary, manuals, and programming cartridges.

### 1.1 Bindings and omitted initializers

- A module variable accepts `[local] const name [: type] [= exp]`.
  An initialized const module binding is never assignable. An initializer-less
  const module binding requires an explicit type whose representation actually
  admits a missing nil (`nil`, `value`, `Option`, or the existing nullable
  legacy/C pointer domains); it is initialized to that nil/NULL representation
  before the root
  module initializer runs and may be assigned only by code executing directly
  in that variable's owning module initializer function frame. Another
  module's initializer and nested functions or lambdas do not inherit the
  permission. The owner initializer may assign it conditionally or more than
  once; constness begins when module initialization finishes.
- A block accepts both `const names = exps` and `local const names = exps`.
  Constness applies to the complete declaration list; there is no per-name
  qualifier. A const local is never assignable after its declaration.
- Ordinary `local names` declarations may omit the expression list; const-local
  declarations always require `= exps`. Every name in an omitted-initializer
  declaration must have an explicit
  type in that same missing-nil domain; truthiness or another ordinary
  coercion is not enough. The checker supplies one `nil` per slot. This follows
  the motivating mutable-optional-then-const-shadow example literally.
- `const x = x` resolves the right-hand side before declaring the new binding,
  so it reads the outer `x` and retains the existing automatic Option unwrap.
- A const direct-C local cannot regain mutation authority through a mutable
  address-taking/decay path, and its inline aggregate fields or automatic-array
  elements cannot be mutated. Const remains shallow for pointer/owned values:
  the binding cannot be replaced, but an independently mutable pointee is not
  frozen.

Const qualifies a binding or storage slot, not the transitive object graph.
For example, a const field holding a mutable Array prevents replacing the
field, but does not make that Array immutable. `const { T }` is the separate
shallow-immutable container type described below.

### 1.2 Record and Interface fields

- Record fields accept `[local] const name: type`. A const field may be filled
  by a positional/named initializer or the synthesized `.new` constructor, but
  no later Titan or Lua write is allowed. Preserve record optional-field
  shorthand as `[local] const name?: type`; Interface fields use an explicit
  option type (`name: type?`) rather than gaining that record-only shorthand.
- Interface fields use `name: type` and are implicitly const. Interfaces may be
  fields-only, methods-only, or mixed, but must contain at least one member.
  Field and method names share one namespace; duplicate or cross-kind
  collisions are rejected in source order. Field slots and method slots each
  retain their own declaration order.
- A record implements an Interface field only when it has a visible, same-name
  const field whose type can be automatically assignment-adjusted to the
  Interface field type. A union may still implement a method-only Interface,
  but never one that requires fields. Generic Interface fields are substituted
  with the same owner arguments as methods.
- Interface construction snapshots each required field into the wrapper after
  applying the frozen adjustment. Reads observe that snapshot, not later
  replacement of the concrete record slot. The snapshot is shallow: a mutable
  object stored in the const field retains its identity and remains mutable
  through its own API. Interface fields are read-only from Titan and Lua.

### 1.3 Const Arrays and casts

- `Type.Array` gains an invariant mutability qualifier. `{T}` and
  `const { T }` are distinct types and runtime tags. General assignment,
  consistency, dynamic plans, and guards never erase that qualifier.
- Gradual consistency remains within one mutability class:
  `const { T }` and `const { value }` have the usual checked view in either
  direction, just as mutable Arrays do today. Mutable and const Arrays are not
  gradual views of each other.
- A written cast from mutable `{S}` to const `const { T }` is the sole
  cross-mutability conversion. It is allowed only when `S` and `T` are equal or
  gradually consistent, because a shallow freeze cannot perform per-element
  numeric or nominal conversions. The target read plan enforces any gradual
  projection. Const-to-mutable conversion is rejected, including through a
  `value` round trip, because the runtime tags differ.
- Preserve Titan's shared written `as`/`is` relation. For an admitted statically
  mutable-to-const pair, `a is const { T }` evaluates `a` once and returns true
  without allocating, copying, or freezing; `as` performs the conversion.
  Tests from `value` continue to inspect the exact qualified runtime tag.
- Mutable and const Array types are directly incomparable because the
  qualifier is part of consistency; equality is available only after an
  explicit common `value` view, where ordinary boxed identity rules apply.
- A normal Array constructor in a `const { T }` target context constructs the
  const Array directly. A mutable-to-const cast otherwise makes a shallow copy:
  it preserves logical length and holes and copies element identities rather
  than recursively freezing them.
- Copy elision requires a linear-use proof, as clarified by the maintainer:
  the mutable allocation has not escaped before the cast, and neither its
  source binding nor any mutable alias is used after the cast. Unproven cases
  copy. The initial optimization domain includes a fresh local Array used as a
  builder across ordinary structured control flow and loops: length queries
  and indexed reads or writes do not escape it, and unrelated calls may
  compute elements. Parameters, imports, fields, module variables, call
  results, rebinding, aliasing, an actual reference from a nested closure,
  passing the Array to a call, aggregate
  storage, or any use of the mutable source or an alias after the cast disables
  elision.

## 2. Compatibility boundary and non-goals

This change advances the ABI boundary. Serialized Array, Field, ModuleVariable, and
Interface descriptors change; Interface wrapper uservalue counts change; the
module-private Array metatable cache grows; and the runtime exports a second
Array tag plus freeze/copy operations. Providers from before the boundary are
not migrated, and the compiler rejects them before decoding metadata.

The feature does not add deep immutability, const functions/methods/parameters,
flow-sensitive definite assignment, consuming types, union named fields,
implicit mutable-to-const Array coercion, or const-to-mutable copying. It does
not alter Map mutability. Copy elision is an optimization and must never weaken
the shallow-copy semantics.

## 3. Parser and AST

### 3.1 Declaration shapes

`const` is already a reserved token for C pointer syntax, so no keyword-table
change is required. Extend `titan-compiler/parser.lua` at the existing top-level
variable, local-statement, record-field, Interface-member, and Array-type
productions without disturbing `const *T` parsing.

- Extend `Ast.TopLevelVar` with binding constness and preserve whether source
  omitted the initializer.
- Extend `Ast.Decl` with `isconst`; all declarations in one const-local list
  receive the flag.
- Let a missing initializer be represented explicitly until checker
  validation. After validation, normalize it to typed `Ast.ExpNil` nodes so
  the existing finite adjustment and code generation paths remain single.
- Extend `Ast.TypeArray` with `isconst` and parse `const { type }`. This
  maintainer-selected spelling deliberately preserves `{ const *ffi.T }` as a
  mutable Array of const C pointers; `const { *ffi.T }` is a const Array of
  mutable pointers and `const { const *ffi.T }` combines both qualifiers. Do
  not admit a const Map form.
- Parse Interface bodies as one source-ordered member list, then derive ordered
  `fields` and `methods` views. Interface field declarations reuse declaration
  location/type machinery but are marked implicitly const.
- Preserve the synthesized record `.new` constructor: it writes an initializer
  list, not an ordinary assignment, and therefore already represents the
  allowed construction-time fill.
- Update `titan-compiler/syntax_errors.lua` expectations and recovery for the
  new optional `=` forms and mixed Interface members.

## 4. Type descriptors, relations, and metadata

### 4.1 Canonical descriptors

In `titan-compiler/types.lua`:

- change `Type.Array(elem)` to `Type.Array(elem, isconst)` and require an exact
  boolean qualifier at the new ABI boundary; migrate every internal constructor explicitly
  so missing hostile metadata cannot be normalized to mutable before closed
  validation;
- add required exact-boolean `isconst` axes to `Type.Field` and
  `Type.ModuleVariable`;
- change `Type.Interface` to carry dense ordered `fields` and `methods` lists,
  decorating each with its canonical by-name projection while rejecting
  hostile keyed input, sparse lists, foreign owners, invalid indices, and
  cross-kind name collisions;
- allow zero fields or zero methods, but not an empty combined member set; and
- preserve all new axes through equality, normalization, rewrite/substitution,
  erasure, generic reconstruction, traversal, dynamic eligibility, tostring,
  serialization, and deserialization validation.

Array equality and consistency compare `isconst`. Guard and dynamic-coercion
plans select the qualified Array tag. Add a dedicated written-cast plan for
mutable-to-const freeze/copy plus an optional same-mutability element gradual
view; ordinary coercion does not acquire the conversion.

Promote the existing duplicated callable missing-argument predicate into one
shared `types.accepts_missing_nil` helper and use that exact representation
domain for omitted declarations. Do not use general assignment adjustment,
which would admit truthiness conversions such as `nil -> boolean`.

### 4.2 Interface implementation plans

Extend `types.interface_implementation` and the checker policy transport so an
implementation contains independent ordered `fields` and `methods` mappings.
For each required field, resolve a visible record `Type.Field`, require
`isconst`, freeze its assignment-adjustment plan and exactness, and retain both
  source and target descriptors for code generation. Freeze the complete
  lowering annotation, including nested Interface conversions and callable
  adapters, rather than retaining only the type-relation adjustment.
  Diagnostics distinguish missing fields, wrong-kind members, mutable fields,
  inaccessible fields, and incompatible field types.

Do not smuggle field state through the existing method mapping. Update generic
Interface reconstruction, constraint satisfaction, imported metadata views,
and lowering copies to carry the complete implementation object.

### 4.3 Closed compiled-interface validation

Extend `titan-compiler/driver.lua`'s closed validators for Array qualifiers,
record/Interface Fields, Interface member lists, and const module variables.
Keep canonical source-order/index checks and reject missing, non-boolean, keyed,
sparse, duplicate, cross-owner, or cross-kind metadata. Hostile compiled input
must fail before registry publication.

## 5. Checker and lowering

### 5.1 Bindings and assignments

- In top-level declaration checking, validate initializer-less const module
  declarations, retain an `_initializerless_const` marker, synthesize nil, and
  publish constness through `Type.ModuleVariable`. Avoid confusing binding
  constness with the existing `isconst(exp)` static-initializer predicate.
- In local statement checking, resolve every written type before an omitted
  initializer, require nil acceptance, synthesize one nil expression per
  declaration, and otherwise keep the current expression-list adjustment and
  inference behavior.
- Mark the synthetic root module-initializer function frame. Assignment to an
  initializer-less const module variable is legal only when that frame is the
  current function frame and its module name equals the variable's owner;
  nested blocks inherit it, nested callables and importing modules do not.
- Centralize assignment rejection after lvalue resolution and before
  `_assigned` bookkeeping for const locals, initialized/no-longer-authorized
  module variables, const record/Interface fields, and const Array indices.
  Preserve left-to-right RHS checking and current diagnostics after recovery.
- Exclude const direct-C declarations from mutable-address eligibility,
  automatic-array decay, and writes reached through inline C-field or C-array
  lvalues. Preserve mutation through pointer/owned pointees as the shallow
  binding rule requires.

### 5.2 Interface field access

Replace the current unconditional “Interface has no fields” branch in
`checker/variables.lua` with lookup of the Interface's required field
descriptor. Reads carry its target type and wrapper-slot annotation; writes are
rejected as const. Constrained generic parameters expose the same fields through
their erased Interface carrier. Field-only Interface declarations obtain their
receiver dynamic plan from the Interface descriptor rather than `methods[1]`.

### 5.3 Linear-use Array analysis

Run a checker-owned, post-typecheck analysis over each function and the root
initializer, after declaration/capture identities and written-cast plans are
known. It never recomputes types in the coder.

1. A direct mutable Array constructor consumed by a const target/cast is
   annotated for direct const construction.
2. A local candidate must be initialized exactly once from a fresh mutable
   Array constructor and remain un-rebound. A conservative whole-use scan up
   to the cast invalidates it on RHS aliasing, aggregate/module/field/container
   storage, argument passing (including named, method, and constructor calls),
   return/yield, or a nested closure that actually references the binding.
   Merely creating a closure in the binding's lexical scope is harmless.
   Length queries and indexed reads/writes
   before the cast do not escape the backing, including when they occur in
   loops or conditional builder logic; calls that do not receive or capture
   the Array may compute elements normally.
3. A complete use check requires the consuming cast to be the final use of the
   binding on every admitted path. The implementation admits a terminal
   same-block cast after structured builder statements, but conservatively
   falls back to copying when the cast itself is hidden in a branch, loop,
   try/catch/defer region, or nested callable, or whenever any later statement
   refers to the mutable binding.
4. Annotate each mutable-to-const cast as `freeze` or `copy`. Code generation
   asserts and follows that annotation; uncertainty always means `copy`.

Tests will verify both the semantic isolation of the copy path and generated-C
evidence that eligible casts actually take the freeze path.

## 6. Runtime and code generator

### 6.1 Const Array identity

Keep exact/native storage as `Table *` for both Array kinds. Add
`TITAN_CONST_ARRAY_METATABLE` beside `TITAN_ARRAY_METATABLE` and construct a
canonical const proxy metatable with `__index` and `__len` but no `__newindex`.
Both proxies retain the existing two-uservalue layout: uv0 is the backing;
mutable uv1 is the construction-selected writer, while const uv1 is nil.

Reserve consecutive mutable and const metatable slots in every generated
module and select them by `Type.Array.isconst` in `coder/names.lua`. Audit every
Array tag user in expressions, values, numerics, module initialization, Lua
entry checks, strict/gradual plans, and Interface adapters. A nested Array
exposed by Lua `__index` must recognize either canonical Array proxy tag rather
than incorrectly assuming the outer Array's mutability. Build/publish the pair
atomically, or perform lazy canonical lookup, so a callback cannot observe one
registered tag while the other is only partially initialized. “Either tag”
validation accepts exactly those two canonical registry metatables, never a
merely structurally similar proxy.

Add runtime helpers that preserve the proxy/backing cycle and GC barriers:

- const construction installs the const proxy with no writer;
- construction receives a caller-owned traced result slot and uses Lua-internal
  allocation, field stores, and barriers without changing `L->top` or calling
  the public Lua stack API;
- shallow copy relies on a distinct caller-owned source root, allocates the
  const backing/proxy directly into the result slot with an array part
  pre-sized to the source's exact physical `asize`, copies every present TValue
  only through logical `lenhint`, preserves holes and length, and returns the
  new `Table *` without growth reallocations or stack effects;
- in-place freeze debug-asserts an unescaped mutable canonical proxy, changes
  that proxy to the const metatable through direct Lua-internal fields with the
  required object barrier/finalizer bookkeeping, clears its writer, and returns
  the same backing without a stack effect.

Contextual const constructors use the const constructor directly. Written
mutable-to-const casts use the checker-selected copy/freeze helper, then apply
the target's gradual read view. Boxing and unboxing always use the static
qualified tag, so `value as {T}` cannot recover `const { T }` and vice versa.

### 6.2 Const bindings and record slots

Checker-synthesized nil initializers keep local/module codegen uniform. Const
captured locals naturally stay by-value because they are never assigned after
declaration. Add defensive coder assertions at assignment sites.

Public module setters and record `__newindex` dispatch must report an explicit
const-write error without modifying storage; omission of a setter arm must not
silently succeed. Imported const module/record metadata receives the same Titan
and Lua behavior.

### 6.3 Interface wrapper field slots

Retain the opaque payload as method pointers only and extend traced uservalues:

```text
payload     method pointers in Interface method order
uv[0]       concrete owner module
uv[1]       concrete record object
uv[2 + i]   copied/coerced Interface field i
```

Allocate `2 + #interface.fields` uservalues. Root the outer wrapper before any
field adjustment that can allocate, restore stack/base offsets afterward, and
store every adjusted target value with the correct barrier. Share this body
between static wrapping and dynamic discovery witnesses so they cannot drift.

Native Interface field reads unbox `uv[2 + index]`. Lua `__index` distinguishes
methods from fields, returns a correctly boxed field snapshot, and leaves
`__newindex` rejecting every write. Wrapper validation checks both method
payload size and exact uservalue count. For a field-only Interface, emit no
zero-length C array or memcpy; the payload size is zero and only field
uservalues are initialized.

Each field mapping carries separate zero-based concrete source and Interface
target indices; do not overload the method mapping's `index`. Reject an
Interface whose `2 + #fields` uservalue count exceeds the runtime's supported
integer bound before calling `luaS_newudata`.

Field coercions may themselves inventory concrete-to-Interface pairs. Before
sorting or emitting pair tables/witnesses, run an explicit deterministic
worklist to a fixpoint over all nested field/callable conversions. Emission
must never append a late pair to an already sorted or partially emitted
inventory.

## 7. ABI cutover

Update the authoritative ABI marker in `titan-runtime/titan.h`,
`titan-compiler/driver.lua`, the Make/install/rockspec scripts, CI caches,
generated metadata, production smokes, and active documentation. Treat this as
a clean rebuild boundary; do not add migration or cross-boundary cleanup.

The cutover tests must prove:

- pre-boundary compiled metadata is rejected by the compiler/loader;
- source, DSO, and archive providers round-trip const module variables, record
  fields, Interface fields, and qualified Arrays;
- module public-prefix and private-slot reconstruction agree on the new layout;
- installer rollback/publication and generated shim paths target only the active layout;
  and
- the standard-library image remains otherwise behaviorally unchanged.

## 8. Compiler test plan and sharding

Add topical covered compiler files `spec/checker/const_values_spec.lua` and
`spec/coder/const_values_spec.lua`. Time them, add them to
`spec/support/ci_compiler_test_groups.txt`, and rerun the repository's measured
longest-first partitioning rather than guessing a permanent shard. Assert the
new checker and coder topical files land in different existing groups. Keep every
new test in the Lua-written compiler suite; do not create stdlib/native behavior
tests for this feature.

### 8.1 Syntax, types, and checker

- `spec/lexer_spec.lua`: exact `const` token and identifier prefixes.
- `spec/parser_spec.lua`: every module/local initializer form, multi-name
  constness, absent RHS, record field qualifiers, mixed/field-only Interfaces,
  `const { T }`, nesting, malformed const Map placement, and unchanged C
  `const *` syntax.
- `spec/types_spec.lua`: Array qualifier equality/consistency/cast truth tables,
  tostring, guards, Interface field mappings, generic substitution, and
  serialization round trips.
- `spec/checker/const_values_spec.lua`: inference, annotations, nil rules,
  shadow/unwrap, multiassignment and closure write rejection, module-initializer
  scope including nested-lambda rejection, C-address rejection, construction,
  const Array reads/writes, and linear-use annotations.
- `spec/checker/interfaces_spec.lua`: exact/coerced/generic fields; fields-only
  and mixed declarations; missing, mutable, inaccessible, incompatible, and
  wrong-kind members; collisions; and union rejection for field-bearing
  Interfaces.
- `spec/union_interface_spec.lua`: canonical and hostile schemas for all new
  descriptor fields and member order.

### 8.2 Generated C and runtime behavior

- `spec/coder/const_values_spec.lua`: nil initialization for scalar/GC locals
  and module slots; const exports and Lua write rejection; const record fields;
  Interface field snapshot/coercion, Lua reads, dynamic witnesses, GC, and
  field-only wrappers; qualified Array tag identity, holes/length, nested mixed
  mutability, typed/gradual reads, Lua immutability, cross-tag `value` failures,
  shallow-copy alias isolation, element identity, and freeze/copy codegen.
- Extend `spec/coder/interfaces_spec.lua` for method/field wrapper ordering,
  two-state initialization, adjusted field plans, and generated payload/
  uservalue assertions.
- Extend `spec/checker/so_rehydration_spec.lua`,
  `spec/coder/so_import_spec.lua`, and static compiled-module coverage for DSO
  and archive metadata/behavior. Extend source/folder visibility cases for local
  const members and the final module initializer.
- Extend `spec/staticmetadata_spec.lua`, `spec/abi_spec.lua`, installer,
  rockspec, and smoke expectations for the current ABI.

Use exact diagnostics for each const storage category and initializer failure.
Run the manifest completeness check so no new compiler spec can silently miss
all four Linux shards.

## 9. Manuals and skill cartridges

Add and link both required feature chapters:

- `doc/language/const-values.md`: syntax and nil rules, assignment regions,
  shallow binding/field semantics, Interface satisfaction/snapshots, const Array
  identity/Lua behavior, and shallow-copy cast semantics while explicitly
  permitting unobservable semantics-preserving copy elision;
- `doc/implementation/const-values.md`: AST/type schema, checker flags and
  analysis, wrapper layout/GC, Array runtime tags/copy/freeze, serialization,
  diagnostics, and the ABI boundary.

Audit and cross-update the existing language chapters for modules, statements,
grammar, types, records, Interfaces, Arrays/Maps, generics, expressions, and Lua
interop, plus the corresponding implementation chapters for AST/parser,
checker, type relations, Interfaces, dense Arrays, codegen, values/GC, Lua
interop, imports/static metadata, and ABI. Update README active-ABI and feature
summaries without rewriting historical entries.

Although these cartridges are not compiler implementation guides, their Titan
contracts must remain current:

- revise `.agents/skills/titan-programmer/SKILL.md` for optional nil
  initialization, binding/field constness, Interface fields, qualified Arrays,
  casts, and Lua behavior;
- revise `.agents/skills/titan-ffi/SKILL.md` where it currently claims every
  local has an initializer and where Array proxy mutability crosses Lua; keep
  Titan `const { T }` distinct from C `const`;
- add a fresh const-semantics scenario to
  `.agents/skills/titan-programmer/EVALUATION.md` and run the prescribed fresh
  evaluation/validation; and
- leave `titan-tester` and narrower async/networking/PEG cartridges unchanged
  unless implementation uncovers a stale concrete claim.

Read each affected cartridge completely before editing it and validate every
modified skill directory with the repository/system skill validator.

## 10. Implementation phases

1. Freeze the parser/AST/type descriptor contract, add focused syntax/type
   tests, and perform the metadata ABI cutover.
2. Implement binding/field constness and omitted nil initialization in the
   checker, including root-initializer authority and mutable-C-address denial.
3. Implement the qualified Array runtime, coder tag selection, shallow copy,
   contextual construction, and conservative linear-use freeze analysis.
4. Implement Interface field checking, frozen mappings, wrapper slots, native/
   Lua reads, dynamic witnesses, generics, and compiled-provider recovery.
5. Close focused checker/coder/import/ABI coverage, rebalance the shard
   manifest, and update both manuals and the relevant cartridges.
6. Run independent semantic, frontend/types, generated-C/GC/ABI, and tests/
   docs/skills reviews; resolve every actionable finding before broad tests.

## 11. Verification, review, and delivery

1. Run parser, type, checker const/Interface, coder const/Interface, hostile
   metadata, and compiled-provider specs with persistent probes disabled.
2. Inspect representative generated C for every new storage shape. Run the
   GC-bearing Array-copy and Interface-field cases with forced collections and
   under the sanitizer prefix; these allocation/rooting gates are mandatory,
   not failure-contingent.
3. Run the complete covered compiler partition locally so manifest validation,
   all four workers, and the LuaCov merge execute as CI will.
4. Run the canonical full mixed suite from a clean isolated absolute `/tmp`
   prefix with ambient `ROCKS_TREE`, `TITAN_ROCKS_ROOT`,
   `TITAN_EXTRA_CPPFLAGS`, and `TITAN_NO_LINE_DIRECTIVES` unset.
5. Run skill evaluation/validation and documentation link/reference checks.
6. Have independent reviewers audit the final semantics, diagnostics,
   serialization/ABI boundary, generated-C rooting/barriers, linear-use
   soundness, tests/shards, manuals, and skills; rerun every affected gate.
7. Commit intentionally, push `agent/const-values`, and open a PR closing #93
   with local evidence and an explicit macOS waiver.
8. Monitor the exact PR head until all three push-triggered Linux jobs and the
   final merged Codecov project/patch gates are green. Fix in-scope failures,
   push reviewed amendments, and continue monitoring. Never dispatch macOS.

The goal is complete only when the reviewed PR is open at its final head,
Linux CI is green, and Codecov's merged report passes.
