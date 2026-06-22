# Statements

Titan's statements are a subset of Lua's, with the same surface syntax,
plus static checking. This chapter covers blocks and scoping, local
declarations, assignment (including multiple assignment), the control-flow
statements (`if`, `while`, `repeat`, the numeric `for`), function calls in
statement position, `raise`, and `return`. For the expressions that appear inside
statements see [Expressions](expressions.md); for the typing rules they
trigger see [The type system](types.md); for the full statement grammar
see [Grammar](grammar.md).

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

The arities must match exactly: a call in the *last* right-hand-side
position contributes all of its return values, any other call contributes
exactly one, and after that expansion the number of values must equal the
number of names, or the declaration is rejected at compile time with
`left-hand side expects N value(s) but right-hand side produces M
value(s)`. Wrapping a call in parentheses truncates it to one value (see
[Functions](functions.md)); a parenthesized call that leaves a multi-name
declaration short (`local a, b = (f())`) gets that same clean arity error.

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

Arity is strict and checked at compile time, with the same rules and the
same error message as multi-declarations: a multi-return call expands only
in the last right-hand-side position, every other call counts as one
value, and `(f())` truncates to one value. There is no Lua-style silent
padding with `nil` or dropping of extras. To discard a value, assign it to
a variable you never read (conventionally `_`); as described above, unused
variables cost nothing.

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

Titan has Lua's numeric `for` (there is no `for ... in`; `in` is a
reserved word with no construct behind it):

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

## Function calls as statements

A function or method call may stand alone as a statement; its results are
discarded:

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
cleanup failure should replace the pending action.

Arity is strict at compile time: the number of returned values must equal
the number of declared return types, or the checker reports
`returned N value(s) but function expected M`. Each value is implicitly
coerced to the corresponding declared type where the coercion rules allow;
mismatches are reported per position (`types in return do not match,
expected integer but found string`). A multi-return call expands in the
last position, and `return (f())` truncates to a single value — see
[Functions](functions.md) for the full multiple-return story.

A function declared without a return annotation returns **zero** values
(its type is `() -> ()`), matching Lua — not one `nil`. Such functions need
no `return` at all, and falling off the end is allowed.

In a zero-return function a completely bare `return` (zero expressions) is
the **only** legal return. Returning any value — `return nil` included — is
a compile-time error (`returned 1 value(s) but function expected 0`):

```lua
local count: integer = 0

function bump(n: integer)    -- no annotation: returns zero values
    if n <= 0 then
        return               -- bare return: the only legal return here
    end
    count = count + n
end
```

`return` and `return nil` are therefore **not** equivalent. A bare `return`
returns no values; `return nil` returns one value and is only legal in a
function whose return type includes a value — for instance one declared
`: nil` (the explicit one-`nil`-return form), `: integer?`, or any other
type. The explicit `: nil` annotation is how you ask for a function that
returns a single `nil`.

A function whose return type carries one or more values must provably
return on every control path; otherwise the compiler rejects it. (A
nil-returning function, like a zero-return one, may instead fall off the
end.) The analysis understands `if`/`elseif`/`else` chains where every arm
returns, but it does not credit loops — a `return` inside a `while` body
does not count as "always returns".

## `break` (no `goto`)

`break` exits the innermost enclosing loop — a `while`, `repeat`, or
numeric `for` — exactly as in Lua:

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

`goto` and the generic `for ... in` loop are **not** implemented:
`goto`, `in`, and `::label::` syntax are recognized by the lexer but have
no statement form, so using them is a syntax error (and there is no
iterator-based `for`). Where Lua would write `for k, v in pairs(t)`,
iterate with a numeric `for` over the keys or indices instead.
