# Generics v1 implementation and refactoring specification

This record refines the designer draft in
[`generics-v1.md`](generics-v1.md). The draft remains the preserved product
brief; this file fixes the
repository-specific source syntax, type model, inference, erased native ABI,
Transient/Shallow semantics selected during review, metadata, refactors,
dogfood boundary, tests, and acceptance criteria before implementation begins.
Where the draft's illustrative prose is incomplete or conflicts with an
explicit reviewed decision here (notably reverse unboxing checks, argument
eligibility, bare applications, and async Runtime storage), this specification
is normative for implementation.

## Status and scope

- Branch: `generics-v1`
- Draft-only preservation commit: `074a269` (`Add generics v1 design draft`)
- Current compiler/provider ABI before this work: 0.23
- Generics ABI: 0.24, a clean-start prototype boundary
- Implementation strategy: one erased body per generic declaration and one
  shared owner identity, with checker-frozen surface applications and one
  erased-core cast-elaboration
  pass; no
  monomorphization, hidden generic dictionary, per-object application
  descriptor, runtime taint, or provenance analysis
- Safety contract: each rigid parameter erases to its constraint (`value`/
  `TValue` when unconstrained, its applied Interface/`Udata *` when constrained).
  Generic-dependent storage may contain any value admitted by that erased
  constraint carrier. Titan inserts its ordinary strict gradual guard whenever
  such a carrier is unboxed or otherwise consumed at a more precise,
  representation-sensitive closed type.

Generics v1 includes:

- explicit type parameters on records, unions, Interfaces, top-level
  functions, record/union methods, record/union nominal functions, and
  Interface methods;
- applied nominal types, generic constructors, constrained type parameters,
  local bidirectional type-argument inference, and explicit complete
  type-argument lists;
- closed generic schemes in source and compiled module interfaces;
- erased ordinary native entries and elaborated concrete boundary casts, including
  first-class functions, methods, varargs, flexible results, Interfaces, Lua,
  and GC-safe aggregate storage;
- Transient/Shallow consistency between rigid parameters and their erased view,
  and pointwise between same-owner generic applications;
- a hard standard-module rename from `titan.iter` to `titan.iteration`, with
  generic `next`, `pairs`, and `ipairs`;
- `titan.gc.finalizable<T>` and its concrete SSL call site;
- generic `Task<A,B>`, `CancellationReason<B>`, `TaskStatus<A,B>`, and the
  existing fixed-arity async combinators, with a concrete all-`value` Runtime;
  and
- complete language/implementation manuals, ABI history, and focused parser,
  type, checker, coder, provider, and standard-library tests.

`IteratorOne`/`IteratorTwo`/`IteratorThree` and closer Interfaces remain deferred
until their exact method and tuple-adapter protocol is specified. The existing
four-value `for/in` protocol does not acquire a magic Interface conversion.

## Selected Transient/Shallow safety contract

Erasure uses the parameter's constraint carrier. An unconstrained parameter is
conceptually constrained by `value` and therefore uses canonical `TValue` in its
one erased body. A parameter constrained by an applied Interface `I<...>` uses
that recursively erased Interface application's `Udata *` carrier. Generic-
dependent fields, payloads,
Arrays, Maps, and captures remain boxed/traced slots, while native arguments,
locals, varargs, flexible results, and callable shapes select the corresponding
constraint carrier recursively.

When the checker closes `T` to `t`, every **reverse** transition from an erased
carrier to `t`'s ordinary concrete representation uses Titan's existing strict
gradual guard. Forward passage of an already statically accepted `t` into the
carrier never does. The reverse rule is the same regardless of how the carrier
was produced; there is deliberately no attempt to prove that one erased result
remained pristine.
For example:

```titan
function id<T>(x: T): T
  return x
end

local n = id<integer>(1)
```

boxes the integer into `TValue` **without a tag check**, runs the one erased
body, then performs the strict integer tag check only while unboxing the result
into `n`'s native `lua_Integer` representation. There is no special identity
fast path, result-dependency summary, `clean`/`dirty` bit, runtime taint, or
cross-module check-elision certificate.

The forward and reverse generic boundaries are intentionally asymmetric. A statically
typed closed value entering a rigid parameter or parameter-dependent aggregate
slot has already been proved by the checker and is boxed directly:

```titan
record Cell<T>
  item: T
end

local x: integer = get_integer()
local c: Cell<integer> = { item = x } -- equivalently Cell.new(x)
c.item = x
```

Neither constructor argument passing, the constructor store, nor the later
typed assignment performs a gradual tag guard. Any ordinary non-gradual source
adjustment selected by Titan's existing relations happens before boxing, but
erasure adds no forward check. Because this `Cell` parameter is unconstrained,
a source whose static type is literally `value` is also admitted as its raw
constraint carrier without target conversion and may pollute the slot. In both
cases the reverse read into an unboxed closed `integer` is where the strict tag
guard runs.

For a constrained binder the analogous carrier is narrower:

```titan
record ICell<T: Show>
  item: T
end
```

`ICell<R>` is shallow-consistent with `ICell<Show>`, not `ICell<value>`.
A closed `R` boxes/adapts to the `Show` Interface wrapper on the forward edge
without an additional test when the checker already selected that Interface
conversion. An arbitrary `value` must pass the ordinary checked `value as Show`
boundary before it can be stored. A later reverse projection to `R` checks the
wrapper's backing nominal owner. This is constraint erasure, not a hidden
application witness.

The same uniform reverse rule makes mutable gradual aliases safe:

```titan
record Cell<T>
  item: T
end

function replace<T>(cell: Cell<T>, x: value)
  cell.item = x
end

local cell = Cell.new(1)
replace(cell, "wrong")       -- stores the raw TValue and returns normally
local n: integer = cell.item -- strict integer guard raises here
```

The bad value may remain in the cell, be copied through generic code, compared
with uniform dynamic equality, or be overwritten without ever raising. It must
not reach `ivalue`, an integer callback, FFI, or another integer-native operation
without the ordinary guard. A successful guard materializes a concrete local;
it does not sanitize the aliased heap object, so a later field/container read is
guarded again when concretely consumed.

“First use” means first **representation-sensitive closed elimination**, not the
next syntactic occurrence. Copying, assignment to the identical rigid binder,
generic-to-generic calls, generic storage/return, Option nil tests, uniform
`TValue` equality/hash, and discard remain erased operations. Guards occur
before native scalar access, concrete operators/conditions, concrete callable
or Interface entries, ordinary concrete storage/results, C/FFI use, and every
fixed/variadic/flexible/`for-in` component that is unboxed to a closed type.
Nested values are shallow: check the immediate owner/container/callable skeleton
before dereference, then guard a dependent child only when that child is itself
eliminated.

An erased body reading `{T}` or `{K:T}` returns its constraint carrier; it cannot
and need not emit `gradual_guard(T)`. The closed consumer guards. An Array
constructed at unconstrained rigid `T` uses the canonical permissive `value`
writer, so a generic-created `{integer}` may accept a Lua float and fail on a
later strict read while a directly constructed monomorphic `{integer}` retains
its current eager writer. At constrained `T:I`, construction uses the exact
`erase(I)` writer: dynamic ingress must first cast to that Interface carrier, because
arbitrary `value` is not consistent with or admissible as constrained `T`.
Maps follow the corresponding constraint-carrier write/strict-read model.

