# Lua interoperability

A compiled Titan module is, from Lua's point of view, an ordinary module:
you `require` it, call its functions, read and write its exported
variables, and pass values back and forth. There is no marshalling layer
and no container copying — Titan operates on Lua-GC values, selecting an
Array's canonical proxy when its private backing crosses a Lua-visible edge.
What a genuine Lua-to-Titan boundary adds is the target-directed
**dynamic coercion** defined by the type system: function arguments,
module/record writes, non-nil Array writes, and results from non-Titan Lua
callables all use one conversion policy. Containers are checked only at their
outer representation there; later typed Array and Map reads use a different,
strict gradual guard. A mismatch raises a normal run-time error rather than
producing a wrongly typed native value. This chapter describes the boundary
from the Lua programmer's side: what `require` returns, what each Titan
type looks like in Lua, exactly where dynamic conversions and strict guards
run, and what does and does not work in each direction.

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
* **one namespace per exported record or union type**, a small table holding
  public nominal functions — in particular the automatically generated
  constructor when it is public, so `mod.Point.new(2, 3)` works from Lua for a
  public `new` or union-variant constructors (see [Records](records.md) and
  [Unions](unions.md));
* **exported module variables**, read and written through the metatable
  so that reads always see the current value and writes are dynamically converted
  (see [Module variables from Lua](#module-variables-from-lua) below).

An exported [Interface](interfaces.md) is type-only and adds no member or
namespace to the Lua module value. Lua can receive Interface wrappers produced
by Titan, but cannot construct one through `mod.InterfaceName`.

Because the module value is a userdata, `type(require "m")` is
`"userdata"`, not `"table"`; functions and nominal namespaces are
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

The same qualified Lua identity applies to every standard module, including
`titan.coroutine`, `titan.async`, `titan.timer`, `titan.io`, `titan.fs`,
`titan.net`, `titan.ssl`, `titan.url`, `titan.http`, `titan.os`, `titan.peg`,
`titan.string`, `titan.math`, `titan.lua`, `titan.iter`, and `titan.gc`. The
private `titan.uv` plumbing module uses the same canonical identity. SSL, URL,
and HTTP use the documented short Titan imports alongside the other public
modules; math, Lua loading, iteration, and GC retain qualified Titan imports. Requiring
`titan.string` does not mutate Lua's `string` table or string metatable. In an
installed Titan 0.20 tree, generated
loaders under `<root>/share/lua/5.5/titan/` all open the DSO form
`<root>/lib/titan/0.20/titan.so` and invoke their own exact Lua entries. Titan
imports may instead select the paired self-describing `titan.a`; both forms
expose the same logical-module ABI/types. The installation does not create
child DSOs, parent-level or `lib/lua` copies, symbolic links, or hard links.

## How values map between the two languages

Every Lua-representable Titan value has a canonical Lua representation. Most
values are handed out directly; an Array backing is represented by its
one-to-one proxy rather than copied. A C scalar is representable only after
its exact value passes the configured Lua numeric-carrier check, while C
aggregates and C function pointers have no Lua representation. Entering Titan,
each value is checked (and, for numbers, possibly converted) against the
declared type:

| Titan type | A Lua caller may pass | Lua receives back |
| --- | --- | --- |
| `integer` | a Lua integer, or a Lua float with an integral value (converted) | a Lua integer (`math.type` is `"integer"`) |
| `float` | a Lua float, or a Lua integer (converted to float) | a Lua float |
| `boolean` | **any value**, converted by truthiness — see below | `true` or `false` |
| `string` | a Lua string only — numbers are *not* coerced | the same string |
| `nil` | only `nil` | `nil` |
| `{T}` (array) | a canonical Titan Array proxy from the same Lua state; elements are **not** checked here | the *same* userdata proxy — aliased, not copied |
| `{K:V}` (map) | any table; the contents are **not** checked here | the *same* table — aliased, not copied |
| record type | a userdata created by that same record type (from any module instance) | a userdata carrying the record's metatable |
| union type | a userdata created by that exact union type | the same opaque union userdata |
| Interface type | an existing wrapper of that exact nominal Interface type; never a bare record or union | the same Interface wrapper userdata |
| function type | any boxed value; callability/signature is deferred to invocation | the same boxed value; a Titan-defined function is its canonical closure |
| `T?` (option) | `nil`, or a value accepted by the same dynamic rule as `T` | `nil`, or whatever `T` produces |
| `value` | anything | the value, unchanged |

Notes on the entries that deserve them:

* **Numbers follow Lua's own conversion rules.** Passing `2.0` where an
  `integer` is expected works; passing `2.5` raises a run-time error of
  the shape `file:line:col: type error, number '2.5' has no integer
  representation`. Passing an integer where a `float` is expected converts
  it silently, just as Lua arithmetic would. The exact same rules apply to
  function arguments, exported module and record writes, non-nil Array
  writes, and non-Titan Lua results entering Titan.
* **Boolean targets accept anything, by truthiness.** A Titan
  `boolean` at any genuine Lua boundary never raises a type error: the value is converted
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

  The same truthiness rule applies to a `boolean` module/record field, Array
  writer, or non-Titan Lua result. A strict implicit `value -> boolean`
  projection or typed container read is different and requires an actual
  boolean tag.
* **Strings are not coerced from numbers.** Where Lua's standard library
  often accepts a number and converts it, a Titan `string` parameter
  raises `type error, expected string but found number`.
* **Arrays and maps have distinct boundary representations.** Arrays are
  canonical Titan userdata proxies; maps are ordinary Lua tables. Both retain
  identity and are shared rather than copied — see
  [Sharing arrays and maps](#sharing-arrays-and-maps-with-lua).
* **Records are userdata, not tables** — see
  [Records from Lua](#records-from-lua).
* **Unions are opaque userdata** — see
  [Unions from Lua](#unions-from-lua).
* **`nil` and options.** A `T?` target accepts nil first and otherwise
  recursively applies the same dynamic rule as plain `T`. Thus `integer?`
  converts an integral float and `boolean?` truthiness-converts every present
  value while preserving nil. A `T?` result reaches Lua as nil or a plain `T` value.
  Since reading a missing array or map element in Titan produces an
  option (see [Option types](option-types.md)), `nil` flows across the
  boundary exactly as a Lua programmer would expect.
* **`value` is the deliberate escape hatch**: it accepts any Lua value
  and hands it back unchanged. A later implicit Titan projection is strict;
  a written `value as/is T` deliberately requests this chapter's broad
  dynamic conversion instead.

This target table is an application of the single
[normative boundary matrix](types.md#normative-boundary-matrix), which is
authoritative when another chapter discusses the same edge.

Interface targets use exact nominal wrapper identity. Lua may supply an
already-constructed wrapper of the requested Interface type, but a bare record
or union is never inspected and dynamically wrapped merely because its Titan
methods would satisfy that Interface structurally.

A raw C pointer has no corresponding dynamic target rule: lightuserdata proves
only that an address was boxed, not its pointee type. Titan therefore rejects
implicit Lua-result/container/callable paths that would need to establish one.
Only a written FFI cast may make that explicitly unsafe assertion.

## Where dynamic conversions and strict guards run

The shared dynamic conversion runs at exactly these places:

1. **The coercive Lua entry of a Titan function, once per argument** —
   including the receiver of a
   method call (`self` is checked like any other nominal argument).
2. **Writes to exported module variables from Lua** (`mod.x = v`).
3. **Writes to record fields from Lua** (`rec.x = v`).
4. **Non-nil writes through an Array proxy's `__newindex`**, using the
   construction-time writer carried by that Array.
5. **Results entering Titan from a non-Titan Lua callable.**
6. **A written `value as/is T`**, which explicitly requests the same dynamic
   operation even though the syntax appears in Titan.

Separate **strict** guards run for an implicit `value -> T` projection, every
typed Array element read, every typed Map value read, and every argument/result
observed through a non-exact branded Titan function view.

And, just as importantly, where they do *not* happen:

* **Never recursively while a container crosses.** A `{string:integer}` Map parameter
  requires a table, while an `{integer}` Array parameter requires a valid
  canonical Titan Array proxy. Neither check walks the contents. Instead,
  every typed read inside Titan strictly checks the requested element type, so
  a wrongly-typed element produces a
  run-time error *later*, deterministically, at the Titan code that reads
  it — never silent misbehavior. Raw Lua can freely mutate a Map. An Array
  instead intercepts every ordinary Lua write and dynamically converts a
  non-nil element before committing it; a later read still performs its
  independent strict guard for the current static view.
* **Not on exact native Titan calls.** A direct Titan-to-Titan call, including
  across modules, needs no boundary checks because the compiler has already
  proven the types match. The same is true for a function value whose exact
  run-time type tag matches its static type. A non-exact but branded Titan
  closure uses the strict generic entry in its trailer. Only a genuine Lua
  call of Titan uses the closure's coercive entry; a non-Titan Lua callable
  uses an ordinary Lua call followed by dynamic result conversion.

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
it dynamically converts the arguments the callee observes. If a synthesized
`nil` does not fit the parameter type, the call raises the usual boundary type
error. Every collected variadic argument uses the same target-directed
conversion for its declared element type.

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

A Titan Map *is* an ordinary Lua table. Passing one in either direction passes
a reference to the same object, with no copying. Mutations made on one side
are immediately visible on the other:

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
Titan reads that element. The read uses the strict target guard regardless of
origin: Titan does not remember that the slot came from Lua and does not apply
the broader dynamic conversion at that later point:

```lua
-- Lua (continuing)
m.foo = "wat"
test.f(m)  --> error: test.titan:...: type error, expected integer but found string
```

An Array instead reaches Lua as userdata with a protected
`"Titan array metatable"` metatable value. Lua may use positive integer
indexing, assignment, and `#` through its `__index`, `__newindex`, and `__len`
callbacks. The proxy preserves holes and reports the deterministic highest
present positive index:

```titan
-- arrays.titan
function make(): {value}
    return {10, nil, 30}
end
```

```lua
local arrays = require "arrays"
local xs = arrays.make()
assert(type(xs) == "userdata")
assert(xs[1] == 10 and xs[2] == nil and xs[3] == 30 and #xs == 3)
xs[3] = nil
assert(#xs == 1)
```

A plain Lua table is not an Array and is rejected for an `{T}` parameter.
Likewise, a forged or structurally invalid userdata is rejected; Lua obtains a
valid Array only from Titan code. Nested Array elements cross as their
canonical proxies, while nested Maps remain tables.

A non-nil Lua write through the Array proxy is dynamically converted by the
writer closure installed when that Array was constructed. A `{integer}`
construction therefore converts `2.0` to an integer, while an inadmissible
value raises before capacity, length, or contents change. Nil deletes before
conversion and never invokes the writer. Passing the Array through `value`,
another static view, an import, or a nested container preserves the same
canonical proxy and writer; the new view does not replace the construction
policy. A later typed Titan read remains strict and does not consult that
writer.

An Array is table-like, but it is not a Lua table. Stock Lua 5.5's `table.*`
functions operate on the Array proxy through its `__index`, `__newindex`, and
`__len` callbacks, so operations such as insertion, removal, movement,
sorting, and concatenation use the public Array behavior. In contrast,
`rawget`, `rawset`, and `rawlen` require an actual table and reject the
userdata proxy. This distinction is a property of stock Lua 5.5's table
library, not a second Array representation.

For both container kinds, checking every element on each crossing would make
the boundary cost proportional to container size. Titan instead validates the
container representation at the edge, converts intercepted non-nil Lua Array
writes one element at a time, and strictly checks each element when typed code
reads it. A bad element therefore cannot be used at the wrong type. See
[Arrays and maps](arrays-maps.md) for the complete container semantics.

## Records from Lua

A Titan record arrives in Lua as a **userdata**, not a table — records
are nominal, fixed-shape values and do not have a table representation
(see [Records](records.md)). The userdata carries a metatable, shared by
all instances of the record type in the Lua state, that makes it behave
like an object:

* **Field reads** (`p.x`) return a public field's value; record-typed fields
  arrive as their own userdata.
* **Field writes** (`p.x = v`) use the same target-directed dynamic
  conversion as a function formal, module variable, or Array writer, with the standard
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
p.x = 10                          -- dynamically converted write
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

## Unions from Lua

An exported union name is a read-only namespace table on the module userdata.
It holds public variant constructors and public user-declared union functions;
private variants and statics are absent. Each entry is the canonical
first-class closure, so repeated reads have stable identity.

A constructed union value is userdata. Its tag and payload are intentionally
opaque to Lua: there is no `.tag`, `.payload`, or variant field. Public
methods are available through normal `:` calls, arbitrary reads report that
the member is not found in the union, and every write fails. The protected
metatable string is `"Titan union <qualified-name>"`.

```lua
local messages = require "messages"
local value = messages.Message.write("hello")
assert(type(value) == "userdata")
assert(messages.Message.write == messages.Message.write)
print(getmetatable(value)) -- Titan union messages.Message
```

Passing a union back into Titan checks the exact nominal metatable identity.
Two separately constructed values compare by userdata identity even when they
use the same variant and equal payloads. Payload access is available only to
Titan code through `case`.

## Interfaces from Lua

An Interface wrapper is userdata with one protected metatable per fully
qualified Interface in a Lua state. It exposes public Interface methods through
ordinary lookup and no fields, constructors, statics, implementation names, or
vtable reflection. Lua may read a method as a callable or invoke it with colon
syntax; every write to the wrapper is rejected.

Lua obtains such a wrapper only when Titan has already performed a statically
checked record/union-to-Interface conversion:

```lua
local m = require "sample"
local box = m.make_box()       -- a bare record userdata
local sink = m.wrap(box)       -- Titan returns an Interface wrapper

m.use(sink)                    -- accepted: exact wrapper
assert(not pcall(m.use, box))  -- rejected: no dynamic structural discovery
sink:put(1)                    -- ordinary Interface method call
```

The exact-wrapper-only rule is uniform for Interface-typed function arguments,
module-variable writes, record-field writes, non-nil Array writes, and results
entering Titan from a non-Titan callable. For `I?`, nil is accepted first and a
present value must be an exact `I` wrapper. A raw Lua Map write is not
intercepted; the later typed Titan read strictly rejects a bare record or
wrong-Interface wrapper.

Calling a method checks the receiver's exact Interface identity, dynamically
converts its explicit Lua arguments under the method signature, dispatches
through the wrapper, and converts results for Lua. Debug-library or C-API
mutation of the wrapper's protected internals is outside Titan's safety
contract. See [Interfaces](interfaces.md#lua-behavior).

## Module variables from Lua

Exported (non-`local`) module variables are readable and writable from
Lua as members of the module value, as in the `counter` example above.
Reads always observe the current value — including changes made by Titan
code — and writes made from Lua are immediately visible to Titan, because
both sides share one storage location. Writes use the target-directed dynamic
conversion at run time:

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

The integral-float conversion above is not a special module-field rule. The
same `integer` target accepts and converts it at a Lua function entry, public
record-field write, non-nil Array write, or non-Titan Lua result.

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

The value passed for `f` may be any boxed Lua value; acceptance into a
Function slot deliberately defers callability. Plain Lua functions, C
functions, tables with a `__call` metamethod, and Titan functions are
callable. Calling a value that turns out **not** to be callable raises an
ordinary Lua error at the point of the call. A Titan function value of the
exact expected type skips the Lua stack and calls its native entry directly.
A non-exact Titan-branded closure instead uses its strict trailer: aligned
arguments and observed results must pass gradual guards, with no ordinary
scalar, Option, or Interface-wrapper coercion lifted through the function type.
A non-Titan callable uses an ordinary Lua call, and each result entering Titan
uses the broad dynamic conversion for its requested target type. A Lua function
may still also travel through Titan opaquely as a `value` inside a shared table
and be
handed back intact.

For a positional call whose static callee type is `value`, Titan derives a
temporary function type from the written arguments and from the surrounding
result demand. A finite annotated result supplies its expected type, an
unannotated finite result becomes `value`, and an open variadic, flexible
return, or positional Array/integer-Map sink derives a flexible result tail.
Named-call syntax is not available through `value`, because the run-time
callable carries no Titan declaration names.

For storing, passing, returning, and the three call paths in general, see
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
instance owns (its variables, its module userdata, its record, union,
Interface, and Array metatables)
lives inside one Lua state. Consequently:

* The same compiled module can be loaded into **several Lua states in the
  same process**, each getting its own fully independent instance —
  module variables in one state are invisible to the others.
* Within one Lua state there is exactly **one instance of each module**,
  no matter how it is reached: requiring it again, or loading two Titan
  modules that both import it, always yields the same instance with its
  state preserved.
* Record, union, and Interface types keep their identity across all of this:
  a nominal value or Interface wrapper created by one module instance is
  accepted by any other code in the same state that knows that exact qualified
  type, even when the modules were loaded separately.
