# Generics

Titan supports explicit, invariant **parametric polymorphism** on nominal types
and named callables. A generic declaration is checked once with rigid type
parameters and compiled as one body whose parameter-dependent values use their
constraint carriers. Calls and constructors infer a fresh, complete set of type
arguments locally, or the caller can write the complete set explicitly.

```titan
record Pair<T, U>
    first: T
    second: U
end

function id<T>(x: T): T
    return x
end

function example(): integer
    local pair = Pair.new(1, "one")      -- Pair<integer, string>
    local n = id<integer>(pair.first)     -- integer
    return n
end
```

There is no monomorphization and no run-time type-argument object. For example,
calls to `id<integer>(...)` and `id<string>(...)` use the same erased native body. Titan preserves
their different static types by inserting ordinary boxing, Interface adapters,
callable wrappers, and strict projections at the closed use site.

This chapter specifies declaration and application syntax, local inference,
what a rigid parameter permits, the constraint-erased run-time contract, type-
argument eligibility, and the generic Task API. The ordinary rules for
[types](types.md), [functions](functions.md), [records](records.md),
[unions](unions.md), [Interfaces](interfaces.md), and the
[Lua boundary](lua-interop.md) still apply unless this chapter says otherwise.
The erased compiler pipeline is documented in
[Generics implementation](../implementation/generics.md).

## Declaring type parameters

A nonempty type-parameter list follows the declared name. Each parameter is
unconstrained or names an applied Interface constraint:

```text
type-parameters = "<" type-parameter { "," type-parameter } ">"
type-parameter  = Name [ ":" Interface-application ]
```

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
    function push<R: Stack<E>>(item: E): R
end

function foldl<T, U>(
    values: {T},
    combine: (T, U) -> U,
    initial: U
): U
    local accumulator = initial
    for i = 1, #values do
        accumulator = combine(values[i], accumulator)
    end
    return accumulator
end
```

Type parameters may be declared by:

- records, unions, and Interfaces;
- top-level functions, including `local` functions;
- record and union methods;
- record and union nominal functions declared with `Owner.name`; and
- Interface methods.

A declaration list is dense and source ordered. It has no trailing comma and is
limited to 100 parameters, like Titan's other guarded source lists. All names in
one list are reserved before its constraints are resolved, so a constraint may
refer to an earlier or later parameter in that list. The checker still rejects
duplicate names, cycles, non-Interface constraints, and unsatisfiable
constraints.

Type aliases, anonymous functions, and `foreign function` declarations cannot
introduce parameters. A lambda inside a generic body may use the surrounding
parameters, but cannot add its own. A generic function named `main` is an
ordinary library function; it does not have the exact monomorphic signature
required of a [standalone entry point](functions.md#standalone-programs-main).

### Owner and callable scopes

An owner's parameters are in scope throughout its fields or variants and in
all of its method and nominal-function signatures and bodies. A method or
nominal function can add a separate callable-local list:

```titan
record Pair<T, U>
    first: T
    second: U
end

function Pair:map<V>(f: (T) -> V): Pair<V, U>
    return Pair.new(f(self.first), self.second)
end

function Pair.replace_first<V>(
    pair: Pair<T, U>,
    item: V
): Pair<V, U>
    return Pair.new(item, pair.second)
end
```

The owner name in a definition remains bare: write `function Pair:map<V>`, not
`function Pair<T,U>:map<V>`. The implicit `self` in `Pair:map` has type
`Pair<T,U>`. A callable-local parameter may not reuse an active owner-parameter
name; Titan rejects shadowing instead of making the two parameters ambiguous.

Owner and callable parameters have distinct identities even when their source
names happen to match in unrelated declarations. Renaming all occurrences of a
binder does not change a declaration's type.

### Interface constraints, not bounds

A constraint is written after `:` and must resolve to a visible Interface
application:

```titan
interface Container<E>
    function get(): E
end

function read<T, C: Container<T>>(container: C): T
    return container:get()