Static generic applications remain invariant and unequal unless all arguments
are equal. Gradual consistency relates each rigid parameter to its own recursively erased
constraint carrier: unconstrained `T` to `value`, and `T:I` to `erase(I)` (for
example `IBar<C>` to `IBar<value>` when `C` is unconstrained). Pointwise same-
owner consistency follows those carriers. Thus
`Cell<integer>` is consistent with `Cell<value>` for an unconstrained owner
parameter, while `Box<R>` for `R:I` is consistent with `Box<erase(I)>`, **not** with
invalid `Box<value>` (because `value` does not implement `I`). These are shallow
views of the same owner userdata. `value as/is Cell<integer>` checks only the
`Cell` owner; it does not prove historical contents or the argument `integer`.
For an unconstrained argument, phantom/capability/typestate distinctions do not
survive a `G<value>`/Lua round trip and must not be used as dynamically enforced
authority. A constraint can preserve only the authority expressed by its erased
Interface, never the hidden precise implementing application.

Witness-free `value as T` inside an erased body follows the constraint. For an
unconstrained `T` it is a deferred carrier ascription accepting any valid
`TValue`; its nonraising twin `value is T` consequently returns true. For
`T:I`, it performs the ordinary `value -> erase(I)` cast (or nonraising
`is erase(I)` test) and yields that Interface `Udata *` carrier before T-typed
transport. Applied
`G<t>` `as/is` performs the shallow owner test. None of these tests narrows or
eliminates dependent contents beyond the selected outer constraint carrier.

Every type argument must satisfy the pure, cycle-safe
`transient_roundtrip(t)` eligibility predicate. It does not authorize a coercion;
it only proves that generic erasure has a canonical GC/lifetime-safe value
carrier and that every later closed elimination can use a sound existing strict
plan. Its exact tag frontier is:

- `Nil`, `Boolean`, `Integer`, `Float`, `String`, and `Value` qualify;
- `Option`, `Array`, and `Map` qualify only when every recursively stored/read
  component qualifies and the reconstructed shape passes ordinary Option/Map-key
  well-formedness;
- Titan `Function` qualifies only when every fixed/variadic/flexible parameter
  and result qualifies and recursive callable wrappers can mediate both
  polarities;
- `Nominal` record/union/Interface values require one sound outer nominal or
  Interface guard, and every argument of a generic application also qualifies;
  canonical owner fields are not recursively inspected as a deep heap promise;
- an in-scope `Parameter` qualifies as a rigid leaf, subject to its enclosing
  binder constraint;
- an FFI type qualifies exactly when Titan already has sound implicit
  conversions both to and from `value` that preserve its value, representation,
  GC/lifetime, and required dynamic checks. Thus exact `CInteger` and `CFloat`
  qualify through existing range/tag-checked boxing/unboxing, complete `COwned`
  through its stamped owner metatable and traced userdata lifetime, and raw C
  `TValue` through its existing whole-slot implicit conversions; and
- `Void`, descriptor-only tags, `CModule`, `CVoid`, `CPointer`, `CArray`,
  `CFunction`, `CStruct`, `CUnion`, and unresolved/legacy pointer, aggregate,
  array, or function-pointer shapes do not qualify. A typedef/alias qualifies
  only by cycle-safe normalization to a qualifying target, without losing its
  required C spelling at ordinary non-generic sites.

Rejection is recursive, including a forbidden type hidden in Option, callable,
container, or phantom generic arguments. The checker applies this admission test
to explicit arguments and every inferred binding before closing the use; an
ineligible FFI type is a compile-time error and never reaches erasure/codegen.
This is deliberately stronger than `has_tvalue_representation`; lightuserdata
cannot establish pointee type, bounds, or lifetime even for `id<T>`. Generics do
not invent any new FFI-to-`value` conversion merely to make a type eligible.
Foreign function declarations themselves can never declare type parameters.

No generic operation environment is passed through `_fn`. Concrete callback,
first-class, bound-method, and Interface adapters are still required wherever
an erased carrier enters a concrete callable ABI: the adapter applies the same
strict guard before the native body and boxes results back into canonical
carriers. These are ordinary traced closure-adjustment mechanisms, not runtime
type arguments inspected by the shared body. Like existing gradual callable
adjustments, each adaptation may create a fresh closure; no source-closure
identity preservation is promised.

A canonical generic declaration called from Lua uses its real constraint-erased
application: unconstrained binders are `value`, while `T:I` positions use exact
`I` Interface carriers. Lua arguments/writes entering constrained positions run
the ordinary dynamic `value -> erase(I)` cast at that boundary; this is not equivalent
to claiming that `value` implements `I`. Unconstrained dependent Lua writes
remain raw, so their failure moves to a later closed elimination. Fixed owner-
independent fields keep their current eager dynamic policy.

The guarantee is open-world representation safety under Titan's existing
trusted-generated-provider and supported-Lua-surface model. It is not a deep
homogeneous heap invariant, exact runtime application identity, Reynolds
relational parametricity, complete blame, or an unqualified static/dynamic
gradual guarantee.

## Architectural invariants

1. A generic declaration has one canonical immutable scheme. Every value use
   obtains fresh inference variables; no use mutates the declaration, nominal
   registry, imported interface, or another use.
2. A declaration type parameter is rigid while its body is checked. A
   use-site inference variable is mutable only inside its one inference
   context. The two representations are never conflated.
3. Every use closes to a monomorphic surface type before erasure. No inference
   variable may enter declared metadata or the code-facing AST; no generic Type
   form may enter ordinary coder paths.
4. Generic inference selects type arguments; it does not introduce subtyping,
   common-supertype search, lifted numeric conversion, or a second coercion
   relation. The subsequent erasure pass inserts only existing ordinary
   concrete adjustment kinds at each frozen generic boundary.
5. Applied generic nominals are invariant static types. All applications of one
   owner share its erased runtime metatable, userdata layout, symbols, module
   slots, and native body.
6. The checker freezes declared generic metadata, then lowers a separate copy/
   view of the AST to ordinary erased types with existing cast/adapter plans.
   Coder never discovers, interprets, or lowers a generic relation.
7. Generic source visibility is exactly ordinary source visibility. Direct
   source imports may select local generic declarations; binary interfaces and
   transitive importers remain public-only.
8. Module declarations remain staged and AST order remains authoritative for
   duplicate precedence, module variables, initializers, serialization order,
   and code generation.
9. ABI 0.24 is a clean rebuild boundary. Preserve 0.23 state; add no migration,
   cross-version cleanup, symbolic links, compatibility providers, or generic
   stale-file reconciliation.

## Source language

### Declaration binders

The syntax is the draft's direct angle-bracket spelling:

```titan
record Pair<T, U>
  first: T
  second: U
end

union Result<T, E>
  ok: T
  error: E
end

interface Stack<E>
  function push<R: Stack<E>>(value: E): R
end

function foldl<T, U>(a: {T}, f: (T, U) -> U, init: U): U
  ...
end

function Pair:map<V>(f: (T) -> V): Pair<V, U>
  ...
end

function Pair.make<V>(value: V): Pair<V, V>
  ...
end
```

A binder list is nonempty, dense, source ordered, has no trailing comma, and
uses the existing 100-item parser list limit. Each item is `Name` or
`Name: InterfaceApplication`. All names in an owner/callable binder list are
reserved before any constraint in that list is resolved, so mutually
referencing constraints are syntactically in scope. Cyclic or otherwise
unsatisfiable constraints fail during semantic validation.

Owner binders and callable-local binders are distinct scopes. A method or
nominal function sees its owner's binders and may add its own. Reusing an active
owner binder spelling in the callable list is rejected instead of shadowing it.
Nested lambdas inherit surrounding rigid parameters but cannot declare their
own.

Binders are not accepted on aliases, anonymous functions, or `foreign`
functions. A generic `main` is an ordinary function and never the standalone
entry point.

### Type applications

A named type may have a full argument list:

