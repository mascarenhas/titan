# Generics

Titan implements generics as a **generic-aware surface checker over an erased,
ordinary core**. Each generic owner or callable has one declared scheme and one
native implementation. Type applications are closed by the checker, but no
generic type argument, dictionary, per-application witness, specialization key,
or provenance bit reaches run time.

The central pipeline is:

```text
generic source AST
    │ reserve scopes/binders; check schemes and bodies; infer each use
    ▼
closed generic-aware surface AST and declared module graph
    │ detach and freeze ast._declared_type
    ▼
erase every code-facing declaration and expression occurrence
    │ focused ordinary cast/adapter insertion at frozen generic boundaries
    ▼
monomorphic ast._type + ordinary plans + erased owner registry
    │ assert that no generic form remains
    ▼
existing generic-unaware coder
    ├── serialize ast._declared_type for the provider interface
    └── generate ordinary erased layouts, entries, closures, and C
```

The language contract is in [Generics](../language/generics.md). This chapter
specifies the frontend representation, surface type algebra and solver,
declaration staging, constraint erasure, cast elaboration, code-generation and
GC layouts, FFI admission, compiled metadata, and the generic shape of the
async owners. The [checker plan architecture](type-relations-and-boundaries.md)
is a prerequisite: generics reuse those concrete plans rather than teaching
the coder a new relation.

The declared type schema (schemes and applications) is part of the provider
interface metadata; there is no run-time generic calling convention.

## Design and safety invariants

The implementation is governed by these invariants:

1. A declaration owns one canonical immutable scheme. Every use receives fresh
   checker-only inference cells; a use never mutates the declaration, an
   imported module interface, `types.registry`, or another use.
2. Declaration parameters are rigid during body checking. Inference cells are
   mutable only inside one local use. The two representations are never
   conflated.
3. Every use closes to a monomorphic **surface** application before erasure. No
   unresolved cell enters declaration metadata or a code-facing annotation.
4. Generic inference only selects type arguments. It does not introduce
   subtyping, common-supertype search, lifted numeric conversion, or a second
   coercion relation.
5. Applied generic nominals are invariant static types. All applications of one
   owner share its metatable, userdata layout, symbols, module slots, and native
   body.
6. A rigid leaf erases recursively to its constraint carrier: `value`/`TValue`
   when unconstrained, or its erased Interface/`Udata *` when constrained.
7. Closed-to-carrier passage boxes a statically accepted value without an
   erasure-induced gradual check. Carrier-to-more-precise-closed passage uses
   the constraint-appropriate existing strict elimination: `gradual_guard` for
   an unconstrained `value` carrier, or checked Interface downcast/backing-owner
   recovery for a constrained carrier. There is no trusted reverse path based
   on call provenance.
8. The declared graph is frozen separately before the AST and active registry
   are erased. Coder sees only ordinary monomorphic types and existing concrete
   annotations.
9. Source order, declaration frontiers, duplicate precedence, visibility, and
   parse-time constructor adjacency are the same as for non-generic code.
10. Generic storage is Transient/Shallow. The implementation promises open-
    world representation safety, not a reified application identity or a deep
    homogeneous heap invariant.

These choices deliberately exclude monomorphization, hidden `_fn` dictionaries,
per-application metatables, run-time taint, cross-module check certificates,
provenance analysis, and wrapper interning.

## Frontend and AST

### Parser-owned nodes and fields

`ast.lua` uses the following positional constructors for generic syntax:

```lua
Ast.TypeParam(loc, name, optional_constraint)
Ast.TypeName(loc, name, typeargs)
Ast.TypeQualName(loc, module, name, typeargs)
Ast.ExpCall(loc, exp, args, typeargs)

Ast.TopLevelRecord(loc, name, fields, typeparams)
Ast.TopLevelUnion(loc, name, variants, typeparams)
Ast.TopLevelInterface(loc, name, members, fields, methods, typeparams)
Ast.TopLevelFunc(loc, islocal, name, params, rettypes, flexrettype,
                 block, typeparams)
Ast.TopLevelMethod(loc, class, name, params, rettypes, flexrettype,
                   block, typeparams)
Ast.TopLevelStatic(loc, class, name, params, rettypes, flexrettype,
                   block, typeparams)
Ast.InterfaceMethod(loc, name, params, rettypes, flexrettype, typeparams)
```

Interface fields reuse `Ast.Decl` with `isconst == true`; the `members` list
keeps their source order relative to `Ast.InterfaceMethod` children.

Every absent `typeparams` or public `ExpCall.typeargs` list is `{}`. An absent
`TypeParam.constraint` is nil. `TypeParam` is syntax, not a value `Decl`.
An `ExpCall` has one `typeargs` list regardless of whether its argument node
is `ArgsFunc`, `ArgsNamedFunc`, `ArgsMethod`, or `ArgsNamedMethod`; generics
add no `Args` tag. Written type arguments after a name, dot member, or method
reference are first recorded as the parser decoration `_nominal_typeargs`
(`parser.lua` `defs.name_with_types`, `defs.dot_with_types`,
`defs.method_with_types`); `defs.call_suffix` moves the callee's list into
`ExpCall.typeargs`. Owner arguments in `Pair<|T|>.member(...)` therefore stay
on the namespace `ExpVar`. The checker consumes that decoration before member
selection, retaining the canonical owner and closed owner application
separately, and rejects it on an `ExpVar` that is not a direct callee; erased
lowering removes it. When owner and callable-local scopes are both open, the
checker accepts both complete written lists or infers both; one written scope
never requests partial inference of the other.

Owner nodes contain owner binders. A method, nominal function, or Interface
method contains only its callable-local binders; a top-level function contains
its complete binder list. Foreign functions and `ExpFunction` reject binder
syntax. `TopLevelFunc.islocal` is positional, while owners, methods, statics,
fields, and variants carry locality as decorations.

