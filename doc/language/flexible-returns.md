# Flexible returns

A Titan function normally has a fixed result list: `integer`,
`(integer, string)`, or `()` for no results. A **flexible return** adds a
trailing run whose length is chosen at run time. The fixed prefix is followed
by zero or more values of one declared type:

```lua
function names(): (...: string)
    return "Ada", "Grace", "Edsger"
end

function lookup(): (boolean, ...: integer)
    return true, 10, 20, 30
end
```

The `...: string` and `...: integer` declarations describe results, not
[variadic parameters](variadic-parameters.md). A flexible function may return
a different number of tail values on different calls. The surrounding
context decides whether it observes a fixed number of optional positions or
the complete run that actually exists.

## Declaring a flexible result

The flexible tail is written last inside a parenthesized return list:

```lua
function only_tail(): (...: integer)
end

function prefix_and_tail(): (boolean, ...: string)
    return true
end

function both_directions(n: integer, ...: string): (boolean, ...: value)
    return n > 0
end

local f: () -> (...: integer) = only_tail
local g: (integer, ...: string) -> (boolean, ...: value) = both_directions
```

The same syntax is available on every Titan callable declaration: exported
and `local` module functions, record functions, methods, and anonymous
functions. An input variadic tail and an output flexible tail are independent
and may appear on the same type, as `g` does above.

The parentheses are mandatory whenever the result list has a flexible tail.
The tail must be last, may appear only once, and must include its type. Thus
these forms are errors:

```lua
function unparenthesized(): ...: integer       -- must be inside (...)
function not_last(): (...: integer, string)    -- must be last
function missing_type(): (...)                 -- needs : type
```

As with an input variadic run, the element type must have a supported Titan
value representation. `...: nil` and flexible runs of foreign C pointers are
rejected. `...: value` is valid, as are option element types when nil is an
intended element and source-written owned C types (which use GC-managed
userdata rather than borrowed pointer storage).

The fixed prefix keeps the ordinary return rules. A function declared as
`(boolean, ...: integer)` must still produce its fixed `boolean`; only the
integer tail may be empty. A function with only a flexible tail may fall off
the end or use a bare `return`, producing an empty run.

## Finite consumption projects option values

Most expression positions ask for a known, finite number of values. When such
a position reaches beyond a flexible function's fixed prefix, each requested
tail position has type `T?`, because that particular value may be absent.

```lua
function measurements(short: boolean): (...: integer)
    if short then
        return 10
    else
        return 10, 20, 30
    end
end

function inspect(short: boolean): integer?
    local first: integer?, second: integer? = measurements(short)
    return second       -- nil when this call returned only one value
end
```

The declaration says that every value which exists is an `integer`; it does
not promise how many exist. Consequently both finite projections above are
`integer?`, even though this particular implementation always produces a
first value.

Assigning a projected `T?` to a non-option `T` uses Titan's ordinary option
force. It is accepted statically and raises the usual nil-unwrap error if the
position is absent at run time:

```lua
function require_second(short: boolean): integer
    local first: integer?, second: integer = measurements(short)
    return second       -- raises when short is true
end
```

A projected `...: value` slot remains `value`, rather than forming a separate
`value?` type: `value` already admits nil. See [Option types](option-types.md)
for the general coercion and forcing rules.

Finite adjustment applies uniformly to declarations, assignments, fixed
return lists, fixed call parameters, generic-`for` iterator tuples, and other
scalar positions. A call wrapped in an extra pair of parentheses, a condition,
a map or record field, and a named argument each request one value. A call
used as a statement requests no results.

Surplus results are ignored by a finite consumer. If a fixed-only call has too
few results, however, the existing arity error remains: only a declared
flexible tail can represent a possibly absent requested position.

```lua
function pair(): (integer, string)
    return 7, "seven"
end

function use_pair(): integer
    local n: integer = pair()  -- the string result is ignored
    return n
end
```

