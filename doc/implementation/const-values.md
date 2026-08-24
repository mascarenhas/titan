# Const-value implementation

ABI 2 adds const bindings, const record and Interface fields, and
const-qualified Arrays across the parser, semantic descriptors, checker,
generated C, Lua boundary, and compiled-module metadata. The language contract
is [Const values](../language/const-values.md). This chapter records the
cross-pass invariants that must stay aligned when the implementation changes.

## Frontend and AST contract

`const` was already a token because the C FFI uses `const *T`; the feature adds
grammar placements without changing keyword recognition.

The relevant AST constructors are:

```lua
Ast.TypeArray(loc, subtype, isconst)
Ast.Decl(loc, name, type, option, isconst)
Ast.TopLevelVar(loc, islocal, isconst, decl, value)
Ast.TopLevelInterface(loc, name, members, fields, methods, typeparams)
```

Every `isconst` is an exact boolean. `TopLevelVar.value == false` preserves an
omitted module initializer until the checker validates and normalizes it.
`TopLevelInterface.members` retains source order, while `fields` and `methods`
are independent ordered projections. Interface fields reuse `Ast.Decl` and are
created with `isconst == true`.

The parser admits:

- `[local] const decl [= exp]` at module scope;
- `(local? const) decllist = explist` in a statement block;
- `local decllist [= explist]` for mutable locals;
- `[local] const name [?] : type` in records;
- `name: type` and bodyless method signatures in Interface bodies; and
- `const { type }` as the const Array type.

The `const { T }` production precedes `const *T`/ordinary Array parsing and
rejects a colon before the closing brace, so no const Map form is created.
`{ const *c.T }` still parses as a mutable Array whose element is a const C
pointer. Const-local grammar always commits to `= explist`; only mutable
`local` uses the optional expression-list production.

Parser record desugaring still synthesizes `Record.new`. Its parameters retain
field order and const flags, while the generated constructor body writes an
initializer list rather than an ordinary assignment. This is the only reason
construction can populate const fields without weakening later assignment
checks.

## Semantic descriptors and serialization

The ABI-2 constructors require their new axes rather than defaulting absent
metadata to mutable:

```lua
Type.Array(elem, isconst)
Type.Field(fqtn, name, type, index, isconst)
Type.ModuleVariable(modname, name, type, isconst)
Type.Interface(name, fields, methods, scope, typeparams)
```

Array qualifier equality is part of type equality, consistency, guard and
dynamic-plan identity, rewriting, substitution, erasure, stringification, and
serialization. `types.tostring` renders mutable `{ T }` and const
`const { T }`.

Interface `fields` and `methods` are separately dense, source-ordered
list/name-map projections. Their names share one namespace. A field is a
canonical `Type.Field` owned by the Interface, has its zero-based target slot,
and must carry `isconst == true`. Record fields and module variables retain
their own required boolean. The closed decoder rejects a missing/non-boolean
qualifier, sparse or keyed input, duplicate or cross-kind member names,
incorrect owners or indices, and descriptors placed outside their allowed
owner graph.

The driver checks the provider ABI before evaluating serialized types, so
mismatched metadata is rejected before a descriptor can be interpreted as ABI
2 state. DSO and embedded archive metadata use the same validation path.

## Checker rules for declarations

`types.accepts_missing_nil` is the shared narrow predicate for omitted local
initializers, initializer-less const module variables, callable missing-result
fill, and other existing missing-slot rules. It admits the actual nil-bearing
representation domain, not general assignment adjustment; in particular,
truthiness cannot make a Boolean declaration initializer-less.

For a mutable `StatDecl` with no expression list, the checker:

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

An initializer-less const `TopLevelVar` receives `_initializerless_const` and
its owning module name. The checker requires an explicit nil-bearing type and
replaces `value == false` with a checked `ExpNil`. `checkfuncbody` marks the
synthetic root initializer frame with its owner module. Assignment to that
module slot is authorized only when this marked frame is the current function
frame and the owners match; nested blocks remain in the frame, while a nested
lambda/function or an importing module does not inherit permission. The rule
does not count assignments or implement definite assignment.