Adding `typeargs` to `TypeName` and `TypeQualName` makes even an unapplied name
explicit in the AST. This is important for parser and lowering assertions: an
omitted list is `{}`, not missing information about whether the spelling was
named.

### Explicit type-list delimiters

Generic binders and arguments use the distinct longest-match tokens `<|` and
`|>`. The parser commits when it consumes `<|`; malformed lists cannot fall
back to comparison syntax. Nested `Outer<|Inner<|T|>|>` applications therefore
need neither a contextual `>` splitter nor a whole-source candidate scan.
Ordinary `<`, `>`, and `>>` remain comparison and shift tokens.

Fold captures accumulate nonempty binder/argument lists. Constraints use named
type syntax, and the checker proves their Interface meaning and scope. Binder
and argument lists share the parser's `LIST_LIMIT` (100) with parameter lists
(`defs.checklist`); later calling-convention limits are separate.

Base names and dot/colon member suffixes can carry written type arguments.
The parser records these candidates once; a following call transfers its
callable-local list into `ExpCall.typeargs`. The checker validates whether the
base is a generic callable or an applicable nominal namespace, preserves the
separate owner/callable scopes, and rejects explicit first-class owner-member
applications. Bare record calls are handled in the checker's `Ast.ExpCall`
visitor (`checker/expressions.lua`), which moves their call type arguments
onto the record namespace.

Missing binders, constraints, arguments, or `|>` receive committed syntax
labels. Eligibility, owner arity, partial application, and direct-call-only
rules remain semantic checks. There is no arbitrary lookahead for a possible
generic call.

### Parse-time constructor elaboration

`parser.lua` `defs.recorddecl` and `defs.uniondecl` place the synthesized
record `new` and union-variant `TopLevelStatic` nodes immediately after their
owner. For `Pair<|T, U|>` the synthetic constructor:

- has `typeparams = {}` rather than copying the owner binders;
- gives its field or payload parameters syntax that refers directly to `T` and
  `U`;
- returns `TypeName("Pair", {TypeName("T", {}), TypeName("U", {})})`
  (`applied_owner_type`); and
- carries `_record_constructor`, or `_union_constructor` and `_union_variant`.

The checker attaches owner quantification only after completing the canonical
record or union descriptor. It derives the constructor scheme from the
canonical fields/variants and validates the adjacent parser node against it.
This prevents double quantification without moving desugaring, changing AST
order, or giving constructors a second independent signature.

An explicit record static `new` suppresses the synthetic declaration instead
and gets the ordinary owner/member generic scopes. Bare record calls lower to
that same member selection. The record descriptor's `custom_constructor` flag
survives both declared and erased graphs; see
[record constructors](record-constructors.md).

## Surface type metadata algebra

Generic-aware checking uses declaration descriptors that never reach ordinary
coder dispatch:

```text
Type.GenericScope(modname, owner_fqtn, callable_name, role, declaration_kind)
Type.TypeParameter(name, constraint)
Type.Parameter(scope, index, diagnostic_name, erased_constraint)
Type.Nominal(fqtn, args)
Type.FunctionScheme(scope, typeparams, signature)
Type.GenericAlias(module, name, locality, target_owner_fqtn,
                  target_alias_fqtn, target_scope, typeparams)

Type.Record(name, fields, functions, methods, nfields, scope, typeparams,
            custom_constructor)
Type.Union(name, variants, functions, methods, nvariants, scope, typeparams)
Type.Interface(name, fields, methods, scope, typeparams)
Type.Method(fqtn, name, params, rettypes, varargtype, flexrettype,
            paramnames, scope, typeparams)
Type.StaticMethod(fqtn, name, params, rettypes, varargtype, flexrettype,
                  paramnames, scope, typeparams)
```

`Type.TypeParameter` describes a binder in a scheme. `Type.Parameter` is a rigid
use of that binder inside a type. Its semantic identity is `(scope,index)`; the
source name exists for diagnostics and is ignored by alpha-equivalence.
`GenericScope` is structural—logical module, owner, callable, role, and
declaration kind—not a filename or Lua table identity. Serialization therefore
has deterministic identities across source checking and interface recovery.

`Parameter.erased_constraint` is nil for the implicit unconstrained `value`
carrier, or the recursively erased ordinary Interface application for a
constrained binder. Owner descriptors own owner binders. Method and static
descriptors own only callable-local binders, although their signatures can
refer to owner leaves. Constructors quantify owner binders; nominal functions
quantify owner binders followed by local binders; receiver methods have their
owner arguments fixed and instantiate only local binders. A top-level
`FunctionScheme` wraps one ordinary function signature. Ordinary first-class
function types are never schemes.

Optional names and scopes are nil. When a consumer needs to recover a binder's
surface constraint, `types.parameter_surface_constraint` returns the optional
constraint plus a validity boolean. A valid unconstrained binder is
`nil, true`; missing or malformed binder evidence is `nil, false`.

### Applications, aliases, and identity

Surface `Type.Nominal(fqtn,args)` retains the complete invariant application.
Equality compares owner and arguments. Gradual consistency is intentionally
shallow and pointwise only where a rigid argument relates to its recursively
erased constraint carrier. Thus an unconstrained `Cell<|integer|>` is consistent
with the owner-erased `Cell<|value|>` view, while `ICell<|R|>` for `R:I` is
consistent with `ICell<|erase(I)|>`, not an invalid `ICell<|value|>`.

All those views share one nominal owner at run time. Equality and `as`/`is`
plans may use that owner identity without claiming argument identity. A
`value -> G<|t|>` test checks the outer `G` metatable only. Static assignment
remains invariant.

`Type.GenericAlias` is a type-namespace descriptor rather than a run-time module
member. It records:

