# Functions

Functions are the unit of Titan code. They are declared at the top level
of a module — there are no nested functions, no anonymous functions, and
no function values yet (see [below](#functions-are-not-values-yet)) — and
they come in two syntactic forms: plain module functions (this
chapter), and the methods of records (declared with `:` after a record
name; see [Records](records.md)). Everything this chapter says about
parameters, return values and arity applies to both forms, and to the
compiler-synthesized `new` static function of each record.

## Declaring functions

A function declaration names the function, gives every parameter a type,
optionally declares the return type(s), and ends with `end`:

```lua
function clamp(x: integer, lo: integer, hi: integer): integer
    if x < lo then
        return lo
    elseif x > hi then
        return hi
    else
        return x
    end
end
```

The pieces:

* **Parameters** are a comma-separated list of `name: type` pairs. The
  type annotation is mandatory for every parameter — parameter types are
  never inferred. Declaring two parameters with the same name is a
  compile-time error (`duplicate parameter 'x' in declaration of
  function 'f'`).
* **The return annotation is optional.** A function declared without
  `: type` returns `nil`; `function log_it(msg: string)` is the same as
  `function log_it(msg: string): nil`. A single return type is written
  bare (`: integer`); multiple return types are written as a
  parenthesized list (`: (integer, string)`).
* **Functions with a non-`nil` return type must return on every control
  path.** If some path can fall off the end of the body, the compiler
  rejects the function with the compile-time error `function can return
  nil but return type is not nil`. Functions returning `nil` may simply
  fall off the end. A `return` statement can only appear as the last
  statement of a block — see [Statements](statements.md).
* Declaring two top-level functions (or a function and a variable) with
  the same name is a compile-time error (`duplicate declaration for f,
  previous one at line N`).

In a function that returns `nil`, an early exit may be written either as
a bare `return` with no expression or as `return nil` — both mean the
same thing.

## Exported and `local` functions

By default a top-level function is **exported**: it becomes part of the
module's interface, callable from other Titan modules that `import` this
one and from Lua through the module table returned by `require`.
Prefixing the declaration with `local` makes the function private to the
module:

```lua
-- geometry.titan
local function square(x: float): float    -- private helper
    return x * x
end

function dist2(x: float, y: float): float -- exported
    return square(x) + square(y)
end
```

A `local` function does not appear in the module's type, is invisible to
importing Titan modules and to Lua (`require "geometry"` yields a table
with `dist2` but no `square`), and the compiler does not even generate
the Lua-side entry code for it. See [Modules](modules.md) for module
interfaces and [Lua interoperability](lua-interop.md) for what exported
functions look like from Lua.

## Strict arity

Titan has none of Lua's argument adjustment: a function declared with
*n* parameters must be called with exactly *n* arguments. Missing
arguments are not padded with `nil` and extra arguments are not dropped.
The rule is enforced in two different places, with the same strictness:

**Titan callers are checked at compile time.** Calling with the wrong
number of arguments is a compile-time error that quotes the function's
type:

```lua
function fma(a: float, b: float, c: float): float
    return a * b + c
end

function wrong(): float
    return fma(2.0, 3.0)   -- compile-time error
end
```

```
test.titan:6:15: type error: function 'fma' called with 2 arguments but expects 3.
(float, float, float) -> float
```

**Lua callers are checked at run time.** Lua code is not compiled by the
Titan compiler, so the check moves into the generated entry code of each
exported function, which counts the incoming arguments before anything
else. The run-time error message has the shape:

```
calling Titan function fma with 2 arguments, but expected 3
```

```lua
-- Lua
local m = require "test"
print(m.fma(2.0, 3.0, 1.0))            --> 7.0
print(pcall(m.fma, 2.0, 3.0))          --> false   calling Titan function fma with 2 arguments, but expected 3
```

The same strictness applies to `return` (returning the wrong number of
values is a compile-time error) and to multiple assignment and
declaration — see the next section. A wrong-arity call is reported the
same way whether the callee returns one value or several: the message
names the function and the expected and actual argument counts.

## Multiple return values

A function may declare and return several values:

```lua
function divmod(a: integer, b: integer): (integer, integer)
    return a // b, a % b
end
```

The `return` statement must supply exactly as many expressions as the
declared return types — `returned 1 value(s) but function expected 2` is
the compile-time error otherwise — and each expression is checked (and
implicitly coerced, where legal) against the corresponding declared
type.

### Consuming multiple values

A call to a multi-return function produces an *expression list*, and the
contexts that consume one are the same as in Lua — but, as everywhere in
Titan, arity is strict. In a multiple declaration or assignment the
number of values produced on the right must equal the number of names on
the left (compile-time error `left-hand side expects N value(s) but
right-hand side produces M value(s)`):

```lua
function use(): integer
    local q, r = divmod(13, 2)       -- ok: q = 6, r = 1
    local q2, _ = divmod(13, 2)      -- ok: '_' is an ordinary name, used here to mean "ignored"
    local q3 = (divmod(13, 2))       -- ok: parentheses adjust the call to one value
    return q + r + q2 + q3
end

function bad1()
    local q = divmod(13, 2)          -- compile-time error: left-hand side expects 1 value(s)
end                                  --                     but right-hand side produces 2 value(s)

function bad2()
    local a, b, c = divmod(13, 2)    -- compile-time error: left-hand side expects 3 value(s)
end                                  --                     but right-hand side produces 2 value(s)
```

Note that `_` is not special syntax — it is a regular variable name that
Lua and Titan programmers conventionally use for values they intend to
discard.

### Expansion in the last position

Exactly as in Lua, a multi-return call appearing in the **last position**
of an expression list expands to all of its values; in any other
position it is truncated to its first value. The compiler materializes
each extra value as a separate expression and type-checks (and coerces)
it individually against the corresponding expected type — a wrongly
typed second or third value produces the same `expected X but found Y`
compile-time errors a written-out argument would. Expansion applies to:

* the right-hand side of multiple declarations and assignments (above);
* `return` expression lists;
* call argument lists — a trailing call fills the remaining parameters:

  ```lua
  function add3(a: integer, b: integer, c: integer): integer
      return a + b + c
  end

  function h(): integer
      return add3(10, divmod(13, 2))   -- divmod fills parameters b and c
  end
  ```

* array constructors — `{ 10, divmod(13, 2) }` is `{ 10, 6, 1 }`, while
  a non-final call inside the constructor contributes only its first
  value.

Map constructors are the exception: a multi-return call as a value
(`[k] = divmod(13, 2)`) keeps only the first value; the extras are
dropped.

### Adjusting to one value

Wrapping a call in parentheses truncates it to exactly one value, again
as in Lua. `(divmod(a, b))` is a single `integer` and can go anywhere a
single value is expected:

```lua
function just_div(a: integer, b: integer): integer
    return (divmod(a, b))    -- ok: adjusted to one value
end

function too_many(a: integer, b: integer): integer
    return divmod(a, b)      -- compile-time error: returned 2 value(s) but function expected 1
end
```

Multiple return values cross the Lua boundary unchanged: Lua code
calling `divmod` receives two values, as from any Lua function (see
[Lua interoperability](lua-interop.md)).

## Functions are not values (yet)

Titan functions are not first-class in the current prototype. A function
name can be used in exactly one way — called. Concretely, all of the
following are compile-time errors:

```lua
function double(x: integer): integer
    return x * 2
end

function bad()
    local f: integer -> integer = double   -- type error: trying to access a function as a first-class value
    double = bad                           -- type error: trying to assign to a function
end

function apply(f: integer -> integer, x: integer): integer
    return f(x)                            -- type error: first-class functions are not
end                                        --             supported in this version of Titan
```

Storing a function in a variable, passing it as an argument, returning
it, or calling through anything other than the name of a declared
function (a module function, an imported module's function, or a record
static — see [Records](records.md)) is rejected. Function *types* exist
in the grammar (`integer -> integer`; `->` is right-associative, and
parameter/return lists are parenthesized: `(integer, string) -> (boolean)`)
precisely so that signatures like `apply`'s can be written down — they
are reserved for the planned first-class functions and closures, the
most prominent item on the project roadmap (see the
[status section](index.md#status-and-limitations)).

Because first-class function values are not implemented, writing a
function type in an annotation (whatever its parameter and return
arity — `integer -> integer`, `() -> integer`,
`(integer, integer) -> integer`) is a clean compile-time error,
`first-class function types are not supported yet`.

## Recursion and declaration order

The compiler checks a module in two passes: it first collects the
signatures of every top-level declaration, then checks the function
bodies. A function body therefore sees *all* top-level declarations of
its module — functions, records, variables, imports — regardless of the
order they appear in the file. Recursion needs no forward declarations,
and mutual recursion just works:

```lua
function is_even(n: integer): boolean
    if n == 0 then return true else return is_odd(n - 1) end
end

function is_odd(n: integer): boolean
    if n == 0 then return false else return is_even(n - 1) end
end
```

The one order-sensitive part of a module is top-level *variable*
initializers, which must be compile-time constants and so cannot call
functions at all — see [Modules](modules.md).

## Methods and static functions

Records may declare methods (`function Point:move(dx: float, dy: float)`).
There is no syntax for declaring static functions of your own —
`function Point.polar(r: float, t: float): Point` is a syntax error in
the current grammar; the only static function is the automatically
provided `Point.new`. Methods are top-level declarations like the
functions in this chapter and follow the same rules for parameters,
return values, arity (the compile-time message reads `method
'test.Point:move' called with ...`) and multiple returns; what differs —
the implicit `self`, name resolution against the record, visibility — is
described in [Records](records.md).

## Standalone programs: `main`

A Titan module is normally compiled to a shared library that Lua (or
another Titan module) loads. A module that declares a function with this
exact signature instead marks the program entry point:

```lua
function main(args: {string}): integer
```

When `titanc` is given a set of modules and exactly one of them has such
a `main`, it produces a standalone executable instead of shared
libraries. The executable is named after the module (dots in the module
name become directory separators) and statically embeds all the
requested modules plus every imported module whose source is available;
imports available only as compiled `.so` files are loaded dynamically at
startup, their interface recovered from the compiled module. See
[Modules](modules.md) for the compilation model.

```sh
./titanc answer        # answer.titan declares main -> executable ./answer
./titanc foo bar       # neither has main -> foo.so and bar.so
```

The rules:

* **The signature must match exactly**: one parameter of type `{string}`
  and the return type written `integer`. A top-level function named
  `main` with any other signature is an ordinary function, and the
  module compiles to a shared library as usual.
* **Only one `main` per program.** If more than one module given on the
  `titanc` command line has a qualifying `main`, compilation fails with
  `<module>: multiple main functions found (already declared in
  <other module>)`.
* `main` should not be declared `local`: a `local main` still selects
  executable mode, but the generated program starts by requiring the
  module and looking up `main` in its module table, where a `local`
  function never appears, so the program fails at startup with
  `attempt to call a nil value (field 'main')`.

At run time, `args` holds the command-line arguments: `args[1]` through
the last argument, with the executable's own name at `args[0]` — the
same layout as the `arg` table of the standalone Lua interpreter. The
integer returned by `main` becomes the process exit status:

```lua
-- answer.titan
function main(args: {string}): integer
    return 42
end
```

```sh
$ ./titanc answer
$ ./answer; echo $?
42
```

If a run-time error escapes `main` (or the module fails to load), the
program prints `<program name>: <error message>` to standard error and
exits with a failure status, without returning from `main`. For what can
raise run-time errors and how to handle them, see
[Error handling](error-handling.md).