The central lvalue check rejects writes to const locals, const module members,
const record/Interface fields, and const Array indices. C lvalue analysis also
rejects mutation reached through a const local's inline struct/union/array
storage and excludes that declaration from mutable address-taking and decay.
Encountering a pointer or owned value ends the inline-storage walk, preserving
shallow pointee mutability.

## Interface fields and frozen mappings

Interface declaration checking builds all field and method descriptors before
publication. A concrete implementation plan contains independent ordered
`fields` and `methods` mappings. For each required field it records:

- the visible same-name concrete `Type.Field` and its source index;
- the required Interface field and its target snapshot index;
- proof that the concrete field is const;
- the exact source and target types; and
- the frozen assignment/lowering plan, including nested callable or Interface
  conversions that can allocate.

Unions fail any field-bearing Interface before method matching. Diagnostics
distinguish a missing field, wrong-kind collision, inaccessible field, mutable
field, and incompatible type. Applied generic Interfaces substitute owner
arguments through fields exactly as through methods. A constrained type
parameter exposes the applied Interface's field reads as well as its methods.

Field access on an Interface resolves to the target descriptor and wrapper
snapshot slot. It is a read-only lvalue category. Because a field adjustment
can inventory another concrete/Interface conversion, pair discovery runs a
deterministic worklist to a fixpoint before pair sorting or C emission; code
generation must never append to an inventory already being emitted.

## Array relations and linear-use analysis

`types.consistent` descends through Array elements only when both qualifiers
are equal. Strict and dynamic plans carry `isconst` and choose the exact
qualified tag. General assignment never changes the qualifier.

`types.written_cast` has one cross-qualifier operation,
`array_freeze`, for mutable `Array(S, false)` to const `Array(T, true)` when
the element types are equal or gradually consistent. Its default mode is
`copy`; const-to-mutable and other cross-qualifier relations are absent. The
matching static `is` is marked allocation-free and returns the admission result
without lowering the conversion. A `value is/as Array` plan instead tests the
exact target qualifier at run time.

After typechecking, `checker/linear.lua` may change an `array_freeze` plan from
`copy` to `freeze`. A candidate is one un-rebound local initialized exactly
once from a fresh mutable Array constructor. Its same-block terminal cast must
be the final use on every admitted path. Before that cast, structured builder
statements and loops may query `#array` and perform indexed reads or writes;
calls that neither receive nor capture the Array may compute element values,
and creating a closure is harmless when its body does not reference the Array
or an alias. Passing, returning, storing, aliasing, actually capturing, or
rebinding the Array, hiding the consuming cast inside control flow, or using
the mutable binding later retains `copy`. The coder trusts only the checker
annotation and never recomputes escape or liveness facts.

A constructor checked under a const Array target is annotated as const at
construction and needs neither conversion helper.

## Runtime Array pair

Mutable and const Arrays retain the same internal `Table *` backing, logical
`lenhint`, positive-index storage, key-0 reverse link, and zero-payload proxy
with two traced user values. Their proxy metatables differ:

```text
mutable proxy: TITAN_ARRAY_METATABLE
  uv[0] backing Table
  uv[1] construction-selected writer CClosure

const proxy: TITAN_CONST_ARRAY_METATABLE
  uv[0] backing Table
  uv[1] nil
```

`titan_array_metatables` creates or recovers both canonical metatables as one
pair. The pair table is the publication point, so callbacks cannot observe one
registered identity while the other is only partly initialized. The mutable
metatable has `__index`, `__newindex`, and `__len`; the const metatable has
`__index` and `__len` only. Each callback captures both identities so nested
Array boxing/validation accepts exactly either canonical tag and never a
structurally similar userdata.

