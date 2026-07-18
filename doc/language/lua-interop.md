# Lua interoperability

A compiled Titan module is, from Lua's point of view, an ordinary module:
you `require` it, call its functions, read and write its exported
variables, and pass values back and forth. There is no marshalling layer
and no copying — Titan operates directly on Lua values. What the boundary
adds is *checking*: every value that enters typed Titan code is validated
once, at the edge, and a mismatch is a run-time error with a descriptive
message rather than silent corruption. This chapter describes the boundary
from the Lua programmer's side: what `require` returns, what each Titan
type looks like in Lua, exactly where the run-time checks happen, and what
does and does not work in each direction.

## Requiring a Titan module

Compiling a library produces paired physical DSO/archive providers plus one
generated Lua loader per physical logical module. A stock Lua interpreter
uses the DSO form: `require` runs the generated loader, which finds the
provider, loads it globally, and invokes that module's exact `luaopen_*` entry
(see
[Multi-module libraries](multi-module-libraries.md)). `require` returns a
**userdata** — the module
value — whose members you access exactly like table fields (`m.f`, `m.v`,
`m.v = x`, `m.Rec.new`), but served through a metatable. The members are:

* **one function per exported Titan function** (and nothing for functions
  declared `local` — they are invisible to Lua), returned read-only;
* **one namespace per exported record type**, a small table holding the
  record's public record functions — in particular the automatically generated
  constructor when it is public, so `mod.Point.new(2, 3)` works from Lua for a
  public `new` (see [Records](records.md));