```titan
Pair<integer, string>
mod.Result<{string}, mod.Error>
Pair<T, U>?
{Pair<T, U>}
```

Arguments bind more tightly than the existing option suffix. Only a named
nominal/Interface owner or a constructor-preserving alias is applicable;
applying a parameter or another type shape is a higher-kinded use and is
rejected.

In an ordinary scalar type use, omitting every argument means the complete
all-`value` application. Thus bare `Task` is exactly `Task<value,value>`, not a
wildcard, raw unknown application, existential, or partial application. This is
valid only when `value` satisfies every owner constraint; otherwise omission is
an error. There is no written wildcard, partial application, variance, default
**call** type argument, or generic function type.

Owner-scheme contexts remain distinct: `Owner.member` constructor/static
selection and `function Owner:method` name the owner scheme so constructor/call
inference may bind its arguments. The exact RHS of a constructor-preserving
alias also names the scheme:

```titan
type Either = Pair                         -- forwards Pair's constructor
local type IntPair = Pair<integer, integer> -- concrete specialization
```

`Either<A,B>` is the same static type and namespace as `Pair<A,B>`; the alias
forwards owner arity and constraints without creating a runtime identity.
`local x: Either` is its all-`value` application. Alias chains preserve an
explicit type-namespace descriptor:

```text
Type.GenericAlias(module, name, locality, target_owner_fqtn, target_alias_fqtn_or_false,
                  target_scope, typeparams)
```

`target_alias_fqtn_or_false` preserves and validates an alias chain for diagnostics
and source-private capability; `target_owner_fqtn`, `target_scope`, and
`typeparams` are the canonical normalized projection used for application.
`typeparams` is the exact dense copied/alpha-remapped owner binder descriptor
list, never fresh parameters and never a value-level runtime member. The symtab
stores `GenericAlias` in its type-alias namespace. Applying it smart-substitutes
its arguments into the target owner and returns the ordinary canonical
`Nominal(target_owner_fqtn,args)`; member/static/constructor lookup delegates to
that same owner while retaining the alias declaration as source provenance.
Using it bare in scalar context performs the all-`value` application. Alias
normalization follows `target_alias_fqtn_or_false` cycle-safely and stops at the
canonical owner; a concrete `TypeAlias` RHS such as `Pair<integer,integer>`
remains the existing resolved Type value and has no arity.

Add `Type.GenericAlias` to every Type-tag dispatch audit. Public aliases encode
this descriptor in `Type.Module.type_members`; local ones remain omitted.
Serialization records module/name/locality, the canonical target owner/scope,
the alpha-stable dense binder/constraint list, and the optional public alias
chain, then recovery proves the projection equals the target owner. A direct
source-private target is permitted only through the existing direct source
capability and cannot be serialized. DSO/archive/prefix recovery reconstructs
the same applicable descriptor, never a runtime object. Constructor-preserving
aliases apply equally to records, unions, and Interfaces.

### Calls and explicit arguments

Ordinary calls infer all unresolved declaration parameters:

```titan
local pair = Pair.new(1, "one")
local result = foldl(xs, f, "")
local pushed = stack:push(value)
```

A caller may instead provide the **complete** unresolved list:

```titan
foldl<integer, string>(xs, f, "")
Pair<integer, string>.new(1, "one")
stack:push<MyStack>(value)
```

There is no partial explicit list. For a receiver method, owner arguments are
already fixed by the receiver and the explicit list names only method-local
binders. For a nominal constructor or function, attach the complete owner list
to the namespace (`Pair<T,U>.new`) and keep a complete callable-local list after
the member (`Pair<T,U>.from<V>`). If both scopes are open, provide both lists or
neither. For a top-level function the suffix is its callable list. Empty
variants and other result-only schemes use evidence first, then the fixed final
carrier rule.

A generic declaration cannot remain a polymorphic first-class value. Expected
monomorphic function context instantiates it:

```titan
local int_id: (integer) -> integer = id
local ctor: (integer, string) -> Pair<integer, string> = Pair.new
```

Without context, `local f = id` closes to the ordinary carrier signature. V1
has no explicit no-call specialization syntax: `Pair<integer>.new` is rejected.

The scannerless PEG grammar gives a complete `typeargs + call-arguments`
suffix priority over comparison parsing and recognizes owner `typeargs` only
when followed by a dot selector. Thus `f<T>(x)` and whitespace-equivalent
`f < T > (x)` are the same generic call, while `Pair<T>.new(x)` decorates the
namespace before selecting `new`. `a < b > c` remains comparisons; parentheses
force a comparison when needed. There is no
pre-parsing tokenization ambiguity for nested closers: a generic-list rule
consumes literal `>` delimiters contextually, so `Outer<Inner<T>>` closes twice,
while an expression rule continues to recognize ordinary `>>` as `SHR`. Do not
weaken the exported operator patterns. The reserved `::` token remains unused.

### Rigid parameter capabilities

A rigid unconstrained parameter `T` is semantically distinct from `value` even
though its erased carrier is a `TValue`. It permits only:

- assignment, argument passing, return, and storage where the target is the
  identical rigid parameter;
- wrapping in/forcing from `T?` under the ordinary option rules;
- Array elements and Map keys/values containing that same parameter;
- equality/inequality with the same rigid parameter, its option/nil where the
  ordinary option matrix admits it, or `value` through an explicit comparison
  plan;
- automatic conversion to and from `value`; and
- written `as`/`is`, whose operand is treated through the erased value
  representation.

It does not gain arithmetic, ordering, concatenation, length, indexing,
calling, fields, or methods merely because a later instantiation might support
them. Distinct rigid parameters are not equal/assignable just because their
carriers match.

A constrained rigid parameter replaces the implicit `value` constraint with its
substituted Interface constraint. Its erased carrier is that Interface after
recursive parameter erasure, not arbitrary `value`; conversion from `value` is
the existing checked Interface
cast, while conversion back to `value` boxes the Interface normally. It
additionally permits exactly that Interface's methods and exposes no concrete
fields, statics, or extra methods. Constraint-to-constraint inference in v1
requires the same applied Interface identity; structural entailment between
distinct Interfaces would be Interface subtyping and is not added.

An unconstrained type argument must satisfy
`types.transient_roundtrip`, the recursive canonical-carrier and strict-
elimination predicate defined above. A constrained argument must both satisfy
that predicate and be the exact Interface application, a visible record/union
application that implements it, or a rigid parameter with that exact constraint.
Raw C pointers and recursively containing shapes are rejected even though some
can be boxed; generics do not broaden ordinary `value -> CPointer` coercion.

Every closed-to-rigid argument, constructor, and assignment boundary converts its
statically accepted source directly to the binder's constraint-erased carrier
with no erasure-induced gradual tag check. For unconstrained T this is raw
`value`; for `T:I` it is exact Interface `erase(I)`. Every inverse rigid-to-more-precise-
closed boundary uses the ordinary strict guard before unboxing, including a direct
result from `id<T>`. There is no trusted reverse path based solely on static
call provenance and no runtime distinction among carriers admitted by the same
constraint after they enter generic-dependent storage.

### Static and runtime identity

`Box<integer>` and `Box<string>` are different invariant static types and are
not directly assignable. They share the one `Box` metatable and may be compared
for reference equality because that operation observes only erased owner
identity. Because this example's owner parameter is unconstrained, pointwise
gradual consistency relates either to `Box<value>` and preserves the same
userdata. A constrained `IBox<T:I>` instead relates to `IBox<erase(I)>`, never
`IBox<value>`. A Lua/`value` cast or `is` test for an applied nominal checks only
the erased owner after its written application is statically valid. Lua never
receives or supplies reified type arguments; each parameter uses its erased
value/Interface constraint.