`titan_array_new` requires the writer and mutable metatable.
`titan_const_array_new` requires the const metatable and writes nil to the
second user value. Both receive an already-live generated result slot, publish
the backing there before resizing it, temporarily publish the proxy there while
installing the key-0 reverse link, and leave the backing in the same slot. They
use `luaH_new`, an exact `luaH_resize`, `luaS_newudata`, direct metatable and
uservalue stores, and the corresponding GC barriers; they never change
`L->top` or call the public Lua stack API.

`titan_array_shallow_copy` requires the mutable source to remain rooted in a
caller-owned slot distinct from its result slot. It constructs a const
destination whose array part preallocates the source's physical `asize`
exactly, copies each present array slot only through the logical length, applies
a backing barrier for each collectable value, and restores the exact length so
spare capacity, holes, and trailing semantics are preserved. It is likewise
stack-neutral.

`titan_array_freeze` is used only after the checker linear proof. It validates
the canonical mutable proxy with debug assertions, writes the const metatable
directly with Lua's internal object barrier and finalizer bookkeeping, clears
the writer user value to nil, and returns the same backing without touching the
Lua stack. The backing/proxy identity is preserved only on this semantically
unobservable optimization path.

Every generated module reserves consecutive private cache slots for the
mutable and const Array metatables. Names, boxing/unboxing, strict guards,
dynamic conversions, numerics, generic entries, Interface adapters, module
initialization, and standalone startup select the cache by
`Type.Array.isconst`. Exact native signatures remain `Table *` for both
qualifiers; semantic type, never C carrier alone, chooses the tag.

## Generated storage and Lua writes

Checker-synthesized nil values keep local/module declaration lowering uniform.
The coder asserts that a rejected const assignment cannot reach a native store.
Public module and record `__newindex` dispatch retains explicit const-member
arms that raise a const-write error; merely omitting a setter would risk an
unknown-member or silent behavior mismatch. Imported metadata drives the same
generated behavior.

Interface wrappers keep method pointers only in their opaque payload. Their
traced layout is:

```text
payload[0 .. method_count-1]  exact or adjusted method entries
uv[0]                         concrete owner module Udata
uv[1]                         concrete record Udata
uv[2 + field_index]           adjusted Interface field snapshot
```

Allocation requests `2 + field_count` user values after checking the runtime
integer bound. Field-only Interfaces use a zero-byte method payload and never
emit a zero-length C array or `memcpy`. The new wrapper is rooted before a
field adjustment that may allocate; stack offsets are restored after every
rebase point, and each collectable snapshot store applies the Udata barrier.
The same construction body serves static wrappers and dynamic witness calls.

Native Interface field reads unbox the snapshot user value. Lua `__index`
distinguishes field names from methods and boxes the stored snapshot; the
wrapper's `__newindex` rejects every write. Validation checks both the exact
method payload length and exact user-value count.

## GC and ABI review points

The new edges use stock Lua reachability:

- const Array proxy `uv[1]` is nil and adds no writer edge;
- shallow copies barrier each copied collectable into the new backing;
- in-place freeze uses the metatable API before clearing the old writer edge;
- Interface wrappers strongly trace every snapshot in addition to concrete
  module/self; and
- nested field conversions root their sources and destinations across every
  allocation or Lua call.

Forced full and generational collections are required around shallow Array
copy/freeze and adjusted Interface snapshot construction. The ABI-2 gate
covers required descriptor booleans, Interface member/schema changes, wrapper
user-value counts, the two-slot Array-metatable cache, and the second runtime
tag. Mismatched providers are rejected before metadata decoding or native
value exchange; earlier installations are not migration sources.

## Focused evidence

Parser and type-shape coverage lives in `spec/lexer_spec.lua`,
`spec/parser_spec.lua`, `spec/types_spec.lua`, and
`spec/union_interface_spec.lua`. Checker policy is covered by
`spec/checker/const_values_spec.lua` plus the Interface and C-FFI checker
suites. Generated behavior, Lua boundaries, GC, and compiled-provider recovery
are covered by `spec/coder/const_values_spec.lua`, the existing dense-Array and
Interface coder suites, and the DSO/archive/static-metadata suites.