end
```

Titan has no general subtyping relation, so the word *constraint* does not mean
a subtype bound. A closed argument for `C` must be:

- that exact applied Interface;
- a visible record or union application that structurally satisfies it; or
- another rigid parameter with the same applied Interface constraint.

Distinct Interface constraints do not entail one another structurally. Within
the body, a value of type `C` exposes exactly the methods declared by
`Container<T>`—not fields, statics, or extra methods of a later concrete
implementation. Where a concrete record or union is accepted, Titan uses the
ordinary [Interface wrapper conversion](interfaces.md#structural-satisfaction-at-the-coercion-site).

Generic Interface methods are matched under their binders, not by erasing the
signature first. An implementing method must have the same callable-local
binder arity; after alpha-renaming, corresponding constraints must be
alpha-equivalent, and the substituted method signatures must satisfy Titan's
existing directional callable-compatibility rules under those rigid binders.
Parameter names do not matter. A missing, inaccessible, differently constrained,
or otherwise incompatible generic method does not satisfy the Interface.

An unconstrained parameter is implicitly constrained by the language's
canonical `value` carrier, but the parameter is **not** the `value` type while
its body is checked. The distinction determines which operations generic code
may perform.

## Applying generic types

A complete argument list can follow a direct or qualified named type:

```titan
Pair<integer, string>
api.Result<{string}, api.Error>
Pair<T, U>?
{Pair<T, U>}
```

The application binds more tightly than `?`, so `Pair<T,U>?` is an option of an
applied `Pair`, not an application whose final argument is optional. Nested
applications close one `>` at a time: `Outer<Inner<T>>` needs no separating
space.

Only a named record, union, Interface, or constructor-preserving alias is
applicable. The list must have exactly the owner's arity and every argument must
satisfy its constraint and the [erasure eligibility rule](#eligible-type-arguments).
Applying a parameter or another arbitrary type shape would require
higher-kinded polymorphism and is rejected.

Applied nominal types are invariant: applications are equal only when all
arguments are equal. Ordinary numeric conversions and Interface satisfaction do
not lift through an application. The separate shallow gradual relation to a
constraint-erased view is described under
[shared run-time identity](#static-applications-and-shared-run-time-identity).

### Bare owners mean an all-`value` application

In an ordinary scalar type position, a generic owner without arguments means
that every argument is literally `value`:

```titan
local p: Pair = Pair<value, value>.new(1, "one")
-- Pair above means Pair<value, value>.
```

It is not a wildcard, existential, partially applied constructor, or unknown
application. The bare spelling is valid only if `value` satisfies every owner
constraint. Consequently an owner such as `Constrained<T: Show>` normally
requires an explicit argument because `value` does not implement `Show`.

This all-`value` rule applies to ordinary scalar uses, including fields,
parameters, results, and the `Task` returned by `async.running()`. Constructor
and nominal-static selection is a different *owner-scheme context*: `Pair.new`
retains the owner parameters through call and expected-function evidence, then
closes any remaining binders to their declared carriers.

### Constructor-preserving aliases

An alias cannot declare its own parameters, but an alias whose exact right-hand
side is a bare generic owner forwards that owner's constructor, arity,
constraints, and nominal namespace:

```titan
type Either = Pair
local type IntPair = Pair<integer, integer>

local e = Either<string, integer>.new("ok", 200)
local p = IntPair.new(1, 2)
```

`Either<A,B>` is exactly `Pair<A,B>` and creates no new run-time identity. Bare
`Either` means `Either<value,value>`. `IntPair` is already concrete and has no
arity. Alias chains preserve the same rule, subject to ordinary visibility and
cycle checks. Public forwarding aliases are available through compiled module
interfaces; local aliases remain source-private.

## Instantiating calls and constructors

Each generic use gets fresh inference cells. A cell is selected by the first
real evidence that reaches it in Titan's checking order; later terms do not
compete to select a different argument. One use never changes the declaration
or another use.

The precedence for an inferred call is:

1. an explicit complete type-argument list;
2. owner arguments fixed by the already checked receiver;
3. available expected-result slots, from left to right; and
4. evaluated arguments in language order.

Expected-result context is static: using it before evaluated arguments does not
change run-time evaluation. For example, `local x: float = id(1)` selects
`T = float` and checks the integer argument against `float`; the call elaborates
like `id<float>(1)`. A receiver-selected owner remains earlier: if `box` is a
`Box<integer>`, an expected `float` result from `box:get()` adjusts the integer
result rather than changing the receiver's owner argument.

Evaluated evidence is consumed exactly in source order: positional arguments
left to right; named arguments in the order written (not formal order); each
fixed result of a final multi-result expression left to right, then its open
tail; and omitted arguments only after written arguments. Constructors consume
positional values left to right, each computed Map key before its value, and
record fields in written order.

A generic `for ... in` use follows the same rule for its four-value iterator
tuple. After the iterator is selected, written state/control producers are
consumed in source and delivered-result order; projections synthesized from a
final `...` and missing nil fills follow without replaying that producer. A
contextual close callback participates at its written tuple slot. Only after
those hidden inputs have supplied evidence do annotated loop variables supply
iterator-result evidence. For example, the nil-fillable projections of `...`
below select `T = integer` through the iterator's optional state/control inputs
before the unannotated result is closed; the loop's first control value is then
ordinarily forced to `integer`:

```titan
function step<T>(state: T?, control: T?): T? return nil end
function consume(...: integer)
    for item in step, ... do
        -- item is the forced integer control value
    end
