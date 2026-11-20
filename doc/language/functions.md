# Functions, Arguments, and Results

Functions are the basic unit of executable code in Titan. Top-level module
functions, record and union methods, static nominal functions, generated
constructors, and anonymous functions all share the same rules for
parameters, argument adjustment, multiple returns, variadic tails, and
flexible results. This chapter covers declaring and calling functions;
[Chapter 5](closures.md) covers functions as first-class values, lambdas,
closures, and bound methods.

## Declaring functions

A top-level function names its parameters with mandatory type annotations,
optionally declares its return types, and ends with `end`:

```titan
local function square(x: float): float
    return x * x
end

function distance_squared(x: float, y: float): float
    return square(x) + square(y)
end

function is_even(n: integer): boolean
    if n == 0 then return true end
    return is_odd(n - 1)
end

function is_odd(n: integer): boolean
    if n == 0 then return false end
    return is_even(n - 1)
end
```

Key declaration rules:

- **Visibility:** Top-level functions are exported by default—visible to
  importing Titan modules and to Lua through `require`. Prefixing `local`
  keeps a function private to its module.
- **Parameters:** Every parameter requires an explicit `name: type`
  annotation, and parameter names must be unique within the declaration.
- **Return annotations:** Omitting `: Ret` means **zero** return values
  (`: ()`), matching Lua—not a single `nil`. Write `: integer` for one result,
  `: (integer, string)` for several, `: nil` for one explicit `nil`, or a
  parenthesized [flexible tail](#flexible-return-tails) such as
  `: (...: string)` or `: (boolean, ...: integer)`.
- **Order independence:** The compiler collects all top-level declarations in
  a module before checking bodies, so recursion and mutual recursion need no
  forward declarations. Duplicate top-level names in the same module (or
  across files of a folder module) are compile-time errors.

Methods (`function Record:m(...)`) and static nominal functions
(`function Record.f(...)`), as well as bodyless Interface method signatures,
follow the same parameter and result grammar; see [Records](records.md),
[Unions](unions.md), and [Interfaces](interfaces.md).

## Positional argument adjustment

Positional calls to Titan functions adjust in both directions:

- **Missing arguments** are filled with `nil` and then type-checked against
  the missing parameters. An optional parameter is simply one whose type
  accepts `nil` (`T?`, `value`, `boolean`, or a nullable C pointer). Omitting
  a required `integer`, `float`, `string`, container, nominal, or function
  parameter is a compile-time error.
- **Surplus arguments** are evaluated left to right for their side effects. A
  non-variadic Titan function discards their values; a variadic function
  collects them in `...`.

Calls to Titan functions from Lua apply the same nil-padding and surplus rules
at run time using Lua's dynamic conversions. Direct C calls written with
parentheses enforce strict C arity without inventing missing arguments.

### Argument reachability during a call

Every argument—along with a method's receiver, a called function value, and
every element passed through `...` or a spread—stays reachable for garbage
collection until the call returns, even if the callee or a later argument
clears the field or variable that originally held it:

```titan
local effects = 0

local function log_effect(): string
    effects = effects + 1
    return "ignored"
end

function format_tag(label: string, prefix: string?): string
    return (prefix or "[") .. label .. "]"
end

function call_examples(): (string, string)
    local short = format_tag("ok")                    -- prefix receives nil
    local extra = format_tag("ok", "<", log_effect()) -- log_effect() runs; value discarded
    return short, extra
end

record Holder
    item: value
end

local function take(holder: Holder, item: value): value
    holder.item = nil  -- clears the caller's field
    return item        -- argument stays reachable during the call
end

function detach(holder: Holder): value
    return take(holder, holder.item)
end
```

Arguments may remain reachable in the caller until the calling function itself
returns. If code requires an object to become collectable immediately after a
call, isolate the call in a helper function or an
[immediately called lambda](closures.md#immediate-calls-as-expressions).

## Named calls

Direct calls to declarations that publish parameter names may use
brace-delimited named arguments. The compiler resolves every label at compile
time to its positional slot—there is no runtime argument table or name lookup:

```titan
record Point
    x: float
    y: float
end

function Point:translate(dx: float, dy: float)
    self.x = self.x + dx
    self.y = self.y + dy
end

union Message
    write(string)
    move(x: float, y: float)
end

function configure(label: string?, enabled: boolean, retries: integer?): string
    local text = label or "default"
    local suffix = enabled and "on" or "off"
    return text .. ":" .. suffix .. ":" .. (retries or 0)
end

function named_call_examples(): (Point, Message, Message, string)
    local point = Point { y = 3.0, x = 2.0 }
    point:translate { dy = 1.5, dx = -0.5 }
    local written = Message.write { value = "hello" }
    local moved = Message.move { y = 20.0, x = 10.0 }
    local status = configure { enabled = true } -- label and retries receive nil
    return point, written, moved, status
end
```

### Braces and eligibility

Bare braces after a callee (`f { x = 1 }`, `f {}`, `obj:m { x = 1 }`) always
select named-call syntax. To pass a brace constructor as a single positional
argument, wrap it in call parentheses: `consume({ x = 1 })`,
`consume({ 1, 2 })`, `consume({})`. Bare-string call sugar (`greet "world"`)
remains positional.

Named lists contain only `label = expression` entries separated by `,` or `;`,
with an optional trailing separator. Mixing positional and named items,
computed keys, or `...` is a syntax error. Labels accept raw identifier
spellings, including Titan keywords such as `repeat` or `end`, which allows
named calls to C functions and union constructors whose parameter names happen
to be keywords.

| Call target | Named syntax |
| --- | --- |
| Direct local, exported, or imported Titan function | Yes |
| Record or union static function, including `Record { ... }` (`Record.new`) | Yes |
| Generated union-variant constructor (unnamed single payload uses `value`) | Yes |
| Direct concrete record or union method (`self` is not a named parameter) | Yes |
| Direct Interface method (uses the Interface signature's parameter names) | Yes |
| Direct fixed-arity C function with complete, unique prototype names (`f(void)` accepts `f{}`) | Yes |
| Function value, anonymous function, bound method, or `value` call | No |
| C function pointer or C allocation form (`foreign T.new`) | No |
| Any input-variadic Titan or C function | No |

A function with fixed parameters and a flexible *return* tail remains eligible
for named calls. Parameter names belong to the declaration, not to structural
function types, so storing a function in a variable makes it positional-only:

```text
local fn = configure
-- compile error: named calls are not supported on function values
fn { enabled = true }
```

### Matching, omission, and evaluation order

Labels may appear in any order; unknown or duplicate labels are compile-time
errors. Omitted parameters receive `nil` and must accept it (so omitted
`boolean` becomes `false`, and an omitted C pointer in a named C call becomes
`NULL`). `f {}` requests named matching and fills every parameter with `nil`.

Evaluation order is strictly lexical: for a method, the receiver evaluates
once first; then explicit named expressions evaluate once each, left to right
as written, regardless of the formal parameter order. Each named expression
contributes exactly one value (multi-return calls and spreads do not expand
across named entries).

Calls from Lua are always positional: in Lua, `module.f { x = 1 }` passes a
single table as the first argument.

## Multiple return values

A function may declare a parenthesized list of return types and return
matching comma-separated expressions:

```titan
function divmod(a: integer, b: integer): (integer, integer)
    return a // b, a % b
end

local function sum_three(a: integer, b: integer, c: integer): integer
    return a + b + c
end

function multi_return_examples(): (integer, {integer})
    local quotient, remainder = divmod(17, 5)     -- 3, 2
    local first_only = (divmod(17, 5))            -- 3 (parentheses keep one result)
    local combined = sum_three(10, divmod(17, 5)) -- 10 + 3 + 2 = 15
    local list = { 10, divmod(17, 5) }            -- { 10, 3, 2 }
    return quotient + remainder + first_only + combined, list
end
```

Only the **last expression** of a positional expression list expands—in
multiple declarations and assignments, `return` statements, call argument
lists, positional Array or exact `{integer: V}` Map constructors, and generic
`for ... in` tuples. Earlier calls contribute only their first result, and
scalar positions (computed Map entries, record fields, named arguments,
conditions, operands) always request one value.

Finite consumers ignore surplus results and report a compile-time error if a
fixed-only producer supplies too few. Wrapping any call in parentheses,
`(f())`, adjusts it to exactly one value—truncating multiple results to the
first, or adjusting a zero-return call to `nil`. Multiple returns cross the
Lua boundary unchanged as ordinary Lua multiple results.

## Variadic parameters

A function may accept a trailing homogeneous run of extra arguments by ending
its parameter list with `...: T`:

```titan
function sum(base: integer, ...: integer): integer
    local total = base
    for i = 1, #... do
        total = total + ...[i]
    end
    return total
end

function first_or_nil(...: integer): integer?
    return (...) -- single-value adjustment: integer?
end

function unpack_pair(...: integer): (integer, integer?)
    local first: integer, second: integer? = ... -- first raises if empty; second nil-fills
    return first, second
end

function forward_with_offset(offset: integer, ...: integer): integer
    return sum(offset, ...)
end

function as_floats(...: integer): {float}
    return {...} -- converts each integer element to float
end
```

The `: T` annotation is mandatory on named functions, methods, and Interface
signatures; an anonymous function may write bare `...` when its expected
function type supplies the element type (see [Chapter 5](closures.md)).

Inside a variadic function, four operations read `...`:

- **`#...`** returns the number of supplied variadic arguments as an
  `integer`.
- **`...[i]`** reads the 1-based `i`-th variadic argument with the plain
  element type `T` (not `T?`). Because a variadic run is dense, an index `< 1`
  or `> #...` raises a runtime error instead of returning `nil`.
- **`(...)`** adjusts the run to a single scalar value of type `T?` (the first
  argument, or `nil` when empty; does not double-wrap `value` or an already
  optional `T?`).
- **Trailing `...`** expands the run in the final position of a call,
  `return`, declaration, assignment, positional Array/integer-Map constructor,
  or generic-`for` tuple:
  - Into a **fixed-arity** context (local list, fixed call, fixed `return`),
    the compiler expands one `...[k]` read per remaining slot. Optional slots
    nil-fill when the run is short; required slots raise.
  - Into a **variadic Titan callee** (`sum(offset, ...)`), the runtime count
    is forwarded. If the static prefix leaves fixed parameters unfilled, the
    leading elements of `...` fill them first (nil-filling optional ones,
    raising on missing required ones). The forwarded tail admits equal or
    gradually consistent element types (for example, `integer` and `value`
    forward both ways). It also admits
    [maybe-const Array views](arrays-maps.md#read-only-and-maybe-const-arrays)
    without introducing or forcing an Option. Unlike collection spreads,
    forwarding bare `...` does not apply scalar conversions to the tail:
    `integer` into `float` or record `R` into Interface `I` is rejected.
  - Into **`{...}`**, the run constructs an Array `{T}` (or `{integer: V}` in
    an exact integer-Map context), applying any element conversion required by
    the target context (such as `integer` to `float` in `as_floats`).

Restrictions and limits:

- `...` is not first-class and cannot be captured by an inner lambda or used
  as a standalone operand (`1 + ...` is rejected). A nested variadic lambda
  accesses its own `...`. To keep the arguments around, copy them into an
  Array with `{...}`.
- `...: nil` and foreign C pointer element types are rejected. Use `...: T?`
  or `...: value` when elements may be `nil`; `owned` C types are permitted.
- A variadic run holds at most **200** elements; crossing 200 raises a runtime
  error. Use an Array parameter `{T}` for unbounded collections.

## Flexible return tails

A function can return a runtime-sized trailing run of values by ending a
parenthesized return list with `...: T` (for example, `(...: string)` or
`(boolean, ...: integer)`). The parentheses are mandatory, the tail must be
last, and the element type obeys the same rules and 200-element limit as
variadic parameters. A function with only a flexible tail may fall off the end
or use bare `return` to produce zero values; a fixed prefix keeps normal
return checking.

How callers observe a flexible return depends on the context:

- **Finite consumers** (declarations, assignments, fixed calls and returns,
  generic-`for` tuples, scalar positions) project every requested position
  past the fixed prefix as `T?` (or `value` for `...: value`). Assigning a
  projected `T?` to a required `T` inserts the usual checked nil unwrap.
- **Open sinks** consume every value that actually exists as raw `T` (absent
  values add nothing). The three open sinks are:
  1. the trailing argument run of a variadic Titan call;
  2. the flexible tail of a `return` statement; and
  3. the final positional entry of an Array or exact `{integer: V}` Map
     constructor.

```titan
function measurements(short: boolean): (...: integer)
    if short then
        return 10
    end
    return 10, 20, 30
end

local function count_all(...: integer): integer
    return #...
end

function inspect_measurements(short: boolean): (integer?, {integer}, integer)
    local first?, second? = measurements(short)       -- finite projections: integer?
    local collected = { 0, measurements(short) }      -- open sink: preserves actual run
    local total_count = count_all(measurements(short)) -- open sink
    return second or first, collected, total_count
end

function call_dynamic(callback: value): (integer, {integer})
    local one: integer = callback()         -- contextual call: function (): integer
    local many: {integer} = { callback() }  -- contextual call: function (): (...: integer)
    return one, many
end
```

Storing a flexible function in a narrower static function slot (such as
`function (): (integer)`) hides its extra results even inside an open sink.

When calling a `value` directly (`callback()` above), Titan synthesizes a
temporary positional function type from the supplied arguments and the
consumer's result demand—using an expected type where present, `value` for an
unannotated finite slot, and `(...: T)` for an open sink—then checks
callability and types at run time. Finite calls through function values or
`value` are bounded by Lua's 250-result VM limit.

## Spread expressions

A spread expression expands an Array, an exact `{integer: T}` Map, or a
subrange of the current function's `...` into the final position of a
positional expression list:

```text
...subject
...subject[, last]
...subject[first,]
...subject[first, last]

...[, last]
...[first,]
...[first, last]
```

Container subjects may be `{T}`, `const { T }`, `const? { T }`,
`{integer: T}`, or any of their Option types (auto-unwrapped once with a
runtime nil check). Other Map key types, `value`, and C arrays require an
explicit cast to an accepted container type first.

Ranges are 1-based, closed, and inclusive: an omitted lower bound defaults to
`1`, an omitted upper bound defaults to the subject's length, and a range with
`first > last` is empty. Evaluation proceeds left to right—subject once, lower
bound once, upper bound (or length) once, then elements in increasing order—even
if the consumer requests zero elements. Map spreads use ordinary `__len` and
`__index` semantics.

```titan
function first_two(items: {integer}): (integer, integer?)
    local first: integer, second: integer? = ...items
    return first, second
end

function middle(words: {string}): {string}
    return { ...words[2, #words - 1] }
end

function prepend_zero(sink: function (...: integer): (), values: {integer}?)
    sink(0, ...values)
end

function forward_tail(...: string): (...: string)
    return ...[2,]
end
```

Spread rules mirror flexible returns:

- **Finite consumers** observe each requested position as `T?` (optional slots
  receive `nil`; required slots raise if absent).
- **Open sinks** preserve the selected runtime length as `T`. A hole in an
  Array or Map raises when `T` excludes `nil`, or delivers `nil` when `T`
  admits it (`value`, `U?`). An out-of-range variadic slice always raises.
- **Placement and disambiguation:** Only the last positional item may expand
  (`sink(...values, 0)` is a compile-time error). Parentheses adjust a spread
  to one optional value (`(...xs)`, `(...xs[2, 4])`, or `(...[2, 4])`).
  Because `...` followed by an expression starts a collection spread,
  `... -1` attempts to spread `-1`; write `(...) - 1` to subtract from the
  first variadic argument.
- **C calls and limits:** A non-variadic C call can consume a spread through
  its fixed parameters, but a Titan spread never supplies C `...` varargs.
  Oversized spreads are checked against the destination's remaining capacity
  (200 for variadic/flexible tails; container limit for Arrays/Maps) before
  any elements are read or written. At most 100 explicit expressions may
  precede a trailing spread in a call, `return`, assignment, declaration, or
  `for ... in` tuple.

## Standalone programs: `main`

A module compiles into a standalone executable (rather than a library) when it
exports a top-level function with this exact signature:

```titan
local io = import "io"

function main(args: {string}): integer
    if #args == 0 then
        io.print("no arguments")
        return 0
    end
    for i = 1, #args do
        io.print(i .. ": " .. args[i])
    end
    return 0
end
```

- **Exact signature:** One mutable `{string}` parameter (transparent aliases
  are accepted, while `const { string }` and `const? { string }` are distinct
  types), no variadic input tail, one `integer` return, and no flexible return
  tail. Any other `main` signature compiles as an ordinary library function.
- **Exported and unique:** Declare `main` without `local` (a `local main` is
  not exposed on the module and fails at startup), and include at most one
  qualifying `main` per `titanc` invocation.
- **Arguments and exit status:** `args[1]` through `args[#args]` hold the
  user-supplied command-line arguments (`args[0]` is `nil`; the executable
  name is omitted). The returned `integer` becomes the process exit code. An
  uncaught error prints `<program>: <message>` and a stack traceback to
  standard error and exits nonzero.

Flat modules produce an executable named after the module (`titanc -o out app`
builds `out/app`); folder modules append `__main` (`out/pkg/app__main`). For
`--exe`, static vs shared dependencies, and multi-module library bundling, see
[Modules and Program Structure](modules.md) and
[Appendix B: The `titanc` Toolchain](toolchain.md).