- the alias's module, name, and locality;
- the canonical target owner and scope;
- an optional fully qualified target-alias name for cycle-safe provenance; and
- a dense alpha-remapped copy of the owner's binder/constraint descriptors.

Applying it substitutes into the canonical owner and returns the ordinary
surface `Nominal(target,args)`. A bare scalar use substitutes `value` for every
argument and then validates constraints. A concrete `TypeAlias` whose RHS is
already `Pair<|integer, integer|>` has no arity. Public `GenericAlias` descriptors
serialize in `Type.Module.type_members`; local ones do not. A source-private
target is valid only through an explicit `.titan` edge and its direct-owner
capability, and is never serialized.

Every new type tag participates in `tostring`, equality and alpha-equivalence,
graph traversal, substitution, normalization, serialization, and the closed
metadata validator. Generic descriptors cannot rely on object identity or an
unserialized back-pointer.

## Declaration staging and rigid checking

The checker preserves the combined AST's source order. Its generic surface
stages (`checker/declarations.lua` `checktoplevel`) are:

1. reserve imports, owner headers, `GenericScope`s, binder names, and arities
   (`generic_reserve_generic_owner_headers`);
2. resolve constraints and aliases;
3. complete records, unions, Interfaces, and their constructor schemes;
4. build top-level, method, and nominal-function schemes, then validate the
   constraints deferred while signatures were incomplete
   (`generic_validate_pending_generic_constraints`);
5. check module variables at their import/variable frontier;
6. check bodies with declaration parameters rigid; and
7. construct and validate the declared module type.

Pre-reservation makes owner names and all binders in one list available while
constraints are resolved without reordering declarations. Cycles and
unsatisfied constraints still fail semantically. Module-variable visibility,
ordinary duplicate winners, initialization, member/slot ordering, and codegen
order remain AST-order properties.

A rigid unconstrained `Parameter` is not `Type.Value` during this pass. The
relation layer admits only identical-parameter transport and storage, ordinary
Option operations, same-parameter Array/Map operations, uniform equality,
conversion to/from its constraint carrier, and written `as`/`is`. A constrained
parameter additionally exposes exactly its applied Interface's read-only
fields and methods. It does not inherit operations from a possible future
binding. Distinct parameters do not become equal merely because erasure later
gives them the same carrier.

Generic Interface satisfaction is checked on the surface schemes
(`types.generic_interface_implementation`). After owner substitution, every
required field needs a visible same-name const record field with the ordinary
assignment adjustment, and an implementation method must have the same
callable-local binder arity as the required method. `close_generic_method_pair`
substitutes one shared set of `Parameter`s into both binder lists, so
corresponding constraints compare equal exactly when they are
alpha-equivalent, and the directional method-callable check then runs under
those shared rigid parameters. Missing, inaccessible, mutable, differently
constrained, or incompatible members fail before erasure. The erased signature
is never used to make two incompatible generic methods appear equal.

Generic source visibility follows the same explicit opt-in. An import whose
terminal `.titan` marker was paired with trusted source provenance can select a
local owner, scheme, or forwarding alias through its direct capability;
ordinary source imports, binary recovery, and transitive importers remain
public-only.

## Local instantiation and inference

An inferred outer generic AST use owns one checker-only inference context
(`checker/calls.lua`). Its fresh cells use occurrence scopes distinct from
declaration scopes and from every other application. Nested generic calls,
constructors, methods, bound methods, and contextual first-class uses inherit
that ambient context, register their own occurrence scopes and child use
records, and may retain cell-to-cell or structural equations until a real term
closes either side. Every equation is occurs-checked before a union-find class
(`generic_inference_root`) is joined or receives a structural binding.

Inference has an explicit selection/checking split.

### Ordered selection

The call scheduler first checks the callee or receiver. The helper
`generic_infer_static_result_context` then applies the current static policy:
available expected-result slots are consumed left-to-right before evaluated
arguments. Keeping that policy behind one phase boundary makes it independent
of the run-time-order machinery. Positional arguments are then consumed
left-to-right; named fields in their written order; a final expression's fixed
results in result order followed by its open tail; and synthesized omissions
only after all written expressions.

A possible generic first-class expression is checked in its lexical callback.
It never pre-scans later positional arguments: the fresh child occurrence joins
the ambient context and publishes its possibly open callable equation
immediately. Bound-method receivers and computed variable paths use the ordinary
single descent, so neither the producer nor its receiver is replayed. Constructor
classification likewise prechecks an arbitrary call callee once; any callee
whose resolved static type is `value` remains contextual, including field,
index, and computed forms. The later real call consumes that transferred callee
check instead of descending again.

`generic_unify_inference` is the equation/first-selection operation. At entry it
smart-substitutes both the declaration-side pattern and producer type. If both
are now closed with respect to the ambient context, it succeeds without raw
comparison: the cell was already selected and the owning finalizer will run the
ordinary directional assignment check. If either side still contains an
ambient cell, invariant structural descent continues, so a closed consumer can
still bind cells owned by a nested producer. This small boundary is phase one;
it neither inserts casts nor emits an ordinary later-term mismatch.

Structural descent covers Option, Array, Map, Function, and same-owner nominal
applications. It records only open-cell equations and first concrete bindings;
it does not choose numeric conversions, Interface implementations, or common
supertypes. A later independently built Array/Map/nominal application therefore
reaches the ordinary invariant assignment relation after selection instead of
being rebuilt component by component.

Argument evidence may peel one outer Option (`checker/common.lua`
`deoptionize`) when its formal is a nonoptional structural shape, allowing a
Map parameter such as `{K: V}` to infer from `({string: T})?`. Direct
inference-cell formals retain the entire optional type. This boundary
adjustment does not alter recursive structural unification; the ordinary
argument finalizer still owns the checked Option force and rejects
incompatible nested shapes. For a literal passed to an optional Array formal,
constructor finalization retains the present Array context, completes element
inference and checking once, then applies the ordinary outer Option wrap.

