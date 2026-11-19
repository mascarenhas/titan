# Statements, Scope, and Control Flow

Titan's statements follow Lua's syntax and block structure while adding static
type checking, `const` bindings, and lexical cleanup. For expressions that
appear inside statements, see [Chapter 2](expressions.md); for union matching,
see [Chapter 8](unions.md); for `defer`, `raise`, and `catch`, see
[Chapter 12](error-handling.md).

## Blocks and lexical scope

A *block* is a sequence of statements optionally ended by a `return`
statement. Function and lambda bodies, loop bodies, each arm of an `if` or
`case`, and explicit `do ... end` constructs are all blocks.

Scoping is lexical: each block introduces a new scope, and a local binding is
visible from the statement after its declaration to the end of its enclosing
block. Shadowing an outer local or an earlier local in the same block is
allowed. A lone `;` is an empty statement; statements require no other
separator.

```titan
function scoped_sum(): integer
    local total = 10
    do
        local total = 20 -- shadows outer total until end
        total = total + 5
    end
    return total -- 10
end
```

Any block may carry a `catch` trailer before its closing `end` (Titan has no
`try` keyword). The protected body and its `catch` clause are sibling scopes,
and the `catch` clause provides read-only `error: value` and
`traceback: string` locals (see [Errors and Resource Cleanup](error-handling.md)).

Unused locals are permitted; their initializers run for their side effects. A
local keeps the value it holds reachable for garbage collection until its
block exits or the local is reassigned, so a local declared solely to hold an
owned C buffer keeps that buffer alive for the block. `_` is an ordinary
identifier conventionally used for ignored values, and may be repeated within
a single multi-local or generic-`for` declaration list.

## Local and `const` declarations

### Mutable locals and type inference

A mutable local variable uses `local`, an optional type annotation, and an
optional initializer expression list:

```titan
function declaration_examples(values: {integer}, input: string?): (integer, string)
    local count = 0                   -- inferred integer
    local ratio: float = 1            -- integer coerced to float
    local pending: string?            -- initialized to nil
    local dynamic: value              -- initialized to nil

    local first = values[1]           -- integer; raises if values[1] is nil
    local second? = values[2]         -- integer?; preserves absence

    const limit = 10
    local const lower: integer, upper: integer = 1, limit

    local name? = input
    const name = name                 -- reads outer name?, forces to string, binds const

    count = first + (second or 0) + lower + upper
    return count, name
end
```

When a declaration has an initializer and omits its type annotation, Titan
infers the type from the initializer—and **drops an outer option**, inserting
a runtime nil check so unexpected `nil` fails immediately (`local first =
values[1]` has type `integer`). Append `?` to the variable name
(`local second? = values[2]`) to preserve an option type without repeating its
base type. `local b?: integer = e` is equivalent to `local b: integer? = e`.

A mutable `local` may omit its initializer only when every declared name has
an explicit type that admits a missing `nil` representation: `nil`, `value`,
an Option `T?`, or a nullable C pointer. The compiler initializes each slot to
typed `nil`. Truthiness does not make `boolean` nil-admitting, and numeric,
string, container, and nominal types require an initializer:

```text
-- compile error: boolean does not admit missing nil
local ready: boolean

-- compile error: integer requires an initializer
local count: integer

-- compile error: no initializer to infer type from
local inferred
```

### `const` locals

Read-only block locals are declared with `const` or `local const` (the two
spellings have identical block-local semantics). `const` applies to every name
in the declaration list and always requires an initializer expression list:

```text
-- compile error: const local requires an initializer
const missing: string?
```

A `const` local cannot be reassigned afterward, including from a capturing
closure. Constness is shallow: it prevents rebinding the variable, not
mutating the contents of a referenced Map, mutable Array, or record. (For
`const` module variables, record fields, Interface fields, and `const { T }`
Arrays, see [Chapters 6, 7, 9, and 13](arrays-maps.md); C pointee `const`
qualifiers are governed by [Calling C](ffi.md).)

Because newly declared names enter scope only after the whole declaration,
shadowing with `const` can force and lock an earlier optional local, as
`const name = name` does above.

### Multiple declarations

One `local` or `const` statement may declare several names at once. Only the
last expression on the right-hand side expands (whether a multi-return call,
flexible return, `...`, or spread); earlier calls contribute one value.
Surplus values are discarded, while a fixed-only deficit is a compile-time
error. Each name in the list may carry its own `?` marker, and initializers
evaluate in the outer scope before any of the new names become visible:

```titan
local function divmod(a: integer, b: integer): (integer, integer)
    return a // b, a % b
end

function split_and_step(step: integer): (integer, integer, integer)
    local quotient, remainder = divmod(17, 5)
    local step = step + 1             -- right-hand side reads the parameter
    return quotient, remainder, step
end
```

## Assignment

An assignment target must be a variable name, an Array or Map element `t[k]`,
a record field `r.f`, or an exported module variable `mod.x`. Parentheses
around a target (`(x) = 1`) are a syntax error.

