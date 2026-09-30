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
declaration staging, constraint erasure, cast elaboration, unchanged codegen and
GC layouts, FFI admission, compiled metadata, and the all-`value` async Runtime.
The existing [checker plan architecture](type-relations-and-boundaries.md) is a
prerequisite: generics reuse those concrete plans rather than teaching the
coder a new relation.

Generics include their declared type schema in compiled-module ABI metadata.
The schema carries schemes and applications; it does **not** add a run-time
generic calling convention.

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
   parse-time constructor adjacency remain unchanged.
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
An `ExpCall` has one callable-local `typeargs` list regardless of whether its
ordinary argument carrier is `ArgsFunc`, `ArgsNamedFunc`, `ArgsMethod`, or
`ArgsNamedMethod`; generics do not add another `Args` tag. Explicit owner
arguments in `Pair<|T|>.member(...)` are a parser decoration on the namespace
`ExpVar`, `_nominal_typeargs`, with its source location. The checker consumes
that decoration before member selection, retaining the canonical owner and
closed owner application separately; erased lowering removes the decoration.
When owner and callable-local scopes are both open, the checker accepts both
complete written lists or infers both; one written scope never requests partial
inference of the other.

Owner nodes contain owner binders. A method, nominal function, or Interface
method contains only its callable-local binders; a top-level function contains
its complete binder list. Foreign functions and `ExpFunction` retain their
existing constructors and reject binder syntax. Existing locality storage also
remains unchanged: `TopLevelFunc.islocal` is positional while owners, methods,
statics, fields, and variants retain their existing decorations.

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
type syntax, and the checker proves their Interface meaning and scope. The
existing 100-item binder/argument guard remains separate from return-type lists
and later calling-convention limits.

Base names and dot/colon member suffixes can carry written type arguments.
The parser records these candidates once; a following call transfers its
callable-local list into `ExpCall.typeargs`. The checker validates whether the
base is a generic callable or an applicable nominal namespace, preserves the
separate owner/callable scopes, and rejects explicit first-class owner-member
applications. `Pair<|T|>.member(...)` still places owner arguments on the
namespace rather than on `new`.

Missing binders, constraints, arguments, or `|>` receive committed syntax
labels. Eligibility, owner arity, partial application, and direct-call-only
rules remain semantic checks. There is no arbitrary lookahead for a possible
generic call.

### Parse-time constructor elaboration

The parser continues to place synthesized record `new` and union-variant
`TopLevelStatic` nodes immediately after their owner. For `Pair<|T, U|>` the
synthetic constructor:

- has `typeparams = {}` rather than copying the owner binders;
- gives its field or payload parameters syntax that refers directly to `T` and
  `U`;
- returns `TypeName("Pair", {TypeName("T", {}), TypeName("U", {})})`; and
- retains `_record_constructor`, `_union_constructor`, and `_union_variant`
  exactly as before.

The checker attaches owner quantification only after completing the canonical
record or union descriptor. It derives the constructor scheme from the
canonical fields/variants and validates the adjacent parser node against it.
This prevents double quantification without moving desugaring, changing AST
order, or giving constructors a second independent signature.

## Surface type metadata algebra

Generic-aware checking uses declaration descriptors that never reach ordinary
coder dispatch:

```text
Type.GenericScope(modname, optional_owner_fqtn,
                  optional_callable_name, role, declaration_kind)
Type.TypeParameter(name, optional_constraint)
Type.Parameter(scope, index, diagnostic_name,
               optional_erased_interface_application)
Type.Nominal(fqtn, args)
Type.FunctionScheme(scope, typeparams, signature)
Type.GenericAlias(module, name, locality, target_owner_fqtn,
                  optional_target_alias_fqtn, target_scope, typeparams)

Type.Record(name, fields, functions, methods, nfields, scope, typeparams)
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

The `Parameter` stores nil for the implicit unconstrained `value` carrier, or
the recursively erased ordinary Interface application for a constrained
binder. Owner descriptors own owner binders. Method and static descriptors own
only callable-local binders, although their signatures can refer to owner
leaves. Constructors quantify owner binders; nominal functions quantify owner
binders followed by local binders; receiver methods have their owner arguments
fixed and instantiate only local binders. A top-level `FunctionScheme` wraps one
ordinary function signature. Ordinary first-class function types are never
schemes.

All optional names and scopes use nil as well. When a consumer needs to recover
a binder's surface constraint, `parameter_surface_constraint` returns the
optional constraint plus a validity boolean. A valid unconstrained binder is
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

The checker preserves the combined AST's existing source order. Its generic
surface stages are:

1. reserve imports, owner headers, `GenericScope`s, binder names, and arities;
2. resolve constraints and aliases;
3. complete records, unions, Interfaces, and their constructor schemes;
4. build top-level, method, and nominal-function schemes;
5. check module variables at their existing import/variable frontier;
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

Generic Interface satisfaction is checked on the surface schemes. After owner
substitution, every required field needs a visible same-name const record field
with the ordinary assignment adjustment, and an implementation method must
have the same callable-local binder arity as the required method. Corresponding
binder constraints are compared by alpha-equivalence, and the existing
directional method-callable compatibility check runs under the matched rigid
parameters. Missing, inaccessible, mutable, differently constrained, or
incompatible members fail before erasure. The erased signature is never used
to make two incompatible generic methods appear equal.

Generic source visibility follows the same explicit opt-in. An import whose
terminal `.titan` marker was paired with trusted source provenance can select a
local owner, scheme, or forwarding alias through its direct capability;
ordinary source imports, binary recovery, and transitive importers remain
public-only.

## Local instantiation and inference

An inferred outer generic AST use owns one checker-only inference context. Its
fresh cells use occurrence scopes distinct from declaration scopes and from
every other application. Nested generic calls, constructors, methods, bound
methods, and contextual first-class uses inherit that ambient context, register
their own occurrence scopes and child use records, and may retain cell-to-cell
or structural equations until a real term closes either side. Every equation is
occurs-checked before a union/find class is joined or receives a structural
binding.

Inference has an explicit selection/checking split.

### Ordered selection

The call scheduler first checks the callee or receiver. The helper
`infer_static_result_context` then applies the current static policy: available
expected-result slots are consumed left-to-right before evaluated arguments.
Keeping that policy behind one phase boundary makes it independent of the
run-time-order machinery. Positional arguments are then consumed left-to-right;
named fields in their written order; a final expression's fixed results in
result order followed by its open tail; and synthesized omissions only after
all written expressions.

A possible generic first-class expression is checked in its lexical callback.
It never pre-scans later positional arguments: the fresh child occurrence joins
the ambient context and publishes its possibly open callable equation
immediately. Bound-method receivers and computed variable paths use the ordinary
single descent, so neither the producer nor its receiver is replayed. Constructor
classification likewise prechecks an arbitrary call callee once; any callee
whose resolved static type is `value` remains contextual, including field,
index, and computed forms. The later real call consumes that transferred callee
check instead of descending again.

`unify_inference` is the equation/first-selection operation. At entry it
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

Argument evidence may peel one outer Option when its formal is a nonoptional
structural shape, allowing a Map parameter such as `{K: V}` to infer from
`({string: T})?`. Direct inference-cell formals retain the entire optional
type. This boundary adjustment does not alter recursive structural unification;
the ordinary argument finalizer still owns the checked Option force and rejects
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

Discoveries have two finite phases. The `evidence` phase drains ready equations
and context-ready producers to a fixed point. Only then may the `default` phase
apply an ordinary constructor shape/default; evidence is drained again after
each default round. Generic carrier closure runs after both phases. Deferred
callbacks execute under their original AST-owned use, so any nested occurrence
is registered at the correct postorder position. Each callback is one-shot.

Constraint propagation is a dirty-root worklist, not a global fixed-point scan.
Every constrained occurrence owns a dense record with a lexical sequence;
unioned equivalence classes merge those records in sequence order, and a changed
binding queues only that root's records. Smart substitution similarly visits
only inference scopes reachable from the type being rewritten, using a direct
scope-to-entry index. These two bounds preserve first-evidence/diagnostic order
while keeping independent constrained siblings linear rather than repeatedly
rescanning the entire ambient context.

A derived operation use is registered before descending whenever an expression
copies checker-owned annotations from an open child. This covers computed
calls/methods, contextual `value` calls, parentheses, field/index projections,
bound methods, fixed/open result projections, and constructors. Postorder
finalization refreshes those annotations after child uses close; it is an
annotation dependency order, never permission to reorder source evidence.

Only the owning outer use closes the context. Closure performs:

1. ordered callee/receiver, static-result, argument, result-slot, and constructor
   selection while the written subtree is checked;
2. evidence discovery and constraint-equation propagation;
3. ordinary constructor defaults followed by another evidence drain;
4. declared-carrier closure of genuinely free equivalence classes, preferring a
   resolvable constrained Interface application over unconstrained `value`;
5. validation of every declaration-local constraint and
   `types.transient_roundtrip`; and
6. postorder finalization of the application/operation tree.

Finalization is phase two for stored surface edges. It smart-substitutes the
resolved target and calls the existing `coerce_and_check`, open-run assignment,
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

Smart substitution uses Titan's canonical constructors rather than replacing
leaves in place. It:

- collapses `Option(value)` and nested Options;
- de-optionizes Array and Map value positions according to their existing
  storage rules;
- rejects nil/optional Map keys and other invalid reconstructed keys;
- revalidates generic owner arity and constraints;
- revalidates fixed, variadic, and flexible callable shapes; and
- reruns recursive type-argument eligibility.

The same path handles explicit, inferred, bare all-`value`, imported, and
metadata-recovered applications. No path may smuggle a syntactically valid but
canonically ill-formed result around reconstruction.

## Freezing the declared graph

After all surface bodies and uses are checked, the checker builds a detached,
immutable declared module graph and stores it on `ast._declared_type`. That graph
retains owners, scopes, schemes, parameters, applications, constraints, and
public forwarding aliases exactly as required for ABI metadata.

The code-facing graph is separate:

- `ast._type` becomes the ordinary erased module descriptor used for slots and
  lowering;
- declaration and expression `_type` annotations become ordinary erased types;
- `types.registry` is replaced with or points at a detached erased owner
  registry;
- temporary inference and surface-boundary links survive only until focused
  cast insertion has materialized ordinary annotations; and
- written generic binders and applications remain on the private
  `_surface_typeparams` and `_surface_typeargs` AST edges, with canonical
  semantic `_decl` bindings, after their public runtime lists are cleared.

No descriptor reachable from `ast._declared_type` is mutated during erasure. In
particular, the declared graph cannot share an owner table whose fields are
later rewritten to `value`. This separation is what lets metadata remain
precise while coder enumerates the same ordinary public/private slots and
layouts as before.

## Constraint erasure

Erasure is a pure recursive type transformation after surface checking:

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

The resulting physical types are exactly those already understood by
`coder.lua`: `value` is a `TValue`; an Interface nominal is a `Udata *`; Arrays
and Maps keep their ordinary backing representations; and Options, vararg
families, and flexible-output descriptors are selected from their erased
ordinary element types. There is no generic carrier algebra or special Option
ABI in coder.

At an optional Array boundary, a closed `({integer})?` and its erased
`({value})?` carrier use the ordinary structural `gradual_view` in either
direction. `assignment_adjustment` selects consistency before the separate
Option/Array qualifier rules, so the outer Option does not turn this view into
an unsupported element-adjustment wrapper. The same Array and optional slot
are retained; closed element observations still use their ordinary strict
guards. Consistency requires matching Array qualifiers, so a mutable-to-const
freeze remains a separate operation and is never classified as this view.

Generic-for lowering visits the complete adjusted setup tuple, including
discarded surplus expressions, and its synthesized initial/next/close calls
and visible-variable declaration. These private AST edges contain executable
casts whose plans must be rebuilt before type erasure: an unconstrained
`T? -> T` force becomes ordinary `value -> value`. Hidden calls remain raw
producers so codegen can assign their fixed and extra results to loop slots.

## Focused cast and adapter insertion

Erasure alone would lose the direction of a closed generic boundary. The
checker therefore performs two bounded lowering steps over the already checked
AST:

1. rewrite every declaration/expression occurrence to its ordinary erased
   source and target types, retaining a temporary reference to the frozen
   surface application where direction is needed; then
2. insert ordinary casts, guards, and callable/Interface adjustment annotations
   for those boundaries.

This is not a second semantic typecheck. It performs no inference, constraint
search, or body recheck. It sees the exact types coder will see and emits only
the existing `CoercionPlan`, `GuardPlan`, callable adapter, Interface conversion,
written-cast, comparison, and AST cast forms already consumed by codegen. It
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

A constrained callback component substitutes the erased Interface carrier and
uses ordinary wrapper construction/downcast. If the current callable-adjustment
emitter cannot lift a nested record/Interface action, the lowering pass
synthesizes an ordinary `Ast.ExpFunction` adapter whose body contains the
existing Interface casts. The same technique covers constrained input varargs
and flexible results. Coder sees a normal lambda and normal annotations.

Each realized adapter is a fresh, traced closure. Source-closure identity across
an adjustment is not part of the contract, so removal or ownership protocols
must not compare the original callback with its adjusted wrapper.

## Arrays, Maps, Lua, and delayed projections

An unconstrained generic Array `{T}` erases to `{value}` and selects the
existing permissive `value` writer. For a binder `T: I`, `{T}` erases to
`{erase(I)}` and selects the corresponding existing Interface writer. Array
erasure preserves the outer qualifier, so `const { T }` becomes
`const { value }` or `const { erase(I) }` and selects the canonical const tag
without a writer. Maps use the same ordinary erased key/value behavior. No new
element-writer family is generated.

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
cast. Known outer shapes keep today's Lua checks. Dependent unconstrained Lua writes may
therefore delay their error until a closed Titan projection; fixed owner-
independent fields keep their eager policy. Applied nominal `as/is` checks one
owner metatable only.

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
separate recursive check: contextual primitives and their portable
pointer/function/owned closure are accepted, while imported typedefs and other
header-dependent C descriptors remain forbidden.

Raw C `TValue` needs no special API whitelist. Once a parameter erases to
`value`, the focused ordinary pass selects the existing whole-slot
`value <-> C TValue` actions around audited Lua-stack operations. Likewise,
C-number and owned-value applications use their existing checked conversions,
not generic coder plans.

## Run-time representation and GC

Generic erasure changes type annotations, not object layouts:

- an unconstrained native leaf is the ordinary `TValue` carrier;
- a constrained native leaf is the ordinary Interface `Udata *` carrier;
- fields, union payloads, Array/Map elements, and captures remain existing
  boxed/traced slots;
- all applications of one record/union/Interface share its metatable and
  userdata layout;
- module user-value slots and exported/private ordering are unchanged; and
- canonical function CClosures retain the existing module/tag/native/brand
  header, captures or bound receiver, and strict generic trailer.

Generic functions do not receive an operation environment through `_fn`.
Concrete-to-erased and erased-to-concrete callable adjustments are ordinary
CClosures. They root their immediate source, module, captures, target relay, and
any Interface wrapper through the same existing upvalue/userdata edges. Fresh
objects are anchored before allocation can trigger GC, and stores use the same
forward or backward barrier selected by their owner kind. There is no
per-application GC object, registry table, type-name string, or specialization
cache.

This also preserves closure and aggregate cycles. An adapter may be fresh, but
its source and captured values remain traced. Vararg/flexible descriptors retain
their current rule: the descriptor payload is not a new root, so the existing
semantic/VM/allocation/result homes keep collectable elements alive. Generics do
not weaken that discipline.

## Coder boundary: an ordinary erased core

Immediately before `coder.generate`, a closed invariant walk rejects:

- `Type.Parameter`, `Type.FunctionScheme`, `Type.GenericAlias`, or an inference
  cell in a code-facing annotation;
- any applied nominal argument in a code-facing owner type;
- a nonempty generic binder/type-argument list that lowering failed to consume;
  and
- any generic-only adjustment plan.

Apart from this assertion and metadata selection, coder is generic-unaware. It
continues to enumerate public/private slots from erased `ast._type`, generate
one translation unit per logical module, choose native types from ordinary
`Type.*` tags, and emit the existing function/closure/record/union/Interface,
vararg, flex, Array-writer, Lua-entry, and GC templates.

The sole metadata-side selection is:

```lua
types.serialize(ast._declared_type)
```

rather than serialization of erased `ast._type`. Generated C does not contain a
generic dispatch switch, type argument, per-application witness, or
instantiation table. Two closed applications of one declaration have the same symbols and native entry;
only their caller-side ordinary adjustments differ.

## Compiled metadata and ABI boundary

The current ABI serializes the frozen declared module graph. The schema adds structural
scopes, dense binder descriptors, rigid parameter references, applied nominal
arguments, function/method/constructor schemes, generic owner descriptors, and
public forwarding aliases. It does not serialize expression inference cells,
erased AST annotations, run-time argument values, generic application
witnesses, or provenance summaries.

The closed validator proves:

- structural scope and `(scope,index)` parameter identity;
- dense unique binder indexes and locally closed parameter references;
- alpha-stable constraints and applications;
- owner, constructor, method, and nominal-function quantification order;
- arity, constraint satisfaction, recursive eligibility, and canonical smart
  substitution results;
- public visibility and canonical record/union/Interface member projections;
- forwarding-alias target, chain, scope, and binder projection; and
- the existing value-facing ban on descriptor-only/private forms.

During recovery, referenced external generic owners and alias targets are loaded
before their arity and constraints are reconciled. DSO callable metadata,
embedded archive metadata, and prefix-container recovery validate the same
schema. ABI 2 includes generic Interface field metadata while retaining erased
implementation. A mismatched provider is rejected before decoding; generics add
no cross-ABI migration or compatibility provider.

Metadata retains precise declared applications while native provenance remains
owner-level. Selecting a static provider still records its physical archive as
one direct link input; it does not specialize every carried key. Dynamic and
source providers likewise expose one native owner/entry per declaration.

## Generic async implementation

`titan.uv` owns the generic Task, status, cancellation, and listener
declarations. `titan.async` exports constructor-preserving aliases of those
owners and owns the public `run`, combinator, and `channel<|T|>` schemes. The
provider-owned surface owners are:

```titan
record ResumeToken
    const source: string?