Constructor consumers expose evaluated component edges in language order:

- positional Array/integer-Map values from left to right, including each fixed
  result of the trailing producer before its open tail;
- each computed Map key immediately before its value; and
- record fields in written order, independent of declaration-slot order.

Generic `for/in` treats its iterator plus hidden state/control inputs as one
delivered tuple. Written producers contribute once at their source position;
fixed multi-results are consumed in result order, while synthesized `...`
projections and final missing-nil slots are consumed left-to-right without
replaying their producer. Iterator result annotations and carrier closure happen
only after those hidden inputs have supplied their evidence.

Once an element/field pattern closes, later components are left for ordinary
constructor finalization, which may install scalar, Option, gradual, callable,
or Interface adjustments. This is construction-time adaptation, not variance
of existing containers.

### Pending producers and defaults

Only genuinely context-only producers are deferred. These include incompletely
annotated lambdas, contextual calls through `value`, ownerless named record
constructors, empty constructors, and nested constructor components whose
syntax still needs a sink. A generic first-class function or method instead
creates its fresh occurrence inside the ambient operation immediately and
registers its open callable equation at the written edge; declaration
constraints from that equation therefore drain before the next lexical edge.
A pending record retains its written fields and resolves descriptors in source
order after its owner appears. A direct open empty constructor retains no false
Array evidence; a later whole context may select Array, integer-keyed Map, or
record, while the constructor-default phase otherwise selects `{integer}`. A
nonempty direct positional constructor selects Array as soon as its first
completed component is available. It remains whole-shape pending only while
every selecting component needs context, so a later exact integer-Map context
may still select its shape. Default discovery is postorder: a nested empty
constructor or computed key/value first completes its own default, and its
completed type then becomes real evidence for the nonempty parent. The parent
is marked invalid only when that ordinary component check actually failed.

Discoveries have two finite phases (`generic_run_inference_discovery_phase`).
The `"evidence"` phase drains ready equations and context-ready producers to a
fixed point. Only then may the `"default"` phase apply an ordinary constructor
shape/default (an empty constructor unifies with `Array(Integer)`); evidence
is drained again after each default round. Generic carrier closure runs after
both phases. Deferred callbacks execute under their original AST-owned use, so
any nested occurrence is registered at the correct postorder position. Each
callback is one-shot.

Constraint propagation is a FIFO queue of changed union-find roots
(`constraint_queue`, `generic_enqueue_constraint_root`), not a global
fixed-point scan. Every constrained occurrence owns a dense record with a
lexical sequence; unioned equivalence classes merge those records in sequence
order, and a changed binding queues only that root's records. Smart
substitution similarly visits only inference scopes reachable from the type
being rewritten, using a direct `scope_entries` index. These two bounds
preserve first-evidence/diagnostic order while keeping independent constrained
siblings linear rather than repeatedly rescanning the entire ambient context.

A derived operation use is registered before descending whenever an expression
copies checker-owned annotations from an open child. This covers computed
calls/methods, contextual `value` calls, parentheses, field/index projections,
bound methods, fixed/open result projections, and constructors. Postorder
finalization refreshes those annotations after child uses close; it is an
annotation dependency order, never permission to reorder source evidence.

Only the owning outer use closes the context
(`generic_close_inference_context`). Closure performs:

1. ordered callee/receiver, static-result, argument, result-slot, and constructor
   selection while the written subtree is checked;
2. evidence discovery and constraint-equation propagation;
3. ordinary constructor defaults followed by another evidence drain;
4. declared-carrier closure of genuinely free equivalence classes, preferring a
   resolvable constrained Interface application over unconstrained `value`
   (`generic_default_inference_cells`);
5. validation of every declaration-local constraint and
   `types.transient_roundtrip` of every binding; and
6. postorder finalization of the application/operation tree.

Finalization is phase two for stored surface edges. It smart-substitutes the
resolved target and calls `coerce_and_check`, the open-run assignment,
record-field, or result-adjustment path exactly once. Those paths freeze the
ordinary plan/cast/guard/Interface or callable wrapper and report a mismatch at
the later source term. Generic erasure subsequently inserts only the separate
closed-surface-to-carrier boundary. It does not rediscover or reverse the
surface decision.

The context is AST-owned; its ambient pointer lives only in the current checker
symbol table during descent. Finalizers do not reevaluate written expressions.
Operation markers and occurrence Parameters are removed before the code-facing
AST returns. Result-only/phantom cells and unresolved nested equations therefore
close without leaving a wildcard, metadata cell, or run-time type argument.

Smart substitution (`types.substitute_inference`, wrapped by the checker's
`generic_substitute_inference`) rebuilds types through the canonical
constructors rather than replacing leaves in place. It:

- collapses `Option(value)` and nested Options (`types.canonical_option`);
- de-optionizes Array element and Map value positions according to their
  storage rules (`types.canonical_array`, `types.canonical_map`);
- rejects nil/optional Map keys;
- revalidates generic owner arity and constraints;
- revalidates fixed, variadic, and flexible callable shapes; and
- reruns recursive type-argument eligibility.

The same path handles explicit, inferred, bare all-`value`, imported, and
metadata-recovered applications. No path may smuggle a syntactically valid but
canonically ill-formed result around reconstruction.

## Freezing the declared graph

After all surface bodies and uses are checked, `checker/entry.lua` calls
`generic_lower_erased_core` (`checker/lowering.lua`). It first freezes a
detached, immutable declared module graph on `ast._declared_type`
(`generic_freeze_declared_core`, `generic_freeze_declared_annotations`). That
graph retains owners, scopes, schemes, parameters, applications, constraints,
and public forwarding aliases exactly as required for interface metadata.

