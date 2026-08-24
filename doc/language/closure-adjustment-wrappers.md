# Closure adjustment wrappers

Titan function types are exactly equal only when their fixed parameters and
results, input tail, and flexible-result tail are equal. A broader
**directional callable adjustment** may nevertheless place an actual function
of type `A` in a slot of expected type `B`. The checker fixes that one `A -> B`
edge at the use site; it is not subtyping, a search through intermediate types,
or permission to lift arbitrary scalar conversions through `Function`.

A non-exact adjustment may be *realized* as a fresh target-typed Titan closure.
That wrapper makes calls through the `B` view use Titan's native convention
while retaining the source function's genuine-Lua behavior. Realization is
conditional: an exact branded Titan `A` closure, including an eligible wrapper
from an earlier edge, may be realized. All other values remain unchanged and
use the existing generic call path.

## The directional shape rule

Callers of the expected type `B` supply `B` arguments, while the immediate
source closure consumes `A` arguments and produces `A` results. An adjustment
therefore acts in opposite directions on the two sides of the arrow:

* **Arguments flow from `B` to `A`.** An actual function may ignore fixed
  arguments or an input tail that only `B` exposes. If `A` has an additional
  fixed parameter, the adjustment may fill it with nil only when that parameter
  accepts a missing nil; an expected input tail may instead supply that
  position. Aligned parameters may use identity, a strict gradual
  injection/projection/view, or another callable adjustment.
* **Results flow from `A` to `B`.** The expected view may hide surplus fixed
  results, project positions from an actual flexible tail, or collect compatible
  remaining fixed/flexible results into its own tail. Aligned results use the
  same limited component operations in the result direction.
* **Ordinary coercions do not lift.** Numeric conversion, ordinary Option
  introduction or force, C conversion, and record/union-to-Interface wrapper
  construction cannot be smuggled through an aligned Function component.

These are the same rules used when a concrete method is checked against an
Interface method. Input and output tails remain bounded by Titan's ordinary
200-element run limit.

### A missing fixed result may be nil-filled

There is one explicit result-side shape action. If `B` requires a fixed result
for which `A` has neither a fixed result nor a flexible result source, Titan may
supply nil when that exact expected result type accepts a missing nil. The
admitted categories are `nil`, `value`, an Option `T?`, and nullable Titan or C
pointer types. A required boolean, number, string, record, union, or Interface
result is rejected.

```titan
function notify(): ()
end

function accepted()
    local maybe_code: () -> integer? = notify  -- call returns one nil option
    local opaque: () -> value = notify         -- call returns one nil value
    local only_nil: () -> nil = notify         -- call returns one nil value
end

function rejected()
    local code: () -> integer = notify         -- compile-time error
end
```

This operation is named nil fill because it is shape adjustment, not a
component conversion from `nil` to the result type. It does not make an
ordinary fixed `T` result adjustable to fixed `T?`, and it cannot be composed
transitively into a new coercion. If an actual flexible tail can supply the
position, the normal flexible projection takes precedence instead.

## Conditional realization

Let `A` be the operand's static source type and `B` the expected type.
Evaluating the edge obeys the following rules:

1. If `A` and `B` are exactly equal, the edge is identity. The operand is
   evaluated once, no closure is allocated, and its original value is
   preserved.
2. For an admitted non-exact edge, Titan first evaluates and anchors the
   operand exactly once. If the run-time value is an exact branded Titan `A`
   closure and its C-closure upvalue list has room for one more entry, Titan
   constructs a fresh closure tagged `B`.
3. Otherwise the boxed operand is left unchanged. Lua closures, Lua C
   functions, `__call` objects, deferred non-callable values, differently
   tagged Titan closures, and Titan closures already at Lua's upvalue ceiling
   all take this fallback. Callability still fails only when the unchanged
   value is called.

The static adjustment is sound in either case. A realized wrapper uses a
native target adapter; an unchanged branded Titan value uses its strict generic
entry; and an unchanged non-Titan value uses ordinary Lua dispatch followed by
Titan's dynamic result boundary.

## Identity and equality

The identity rule distinguishes the **source value** from an **adjusted view**.
A referenced top-level, local, imported, record/union function, or constructor
still has its canonical per-state closure. Repeated reads such as `m.f` keep
that exact source identity. A lambda still creates one fresh source closure per
lambda evaluation, and a bound-method expression still creates its ordinary
capturing closure.

When a non-exact edge actually realizes a wrapper, however:

* the wrapper differs from its immediate source;
* separately evaluated adjustments produce separate wrappers; and
* a chain such as `A -> B -> C` produces one fresh identity for every realized
  non-exact edge.

Titan does not cache, intern, flatten, or equality-unwrap wrappers. Ordinary
function equality remains raw object identity. By contrast, a conditional
fallback allocates nothing and preserves the operand's existing identity.
Retain an adjusted value in a variable when later uses need stable wrapper
identity; do not repeatedly re-evaluate the adjustment.

## Titan and Lua observe different contracts

A realized `B` wrapper carries two intentional call surfaces:

* An exact Titan call through `B` enters the wrapper's target-native adapter.
  It adjusts `B` arguments to `A`, invokes the **immediate source closure**
  through its exact native entry, and adjusts `A` results to `B`. Nested
  callable components are wrapped under the same conditional rule. Every
  action comes from the checker-approved callable adjustment.
* A genuine Lua call enters the `source->f` coercive entry copied from the
  immediate source value. It therefore preserves whatever Lua surface that
  value already carries—ultimately the original source declaration's parameter
  count, dynamic conversions, and result behavior. Titan never synthesizes a
  target-`B` Lua entry.

For example, a static `A = (integer) -> integer` function may be viewed as
`B = (value) -> integer`. A Titan call through `B` first applies the strict
`value`-to-`integer` component observation required on the route to `A`. A Lua
call of the realized wrapper instead uses `A`'s genuine-Lua integer conversion,
which accepts an integral in-range Lua float. The wrapper does not turn the
Titan call into a Lua boundary or the Lua call into a target-typed Titan call.

A later non-exact Titan call of the wrapper uses the wrapper's target-`B`
strict relay and then its native adapter. The relay belongs to the consumer
that created the wrapper; it is not the source declaration's strict entry with
its source-tag check weakened or copied. This keeps strict target behavior
valid across source, DSO, and archive providers.

## Implicit adjustment, `as`, and `is`

Every ordinary finite target-typed sink uses the same rule: declarations,
assignments, arguments, returns, fields, container elements, and other finite
scalar positions may conditionally realize a wrapper for an admitted non-exact
Function edge. A written non-exact callable cast does the same:

```titan
function first(n: integer): integer
    return n
end

function make_view(): (integer, string) -> integer
    return first as (integer, string) -> integer
end
```

`exp is B` asks whether the corresponding written cast is admitted, evaluates
`exp` once, and remains allocation-free. It neither constructs a wrapper nor
tests whether conditional realization would succeed. In particular, the usual
function-boundary deferral remains: a boxed non-callable value may pass through
a Function-typed view and fail only when called.

A dynamic `value -> Function` projection is not a statically known `A -> B`
edge. It preserves the boxed value, creates no adjustment wrapper, and defers
callability/signature enforcement to the ordinary exact/branded/non-Titan call
dispatch.

Runtime-open expression-list paths—forwarded `...`, flexible results, and open
positional constructors—apply the same checker-recorded action per element.
They do not invent a different relation merely because no finite expression
node exists for each element.

## Limits and non-goals

Lua permits at most 255 upvalues in a C closure. Titan keeps the existing
source-closure capture limit: it does not reserve an extra source capture slot
for this optimization. If a source closure already uses all 255 upvalues, or a
wrapper chain reaches that ceiling, the next adjustment simply preserves the
value and uses the generic fallback. This changes performance and identity
allocation at that edge, not which programs are accepted or how calls are
checked.

Closure adjustment wrappers do **not** add:

* a Function subtyping relation or lifted scalar coercions;
* retagging for dynamic `value -> Function`, Arrays, Maps, or C function
  pointers;
* wrapper caching, interning, flattening, equality unwrapping, or escape
  analysis; or
* a new Lua-facing target entry or a new provider ABI.

The fixed Titan closure header and native function signatures are retained through ABI 2.
Debug-library or C-API mutation of Titan's private closure upvalues opts out of
these guarantees, exactly as it does for ordinary function closures.

See [Functions](functions.md#functions-as-values) for first-class dispatch,
[Flexible returns](flexible-returns.md#callable-adjustment-is-directional) for
finite/open demand, [Variadic parameters](variadic-parameters.md) for input
tails, [Lua interoperability](lua-interop.md) for the dynamic boundary, and
[Interfaces](interfaces.md#exact-and-adjusted-methods) for method matching.