Do not add per-instantiation metatables, registries, runtime type-name strings,
global specialization caches, provenance tags, or check-elision analysis.
Closed elimination of an erased `TValue` always guards.

## Frontend and source AST

### AST contract

Use these exact positional constructors; append fields so current source-order
captures and helpers remain recognizable:

```text
Ast.TypeParam(loc, name, constraint_or_false)
Ast.TypeName(loc, name, typeargs)
Ast.TypeQualName(loc, module, name, typeargs)
Ast.ExpCall(loc, exp, args, typeargs)

Ast.TopLevelRecord(loc, name, fields, typeparams)
Ast.TopLevelUnion(loc, name, variants, typeparams)
Ast.TopLevelInterface(loc, name, methods, typeparams)
Ast.TopLevelFunc(loc, islocal, name, params, rettypes, flexrettype,
                 block, typeparams)
Ast.TopLevelMethod(loc, class, name, params, rettypes, flexrettype,
                   block, typeparams)
Ast.TopLevelStatic(loc, class, name, params, rettypes, flexrettype,
                   block, typeparams)
Ast.InterfaceMethod(loc, name, params, rettypes, flexrettype, typeparams)
```

Every absent list is `{}` and only an absent `TypeParam.constraint` is false.
`TypeParam` is not a value `Decl`. `ExpCall.typeargs` occurs exactly once and is
independent of the existing `ArgsFunc`/`ArgsMethod`/named carriers; do not add
generic Args variants. Owner declarations store owner binders. Method, nominal-
static, and Interface-method nodes store only callable-local binders. Top-level
functions store their complete callable list. Foreign functions and lambdas
retain their existing constructors and reject binder syntax.

Retain current locality representation: TopLevelFunc keeps positional
`islocal`; methods/statics/owners and local fields/variants keep the parser's
existing `node.islocal` decoration. Do not normalize locality as part of this
feature. Retain the current `class` field spelling in these existing AST tags,
but use “owner” in new checker/type APIs and diagnostics. Every parser helper
passes explicit `{}` defaults, so no downstream visitor observes nil.

### Constructor elaboration

Retain Titan's architectural invariant that the parser emits the adjacent
synthesized `TopLevelStatic` nodes for record `new` and union variants, marked
with `_record_constructor`/`_union_constructor` and `_union_variant`. For owner
`Pair<T,U>`, each synthetic static has `typeparams = {}` (never a copy of owner
binders), its field/payload parameter syntax directly references `T`/`U`, and
its return syntax is exactly `TypeName(Pair, {TypeName(T,{}),TypeName(U,{})})`.
Qualified references are unnecessary because these are adjacent same-owner
nodes. An empty variant likewise returns the applied owner. Owner quantification
is attached only by the checker, preventing double quantification or a changed
explicit argument order.

After the checker completes the owner descriptor, derive the constructor scheme
once from canonical fields/variants and validate/annotate the already adjacent
lowered node with that scheme and applied owner return type. Coder lowering
continues to consume the same AST order and `ExpUnionInit`. This avoids a second
independent signature without moving desugaring across the parser/checker
boundary, changing duplicate precedence, or inserting nodes before staging.
Any future constructor-staging refactor is separate from generics v1.

### Grammar and diagnostics

Factor one named-type production shared by ordinary and owned-C syntactic
positions. In the scannerless PEG, generic-list productions consume a literal
`>` plus `SKIP*` in their own context; this naturally parses adjacent nested
closers without changing the ordinary expression patterns for `GT`, `GE`, or
`SHR`. Left-factor expression suffixes so one generic-list lookahead proves the
complete list and a following call delimiter or nominal-member dot before
committing, then selects positional/named arguments or the owner member without
replaying full alternatives. Parse a method's `: Name` prefix once before its
optional generic call tail or bound-method-reference tail. Thus ordinary calls
do not repeatedly enter recursive generic productions and ordinary `<`
comparisons do not emit misleading generic-list errors.

Add dedicated labels for missing binder name, missing constraint, binder-list
close, generic foreign function, generic lambda, and generic alias. Missing type-
argument/closing-delimiter labels are promised only after a declaration/type-
application context or a complete call-suffix lookahead has committed. For the
ambiguous direct-angle expression syntax, incomplete `f<T...` text may correctly
fall back to ordinary comparison parsing; pin its actual deterministic diagnostic
rather than claiming an impossible generic-specific error before commitment.
Every introduced label has a registry entry and parser spec. Add one label-
registry coverage assertion. Remove only confirmed stale labels/docs while this
boundary is open; preserve unrelated parser behavior.

## Generic-aware checker and erased core

### Two frozen views

The checker maintains two distinct products:

1. the **declared module type**, containing generic owners, schemes, binders,
   applications, aliases, and constraints exactly as required for source
   checking and ABI 0.24 metadata; and
2. an **erased ordinary AST**, containing only Titan's existing monomorphic AST
   and `Type.*` shapes plus existing concrete adjustment annotations.

Freeze a separate immutable declared module graph on `ast._declared_type`
before erasing anything. Keep `ast._type`, declaration/expression annotations,
and `types.registry` as the erased ordinary graph used by all code-facing paths.
The erasure pass builds a detached erased owner registry (or replaces the active
registry only after the declared graph is detached); no shared descriptor in
`ast._declared_type` is mutated. Coder continues to enumerate public/private
slots from ordinary erased `ast._type` exactly as today. Its sole metadata change
is `types.serialize(ast._declared_type)` instead of serializing erased
`ast._type`. Generics do not change module-userdata slots, record/union/Interface
layouts, closure upvalue layouts, symbol families, metatables, or any other non-
type metadata. Generic applications of one owner share all those existing
layouts.

All expression/declaration `_type` annotations handed to ordinary coder paths
are erased. No `Type.Parameter`, `Type.FunctionScheme`, applied nominal argument,
checker inference cell, or generic AST list may reach those paths. Add one
entry assertion at `coder.generate` for that invariant. Apart from selecting
`ast._declared_type` only for type serialization, coder generation remains
unchanged; it receives the same code-facing forms it receives today.

### Surface type metadata algebra

The generic-aware pass adds these declaration/interface descriptors:

```text
Type.GenericScope(modname, owner_fqtn_or_false,
                  callable_name_or_false, role, declaration_kind)
Type.TypeParameter(name, constraint_or_false)
Type.Parameter(scope, index, diagnostic_name,
               erased_interface_application_or_false)
Type.Nominal(fqtn, args)
Type.FunctionScheme(scope, typeparams, signature)
Type.GenericAlias(module, name, locality, target_owner_fqtn,
                  target_alias_fqtn_or_false, target_scope, typeparams)

Type.Record(name, fields, functions, methods, nfields, scope, typeparams)
Type.Union(name, variants, functions, methods, nvariants, scope, typeparams)
Type.Interface(name, methods, scope, typeparams)
Type.Method(fqtn, name, params, rettypes, varargtype, flexrettype,
            paramnames, scope, typeparams)
Type.StaticMethod(fqtn, name, params, rettypes, varargtype, flexrettype,
                  paramnames, scope, typeparams)
```

`GenericScope` is structural and uses logical module/owner/callable names, not
filenames or table identity. `Parameter` identity is `(scope,index)`; its name
is diagnostic. Its erased application is false for the implicit `value`
constraint or the recursively erased ordinary Interface nominal otherwise.
Owner descriptors own owner binders. Method/static descriptors own only local
binders; signatures may reference owner Parameter leaves. Constructors
quantify owner binders; nominal functions quantify owner binders then local
binders; receiver methods fix owner arguments and instantiate only local ones.
Top-level `FunctionScheme` owns its complete list and wraps one ordinary
Function signature. Ordinary first-class types are never schemes.

