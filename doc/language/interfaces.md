# Interfaces

An Interface is a nominal, type-only contract made of method signatures. A
record or union satisfies that contract structurally at a use site: no
`implements` declaration is written on the concrete type. When the compiler
accepts a concrete value where an Interface is expected, it constructs a fresh
Interface wrapper whose method entries call that concrete value.

```titan
interface Reader
    function read(): string?
    function read_until(delimiter: string, chop: boolean?): string?
end

record Buffer
end

function Buffer:read(): string?
    return nil
end

function Buffer:read_until(
    delimiter: string,
    chop: boolean?
): string?
    return nil
end

function consume(reader: Reader): string?
    return reader:read()
end

function use(buffer: Buffer): string?
    return consume(buffer) -- constructs a Reader wrapper
end
```

This is a direct source-to-target coercion, not subtyping and not gradual
consistency. Keeping those relations separate is central to the feature:
Titan may wrap one statically known record as an Interface without thereby
making every Array element, Map value, or function result containing that
record interchangeable with the Interface type.

## Declaring an Interface

An Interface declaration is a nonempty list of bodyless method signatures:

```text
interface-declaration =
    "interface" Name
        interface-method
        { interface-method }
    "end"

interface-method =
    "function" Name "(" parameter-list? ")" return-annotation?
```

For example:

```titan
interface Stream
    function close()
    function write(data: string): integer
    function write_many(prefix: string, ...: string): (integer, ...: string)
end
```

The declaration is allowed only at module top level. Neither the Interface nor
one of its methods may be `local`. There must be at least one method, and
method names must be unique.

An Interface method has:

- fixed, named parameters using the ordinary `name: type` syntax;
- an optional trailing typed variadic parameter;
- zero, one, or several fixed results; and
- an optional flexible result tail.

It has no body and no individual `end`. There is no receiver colon in the
declaration: write `function read(...)`, not `function Reader:read(...)`.
Fields, constructors, static functions, record/union functions, method bodies,
and default methods are not Interface members.

