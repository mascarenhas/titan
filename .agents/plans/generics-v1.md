# Generics v1 (parametric polymorphism)

Explicit type parameters in records/unions/interfaces/top-level functions/methods.
Local inference for type parameters only on use sites (constructors, function calls, method calls).
Anonymous functions cannot be polymorphic, no Hindley-Milner "let-polymorphism" either.
No higher-kinded type parameters. `foreign` functions cannot be polymorphic, either.

Note that a method definition for a polymorphic record/union/interface
can have its own type parameters, but these are separate from the
type parameters of the record/union itself (and the record/union
type parameters are in scope).

A somewhat-contrived example (where Stack<T> is supposed to
represent an immutable stack):

```
interface Stack<E>
  function push<R: Stack<E>>(value: E): R
end

record Pair<T,U>
  local first: T
  local second: U
end

function Pair:push_to_stack<S: Stack<T>>(s: S): S
  return s:push(self.first)
end
```

Type parameters are unconstrained (`T`) or constrained by an interface (`T: Interface`).
These are called constraints and not bounds because the type system does not have subtyping.

A type parameter constrained by an interface can only be bound to a type that implements
the interface.

An unconstrained type parameter is technically constrained by `value` in that it can
only be bound to a type that can have a `TValue` representation
(see `types.has_tvalue_representation`).

When typechecking a function body, the type parameters of the function cannot be bound.
Same for typechecking method bodies, and for method bodies this includes the type
parameters of the record/union itself. Record/union type parameters are present
in the type of the implicit `self` parameter of methods, but can also appear in regular
type declarations in methods (in parameter types, return types, local variables, etc.)

A value typed as an unconstrained, unbound non-free type parameter can only be
assigned to a variable declared (or inferred to have) the same type parameter,
passed as an argument expecting that same type parameter, compared by equality/inequality,
returned as a return value of the same type parameter, stored in an array of elements of
that type parameter, used as a key in a map with keys of that type parameter,
stored in a map with values of that type parameter, or used in the LHS of `is` or `as`
expressions as if it were a `value`. The only automatic coercions are to an optional
of that type, e.g. from `T` to `T?`, and to `value`.

A value of an unbound non-free constrained type parameter can also be used to call
methods of the interface that it is constrained to.

The example above also shows type inference on the `s:push` call. The example
uses different parameter names throughout to avoid confusion, but alpha renaming
is assumed. To typecheck this call, first the checker determined that the method
call is allowed, because the constraint of `S`, the type of the receiver `s`, is
`Stack<T>`, and this interface has a `push` method. This method itself has
a type parameter `R`, which starts off unbound and free within a constraint of `Stack<T>`
obtained through substitution of `E` with `T`.

The first argument typechecks because the type `E` of the first parameter also was
substitued by `T`, and this is the same (unbound, not free) `T` of `self.first`.
Then the return is checked against the context it is in (the return statement),
which expects the (also unbound but not free) `S`. This is checking the
still free `R` against `S`, which triggers an unification attempt, which
has to check the constraint of `R` since it is constrained. In this case
the constraint is satisfied, because both type variables are constrained to `Stack<T>`.
So the typechecker concludes that `R` is actually `S`.

This is functionally equivalent to an explicit `return s:push<S>(self.first)`.

So conceptually a type parameter/variable can be:

1. Unbound and free, same restricted set of operations, but can get unified during local inference and become bound
2. Bound to type `t` that satisfies the constraint, and is functionally the same as the type `t`
3. Unbound but not free, which is like if it was bound to a unique nominal type with a very restricted set of operations

Once bound, a type parameter/variable stays bound throughout typechecking and code generation. No free
type parameters may escape a local type inference context, and consequently may never reach code generation.

A bound type parameter has the type it is bound to, so further typechecking proceeds normally for it,
including any automatic coercions. In particular, typechecking a bound type parameter against an
unbound but not free one can generate a cast. The cast is like a cast to `value` if the unbound
parameter is unconstrained, or to the interface constraint if the unbound one is constrained.

The other way around (unbound against bound) generates the opposite cast, again assuming it typechecks
in the first place.

During code generation, since bound type parameters have the type they are bound to any generated declarations
use the unboxed type.

For example, assume this function:

```
function foldl<T, U>(a: {T}, f: (T, U) -> U, init: U): U
  local acc = init
  for i = 1, #a do
    acc = f(a[i], acc)
  end
  return acc
end
```

And this use site:

```
local xs: {integer} = {1,2,3}
local s = foldl(xs, function (x, s) return tostring(x) .. s end, "")
```

The call to `foldl` will bind `U` to `string`, since the value passed to `init` has
type `string`. `S` gets bound to `integer` because of the type of `xs`. The local variable `s`
gets also gets `string`, and its runtime representation will be an unboxed `TString*`,
not a boxed `TValue`. Local inference can flow both ways, the anonymous function
used in the call to `foldl` ends up typed as `(integer, string) -> string`.

It may be useful to rewrite the existing limited type inference for anonymous
functions and local variables to also use fresh unbound type parameters, so the same
unification mechanism handles inference both for polymorphic type parameters and
local variables/anonymous functions.

Unbound non-free type parameters have a `TValue` or `Udata*` representation depending on whether they are
constrained or not, so the compiled `map` native entry point and body uses

This does not affect record fields/union payloads/array elements/map keys/map values,
since they are always stored in boxed `TValue` form.

Unbound and not free type parameters are **not** `value`s, despite having the same `TValue`
representation. For example, `local i: integer = v` is valid when `v` has type `value`
(inserting the cast), but `local i: integer = v` is **not** valid when `v` has an unbound
but not free type parameter `T` (we are in a function body where `T` is a type parameter of
the function, for example). If such a cast is what the programmer intends they
need to write `v as integer` explicitly.

Unbound and not free type parameters **can** be automatically coerced to/from `value`.
For constrained type parameters the coercion (or explicit cast) from `value` will only succeed
at runtime if the value is already an interface value of the interface constraint.

From the Lua side all type parameters are effectively erased.

Type aliases cannot introduce type parameters, but they can have a polymorphic record/union
on the RHS, this should be written without any type parameters, too (e.g. `type Either = Pair`
for an alias to the `Pair` type in the example given above).

A polymorphic function used as a first-class function uses the same rules as a function call to
resolve type parameters, since first-class functions cannot be polymorphic.

## Dogfooding

Functions in the `iter` module are obvious candidates. Rename the `iter` module to `iteration`,
to make its name more in line other modules (`string`, `coroutine`).

An addition to the `iteration` module could be a family of iterator constructor interfaces usable with the
`for/in` loop (where the iterator itself is the state):

* `IteratorOne<A>` produces a `A` on every turn
* `IteratorTwo<A, B>` produces an `A` and `B` on every turn

Up to `IteratorThree`. They should also have `IteratorCloser*` versions that include a `close` method.

Adding finalizers (`__gc` metamethods) is another candidate. Change `gc.finalizable` to
`gc.finalizable<T>(val: T, finalizer: (T) -> ())`.

The `async` module also has aggregates and functions that can be generic:

* `async.Task<A,B>` where `A` is the return value of the task and `B` the complex cancellation reason.
* `async.run<A,B>(() -> A): Task<A,B>
* `async.CancellationReason<B>`, to use in the `complex` arm
* `async.TaskStatus<A,B>`, to use `A` in the `succeeded` arm and `CancellationReason<B>` in the `cancelled` arm
* All of the async combinators (all/race/any/join) and their related aggregates, to preserve task types