A `GenericAlias` is a type-namespace descriptor, not a runtime member. Its
optional target alias is a fully qualified name, never a table link; its target
scope/binders are the canonical owner's. Applying it yields the canonical
`Nominal(target,args)`. Bare scalar use applies `value` to every owner parameter
and is legal only when those arguments satisfy the constraints. Local aliases
are omitted from metadata; public aliases serialize this descriptor.

Add the new tags to `tostring`, equality/alpha-equivalence, graph traversal,
substitution, serialization, and the closed validator. Diagnostic names are
serialized but ignored by semantic alpha-equivalence.

### Surface declaration staging

Keep AST order and the parser's existing adjacent synthesized record/union
constructors. The checker:

1. reserves imports, owner headers, scopes, binders, and arities;
2. resolves constraints and aliases;
3. completes records, unions, Interfaces, and their constructor schemes;
4. builds callable/method/static schemes;
5. checks module variables in their existing frontier order;
6. checks bodies with declaration parameters rigid; and
7. constructs and validates the declared module type.

Synthetic constructors have no callable-local binder list. Their field/payload
syntax references owner parameters and their return syntax is the fully applied
owner; the checker alone attaches owner quantification. Direct-source private
access remains direct-only, while serialized interfaces remain public-only.

### Inference and surface checking

Every inferred generic AST use allocates fresh checker-only inference cells,
with occurrence scopes distinct from its declaration and from every other
application of the same declaration. The outermost inferred use owns one
AST-scoped ambient inference context. While its receiver, result, and argument
subtree is checked, nested generic calls, constructors, methods, bound methods,
and contextual first-class uses inherit that context, register child use
records, and equate their distinct cells with outer cells where structural
evidence connects them. An ordinary derived call or constructor registers a
zero-binder operation use before descending whenever it may freeze annotations
computed from an unresolved child type. A complete explicit type-argument list
remains closed locally and contributes its ordinary result as evidence.

Bind complete explicit lists when present. Otherwise gather receiver and
expected-result evidence, then positional or named argument and declared
constraint evidence, including contextual lambda parameter/result types.
Unification is invariant structural evidence over Option, Array, Map, Function,
and same-owner applications. It does not choose numeric conversions, Interface
implementations, or common supertypes. Recursive equations are rejected before
the union/find forest is mutated, so inference remains finite.

Only the owning outer use closes the context. Constraint evidence propagates
across cell-equivalence classes before each still-free class closes to its
declared erased carrier (`value` or its fully substituted Interface
application). Evidence always wins over this fallback. The checker then checks
all constraints and `transient_roundtrip` and finalizes registered uses in
postorder: deepest children before parents and left-to-right among siblings.
Each written expression and contextual lambda body is checked exactly once;
finalization substitutes closed types into already-checked results and refreshes
checker-owned dependent annotations such as ordinary call/method signatures,
Interface receiver plans, constructor field/container types, synthesized fixed
extras, and open-result projections. It never reevaluates or rechecks the
written expression. Parentheses and named-field order therefore cannot change
inference.

Smart substitution uses Titan's canonical constructors: collapse
`Option(value)` and nested Options, de-optionize Array/Map value positions,
reject invalid optional/nil Map keys, and revalidate nominal arity/constraints,
varargs, flexible results, and type-argument eligibility. Apply this equally to
explicit, inferred, bare, imported, and recovered applications. No temporary
occurrence `Parameter` may survive surface closure or reach erasure, metadata,
or code generation. There is no partial list, source-declared default argument,
HM generalization, wildcard, heuristic candidate order, or inference cell in
metadata/codegen.

Rigid body checking exposes only the capabilities in the source contract:
identical-parameter transport/storage, Option operations, same-parameter
container operations and equality, conversion to/from its constraint, written
`as/is`, and methods of an Interface constraint. It does not expose operations
of a future instantiation.

### Constraint erasure

Erasure is a pure recursive Type transformation performed after surface
checking:

```text
erase(T unconstrained) = value
erase(T : I<args>)      = erase(I<args>)
erase(I<args>)          = I<erase(args)>
```

An ordinary bare generic Interface whose own parameters are unconstrained is its
all-`value` application in erased core; constrained owner parameters use their
recursively erased constraints instead. Thus with `IBar<A>` and
`B: IBar<C>` where `C` is unconstrained,
`B` erases to bare `IBar`, exactly `IBar<value>`. Applied nominal arguments are
then dropped from code-facing nominal types because all applications share the
existing owner runtime identity. A `Cell<T>` field becomes the ordinary
code-facing `value` field; a `B:IBar<C>` formal/result becomes ordinary `IBar`;
an `IBar<T>:cons(T):IBar<T>` method becomes ordinary
`IBar:cons(value):IBar`.

Erase recursively through Option, Array, Map, Function, fixed/open results,
varargs, flexible results, fields, payloads, captures, and hidden `for/in`
calls. Smart reconstruction preserves Titan's existing option/container rules.
The result uses existing physical representations: `value` is `TValue`, an
Interface nominal is `Udata *`, and every composite is whatever current
`coder.lua` already emits for that ordinary erased type. In particular, the
code generator does not need a generic carrier algebra or special generic
Option ABI.

### Erasure followed by ordinary cast insertion

After generic-aware checking freezes `ast._declared_type`, perform two bounded
lowering steps over the already checked AST:

1. erase every declaration/expression occurrence to the ordinary monomorphic
   source/target types described above, retaining only a temporary link to the
   checked surface application where boundary direction is needed; then
2. run a focused cast-insertion/adjustment pass over those erased types using
   the same adjustment constructors and AST annotations as today's checker.

This is not a second semantic typecheck and does not repeat inference or body
checking. It sees exactly the types coder sees and exists only to materialize
ordinary erased-boundary conversions. For each generic definition erasure
rewrites signatures, locals, fields/payloads, function tags, and bodies. For
each closed use cast insertion adds:

- a statically accepted closed value is converted/boxed to the erased
  constraint type before the call/store, with no erasure-induced tag check;
- a literal `value` entering an unconstrained position remains raw;
- `value` entering `T:I` uses the existing checked `value -> erase(I)`
  Interface conversion;
- a result flowing to the same erased constraint or `value` is transported;
- a result flowing to a more precise closed type uses the existing strict
  gradual projection before any concrete representation-sensitive use;
- record/union-to-Interface uses the existing Interface wrapper construction;
- Interface-to-record/union uses Titan's existing checked Interface downcast,
  which recovers the original backing value from the wrapper;
- same-owner applied Interface views retain the wrapper and erase to the same
  code-facing Interface nominal; and
- concrete callable components are wrapped to/from erased callable types using
  the existing closure-adjustment machinery, recursively including constrained
  Interface construction/downcast, Options, varargs, and flexible results.

The pass does not ask the ordinary adjustment classifier to rediscover a
relation involving a now-erased rigid Parameter. It retains boundary direction
from the surface pass, then emits ordinary annotations. When current callable
adjustment cannot lift a nested record/Interface conversion, synthesize an
ordinary erased `ExpFunction` wrapper whose body uses Titan's existing
Interface construction/downcast casts; coder sees only that normal lambda and
its existing annotations. The same technique handles constrained callback
vararg/flexible components without a generic coder path. No generic-only plan
reaches coder. Missing or unlowered generic annotations are compiler errors at
the pass boundary.

