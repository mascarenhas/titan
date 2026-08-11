# Anonymous functions and closures

Titan has anonymous function expressions — lambdas — that capture the
local variables of the function around them. A lambda is an ordinary
[function value](functions.md#functions-as-values): the same first-class
machinery applies, so it can be stored, passed, returned, called through
either path, and crossed to and from Lua. What this chapter adds on top of
that is the *expression* form, the type **inference** that lets you leave
its annotations off, and the **lexical capture** of enclosing variables.

```lua
function make_counter(): () -> integer
    local n = 0
    return function (): integer
        n = n + 1
        return n
    end
end
```

```lua
-- Lua
local m = require "counter"
local c = m.make_counter()
print(c(), c(), c())   --> 1   2   3
```

Each call to `make_counter` produces an independent counter: the returned
lambda keeps a reference to that call's `n`, increments it on every call,
and the value persists between calls because the lambda holds the variable
alive after `make_counter` has returned.

## Syntax

A function expression is a top-level function declaration minus the name
and `local`, and with **optional** parameter and return annotations:

```
function (p1[: T1], …, pn[: Tn]) [: rettype] <block> end
```

The parameter list may end in an input `...: T` (or a context-inferred bare
`...`), and a parenthesized return annotation may end in a flexible result
tail such as `: (...: R)` or `: (R1, ...: R)`. See
[Variadic parameters](variadic-parameters.md) and
[Flexible returns](flexible-returns.md).

It is an expression, so it appears wherever an expression may: as a
declaration or assignment right-hand side, a call argument, a `return`
value, a record/union-constructor or array/map element, and so on.

```lua
local g = function (x: integer): integer return x + 1 end   -- in a local
apply(function (x): integer return x * 3 end, 14)            -- as an argument
return function (): integer return 42 end                   -- as a return value
```

A lambda is a *simple* expression, not a prefix expression, so it cannot
be **called directly**: `function () … end(x)` is a syntax error. Wrap it
in parentheses to apply it immediately — `(function () … end)(x)` — exactly
as Lua requires for an immediately-invoked function expression.

The body block follows the same rules as any function body, including the
*return-on-every-path* rule for a value-returning lambda (see
[Functions](functions.md)).

> **A note on nesting depth.** The parser caps deeply nested lambdas at
> roughly seven levels (an LPeg sub-capture limit); going past that is a
> parse error. Real code never approaches it.

## Parameter inference and return annotations

Lambda parameter annotations are optional when an **expected function type** is
available—the type of the slot the lambda flows into, whether that is an
assignment target, an argument position, or a `return`. Return annotations obey
the ordinary function rule instead: omitting one always means zero results,
independent of context. Neither parameter nor result types are inferred from the
lambda body.

**Parameter types.** An annotated parameter uses its annotation. An
*unannotated* parameter is filled in from the expected function type:

```lua
function f(): integer
    -- x comes from g's annotation; the result is written explicitly
    local g: (integer) -> integer = function (x): integer return x + 1 end
    return g(2)
end

function apply(g: (integer) -> integer, x: integer): integer
    return g(x)
end

function use(): integer
    -- y comes from apply's first parameter
    return apply(function (y): integer return y + 1 end, 5)
end
```

If an unannotated parameter has no usable context—there is no expected function
type to read it from—it is a clean compile-time error:

```lua
function f(): integer
    local g = function (x) return x end   -- compile-time error
    return 1
end
```

```
test.titan:2:30: type error: cannot infer type of parameter 'x'
```

Annotate the parameter, or use the lambda where its parameter type is known.

**Return shape.** An explicit fixed or flexible return annotation is used as
written. Without one, the lambda has the **zero-return** shape `()` even when an
expected function type is available. This is exactly the rule for a named
function:

```lua
function f(): integer
    local zero: (integer) -> () = function (x) end
    local one: (integer) -> integer =
        function (x): integer return x + 1 end
    local pair: (integer) -> (integer, integer) =
        function (x): (integer, integer) return x, x + 1 end
    local many: () -> (...: integer) =
        function (): (...: integer) return 1, 2, 3 end
    zero(1)
    return one(2)
end
```

The default applies whether or not the body contains a `return`. Expressions in
such a `return` are evaluated for their effects, but their values are discarded
instead of becoming inferred results:

```lua
function f(): integer
    local g = function (x: integer) return x + 1 end
    g(4) -- g is (integer) -> (); x + 1 was evaluated and discarded
    return 1
end
```

A context may still apply ordinary callable adjustment after the lambda has
acquired that zero-result source type. For example, a zero-result callback can
flow directly to `() -> value`: the adjusted view supplies the missing `nil`
result. A target requiring a non-nilable result such as `integer` is rejected.
See [Callable adjustment wrappers](closure-adjustment-wrappers.md).

To give a lambda any nonzero or flexible return shape, write the return
annotation explicitly.

## Capturing enclosing locals

A lambda may use the locals and parameters of the function(s) around it.
This *just works* — no explicit capture list, no special syntax — and it
follows the same lexical scoping as Lua:

```lua
function make_adder(k: integer): (integer) -> integer
    local base = k * 10                  -- a local of make_adder
    return function (x: integer): integer
        return base + x                  -- base is captured from make_adder
    end
end
```

A few details worth knowing:

* **Mutating a captured variable is shared.** If the lambda *assigns* to a
  captured variable, the change is visible to the enclosing function and to
  every other lambda that captured the same variable — they all refer to
  one mutable cell. The counter at the top of this chapter relies on this.
* **A captured variable that is never reassigned** behaves like an
  immutable snapshot. In a loop, each iteration's lambda captures *that
  iteration's* value, so loop-created closures are independent:

  ```lua
  function make_closures(): {(integer) -> integer}
      local fns: {(integer) -> integer} = {}
      local i = 1
      while i <= 3 do
          local captured = i                 -- a fresh local per iteration
          fns[i] = function (x: integer): integer
              return captured * 100 + x
          end
          i = i + 1
      end
      return fns
  end
  -- fns[1](7) == 107, fns[2](7) == 207, fns[3](7) == 307
  ```

* **Shadowing works as expected.** A local declared *inside* the lambda
  with the same name as an outer one shadows it and is not a capture.
* **Module-level names are not captures.** Module variables, imported
  modules' members, top-level functions, and record/union functions are reached
  directly, exactly as they are from any function body; they are not part
  of the lambda's capture.
* **Capture is transitive.** A lambda nested two or three levels deep can
  use a variable from an outer function it is not directly inside; the
  variable is threaded down through the intervening lambdas. Mutable
  captures stay shared all the way down; immutable ones are copied down.
* **Captured strings, arrays, records, unions, Interfaces, and other heap values** are captured
  and kept alive correctly across garbage collection, whether by value or
  shared-and-mutable.

## Each lambda evaluation is a fresh value

Evaluating a `function … end` expression produces a **new** function value
every time control reaches it — there is no caching and no stable
identity. This is what makes the two counters above independent, and it
defines what equality means for lambdas:

* the *same* evaluated closure compares equal to itself (`f == f`);
* two distinct evaluations of the same `function … end` text are distinct
  objects, and so are **not** equal.

Equality on function values is object identity (raw closure-pointer
comparison), the same rule that applies to any function value
([functions](functions.md#functions-as-values)).

This fresh lambda is the **source closure**. An exact target-typed use preserves
it. Evaluating an admitted non-exact Function-to-Function edge may, when the
run-time value is an eligible exact Titan closure, create another fresh
[target-tagged adjustment wrapper](closure-adjustment-wrappers.md). That wrapper
is unequal to the lambda and to a wrapper from another evaluation; an
ineligible generic fallback preserves the lambda's identity. Wrapper allocation
does not re-evaluate the lambda expression or its capture expressions.

## Recursion: a lambda cannot name itself

A lambda bound to a `local` cannot refer to itself by that name, because
the name only comes into scope *after* its initializer is checked — just
as `local x = x` reads an outer `x`, not the one being declared. A
self-reference is therefore a clean "not declared" compile-time error, not
a silent miscompile:

```lua
function g(): integer
    local f: (integer) -> (integer) = function (n: integer): integer
        return f(n)     -- compile-time error: variable 'f' not declared
    end
    return 1
end
```

For a recursive helper, write a named top-level function (recursion and
mutual recursion among top-level functions work without forward
declarations — see [Functions](functions.md#recursion-and-declaration-order)).

## Lambdas in module-variable initializers

A lambda is a valid module-variable initializer. Constructing the closure does
not execute its body or read the values mentioned there, so the ordinary
module-initialization frontier remains sound:

```lua
local transform = function (x: integer): integer return x + 1 end

function apply(x: integer): integer
    return transform(x)
end

function replace(f: (integer) -> integer)
    transform = f
end
```

This declares an ordinary function-typed module variable, not a named function.
It is initialized once with a fresh closure, can be reassigned later, and calls
through it use the first-class function path. The usual initializer rule still
rejects an expression that immediately reads a module variable whose value is
not visible at that point. Putting the read of an **already name-visible** module
variable in the lambda body defers its value access until the closure is called;
it does not make a later module variable or import visible.

## Bound method references

A method *named but not called* is a function value with the receiver
bound in. Writing `obj:method` with **no argument list** yields a value
whose type is the method's type with the implicit `self` removed, and
calling that value runs the method on the nominal receiver `obj` was when the
reference was taken:

```lua
record Adder
    base: integer
end

function Adder:add(x: integer): integer
    return self.base + x
end

function use(): integer
    local a = Adder.new(100)
    local f: (integer) -> integer = a:add   -- bound: (integer) -> integer
    return f(5) + f(7)                       --> 105 + 107 == 212
end
```

The receiver expression is evaluated **once**, when the bound source value is
created. The result is an ordinary function value — store it, pass it, return
it, call it through Titan or Lua — with no special handling at the use site. An
exact static view preserves that bound closure; a non-exact callable edge has
the same conditional fresh-wrapper/fallback behavior as any other
[closure adjustment](closure-adjustment-wrappers.md). Because the captured
receiver is a reference,
calling a bound method that mutates record state is visible through the
record:

```lua
record Counter
    n: integer
end

function Counter:bump(): integer
    self.n = self.n + 1
    return self.n
end

function make(): () -> integer
    local c = Counter.new(0)
    return c:bump          -- the receiver c is captured
end
-- the returned value bumps c on each call: 1, 2, 3, …
```

An Interface method can be bound in the same way. The function value captures
the Interface wrapper, uses the Interface method's self-removed type, and
dispatches through that wrapper when called. Like every bound method value, it
is positional-only after binding even though a direct Interface method call can
use the Interface declaration's parameter names.

Restrictions are clean compile-time errors:

* the receiver must be a record, union, or Interface — `n:bump` on another
  type is a receiver-type error;
* the method must exist on that nominal owner;
* a **foreign (C) method** cannot be bound:
  `a foreign (C) method cannot be used as a first[-class value]`.

Bound method references work across modules, including against a dependency
available only through a compiled `.so` or `.a` provider. See
[Records](records.md#methods) for method declaration rules.
Union methods use the same bound-reference path; unlike a record method they
cannot access fields and must inspect `self` with `case`. See
[Unions](unions.md). Interface dispatch and wrapper lifetime are described in
[Interfaces](interfaces.md#calls-and-bound-methods).