Only the last expression of an expression list can expand. Earlier calls are
scalar, just as for ordinary [multiple returns](functions.md#expansion-in-the-last-position).

## Open sinks preserve the actual run

Three contexts are **open sinks**. They consume every result that actually
exists after their fixed prefix:

* the trailing argument run of a variadic Titan call;
* the flexible tail of a `return` statement;
* the expanding final expression of a positional Array or exact
  integer-keyed Map constructor.

```lua
function names(): (...: string)
    return "Ada", "Grace", "Edsger"
end

function count_all(...: string): integer
    return #...
end

function forward_names(): (...: string)
    return names()             -- forwards exactly the results that exist
end

function collect_names(): {string}
    return { "Titan", names() } -- four elements for this implementation
end

function count_names(): integer
    return count_all(names())  -- forwards the complete run as arguments
end
```

An open sink consumes the raw element type `T`, not `T?`: absent results add
no element at all. Every remaining fixed result of the final producer is
consumed first, followed by its flexible tail. Fixed-only producers therefore
still expand their statically declared results in an open sink; only a
statically flexible producer can add a run whose length is not known until
run time.

The last-position rule still applies. Scalar expressions before the final
producer each contribute one element, while only that final producer may
expand. Computed Map entries, record fields, named arguments, conditions, and
parenthesized expressions are never open sinks.

An open context does not reveal results hidden by a narrower static function
type. If a callable that can return `(integer, ...: integer)` is stored in a
slot typed `() -> integer`, calls through that slot expose one integer even in
a positional container or flexible-return context. The callable's static type
remains the contract visible to its caller.

## Contextual calls through `value`

A `value` may be called directly. Titan derives a temporary function type
from the positional arguments and from the results demanded by the
surrounding context, then performs the ordinary run-time callable and boundary
type checks.

```lua
function call_one(f: value): integer
    local n: integer = f()     -- treat f as () -> integer here
    return n
end

function call_maybe(f: value): integer?
    local n: integer? = f()    -- treat f as () -> integer? here
    return n
end

function call_all(f: value): {integer}
    return { f() }             -- treat f as () -> (...: integer) here
end

function call_for_effect(f: value): ()
    f()                        -- zero-result demand
end

function sum_iterator(factory: value): integer
    local total = 0
    for n: integer in factory() do
        total = total + n
    end
    return total
end
```

The generic `for` call temporarily treats `factory` as
`() -> (value, value, value, value)`, for the iterator, state, initial control,
and optional close slots. Missing results are padded with `nil`; in particular,
a missing or explicit `nil` close from a `value` factory means that no close
call is made. The iterator and any non-`nil` close value are then checked
against the function shapes synthesized from the state, control, and visible
loop declarations.

The synthesized parameter types come from the positional argument expression
list. A known finite result position contributes its expected type; an
inferred finite position with no expected type becomes `value`:

```lua
function infer(f: value): value
    local result = f()         -- result is value
    return result
end
```

An open sink supplies a flexible result element type, as in `call_all`.
Nested positional calls also preserve Lua-style last-expression expansion:
an open outer argument tail can consume all the results of an inner call
through `value`.

Contextual calls are positional only. An arbitrary `value` carries no
declaration parameter names, so `f { name = x }` remains a compile-time error.
If the run-time value is not callable, the call raises the ordinary
non-callable error. Wrong argument or result types likewise raise the normal
Lua-boundary type errors.

If a `value` contains a Titan function whose exact type matches the type
derived for the call, Titan preserves the same native call path used by a
statically typed function value. A merely compatible Titan function, a Lua
function, a Lua C function, or a value with `__call` uses the generic callable
path. This distinction does not change the result-list rules above: the
derived static type still determines which results are visible.

Lua 5.5 can encode at most 250 results in a finite VM call request. Titan
therefore rejects a generic callable call when its finite visible result demand
can exceed 250. This limit is separate from the 200-element flexible-tail
limit: for example, a finite projection of 51 fixed results plus 200 flexible
positions would require 251 VM results and is rejected. A statically named
direct Titan call uses the native ABI and is not subject to this VM boundary.
A function-value site remains subject even when its run-time callee happens to
take Titan's exact native fast path, because the site must also be encodable for
the generic fallback. A generic call whose static result type has a flexible
tail and is expanded into an open return, array, or argument sink uses Lua's
open-result mode and is likewise unaffected. An open sink consuming a
fixed-only static callable still makes a finite request for that callable's
declared results and remains subject to the 250-result VM boundary.

## Surplus arguments and results

Positional Titan calls follow Lua's downward adjustment rule. Every explicit
argument expression is evaluated exactly once, from left to right, but a
non-variadic Titan function observes only its declared fixed parameters:

```lua
function take_one(n: integer): ()
end

function caller(): ()
    take_one(1, expensive_value()) -- expensive_value() runs; its result is ignored
end
```

An input-variadic Titan function instead receives the surplus as its `...`
run. Missing fixed arguments keep Titan's existing nil-padding behavior. Lua
callers follow the same boundary rule: an exported fixed-parameter Titan
function ignores surplus Lua arguments, while a variadic one collects them.

Finite result consumers likewise ignore surplus values. Explicit surplus
expressions are still evaluated for their effects, so a fixed-return function
may write more expressions than its declaration exposes:

```lua
function answer(): integer
    return 42, record_effect() -- record_effect() runs; its result is discarded
end

function notify(): ()
    return record_effect()     -- evaluated under zero-result demand
end
```

This relaxation is for Titan's positional expression lists. It does not
weaken other call forms:

* A direct C function, C function pointer, or C pseudo-constructor keeps
  strict C arity. A trailing Titan multi-result producer may be truncated to
  fill exactly the remaining C formals, but explicitly writing surplus C
  arguments is an error. A Titan function type with a flexible result tail
  cannot be converted to a C function pointer; C prototypes have their own
  fixed return convention.
* Named calls still reject unknown, duplicate, and excess labels. Each named
  expression supplies one scalar value, and calls through `value` cannot use
  named syntax. A flexible output tail does not by itself make a declaration
  ineligible for named calls; an input-variadic declaration remains
  ineligible.

See [Named arguments](named-arguments.md) and [The C FFI](ffi.md) for those
boundaries.

## Function compatibility is directional

Function types remain exactly equal only when all their fixed parameter and
result types, input-tail presence and type, and flexible-result presence and
type are equal. Assignment compatibility is broader and directional: an
actual function is being placed in an expected slot, and future callers obey
the expected slot's type.

For inputs:

* An actual function may have fewer fixed parameters than the expected type;
  it ignores the additional arguments that callers of the expected type may
  supply.
* An actual function may have additional fixed parameters only when each
  additional parameter accepts nil. Ordinary call adjustment fills those
  positions with nil when the expected type supplies no value. If the expected
  type has an input-variadic tail, each additional parameter must also accept
  that tail's element type because a caller may supply the position instead.
  A non-nilable additional parameter remains an incompatible hidden
  requirement.
* An expected input-variadic tail may flow to a non-variadic actual function,
  which ignores it. If the actual function has an input tail, every expected
  argument that reaches it must be accepted by its element type.
* Shared parameter positions are checked in the input direction: the actual
  function must accept every value permitted by the expected type.

```lua
function first(n: integer): integer
    return n
end

local wider_call: (integer, string) -> integer = first -- accepted
-- wider_call(7, "ignored") calls first(7)

function second(first: value, following: value): value
    return following
end

local adjusted: (value, ...: value) -> value = second -- accepted
-- adjusted("a") supplies nil to second's second parameter
-- adjusted("a", "b", "ignored") returns "b"
```

For results:

* An actual function may return more fixed values than the expected type;
  consumers ignore the surplus.
* When expected fixed positions extend into an actual flexible tail, each is
  projected as the corresponding option type. A non-option expected result
  uses the ordinary run-time nil unwrap.
* An expected flexible tail consumes all compatible actual fixed results
  beyond its own prefix, followed by the actual flexible tail when present.
  A fixed-only actual function may simply end; a flexible tail is always
  allowed to contain zero values.
* Shared result positions are checked in the result direction: every value
  produced by the actual function must be acceptable to consumers of the
  expected type.

```lua
function pair(): (integer, integer)
    return 1, 2
end

function numbers(): (...: integer)
    return 1, 2, 3
end

local one: () -> integer = pair                    -- second result is hidden
local run: () -> (...: integer) = pair             -- finite pair, then the run ends
local maybe_one: () -> integer? = numbers          -- safe finite projection
local required_one: () -> integer = numbers        -- raises if the run is empty
```

In conventional type-system terms, parameters are contravariant and results
are covariant. Titan's gradual `value` compatibility still applies at each
individual position, but it does not make whole function compatibility
symmetric.

Compatibility is not exact identity. A compatible assignment may use the
generic callable path and its boundary checks. It also cannot expose results
outside the expected static type: storing `numbers` in `() -> integer` makes
calls through that slot finite one-result calls, including inside an open
sink. See [The type system](types.md#function-types) and
[Functions as values](functions.md#functions-as-values).

## The 200-value bound

A flexible tail contains at most 200 values. When a Titan boundary materializes
an open flexible tail, more than 200 actual tail values raise a run-time error
instead of being silently truncated. A statically known finite context that
requests more than 200 projected tail positions is rejected at compile time; a
dynamic Lua caller making the same finite request receives the corresponding
run-time error.

A smaller finite consumer is not an open overflow: it receives only the
positions it requested and ignores the rest. The bound is shared with
variadic input runs and keeps these homogeneous runs small. Code that needs an
unbounded collection should return an explicit array `{T}` instead.

A statically open generic flexible forwarding call crosses the Lua boundary in
open-result mode, even when a later outer consumer will retain only a finite
prefix. Titan measures the raw results and that outer consumer copies only its
requested prefix, so discarded surplus Lua results do not by themselves
trigger the 200-value bound. If the run-time target is a
compatible-but-non-exact Titan closure, however, that closure first enters
through its own Lua wrapper with an open request. The wrapper materializes and
caps its own open flexible tail before the later finite outer consumer can trim
the run. No inherited finite flexible-result budget is passed through that
statically open generic Lua-call boundary; ordinary statically finite generic
calls still request their concrete result count.

Flexible returns cross the [Lua boundary](lua-interop.md) as ordinary Lua
multiple results. Lua's requested result count determines whether it receives
a finite prefix or the open run, subject to the same 200 flexible-tail limit.
