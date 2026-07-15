# Statements

Titan's statements are a subset of Lua's, with the same surface syntax,
plus static checking. This chapter covers blocks and scoping, local
declarations, assignment (including multiple assignment), the control-flow
statements (`if`, `while`, `repeat`, numeric `for`, and generic
`for ... in`), function calls in statement position, `defer`, `raise`, and
`return`. For the expressions that appear inside statements see
[Expressions](expressions.md); for the typing rules they trigger see
[The type system](types.md); for the full statement grammar see
[Grammar](grammar.md).

## Blocks, scope, and semicolons

A *block* is a sequence of statements optionally ended by a single
`return` statement. Function bodies are blocks, as are the bodies of
`while`, `repeat`, `for`, and each arm of an `if`. A free-standing block
can be written with `do ... end`:

```lua
function f(): integer
    local x = 10
    do
        local x = 20   -- shadows the outer x until 'end'
    end
    return x           -- 10
end
```

Scoping is lexical, as in Lua: every block opens a new scope, and a local
declaration is visible from the statement *after* its declaration to the
end of the enclosing block. Shadowing an outer variable (or even an
earlier variable in the same block) is allowed and not diagnosed. As in
Lua, a lone semicolon is an empty statement, and statements need no other
separator.

Any block may have `catch` and/or `finally` trailers. These are Titan's
error-handling construct; there is no `try` keyword. The body, catch, and
finally are sibling scopes, and the catch has implicit `error: value` and
`traceback: string` locals. Those catch locals are read-only snapshots.
See [Error handling](error-handling.md).

Unused variables are not an error or a warning. The compiler notices
variables that are never read and simply omits storage for them — the
initializer is still evaluated for its effects. The name `_` has no
special meaning in Titan; it is an ordinary identifier that is
conventionally used for values you want to discard:

```lua
local x, _ = f()   -- keep the first result, ignore the second
```

## Local declarations

A local variable is declared with `local`, an optional type annotation,
and a mandatory initializer:

```lua
local x: integer = 10
local s = "hello"        -- type inferred: string
```

Unlike Lua, a declaration *must* have an initializer — `local x: integer`
by itself is a compile-time syntax error (`Expected '=' after variable
declaration.`). There is no implicit `nil` default; if you want a variable
that starts out as "no value yet", give it an
[option type](option-types.md) and initialize it with `nil`:

```lua
local found: string? = nil
```

When the annotation is omitted the type is inferred from the initializer.
Inference never produces an option type: if the initializer is an option
(for example an array read, which has type `T?`), it is implicitly
unwrapped, with a run-time check, and the variable gets the base type. Ask
for an option explicitly by writing `?` after the name:

```lua
local xs: {integer} = {1, 2, 3}
local a = xs[1]    -- a: integer  (run-time error if xs[1] is nil)
local b? = xs[1]   -- b: integer? (nil is fine)
```

`local b?: integer = e` is also accepted and means the same as
`local b: integer? = e`. The full inference and coercion rules are in
[The type system](types.md); the initializer is implicitly coerced to the
annotated type wherever the types allow it (so
`local n: float = 1` works), and otherwise the declaration is a
compile-time error of the shape
`test.titan:1:1: type error: types in declaration of local variable n do
not match, expected float but found string`.

A single `local` can declare several variables at once:

```lua
local x, y = 10, 20
local q, r = divmod(17, 5)   -- a multi-return call in last position
```

A call in the *last* right-hand-side position may expand to fill the remaining
names; any earlier call is scalar. Producer surplus is ignored, while a
fixed-only deficit is rejected at compile time with `left-hand side expects N
value(s) but the expression list produces M`. A declared flexible result tail
can fill finite positions with projected option values instead. Wrapping a call
in parentheses requests one value (see [Functions](functions.md)); a
parenthesized call that leaves a multi-name declaration short
(`local a, b = (f())`) gets the same clean deficit error.

The declared names only enter scope after the whole statement, so the
initializers see the *outer* bindings:

```lua
function f(x: integer): integer
    local x = x + 1   -- the x on the right is the parameter
    return x
end
```

The bare-`?` option-inference marker is honored for every name in a
multi-declaration, including names filled from the extra results of a
trailing multi-return call (`local a, b? = f()` gives `b` an option type).

## Assignment

An assignment target (lvalue) is a variable name, an array or map element
`t[k]`, a record field `r.f`, or an exported module variable `mod.x`.
Parentheses are not allowed around a target — `(x) = 42` is a syntax
error.

```lua
x = x + 1
xs[i] = v
p.x = 2.0
```

