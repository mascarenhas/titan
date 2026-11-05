# Anonymous functions and closures

Titan has anonymous function expressions — lambdas — that capture the
local variables of the function around them. A lambda is an ordinary
[function value](functions.md#functions-as-values): the same first-class
machinery applies, so it can be stored, passed, returned, called through
either path, and crossed to and from Lua. What this chapter adds on top of
that is the *expression* form, the type **inference** that lets you leave
its annotations off, and the **lexical capture** of enclosing variables.

```titan
function make_counter(): function (): (integer)
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

## Transferring a closure between Lua states

[`TransferValue.from_value(callback)`](async-io.md#transfer-values) snapshots a
Titan function immediately for an independent Lua state or cross-state Receiver.
All immediate captures are projected before any capture's custom hook runs.
Sending the resulting packet later does not observe subsequent origin changes.
The destination loads the recorded owning module through its preload
entry, validates the entry token, and creates a fresh closure over copied
capture values. Module globals belong to the destination module instance.

Mutable captures become fresh cells. An outer closure and nested captured
closures receive independent cells even if they shared a source cell.
Separate conversions and repeated `to_value` calls also form independent
snapshots. Bound concrete methods copy their receiver under the same custom-hook
or protobuf rules as other nominal captures. Callable adjustment preserves its
source callable and target signature.

Every capture must satisfy its selected policy. Cycles, including a closure
that captures itself through a mutable variable, raise during `from_value`.
Direct Arrays, Maps, Interfaces, owned C storage, and local nominal types are
not transferable captures. A public record with private fields may supply
[custom transfer hooks](async-io.md#custom-record-transfer); other records and
unions follow public protobuf rules. A captured `TransferValue` remains its
policy wrapper, including opaque custom-record or closure packet bytes. It is
not implicitly unwrapped into its semantic value.

The Interface restriction applies to bound Interface methods because their
captured receiver is an Interface. Native pointers remain borrowed addresses
with caller-managed lifetime. A pointer to Lua-managed `Udata` is rejected,
including a present optional pointer; an absent optional transfers as `nil`.
The packet retains no source-state closure, mutable box, string, or nominal
heap object. See [transfer values](async-io.md#transfer-values).

Nominal packets carry their actual defining module. Reconstruction queries the
destination registry first, calls the preload loader on a miss, then
retries. This applies to structural protobuf nominals and custom-record
payloads; qualified nominal names are never split to infer their module.

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

```titan
local g = function (x: integer): integer return x + 1 end   -- in a local
apply(function (x) return x * 3 end, 14)                     -- as an argument
return function (): integer return 42 end                   -- as a return value
```

A lambda is a *simple* expression, not a prefix expression, so it cannot
be **called directly**: `function () … end(x)` is a syntax error. Wrap it
in parentheses to apply it immediately — `(function () … end)(x)` — exactly
as Lua requires for an immediately-invoked function expression. Titan
[optimizes this direct immediate call](#immediate-calls-as-expressions) into
an inline block.

The body block follows the same rules as any function body, including the
*return-on-every-path* rule for a value-returning lambda (see
[Functions](functions.md)).

> **A note on nesting depth.** The parser caps deeply nested lambdas at
> roughly seven levels (an LPeg sub-capture limit); going past that is a
> parse error. Real code never approaches it.

## Type inference for parameters and return

Lambda annotations are optional. When you leave them off, Titan fills them
in from the **expected function type** — the type of the slot the lambda
flows into, whether that is an assignment target, an argument position, or a
`return`. **Both the parameter types and the return type come from this same
expected type**; neither is reverse-engineered from the lambda's body.

**Input types.** An annotated parameter uses its annotation. An *unannotated*
fixed parameter is filled in from the expected function type. A trailing bare
`...` similarly inherits the expected input-tail element type; explicit
`...: T` wins. See [Variadic parameters](variadic-parameters.md).

```titan
function f(): integer
    -- g's parameter and return both come from the annotation on g
    local g: function (integer): (integer) = function (x) return x + 1 end
    return g(2)
end

function apply(g: function (integer): (integer), x: integer): integer
    return g(x)
end

function use(): integer
    -- y's type is inferred from apply's first parameter
    return apply(function (y) return y + 1 end, 5)
end
```

If an unannotated parameter has no usable context — there is no expected
function type to read it from — it is a clean compile-time error:

```titan
function f(): integer
    local g = function (x) return x end   -- compile-time error
    return 1
end
```

```
test.titan:2:30: type error: cannot infer type of parameter 'x'
```

Annotate the parameter, or use the lambda where its type is known. A bare `...`
without a variadic expected type receives the corresponding inference error.

**Return shape.** Like the parameters, the fixed return list and any flexible
result tail come only from the
expected function type — it is *never* read off the body's `return`
statements. An explicit return annotation is used as written; otherwise the
complete return shape is taken from the expected function type when there is
one. The body is then checked against those results, exactly as a top-level
function body is checked against its declared returns:

```titan
function f(): integer
    -- g's return (integer) comes from the annotation on g; the body's
    -- `return x + 1` is checked against it
    local g: function (integer): (integer) = function (x) return x + 1 end
    -- h returns two values, again from h's annotation
    local h: function (integer): (integer, integer) = function (x) return x, x + 1 end
    local many: function (): (...: integer) = function () return 1, 2, 3 end
    return g(2)
end
```

An explicit annotation always wins. In particular, write `: ()` when the lambda
deliberately produces no results even though its context has a result-bearing
function type:

```text
function install(callback: function (): (value))
    -- ...
end

install(function (): ()
    record_event()
end)
```

The explicit source shape here is `function (): ()`. Ordinary callable adjustment then
decides whether it can flow to the target: `value` admits the missing nil result,
while a non-nilable target such as `integer` does not. See
[Callable adjustment wrappers](closure-adjustment-wrappers.md).

When there is no return annotation and no expected function type, the return
type defaults to the **zero-return** type `()` — exactly the default an
unannotated top-level function gets:

```titan
function f(): integer
    local g = function (x: integer) end   -- function (integer): ()
    g(1)
    return 1
end
```

This default applies whether or not the body contains a `return`. Because
the lambda has no expected type, `g`'s return type is `()`. Expressions in a
`return` are still evaluated for their effects, but their values are discarded
instead of becoming inferred results — consistent with an unannotated
top-level function:

```titan
function f(): integer
    -- no annotation, no expected type -> g is function (integer): ();
    -- x + 1 is evaluated and its value is discarded
    local g = function (x: integer) return x + 1 end
    g(4)
    return 1
end
```

To give such a lambda a return type, either annotate it (`function (x:
integer): integer ...`) or place it where its function type is known (an
annotated `local`, an argument slot, or a `return` position).

## Immediate calls as expressions

An anonymous function called immediately is a useful way to put statements
inside an expression:

```titan
function choose(flag: boolean): integer
    local result = (function (): integer
        if flag then return 10 end
        return 20
    end)()
    return result + 1
end
```

Titan generates an inline scoped block for this call, with result holders
outside the block. It allocates no function closure for the immediately called
literal. Parameters, variadic inputs, captures, multiple results, and flexible
results work with the same source rules as ordinary anonymous functions.

This optimization applies when the call's callee is the anonymous function
literal itself, including parentheses around that literal. It does not follow
stored function values, inline a function returned by another call, or look
through a callable cast. Parentheses around the **completed call** still force
one result: `((function (): () end)())` produces one nil, while the unadjusted
call produces no results.

The call's consumer does not supply an expected function type for the literal.
Annotate its parameters and results as needed: omitting its return annotation
still means zero results, even when the body writes `return expression`.
Inlining changes neither type checking nor capture restrictions.

The compiler uses the consumer's existing result demand at each return:

* A call statement retains no results; a scalar use retains one.
* A fixed declaration, assignment, argument list, return list, or iterator
  tuple retains the required remaining positions. Requested flexible positions
  keep their ordinary `T?` type and missing-value behavior.
* An open variadic argument tail, flexible return tail, or final positional
  Array/integer-Map constructor entry preserves the actual result count.

Only the final expression expands. A flexible return also respects any finite
budget inherited from its enclosing caller; the existing result-count limits
continue to apply.

Argument expressions are evaluated once in their usual order before the body
runs, and surplus arguments still execute. A return exits only this anonymous
function. Its return expressions and declared-result conversions run before
its `defer` cleanup, and caller-side conversions run afterward, outside its
`catch`. For example, returning an integer through a declared `float` result
and then storing it in `value` preserves the float tag. Discarded fixed-result
conversions can still raise; discarded implicit flexible-tail adjustments can
be skipped, while written casts and other source effects still execute.

Nested functions that are stored or returned remain ordinary closures. Their
captures stay alive after the immediate call exits, and mutable captures keep
their normal shared-cell behavior. Errors retain the source filename and line;
the optimized call does not require a separate anonymous native stack frame.

Immediate calls can initialize related values together without mutable
placeholders. Annotate an optional receiving slot when nil is part of the
result, so declaration inference does not force it before the caller can check:

```titan
function find_first(items: {integer}, minimum: integer): (integer?, integer?)
    local position: integer?, found: integer? =
        (function (items: {integer}, minimum: integer): (integer?, integer?)
            for index = 1, #items do
                if items[index] >= minimum then return index, items[index] end
            end
            return nil, nil
        end)(items, minimum)
    return position, found
end
```

Use this shape for a computation that belongs at its expression site. Keep a
useful named helper when the operation has its own meaning or callers. Passing
inputs explicitly can avoid introducing shared capture cells. In either form,
keep resource cleanup in the scope that owns the resource: a `defer` inside an
immediate function runs before its caller uses the returned value.

## Capturing enclosing locals

A lambda may use the locals and parameters of the function(s) around it.
This *just works* — no explicit capture list, no special syntax — and it
follows the same lexical scoping as Lua:

```titan
function make_adder(k: integer): function (integer): (integer)
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
  function make_closures(): {function (integer): integer}
      local fns: {function (integer): integer} = {}
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

For a [direct immediate call](#immediate-calls-as-expressions), the function
value never escapes or participates in an identity comparison, so the compiler
can omit its allocation without changing these rules.

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

```titan
function g(): integer
    local f: function (integer): (integer) = function (n: integer): integer
        return f(n)     -- compile-time error: variable 'f' not declared
    end
    return 1
end
```

For a recursive helper, write a named top-level function (recursion and
mutual recursion among top-level functions work without forward
declarations — see [Functions](functions.md#recursion-and-declaration-order)).

## Lambdas in module-variable initializers

A lambda may initialize a module variable, and a stored lambda may also appear
inside an Array, Map, record or union construction, operator, or written cast
in that initializer. Constructing the closure does not execute its body or read
the values mentioned there, so the ordinary module-initialization frontier
remains sound:

```titan
local transform = function (x: integer): integer return x + 1 end

function apply(x: integer): integer
    return transform(x)
end

function replace(f: function (integer): (integer))
    transform = f
end
```

This declares an ordinary function-typed module variable, not a named function.
It is initialized once with a fresh closure, can be reassigned later, and calls
through it use the first-class function path. The
[initializer dependency rule](modules.md#initializer-dependencies) rejects
references to the module's own variables and functions, and rejects a lambda
that a call evaluated by the initializer could invoke: one passed to that
call, directly or nested in its arguments, or called immediately. Putting
the read of an **already name-visible** module variable in the lambda's body
defers its value access until the closure is called; it does not make a later
module variable or import visible.

## Bound method references

A method *named but not called* is a function value with the receiver
bound in. Writing `obj:method` with **no argument list** yields a value
whose type is the method's type with the implicit `self` removed, and
calling that value runs the method on the nominal receiver `obj` was when the
reference was taken.

A bound-method initializer evaluates its receiver once and stores the method
without calling it. The receiver must obey the initializer dependency rule:
`Adder.new(100):add` is accepted, while a receiver that reads an own module
variable is rejected. A bound own-module method may be stored, but it is
rejected where a call evaluated by the initializer could invoke it. Imported
methods follow the same receiver rule.

```titan
record Adder
    base: integer
end

function Adder:add(x: integer): integer
    return self.base + x
end

function use(): integer
    local a = Adder.new(100)
    local f: function (integer): (integer) = a:add   -- bound: function (integer): integer
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

```titan
record Counter
    n: integer
end

function Counter:bump(): integer
    self.n = self.n + 1
    return self.n
end

function make(): function (): (integer)
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