* **exported module variables**, read and written through the metatable
  so that reads always see the current value and writes are type-checked
  (see [Module variables from Lua](#module-variables-from-lua) below).

Because the module value is a userdata, `type(require "m")` is
`"userdata"`, not `"table"`; functions and record namespaces are
read-only (assigning to them errors).

```lua
-- counter.titan          -- Titan
count: integer = 0

function bump(n: integer): integer
    count = count + n
    return count
end
```

```sh
./titanc counter          # produces counter.so, counter.a, and counter.lua
```

```lua
-- Lua
local counter = require "counter"
print(counter.bump(10))   --> 10
print(counter.count)      --> 10
counter.count = 100
print(counter.bump(1))    --> 101
```

The module value's metatable is protected: `getmetatable` on it returns
the string `"Titan module counter"`, and `setmetatable` on it fails.

One provider may export several logical Lua entries. For example,
`titanc pkg.left pkg.right` produces `pkg.so`, `pkg.a`, `pkg/left.lua`, and
`pkg/right.lua`. `require "pkg.left"` and `require "pkg.right"` map the same
DSO but call `luaopen_pkg_left` and `luaopen_pkg_right`, respectively. They
return distinct logical module values, initialize independently, and retain
their own module state. Requiring one sibling does not initialize the other.

Each generated loader first obtains Titan's native support table with bare
`require "titan"`, then uses its internal lazy/global loader for the physical
provider. The bare name is therefore reserved: no generated logical module may
be named exactly `titan`, and no top-level `titan.lua` loader is emitted. Bare
`require "titan"` itself returns only the support table; it does not initialize
the standard `titan.*` modules that share the installed `titan.so` image.

### Qualified standard-library names

Titan's standard modules have qualified `titan.*` identities. The parser
desugars their convenient short Titan imports to those qualified names, while
Lua requires the qualified names directly. For example:

```lua
local lua_os = require "os"          -- Lua's standard table
local titan_os = require "titan.os"  -- Titan module userdata

assert(type(lua_os) == "table")
assert(type(titan_os) == "userdata")
assert(require "os" == lua_os)
```

The same rule applies to `titan.coroutine`, `titan.async`, `titan.timer`,
`titan.fs`, `titan.net`, and `titan.os`. The private `titan.uv` plumbing module
uses the same canonical identity. In an installed Titan 0.16 tree, generated
loaders under `<root>/share/lua/5.5/titan/` all open the DSO form
`<root>/lib/titan/0.16/titan.so` and invoke their own exact Lua entries. Titan
imports may instead select the paired self-describing `titan.a`; both forms
expose the same logical-module ABI/types. The installation does not create
child DSOs, parent-level or `lib/lua` copies, symbolic links, or hard links.

## How values map between the two languages

Titan values *are* Lua values; nothing is converted on the way out of
Titan. Entering Titan, each value is checked (and, for numbers, possibly
converted) against the declared type:

| Titan type | A Lua caller may pass | Lua receives back |
| --- | --- | --- |
| `integer` | a Lua integer, or a Lua float with an integral value (converted) | a Lua integer (`math.type` is `"integer"`) |
| `float` | a Lua float, or a Lua integer (converted to float) | a Lua float |
| `boolean` | **any value**, converted by truthiness — see below | `true` or `false` |
| `string` | a Lua string only — numbers are *not* coerced | the same string |
| `nil` | only `nil` | `nil` |
| `{T}` (array) | any table; the contents are **not** checked here | the *same* table — aliased, not copied |
| `{K:V}` (map) | any table; the contents are **not** checked here | the *same* table — aliased, not copied |
| record type | a userdata created by that same record type (from any module instance) | a userdata carrying the record's metatable |
| `T?` (option) | `nil`, or a value of type `T` — stricter than plain `T`, see below | `nil`, or whatever `T` produces |
| `value` | anything | the value, unchanged |

Notes on the entries that deserve them:

* **Numbers follow Lua's own conversion rules.** Passing `2.0` where an
  `integer` is expected works; passing `2.5` raises a run-time error of
  the shape `file:line:col: type error, number '2.5' has no integer
  representation`. Passing an integer where a `float` is expected converts
  it silently, just as Lua arithmetic would. The integer-to-float
  direction works everywhere, but the float-to-integer conversion is for
  *function arguments only*: writing an integral float to an `integer`
  module variable or record field from Lua is a run-time error
  (`type error, expected integer but found number`).
* **Boolean parameters accept anything, by truthiness.** A Titan
  `boolean` parameter never raises a type error: the argument is converted
  the way a Lua `if` would treat it — `false` and `nil` become `false`,
  *everything else* (including `0` and the empty string, as in Lua)
  becomes `true`:

  ```lua
  -- test.titan           -- Titan
  function pick(c: boolean, a: integer, b: integer): integer
      if c then return a else return b end
  end
  ```

  ```lua
  -- Lua
  test.pick(true, 1, 2)  --> 1
  test.pick(nil, 1, 2)   --> 2   (nil is falsy)
  test.pick(42, 1, 2)    --> 1   (any other value silently counts as true)
  ```

  This is the one place where the boundary coerces rather than checks.
  Asymmetrically, *writing* a non-boolean to a `boolean` module variable
  or record field from Lua is a run-time error
  (`type error, expected boolean but found ...`) — only function
  arguments get the truthiness treatment.
* **Strings are not coerced from numbers.** Where Lua's standard library
  often accepts a number and converts it, a Titan `string` parameter
  raises `type error, expected string but found number`.
* **Arrays and maps are the very same Lua table** on both sides of the
  boundary — see [Sharing arrays and maps](#sharing-arrays-and-maps-with-lua).
* **Records are userdata, not tables** — see
  [Records from Lua](#records-from-lua).
* **`nil` and options.** A `T?` parameter accepts `nil` or a value of
  type `T`, but is *stricter* than a plain `T` parameter: the
  argument-only coercions above do not apply, so `integer?` rejects an
  integral float (`type error, expected integer but found number`) and
  `boolean?` rejects non-boolean values instead of converting by
  truthiness. (`float?` still accepts an integer — that conversion works
  everywhere.) A `T?` result reaches Lua as `nil` or a plain `T` value.
  Since reading a missing array or map element in Titan produces an
  option (see [Option types](option-types.md)), `nil` flows across the
  boundary exactly as a Lua programmer would expect.
* **`value` is the deliberate escape hatch**: it accepts any Lua value
  and hands it back unchanged. Checking is deferred to the point where
  Titan code converts the `value` to a concrete type (see
  [the type system](types.md)).

## Where the run-time checks happen

The boundary checks run at exactly these places:

1. **Function entry, once per argument** — including the receiver of a
   method call (`self` is checked like any other record-typed argument).
2. **Writes to exported module variables from Lua** (`mod.x = v`).
3. **Writes to record fields from Lua** (`rec.x = v`).
4. **Inside Titan**, whenever a `value` is converted to a concrete type
   and whenever an array or map element is read (see below).

And, just as importantly, where they do *not* happen:

* **Never inside containers.** A `{string:integer}` parameter only
  requires *a table*; what is stored under its keys is not inspected when
  the table crosses the boundary. Instead, every element read inside
  Titan re-checks the element type, so a wrongly-typed element produces a
  run-time error *later*, deterministically, at the Titan code that reads
  it — never silent misbehavior. The same applies in reverse: Lua can
  freely (and type-incorrectly) mutate a table it got from Titan, and the
  error surfaces at the next Titan read.
* **Not on exact native Titan calls.** A direct Titan-to-Titan call, including
  across modules, needs no boundary checks because the compiler has already
  proven the types match. The same is true for a function value whose exact
  run-time type tag matches its static type. A merely compatible Titan
  function, a Lua callable, or a contextual call through `value` uses the
  generic Lua-stack path and checks arguments and requested results there.

When an argument check fails, the error message is prefixed with a source
location of the shape `file:line:col:` — note that this is the location of
the *Titan function's declaration* in the `.titan` source, not the Lua
call site. (As for any error raised from a C function, Lua prepends its
own `chunk:line:` call-site position on top of that when the failing
operation runs inside a Lua function — though not when the Titan function
is passed directly to `pcall`. The example outputs in this chapter omit
that prefix.) The Lua-side traceback identifies the call site as usual.

*Implementation note:* the per-type checks and the wrapper that runs them
are described in
[the interop internals](../implementation/lua-interop-internals.md).

## Calling Titan functions: argument counts and multiple returns

Titan function calls adjust missing arguments upward with `nil`. A
fixed-parameter Titan function ignores surplus arguments; an input-variadic
one collects them (see [Functions](functions.md)). When *Lua* calls a Titan
function, the generated Lua entry wrapper performs the same adjustment before
it checks the arguments the callee observes. If a synthesized `nil` does not
fit the parameter type, the call raises the usual boundary type error. Every
collected variadic argument is checked against its declared element type.

Lua calls remain positional-only. In Lua, `test.f { x = 1 }` is exactly
`test.f({ x = 1 })`: one ordinary table argument. It does not carry the syntax
marker used by Titan's [named calls](named-arguments.md), and the generated
entry wrapper does not inspect keys or infer a mapping from the table's shape.
Exported parameter names are a compile-time API for Titan callers, not a new
Lua calling convention.

Multiple return values work exactly as in Lua — a Titan function declared
with several return types returns that many values to Lua:

```lua
-- test.titan             -- Titan
function f(x: integer): (integer, string)
    return x * 2, "foo"
end
```

```lua
-- Lua
local test = require "test"
local x, y = test.f(2)
assert(x == 4 and y == "foo")
assert(test.f(2, "extra") == 4)             -- surplus argument is ignored
```

A flexible Titan return crosses the same boundary as ordinary Lua multiple
results. When Lua requests a finite number of results, the wrapper supplies
that prefix and nil-fills absent flexible positions; an open Lua call receives
the complete run that was produced, subject to Titan's 200-value flexible-tail
bound. Fixed results and flexible elements are checked and converted before
they reach Lua. See [Flexible returns](flexible-returns.md).

## Sharing arrays and maps with Lua

A Titan array or map *is* a Lua table — passing one in either direction
passes a reference to the same object, with no copying. Mutations made on
one side are immediately visible on the other:

```lua
-- test.titan             -- Titan
function f(m: {string:integer}): {string:integer}
    m["foo"] = m["foo"] + 10
    return m
end
```

```lua
-- Lua
local test = require "test"
local m = { foo = 10 }
local m2 = test.f(m)
assert(m2 == m)           -- the same table came back, not a copy
assert(m.foo == 20)       -- Titan's write is visible in Lua
test.f(m)
assert(m.foo == 30)
```

Because the contents are not checked at the boundary, Lua can put a
wrongly-typed value into a shared table; the error is raised later, when
Titan reads that element:

```lua
-- Lua (continuing)
m.foo = "wat"
test.f(m)  --> error: test.titan:...: type error, expected integer but found string
```

This deferred check is a deliberate trade-off: checking a whole table on
every crossing would make the boundary cost proportional to the table's
size, defeating the point of sharing. The guarantee Titan keeps is that
the bad element can never be *used* at the wrong type — every read is
checked. See [Arrays and maps](arrays-maps.md) for the container types
themselves.

## Records from Lua

A Titan record arrives in Lua as a **userdata**, not a table — records
are nominal, fixed-shape values and do not have a table representation
(see [Records](records.md)). The userdata carries a metatable, shared by
all instances of the record type in the Lua state, that makes it behave
like an object:

* **Field reads** (`p.x`) return a public field's value; record-typed fields
  arrive as their own userdata.
* **Field writes** (`p.x = v`) are type-checked against the declared
  field type, with the standard
  `file:line:col: type error, expected X but found Y` message on
  mismatch.
* **Methods** are called with the usual colon syntax (`p:move(2, 3)`) when
  they are public.
  Method names are not assignable fields: `p.move = 2` raises the
  "field not found" error.
* **Unknown fields**, including local fields and local methods, raise
  `file:line:col: field 'name' not found in record 'mod.Rec'` on both
  read and write — there is no Lua-style `nil` for missing fields.
* **Record functions**, including the generated `new`, are reached as a member of
  the module value: `mod.Point.new(2, 3)`. Local records are not module members,
  and a local `new` static is absent from the namespace table.

```lua
-- test.titan             -- Titan
record Point
    x: float
    y: float
end

function Point:move(dx: float, dy: float)
    self.x, self.y = self.x + dx, self.y + dy
end
```

```lua
-- Lua
local test = require "test"
local p = test.Point.new(2, 3)
assert(type(p) == "userdata")     -- not a table!
p:move(2, 3)
assert(p.x == 4.0 and p.y == 6.0)
p.x = 10                          -- type-checked write (10 converts to float)
print(pcall(function () p.z = 1 end))
--> false   test.titan:...: field 'z' not found in record 'test.Point'
```

Record identity is userdata identity: the same record instance always
appears as the same userdata, two distinct instances compare `~=`, and
there is no structural equality. The metatable is protected —
`getmetatable(p)` returns the string `"Titan record test.Point"` — so Lua
code cannot swap it. Titan record type checks use the real metatable pointer as
the type identity, so plain Lua cannot pass one record type off as another;
debug-library or C code that mutates protected metatables is outside Titan's
safety boundary. Passing the wrong record type (or a non-record) where a record
is expected is a run-time error naming both types:
`type error, expected test.Rec but found test.Point`, or
`... but found number`.

## Module variables from Lua

Exported (non-`local`) module variables are readable and writable from
Lua as members of the module value, as in the `counter` example above.
Reads always observe the current value — including changes made by Titan
code — and writes made from Lua are immediately visible to Titan, because
both sides share one storage location. Writes are type-checked at run
time:

```lua
-- counter.titan          -- Titan
count: integer = 0
```

```lua
-- Lua
local counter = require "counter"
counter.count = 2          -- fine
counter.count = 2.0        -- fine: integral floats convert to integer
counter.count = 2.5
--> error: counter.titan:...: type error, expected integer but found number
counter.count = "lots"
--> error: counter.titan:...: type error, expected integer but found string
```

Accessing a module member that does not exist raises
`member 'name' does not exist in Titan module 'counter'` rather than
returning `nil`. (Exception: a module that exports *nothing at all* has
no metatable, so it has no members to reach.)

Module variables declared `local` are not members of the module value at
all; they are private to the module (see [Modules](modules.md)).

## Calling Lua from Titan

Calls cross the boundary **both ways**: Lua calls Titan, and Titan calls
Lua. Titan code can receive a Lua function in a function-typed parameter, or
receive it as a `value` and call it contextually. There is still no `import`
of a Lua *module* — `import` loads Titan modules and `foreign import` binds
C headers (see [the C FFI](ffi.md)) — but a Lua callable passed in as an
argument is fully usable:

```lua
-- apply.titan            -- Titan
function apply(f: (integer) -> integer, x: integer): integer
    return f(x)
end
```

```lua
-- Lua
local m = require "apply"
print(m.apply(function(n) return n * 10 end, 5))   --> 50
```

The value passed for `f` may be any callable: a plain Lua function, a C
function, a table with a `__call` metamethod, or another Titan function.
The call is checked the way every Titan call is — the arguments are
coerced to the parameter types and the results are checked against the
return types — and calling a value that turns out **not** to be callable
raises an ordinary Lua error at the point of the call. (A Titan function
value of the *exact* expected type skips the Lua stack entirely and calls
the native entry directly; everything else goes through a normal Lua
call.) A Lua function may still also travel through Titan opaquely as a
`value` inside a shared table and be handed back intact.

For a positional call whose static callee type is `value`, Titan derives a
temporary function type from the written arguments and from the surrounding
result demand. A finite annotated result supplies its expected type, an
unannotated finite result becomes `value`, and an open variadic, flexible
return, or array sink derives a flexible result tail. Named-call syntax is not
available through `value`, because the run-time callable carries no Titan
declaration names.

For storing, passing, returning and the two call paths in general, see
[Functions as values](functions.md#functions-as-values).

## Unannotated functions return nothing

A Titan function with no return annotation is a zero-return `() -> ()`
function (see [Functions](functions.md)), so from Lua it returns **no**
values, exactly like a Lua `function f() end`:

```lua
-- log.titan              -- Titan
function note(msg: string)   -- no annotation: returns ()
end
```

```lua
-- Lua
local m = require "log"
print(select('#', m.note("hi")))   --> 0
```

If you want a function that hands one `nil` back to Lua, annotate it
`: nil` explicitly.

## Errors cross the boundary as Lua errors

Every run-time error raised by Titan code — boundary check failures,
failed casts, arithmetic errors — is an ordinary Lua error. It propagates
to the Lua caller and is catchable with `pcall`, like an error from any
Lua or C function:

```lua
-- test.titan             -- Titan
function double(x: integer): integer
    return x * 2
end
```

```lua
-- Lua
local test = require "test"
local ok, err = pcall(test.double, "not a number")
print(ok)   --> false
print(err)  --> test.titan:...: type error, expected integer but found string
```

In addition, whenever an error is raised inside a Titan call, a single
**unified, intermingled traceback** — pure-Lua and Titan frames in call
order, innermost first — is recorded and can be retrieved afterwards with
`titan.backtrace()` from the `titan` Lua support module. The error value
seen by `pcall` is unchanged. See
[Error handling](error-handling.md) for the full error model and the
option-type idiom for recoverable failures.

## Multiple Lua states

A Titan module keeps no instance state in C globals: everything a module
instance owns (its variables, its module userdata, its record metatables)
lives inside one Lua state. Consequently:

* The same compiled module can be loaded into **several Lua states in the
  same process**, each getting its own fully independent instance —
  module variables in one state are invisible to the others.
* Within one Lua state there is exactly **one instance of each module**,
  no matter how it is reached: requiring it again, or loading two Titan
  modules that both import it, always yields the same instance with its
  state preserved.
* Record types keep their identity across all of this: a record created
  by one module instance is accepted by any other code in the same state
  that knows the same record type, even when the modules were loaded
  separately.
