# Interoperating with Lua

A compiled Titan module shares Lua's garbage collector and value representation directly—there is no marshalling layer and no container copying when values cross between Lua and Titan.

At genuine Lua-to-Titan edges (function arguments, exported variable writes, mutable record and Array writes, and results returned from Lua callbacks), Titan runs a checked **dynamic conversion** against the declared type. Inside Titan, reading from a shared container or projecting an untyped `value` applies a **strict guard**. Any mismatch raises a normal Lua error rather than corrupting native data.

## Requiring a Titan module

Compiling a library produces a native provider (`.so` and `.a` on Linux and macOS; `.dll` on Windows). A plain Lua host installs Titan's package searcher once with `require "titan"`, and then loads compiled modules with ordinary `require`:

```titan
-- counter.titan
count: integer = 0

function bump(n: integer): integer
  count = count + n
  return count
end
```

```sh
titanc -o out counter
```

```lua
-- Lua host (run with TITAN_PATH_0_6='out;;')
require "titan"
local counter = require "counter"

print(counter.bump(10))    --> 10
print(counter.count)       --> 10
counter.count = 100
print(counter.bump(1))     --> 101
```

Standalone Titan executables, isolated [`lua.new()`](standard-library-lua.md#independent-lua-states) states, and [`thread`](standard-library-thread.md) workers already have Titan's package searcher installed. For `TITAN_PATH_0_6` and stock-Lua setup details, see [Appendix B](toolchain.md).

`require` returns a **module userdata** (`type(m) == "userdata"`) with a protected metatable (`getmetatable(m)` returns `"Titan module <name>"`; `setmetatable` fails). Its visible members are:

- **Exported functions:** read-only callables (`local` functions are invisible to Lua).
- **Exported record and union namespaces:** read-only tables holding public constructors (`mod.Point.new`, `mod.Message.text`) and public static functions. When a record's `new` is public, the namespace also supports calling `mod.Point(...)` directly via `__call`.
- **Exported module variables:** readable directly; mutable variables accept dynamically checked writes, while `const` variables reject writes.

Exported Interfaces are type-only and add no runtime member to the module userdata.

When one provider bundles multiple logical roots (such as `pkg.left` and `pkg.right` in `pkg.so`), `require "pkg.left"` and `require "pkg.right"` share the provider file while initializing independently with separate module state. Every successfully initialized Titan module also publishes its loader to `package.preload`, so embedded dependencies of a standalone executable can be reached via `require` without a separate `.so`.

### Qualified standard-library names

In Lua, load Titan's standard-library modules under their qualified `titan.*` names so Lua's own `os`, `string`, `io`, `math`, and `coroutine` libraries remain untouched:

```lua
require "titan"
local lua_os = require "os"          -- Lua's standard table
local titan_os = require "titan.os"  -- Titan module userdata

assert(type(lua_os) == "table")
assert(type(titan_os) == "userdata")
```

All 26 native standard modules use this qualified naming (`titan.async`, `titan.coroutine`, `titan.fs`, `titan.gc`, `titan.http`, `titan.io`, `titan.iteration`, `titan.json`, `titan.lua`, `titan.math`, `titan.net`, `titan.os`, `titan.path`, `titan.peg`, `titan.protobuf`, `titan.reflect`, `titan.sqlite3`, `titan.ssl`, `titan.string`, `titan.test`, `titan.thread`, `titan.timer`, `titan.transfer`, `titan.url`, `titan.uv`, `titan.websocket`). The bare name `"titan"` is reserved for the support module that installs the searcher.

## How values map between Titan and Lua

| Titan type | Lua caller may pass | Lua receives back |
| --- | --- | --- |
| `integer` | Lua integer, or integral Lua float (converted) | Lua integer (`math.type == "integer"`) |
| `float` | Lua float or Lua integer (converted) | Lua float |
| `boolean` | Any value, converted by Lua truthiness | `true` or `false` |
| `string` | Lua string only (numbers are **not** coerced) | Same string |
| `nil` | Only `nil` | `nil` |
| `{T}` | Canonical mutable Titan Array proxy (elements checked on read) | Same mutable userdata proxy (aliased) |
| `const { T }` | Canonical const Titan Array proxy (elements checked on read) | Same const userdata proxy (aliased) |
| `const? { T }` | Either mutable or const Titan Array proxy | Same userdata proxy (aliased) |
| `{K: V}` | Any Lua table (contents checked on read) | Same Lua table (aliased) |
| Record | Userdata of that exact record type | Userdata with record metatable |
| Union | Userdata of that exact union type | Opaque union userdata |
| Interface | Exact wrapper, or bare userdata with a compiled witness for that Interface | Existing or fresh Interface wrapper |
| Function | Any boxed value (callability checked at call time) | Boxed callable |
| `T?` | `nil`, or any value accepted by `T` | `nil`, or what `T` returns |
| `value` | Anything | Value unchanged |

Key boundary behaviors:

- **Numeric conversion matches Lua:** Passing `2.0` to an `integer` parameter succeeds; `2.5` raises `number '2.5' has no integer representation`. Passing an integer to a `float` parameter widens cleanly.
- **Booleans use Lua truthiness:** A `boolean` parameter never raises a type error from Lua—`nil` and `false` become `false`, and every other value (including `0` and `""`) becomes `true`:

```titan
-- pick.titan
function pick(flag: boolean, when_true: integer, when_false: integer): integer
  if flag then return when_true else return when_false end
end
```

```lua
local m = require "pick"
assert(m.pick(true, 1, 2) == 1)
assert(m.pick(nil, 1, 2) == 2)
assert(m.pick(0, 1, 2) == 1)
```

- **Strings never coerce from numbers:** Passing `42` to a `string` parameter raises `type error, expected string but found number`.
- **Options preserve `nil`:** `T?` accepts `nil` directly and applies `T`'s dynamic rule to any non-`nil` value. In particular, `boolean?` keeps `nil` distinct while truthiness-converting present values.
- **Raw C pointers cannot cross dynamically:** Lightuserdata carries no C pointee tag, so Lua cannot pass or return a raw `foreign *T` implicitly; recovering one from `value` requires an explicit unsafe FFI `as` cast ([Chapter 16](ffi.md)).

## Dynamic conversions versus strict guards

Titan distinguishes two runtime checks:

1. **Dynamic conversion** runs at genuine Lua-to-Titan edges:
   - arguments to a Titan function or method called from Lua;
   - writes from Lua to exported mutable module variables (`mod.x = v`) and mutable record fields (`rec.x = v`);
   - non-`nil` writes from Lua to a mutable Array proxy (`xs[i] = v`);
   - results returning into Titan from a non-Titan Lua callable; and
   - explicit `value as T` and `value is T` expressions in Titan.
2. **Strict guards** run inside Titan for implicit `value -> T` projections and every typed read from an Array or Map (`xs[i]`, `m[k]`). A strict `integer` guard requires an actual Lua integer tag and rejects `2.0`; a strict `boolean` guard requires an actual boolean and rejects `0`.

Containers are **never scanned recursively** when crossing the boundary. Passing a Map verifies that it is a table; passing an Array verifies that it is a valid Titan Array proxy of the matching mutability qualifier. Elements are checked lazily when typed Titan code reads them.

When a boundary check fails, the error message begins with the Titan declaration's `file:line:col:` position, while the Lua traceback points to the Lua call site.

## Calls, multiple returns, and errors

When Lua calls a Titan function, argument adjustment follows Titan's normal rules: missing arguments are filled with `nil` (raising if the parameter does not accept `nil`), and surplus arguments are ignored unless the function is variadic (`...: T`). Lua calls are always **positional**: writing `mod.clamp { upper = 10 }` in Lua passes one ordinary Lua table as the first positional argument rather than invoking Titan's compile-time named-call syntax.

Multiple returns and flexible returns (`(...: T)`) map directly to Lua multiple returns. A Titan function without a return annotation returns **zero values**, not `nil`:

```titan
-- calc.titan
function divmod(a: integer, b: integer): (integer, integer)
  return a // b, a % b
end

function touch(label: string)
  -- No return annotation: returns 0 values to Lua.
end
```

```lua
local calc = require "calc"
local q, r = calc.divmod(17, 5)
assert(q == 3 and r == 2)
assert(select("#", calc.touch("hi")) == 0)
```

Every runtime error raised by Titan—including `raise`, failed casts, and boundary type errors—propagates to Lua as a normal error catchable with `pcall` and `xpcall`. After an error crosses out of Titan, `require("titan").backtrace()` returns the unified, intermingled Titan-and-Lua stack traceback:

```lua
local titan = require "titan"
local calc = require "calc"

local ok, err = pcall(calc.divmod, "bad", 2)
assert(not ok)
print(err)
print(titan.backtrace())
```

## Arrays, Maps, records, unions, and Interfaces

### Maps

A Titan Map `{K: V}` **is** an ordinary Lua table, passed by reference with zero copying. Mutations on either side are immediately visible to the other:

```titan
-- scores.titan
function bump_score(scores: {string: integer}, player: string, delta: integer): {string: integer}
  local current = scores[player] or 0
  scores[player] = current + delta
  return scores
end
```

```lua
local scores = require "scores"
local table_scores = { ada = 10 }
local same = scores.bump_score(table_scores, "ada", 5)
assert(same == table_scores and table_scores.ada == 15)

table_scores.ada = "invalid"
-- Raises when Titan strictly reads scores["ada"]:
local ok = pcall(scores.bump_score, table_scores, "ada", 1)
assert(not ok)
```

### Arrays

An Array crosses to Lua as a protected **userdata proxy** (not a table), preserving its exact mutability qualifier (`{T}` vs `const { T }`) and holes:

```titan
-- arrays.titan
function sample(): {integer}
  local xs = {10, 20, 30}
  xs[2] = nil
  return xs
end
```

```lua
local arrays = require "arrays"
local xs = arrays.sample()
assert(type(xs) == "userdata")
assert(xs[1] == 10 and xs[2] == nil and xs[3] == 30 and #xs == 3)
xs[2] = 20.0      -- dynamically converted to integer 20 by the proxy writer
xs[3] = nil       -- deletes slot 3
assert(#xs == 2)
```

- Plain Lua tables are rejected for Array parameters; Lua obtains valid Array proxies from Titan.
- Mutable proxies check non-`nil` writes using the element type with which the Array was constructed; `nil` deletes the slot. Const proxies have no writer and reject every assignment.
- Stock Lua `table.*` functions work through metamethods (`table.concat` and `table.unpack` on either qualifier; `table.insert`, `table.remove`, `table.sort` on mutable proxies). `rawget`, `rawset`, and `rawlen` reject Array proxies because they require plain tables.

### Records

Records appear in Lua as userdata with a protected metatable (`"Titan record mod.Name"`):

- Public fields support dot reads and (when mutable) dynamically checked writes. Writes to `const` fields raise.
- Public methods use colon syntax (`p:move(2, 3)`).
- Reading or writing unknown or `local` fields raises immediately rather than returning `nil`.
- Public constructors and static functions live on `mod.RecordName`; when `new` is public, Lua can call either `mod.Point(2, 3)` (via `__call`) or `mod.Point.new(2, 3)`.
- Equality is userdata identity.

```titan
-- point.titan
record Point
  x: float
  y: float
end

function Point:move(dx: float, dy: float)
  self.x = self.x + dx
  self.y = self.y + dy
end
```

```lua
local geom = require "point"
local p = geom.Point(2, 3)         -- calls geom.Point.new(2, 3)
assert(type(p) == "userdata")
p:move(1.5, -1.0)
assert(p.x == 3.5 and p.y == 2.0)
```

### Unions

An exported union provides a read-only namespace table on the module userdata holding its public variant constructors and static functions (`mod.Event.click(10, 20)`). Constructed union values are opaque userdata (`"Titan union mod.Name"`): Lua can call public union methods and pass the value back to Titan, while tag and payload inspection happen exclusively inside Titan `case` statements.

### Interfaces

An Interface value arrives in Lua as a read-only userdata wrapper exposing its declared field snapshots and public methods (`writer:write("hi")`); every write to the wrapper raises.

When passing a value from Lua into an Interface parameter, Titan accepts either an existing wrapper for that Interface or a bare record/union userdata whose concrete type has a statically compiled conversion to that Interface in an initialized module (producing a fresh wrapper). Titan does not perform dynamic structural method lookup at run time.

## Module variables from Lua

Exported module variables share storage directly with Titan. Reads reflect current values immediately; writes to mutable variables apply dynamic conversion, and writes to `const` variables raise:

```lua
local counter = require "counter"
counter.count = 2.0       -- valid: integral float converts to integer 2
-- counter.count = 2.5    -- raises type error
-- counter.count = "ten"  -- raises type error
```

Accessing a nonexistent or `local` module member raises `member '<name>' does not exist in Titan module '<mod>'` rather than returning `nil`.

## Calling Lua from Titan

Titan calls into Lua in two ways: through passed callable values, or by dynamically loading Lua code with `import "lua"`.

### Passing Lua callables as arguments

Any Lua function, C function, or table with a `__call` metamethod can be passed to a Titan function-typed parameter (or held as `value` and called contextually). Callability is verified at invocation time, and results returning from a non-Titan callable undergo dynamic conversion to the declared return types:

```titan
-- map_apply.titan
function apply_twice(fn: function (integer): (integer), x: integer): integer
  return fn(fn(x))
end
```

```lua
local m = require "map_apply"
assert(m.apply_twice(function (n) return n + 3 end, 4) == 10)
```

When a Titan function value is called from Titan with an exact signature match, it executes directly without entering the Lua call boundary. When called from Lua, it uses its ordinary dynamic Lua entry.

### Loading Lua code and modules (`import "lua"`)

When a Titan program genuinely needs to compile Lua chunks at run time or load an existing Lua module dynamically, use [`import "lua"`](standard-library-lua.md):

- `lua.load(chunk, name?, env?)` and `lua.load_from_reader(reader, name?, env?)` compile a Lua text or binary chunk into `function (...: value): (...: value)`, raising on syntax errors.
- `lua.dofile(filename, ...)` (native only) reads and executes a Lua file asynchronously inside an async Task.
- `lua.require(modname): value` loads a Lua, C, or Titan module through `package.loaded` and `package.searchers`.

Isolate `import "lua"` behind a narrow boundary and recover typed Titan values immediately:

```titan
local io = import "io"
local lua = import "lua"

function evaluate_formula(source: string, x: integer): integer
  local env: {string: value} = { ["x"] = x }
  local chunk = lua.load("return " .. source, "=formula", env)
  local result = chunk()
  return result as integer
end

function main(args: {string}): integer
  io.print("result = " .. evaluate_formula("x * 2 + 1", 20))
  return 0
end
```

Supplying a custom `env` table chooses the chunk's `_ENV` upvalue; it is **not** a security sandbox for untrusted code or bytecode.

## Multiple Lua states

Titan modules store all instance state—module variables, metatables, and nominal identities—inside each Lua state rather than in process-wide C globals:

- The same compiled module can load independently into multiple Lua states in one process, each with separate module variables.
- Within a single Lua state, every `import` and `require` of a module shares the exact same instance and nominal type identities.
- Array proxies belong strictly to the Lua state that created them.

From Titan, `lua.new()` creates a completely isolated Lua state with its own globals, garbage collector, and snapshotted native module preload table. Use `state:run(...)` for synchronous execution or `state:run_async(...)` (native only) for execution on libuv's worker pool, passing values through [`TransferValue`](standard-library-transfer.md):

```titan
local async = import "async"
local io = import "io"
local lua = import "lua"

function main(args: {string}): integer
  local state = lua.new()
  defer state:close()

  local product = state:run(
    "local a, b = ...; return a * b",
    "=mul",
    async.TransferValue.is_integer(6),
    async.TransferValue.is_integer(7)
  )
  case product
  when is_integer(n) then
    io.print("6 * 7 = " .. n)
  else
    raise "unexpected result from isolated Lua state"
  end
  return 0
end
```

For full-featured multi-core parallelism with isolated states, channels, and task-compatible joins, prefer [`import "thread"`](concurrency.md#parallelism-with-os-threads). For Lua threads (coroutines) sharing one state, enter other threads only through `resume`—calling back into an active ancestor thread via raw C `lua_call`/`lua_pcall` breaks [abandoned coroutine unwinding](coroutines.md#abandoned-coroutines).