end

union CancellationReason<|B|>
    simple(string)
    complex(B)
end

union TaskStatus<|A, B|>
    ready()
    running()
    waiting()
    succeeded(A)
    failed(Error)
    cancelled(CancellationReason<|B|>)
end

record Task<|A, B|>
    local root: coroutine.Coro
    local runtime: Runtime
    local state: TaskStatus<|A, B|>
    local cancel_value: CancellationReason<|B|>?
    local cancel_action: CancelAction?
    local pending: value
    local root_index: integer
    local cleanup: boolean
    local terminal_registrations: {TerminalRegistration<|A, B|>}
    local suspended: boolean
    local resume_token: ResumeToken?
    local resume_pending: boolean
    local pending_cancellation_affected: boolean
end

local record TerminalRegistration<|A, B|>
    local listener: function (TaskStatus<|A, B|>): ()
    local live: boolean
end
```

Every Task field remains in the canonical owner. The generic registration
record stores the exact adjusted listener and its live bit. `ResumeToken` is a
separate non-generic nominal owner: all `Task<|A, B|>` applications store the same
optional token type, compare it by record identity, and use its optional source
only to diagnose a public explicit-resume mismatch. It is not an application
witness and does not participate in erased payload guards.

The facade re-exports that constructor namespace exactly as
`type ResumeToken = uv.ResumeToken`. Its non-generic boundaries are
`suspend(token: ResumeToken, cancel_action: SuspendCancelAction?)` and
`Task:resume(token: ResumeToken)`; closing or erasing `A` and `B` never changes
either signature.

The Runtime remains concretely all-value:

```text
task_roots     : {Task<|value, value|>}
current_task   : Task<|value,value|>?
libuv owners   : Task<|value, value|>
running_task() : Task<|value, value|>
```

Runtime creation spells `Task<|value,value|>.new` explicitly to state its
all-value storage invariant; the final carrier rule would choose the same
application without evidence. There is no existential Task, wildcard, private
application descriptor, or ambient recovery of `A`/`B`. A public `Task<|A, B|>` is
a shallow view of the same userdata.

The source-private operational entry remains monomorphic:

```text
local function run_internal(func: function (): (value)): Task<|value, value|>
```

Public `async.run<|A, B|>(func: function (): (A)): Task<|A, B|>` adapts the callback to the
real `function (): (value)` erased shape, calls `run_internal`, and returns the same Task
userdata through the owner-erased view. A callback annotated `function (): (nil)`
infers `A = nil`; a complete explicit application or surrounding result context
can instead supply that application to an unannotated callback. Once the
callback has the exact `function (): (nil)` shape, bare return or fallthrough supplies one
nil by ordinary return adjustment; this is not a generic special case. The
coroutine stores its raw result in `TaskStatus<|value,value|>.succeeded`; a later concrete success
projection inserts the strict `A` guard. Complex cancellation likewise stores a
raw `value` in `CancellationReason<|value|>.complex` and guards only at a concrete
`B` projection. Scheduler inventory, coroutine dispatch, pending operations,
cancellation actions, libuv callbacks, and cleanup helpers stay monomorphic.

Public `async.channel<|T|>(size)` declares `{T}` storage and returns
`(function (T): (), function (): (T), function (): ())`. Because `size` provides no evidence for `T`,
a result context, a complete explicit application, or final carrier closure
selects the application. Erased-core lowering recursively maps the Array and
callbacks to `{value}`, `function (value): ()`, and `function (): (value)`, exactly the single
pre-generic implementation shape. Closed callers receive ordinary traced
callable wrappers: send boxes its accepted `T`, receive strictly projects its
`T`, and close is unchanged. The string-only `ChannelReader` and
`ChannelWriter` records are not generic owners; their factory closes
`channel<|string|>` and stores those exact wrappers. Each channel closure triple
also captures one fresh private non-generic `ResumeToken`; its blocking paths
pass that record to `suspend`, and its send, receive, and close paths pass the
same record to `Task:resume(token)`.

The public fixed-arity combinators quantify interleaved `(A_i,B_i)` per operand.
Their named listener-based algorithms remain expanded through arity five; they
never erase the operands into an Array merely to share implementation. Their
ordinary erased bodies use all-value Task/status carriers, while closed
`AnyNResult`, `RaceNResult`, `AllNError`, `join*`, and `all_*` projections receive
the focused strict guards described above. Each invocation creates one fresh
non-generic private token, captures it in every deciding listener, and suspends
with that same record. The token carries no generic evidence; it only binds
those listeners to that exact explicit suspension.

Terminal listener removal no longer depends on closure identity.
`add_terminal_listener` allocates one fresh `TerminalRegistration<|A, B|>`, stores
the adjusted listener, appends that record, and returns a no-argument remover
closure capturing the Task and registration. The remover is idempotent and
removes that exact live record. If the Task is already terminal, registration
returns an idempotent no-op remover.

Publication detaches the dense registration Array as a stable snapshot,
installs an empty live Array, and makes later removers no-ops before delivering
the snapshot in registration order. Delivery ignores each listener error
independently and does not consult a mutable `live` bit again. Duplicate source
callbacks remain distinct, and removal during delivery cannot mutate or skip
the snapshot. The remover, registration, adjusted listener, and Task links are
ordinary traced state—never generic type witnesses.

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
  semantic bindings are explicitly outside the coder traversal;
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
- the concrete all-value Runtime plus precise public async projections and
  registration-remover ownership.

The invariant is fail-closed: after the explicit final carrier-closing pass, a
free inference cell, malformed recovered scheme, ineligible nested FFI argument,
missing boundary direction, or generic form at coder entry is a compiler or
metadata error. It is never permission for code generation to guess a
representation or semantic relation.
