# Functions

Functions are the unit of Titan code. They come in two syntactic forms
declared at the top level of a module: plain module functions (this
chapter), and the methods of records (declared with `:` after a record
name; see [Records](records.md)). Functions are also **first-class
values** — a function name can be used as a value (see
[Functions as values](#functions-as-values)) — and there are **anonymous
function expressions** that close over the enclosing function's locals,
which have their own chapter
([anonymous functions and closures](closures.md)). Everything this chapter
says about parameters, return values and arity applies to every form, and
to the compiler-synthesized `new` static function of each record.

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
* **The return annotation is optional, and omitting it means zero return
  values.** A function declared without `: type` is a `(...) -> ()`
  function that returns *nothing* — `function log_it(msg: string)` is the
  same as `function log_it(msg: string): ()`, and `select('#', m.log_it(s))`
  from Lua is `0`. This matches Lua, where `function f() end` returns no
  values. If you want a function that returns a single `nil`, write it
  explicitly as `: nil`. A single return type is written bare
  (`: integer`); multiple return types are written as a parenthesized list
  (`: (integer, string)`); zero return values are written `: ()`.
* **Functions whose return type carries a value must return on every
  control path.** If some path can fall off the end of the body, the
  compiler rejects the function with the compile-time error `function can
  return nil but return type is not nil`. Zero-return (`()`) functions and
  `nil`-returning functions may simply fall off the end. A `return`
  statement can only appear as the last statement of a block — see
  [Statements](statements.md).
* Declaring two top-level functions (or a function and a variable) with
  the same name is a compile-time error (`duplicate declaration for f,
  previous one at line N`).

In a zero-return (`()`) function — including any function written without
a return annotation — the only legal `return` is a bare `return` with no
expression. `return nil` is **not** the same thing: it tries to return one
value and is the arity error `returned 1 value(s) but function expected 0`.
A bare `return` and `return nil` are equivalent only inside a function
whose declared return type is exactly `nil`. For option- or
`value`-returning functions, write `return nil` explicitly.

## Exported and `local` functions

By default a top-level function is **exported**: it becomes part of the
module's interface, callable from other Titan modules that `import` this
one and from Lua as a member of the module value returned by `require`.
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
importing Titan modules and to Lua (`require "geometry"` yields a module
value with `dist2` but no `square`), and the compiler does not even
generate the Lua-side entry code for it. See [Modules](modules.md) for module
interfaces and [Lua interoperability](lua-interop.md) for what exported
functions look like from Lua.

## Argument adjustment

Titan function calls adjust upward, but never downward. A function
declared with *n* parameters may be called with fewer than *n* arguments;
the missing positions are filled with `nil` and then type-checked as if
the caller had written those `nil` arguments explicitly. Calling with
more than *n* arguments is still a compile-time error. Titan never drops
extra arguments.

This is why omitted parameters are "optional" only when their declared
type can accept the synthesized `nil` (for example `T?`, `value`,
`boolean`, or a nullable pointer type). Omitting a non-optional
`integer`, `float`, `string`, array, map, record, or function parameter
is a type error at the call site:

```lua
function fma(a: float, b: float, c: float): float
    return a * b + c
end

function wrong(): float
    return fma(2.0, 3.0)   -- compile-time error: c receives nil
end
```

```
test.titan:6:15: type error: types in argument 3 of call to function 'fma' do not match, expected float but found nil
```

The same adjustment applies to methods, record static functions
(including the compiler-synthesized `Rec.new` constructor), imported
Titan functions, anonymous functions, and calls through function-typed
values. Foreign C functions keep C-style arity: Titan does not invent
missing C arguments in a parenthesized positional call. A supported named
direct-C call may omit a fixed parameter whose Titan-visible type accepts
`nil`; see [Named arguments](named-arguments.md#matching-checking-and-omission).

**Titan callers are checked at compile time.** Once missing positions
have been filled with `nil`, each argument is coerced and checked against
the corresponding parameter type. Too many arguments are rejected before
code generation, with a message that quotes the function's type:

```lua
function too_many(): float
    return fma(2.0, 3.0, 1.0, 0.0)   -- compile-time error
end
```

```
test.titan:6:15: type error: function 'fma' called with 4 arguments but expects 3.
(float, float, float) -> float
```

**Lua callers are adjusted and checked at run time.** Lua code is not
compiled by the Titan compiler, so the generated entry code of each
exported function pads missing arguments with `nil`, then runs the usual
boundary type checks. Extra Lua arguments are rejected:

```lua
-- Lua
local m = require "test"
print(m.fma(2.0, 3.0, 1.0))            --> 7.0
print(pcall(m.fma, 2.0, 3.0))          --> false   test.titan:1:1: type error, expected float but found nil
print(pcall(m.fma, 2.0, 3.0, 1.0, 0.0)) --> false   calling Titan function fma with 4 arguments, but expected at most 3
```

The adjustment rule is only for function arguments. `return`, multiple
assignment and multiple declaration still require the exact number of
values in fixed-arity contexts — see the next section.

## Named calls

A direct declaration can also be called with a brace-delimited named list:

```lua
function clamp(x: integer, lo: integer, hi: integer): integer
    if x < lo then return lo elseif x > hi then return hi else return x end
end

local function use_clamp(): integer
    local y = clamp { hi = 10, x = 17, lo = 0 }
    return y
end
```

Names are matched to formal positions, so they may be written in any order.
An omitted formal receives the same synthesized `nil` and type check described
above. Explicit expressions are nevertheless evaluated left to right as
written, and each named item contributes exactly one value.

Named syntax is available for direct Titan functions, record functions, and
methods, plus direct fixed-arity C functions whose prototypes publish complete
parameter names. It is not available through a function value, anonymous
function, bound-method value, or C function pointer, and it is rejected for
variadic functions. Bare braces always select this form; write
`consume({ x = 1 })` to pass one constructor positionally. See
[Named arguments](named-arguments.md) for the full syntax, eligibility table,
evaluation order, FFI metadata rules, and Lua boundary.

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
  value;
* generic `for ... in` iterator tuples — a helper returning
  `(next, state, init, close)` can be used directly after `in`, and a
  trailing `...` in a variadic function can fill the remaining tuple slots.

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

## Functions as values

Titan functions are first-class values. A **function name** used where a
value is expected yields a function value you can store, pass, return, and
call indirectly. The name can be a top-level function, a `local` function,
an imported module's function (`mod.f`), or a record function (`Rec.new` or
`Rec.make`):

```lua
function double(x: integer): integer
    return x * 2
end

function apply(f: (integer) -> integer, x: integer): integer
    return f(x)                            -- call through a function value
end

function use(): integer
    local f: (integer) -> integer = double -- store a function in a variable
    return apply(f, 21)                    -- pass it as an argument  --> 42
end
```

A **function type** is written `(P1, …, Pn) -> R` for one return,
`(P…) -> (R1, …, Rm)` for several, `() -> R` for no parameters, and
`(P…) -> ()` for zero return values. `->` is right-associative and the
single-parameter form may drop its parentheses (`integer -> integer`), so
higher-order types nest naturally: `(integer -> integer, integer) -> integer`.
Writing a function type in an annotation is no longer an error.

Function values may be assigned into function-typed locals, parameters and
record fields, stored in arrays (`{(integer) -> integer}`) and maps,
returned, and passed across the Lua boundary in both directions. (Indexing
an array or map of functions yields an option `T?`; calling it directly,
`fns[i](x)`, auto-unwraps with a runtime nil-check.)

Parameter names are not part of a function value's type. Named-call syntax is
therefore available only while the callee is reached as a direct declaration;
storing the same function in a variable keeps it callable positionally but
does not carry its formal names with the value.

**Calling a function value** has two paths, chosen automatically. When the
value is a Titan function whose type is *exactly* the call's static type,
the call goes straight to its native entry with no Lua-stack round trip —
the same cost as calling the function by name. Otherwise (a Titan function
of a merely *compatible* type, or a plain Lua function, C function, or
`__call` object) the call goes through the Lua stack; an attempt to call a
value that is not actually callable raises a clean runtime error at the
call. This is also how Titan **calls Lua code**: pass a Lua closure to a
function-typed parameter and call it — see
[Lua interoperability](lua-interop.md).

**Identity is stable.** Each referenced function has one canonical value,
so `m.f == m.f` and an in-module reference equals the exported
module-table entry seen from Lua.

**`value` and function types convert both ways.** A function value flows
into a `value` implicitly, and a `value` flows into a function type
implicitly as well — the check that it is callable is deferred to the
moment of the call (so a `value` holding a non-callable raises only when
you try to call it).

**Anonymous functions are values too.** A `function (...) ... end`
expression evaluates to a function value of the same kind, and it can
capture the enclosing function's locals — see
[anonymous functions and closures](closures.md). An instance method named
but not called, `obj:method`, is also a value: a *bound method reference*,
the method's type with the implicit `self` bound to the receiver (see
[bound method references](closures.md#bound-method-references)).

What is **still not** a Titan function value: a foreign/FFI function — it can
be called by name or converted to a compatible C function pointer, but not
stored as a Titan function value (see [the FFI chapter](ffi.md)). Assigning
*to* a function name (`double = bad`) also remains an error.

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

## Methods and record functions

Records may declare methods (`function Point:move(dx: float, dy: float)`), and
methods may be `local` to the defining module. Records may also declare record
functions (`function Point.polar(r: float, t: float): Point`), likewise with
optional `local` visibility. Record functions are called as `Point.polar(...)`
and have no implicit `self`; the automatically provided `Point.new` is a
record function synthesized by the parser.

Methods and record functions are top-level declarations like the functions in
this chapter and follow the same rules for parameters, return values, arity
(method diagnostics read `method 'test.Point:move' called with ...`) and
multiple returns. What differs — implicit `self` for methods, name resolution
against the record, and record-member visibility — is described in
[Records](records.md).

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

* **The resolved signature must match exactly**: one parameter of type
  `{string}` and a return type of `integer`. Transparent aliases of either
  type are accepted. A top-level function named `main` with any other
  signature is an ordinary function, and the module compiles to a shared
  library as usual.
* **Only one `main` per program.** If more than one module given on the
  `titanc` command line has a qualifying `main`, compilation fails with
  `<module>: multiple main functions found (already declared in
  <other module>)`.
* `main` should not be declared `local`: a `local main` still selects
  executable mode, but the generated program starts by requiring the
  module and looking up `main` as a member of the module value, where a
  `local` function never appears, so the program fails at startup with
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
exits with a failure status, without returning from `main`. The report
also includes `stack traceback:` followed by tab-indented traceback
frames through the Titan `main` frame; the synthetic Lua bootstrap is not
shown. For what can raise run-time errors and how to handle them, see
[Error handling](error-handling.md).
