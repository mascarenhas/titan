# A Tour of Titan

Titan is a statically typed programming language that compiles ahead of time
to native code and runs inside the Lua runtime. Its syntax, values, and
garbage collector follow Lua closely, while modules, records, unions,
containers, calls, and the boundary with Lua are statically checked.

This tour introduces the language through short, complete programs. It assumes
Titan is [installed](installation.md) and its `bin` directory is on `PATH`.
Two conventions apply to every command below:

- `titanc` takes dotted module names, not file paths. Run it from the source
  root: `titanc hello` compiles `hello.titan`.
- `-o out` places generated files under `out/` so the source tree stays clean.
  The executable for `hello` is `out/hello`.

## Compiling and running a program

Save this module as `hello.titan`:

```titan
local io = import "io"
local strings = import "string"

record Greeting
    name: string
    marks: integer
end

local function Greeting:render(): string
    return "Hello, " .. self.name .. strings.rep("!", self.marks)
end

function main(args: {string}): integer
    local name = args[1] or "world"
    local greeting = Greeting(name, 3)
    io.print(greeting:render())
    return 0
end
```

Compile and run it:

```sh
titanc -o out hello
./out/hello Titan
```

```text
Hello, Titan!!!
```

Several of Titan's core rules appear in these twenty lines:

- `import` binds a module to a local alias. Standard-library modules use short
  names such as `"io"` and `"string"`.
- Every function parameter and record field has a static type. Local variables
  such as `name` and `greeting` infer their types from their initializers.
- Top-level declarations are exported by default; `local` keeps a declaration
  private to its module.
- A `record` defines a nominal data type. Calling `Greeting(name, 3)` invokes
  its generated constructor, taking the fields in declaration order, and
  `Greeting:render()` defines a method whose receiver is `self`.
- `args` is an Array of command-line arguments. Reading `args[1]` yields an
  option type (`string?`), because the slot may be absent, and `or` supplies a
  default without an explicit unwrap.
- `strings.rep` has a third parameter, `separator: string?`. Omitting a fixed
  positional argument passes `nil`, which an option parameter accepts.
- A module that defines `function main(args: {string}): integer` builds as an
  executable. Importing `io` (or another asynchronous module such as `fs` or
  `http`) runs `main` on the event loop automatically, so I/O calls inside
  `main` read like ordinary blocking code.

## Arrays, Maps, and options

An Array `{T}` is indexed by positive integers and may contain holes. A Map
`{K: V}` is a key-value dictionary. They are distinct types with separate
representations:

```titan
local iteration = import "iteration"

function frequencies(words: {string}): {string: integer}
    local counts: {string: integer} = {}
    for i = 1, #words do
        local word = words[i]
        counts[word] = (counts[word] or 0) + 1
    end
    return counts
end

function titan_count(words: {string}): integer
    local counts = frequencies(words)
    local count? = counts["Titan"]
    return count or 0
end

function total_words(counts: {string: integer}): integer
    local total = 0
    for _, n in iteration.pairs(counts) do
        total = total + n
    end
    return total
end
```

Every indexed read returns an option type `T?`, because the position or key
may be absent. A plain inferred local (`local word = words[i]`) unwraps the
option immediately and raises an error if the slot is `nil`. Adding `?` to the
variable name (`local count? = counts["Titan"]`) keeps the option so the next
line can handle absence with `or`. Choose the plain form when absence is a
bug, and the `?` form when absence is expected.

For an Array, `#values` is the highest present positive index, not the count
of non-`nil` elements. Assigning `nil` to an interior position creates a hole
without changing `#`:

```titan
function length_with_hole(): integer
    local values = {10, 20, 30}
    values[2] = nil
    return #values -- 3, because position 3 is present
end
```

Method calls and field reads also unwrap options automatically. After checking
for `nil`, call the method directly on the optional variable—no cast is
needed:

```titan
local strings = import "string"

function whole_match(pattern: strings.Regex, subject: string): string?
    local found? = pattern:match(subject)
    if not found then return nil end
    return found:whole()
end
```

If `found` were `nil` at `found:whole()`, Titan would raise a runtime error at
the call site. The `if not found` guard ensures it is present.

## Records, methods, and unions

`Greeting` above showed a record with fixed fields and a method. A `union`
represents a closed set of tagged variants, each carrying zero or more payload
parts, and `case` dispatches on the tag. Unions can declare methods just like
records:

```titan
union Lookup
    found(string)
    redirect(target: string, permanent: boolean)
    missing()
end

function Lookup:describe(): string
    case self
    when found(text) then
        return "found: " .. text
    when redirect { target, permanent } then
        local kind = permanent and "permanent" or "temporary"
        return kind .. " redirect to " .. target
    when missing() then
        return "missing"
    end
end

function sample_lookups(): {string}
    return {
        Lookup.found("Titan"):describe(),
        Lookup.redirect { target = "/docs", permanent = true }:describe(),
        Lookup.missing():describe(),
    }
end
```

Each variant provides a constructor function on the union (`Lookup.found`,
`Lookup.redirect`, `Lookup.missing`). Multi-part variants accept both
positional arguments and named brace calls (`Lookup.redirect { ... }`), and
`case` binds payload parts positionally (`when found(text)`) or by name
(`when redirect { target, permanent }`). Because `Lookup:describe` handles
every variant of `Lookup` with a `return`, the compiler proves the method
cannot fall through.

## Functions, multiple results, and cleanup

A return annotation describes the entire result list. Omitting it means zero
results, not `nil`:

```titan
local strings = import "string"

function divmod(numerator: integer, denominator: integer): (integer, integer)
    return numerator // denominator, numerator % denominator
end

function quotient(a: integer, b: integer): integer
    local q = divmod(a, b) -- remainder is discarded
    return q
end

function bytes(text: string): {integer}
    return {strings.byte(text, 1, -1)}
end
```

Functions such as `strings.byte` return a flexible tail of results whose count
is decided at run time. Placing the call last inside an Array constructor
collects every returned value into the Array. Only the last expression in an
expression list expands; wrapping a call in parentheses, as in
`(divmod(17, 5))`, keeps only its first result.

For recoverable absence, return an option `T?`. For exceptional failure, raise
an error with `raise`, schedule cleanup with `defer`, and handle errors by
attaching a `catch` clause directly to an existing block:

```titan
local fs = import "fs"
local io = import "io"

function first_line(path: string): string?
    local file = fs.open(path, "r")
    defer file:close()
    return file:read_until("\n", true)
end

function optional_first_line(path: string): string?
    return first_line(path)
catch
    return nil
end

function logged_first_line(path: string): string?
    return first_line(path)
catch
    -- `error: value` and `traceback: string` are read-only bindings here.
    io.print("failed to read", path, error)
    raise -- rethrow with the original error value and traceback
end
```

Place `defer` immediately after acquiring a resource. Deferred statements run
last-in, first-out whenever their block exits—whether by fallthrough,
`return`, `break`, or a raised error.

## Modules and Lua

A module without `main` compiles to a native library that both Titan and Lua
can load. Save this as `greeting.titan`:

```titan
function make(name: string): string
    return "Hello, " .. name .. private_suffix()
end

local function private_suffix(): string
    return "!"
end
```

Compile it and call it from Lua. Requiring `"titan"` installs Titan's package
searcher, which locates compiled modules along `TITAN_PATH_0_6`:

```sh
titanc -o out greeting
TITAN_PATH_0_6='out;;' \
    lua -e 'require "titan"; print(require("greeting").make("Lua"))'
```

```text
Hello, Lua!
```

From another Titan module, write `local greeting = import "greeting"`.
Application modules keep the same dotted name in both languages, while
standard-library modules use short names in Titan (`import "fs"`,
`import "url"`) and `titan.`-prefixed names in Lua (`require "titan.fs"`,
`require "titan.url"`), leaving Lua's own standard libraries untouched.