Titan has no ambient global variables: assigning to an undeclared name is a
compile-time error. Assignment also rejects functions, modules, `const`
locals, `const` module variables outside their owning root initializer,
`const` record or Interface fields, and elements of `const { T }` or
`const? { T }` Arrays.

Multiple targets may be assigned in one statement:

```titan
record Point
    x: float
    y: float
end

function swap_and_move(items: {integer}, point: Point)
    local left, right = 1, 2
    left, right = right, left
    items[left], items[right] = 20, 10
    point.x, point.y = point.y, point.x
end
```

Every assignment—single or multiple—executes in three ordered phases:

1. Evaluate and freeze all effectful target components left to right (for
   `t[k]`, container then key; for `r.f`, the receiver).
2. Evaluate all right-hand-side expressions left to right into temporaries.
3. Validate and commit each store left to right.

Because all targets and right-hand values are evaluated before any store runs,
swaps such as `left, right = right, left` work without temporary variables and
side effects in right-hand expressions do not alter frozen targets. If a store
raises (for example, an invalid Array index), earlier stores remain committed
and later stores do not execute.

Multiple assignment uses the same expression-list rules as multiple
declarations: only the final right-hand expression expands, surplus values are
ignored, fixed-only deficits are compile-time errors, and flexible producers
fill finite targets with `T?`.

## Conditional branching: `if`

`if` follows Lua's syntax with any number of `elseif` clauses and an optional
`else`, each forming its own lexical block:

```titan
record User
    name: string
end

function sign(n: integer): integer
    if n > 0 then
        return 1
    elseif n < 0 then
        return -1
    else
        return 0
    end
end

function display_name(users: {User}, index: integer): string
    local user? = users[index]
    if not user then
        return "guest"
    end
    return user.name -- automatic option unwrap; no cast needed
end

function enabled_by_default(flag: boolean?): boolean
    if flag == nil then return true end
    return flag
end
```

Conditions accept an expression of any type using Lua truthiness: `nil` and
`false` are falsy, and everything else—including `0`, `0.0`, and `""`—is
truthy. Conditions do **not** narrow the static type of a variable inside the
branch. Instead, field reads, method calls, and typed sinks unwrap options
automatically, so after guarding against `nil` you use the variable directly
(`user.name`) without a cast. Use `== nil` or `~= nil` whenever a present
value can itself be falsy, as with `boolean?`.

For multi-way dispatch on a tagged union, Titan provides `case ... when ...
else ... end` (see [Tagged Unions and Pattern Matching](unions.md)). Each
`when` and `else` arm is an independent block with its own scope, `defer`, and
`catch`; `case` does not fall through and is not a loop.

## `while` and `repeat`

`while` tests its condition before each iteration and creates a fresh body
scope on each pass. `repeat ... until` executes its body at least once and
stops when the `until` condition is truthy. Both conditions accept any type
under Lua truthiness—remember that `0` is truthy, so `while n do` does not
stop when `n` reaches `0`.

As in Lua, the `until` expression is evaluated inside the scope of the loop
body, so it can read locals declared in the body:

```titan
function first_present(items: {integer}): integer?
    local index = 1
    while index <= #items and not items[index] do
        index = index + 1
    end
    if index <= #items then return index end
    return nil
end

function count_down(start: integer): integer
    local steps = 0
    local remaining = start
    repeat
        remaining = remaining - 1
        steps = steps + 1
        local finished = remaining <= 0
    until finished -- until sees locals declared inside the loop body
    return steps
end
```

## Numeric `for`

The numeric `for` loop steps a read-only `integer` or `float` control variable
over a closed range: `for v [: type] = start, limit [, step] do ... end`. The
step defaults to `1` for `integer` and `1.0` for `float`.

```titan
function sum_elements(values: {integer}): integer
    local total = 0
    for i = 1, #values do
        total = total + (values[i] or 0)
    end
    return total
end

function half_step_total(): float
    local total = 0.0
    for x: float = 1.0, 10.0, 0.5 do
        total = total + x
    end
    return total
end
```

Key rules for numeric `for`:

- Without a type annotation, the control variable's type is inferred from
  `start` and must be `integer` or `float`.
- Bounds are checked **strictly** against the control variable's type: Titan
  does not implicitly convert `integer` bounds to `float` here. Option bounds
  unwrap automatically with a runtime nil check.
- `start`, `limit`, and `step` evaluate once before the loop in the enclosing
  scope, so `for i = 1, #i do` reads an outer `i`.
- The control variable is scoped to the loop body and read-only; assigning to
  it is a compile-time error.
- A step of `0` raises a runtime error. Integer loops bound their iteration
  count so `for i = 1, math.maxinteger` terminates without wrapping.

## Generic `for`

Generic `for` (`for decllist in explist do ... end`) iterates using an
explicit four-slot iterator tuple. The expression list after `in` evaluates
once and adjusts to four positions:

| Slot | Meaning |
| --- | --- |
| 1 | Iterator function (required) |
| 2 | Invariant state value |
| 3 | Initial control value |
| 4 | Optional close function |

Missing slots receive `nil`, and surplus values are evaluated and ignored. A
trailing multi-return call, flexible return, `...`, or spread can supply the
tuple directly.

```titan
local fs = import "fs"
local iteration = import "iteration"

local function step(limit: integer, current: integer): integer?
    if current >= limit then return nil end
    return current + 1
end

function sum_to(limit: integer): integer
    local total = 0
    for n in step, limit, 0 do
        total = total + n
    end
    return total
end

function count_nonempty(items: {string}): integer
    local present = 0
    for _, item? in iteration.ipairs(items) do
        if item and #item > 0 then
            present = present + 1
        end
    end
    return present
end

local function next_line(file: fs.File): string?
    return file:read_until("\n", true)
end

local function close_file(file: fs.File)
    file:close()
end

function file_lines(path: string):
        (function (fs.File): (string?), fs.File, nil, function (fs.File): ())
    local file = fs.open(path, "r")
    return next_line, file, nil, close_file
end

function count_lines(path: string): integer
    local count = 0
    for _ in file_lines(path) do
        count = count + 1
    end
    return count
end
```

The iterator protocol follows four rules:

- **Iterator calls.** The iterator must be a non-variadic function (or a
  `value` or eligible C function pointer) taking zero, one, or two fixed
  parameters, called as `next()`, `next(state)`, or `next(state, control)`.
  For a `value` iterator, Titan synthesizes its parameter types from non-`nil`
  state and control slots and its return types from the loop variables (with
  the first return nil-capable).
- **Stopping condition.** The iterator's first return value is the control
  value and must have a nil-capable type (`T?`, `value`, or nullable C
  pointer; plain `nil` and non-nilable types such as `integer` are rejected).
  The loop stops **only** when that first result is `nil` (or `NULL`). A
  `false` control value runs the loop body normally.
- **Loop variables.** Loop variables are scoped to the body, fresh on each
  iteration, and read-only. The first variable receives the forced non-`nil`
  control value; later variables follow ordinary local inference (use a
  trailing `?` to preserve an option, as in `item?` above). Any loop variable
  beyond the iterator's declared returns must be explicitly annotated with a
  nil-admitting type.
- **Guaranteed close.** Slot 4 may be `nil`, a zero- or one-parameter close
  function (receiving `state` when it takes one parameter; any return values
  are discarded), a `value` (runtime `nil` skips closing; non-`nil` must be
  callable), or an eligible C function. Once the tuple is produced, the close
  function runs when the loop finishes normally, exits via `break` or
  `return`, or unwinds from an error in the iterator or body. If the close
  function raises, its error replaces the pending exit or error. Errors raised
  while evaluating the factory expression before the tuple is returned occur
  outside the loop's close region.

Bound nil-terminated methods work directly as zero-argument iterators—for
example, `for chunk in reader:read do ... end` reads until `read` returns
`nil`.

## Call statements, `return`, and `break`

Only function and method calls are valid as expression statements; all fixed
and flexible results of a call statement are discarded.

`return` exits the enclosing function and must appear as the **last**
statement of its block (optionally followed by `;`).

- In a zero-return function (one with no return annotation or `: ()`), bare
  `return` exits with no values, and falling off the end is allowed. Writing
  expressions after `return` evaluates them for their side effects and
  discards their values.
- In an explicit `: nil` function, bare `return` or falling off the end
  returns one `nil`.
- In every other fixed-result function, every declared return position must be
  supplied (surplus expressions evaluate and are discarded), and every
  reachable control path must end in `return`, `raise`, or a non-fallthrough
  construct. Non-fallthrough analysis recognizes complete `if`/`elseif`/`else`
  chains, exhaustive `case` statements over a closed union (or with a
  terminating `else`), and literal `while true` loops with no reachable
  `break` and no falling-through enclosing `catch`.
- A function returning only a flexible tail `(...: T)` may fall off the end or
  use bare `return` to return zero values.

`break` exits the innermost enclosing loop (`while`, `repeat`, numeric `for`,
or generic `for`). Using `break` outside a loop is a compile-time error. A
`case` statement is not a loop, so a `break` inside a `when` arm exits the
enclosing loop.

```titan
local total_calls = 0

function record_call(delta: integer)
    if delta <= 0 then
        return
    end
    total_calls = total_calls + delta
end

function first_positive(values: {integer}): integer
    local found = 0
    for i = 1, #values do
        local current? = values[i]
        if current and current > 0 then
            found = current
            break
        end
    end
    return found
end
```

Resource cleanup and error propagation use `defer` and `raise` (see
[Errors and Resource Cleanup](error-handling.md)). The keywords `goto` and
`finally` are reserved by the lexer and have no statement forms in Titan.