Assignments are type-checked: the right-hand side is implicitly coerced to
the target's type where the [coercion rules](types.md) allow, and
otherwise the assignment is a compile-time error (`types in assignment do
not match, expected T but found U`). Assigning to an undeclared name is a
compile-time error (`variable 'y' not declared`) — Titan has no global
variables; module-level variables must be declared at the top level (see
[Modules](modules.md)). Functions and modules are not assignable: `f = 2`
where `f` is a function is the compile-time error `trying to assign to a
function`.

## Multiple assignment

Several targets can be assigned in one statement:

```lua
x, y = y, x                  -- swap
arr[1], arr[2] = 4, 2        -- element targets
x, foo.a = 2, 5              -- 'foo' is an imported module
q, r = divmod(17, 5)         -- multi-return call expands
```

The semantics are two-phase, matching Lua: **all** right-hand-side values
are evaluated first, left to right, into temporaries; only then are the
stores performed, left to right. This is what makes the swap idiom work.
(Any expressions inside the *targets* — the table and index of `t[k]`, the
receiver of `r.f` — are evaluated in the second phase, with the stores.)

The same finite-demand rules as multi-declarations apply: a trailing call may
fill the remaining targets, earlier calls are scalar, and `(f())` requests one
value. Producer surplus is ignored; an ordinary fixed-only deficit remains an
error. The conventional `_` name is useful when code wants to document a
discarded position explicitly, but it is not required merely to hide trailing
results. A flexible producer projects `T?` into positions reached beyond its
fixed prefix; see [Flexible returns](flexible-returns.md).

## `if`

`if` has the same shape as in Lua, with any number of `elseif` arms and an
optional `else`:

```lua
function sign(x: integer): integer
    if x > 0 then
        return 1
    elseif x < 0 then
        return -1
    else
        return 0
    end
end
```

The condition may be an expression of any type, with Lua's truthiness
rules: `false` and `nil` are false, everything else is true. In
particular, an option-typed condition tests whether the value is `nil` —
the idiomatic way to check an array read:

```lua
function get(xs: {integer}, i: integer): integer
    if xs[i] then
        return xs[i]
    else
        return 0
    end
end
```

Note that a condition whose type can never be `nil` or `false` (an
`integer`, a `string`, an array...) is statically always true; the
compiler accepts it without complaint. How conditions influence the typing
of `and`/`or` inside them is described in [Expressions](expressions.md).

Each arm's block is its own scope. The same any-type, Lua-truthiness rule
applies to `while` and `repeat`/`until` conditions.

## `while`

```lua
function first_set(t: {integer}): integer
    local i = 1
    while not t[i] do   -- loop while t[i] is nil
        i = i + 1
    end
    return i
end
```

The condition is evaluated before each iteration. The body is a new scope,
re-entered on each iteration. The condition may be of any type, with Lua's
truthiness rules — an option-typed condition (`while t[i] do`) tests
whether the value is `nil`, and a numeric condition is always truthy
(`while n do` does not exit when `n` reaches `0`, since `0` is truthy in
Lua). (Note that comparing an option against `nil` with `==`/`~=` is itself
a compile-time error — `trying to compare values of incomparable types:
integer? and nil?` — so the `not`/`if` forms are the way to test for a
missing element.)

## `repeat` / `until`

```lua
function count_down(n: integer): integer
    local steps = 0
    repeat
        n = n - 1
        steps = steps + 1
    until n <= 0
    return steps
end
```

The body runs at least once, and the loop exits when the `until` condition
is true. As in Lua, the condition is scoped as part of the loop body, so
the condition may refer to locals declared inside the body — for example,
the loop above could end with `local done = n <= 0` followed by
`until done`.

## The numeric `for`

Titan has Lua's numeric `for`:

```lua
function sum_list(xs: {integer}): integer
    local sum: integer = 0
    for i = 1, #xs do
        sum = sum + xs[i]
    end
    return sum
end
```

The full form is `for v = start, limit, step do ... end`; the step is
optional and defaults to `1` (or `1.0` for a float loop). The control
variable may carry a type annotation (`for i: integer = 1, 10 do`), and
must be of type `integer` or `float` — anything else is the compile-time
error `type of for control variable v must be integer or float`. Without
an annotation its type is inferred from the `start` expression. Float
loops work the same way with float bounds:

```lua
local n = 0.0
for i = 1.0, 10.0, 0.5 do
    n = n + i
end
```

The bound expressions are checked *strictly* against the control
variable's type: this is one of the few places where Titan applies no
implicit numeric coercion, so an integer `start` with a `float` control
variable (or vice versa) is a compile-time error (`types in 'for' start
expression do not match, expected float but found integer`). Option-typed
bounds are implicitly unwrapped with a run-time nil check. The bound
expressions are evaluated once, before the loop, and they see the
enclosing scope — the control variable does not shadow them
(`for i = 1, #i do` is legal when an outer `i` exists).

The control variable is scoped to the loop body and is read-only, as in
Lua 5.4+: assigning to it inside the body is a compile-time error
(`cannot assign to 'for' control variable`).