Dotted module names map to directories: `import "app.model"` resolves either
to a flat file `app/model.titan` or to a folder module rooted at
`app/model/model.titan`, whose sibling `.titan` files share one namespace.

## Tasks and threads

Titan separates cooperative concurrency on one event loop from parallel
execution across OS threads.

Within one Lua state, `async.run` schedules lightweight cooperative Tasks. The
`timer`, `fs`, `net`, `ssl`, `http`, `websocket`, `sqlite3`, and `os` modules
all suspend the current Task on the shared event loop while waiting on I/O,
and `thread.Thread:task()` bridges an OS thread onto the same loop. Save this
as `concurrent.titan`:

```titan
local async = import "async"
local io = import "io"
local timer = import "timer"

function main(args: {string}): integer
    local left = async.run(function (): string
        timer.sleep(5)
        return "left"
    end)
    local right = async.run(function (): string
        async.yield()
        return "right"
    end)
    local a, b = async.all_two(left, right)
    io.print(a .. " and " .. b)
    return 0
end
```

```sh
titanc -o out concurrent
./out/concurrent
```

```text
left and right
```

Tasks take turns cooperatively: a Task runs until it returns, raises, or
suspends on an asynchronous call. Call `async.yield()` inside long CPU loops
so other Tasks and I/O callbacks can make progress. When calling Titan async
modules from a plain Lua script, drive the loop explicitly with
`async.loop()`:

```lua
require "titan"
local async = require "titan.async"
local timer = require "titan.timer"

local result
local task = async.run(function()
    timer.sleep(5)
    result = "done"
end)
async.loop()
assert(task:status():as_string() == "succeeded")
assert(result == "done")
```

For multi-core parallelism, `thread` spawns OS threads that each own an
isolated Lua state and event loop. Values are copied across threads rather
than shared, and threads communicate through bounded channels:

```titan
local thread = import "thread"

function main(args: {string}): integer
    local tx, rx = thread.channel<|integer|>(4)
    local producer = thread.spawn_one(
        function (out: thread.Sender<|integer|>): nil
            for i = 1, 5 do
                out:send(i * i)
            end
            out:close()
            return nil
        end,
        tx
    )

    local total = 0
    for _, square in rx:incoming() do
        total = total + square
    end
    producer:join()
    if total == 55 then return 0 else return 1 end
end
```

`spawn_one` copies the worker function and its argument into the new thread.
`send` waits when the bounded channel is full, `incoming()` stops once the
channel is closed and drained, and `join()` waits for the thread to finish.

## Native tests

A native test is a public function whose name begins with `test_` and whose
sole parameter is `test.Context`. `titanc --test` discovers every such
function and links a test runner executable—no `main` is needed.

Ordinarily a test module imports the library under test (for example,
`local calc = import "calc"`). Here is a self-contained test module saved as
`calc_test.titan`:

```titan
local test = import "test"

local function twice(x: integer): integer
    return x * 2
end

function test_twice(context: test.Context)
    test.assert(twice(21) == 42, "twice(21) should be 42")
end

function test_twice_negative(context: test.Context)
    test.assert(twice(-4) == -8)
end
```

Build and run it, optionally filtering by name:

```sh
titanc -o out --test calc_test
./out/calc_test
./out/calc_test --filter='test_twice$' --verbose
```

`test.assert` raises with the source location when its condition is false, and
the runner exits with status 1 if any test fails.

## Where to go next

- Continue with
  [Chapter 2: Lexical Structure, Values, and Expressions](expressions.md) for
  literals, operators, and casts.
- Browse the full [Table of Contents](index.md) to jump straight to any
  language topic or standard-library module.
- Read the [Titan style guide](../style-guide.md) for conventions on types,
  options, cleanup, and concurrency.
