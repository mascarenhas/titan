# Variadic parameters

A Titan function can take a **variadic parameter** `...t`: a trailing,
homogeneously typed run of extra arguments, all of element type `t`. It is
Titan's lightweight stand-in for a slice type — a function can accept *any
number* of trailing `t` values without an explicit array — but it is
deliberately limited so the compiler can pass those values on the C stack
with no allocation in the common case.

```lua
function sum(base: integer, ...integer): integer
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
declaration syntax, the three things you can do with `...`
(`#...`, `...[e]`, and spreading it), how a trailing `...` adjusts up into a
fixed-arity context, variadic functions as values, the Lua boundary, and
the limits and bans.

## Declaring a variadic parameter

A variadic parameter is written `...t` — the literal three dots followed by
its element type, with **no colon and no name**. It must be the **last**
parameter of the function, and its type is **mandatory** (there is no
inference for it, just as for any parameter). The same form works on
top-level functions, [anonymous functions](closures.md), and
[methods](records.md#methods):

```lua
function log(level: string, ...string)          -- top-level function
    -- ...
end

local fmt = function (...integer): integer       -- anonymous function
    return #...
end

record Acc
    base: integer
end

function Acc:total(...integer): integer          -- method
    local s = self.base
    for i = 1, #... do s = s + ...[i] end
    return s
end
```

A function may also have *only* the variadic parameter (`function f(...integer)`),
or a fixed prefix followed by it (`function f(a: integer, ...string)`). Because
the grammar admits `...t` only as the trailing parameter and always with its
type, both rejected forms below are caught as **syntax errors** at parse time:

```lua
function bad1(...integer, a: integer)   -- syntax error: nothing may follow ...
function bad2(...)                       -- syntax error: a type must follow ...
```

The element type may be almost any Titan type — a scalar, a `string`, an
array, a map, a record, `value`, or an option type — with two exceptions
(`nil` and foreign C pointers) described under [Limits and bans](#limits-and-bans).

## `...` is usable only inside its own function

Inside the declaring function, `...` names the run of extra arguments. It is
**not** visible to any nested [anonymous function](closures.md): an inner
lambda has its own (possibly absent) `...`, and reaching for the enclosing
one is a compile-time error.

```lua
function outer(...integer): integer
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
    local g = function (...integer): integer return ...[1] end
    return g(1, 2)           -- ok: g's own ...
end
```

Using `...` in a function that is not variadic at all is the related error
`'...' can only be used inside a variadic function`.

The three legal uses of `...` are `#...`, `...[e]`, and spreading it in a
trailing position; a bare `...` anywhere else (`1 + ...`) is the error
`'...' can only be used as the last item of an argument list, a return, an
assignment, or an array constructor`.

## Length: `#...`

`#...` is the number of variadic arguments the call supplied, as an
`integer`:

```lua
function count(...integer): integer
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
exactly as for [array indexing](arrays-maps.md#indexing-and-reads)).

This is a deliberate **divergence from array indexing**. Reading `a[i]` from
an array gives `t?`, because Lua arrays can have holes; a variadic run is
*dense*, so `...[e]` gives a bare `t` and an **out-of-range index raises a
run-time error** instead of reading as `nil`. An index `e < 1` or `e` past
`#...` both raise:

```lua
function at(i: integer, ...integer): integer
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

## Spreading `...`

A bare trailing `...` **spreads** the whole run of variadic arguments into
the surrounding list. As with the [expansion of a multi-return call](functions.md#expansion-in-the-last-position),
`...` is only legal in the **last** position. The three spread contexts:

* **a call argument list** — `f(a, ...)` or `f(...)`;
* **a `return`** — `return a, ...` or `return ...`;
* **an array constructor** — `{a, ...}` or `{...}`.

```lua
function tail_call(...integer): integer
    return sum(0, ...)         -- forward this function's ... into sum
end

function build(...integer): {integer}
    return {...}               -- collect the run into a fresh array
end
```

`{...}` (and `{e1, e2, ...}`) builds an array whose element type is the
variadic element type `t` — `{...}` from a `...string` function has type
`{string}`, and `{}` when the run is empty. The element type can also be
overridden by context, as long as `t` coerces to it: `{...}` of a
`...integer` run typed as `{float}` converts each element to a float, and
typed as `{value}` boxes each element. A type that `t` cannot coerce to is
the compile-time error `'...' element type integer is not coerceable to
array element type string`.

```lua
function as_floats(...integer): {float}
    return {...}               -- {3, 4} of integers becomes {3.0, 4.0}
end
```

A `...` that is not last in a constructor (`{..., 1}`) is the error `'...'
must be the last field in an array constructor`, and `...` inside a
[map](arrays-maps.md#maps) or [record](records.md) constructor (whose
entries are keyed, not positional) is `'...' can only appear in an array
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
function third(...integer): integer
    local a, b, c = ...        -- three non-optional slots: needs #... >= 3
    return a + b + c
end

function maybe(...integer): integer?
    local a: integer, b: integer? = ...   -- b nil-fills when ... has < 2 args
    return b
end
```

Each filled position is coerced to its slot's type the usual way, so the
adjust-up is type-checked: an `...integer` run filling a `float?` slot
converts each element to float, while an `...integer` run filling a
`string?` slot is the compile-time error `expected string? but found
integer?` — a representation mismatch is caught, never silently
reinterpreted.

Supplying *more* static values than the fixed arity has slots is the
ordinary over-supply error. `return 1, 2, ...` into a one-value return, or
`local a, b = 2, 3, 5, ...`, reports that the list `already supplies` enough
values:

```lua
function over(...integer): integer
    return 1, 2, ...           -- error: list already supplies the one return slot
end
```

`return ...` is itself adjust-up into the function's **fixed** return arity,
not a run-time-sized spread — `function pair(...integer): (integer, integer)
return ... end` returns `...[1], ...[2]` (and raises if fewer than two were
supplied). A `return ...` from a function that returns no values (`: ()`) is
the error `cannot use '...' to return from a function that returns no values`.

### Forwarding `...` to another variadic function

When the trailing `...` instead reaches a **variadic** callee — `f(...)` or
`f(a, ...)` where `f` is itself variadic — the *whole* run is forwarded as
that callee's variadic arguments (a true run-time-sized spread, not
adjust-up). This is the one spread that carries the count through. The two
runs' element types must be **compatible**:

```lua
function forward(...integer): integer
    return sum(0, ...)         -- forward the run; element types must match
end
```

`integer` and `value` forward both ways (the gradual `value` relationship),
so an `...integer` run forwards into a `...value` callee and vice versa. A
representation mismatch such as `...integer` into a `...float` callee is the
compile-time error `'...' element type integer is not compatible with the
'...' element type float of function 'sink'` (naming the callee).

## Variadic functions are first-class values

Only the `...` *expression* is non-first-class. A **variadic function** — and
a variadic method's [bound reference](closures.md#bound-method-references)
`obj:m` — is a perfectly ordinary value: store it, pass it, return it, call
it indirectly, hand it across the Lua boundary. Its function type carries the
variadic element, written with the same `...t` syntax inside the arrow type:

```lua
function sum(...integer): integer
    local s = 0
    for i = 1, #... do s = s + ...[i] end
    return s
end

function run(): integer
    local f: (...integer) -> integer = sum      -- store a variadic function
    return f(1, 2, 3) + f() + f(10)             --> 6 + 0 + 10
end
```

A function type with a fixed prefix and a variadic tail is written the
obvious way, `(integer, ...integer) -> integer`. Calling a variadic value
works exactly like calling any [function value](functions.md#functions-as-values):
when the value's run-time type matches the call's static type, the call takes
the zero-overhead native path; a merely *compatible* type (for example a
`(...value) -> integer` slot holding a `(...integer) -> integer` function, or
a plain Lua function), goes through the generic Lua-stack path, which checks
and converts each variadic argument at the boundary.

`(...integer) -> integer` and `(...value) -> integer` are mutually
**compatible** (gradually, through `value`), so a variadic function flows
into either; but a variadic function type is **never** compatible with a
non-variadic one — `local f: (integer) -> integer = sum` where `sum` is
variadic is a type error.

## Using a variadic function from Lua

A variadic exported function is called from Lua like any other: pass the
fixed arguments, then as many trailing values as you like. Unlike a
fixed-arity Titan function — which is [strict about argument count](functions.md#strict-arity)
— a variadic one accepts **at least** its fixed parameters, with everything
beyond them becoming the variadic run. The trailing values are checked and
converted to the element type `t` at the boundary, exactly as a fixed
parameter of type `t` would be, and a wrong-typed one raises the usual
boundary error.

```lua
function greet(prefix: string, ...string): string
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
print(pcall(m.greet))                --> false   calling Titan function greet with 0 arguments, but expected at least 1
```

Spreading `...` works across the boundary in both directions: a variadic
Titan function can be `return`ed and called from Lua, and a Titan `{...}`
result arrives in Lua as a plain table.

## Limits and bans

* **`...nil` is rejected.** A typed `...t` run cannot hold `nil`, so a `nil`
  element type makes no sense: `function f(...nil)` is the compile-time error
  `a variadic parameter cannot have type nil`. (Use `...value` or `...t?` if
  you genuinely need nil among the elements; those types already include
  it.)
* **A foreign C pointer element is rejected.** A `...` whose element type is
  a [C FFI](ffi.md) pointer is a compile-time error `a variadic parameter
  cannot have a foreign pointer type`, and `...` cannot be passed into a
  foreign function — the C FFI has its own, disjoint notion of variadic.
* **At most 200 variadic arguments.** A variadic run is capped at 200
  elements (`TITAN_VARARG_MAX`). A statically written call can never reach
  it (the parser caps an argument list well below that), but a long chain of
  forwarding or a large Lua-side call can: crossing 200 raises the clean
  run-time error `too many variadic arguments`. The cap is intentional —
  it keeps the run small and stack-allocatable; a function that genuinely
  needs an unbounded homogeneous run should take an explicit array
  parameter `{t}` instead.
* **`...` does not escape its function.** As covered above, `...` cannot be
  captured by an inner lambda, stored in a variable, or referenced as a
  value. Spread it, index it, or take its length — but to keep the run
  around, copy it into an array with `{...}` first.

*Implementation note:* a variadic run is passed as a small homogeneous C
struct (one of seven, one per element representation) rather than a Lua
table, which is why the element type is fixed and the count is capped; the
full runtime representation and GC discipline are described in the
[implementation documentation](../implementation/index.md).