The code-facing graph is separate:

- `ast._type` becomes the ordinary erased module descriptor used for slots and
  lowering, checked by `types.assert_erased`;
- declaration and expression `_type` annotations become ordinary erased types
  (`generic_lower_erased_annotations`, `generic_refresh_erased_annotations`);
- `generic_prepare_erased_registry` builds an erased copy of `types.registry`,
  stored as `ast._erased_registry`; `coder.generate` installs it as
  `types.registry` before generating code;
- temporary inference and surface-boundary links survive only until focused
  cast insertion has materialized ordinary annotations; and
- written generic binders and applications move to the private
  `_surface_typeparams` and `_surface_typeargs` AST edges, with canonical
  semantic `_decl` bindings, and their public lists are cleared.

No descriptor reachable from `ast._declared_type` is mutated during erasure. In
particular, the declared graph cannot share an owner table whose fields are
later rewritten to `value`. This separation is what lets metadata remain
precise while coder enumerates the same ordinary public/private slots and
layouts as non-generic code.

### Erased-graph validation

`types.contains_generic(typ, memo)` is the predicate behind
`types.assert_erased` and `types.is_erased`. It reports a generic form when it
reaches `Type.GenericScope`, `Type.TypeParameter`, `Type.Parameter`,
`Type.FunctionScheme`, `Type.GenericAlias`, an applied `Type.Nominal`, or a
record, union, Interface, method, or static method that still carries a scope
or binders. It walks every table field except `_tag`, with a per-call `seen`
set, so it also traverses plans and source-navigation edges and can be costly
on a large module graph. Callers therefore test cheap shapes first:
`checker_assignment_adjustment` (`checker/interfaces.lua`) walks a source or
target only when the other side is `value` or a C `TValue`, and
`generic_erased_descriptor` (`checker/lowering.lua`) walks only descriptors
outside the owner-bearing tags that always take its canonical erasure path.

The optional `memo` is explicit and caller-owned; there is no global or
cross-check cache. A memo is valid only while no table reachable from the
queried roots changes, and it records complete results only. A query that
returns true records its root. A query that returns false records every table
it visited, because the whole reachable graph was proven free of generic forms.
A false answer from a cycle back-edge inside a query that ultimately returns
true is not complete, so nothing else from that query is recorded. Exactly one
batch shares a memo: the end of `generic_lower_erased_core`, after the erased
module descriptor, the erased registry, the refreshed annotations, and the
frozen declared registry are complete. It asserts `ast._type` and then every
erased registry owner with one local memo and no intervening mutation, and
discards the memo when it returns. Every other caller passes none.

## Constraint erasure

Erasure (`types.erase`, `types.erase_constraint`) is a pure recursive type
transformation after surface checking:

```text
erase(T unconstrained) = value
erase(T : I<|args|>)      = erase(I<|args|>)
erase(I<|args|>)          = I<|erase(args)|>
```

Suppose `IBar<|A|>` is generic, `C` is unconstrained, and `B` has constraint
`IBar<|C|>`. `C` first erases to `value`, the constraint becomes
`IBar<|value|>`, and `B` uses that exact Interface carrier. The code-facing
nominal then drops the application arguments because every `IBar<|...|>` shares
the existing owner identity and `Udata *` representation.

Erasure recurses through:

- Options, Arrays, and Maps;
- fixed parameters and results;
- input varargs and flexible result tails;
- function, method, static, bound-method, and Interface callable shapes;
- fields, union payloads, locals, captures, and module slots; and
- the synthesized init/next/close calls of `for ... in`.

Smart reconstruction preserves existing Option/container rules. A `Cell<|T|>`
field becomes an ordinary `value` field. A `B:IBar<|C|>` native formal/result
becomes the ordinary `IBar` nominal. A surface
`IBar<|T|>:cons(T):IBar<|T|>` method becomes the code-facing
`IBar:cons(value):IBar` method.

The resulting physical types are exactly those the generic-unaware coder
handles: `value` is a `TValue`; an Interface nominal is a `Udata *`; Arrays
and Maps keep their ordinary backing representations; and Options, vararg
families, and flexible-output descriptors are selected from their erased
ordinary element types. There is no generic carrier algebra or special Option
ABI in coder.

At an optional Array boundary, a closed `({integer})?` and its erased
`({value})?` carrier use the ordinary structural `gradual_view` in either
direction. `assignment_adjustment` selects consistency before its separate
Option(Array) rule, so the outer Option does not turn this view into an
unsupported element-adjustment wrapper. The same Array and optional slot are
retained; closed element observations still use their ordinary strict guards.
Consistency requires matching Array qualifiers, so a mutable-to-const freeze
remains a separate operation and is never classified as this view.

Generic-for lowering (`generic_lower_forin`) visits the complete adjusted
setup tuple, including discarded surplus expressions, its synthesized
`_init_call`/`_next_call`/`_close_call`, and the visible-variable declaration.
These private AST edges contain executable casts that are reclassified before
type erasure (`generic_lower_call_in_place`): an unconstrained `T? -> T` force
becomes ordinary `value -> value`. Hidden calls remain raw producers so
codegen can assign their fixed and extra results to loop slots.

## Focused cast and adapter insertion

Erasure alone would lose the direction of a closed generic boundary. The
lowering pass therefore performs two bounded steps over the already checked
AST:

1. rewrite every declaration/expression occurrence to its ordinary erased
   source and target types, retaining a temporary reference to the frozen
   surface application where direction is needed; then
2. insert ordinary casts, guards, and callable/Interface adjustment annotations
   for those boundaries. `generic_erased_boundary_expression` asks for the
   ordinary assignment adjustment between the two erased types and applies it
   through `trycoerce`; when none exists it tries
   `generic_interface_downcast_expression`, and otherwise raises an internal
   compiler error.

