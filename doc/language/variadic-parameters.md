# Variadic parameters

A Titan function can take a **variadic parameter** `...: t`: a trailing,
homogeneously typed run of extra arguments, all of element type `t`. It is
Titan's lightweight stand-in for a slice type — a function can accept *any
number* of trailing `t` values without an explicit array — but it is
deliberately limited so the compiler can pass those values on the C stack
with no allocation in the common case.

```lua
function sum(base: integer, ...: integer): integer
    local n = #...
    local s = base
    for i = 1, n do
        s = s + ...[i]
    end
    return s
end
```

```lua
-- Lua
local m = require "sum"
print(m.sum(0))             --> 0
print(m.sum(100, 1, 2, 3))  --> 106
```

The variadic *parameter* and the `...` *expression* are **not** first-class
— `...` cannot be captured by an inner function, stored, or made to escape
its function — but the function that declares one **is** an ordinary
[first-class value](functions.md#functions-as-values), with a
function type that records the variadic element. This chapter covers the
declaration syntax, the explicit scalar forms `#...`, `...[e]`, and `(...)`,
spreading a trailing `...`, how that tail adjusts up into a fixed-arity
context, variadic functions as values, the Lua boundary, and the limits and
bans.

An input variadic tail is independent of a
[flexible result tail](flexible-returns.md). A function may declare both:

```lua
function transform(...: integer): (...: string)
    -- input and output runs have separate element types and counts
end
```

## Declaring a variadic parameter

A variadic parameter is written `...: t` — the literal three dots, a colon, and
its element type, with **no name** (the `name: type` declaration style used
everywhere else, just with no name before the colon). It must be the **last**
parameter of the function. On a top-level function, a concrete method, or an
Interface method signature the element type is **mandatory** (there is no
inference for it, just as for any parameter); an
[anonymous function](closures.md) may instead write a bare `...` whose element
type is [inferred from context](#untyped-lambda-vararg). The same form works on
top-level functions, anonymous functions, concrete methods, and
[Interface signatures](interfaces.md#declaring-an-interface):

```lua
function log(level: string, ...: string)          -- top-level function
    -- ...
end

local fmt = function (...: integer): integer       -- anonymous function
    return #...
end

record Acc
    base: integer
end

function Acc:total(...: integer): integer          -- method
    local s = self.base
    for i = 1, #... do s = s + ...[i] end
    return s
end
```

A function may also have *only* the variadic parameter (`function f(...: integer)`),
or a fixed prefix followed by it (`function f(a: integer, ...: string)`). Because
the grammar admits `...: t` only as the trailing parameter, and requires the
`: t` on top-level functions and concrete or Interface methods, both rejected
forms below are caught as **syntax errors** at parse time:

```lua
function bad1(...: integer, a: integer)  -- syntax error: nothing may follow ...
function bad2(...)                       -- syntax error: a top-level vararg needs `: t`
function bad3(...integer)                -- syntax error: the colon is required
```

The element type may be almost any Titan type — a scalar, a `string`, an
array, a map, a record, `value`, or an option type — with two exceptions
(`nil` and foreign C pointers) described under [Limits and bans](#limits-and-bans).

### Untyped variadic in an anonymous function {#untyped-lambda-vararg}

An [anonymous function](closures.md) may write a bare `...` with **no** element
type, exactly as it may write an untyped parameter `a`. The element type is then
**inferred from the context** — the expected variadic function type at the point
where the lambda is assigned, passed, or returned:

```lua
function apply(f: (...: integer) -> integer): integer
    return f(1, 2, 3)
end

local r = apply(function (...)           -- ... inferred as integer
    return #... + ...[1]
end)
```

Inference comes only from the context type. If the context is a variadic
function type, its element type is used; if the context is non-variadic (or
there is no usable context at all), the bare `...` is a type error (`cannot infer
the type of '...'`), just like an uninferable untyped parameter. A lambda that
writes an explicit `...: t` keeps that type regardless of context. Top-level
functions and concrete or Interface methods get no such inference — their
`...: t` is mandatory.

## `...` is usable only inside its own function

Inside the declaring function, `...` names the run of extra arguments. It is
**not** visible to any nested [anonymous function](closures.md): an inner
lambda has its own (possibly absent) `...`, and reaching for the enclosing
one is a compile-time error.

```lua
function outer(...: integer): integer
    local g = function (): integer
        return ...[1]        -- compile-time error
    end
    return g()
end
```

```
test.titan:3:16: type error: '...' is not visible inside an inner function
```

A *variadic inner lambda* resolves its **own** `...` normally — the rule
only forbids reaching *outward*:

```lua
function outer(): integer
    local g = function (...: integer): integer return ...[1] end
    return g(1, 2)           -- ok: g's own ...
end
```

Using `...` in a function that is not variadic at all is the related error
`'...' can only be used inside a variadic function`.

The parser admits `...` only in an explicit form—`#...`, `...[e]`, `(...)`, a
collection spread `...subject`, or one of the bracketed spread slices—or as
the final bare marker of a positional expression list. A bare `...` anywhere
else, such as `1 + ...`, is a syntax error; it does not reach type checking as
a scalar operand. At the start of a list item, `... -1` instead has the
unambiguous collection-spread subject `-1` and reaches the checker, which
rejects that non-container subject.

## Length: `#...`

`#...` is the number of variadic arguments the call supplied, as an
`integer`:

```lua
function count(...: integer): integer
    return #...
end
```

```lua
-- Lua
local m = require "count"
print(m.count())          --> 0
print(m.count(7, 8, 9))   --> 3
```

## Indexing: `...[e]`

`...[e]` reads the `e`-th variadic argument, **1-based**, with type `t` —
the plain element type, **not** an option. The index is an `integer` (a
`float` or `value` index is accepted and converted with a run-time check,
exactly as for [array indexing](arrays-maps.md#positive-indices)).

This is a deliberate **divergence from array indexing**. Reading `a[i]` from
an array gives `t?`, because Lua arrays can have holes; a variadic run is
*dense*, so `...[e]` gives a bare `t` and an **out-of-range index raises a
run-time error** instead of reading as `nil`. An index `e < 1` or `e` past
`#...` both raise:

```lua
function at(i: integer, ...: integer): integer
    return ...[i]            -- type integer; raises if i is out of range
end
```

```lua
-- Lua
local m = require "at"
print(m.at(2, 10, 20, 30))      --> 20
print(pcall(m.at, 0, 10, 20))   --> false   ...:N:C: variadic index 0 out of range [1, 2]
print(pcall(m.at, 5, 10, 20))   --> false   ...:N:C: variadic index 5 out of range [1, 2]
```

Because an in-range read is always a valid `t`, you never have to unwrap an
option to use it — `...[i]` goes straight into arithmetic, a comparison, a
field access, or a call. The raise is exactly what licenses the
non-optional type.

## Explicit one-value adjustment

Parentheses turn the input run into exactly one scalar value, using its first
element. Its intrinsic type is `t?`: when `t` is already optional or is
`value`, Titan does not add another option layer. When the caller supplied no
variadic argument the value is `nil`, and surplus arguments after the first are
ignored.

```lua
function first(...: integer): integer?
    return (...)
end
```

As with every other `t?` expression in Titan, a context requiring plain `t`
automatically forces it. The force succeeds when a first argument exists and
raises at run time when the input run is empty. Unlike a bare trailing `...`,
`(...)` always contributes exactly one value to an expression list, including
one `nil` value when the run is empty.

## Spreading `...`

A bare trailing `...` **spreads** the whole run of variadic arguments into
the surrounding list. As with the [expansion of a multi-return call](functions.md#expansion-in-the-last-position),
`...` is only legal in the **last** position. Positional expression-list
consumers include:

* **a fixed or variadic Titan call argument list** — `f(a, ...)` or `f(...)`;
* **a `return`**, fixed or flexible — `return a, ...` or `return ...`;
* **a multiple declaration or assignment** — `local a, b = ...` or
  `a, b = ...`;
* **a positional Array or exact integer-keyed Map constructor** —
  `{a, ...}` or `{...}`;
* **a generic `for ... in` iterator tuple**, where it fills the remaining
  iterator, state, control, and optional close positions.

```lua
function tail_call(...: integer): integer
    return sum(0, ...)         -- forward this function's ... into sum
end

function build(...: integer): {integer}
    return {...}               -- collect the run into a fresh array
end
```

The general [spread-expression](spread-expressions.md) feature also accepts
`...subject` to expand an Array or integer-keyed Map, and comma-bearing forms
such as `...[first, last]` to select a closed subrange of this input run.
Scalar `...[e]` above remains a different, raising operation.

Without a Map context, `{...}` (and `{e1, e2, ...}`) builds an Array whose
element type is the variadic element type `t` — `{...}` from a
`...: string` function has type `{string}`, and `{}` when the run is empty.
An exact `{integer: V}` context instead builds an ordinary positional Map.
The element/value type can be overridden by context when the checker can
record an assignment adjustment for each element. For `{...}` of a
`...: integer` run, a `{float}` context uses the direct numeric coercion,
whereas a `{value}` context uses a gradual injection that boxes each element;
the latter is not a structural or direct coercion. A target with no assignment
adjustment is a compile-time error, such as
`'...' element type integer is not coerceable to array element type string`.

```lua
function as_floats(...: integer): {float}
    return {...}               -- {3, 4} of integers becomes {3.0, 4.0}
end
```

A bare `...` that is not last in a constructor (`{..., 1}`) is a syntax error.
An explicit collection spread such as `{...items, 1}` parses and is rejected
by the checker because only the final positional field can expand. A trailing
`...` inside a computed-key [Map](arrays-maps.md#maps) or
[record](records.md) constructor is
`'...' can only appear in an all-positional array or integer-keyed map
constructor`.

## Adjust-up: filling a fixed arity from `...`

A trailing `...` does **not** carry a run-time count into a *fixed-arity*
context. When `...` spreads into a context with a known number of slots — a
non-variadic call, a multiple assignment or declaration, or a `return` into
a fixed return arity — the compiler expands it into one `...[k]` read **per
remaining slot**. So `local a, b, c = ...` is exactly `local a, b, c =
...[1], ...[2], ...[3]`.

What happens when the run is too short to fill a slot is **driven by that
slot's type**, generalizing the `...[e]` rule above:

* a **non-optional** target slot uses the raising read — if `...` under-supplies
  it, the call raises at run time (`local a, b, c = ...` needs at least three
  variadic arguments);
* an **optional** target slot `s?` **nil-fills** — an out-of-range position
  reads as `nil` rather than raising (`local a: integer, b: integer? = ...`
  leaves `b` as `nil` when only one argument was supplied).

```lua
function third(...: integer): integer
    local a, b, c = ...        -- three non-optional slots: needs #... >= 3
    return a + b + c
end

function maybe(...: integer): integer?
    local a: integer, b: integer? = ...   -- b nil-fills when ... has < 2 args
    return b
end
```

Each filled position receives the ordinary assignment adjustment to its
slot's type, so the adjust-up is type-checked: an `...: integer` run filling a `float?` slot
converts each element to float, while an `...: integer` run filling a
`string?` slot is the compile-time error `expected string? but found
integer?` — a representation mismatch is caught, never silently
reinterpreted.

Supplying more static values than a finite Titan sink has slots is allowed.
Every surplus expression is still evaluated, while its value is discarded;
if the surplus is the trailing `...`, no element is read because the sink
requests none of the run:

```lua
function over(...: integer): integer
    return 1, 2, ...           -- returns 1; the explicit 2 is evaluated then discarded
end
```

`return ...` is itself adjust-up into the function's **fixed** return arity,
not a run-time-sized spread — `function pair(...: integer): (integer, integer)
return ... end` returns `...[1], ...[2]` (and raises if fewer than two were
supplied). A `return ...` from a function that returns no values (`: ()`) is
legal and requests no elements. If the function instead declares a consistently
shaped
flexible result tail, `return ...` is open and forwards the complete run-time
input run into that output tail.

### Forwarding `...` to another variadic function

When the trailing `...` instead reaches a **variadic** callee — `f(...)` or
`f(a, ...)` where `f` is itself variadic — the run-time count is carried
through. If the static prefix has already filled the callee's fixed
parameters, the remaining run becomes that callee's variadic arguments. If
the static prefix is short, the first elements of the run are borrowed for
the missing fixed parameters, with the same nil-fill rule used for short
call arguments: fixed parameters whose types accept `nil` receive `nil`
when the run is too short; fixed parameters that cannot accept `nil` raise
on an under-supplied run. Whatever remains after the fixed parameters
becomes the callee's variadic run. The two variadic element types must be
equal or **gradually consistent**, and the checker records the element
adjustment consumed by the open run:

```lua
function forward(...: integer): integer
    return sum(0, ...)         -- forward the run; element types must match
end
```

A trailing call with a flexible result tail is another open producer for this
same sink. `sink(produce())` forwards every result actually produced after
filling `sink`'s fixed parameters; the result element type must be consistent
with the callee's variadic element type under the same gradual rule.

`integer` and `value` forward both ways (the gradual-consistency relationship),
so an `...: integer` run forwards into a `...: value` callee and vice versa. A
representation mismatch such as `...: integer` into a `...: float` callee is the
compile-time error `'...' element type integer is not compatible with the
'...' element type float of function 'sink'` (naming the callee). The
ordinary scalar `integer -> float` coercion does not lift through a variadic
run. A satisfying record/union-to-Interface wrapper coercion likewise does not
lift through a variadic run; forwarding `...: R` into `...: I` is rejected even
when `R` directly satisfies `I`.

## Variadic functions are first-class values

Only the `...` *expression* is non-first-class. A **variadic function** — and
a variadic method's [bound reference](closures.md#bound-method-references)
`obj:m` — is a perfectly ordinary value: store it, pass it, return it, call
it indirectly, hand it across the Lua boundary. Its function type carries the
variadic element, written with the same `...: t` syntax inside the arrow type:

```lua
function sum(...: integer): integer
    local s = 0
    for i = 1, #... do s = s + ...[i] end
    return s
end

function run(): integer
    local f: (...: integer) -> integer = sum      -- store a variadic function
    return f(1, 2, 3) + f() + f(10)             --> 6 + 0 + 10
end
```

A function type with a fixed prefix and a variadic tail is written the
obvious way, `(integer, ...: integer) -> integer`. Calling a variadic value
works exactly like calling any [function value](functions.md#functions-as-values):
when the value's run-time type matches the call's static type, the call takes
the native path. A statically known non-exact adjustment conditionally creates
a fresh target-tagged wrapper, so an eligible exact Titan source then reaches a
native adapter that implements fixed/tail actions. For example, a
`(...: value) -> integer` slot may hold a `(...: integer) -> integer` source;
the adapter strictly establishes the integer elements before invoking the
source. If wrapper realization is ineligible, the unchanged branded value uses
its strict generic trailer. A plain Lua function instead uses the ordinary Lua
call path and dynamic result conversion.

Calling a variadic Interface method follows the same rules. Direct calls use
the Interface signature's fixed prefix and tail; a bound Interface method is an
ordinary variadic function value whose receiver has already been captured.

`(...: integer) -> integer` and `(...: value) -> integer` are mutually
**consistent** at their aligned components (gradually, through `value`).
Callable adjustment with fixed-only function types is directional. A fixed
actual function may inhabit a slot whose type has a variadic tail and ignore
that tail. A variadic actual may inhabit an admissible fixed-only slot and
simply receives whatever fixed arguments the slot promises. An actual
function may also have additional fixed parameters when each accepts nil from
an omitted expected tail; if the expected type is variadic, those parameters
must additionally accept its tail element. The reverse direction is rejected
whenever adjustment would force nil into a non-nilable parameter or feed an
incompatible value to an observed tail. Once a wrapper is realized, its target
tag does not erase these obligations: the target typed tail is enforced on the
exact path, and the adapter then performs any stricter source-side component
observation. A `value` element cannot use a historical tag mismatch to bypass
an `integer` view.
See [Flexible returns](flexible-returns.md#callable-adjustment-is-directional),
[Closure adjustment wrappers](closure-adjustment-wrappers.md), and the
[normative boundary matrix](types.md#normative-boundary-matrix) for native
adapters, strict fallback, and the coercive Lua entry.

## Using a variadic function from Lua

A variadic exported function is called from Lua like any other: pass the
fixed arguments, then as many trailing values as you like. Missing fixed
arguments are [padded with `nil`](functions.md#argument-adjustment), just
as they are for non-variadic Titan functions; everything beyond the fixed
parameters becomes the variadic run. The trailing values are checked and
converted by the shared dynamic rule for element type `t`, exactly as a fixed
parameter of type `t` would be, and a wrong-typed one raises the usual
boundary error.

```lua
function greet(prefix: string, ...: string): string
    local out = prefix
    for i = 1, #... do out = out .. " " .. ...[i] end
    return out
end
```

```lua
-- Lua
local m = require "greet"
print(m.greet(">"))                  --> >
print(m.greet(">", "a", "b", "c"))   --> > a b c
print(pcall(m.greet))                --> false   greet.titan:1:1: type error, expected string but found nil
```

Spreading `...` works across the boundary in both directions: a variadic
Titan function can be `return`ed and called from Lua, and a Titan `{...}`
Array result arrives in Lua as its canonical userdata proxy. If the same
positional expression is constructed under an exact integer-keyed Map context,
the result is an ordinary Lua table.

## Limits and bans

* **`...: nil` is rejected.** A typed `...: t` run cannot hold `nil`, so a `nil`
  element type makes no sense: `function f(...: nil)` is the compile-time error
  `a variadic parameter cannot have type nil`. (Use `...: value` or `...: t?` if
  you genuinely need nil among the elements; those types already include
  it.)
* **A foreign C pointer element is rejected.** A `...` whose element type is
  a [C FFI](ffi.md) pointer is a compile-time error `a variadic parameter
  cannot have a foreign pointer type`. A Titan input run or collection spread
  cannot supply a C function's variadic operands: C `...` has its own ABI and
  promotion rules. A nonvariadic C call may consume a Titan spread through its
  finite fixed formals, with one ordinary foreign conversion per projected
  scalar. A source-written owned C type is different: it is GC-managed
  userdata and is a supported variadic element type.
* **At most 200 variadic arguments.** A variadic run is capped at 200
  elements (`TITAN_VARARG_MAX`). A fixed statically written prefix cannot reach
  it (the parser caps an argument list well below that), but a runtime-sized
  Array/Map/input-vararg spread, a long forwarding chain, or a large Lua-side
  call can: crossing 200 raises the clean run-time error `too many variadic
  arguments`. The cap is intentional —
  it keeps the run small and stack-allocatable; a function that genuinely
  needs an unbounded homogeneous run should take an explicit array
  parameter `{t}` instead. Flexible result tails use the same 200-element
  bound for the same reason.
* **`...` does not escape its function.** As covered above, `...` cannot be
  captured by an inner lambda, stored in a variable, or referenced as a
  value. Spread it, index it, take its length, or adjust its first value with
  `(...)` — but to keep the run around, copy it into an array with `{...}`
  first.

*Implementation note:* a variadic run is passed as a small homogeneous C
struct (one of seven, one per element representation) rather than a Lua
table, which is why the element type is fixed and the count is capped; the
full runtime representation and GC discipline are described in the
[implementation documentation](../implementation/index.md).