Cover every sink/source once: positional/named/omitted arguments, constructor
fields, assignments/declarations/returns, field and union payload reads/writes,
Array/Map reads/writes and writers, captures, fixed/extra/open results,
varargs/flexible results, first-class and bound functions, Interface slots,
`for/in` init/next/close components, and Lua/FFI boundaries. Preserve evaluation
order and materialize multiply referenced operands exactly as existing
adjustments do.

This separation also makes the `foldl` behavior direct. Surface inference gives
the lambda `(integer,string)->string`; elaboration uses the existing closure
wrapper to produce `(value,value)->value`; erased `foldl` calls that wrapper;
and the caller's erased result is strictly projected to string.

### Arrays, Maps, Lua, and FFI

An unconstrained generic Array erases to `{value}` and therefore uses the
existing permissive value writer. A constrained `{T:I}` erases to `{I}` and
uses the existing Interface writer. Generic Maps and all closed projections use
the ordinary erased container behavior and existing strict read plans. Dynamic
writes into unconstrained storage may pollute a later precise view; constrained
writes must first become the erased Interface. No new writer kind is needed.

Lua sees the erased declaration: unconstrained positions are value; constrained
positions are the erased Interface; known outer shapes retain current checks.
Errors on unconstrained dependent writes remain delayed until a precise
projection. Applied nominal `as/is` remains a shallow owner test.

An FFI type is eligible as a type argument exactly when existing Titan has
sound implicit conversions both to and from `value`, including all necessary
range/tag/lifetime checks. Apply eligibility to explicit and inferred bindings
and recursively through compound arguments. Ineligible C pointers, aggregates,
arrays, functions, and function pointers are compile-time errors; generics add
no conversion to make them eligible. Raw C `TValue` uses its existing structural
whole-slot conversion. Foreign functions cannot declare type parameters.

### Metadata and ABI 0.24

Serialize `ast._declared_type`, not erased `ast._type` or expression types. ABI 0.24
extends metadata with scopes, binders, Parameter references, applied nominal
arguments, schemes, generic owners/methods, and forwarding aliases. There is no
runtime type argument, specialization, witness, or provenance schema.

Keep current closed metadata validation proportional to existing trust
boundaries. Validate constructor shape, local binder closure, dense indexes,
arity, constraints, public visibility, and canonical member projections. During
ordinary referenced-nominal recovery, load external generic owners/alias targets
before reconciling their arity and constraints; do not add speculative hardening
or a second registry architecture. DSO and archive metadata remain identical,
and ABI 0.24 rejects 0.23 before decoding.

Advance all current ABI paths/constants/stamps/scripts/fixtures together,
preserve prior 0.23 state, and add no migration or cleanup machinery.

## Standard-library dogfood

### `titan.iteration`

Hard-rename source logical module `titan.iter` to `titan.iteration`. It remains
qualified-only (`import "titan.iteration"`); add no parser shorthand and no
`titan.iter` compatibility root. Rename its native test owner and both manual
chapters. Update all authoritative source/root/shim/key lists, installer and
snapshot manifests, metadata fixtures, build/smoke tests, README/quick tour,
style/agent guidance, and generated-shim ignore entries. The provider remains
18 logical modules and 19 Lua openers.

A fresh 0.24 prefix is required. An old unversioned `titan/iter.lua` in an
in-place prefix is prior-version state and is not removed by cross-ABI cleanup.

Use these exact types:

```titan
function next<K, V>(map: {K: V}, key: K?): (K?, V?)

function pairs<K, V>(map: {K: V}):
    (({K: V}, K?) -> (K?, V?), {K: V}, nil, nil)

local function array_next<T>(array: {T}, index: integer):
    (integer?, T?)

function ipairs<T>(array: {T}):
    (({T}, integer) -> (integer?, T?), {T}, integer, nil)
```

Map-key binding must still satisfy the ordinary Map key restrictions. Preserve
false keys, Array holes, trailing deletion, and nil termination. Raw C `TValue`
already has sound implicit conversions to and from `value`, so it passes
`transient_roundtrip`. Once K/V erase to `value`, the ordinary second adjustment
pass selects today's existing whole-slot `value <-> C TValue` operations around
`lua_pushtvalue`/`lua_totvalue`; no generic plan or API whitelist is needed.
Remove the old source `value` casts/erasures rather than wrapping them.

### `titan.gc.finalizable`

Preserve public parameter names for named-call compatibility:

```titan
function finalizable<T>(v: T, f: (T) -> ()): ()
```

Keep the current runtime collectability check and exact Lua-stack/metatable
ledger. After T erases to value, use the same existing whole-slot
`value <-> C TValue` adjustments; add no generic plan or API whitelist. A scalar
instantiation still typechecks and raises
the established runtime error. Change the SSL default-client-context finalizer
callback to its exact local record type and remove its `value as Record` cast.
Preserve the shared-metatable warning: generic typing improves the call boundary
but does not create per-value Lua finalizers.


### Generic async Tasks

Keep nominal ownership in `titan.uv`; `titan.async` exports constructor-
preserving aliases:

```titan
type CancellationReason = uv.CancellationReason
type TaskStatus = uv.TaskStatus
type Task = uv.Task
```

The owners and methods are:

```titan
union CancellationReason<B>
  simple: string
  complex: B
end

union TaskStatus<A, B>
  ready
  running
  waiting
  succeeded: A
  failed: Error
  cancelled: CancellationReason<B>
end

record Task<A, B>
  local root: coroutine.Coro
  local runtime: Runtime
  local state: TaskStatus<A, B>
  local cancel_value: CancellationReason<B>?
  local cancel_action: CancelAction?
  local pending: value
  local root_index: integer
  local cleanup: boolean
  local terminal_registrations: {TerminalRegistration<A, B>}
  local suspended: boolean
  local resume_pending: boolean
  local pending_cancellation_affected: boolean
end

local record TerminalRegistration<A, B>
  local listener: (TaskStatus<A, B>) -> ()
  local live: boolean
end

function TaskStatus:as_string(): string
function TaskStatus:has_finished(): boolean
function TaskStatus:has_succeeded(): (boolean, A?)
function TaskStatus:has_failed(): (boolean, Error?)
function TaskStatus:has_cancelled():
    (boolean, CancellationReason<B>?)
function Task:cancel(reason: CancellationReason<B>?)
function Task:status(): TaskStatus<A, B>
function Task:add_terminal_listener(
    listener: (TaskStatus<A, B>) -> ()): () -> ()
function Task:resume()

function run<A, B>(func: () -> A): Task<A, B>
function running(): Task -- exactly Task<value,value>
```

The Runtime remains concretely all-value: `task_roots: {Task}` is
`{Task<value,value>}`, `current_task: Task?` is its option, every libuv waiter/
request/callback owner uses bare Task, and `running_task()` truthfully returns
that type. Public `Task<A,B>` is a shallow same-userdata view. Runtime creation
uses explicit `Task<value,value>.new` to state this storage invariant, although
the final carrier rule would select the same application without evidence. No
existential, wildcard, private TaskCore, variance, or ambient
application recovery is needed.

`B` in `run<A,B>` is result-only. Result context binds it when available;
otherwise the final carrier rule closes it to `value`. A complete explicit list,
e.g. `run<Request?,value>(func)`, remains valid, but partial lists do not. A
zero-result callback supplies no evidence for `A`, so it likewise closes to its
carrier unless context or a complete list selects another application.
`running()` is deliberately monomorphic, not `running<A,B>`.

Keep source-private `uv.run_internal` monomorphic:

```titan
local function run_internal(func: () -> value): Task<value,value>
```