end
```

```titan
function same<T>(left: T, right: T): T return left end

local i = same(1, 2.5)  -- T is integer; argument 2 converts float -> integer
local f = same(1.0, 2)  -- T is float; argument 2 converts integer -> float
```

Once the first argument has selected `T`, the second is checked by Titan's
ordinary directional assignment rules. It may therefore receive a numeric,
Option, gradual, callable, or Interface adjustment. An incompatible later term
reports the ordinary error at that term; inference does not search for a common
type and does not report later evidence as a competing inference candidate.

This component adjustment applies while a constructor is building a value. It
does not make an independently built generic application variant: after an
existing `{integer}` selects `{T}`, a later existing `{float}` is an ordinary
container mismatch rather than an element-wise conversion.

Some producers have no independent type until their sink is known. An untyped
lambda, a contextual call through `value`, an ownerless named record
initializer, or a constructor whose component syntax itself needs context
remains pending. It is checked exactly once when later evidence or final
fallback closes its context; its written position and run-time evaluation do
not move. “Call through `value`” is determined from the statically checked
callee, so it includes record/module fields, indexed values, and other computed
callees rather than only a bare local name. A generic first-class function or
method is different: at its written position it registers a fresh open callable
equation immediately. Later
evidence may close that occurrence's local cells, but the value is not replayed
or moved behind its siblings. Thus:

```titan
function agree<T>(left: T, right: T): T return left end

function from_dynamic(callback: value): integer
    return agree(callback(), 42)
end
```

`callback()` cannot synthesize its result type, so the later `42` selects
`integer` and the earlier call is finished as `() -> integer`. This is not an
order-independence rule for an already typed `value`: `agree(v, 42)` selects
`value`, while `agree(42, v)` selects `integer` and checks `v` at that boundary.

Brace syntax follows the same distinction. `{}` has no component evidence and
may take a later Array, integer-keyed Map, or record context; without one it uses
the ordinary `{integer}` default before generic carrier fallback. A nonempty
positional constructor whose first usable component is independently typed
selects Array at that source position. It remains shape-pending only while all
of its potentially selecting components still require context.
Computed syntax selects Map shape immediately, while named syntax still needs a
nominal record owner. Nested defaults settle inside-out: in `id({{}})`, the
inner empty syntax first defaults to `{integer}`, and that completed component
selects the outer `{{integer}}`; a nonempty parent never invents the empty
constructor's integer-element default for itself. The same postorder rule
applies to computed Map keys and values. A context-only record constructor
builds the selected record base and then takes any ordinary outer Option wrap
or force.

Inference equations remain invariant structural equations over corresponding
parts of Options, Arrays, Maps, function shapes, and applications of the same
owner. They connect still-open cells, including cells owned by nested uses, and
are subject to an occurs check. They do not:

- search for a common supertype;
- choose a conversion as evidence;
- use structural Interface satisfaction as unification (a selected argument's
  constraint is checked normally);
- generalize a local binding in Hindley–Milner style; or
- leave a wildcard or unresolved parameter in the result.

After ordered evidence and ordinary constructor defaults are exhausted, a
still-free equivalence class closes to its declared erased carrier: `value` for
an unconstrained parameter, or the recursively closed Interface application for
a constrained parameter. A pending producer is then finished once under that
closed target. This lets empty variants, phantom parameters, and result-only
parameters remain ordinary closed calls without introducing a wildcard or a
run-time type argument.

After every parameter closes, Titan reconstructs the application with its
ordinary canonical type constructors. `value?` and nested Options collapse to
their canonical form; Array elements and Map values are de-optionized according
to their existing nil-as-absence rules. A binding that reconstructs a nil or
optional Map key, an invalid variadic/flexible shape, a bad owner arity, or an
unsatisfied constraint is rejected. This revalidation applies equally to
explicit, inferred, bare all-`value`, imported, and recovered applications; it
is not an inference default or a way around ordinary container rules.

### Explicit type arguments

A call may instead supply the complete unresolved list:

```titan
foldl<integer, string>(numbers, combine, "")
Pair<integer, string>.new(1, "one")
stack:push<MyStack>(item)
make<integer>{ item = 1 }       -- named-call syntax is also supported
```

There is no partial explicit list. The order is:

- a top-level function's callable parameters;
- for a receiver method, only its callable-local parameters (the receiver has
  already fixed the owner arguments); and
- for a constructor or nominal function, the complete owner list is attached to
  the nominal namespace, while any complete callable-local list remains after
  the member name: `Pair<T,U>.new(...)` and `Pair<T,U>.from<V>(...)`.

Constructors synthesized for records and union variants have only the owner's
parameters. The old member-attached spelling `Pair.new<T,U>(...)` is rejected.
When a nominal function has both owner and callable-local binders, write both
lists or neither; `Pair<T,U>.from(...)` and `Pair.from<V>(...)` do not request
partial inference. A concrete alias such as `IntPair` has already fixed its
owner arguments, so only a nominal function's callable-local list can remain.

Generic-call suffixes use the same positional, named, and method-call argument
forms as ordinary calls. Whitespace is insignificant, so `f<T>(x)` and
`f < T > (x)` are the same call. The parser treats an angle list as type
arguments only when a complete list is followed by a call delimiter. Thus
`a < b > c` remains two comparisons, while `a < b > (c)` is a generic call;
write `(a < b) > (c)` to force the comparison in that ambiguous shape. `>>`
and `>=` retain their ordinary operator meanings.

### Generic declarations as function values

A generic declaration is not itself a polymorphic first-class value. A complete
expected monomorphic function type can instantiate it:

```titan
function use_function_values(): integer
    local int_id: (integer) -> integer = id
    local constructor: (integer, string) -> Pair<integer, string> = Pair.new
    local pair = constructor(1, "one")
    return int_id(pair.first)