`interface` is a reserved word. Longer names such as `interfaces` and
`interfaced` remain ordinary identifiers. A C declaration may still use
`interface` as a typedef, field, module member, or prototype parameter because
the [contextual C-name](grammar.md#identifiers-and-reserved-words) and named
label positions retain raw C identifier spellings.

## A nominal, type-only declaration

An Interface occupies the module's type namespace alongside records, unions,
and type aliases. It is visible throughout its flat or combined folder module
under the same declaration frontier as the other nominal types. An imported
Interface is named through its import alias:

```titan
local io = import "io"

function read_one(input: io.Reader): string?
    return input:read()
end
```

The declaration creates no source-visible value or record-style namespace:

- `Reader` and `io.Reader` are valid in type positions;
- `Reader` is not a constructor or first-class value;
- `io.Reader` in an expression is rejected as a type used as a value; and
- Lua does not see a `Reader` member on the module returned by
  `require "titan.io"`.

Because the declaration is type-only, it may share a spelling with a module
variable, function, or import alias. It may not share one with another
Interface, type alias, record, or union. A transparent type alias can name an
Interface, but it remains the same nominal Interface rather than defining a
new identity.

Each fully qualified Interface declaration is distinct. Identical method
lists do not relate two Interfaces:

```titan
interface LeftReader
    function read(): string?
end

interface RightReader
    function read(): string?
end

function rejected(left: LeftReader): RightReader
    return left -- compile-time error: distinct nominal Interfaces
end
```

`LeftReader` and `RightReader` are neither consistent nor coercible. There is
no Interface inheritance, and repeating a method set does not create an
implicit extension relation.

## Structural satisfaction at the coercion site

A record or union can be coerced directly to an Interface when every
Interface method is satisfied in declaration order. For each method, Titan
requires:

1. a method with the same name on the concrete record or union;
2. that method to be visible at the coercion site; and
3. the concrete method's self-removed function type to be directionally
   adjustable to the Interface method's self-removed function type.

Only methods count. A same-named field, module function, record/union function,
or generated union constructor does not satisfy an Interface method. Extra
concrete methods are irrelevant.

Visibility is checked where the wrapper is constructed. A `local` concrete
method may satisfy an Interface for a coercion inside its defining module, but
the same concrete/Interface pair is rejected in an importing module where
that method is hidden.

This is deliberately a cast-site visibility rule, not a requirement that
every satisfying method be public. Interface v1 does not yet permit local
Interfaces or local Interface methods, but the matching rule does not bake in
a public-only assumption that would prevent such declarations in a future
version.

When satisfaction fails, the diagnostic names the first Interface method in
declaration order and distinguishes a missing method, a same-named local
method that is inaccessible at this site, and an incompatible callable shape.
Titan does not choose the failure by iterating an unordered concrete member
map.

### Parameter names do not determine satisfaction

Parameter names are declaration metadata for named calls, not part of a
structural function type. Titan ignores concrete parameter names while
matching an implementation, but keeps the Interface names for calls:

```titan
interface PairConsumer
    function put(x: integer, y: integer)
end

record Swapped
end

function Swapped:put(y: integer, x: integer)
end

function send(swapped: Swapped)
    local consumer: PairConsumer = swapped
    consumer:put { x = 2, y = 3 }
end
```

`Swapped` satisfies `PairConsumer`. The named call selects Interface positions,
then invokes the concrete method positionally. The concrete method therefore
receives `y == 2` and `x == 3`.

### Exact and adjusted methods

When the projected concrete and Interface method types are equal, the wrapper
uses the concrete native method entry directly. Otherwise Titan may construct
an adjustment entry using the ordinary directional callable-shape rules.

For example, a concrete method may ignore arguments promised by the Interface,
and its fixed result may feed a compatible flexible result tail:

```titan
record R
end

function R:foo(): float
    return 1.0
end

interface I
    function foo(x: float, y: float): (...: value)
end

function adapt(r: R): I
    return r
end
```

Calls through `I` evaluate `x` and `y`, but the adjusted concrete method
ignores them. Its one `float` result becomes the first `value` in the flexible
tail. This pair needs an adjustment entry; it is not an exact method pair.

Aligned parameter and result components may use gradual consistency and nested
callable adjustment. They may not use an ordinary numeric, Option, C, or
Interface wrapper coercion. In particular, a concrete result coercion does not
lift through the method's function type:

```titan
interface Cloneable
    function clone(): Cloneable
end

record Node
end

function Node:clone(): Node
    return self
end
```

`Node` does not satisfy `Cloneable`: `() -> Node` is not adjustable to
`() -> Cloneable`. Instead, replace that method declaration so the scalar
conversion occurs in the concrete method's own declared result context:

```titan
function Node:clone(): Cloneable
    return self
end
```

The `return` now performs the direct `Node -> Cloneable` coercion. Interface
matching sees the exact `Cloneable` result instead of inventing a lifted
function-result conversion.

## Coercion is not consistency or subtyping

For an Interface `I`:

| Source | Target | Result |
| --- | --- | --- |
| `I` | the same `I` | identity; no allocation |
| `I` | a distinct Interface `J` | rejected |
| satisfying record/union `R` | `I` | direct coercion; construct a fresh wrapper |
| non-satisfying record/union | `I` | rejected with the first declaration-order method failure |
| `value` | `I` | strict implicit projection or explicit dynamic check; exact existing `I` wrapper only |
| `I` | `value` | gradual boxed injection |
| `I` | record/union `R` | no implicit relation; only the explicit concrete test/downcast described below |

There is no record/Interface or Interface/Interface subtyping relation.
Structural satisfaction is a private predicate used to construct one direct
outer coercion plan. It is not transitive and is never recursively queried for
Array, Map, Option, or Function components.

The coercion is available in every ordinary statically target-typed sink:
declarations, assignments, arguments (including named arguments), returns,
record fields, union payloads, Array elements, Map keys and values, module
variable initializers, generic-`for` bindings, and finite projections from a
variadic or flexible run. Each accepted scalar edge constructs the wrapper
explicitly.

### No container or callable lifting

Pointwise Array/Map gradual consistency remains separate from direct
coercion. Because `R` and `I` are not consistent, neither are `{R}` and `{I}`:

```titan
record R
end

function R:run()
end

interface I
    function run()
end

function rejected(rs: {R}, make_r: () -> R)
    local interfaces: {I} = rs       -- rejected
    local make_i: () -> I = make_r   -- rejected
end

function accepted(r: R): {I}
    return {r}                        -- the element sink wraps r
end
```

A gradual view such as `{integer}` as `{value}` preserves the same container
and checks elements when observed. It does not perform scalar conversions over
the contents. Likewise, a non-exact branded function view uses delayed strict
guards when called; it does not smuggle an Interface, numeric, or Option
coercion through an aligned component.

An Interface may be a Map key. A satisfying concrete key is wrapped at each
target-typed indexing operation. Since each conversion allocates a fresh
wrapper, two separately evaluated conversions normally denote different keys:

```titan
function lookup_twice(map: {I: string}, r: R): string?
    map[r] = "stored" -- one fresh I wrapper
    return map[r]     -- another wrapper: normally a miss
end
```

Retain the wrapper when stable key identity is needed:

```titan
function stable(map: {I: string}, r: R): string?
    local i: I = r
    map[i] = "stored"
    return map[i]
end
```

## Calls and bound methods

An Interface method call uses the Interface declaration's signature and
parameter names. Positional and named calls, missing-argument nil fill,
surplus-argument evaluation, typed variadic inputs, fixed/multiple/flexible
results, and finite/open result consumption follow the ordinary Titan call
rules.

```titan
interface Writer
    function write(data: string, ...: string): (integer, ...: string)
end

function forward(writer: Writer): (integer, ...: string)
    return writer:write("prefix", "a", "b")
end
```

The receiver is evaluated once before its arguments. Dispatch selects the
method's declaration-order slot in that wrapper and invokes either the exact
concrete entry or the recorded adjustment entry.

Naming a method without calling it produces an ordinary bound function value:

```titan
interface Counter
    function add(n: integer): integer
end

function bind(counter: Counter): (integer) -> integer
    return counter:add
end
```

The function value captures the Interface wrapper and has the method's type
with `self` removed. Exact Titan calls use its native Interface trampoline;
non-exact branded views use the strict generic path; Lua calls its coercive Lua
entry. Like every function value, a bound method has no named-call metadata,
so call it positionally after binding.

## Options

Interface options use explicitly named plans rather than a generic lifting
rule:

| Source | Target | Behavior |
| --- | --- | --- |
| satisfying `R` | `I?` | build an `I`, then make it present |
| satisfying `R?` | `I` | force non-nil, then build `I` |
| satisfying `R?` | `I?` | propagate nil; wrap a present `R` |
| `I` | `I?` | ordinary Option introduction |
| `I?` | `I` | ordinary force; nil raises |
| `value` | `I?` | nil propagates; a present value must already be an exact `I` wrapper |

```titan
function optional(r: R?): I?
    return r
end
```

If `r` is nil, `optional` returns nil. Otherwise it constructs an `I` wrapper.
Calling a method on `I?` applies the ordinary receiver force first, so nil
raises the normal option/type error.

Written casts remain narrower than the implicit option matrix. In particular,
the following are the complete Interface-specific rows to keep separate:

- `I? is R` is false for nil and otherwise tests the wrapped concrete value;
- `I? as R` raises for nil and otherwise performs the concrete downcast;
- `I? as I` performs the ordinary exact Option force, while `I? is I` is
  false for nil and true for a present exact `I`;
- `value as/is I?` accepts nil or an existing exact `I` wrapper, never a bare
  satisfying record or union;
- `R as/is I` is admitted only when the statically known record or union
  satisfies `I`; `as` constructs a wrapper and `is` is allocation-free; and
- direct C `TValue as/is I` or `I?` is inadmissible.

Source-option adaptation `R? as/is I` and target-option combinations
`R as/is I?`, `R? as/is I?`, `I as/is R?`, and `I? as/is R?` are not
admitted merely because an implicit assignment plan exists. Convert a C
`TValue` to `value` explicitly before applying one of the dynamic rows.

## `value`, C `TValue`, and explicit C `void *`

Boxing an Interface as `value` preserves the outer wrapper:

```titan
function dynamic(r: R)
    local i: I = r
    local wrapped: value = i
    local i2 = wrapped as I -- succeeds: wrapped already holds an I

    local bare: value = r
    local i3 = bare as I    -- raises: no dynamic implementation discovery
end
```

An implicit `value -> I` projection and a written `value as/is I` are
different operations, but this target has the same acceptance condition for
both: the value must already carry the exact nominal `I` wrapper. The written
form uses Titan's broader dynamic-coercion machinery; it still cannot build
the missing declaration-order vtable after the concrete static type has been
erased.

The same exact-wrapper-only dynamic rule applies at every genuine Lua sink
whose target is `I` or present `I?`: function formals, exported module
variables, public record fields, non-nil Array writes, and results entering
Titan from a non-Titan Lua callable. Raw Lua Map writes are not intercepted;
a later typed read strictly requires the exact wrapper and rejects a bare
implementer.

A C `TValue` has no direct relation to an Interface target. Convert the whole
slot to `value` first, then apply the exact-wrapper rule:

```titan
-- `tv` has an imported C TValue type:
-- local i = (tv as value) as I
```

The reverse direction follows the existing complete-slot conversion:
`I` and `I?` can be boxed into C `TValue`, preserving nil for the option.
Direct `TValue as/is I` remains inadmissible.

An Interface value may be explicitly cast to C `void *` to expose its GC
identity, under the same borrowed-address rules as records, unions, Arrays,
Maps, and function values. This written FFI operation neither unwraps the
concrete value nor transfers ownership. There is no other direct Interface/C
pointer relation.

## Concrete tests and downcasts

For a satisfying record or union `R`, written `r as I` constructs a wrapper.
The corresponding `r is I` evaluates `r` once, allocates nothing, and returns
`true`: the checker has already proved the same structural predicate. If `R`
does not satisfy `I`, both spellings are compile-time `cannot cast` errors;
`is` is not general structural reflection.

```titan
function explicit_wrapper(r: R): I
    return r as I -- constructs a fresh wrapper
end

function statically_satisfies(r: R): boolean
    return r is I -- true, with no wrapper allocation
end
```

The reverse written operation may name any visible record or union type,
whether or not that type satisfies the Interface. It inspects the concrete
value retained by a wrapper:

```titan
function recover(i: I): R
    if i is R then
        return i as R
    end
    raise "unexpected implementation"
end
```

`i is R` compares the hidden concrete value with `R`'s exact nominal identity.
`i as R` returns that original record/union reference on success and raises a
cast error naming both types on failure. A distinct Interface cannot be reached
by downcasting and rewrapping through the hidden concrete value:
`I as/is J` is admitted only when `I` and `J` are the same nominal Interface.

## Allocation, equality, and lifetime

Every evaluated concrete-to-Interface coercion constructs a fresh wrapper.
Wrappers are not interned or cached per concrete object:

```titan
function identities(r: R): (boolean, boolean, boolean)
    local a: I = r
    local b: I = r
    local c = a

    return a ~= b, a == c, (a as R) == r
end
```

`identities(r)` returns `true, true, true`.

Interface equality is wrapper identity. The separate symmetric comparability
policy does not consult a directional coercion, so `I == R`, `R == I`, and
their Option combinations are compile-time errors. Distinct nominal
Interfaces are also incomparable. Convert both sides explicitly to the same
representation before comparing.

The wrapper strongly retains both the concrete value and the concrete
type's owning module state. A consumer can therefore dispatch safely even when
it imports only the Interface owner and receives a wrapper constructed in a
different module. Native providers remain loaded by Titan's ordinary loader;
the retained module object supplies the correct per-Lua-state concrete context.

These are exactly the wrapper's two hidden user values: the first holds the
concrete owner's module object, and the second holds the concrete `self`. Both
exact entries and adjustment entries receive that first value, the
concrete-owner module, as their hidden `_mod` argument. The Interface owner
still supplies the identities needed to check and box the Interface signature
at a Lua entry, but it is never substituted for the concrete owner when the
selected method runs. The consumer module and the translation unit that
emitted an adjustment entry are likewise irrelevant to this ownership rule.

## Lua behavior

An Interface wrapper is userdata with one protected metatable per fully
qualified Interface in a Lua state. All implementers of that Interface share
the metatable. Public Interface methods are available through `__index`; every
write is rejected. There are no fields, constructors, statics, implementation
names, or vtable-reflection members.

Lua can obtain a wrapper only from Titan code that has already performed the
static concrete-to-Interface coercion:

```titan
interface Sink
    function put(n: integer)
end

record Box
end

function Box:put(n: integer)
end

function make_box(): Box
    return Box.new()
end

function wrap(box: Box): Sink
    return box
end

function use(sink: Sink)
    sink:put(1)
end
```

```lua
local m = require "sample"
local box = m.make_box()
local sink = m.wrap(box)

m.use(sink)                         -- accepted: exact Sink wrapper
assert(not pcall(m.use, box))       -- rejected: bare Box is not wrapped
```

Every Interface-typed Lua argument, module/record-field write, Array write, or
non-Titan callable result follows that exact-wrapper-only rule. Lua never asks
Titan to discover that a bare record/union implements the Interface. For `I?`,
nil is accepted first and every present value follows the same exact check.

Lua calls Interface methods with ordinary colon syntax. The generic method
entry checks that argument 1 has the exact Interface metatable, applies the
normal dynamic conversion to the declared arguments, dispatches through the
wrapper, and converts results for Lua. Reading a method produces a callable;
calling it with a receiver of the wrong Interface raises an error naming the
Interface and method. The metatable is protected, and debug-library or C-API
mutation of its private uservalues or payload is outside Titan's safety
contract.

The Interface declaration itself is type-only, so a Lua module object exposes
no `mod.InterfaceName` namespace. Lua's builtin `require "io"` remains its
ordinary standard library; Titan's IO module is loaded by Lua only through
`require "titan.io"`.

## Separate compilation

An Interface consumer does not need the concrete implementation in its source
import graph. The minimal topology has four modules:

```titan
-- api.titan
interface Scorer
    function score(n: integer): integer
end
```

```titan
-- provider.titan
record Counter
    base: integer
end

function Counter:score(n: integer): integer
    return self.base + n
end
```

```titan
-- consumer.titan
local api = import "api"

function use(scorer: api.Scorer): integer
    return scorer:score(1)
end
```

```titan
-- bridge.titan
local api = import "api"
local provider = import "provider"
local consumer = import "consumer"

function run(): integer
    local counter = provider.Counter.new(41)
    local scorer: api.Scorer = counter
    return consumer.use(scorer)
end
```

`consumer` imports `api`, not `provider`. The wrapper built by `bridge`
retains the provider module and concrete value. The serialized `api.Scorer`
descriptor supplies nominal identity, method order, and signatures; the
Interface owner supplies the canonical per-state metatable; and the wrapper
payload supplies the exact or adjusted concrete entries. This contract is the
same for source dependencies, individual shared providers, regular static
archives, multi-module prefix providers, and standalone executables.

Interface method order is ABI-significant and is preserved in compiled module
metadata. Interfaces are part of compiled-module ABI 0.20 together with the
two-user-value Array proxy and strict generic function-entry protocol. ABI
0.19 providers are rejected rather than adapted in place.

## Version-one boundaries

Interface v1 deliberately does not add:

- local or nested Interfaces, or local Interface methods;
- fields, constructors, static functions, method bodies, or default methods;
- embedding, inheritance, extension, intersections, or anonymous Interface
  types;
- an explicit `implements` declaration;
- record/Interface or Interface/Interface subtyping;
- a transitive or structurally lifted implementation relation;
- whole-container or general callable lifting of concrete-to-Interface
  coercion;
- dynamic discovery that a `value` or Lua value holding a bare record/union
  implements an Interface;
- conversion from one Interface to another through the hidden concrete value;
- reflection over implementer names or vtable contents;
- wrapper interning, special equality, hashing, or ordering;
- whole-container or general callable adapters;
- a C-compatible struct/vtable layout;
- a source-level vtable or unsafe Interface-construction API;
- readonly record fields; or
- in-place migration of an ABI-0.19 installation.

Interfaces do not change the existing rules for record and union declarations.
A concrete type satisfies an Interface only at a statically known coercion
site, using the visible methods and the directional callable rules described
above.