This is not a second semantic typecheck. It performs no inference, constraint
search, or body recheck. It sees the exact types coder will see and emits only
the `CoercionPlan`, `GuardPlan`, callable adapter, Interface conversion,
written-cast, comparison, and AST cast forms codegen already consumes. It
does not ask an ordinary relation to rediscover an edge involving a
`Parameter` that has already disappeared.

For a closed use, the pass implements the selected direction rules:

| Surface boundary | Erased-core action |
| --- | --- |
| Closed statically accepted value → unconstrained `T` | Apply any already selected ordinary source adjustment, then box to `value`; no erasure-induced tag test. |
| Literal `value` → unconstrained `T` | Transport the raw `TValue`; do not convert it to the closed instantiation. |
| Closed record/union → `T:I` | Construct the existing Interface wrapper selected by surface checking, then use the erased `I` carrier. |
| Literal `value` → `T:I` | Run the existing exact-or-compiler-witnessed `value -> erase(I)` dynamic Interface cast immediately. |
| Rigid result → the same constraint carrier or `value` | Transport/box only; no precise projection. |
| Unconstrained rigid result → a more precise closed type | Run the existing strict gradual guard before unboxing or any representation-sensitive use. |
| Constrained erased Interface → closed record/union | Use the existing checked Interface downcast/backing-owner test and recover the wrapper's backing value. |
| Same-owner applied Interface views | Retain the wrapper; both erase to the same code-facing Interface nominal. |
| Concrete callable ↔ erased callable | Realize an ordinary closure-adjustment wrapper with per-component strict projections, Interface actions, and boxing. |

There is no special check elision for `id<|integer|>(1)`: the input boxes without a
tag test and the result receives the normal strict integer projection. A value
stored through unconstrained generic storage can remain polluted until any
later closed elimination, regardless of which call or provider produced it.

The pass covers every source and sink once: positional, named, omitted, and
surplus arguments; constructors; assignments, declarations, and returns;
field/payload reads and writes; Array/Map readers and writers; captures; fixed,
extra, and open results; input varargs and flexible results; first-class and
bound functions; Interface slots; hidden `for ... in` components; and Lua/FFI
boundaries. Lowering preserves expression order and materializes an operand when
an existing adjustment would otherwise reference it more than once.

Any missing temporary boundary link, unknown adjustment, generic-only plan, or
remaining generic annotation is an internal compiler error at this phase—not a
relation for coder to infer.

### Concrete callback wrappers

The standard example makes callable elaboration explicit:

```titan
function foldl<|T, U|>(
    values: {T},
    combine: function (T, U): (U),
    initial: U
): U
    local accumulator = initial
    for i = 1, #values do
        accumulator = combine(values[i], accumulator)
    end
    return accumulator
end
```

At a call closing `T = integer` and `U = string`:

```text
surface callback       function (integer, string): string
erased foldl callback  function (value, value): value
erased foldl body       function ({value}, erased callback, value): value
surface call result     string
```

Cast elaboration realizes a normal wrapper around the concrete callback. On the
call from erased `foldl`, the wrapper strictly projects its two `TValue`
arguments to `lua_Integer` and `TString *`; it calls the concrete native body;
and it boxes the string result into `TValue` without another tag check. The
caller then strictly projects the erased `foldl` result to string.

The inverse first-class use assigns a generic declaration either to an expected
monomorphic type or, without context, to its declared carrier signature. For
example, assigning `id` to `function (integer): (integer)` realizes a concrete outward
wrapper, while bare `local f = id` yields `function (value): (value)`. The concrete
wrapper boxes
its concrete argument for the canonical erased entry and strictly projects the
erased result. The concrete function tag and native relay belong to the wrapper;
the canonical erased native pointer is never exposed under a concrete tag.

A constrained callback component substitutes the erased Interface carrier.
Its wrapper is an ordinary frozen callable adapter
(`checker.freeze_callable_adapter`); the component actions include the
Interface wrapper construction and checked downcast. The same applies to
constrained input varargs and flexible results.

Each realized adapter is a fresh, traced closure. Source-closure identity across
an adjustment is not part of the contract, so removal or ownership protocols
must not compare the original callback with its adjusted wrapper.

## Arrays, Maps, Lua, and delayed projections

An unconstrained generic Array `{T}` erases to `{value}` and selects the
permissive `value` writer. For a binder `T: I`, `{T}` erases to `{erase(I)}`
and selects the corresponding Interface writer. Array erasure preserves the
outer qualifier, so `const { T }` becomes `const { value }` or
`const { erase(I) }` and selects the canonical const tag without a writer.
Maps use the same ordinary erased key/value behavior. Generics add no
element-writer family.

A literal `value` store into unconstrained dependent storage writes the raw
`TValue` and returns normally. A read that remains in the same erased carrier
also transports normally. The first later read consumed as a closed type carries
the existing strict `gradual_guard` plan. That successful read materializes a
concrete local; it does not rewrite or bless the aliased slot. The next precise
read guards again.

For constrained storage, dynamic ingress first passes `value -> erase(I)`.
Titan does not claim that `value` implements `I`. A later concrete projection
checks the Interface wrapper's backing nominal owner. Nested containers are
shallow: an outer nominal/container/callable skeleton is checked before use,
then a dependent child is guarded when eliminated.

The generated Lua entry for a generic declaration uses the actual erased
signature. Unconstrained positions use ordinary dynamic `value`; constrained
positions use the erased Interface and its normal exact-or-witnessed dynamic
cast. Known outer shapes keep their ordinary Lua checks. Dependent
unconstrained Lua writes may therefore delay their error until a closed Titan
projection; fixed owner-independent fields keep their eager policy. Applied
nominal `as/is` checks one owner metatable only.