end
```

Without an expected function type, `local f = id` closes `T` to its declared
erased carrier and therefore gives `f` the ordinary type `(value) -> value`.
Version one has no written specialization form that produces a value without a
call: `Pair<integer>.new` is rejected, while the bare `Pair.new` can still be
instantiated by context or by the final carrier rule. The instantiated value may
be an ordinary adjustment wrapper, and wrappers are
fresh values: generic instantiation does not promise that function identity is
preserved across adjusted views. See
[closure adjustment wrappers](closure-adjustment-wrappers.md).

## Checking a generic body

A declaration's parameters are **rigid** while its body is checked. They cannot
be bound to the types of expressions encountered in the body; only fresh use-
site inference variables can be bound. This prevents a body from being accepted
because one convenient future instantiation happens to support an operation.

### Unconstrained parameters

For one rigid unconstrained parameter `T`, the body permits:

- assignment, argument passing, return, and storage where the other type is the
  identical `T`;
- ordinary wrapping in and forcing from `T?`;
- Array elements and Map keys or values containing that same `T`;
- equality and inequality with the same parameter, and with option, nil, or
  `value` where the ordinary comparison rules admit it;
- automatic conversion between `T` and `value`; and
- written `as` and `is`, treating the operand through its erased carrier.

For example, identity, uniform equality, and storage are valid:

```titan
function same<T>(left: T, right: T): boolean
    return left == right
end

