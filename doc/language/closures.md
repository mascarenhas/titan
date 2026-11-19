# First-Class Functions and Closures

Functions are first-class values in Titan. Named functions, record and union
constructors, anonymous function expressions (lambdas), and bound method
references can all be stored in variables and containers, passed as arguments,
returned, and exchanged with Lua.

## Function types and functions as values

A function type lists its parameter types in parentheses followed by its
return type or parenthesized return list:

```text
function (integer, string): boolean
function (integer): (integer, integer)
function (string): ()                       -- zero return values
function (...: integer): (integer)          -- variadic input tail
function (): (boolean, ...: string)         -- flexible return tail
(function (integer): (integer))?            -- optional function type
```

Referencing any top-level function, `local` function, imported `mod.f`, record
static (`Point.new`, `Point.origin`), or union-variant constructor
(`Lookup.found`) yields a function value of its type:

```titan
local function double(x: integer): integer
    return x * 2
end

function apply(transform: function (integer): (integer), item: integer): integer
    return transform(item)
end

function apply_handler(handlers: {function (integer): (integer)},
                       index: integer, item: integer): integer
    return handlers[index](item) -- auto-unwraps optional function slot
end

function double_twenty_one(): integer
    local fn: function (integer): (integer) = double
    return apply(fn, 21)
end
```

Key properties of function values:

- **Positional-only calls:** Parameter names are not part of a function type.
  Once a function is held as a value, it can only be called positionally, not
  with named-call braces.
- **Identity:** Equality compares function values by object identity. A named
  function has a single canonical value per Lua state, so `mod.f == mod.f`.
- **Dynamic `value` and Lua:** Function values convert implicitly to `value`,
  and a `value` converts implicitly to any function type with callability
  checked only when the value is called. Passing a Lua function to a Titan
  function-typed parameter is the standard way for Titan to invoke Lua
  callbacks (see [Interoperating with Lua](lua-interop.md)).
- **Foreign C functions:** Imported C functions and `foreign function`
  declarations are not Titan function values; use C function pointers for C
  callbacks (see [Foreign Functions and C Callbacks](foreign-functions.md)).

## Anonymous functions and type inference

An anonymous function (lambda) has the same syntax as a function declaration
without a name, with optional parameter and return annotations:

```text
function (p1[: T1], ..., pn[: Tn]) [: Ret] <block> end
```

When annotations are omitted, Titan infers parameter types, a trailing bare
`...` element type, and the complete return shape from the **expected function
type** at the assignment, argument, or `return` site. Titan never infers
parameter or return types backwards from the lambda's body:

```titan
function apply_twice(fn: function (integer): (integer), x: integer): integer
    return fn(fn(x))
end

function apply_variadic(fn: function (...: integer): (integer)): integer
    return fn(10, 20, 30)
end

function lambda_examples(): (integer, integer, integer)
    local inc: function (integer): (integer) = function (x) return x + 1 end
    local doubled = apply_twice(function (x) return x * 2 end, 3)
    local summed = apply_variadic(function (...)
        local total = 0
        for i = 1, #... do total = total + ...[i] end
        return total
    end)
    return inc(5), doubled, summed
end
```

When there is no expected function type:

- Every parameter (and any `...: T` tail) must be explicitly annotated; an
  unannotated parameter without usable context is a compile-time error:

  ```text
  -- compile error: cannot infer type of parameter 'x'
  local id = function (x) return x end
  ```

- Omitting the return annotation defaults to **zero results** (`: ()`), even
  if the body contains `return expression` (the expression evaluates for its
  effects and its value is discarded). Write an explicit return annotation
  (`function (x: integer): integer ...`) or place the lambda in a typed
  context when it should return a value. Conversely, write `: ()` explicitly
  when a lambda should return nothing despite a result-bearing context:

```titan
local events = 0

local function record_event(): integer
    events = events + 1
    return events
end

function install(callback: function (): (value))
    callback()
end

function zero_return_lambdas()
    install(function (): ()
        record_event()
    end)

    -- No expected type and no return annotation: type is function (integer): ().
    local bump = function (step: integer)
        events = events + step
    end
    bump(2)
end
```