## Type-argument admission and the FFI

`types.transient_roundtrip(t)` is a pure, cycle-safe eligibility predicate. It
proves that erasure has a canonical traced carrier and that a later precise
elimination has an existing sound strict plan. It does not create a conversion.
The exact positive frontier is:

- `Nil`, `Boolean`, `Integer`, `Float`, `String`, and `Value`;
- `Option`, `Array`, and `Map` when all recursively stored/read components pass
  and smart reconstruction is well formed;
- Titan `Function` when every fixed, variadic, and flexible input/result passes
  and callable wrappers can mediate both polarities;
- record, union, and Interface `Nominal` applications when the outer type has a
  sound nominal/Interface guard and every application argument passes;
- an in-scope rigid `Parameter`, subject to its enclosing constraint;
- exact `CInteger` and `CFloat` values through existing range/tag-checked
  implicit boxing and unboxing;
- complete `COwned` values through their stamped metatable and traced userdata
  wrapper lifetime (not because the C payload independently qualifies); and
- the compiler-recognized raw C `TValue` through its dedicated existing
  whole-slot implicit conversions.

The negative frontier is `Void`, descriptor-only tags, `CModule`, `CVoid`,
`CPointer`, `CArray`, `CFunction`, direct ordinary `CStruct`/`CUnion`, and
unresolved or legacy pointer, aggregate, array, and function-pointer shapes. The
recognized raw `TValue` is the one narrow aggregate exception, not general
`CStruct`/`CUnion` eligibility. Typedef and alias
normalization is cycle-safe. Rejection is recursive, including a forbidden leaf
in an Option, container, callable, or phantom generic application argument.

The checker runs this predicate for every explicit and inferred binding before
closing the use. This is intentionally stronger than
`types.has_tvalue_representation`: lightuserdata alone cannot recover pointee
type, bounds, or lifetime. No generic path broadens `value -> CPointer` or
another FFI relation. Foreign functions remain non-generic. Exportability is a
separate recursive check (`types.is_exportable_c_type_graph`): besides portable
graphs it accepts eligible named header typedefs, structs/unions, and fixed
arrays when every component is exportable and consumers provide the original
compatible C declarations. Ordinary imports do not inherit those headers.
This does not admit otherwise-forbidden C shapes as generic type arguments or
create new boxing/ownership conversions; see [the C FFI](../language/ffi.md).

Raw C `TValue` needs no special API whitelist. Once a parameter erases to
`value`, the focused ordinary pass selects the existing whole-slot
`value <-> C TValue` actions around audited Lua-stack operations. Likewise,
C-number and owned-value applications use their existing checked conversions,
not generic coder plans.

## Run-time representation and GC

Generic erasure changes type annotations, not object layouts:

- an unconstrained native leaf is the ordinary `TValue` carrier;
- a constrained native leaf is the ordinary Interface `Udata *` carrier;
- fields, union payloads, Array/Map elements, and captures are ordinary
  boxed/traced slots;
- all applications of one record/union/Interface share its metatable and
  userdata layout;
- module user-value slots and exported/private ordering are those of the
  erased module; and
- canonical function CClosures keep the ordinary module/tag/native/brand
  header, captures or bound receiver, and strict generic trailer.

Generic functions do not receive an operation environment through `_fn`.
Concrete-to-erased and erased-to-concrete callable adjustments are ordinary
CClosures. They root their immediate source, module, captures, target relay, and
any Interface wrapper through the ordinary upvalue/userdata edges. Fresh
objects are anchored before allocation can trigger GC, and stores use the same
forward or backward barrier selected by their owner kind. There is no
per-application GC object, registry table, type-name string, or specialization
cache.

This also preserves closure and aggregate cycles. An adapter may be fresh, but
its source and captured values remain traced. Vararg/flexible descriptors keep
their rule that the descriptor payload is not a root, so the semantic, VM,
allocation, and result homes keep collectable elements alive
([variadic GC discipline](variadic-parameters.md)).

## Coder boundary: an ordinary erased core

Immediately before code generation, `coder._assert_erased_boundary`
(`coder/generate.lua`) walks the AST (skipping `_declared_type`) and the
installed erased registry and rejects:

- `Type.GenericScope`, `Type.TypeParameter`, `Type.Parameter`,
  `Type.FunctionScheme`, `Type.GenericAlias`, or any inference tag;
- a `Type.Nominal` with nonempty `args`;
- a record, union, Interface, method, or static descriptor with a nonempty
  `scope` or `typeparams`; and
- `Ast.TypeParam`, or a nonempty `typeparams`, `typeargs`, or
  `_nominal_typeargs` list that lowering failed to consume.

Apart from this assertion and metadata selection, coder is generic-unaware. It
enumerates public/private slots from erased `ast._type`, generates one module's
C (one translation unit or several size-partitioned parts) per logical module,
chooses native types from ordinary
`Type.*` tags, and emits the ordinary function/closure/record/union/Interface,
vararg, flex, Array-writer, Lua-entry, and GC templates.

The sole metadata-side selection is `ast._declared_type or ast._type` (and the
per-declaration `_declared_type` equivalent) wherever metadata is serialized
(`coder/binary.lua`, `coder/module.lua`, `coder/generate.lua`, `driver.lua`).
Generated C does not contain a generic dispatch switch, type argument,
per-application witness, or instantiation table. Two closed applications of
one declaration have the same symbols and native entry; only their caller-side
ordinary adjustments differ.

## Compiled metadata and ABI boundary

Provider metadata serializes the frozen declared module graph. The generic
part of the schema is structural scopes, dense binder descriptors, rigid
parameter references, applied nominal arguments,
function/method/constructor schemes, generic owner descriptors, and public
forwarding aliases. It does not serialize expression inference cells, erased
AST annotations, run-time argument values, generic application witnesses, or
provenance summaries.