Public `async.run<A,B>` wraps `func:()->A` to the real erased `()->value`
callback, calls `run_internal`, and returns a shallow `Task<A,B>` view of that
same userdata. The coroutine publishes its raw returned value into
`TaskStatus<value,value>.succeeded`; no `A` check occurs there. A later
`Task<A,B>` success projection supplies the strict `A` guard. Runtime complex
cancellation similarly stores a raw `value` in
`CancellationReason<value>.complex`; only a `B` projection guards. Runtime,
coroutine, pending operation, cancellation action, roots, libuv callbacks, and
all operational helper signatures remain intentionally monomorphic/all-value.
Only status/reason/listener projections and the public combinator layer are
generic; remove the vague instruction to genericize other helpers.

Use per-operand interleaved parameters for the expanded combinators. For each
operand `i`, let `T_i = Task<A_i,B_i>` and `S_i = TaskStatus<A_i,B_i>`:

```titan
function join<A,B>(task: Task<A,B>): TaskStatus<A,B>
function join_two<A1,B1,A2,B2>(first: T_1, second: T_2): (S_1,S_2)
function any_two<A1,B1,A2,B2>(first: T_1, second: T_2):
    AnyTwoResult<A1,A2>
function race_two<A1,B1,A2,B2>(first: T_1, second: T_2):
    RaceTwoResult<A1,B1,A2,B2>
function all_two<A1,B1,A2,B2>(first: T_1, second: T_2): (A1,A2)
```

Extend the same pattern through arity five. `AnyNResult` has only the `A_i`
parameters and one payload arm per operand plus `none`. `RaceNResult` and
`AllNError` have interleaved `(A_i,B_i)` and one `TaskStatus<A_i,B_i>` arm per
operand. Result context or complete explicit lists preserve a precise
payload-free/result-incomplete application; without evidence, a bare
`raise AllNError.first(...)` carrier-closes its remaining binders because
`raise` expects only `value`. Keep the named, expanded,
listener-based algorithms and never collect operands into `{Task}`.

All success and complex-cancellation payloads are erased Runtime carriers.
Case payloads, `has_succeeded`, `has_cancelled`, `AnyNResult` payloads, and
`all_*` direct results receive normal strict guards when concretely unboxed.
Returning/storing an opaque Task or status, owner/tag inspection, `as_string`,
`has_finished`, equality, resume, and scheduler inventory need no A/B check.

Migrate terminal listener registration away from callback identity:
`add_terminal_listener` allocates one fresh `TerminalRegistration<A,B>` per call,
stores the exact adjusted listener in it, appends that record to
`terminal_registrations`, and returns a no-argument remover closure capturing the
record and Task. If the Task is already terminal, it returns an idempotent no-op
remover without appending. A live remover flips `registration.live` and removes
that exact record if it remains in the live Array; later/repeated calls are no-
ops. Callers invoke the remover in `defer`, never pass the source listener to a
separate remove method. Duplicate registrations therefore remain distinct
without comparing original or adjusted closure identity.
Terminal publication detaches the dense live registration Array as its stable
snapshot, installs an empty live Array, and marks/removes ownership so later
removers are no-ops; delivery invokes every snapshot listener in order without
consulting mutable `live` again. Thus a remover called during delivery cannot
mutate or skip that snapshot. Preserve registration
order, cancellation-defer cleanup, duplicate registration, and per-listener
error isolation. The remover and captured registration are ordinary GC-traced
closures/state, not generic witnesses or global wrapper interning.

Migrate the 2–5 arity APIs and the native async/uv suites rather than replacing
them. Make the HTTP idle-timeout reader/deadline `race_two` path production
dogfood for heterogeneous Task results. Bare Task helpers intentionally retain
the current all-value API; genericize selected helpers to prove precise paths.

## Tests

### Pure frontend/type tests

Add focused parser and lexer coverage for every eligible/ineligible binder,
constraints, nested applications/closers, option precedence, direct/qualified
names, inferred/explicit positional/named/method/constructor calls, ambiguity
priority, source-faithful owner ASTs, list limits, and every new failure label.
Keep `>>`, `>=`, and ordinary comparisons unchanged. Assert new AST fields
explicitly because parser subset assertions otherwise hide omissions.

In `spec/types_spec.lua`, cover:

- rigid scope/index identity and alpha-renaming;
- applied nominal invariant equality and erased owner identity;
- smart substitution through every structural type, scheme, constraint, and
  method, including canonical `value`/nested Option collapse, Array/Map value
  de-optionization, invalid optional/nil Map keys, and post-binding vararg/flex
  shape rejection for explicit, inferred, bare, and recovered applications;
- occurs checks/inference helpers if type-owned;
- rigid representation/capability/relation truth tables and the exact positive/
  negative `transient_roundtrip` frontier, including C numbers, owned values,
  raw C TValue carrier eligibility through existing bidirectional implicit
  value conversion, rejected C aggregates/arrays/functions/function pointers/
  raw pointers under both explicit and inferred instantiation, and each
  forbidden shape recursively hidden
  in Option/container/callable/phantom generic arguments;
- erasure/cast-elaboration completeness and no-generic-core assertions; and
- deterministic serialization round trips.

### Checker suite

Create `spec/checker/generics_spec.lua` and focused additions to declaration
order, visibility, Interfaces, closures, named arguments, variadics, flexible
returns, `for/in`, aliases, and recovered-interface specs. Cover:

- generic records/unions/Interfaces, recursive headers, fields/payloads/cases,
  constructors, statics, methods, and exact `self`;
- top-level calls, explicit full lists, result-context inference, nested calls,
  conflicts, carrier-closed phantom/result-only parameters, constraints, and
  repeat-use isolation;
- the draft `Stack` and `foldl` examples;
- contextual lambdas checked once, first-class declarations, bound methods,
  and no let/lambda polymorphism;
- rigid allowed/rejected operations and value/option/container edges, including
  raw forward `value` argument/constructor/assignment sinks for unconstrained
  binders, mandatory `value -> erase(I)` conversion for `T:I` sinks, no check for an
  unconstrained result consumed as `value`, direct constrained results consumed
  as `I`, and strict reverse timing for more precise concrete consumers;
- positional/named omission/surplus, varargs, fixed/open/flexible results, and
  hidden `for/in` calls;
- generic Interface implementation alpha-equivalence and deterministic
  missing/inaccessible/incompatible failures;
- direct-source local generics versus public-only binary denial;
- public export closure and generic `main`/foreign rejection; and
- AST assertions that the declared module type remains generic while the erased
  code-facing AST contains no Parameter/scheme/application/cell, every precise
  projection carries its existing strict plan, and erased transport does not.

### Coder/runtime suite

Create `spec/coder/generics_spec.lua` as runtime evidence for the erased core;
these tests also assert generated C contains only ordinary erased signatures and
that equivalent nongeneric erased fixtures produce the same layouts/entry
shapes. Cover:

- unboxed concrete locals around erased scalar identity/fold calls, proving no
  guard on the typed argument/constructor/write direction; bad literal-`value`
  arguments, constructors, and writes at unconstrained binders commit raw and
  fail only on concrete elimination, while constrained binders cast to their
  Interface immediately; an unconstrained result assigned to `value` and a
  constrained result assigned to its Interface do not check; and
  `id<integer>(1)`'s result receives the mandatory reverse strict guard;
- numeric, string, boolean, option, Array, Map, record, union, Interface,
  function, C-number, owned C value, and raw C TValue carrier arguments, plus
  rejected direct/nested C struct, union, array, function, function-pointer, and
  raw-pointer arguments;
- record fields, union payloads/cases, constructors, methods, nominal functions,
  recursive generic calls, constrained dispatch, and Interface adapters,
  asserting generated native signatures use `TValue`/value descriptors for
  unconstrained binders and the exact recursively erased Interface `Udata *`/
  nominal descriptors for constrained binders, including a constraint whose
  applied arguments mention outer rigid parameters;