A step of zero is a run-time error (`'for' step is zero`), as in Lua.
Integer loops are Lua-faithful at the integer limits: the number of
iterations is bounded so that `for i = 1, math.maxinteger` terminates
rather than wrapping the counter past the maximum integer.

## The generic `for ... in`

Titan's generic `for` iterates with an explicit iterator tuple:

```lua
function step(limit: integer, n: integer): integer?
    if n >= limit then
        return nil
    else
        return n + 1
    end
end

function sum_to(limit: integer): integer
    local sum = 0
    for n: integer in step, limit, 0 do
        sum = sum + n
    end
    return sum
end
```

The syntax is `for decllist in explist do ... end`. The expression list is
evaluated once before the loop and adjusted to a four-slot iterator tuple:

| Slot | Meaning |
| --- | --- |
| 1 | iterator function, required |
| 2 | state/context value |
| 3 | initial control value |
| 4 | close function |

Missing slots are filled with `nil`; values beyond the four tuple slots are
evaluated and ignored. A trailing multi-return expression, flexible result
run, or trailing `...` in a variadic function can fill the tuple, so a helper
may return `(next, state, init, close)` directly. Finite positions projected
from a flexible result are optional; the required iterator slot is forced
before it is resolved as callable.

The iterator slot may be a function, a `value` that is coerced to a
synthesized function type, or a compatible C function pointer/foreign
function. The iterator cannot be variadic and may take zero, one, or two
fixed parameters. A two-parameter iterator is called as
`next(state, control)`: first with the initial control value, then after
each body execution with the previous first result. A one-parameter
iterator is called as `next(state)`, and a zero-parameter iterator as
`next()`.

When the iterator slot has type `value`, Titan synthesizes the function type
from the tuple and declaration list. The parameter types come from the
non-`nil` state and initial-control slots. Return types come from the
visible declarations: an annotated declaration contributes its annotation,
and an unannotated one contributes `value`. The first synthesized return is
made nil-capable so it can stop the loop.

The iterator must return at least one value. Its first return value is the
loop control value and must be an option type, `value`, or a nullable C
pointer. A plain `nil` return type and non-nil-capable return types such as
`integer` are rejected. The loop stops only when that first returned value is
`nil` (or `NULL` for C pointers). False values do **not** stop the loop:

```lua
function flags(_: nil): boolean?
    -- returning false here still runs the loop body
end
```

On each iteration, Titan initializes the visible declaration list from the
iterator returns. The first declaration is initialized from the forced
control value; later declarations use later iterator returns. If the
iterator returns fewer values than the declaration list needs, the missing
values are `nil`, but only annotated declarations can receive them:
`for x: integer, y: string? in step do` is legal when `step` returns only
the first value, while `for x, y in step do` cannot infer `y`'s type.
Generic `for` variables are scoped to the body, fresh per iteration, and
read-only, like numeric `for` variables.

The close slot is `nil`, a function, a `value` that is coerced to a
synthesized close function type, or a compatible C function pointer/foreign
function. A close function may accept zero or one fixed parameter; when it
accepts one, the state value must be coercible to that parameter type. Close
return values are discarded. When present, the close function runs after
normal exhaustion, `break`, `return`, and errors from the initial iterator
call, body, or update iterator call. If close itself raises, that new error
replaces the pending action.

This helper returns the whole tuple, including a close function that receives
the file state:

```lua
function numbered_lines(filename: string):
        ((File, integer) -> (integer?, string?), File, integer, (File) -> ())
    local file: File = File.open(filename)
    local next = function (f: File, line_no: integer): (integer?, string?)
        local line? = f:read_line()
        if line == nil then
            return nil, nil
        else
            return line_no + 1, line
        end
    end
    local close = function (f: File): ()
        f:close()
    end
    return next, file, 0, close
end

for line_no: integer, line: string in numbered_lines("input.txt") do
    process(line_no, line)
end
```

If the iterator and closer are method closures that already capture the file,
no state value is needed:

```lua
function lines(filename: string): (() -> string?, nil, nil, () -> ())
    local file: File = File.open(filename)
    return file:read_lines, nil, nil, file:close
end

for line: string in lines("input.txt") do
    process_line(line)
end
```

## Function calls as statements

A function or method call may stand alone as a statement; all of its fixed and
flexible results are discarded:

```lua
xs_push(xs, 10)
p:move(2.0, 3.0)
```

Only calls are valid as expression-statements. Any other expression in
statement position — `(f)`, `1 + 1` — is a compile-time syntax error:
`Expected a statement but found an expression that is not a function
call.`

## `raise`

`raise <exp>` raises a new run-time error with the expression coerced to
`value`:

```lua
raise "bad input"
raise { "structured", "error" }
```