The closed validator
([driver](driver.md#interface-recovery-and-the-closed-validator)) proves for
generics, in `driver.lua` `validate_generic_scope`,
`validate_generic_binders`, `validate_parameter_descriptor`,
`validate_generic_alias`, and `validate_local_alias_projection`:

- structural scope and `(scope,index)` parameter identity;
- dense unique binder indexes and locally closed parameter references;
- alpha-stable constraints and applications;
- owner, constructor, method, and nominal-function quantification order;
- arity, constraint satisfaction, recursive eligibility, and canonical smart
  substitution results;
- public visibility and canonical record/union/Interface member projections;
- forwarding-alias target, chain, scope, and binder projection; and
- the value-facing ban on descriptor-only/private forms.

A constraint that names an external generic owner is not checked by the
validator; the checker reconciles it after the loader recovers that owner
(`driver.lua` `recover_contextual_owner`). DSO callable metadata, embedded
archive metadata, and prefix-container recovery validate the same schema.
Version gating is described in
[Compiled-module ABI](codegen-overview.md#compiled-module-abi).

Metadata retains precise declared applications while native provenance remains
owner-level. Selecting a static provider records its physical archive as one
direct link input; it does not specialize every carried key. Dynamic and
source providers likewise expose one native owner/entry per declaration.

## Generic async owners

`titan.async` (`titan/async.titan`) declares the generic Task, status,
cancellation, and result owners and the generic `run`, combinator, and
`channel<|T|>` schemes. Their runtime behavior (waits, listeners, suspension,
combinators, channels, subscriptions) is specified in
[the async runtime](libuv-runtime.md); this section records only how generics
shape them.

- **One all-`value` Runtime.** `run<|A, B|>(func: function (): (A)):
  Task<|A, B|>` constructs `Task<|A, B|>`, then stores
  `task as Task<|value, value|>` in the Runtime's `tasks: {Task}` (a bare
  owner is its all-`value` application). Runtime inventory, the ready queue,
  and dispatch use those all-value views of the same userdata. There is no
  existential Task, private application descriptor, or run-time recovery of
  `A` and `B`; a later concrete projection of a terminal value inserts the
  strict `A` or `B` guard.
- **Non-generic tokens.** `ResumeToken` is a non-generic record with
  `const source: string?`. `suspend(token: ResumeToken, cancel_action:
  (function (): ())?)` and `Task:resume(token: ResumeToken)` therefore have
  the same signature for every application and compare tokens by record
  identity.
- **Nil results.** A callback annotated `function (): (nil)` infers `A = nil`;
  a complete explicit application or surrounding result context can supply
  that application to an unannotated callback. Bare return or fallthrough
  supplies one nil to an exact `function (): (nil)` callable by ordinary
  return adjustment.
- **Channels.** `channel<|T|>(size: integer?)` returns
  `(function (T): (), function (): (T), function (): ())`. Because `size`
  provides no evidence for `T`, a result context, a complete explicit
  application, or final carrier closure selects the application. Erasure
  maps its `{T}` buffer and callbacks to `{value}`, `function (value): ()`,
  and `function (): (value)`; closed callers receive ordinary callable
  wrappers in which send boxes its accepted `T` and receive strictly projects
  it. The string-only `ChannelReader`/`ChannelWriter` records are not generic
  owners; their factory closes `channel<|string|>`.
- **Combinators.** The fixed-arity combinators quantify interleaved
  `(A_i, B_i)` per operand and never erase operands into an Array to share
  implementation. Their erased bodies use all-value Task/status carriers,
  while closed `Any*Result`, `Race*Result`, `All*Error`, `join*`, and `all_*`
  projections receive the strict guards described above.
- **Listeners.** `TerminalRegistration<|A, B|>` stores the adjusted listener.
  Registrations, removers, and adjusted listeners are ordinary traced state,
  never generic type witnesses.

## Failure boundaries and review checklist

A generics change is incomplete if any layer can observe a half-erased scheme.
Focused tests and reviews therefore establish:

- parser fidelity for binder/application lists, contextual closers, ambiguity,
  and synthetic applied constructors;
- scope/index alpha-equivalence, invariant applications, smart substitution,
  recursive eligibility, and deterministic serialization;
- fresh use isolation, result/context/lambda inference, constraint validation,
  rigid capability rejection, and explicit-source visibility;
- a frozen generic `ast._declared_type` beside a code-facing AST containing no
  runtime-facing parameter, scheme, application, alias descriptor, or inference
  cell; private `_surface_typeparams`/`_surface_typeargs` source syntax and their
  semantic bindings are outside the coder traversal;
- no guard on a statically typed closed-to-carrier argument, constructor, or
  write, but every carrier-to-closed edge uses the constraint-appropriate strict
  elimination—`gradual_guard` for unconstrained carriers (including
  `id<|integer|>(1)`'s result) and checked Interface downcast for constrained
  carriers;
- immediate `value -> erase(I)` checking for constrained ingress and delayed raw
  unconstrained pollution for fields, Arrays, Maps, Task payloads, and Lua;
- callback/first-class/bound-method wrappers over fixed, variadic, flexible,
  Interface, and Option components with GC rooting and fresh identity;
- exact ordinary native signatures (`TValue` for unconstrained leaves,
  `Udata *` Interface carriers for constrained leaves) and no generic coder
  branch;
- source, DSO, archive, prefix-container, and Lua agreement; and
- the all-value Runtime plus precise public async projections.

The invariant is fail-closed: after the explicit final carrier-closing pass, a
free inference cell, malformed recovered scheme, ineligible nested FFI argument,
missing boundary direction, or generic form at coder entry is a compiler or
metadata error. It is never permission for code generation to guess a
representation or semantic relation.