function append<T>(items: {T}, item: T)
    items[#items + 1] = item
end
```

`T` does not acquire arithmetic, ordering, concatenation, length, indexing,
calling, fields, methods, or direct use as a condition merely because Titan
values have Lua truthiness. Use a suitable constraint or written cast when one
of those operations is intended. Distinct parameters such as `T` and `U` remain
distinct even though both eventually use `value` storage. Write a constraint
when a body needs an operation.

A written cast can deliberately ask a more dynamic question. For an
unconstrained `T`, casting a `value`-typed operand `as T` is a carrier ascription
accepting any valid Lua value, and testing that operand `is T` is consequently
true. Casting a `T` to a closed type, such as `x as integer`, applies that closed
type's ordinary checked written cast. For `T: I`, the corresponding `as T` and
`is T` operations instead perform the ordinary cast or test for the erased
Interface `I`; they cannot discover an implementation from a bare record hidden
in `value`.

### Constrained parameters

A parameter constrained by `I<...>` has the same transport, Option, container,
equality, and written-cast operations, but its carrier is the substituted
Interface and it may call exactly that Interface's methods:

```titan
interface Stack<E>
    function push<R: Stack<E>>(item: E): R
end

function add<S: Stack<integer>>(stack: S, item: integer): S
    return stack:push<S>(item)
end
```

Inferred constraint-to-constraint evidence requires the same applied Interface
identity. Structural satisfaction is checked when a concrete record or union
closes the parameter; it is not a new subtyping relation inside the body.

## Eligible type arguments

Every explicit or inferred type argument must have a canonical, GC-safe erased
carrier **and** an existing sound strict projection back to its closed type.
The compiler calls this recursive admission predicate `transient_roundtrip`.
It authorizes the argument, not a new coercion.

The following Titan types qualify:

- `nil`, `boolean`, `integer`, `float`, `string`, and `value`;
- `T?`, Arrays, and Maps when all recursively stored/read components qualify and
  the reconstructed Option and Map key are otherwise well formed;
- Titan function types when every fixed, variadic, and flexible parameter and
  result qualifies, so ordinary callable wrappers can mediate both directions;
- record, union, and Interface applications when their outer value has a sound
  nominal/Interface guard and every written argument also qualifies; and
- another in-scope rigid parameter, subject to its own constraint.

Nominal eligibility is shallow: the compiler does not recursively promise the
historical contents of every field. It verifies the owner on a closed
elimination and verifies dependent contents when those contents are later
eliminated.

FFI types qualify only when Titan already provides sound **implicit**
conversions both to and from `value`, preserving the value, dynamic checks,
GC lifetime, and representation:

- exact C integer and floating values use their existing tag/range-checked
  boxing and unboxing;
- a complete GC-owned C value qualifies through its stamped owner userdata and
  traced lifetime—not because its C payload independently qualifies; and
- the compiler-recognized raw C `TValue` carrier uses its dedicated existing
  whole-slot conversions.

Raw C pointers, C arrays, C functions and function pointers, and direct ordinary
C structs and unions, as well as `void`, incomplete, or descriptor-only shapes,
do **not** qualify. The recognized raw `TValue` case above is the narrow
aggregate exception, not general `CStruct`/`CUnion` eligibility. Types
recursively containing a forbidden shape are rejected. A typedef or Titan alias
is normalized cycle-safely and qualifies only if its target does. A forbidden type hidden in
an Option, container, callback component, or phantom generic argument is still
rejected. Generics do not invent a pointer cast, bounds proof, lifetime proof,
or FFI-to-`value` conversion to make an argument eligible. The ordinary rule
that C-bearing types cannot be exported from a Titan module also remains in
force; see [the C FFI](ffi.md).

## Constraint erasure and run-time safety

Titan compiles one erased body for every generic declaration. A rigid parameter
uses its recursively erased constraint:

```text
erase(T)             = value                 when T is unconstrained
erase(T : I<args>)   = erase(I<args>)
erase(I<args>)       = I<erase(args)>
```

At the native representation level, unconstrained leaves use Titan's canonical
`TValue` representation. A constrained leaf uses the ordinary `Udata *`
Interface wrapper representation selected by its erased Interface application.
Erasure recurses through Options, Arrays, Maps, functions, fixed and open
results, variadic and flexible tails, fields, payloads, and captures. It uses
all of Titan's existing representations; there is no separate generic Option,
container, or callback ABI.

For example, in:

```titan
interface Boxed<E>
    function get(): E
end

function get<T, B: Boxed<T>>(box: B): T
    return box:get()
end
```

`T` erases to `value`, `Boxed<T>` erases recursively to `Boxed<value>`, and `B`
uses that Interface carrier. The generated code still has only the ordinary
run-time `Boxed` Interface identity; `<value>` is declared metadata, not a
per-wrapper descriptor.

### Forward boxing and reverse projection

The selected safety contract is asymmetric:

1. A statically accepted closed value moving **into** its erased constraint is
   adjusted and boxed directly. Erasure adds no gradual tag check.
2. An erased carrier moving **back to** a more precise, representation-sensitive
   closed type uses the constraint-appropriate strict elimination: the ordinary
   gradual guard for an unconstrained `value` carrier, or the existing checked
   Interface downcast/backing-owner test for a constrained carrier. A result
   consumed as its erased Interface transports without either check.

```titan
function id<T>(x: T): T
    return x
end

function use_id(): integer
    local n = id<integer>(1)
    return n
end
```

The integer is boxed into a `TValue` without a tag test, the one erased body
runs, and the result is strictly checked as an integer only when it is unboxed
for `n`. There is no identity-function exception or proof that the returned
carrier stayed pristine.

“First use” means the first **representation-sensitive closed elimination**,
not the next syntactic occurrence. Copying a carrier, storing or returning it
through the same rigid parameter, passing it to generic code, comparing it by
uniform `TValue` equality, testing an Option for nil, or discarding it does not
check a hidden application. The constraint-appropriate strict elimination
runs before a closed native scalar operation, concrete operator or condition,
concrete callable or Interface entry, FFI use, precise field/container/result
sink, or any fixed, variadic, flexible, or `for ... in` component unboxed to a
closed type.

A successful projection creates a checked concrete value for that use. It does
not sanitize an aliased aggregate, so a later dependent read is checked again.
Nested values are shallow: the outer container/callable/owner is checked before
it is used, and a dependent child is checked when that child is eliminated.

### Raw writes and delayed failure

Because `T` converts to and from its erased constraint, unconstrained generic
storage deliberately admits a literal `value` without converting it to a
closed instantiation first:

```titan
record Cell<T>
    item: T
end

function replace<T>(cell: Cell<T>, replacement: value)
    cell.item = replacement
end

function demonstrate_delayed_failure(): integer
    local cell = Cell.new(1)        -- Cell<integer>
    replace(cell, "wrong")          -- raw TValue store; returns normally
    local n: integer = cell.item    -- strict integer projection raises here
    return n
end
```

The write commits and the bad value may be copied, compared uniformly, returned
through generic code, or overwritten without raising. It cannot reach an
integer-native operation, integer callback, or FFI integer boundary without the
strict projection. This Transient/Shallow rule avoids run-time witnesses and
provenance tracking while preserving representation safety.

A constrained store is narrower. If `T: Show`, a statically known implementing
record is first adapted to `Show` on the forward edge. A literal `value` must
pass the ordinary checked `value -> Show` boundary immediately; arbitrary
`value` is not admitted as constrained `T`. A later projection to the concrete
implementing type checks the Interface wrapper's backing owner.

### Arrays, Maps, and dynamic writers

An Array constructed with unconstrained element `T` erases to `{value}` and
uses the existing permissive `value` writer. A generic-created closed view such
as `{integer}` can therefore receive a Lua float or another raw value and fail
only on a later strict integer read. A directly constructed monomorphic
`{integer}` keeps its ordinary eager writer policy.

For `T: I`, `{T}` erases to `{I}` and uses the Interface writer: dynamic ingress
must become the exact erased Interface before storage. Maps follow the same
constraint-carrier write and strict-read rule. There is no generic writer kind
and no deep traversal of existing container contents.

### Static applications and shared run-time identity

Applications of one owner are different invariant static types but share one
run-time owner identity, metatable, userdata layout, methods, statics, fields,
and native code. `Box<integer>` and `Box<string>` cannot be assigned to one
another, but they may be compared for reference equality because that operation
observes only their shared owner.

For an unconstrained owner parameter, gradual consistency relates a closed
application pointwise to its erased `value` view—for example,
`Box<integer>` with `Box<value>`. For `IBox<T: I>`, the erased view is
`IBox<erase(I)>`, never `IBox<value>` unless `value` actually satisfies the
constraint. These views preserve the same userdata; they are not conversions to
new instantiations.

A written `value as Box<integer>` or `value is Box<integer>` checks only the
outer `Box` owner. It does not prove the historical element argument or field
contents. Therefore a phantom type parameter or typestate distinction that is
not present in an Interface constraint is not dynamically enforced authority:
a `Box<value>` or Lua round trip erases it.

### Generic callbacks and function wrappers

Functions are eligible arguments because Titan can adapt a concrete callable to
the erased callable shape and back. Consider the earlier `foldl` call. Surface
inference gives the lambda type `(integer,string) -> string`, while the one
`foldl` body expects `(value,value) -> value`. Titan supplies an ordinary traced
closure-adjustment wrapper:

- when erased `foldl` invokes the callback, the wrapper strictly projects its
  two carrier arguments to `integer` and `string`;
- it calls the concrete lambda through its ordinary entry; and
- it boxes the concrete string result into the erased `value` carrier without
  an erasure-induced check.

The final result returned by erased `foldl` is strictly projected to `string` at
the caller. The inverse first-class edge uses the opposite wrapper. In
`local int_id: (integer) -> integer = id`, the concrete outward wrapper boxes
its integer argument for canonical erased `id`, invokes that erased entry, and
strictly projects the returned `TValue` to integer. It never exposes the erased
native pointer under a concrete function tag.

Constrained callback components use the same mechanism, including Interface
construction or downcast. Options, input variadics, flexible results, and bound
methods are adapted component by component.

These wrappers are ordinary GC-traced Titan closures, not dictionaries or
objects carrying type arguments. An adjustment may allocate a fresh wrapper;
closure identity across an adjusted generic edge is not promised.

### Lua sees erased declarations

Lua has no syntax or API for supplying Titan type arguments. An exported generic
declaration presents its real constraint-erased application:

- an unconstrained position is `value` and accepts any ordinary Lua value;
- a constrained position is the erased Interface and uses the ordinary dynamic
  Interface cast; and
- a known outer record, union, Array, Map, Option, or function shape retains its
  normal outer boundary behavior.

A Lua write to an unconstrained dependent field or Array slot may therefore
store raw data and move the failure to a later precise Titan projection. Fixed,
owner-independent fields keep their current eager dynamic conversion. Applied
nominal `as`/`is` remains a shallow owner test. Lua never receives a reified
argument list or per-application metatable.

## Separate compilation and visibility

Public generic owners, forwarding aliases, functions, methods, constraints, and
schemes are part of compiled-module type metadata. A consumer of a source, DSO,
static archive, or prefix-container provider therefore performs the same fresh
local instantiation and eligibility checks. The native provider still contains
one erased entry and one owner identity, not a specialization per application.

Generic declarations obey ordinary [visibility](modules.md#declaration-order-and-visibility). A
direct trusted source import may select a local generic declaration, just as it
may select another local declaration. Binary metadata and transitive imports
remain public-only. A type argument cannot smuggle a source-private owner across
that boundary.

Generics enter the compiled-module contract in ABI 0.24. An older provider is
rejected before its type metadata is decoded; this is a clean rebuild boundary,
not a compatibility or migration protocol.

## Generic asynchronous Tasks and channels

The `async` facade exports constructor-preserving aliases of the owners in
`titan.uv`, so the ordinary public spellings are applicable:

```titan
type CancellationReason = uv.CancellationReason
type TaskStatus = uv.TaskStatus
type Task = uv.Task
```

`Task<A,B>` is an opaque generic record. The public generic shapes are:

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

function TaskStatus:as_string(): string
function TaskStatus:has_finished(): boolean
function TaskStatus:has_succeeded(): (boolean, A?)
function TaskStatus:has_failed(): (boolean, Error?)
function TaskStatus:has_cancelled(): (boolean, CancellationReason<B>?)

function Task:cancel(reason: CancellationReason<B>?)
function Task:status(): TaskStatus<A, B>
function Task:add_terminal_listener(
    listener: (TaskStatus<A, B>) -> ()
): () -> ()
function Task:resume()

function run<A, B>(func: () -> A): Task<A, B>
function running(): Task
function channel<T>(size: integer?):
    ((T) -> (), () -> T, () -> ())
```

`A` is the Task's success type and `B` is the payload of a complex
cancellation reason. `running()` is deliberately
monomorphic: bare `Task` is exactly `Task<value,value>`.

`B` is result-only in `run<A,B>`. An expected `Task<A,B>` infers it;
without that evidence it closes to `value`. A complete explicit list remains
useful when the caller wants to state both arguments:

```titan
function start(): async.Task<string, value>
    return async.run<string, value>(function(): string
        return "done"
    end)
end
```

There is no partial explicit `async.run<string>` list. A callback already typed
with the zero-result list `()`, such as a named function whose body falls
through, gives no result evidence for `A`; the final carrier rule chooses
`value`, and ordinary callable adjustment supplies the missing value. An inline
unannotated lambda is different because it is still waiting for context. If no
other evidence binds `A`, `A` closes to `value`, the lambda receives a
`() -> value` context, and its fallthrough is rejected because that result is
not nil.

A Task that succeeds without a data payload uses one fixed nil result, not the
zero-result list `()`. Prefer `async.run(function (): nil end)`: the lambda
annotation infers `A = nil`, and its fallthrough supplies that nil through
ordinary return adjustment. A complete `run<nil, value>` application can
provide the same context when needed.

`channel<T>` has no payload-bearing argument, so `T` is likewise result-only.
Write `channel<string>()`, or give the returned callback slots an expected
shape, to select a precise application. A bare unconstrained `channel()` closes
to the backward-compatible `value` application. The returned send and receive
callbacks have exact `T` shapes even though they share one erased body.

The fixed-arity combinators preserve each operand independently. Their
one- and two-operand forms make the per-operand types explicit:

```titan
function join<A, B>(task: Task<A, B>): TaskStatus<A, B>
function join_two<A1, B1, A2, B2>(
    first: Task<A1, B1>,
    second: Task<A2, B2>
): (TaskStatus<A1, B1>, TaskStatus<A2, B2>)

function any_two<A1, B1, A2, B2>(
    first: Task<A1, B1>,
    second: Task<A2, B2>
): AnyTwoResult<A1, A2>

function race_two<A1, B1, A2, B2>(
    first: Task<A1, B1>,
    second: Task<A2, B2>
): RaceTwoResult<A1, B1, A2, B2>

function all_two<A1, B1, A2, B2>(
    first: Task<A1, B1>,
    second: Task<A2, B2>
): (A1, A2)
```

The same interleaved `(A_i,B_i)` parameter order extends through arity five.
Only `join` has a unary form; unary `any`, `race`, and `all` are intentionally
absent. `join_three` through `join_five` return the corresponding statuses.
`AnyNResult<A1,...,AN>` has a success-payload arm for each operand plus `none`;
it does not need cancellation parameters. `RaceNResult<A1,B1,...,AN,BN>` and
`AllNError<A1,B1,...,AN,BN>` have one `TaskStatus<A_i,B_i>` arm per operand.
`all_*` returns every `A_i` on success and raises the corresponding `AllNError`
on failure or cancellation. Expected type information closes a payload-free or
result-incomplete union constructor precisely; without it, remaining binders
close to their declared carriers like any other result-only generic constructor.

The scheduler and libuv ownership machinery intentionally store
`Task<value,value>`. A public `Task<A,B>` is a shallow view of that same userdata:
the coroutine stores a raw success `value`, and complex cancellation stores a
raw `value`. A precise `succeeded`, `has_succeeded`, `complex`, or
`has_cancelled` projection supplies the ordinary strict `A` or `B` guard.
Inspecting status tags, `as_string`, `has_finished`, equality, scheduling, and
resource ownership needs no hidden type-argument check. The scheduler's
operational helpers retain their concrete all-`value` APIs. Public `channel<T>`
likewise erases to one all-value buffer and callback triple, while closed uses
receive ordinary precise callback wrappers; Task projections, combinators, and
channels form the generic async surface.

`add_terminal_listener` returns an idempotent no-argument remover. Each
registration is distinct even if the same source callback is added twice, so
callers keep and invoke the returned remover in `defer`; there is no separate
removal operation that depends on adjusted closure identity. Registering after
the Task is already terminal does not deliver or append the listener and returns
an idempotent no-op. Once terminal publication has detached its delivery
snapshot, removers for that snapshot are likewise no-ops and cannot skip a
listener already selected for delivery. Listener adjustment follows the generic
callback rules above. For scheduling, cancellation, combinator behavior, and
ownership, see
[Asynchronous I/O and tasks](async-io.md).

## Version-one boundaries and diagnostics

Titan diagnoses a generic use before code generation when a binder, argument,
or application is malformed or cannot close. Common categories include:

- duplicate, cyclic, shadowing, or non-Interface binders and constraints;
- wrong owner arity, misplaced or partial explicit lists, or a constraint
  violation;
- an ordinary later argument/result incompatibility, or a recursive open-cell
  inference equation;
- use of an operation not provided by a rigid parameter;
- an ineligible type argument, including a forbidden FFI shape hidden inside a
  larger type; and
- using an explicitly owner-applied nominal member without a direct call.

The parser gives focused errors after a declaration or type-application angle
list has committed. Because call syntax is intentionally ambiguous with
comparisons, an incomplete `f<T...` may instead receive the deterministic
ordinary-expression diagnostic reached after the parser declines the generic
call suffix.

Version one deliberately has:

- no higher-kinded parameters, wildcard or partial applications, variance,
  subtyping, or source-declared default type arguments (the fixed final carrier
  rule is not a declaration-specific default);
- no parameterized aliases (only constructor-preserving forwarding aliases);
- no polymorphic lambdas, local let-polymorphism, generic function types, or
  first-class values that remain polymorphic;
- no generic `foreign function` declarations;
- no monomorphization, run-time dictionaries, witnesses, application tags,
  specialization caches, or deep homogeneous-heap guarantee;
- no provenance- or taint-based projection-check elision; and
- no magic iterator Interface conversion beyond Titan's existing four-value
  [`for ... in`](statements.md#the-generic-for--in) protocol.

The safety guarantee is open-world representation safety for Titan-generated
providers and the supported Lua surface. It is not exact run-time application
identity, relational parametricity, deep validation of aliased storage, or a
promise that every invalid dynamic write raises at the write site.