A bare `raise` is a re-raise and is legal only inside a `catch` block; it
preserves the original caught error value and traceback. Outside a catch,
bare `raise` is a compile-time error. `raise` always terminates the
current control-flow path, like `return` for the purpose of checking that
a function with return values always returns. Full propagation and
`finally` semantics are in [Error handling](error-handling.md).

## `defer`

`defer <statement>` schedules a statement to run when the rest of the
current statement-list finishes. It is equivalent to wrapping the rest of
that `simpleblock` in a `do ... finally ... end` block:

```lua
defer cleanup()
body()
return result()
```

behaves like:

```lua
do
    body()
    return result()
finally
    cleanup()
end
```

The deferred statement runs on normal fallthrough, `return`, `break`, or
a propagating error. If the deferred statement raises, that new error
overrides the pending action exactly like a `finally` raise. Fixed return
values and any run-time flexible tail are evaluated and saved before the
deferred statement runs, so cleanup side effects do not change them.

Multiple defers in the same block run in last-in-first-out order:

```lua
defer first()
defer second()
work()
-- execution order on exit: work, second, first
```

The deferred statement is checked in the scope where the `defer` appears.
It can read and assign locals that are already in scope, but it cannot see
locals declared later in the rest of the block. A `defer` inside a loop
body is installed for that iteration's body and runs before the iteration
leaves the body.

The statement after `defer` may not itself be another `defer` statement.
Write two separate defers for LIFO cleanup, or use `defer do ... end` to
defer multiple statements:

```lua
defer do
    flush()
    close()
end
```

Because `defer` lowers to `finally`, the same control-transfer limits
apply to the deferred statement: it may not `return`, and a `break` inside
it may only target a loop written inside that deferred statement. See the
full [Defer](defer.md) chapter for details.

## `return`

`return` ends the function, supplying its return values:

```lua
function divmod(a: integer, b: integer): (integer, string)
    return a // b, "ok"
end
```

Like in Lua, `return` may only appear as the **last** statement of a
block — of the function body, or of any inner block such as an `if` arm or
a loop body. A statement after a `return` in the same block is a syntax
error. An optional `;` may follow the statement.

`return` is forbidden inside a `finally` block, because explicit control
transfer out of cleanup would otherwise override a pending return, break,
or error. Use a normal fallthrough from finally, or raise a new error if
cleanup failure should replace the pending action. This restriction applies
to the finally block's own statements; a nested anonymous function defined
inside a finally has its own body and may return normally from that nested
function.

Every fixed declared return position must be filled, or the checker reports
`returned N value(s) but function expected M`. Each delivered value is
implicitly coerced to the corresponding declared type where the coercion rules
allow; mismatches are reported per position (`types in return do not match,
expected integer but found string`). Surplus expressions are still evaluated
but their values are discarded. A trailing call expands only as far as the
finite return prefix requires, unless the function declares a flexible tail,
which consumes the complete compatible run. `return (f())` always requests one
value. See [Functions](functions.md) and
[Flexible returns](flexible-returns.md).

A function declared without a return annotation returns **zero** values
(its type is `() -> ()`), matching Lua — not one `nil`. Such functions need
no `return` at all, and falling off the end is allowed.

In a zero-return function a completely bare `return` is the clearest spelling,
but expressions are also permitted: they are evaluated for their effects and
their values are discarded. The function still exposes zero results:

```lua
local count: integer = 0

function bump(n: integer)    -- no annotation: returns zero values
    if n <= 0 then
        return               -- bare return: no values
    end
    count = count + n
end
```

`return` and `return nil` still describe different expression lists, but a
zero-return function discards the latter's `nil` and exposes no values. In an
explicit `: nil` function, either spelling supplies the one `nil` return. In
option- or `value`-returning functions, write `return nil` explicitly. The
explicit `: nil` annotation is how you ask for a function that returns a
single `nil`.

A function whose first fixed return exists and is not `nil` must provably
return on every control path; otherwise the compiler rejects it. A
nil-returning function, a zero-return function, and a function with only a
flexible tail may instead fall off the end; the last case produces an empty
run. The analysis understands `if`/`elseif`/`else` chains where every arm
returns, but it does not credit loops — a `return` inside a `while` body
does not count as "always returns".

## `break` (no `goto`)

`break` exits the innermost enclosing loop — a `while`, `repeat`,
numeric `for`, or generic `for` — exactly as in Lua:

```lua
function first_positive(xs: {integer}): integer
    local r = 0
    for i = 1, #xs do
        if xs[i] > 0 then
            r = xs[i]
            break
        end
    end
    return r
end
```

A `break` that is not inside any loop is the compile-time error
`'break' outside a loop`.

`goto` and `::label::` syntax are recognized by the lexer but have no
statement form, so using them is a syntax error.