A lambda is a simple expression, so calling one immediately requires
parentheses: `(function () ... end)()`. Deeply nested lambdas are capped by
the parser at roughly seven levels.

## Capturing enclosing locals

A lambda automatically captures any enclosing local variables and parameters
it references, following Lua's lexical scoping rules:

```titan
function make_counter(start: integer): function (): (integer)
    local current = start
    return function (): integer
        current = current + 1
        return current
    end
end

function make_adders(): {function (integer): (integer)}
    local adders: {function (integer): (integer)} = {}
    for i = 1, 3 do
        local offset = i * 10 -- fresh local per iteration
        adders[i] = function (x: integer): integer
            return offset + x
        end
    end
    return adders
end
```

Each call to `make_counter` creates an independent closure over its own
`current` variable. Capture semantics follow five rules:

- **Shared mutable cells:** Reassigning a captured local updates the shared
  variable seen by the enclosing function and every closure that captured it.
  A `const` local cannot be reassigned from inside a closure.
- **Per-iteration isolation:** A fresh local declared inside a loop body
  (`local offset = i * 10`) produces an independent capture for each
  iteration.
- **Transitive and GC-safe:** Nested lambdas can capture locals from any
  enclosing function; module variables and top-level functions are accessed
  directly without capture. Captured strings, containers, and nominal objects
  stay rooted across garbage collection.
- **Fresh identity:** Every evaluation of a `function ... end` expression
  produces a distinct closure object (`f == f`, while two evaluations of the
  same lambda text are unequal).
- **No self-reference through `local`:** Because a `local` enters scope after
  its initializer, a lambda cannot call itself through the local being
  initialized:

  ```text
  -- compile error: variable 'countdown' not declared
  local countdown: function (integer): (integer) = function (n: integer): integer
      if n <= 0 then return 0 end
      return countdown(n - 1)
  end
  ```

  Write a named top-level `local function` for recursion.

A lambda may also appear in a module-variable initializer to store a function
value without executing its body during module startup, provided the
initializer does not invoke or expose it to a call evaluated during
initialization (see [Modules and Program Structure](modules.md)).

## Bound method references

Naming a method on a receiver without a call list (`obj:method`) produces a
first-class function value with `self` bound to `obj` and removed from the
parameter list:

```titan
record Counter
    count: integer
end

function Counter:bump(step: integer): integer
    self.count = self.count + step
    return self.count
end

function make_bumper(): function (integer): (integer)
    local counter = Counter(0)
    return counter:bump -- binds counter; type is function (integer): (integer)
end
```

The receiver expression evaluates once when the bound method is created.
Because records are reference values, mutations through the bound method are
visible through the original record.

Bound methods work on records, unions, and Interfaces (capturing the Interface
wrapper) and across compiled modules. Once bound, a method is positional-only.
Explicit method type arguments (`obj:m<|T|>`) are only valid on a direct call,
not on a detached bound method reference, and foreign C methods cannot be
bound as Titan function values.

## Immediate calls as expressions

Calling an anonymous function literal directly—`(function (...) ... end)(...)`—
lets you write local control flow and multi-statement initialization inside an
expression with zero closure allocation. The compiler inlines the call as a
scoped block:

```titan
function find_first(items: {integer}, minimum: integer): (integer?, integer?)
    local position?, found? =
        (function (values: {integer}, threshold: integer): (integer?, integer?)
            for index = 1, #values do
                local current? = values[index]
                if current and current >= threshold then
                    return index, current
                end
            end
            return nil, nil
        end)(items, minimum)
    return position, found
end
```

Because the surrounding expression does not supply an expected function type
to the literal, annotate its parameters and return types explicitly. Arguments
evaluate once before the body runs; `return` exits only the lambda (evaluating
return values before any `defer` inside the lambda); and an outer pair of
parentheses adjusts a zero-return immediate call to `nil`, as in
`((function (): () end)())`.

## Callable shape adjustment

Two function types are identical only when their fixed parameters, fixed
results, variadic input tail, and flexible return tail all match. At typed
sinks (assignments, arguments, returns, `as B`, and Interface method
matching), Titan also permits directional **callable shape adjustment** from
an actual function type `A` to an expected function type `B`:

- **Inputs (`B -> A`):** `A` may accept fewer parameters than `B` (ignoring
  extra fixed arguments or an input tail from `B`). `A` may accept *more*
  fixed parameters than `B` if every extra parameter accepts `nil` (and also
  accepts `B`'s variadic element type when `B` is variadic).
- **Results (`A -> B`):** `B` may expect fewer fixed results than `A` (hiding
  the extras), project optional `T?` results from `A`'s flexible tail, or
  collect `A`'s remaining fixed and flexible results into `B`'s flexible tail.
- **Missing fixed results (`nil`-fill):** If `B` expects a fixed result beyond
  everything `A` produces, Titan fills `nil` when `B`'s result type admits
  missing `nil` (`nil`, `value`, `T?`, or a nullable pointer). Required
  booleans, numbers, strings, containers, and nominal types are rejected.
- **Aligned components:** Aligned parameter and result positions accept exact
  identity, gradual consistency with `value`, or nested callable adjustment.
  Scalar coercions (`integer` to `float`, fixed `T` to `T?`, or record `R` to
  Interface `I`) do **not** lift through function types.

```titan
local function first(n: integer): integer
    return n
end

local function pair(): (integer, integer)
    return 1, 2
end

local function numbers(): (...: integer)
    return 1, 2, 3
end

local function notify()
end

function adjustment_examples(): (integer, integer, integer?, integer?)
    local wider: function (integer, string): (integer) = first
    local one: function (): (integer) = pair
    local maybe_first: function (): (integer?) = numbers
    local absent: function (): (integer?) = notify
    return wider(7, "ignored"), one(), maybe_first(), absent()
end
```

Incompatible shapes and lifted scalar coercions are compile-time errors:

```text
-- compile error: notify produces no result, and integer does not admit missing nil
local required: function (): (integer) = notify

-- compile error: integer -> float does not lift through function types
local as_float: function (): (float) = one

-- compile error: fixed integer -> integer? does not lift through function types
local as_opt: function (): (integer?) = one
```

An exact function-type assignment preserves the original closure identity. A
non-exact adjustment may allocate a fresh wrapper closure, which compares
unequal to the source function and to a second adjustment of the same
function; store the adjusted function in a variable when stable identity
matters. `fn is B` checks eligibility without allocating a wrapper. When Lua
calls an adjusted Titan function, Lua observes the original function's dynamic
Lua signature rather than a synthesized target signature.

## Transferring a closure between Lua states

[`TransferValue.from_value(callback)`](async-io.md#transfer-values) snapshots
a Titan function or closure so it can be sent to another OS thread, an
independent `lua.Lua` state, or a cross-state `async.Receiver`.

Conversion immediately snapshots all captured variables before any capture's
custom transfer hook runs, so later mutations in the origin state do not
affect the snapshot. In the destination state, `to_value` loads the owning
module through its preload entry and constructs a fresh closure over copied
captures; module-level variables inside the closure refer to the destination
state's module instance.

Capture rules across states:

- **Mutable captures become fresh cells:** Shared cell aliasing is not
  preserved across states—an outer closure and a nested captured closure each
  receive independent cells, and repeated conversions produce independent
  snapshots.
- **Allowed captures:** Primitive values, strings, nested Titan closures,
  bound concrete methods (copying their receiver), public records and unions
  eligible for protobuf serialization, public records defining
  [custom transfer hooks](async-io.md#custom-record-transfer), retained
  `TransferValue` wrappers (preserved as wrappers rather than unwrapped), and
  raw C pointers (keeping caller-managed lifetimes). Callable adjustments
  preserve both source and target signatures.
- **Rejected captures:** Cycles (including a closure capturing itself through
  a mutable variable), direct Arrays, Maps, Interfaces (including bound
  Interface methods), `owned` C storage, `local` nominal types, and non-`nil`
  Lua `Udata` pointers.

The snapshot retains no reference to the source state's closures, strings, or
heap objects. See [Concurrency](concurrency.md) and
[Transfer values](async-io.md#transfer-values) for cross-state patterns.