- concrete/erased first-class and bound-method wrappers, captures, mutation,
  GC cycles/barriers, strict non-exact calls, genuine Lua calls, and identity;
- omitted/surplus/named args, generic input varargs, multiple/flexible results,
  catch/finally/defer, and generic iterators;
- two instantiations of one declaration in one module and across source, DSO,
  static archive, prefix container, and Lua shim boundaries;
- erased nominal runtime identity with invariant static rejection and strict
  field/read projections; and
- line attribution plus no duplicate operand evaluation.

Extend hostile compiled-schema, DSO rehydration, static provider, and
multi-module tests for binders/applications/schemes and malformed scope,
constraint, arity, free-reference, alpha-order, smart-substitution, and
GenericAlias data. Add ABI/generated-C assertions that every erased signature
uses exactly today's ordinary representation for its erased source type:
unconstrained leaves use `value`/`TValue`, constrained leaves use their erased
Interface/`Udata *`, and Option, vararg, and flex forms use the existing ordinary
descriptor rules for those erased types. Then update exact stdlib metadata
fixtures from a validated generated 0.24 provider.

### Standard-library behavior

Move the native iteration suite to `iteration.tests`; retain existing tuple,
false-key, hole, trailing-delete, and invalid-control behavior and add inferred
concrete Map/Array types, direct option results, explicit applications,
first-class contextual instantiation, and polluted-container projection errors.
Keep the Lua provider smoke.

Extend `gc.tests` with exact record and Map callbacks, checker rejection of a
mismatched callback, scalar runtime rejection with stack balance, shared
metatable replacement behavior, and Lua erased invocation. Keep the SSL owner
lifetime test.

Migrate the existing async/uv native suites to generic owners and add
heterogeneous result/cancellation types at every combinator arity, bare
`running()` same-identity behavior, all-value Runtime coexistence, delayed
polluted success/complex projection failures, terminal-listener remover
closures (idempotence, duplicate registration, cancellation cleanup, and
removal during detached delivery), zero/nil-result Tasks, Lua-erased Tasks, and the existing
HTTP timeout ownership asymmetry. Regenerate exact `titan.uv`/`titan.async`
provider fixtures from the validated 0.24 image.

## Documentation

Create and link:

- `doc/language/generics.md`: normative syntax, scopes, constraints, inference,
  explicit arguments, aliases, rigid operations, static/runtime identity, Lua
  erasure, diagnostics, and v1 exclusions;
- `doc/implementation/generics.md`: AST/elaboration, type model, solver,
  staging, erased-core cast elaboration, unchanged codegen layouts, GC, Interface
  adapters, metadata validator,
  and ABI 0.24.

Update the grammar, types, functions, records, unions, Interfaces, aliases,
expressions, closures, foreign-functions, modules/providers, Lua interop,
version history, and both indexes. Remove generics from roadmap/limitations.
Update `AGENTS.md` in the same change for ABI 0.24 paths/constants, the
`titan.iteration` root, all new Type tags/dispatch duties, retained parse-time
constructor desugaring, constraint-directed rigid erasure ABI, all-value Task
Runtime, and
remover-returning listener contract.
Update iteration and GC user/implementation chapters and all renamed examples.
Update async-io, libuv-runtime, and the libuv extension guide with the exact
Task/status/reason/combinator schemes, concrete all-value Runtime,
complete-list/final-carrier `run` rule, shallow Task views, delayed payload guards, and remover-returning
listener registration. Explain that adjusted function wrappers have fresh
identity and generics do not promise identity-preserving casts.
Remove future-generic-Task wording. Do not document the deferred iterator
Interface family as shipped.

Docs are reviewed alongside the code at each phase, not appended after tests.

## Implementation phases and review gates

1. **Frontend/type algebra:** AST/grammar/elaboration, binders, applied
   nominals, schemes, substitution, equality, serialization primitives, and
   pure tests. Run Lua syntax checks and pure specs.
2. **Checker declarations:** type scopes, owner headers, generic aggregates,
   aliases, shared signature builder, applied member views, rigid-body rules,
   and checker tests using explicit types.
3. **Inference:** fresh cells, result/argument/lambda scheduling, calls,
   constructors, methods/statics, first-class uses, and vararg/flex/for-in.
   Review diagnostics and isolation.
4. **Erased core:** freeze declared metadata, erase the checked AST, insert
   existing concrete casts/callable and Interface adjustments, assert the core
   invariant, and run coder/runtime tests. Change coder only to serialize the
   frozen declared module type and reject
   leaked generic forms.
5. **Separate compilation/ABI:** closed validator, DSO/archive/container tests,
   0.24 sweep, and publication fixtures.
6. **Dogfood/docs:** iteration hard rename/generic APIs, generic finalizable,
   SSL cleanup, generic uv/async owners and fixed-arity combinators with an
   all-value Runtime, both manuals, API chapters, and standard-library tests.
7. **Review:** independent code, type-soundness, native ABI/GC, metadata,
   standard-library, and documentation audits; address every finding.
8. **Validation/publication:** fresh isolated prefix, focused groups, full mixed
   suite, push branch, open PR, monitor all Linux jobs, and fix until green.
   The maintainer has explicitly waived the otherwise-required manual macOS
   pre-merge dispatch for this generics-v1 task.

After compiler-source edits, reinstall the rock before Busted so tests do not
load a stale snapshot. Use an isolated absolute 0.24 prefix with no ambient
`ROCKS_TREE`, `TITAN_ROCKS_ROOT`, `TITAN_EXTRA_CPPFLAGS`, or
`TITAN_NO_LINE_DIRECTIVES` for canonical validation.

## Acceptance criteria

The work is complete only when:

- the draft and this implementation specification remain separate commits;
- every included syntax/semantic/ABI rule above has positive and negative
  coverage at the owning layer;
- coder receives only the ordinary erased monomorphic AST and existing concrete
  plans, with no Parameter, scheme, applied argument, or inference cell; the
  separate frozen declared module type alone retains generic metadata;
- every statically typed closed-to-erased argument/constructor/write boxes
  without a gradual guard, while every erased-to-closed elimination, including
  `id<integer>(1)`'s result, consumes its strict guard; no provenance/check-
  elision machinery exists;
- every unconstrained rigid leaf erases to `value`/`TValue`, every constrained
  leaf to its exact erased Interface/`Udata *`, and no other carrier is selected;
  every type argument—including explicit or inferred FFI arguments—satisfies the
  exact existing-implicit-`value`-round-trip rule; smart substitution
  revalidates canonical Option/container/vararg/flex shapes; and forbidden C
  pointer/aggregate/function shapes are rejected recursively;
- bare generic-owner scalar uses are exact all-`value` applications while
  constructor-forwarding aliases retain arity across every provider format;
- generic Task listener registration returns an idempotent remover closure and
  requires no adjusted-wrapper identity preservation, while the Runtime remains
  concretely `Task<value,value>`;
- coder layout/upvalue/uservalue generation remains generic-unaware and generic
  declared types appear only in serialized metadata;
- source, DSO, archive, prefix-container, Lua, first-class, Interface, GC,
  vararg/flexible-result, async, and other standard-library paths agree;
- both new manuals and all affected API/version chapters are current;
- a fresh isolated `make test` (or the repository-equivalent complete mixed
  suite) passes;
- the branch is pushed, a PR is open, and every required Linux CI job is green
  (the manual macOS pre-merge job is explicitly waived for this task); and
- the persistent goal is marked complete only after auditing these criteria
  against the final PR head.
