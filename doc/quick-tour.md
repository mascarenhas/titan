# Titan quick tour

Titan is a statically typed language that compiles ahead of time to native code
and runs inside the Lua runtime. The syntax is close to Lua's, but modules,
records, containers, calls, and the boundary with Lua all have static types.

This tour walks through short programs that use the compiler and standard
library as they exist today. It assumes Titan is
[installed](language/installation.md) and that the installation's `bin`
directory is first on `PATH`.

Two conventions apply to every command below:

- `titanc` takes dotted module names, not file paths. Run it from the directory
  that holds the source: `titanc hello` compiles `hello.titan`.
- `-o out` puts all generated files under `out/`, so your source directory stays
  clean. The executable for module `hello` is `out/hello`.

## A first executable

Save this as `hello.titan`:

```titan
local fs = import "fs"
local strings = import "string"

record Greeting
  name: string
  marks: integer
end

local function render(greeting: Greeting): string
  return "Hello, " .. greeting.name ..
         strings.rep("!", greeting.marks)
end

function main(args: {string}): integer
  local name = args[1] or "world"
  local greeting = Greeting.new(name, 3)
  fs.write_file("greeting.txt", render(greeting))
  return 0
end
```

Compile and run it:

```sh
titanc -o out hello
./out/hello Titan
test "$(cat greeting.txt)" = 'Hello, Titan!!!'
```

What this program shows:

- `import` binds a module to a local name.
- Every parameter and record field has a type.
- Top-level functions are exported unless they are `local`.
- A record is a distinct named type. It gets a `new` function that takes the
  fields in order.
- `args` is an Array of the command-line arguments. `args[1]` is the first one,
  and reading a missing element gives an option value. `or` supplies the default
  without an explicit unwrap.
- A module that defines `function main(args: {string}): integer` builds into an
  executable. Importing `fs` makes `main` run as an async task, so file
  operations in `main` look like ordinary blocking calls.

`strings.rep` has a third parameter, `separator: string?`. You can omit it
because a missing fixed argument is filled with `nil`, which an option type
accepts. This is Titan's general call rule, not a default-argument feature.

## Values, containers, and options

An Array `{T}` is indexed by positive integers and may contain holes. A Map
`{K: V}` is a key/value dictionary. They are different types with different
runtime representations.

```titan
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
```

An indexed read has an option type, because the position or key may be absent.
A plain local such as `word` unwraps the option at once and raises an error if
the Array has a hole there. The marked local `count?` keeps the absence so that
the next line can handle it. Choose between them on purpose, so that an
unexpected `nil` does not travel further into the program.

A method receiver also unwraps automatically. After a `nil` check, call the
method on the option directly:

```titan
local strings = import "string"

function whole_match(expression: strings.Regex,
                     subject: string): string?
  local found? = expression:match(subject)
  if not found then return nil end
  return found:whole()
end
```

If `found` were still `nil`, the call itself would raise. Here the `nil` check
above it makes the unwrap safe, so no cast is needed.

For an Array, `#values` is the highest present positive index, not the number of
present elements. Setting an interior position to `nil` does not shorten the
Array while a later position is still present:

```titan
function length_with_a_hole(): integer
  local values: {value} = {10, 20, 30}
  values[2] = nil
  return #values -- still 3
end
```

A record holds fixed named fields. A union is a closed set of tagged cases:

```titan
union Lookup
  found(string)
  missing()
end

function describe(result: Lookup): string
  case result
  when found(text) then
    return "found " .. text
  when missing() then
    return "missing"
  else
    return "unknown"
  end
end
```

Build these values with `Lookup.found("Titan")` and `Lookup.missing()`. Union
constructors take their arguments by position. Each `when` arm is a full block,
so `defer` and `catch` work inside it as anywhere else.

## Functions and result lists

A return annotation describes the whole result list. Leaving it out means zero
results, not one `nil`:

```titan
function divmod(numerator: integer,
                denominator: integer): (integer, integer)
  return numerator // denominator, numerator % denominator
end

function quotient(): integer
  local q = divmod(17, 5) -- the remainder is discarded
  return q
end
```

Some functions return a run of values whose length is known only at run time.
`string.byte` is one, and an Array constructor accepts such a run:

```titan
local strings = import "string"

function bytes(text: string): {integer}
  return {strings.byte(text, 1, -1)}
end
```

The final call expands into every byte that exists. A fixed-size consumer sees
each requested position as optional instead. Only the last expression in a list
expands, and parentheses reduce a call to one result. See
[Functions](language/functions.md),
[variadic parameters](language/variadic-parameters.md), and
[flexible returns](language/flexible-returns.md) for the full rules.

## Modules and Lua

Suppose `greeting.titan` contains:

```titan
function make(name: string): string
  return "Hello, " .. name .. private_suffix()
end

local function private_suffix(): string
  return "!"
end
```

It has no `main`, so it builds as a library. Lua loads it with `require` once
`require "titan"` has installed Titan's package searcher, which finds the
provider along the [Titan path](language/modules.md#the-titan-path):

```sh
titanc -o out greeting
TITAN_PATH_0_6='out;;' \
  lua -e 'require "titan"; print(require("greeting").make("Lua"))'
```

Another Titan module uses `local greeting = import "greeting"`. Lua uses
`require "greeting"`. Standard-library modules are named differently in the two
languages: Titan uses short names (`import "fs"`, `import "url"`), and Lua uses
qualified names (`require "titan.fs"`, `require "titan.url"`).

A dotted module name maps to directories. `import "app.model"` finds either
`app/model.titan` or a folder whose main file is `app/model/model.titan`. The
other `.titan` files in that folder belong to the same module. They share its
namespace and cannot be imported on their own. See
[Folder modules](language/folder-modules.md).

## Errors and cleanup

Errors are ordinary Lua error values. Use `raise` to raise one, `catch` to handle
errors from a block, and `defer` to schedule cleanup. There is no `try` and no
user-written `finally`.

The usual pattern is to defer the close right after acquiring a resource:

```titan
local fs = import "fs"

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

function checked_first_line(path: string): string?
  return first_line(path)
catch
  -- `error: value` and `traceback: string` are available here.
  raise -- keep the original error value and traceback
end
```

`defer` runs when the block ends normally, returns, breaks, or raises. Several
defers in one block run last-in, first-out. An error in a deferred statement
replaces the pending return or error. Every `io.Closer` accepts repeated
`close()` calls. Check the concrete resource for what reads, writes, and
cancellation do after close.

## Tasks and asynchronous work

`async` is the public API for tasks. `timer`, `fs`, `net`, `ssl`, `http`, and
`os` run on the same event loop, and the `url` parser is plain synchronous code.
In an executable, the program drives the event loop for you:

```titan
local async = import "async"
local timer = import "timer"

function main(args: {string}): integer
  local results: {string: string} = {}
  async.run(function (): nil
    timer.sleep(5)
    results["left"] = "ready"
  end)
  async.run(function (): nil
    async.yield()
    results["right"] = "ready"
  end)
  -- The program keeps running until both tasks finish, even though
  -- main returns first.
  return 0
end
```

```sh
titanc -o out concurrent
./out/concurrent
```

`async.run` schedules a task and returns without running it. A task runs inside
a libuv callback until it finishes, raises an error, or starts an asynchronous
operation and waits. Tasks never run at the same time, and nothing preempts a
task: code that loops without waiting blocks everything, so call `async.yield()`
in long CPU-bound loops.

- An uncaught error in a task is logged with its traceback and ends only that
  task. `Task:status()` keeps the error and traceback.
- The fixed-arity combinators `any_*`, `race_*`, `all_*`, and `join*` wait on a
  bounded group of tasks. They do not cancel the tasks that are still running.
- Close resources yourself. Shutting down the event loop closes its libuv
  handles, but closing a process watcher does not kill or reap its child, and
  you must close raw file descriptors yourself.

A Lua program runs the event loop explicitly and uses qualified module names:

```lua
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

## Threads

`thread` runs a function on its own operating-system thread. Each thread has a
separate Lua state, so values are copied between threads and never shared.
Threads talk through bounded channels:

```titan
local thread = import "thread"

function main(args: {string}): integer
  local tx, rx = thread.channel<|integer|>(4)
  local producer = thread.spawn_one(function (out: thread.Sender<|integer|>): nil
    for i = 1, 5 do out:send(i * i) end
    out:close()
    return nil
  end, tx)

  local total = 0
  for _, square in rx:incoming() do
    total = total + square
  end
  producer:join()
  if total == 55 then return 0 else return 1 end
end
```

`spawn_one` copies the function and its argument when it is called, and raises
an error in the caller if either cannot be copied. `send` waits when the channel
is full. `incoming()` ends once the channel is closed and empty. `join()` waits
until the thread has finished and been joined, and returns its outcome without
raising. See the [thread chapter](language/standard-library-thread.md) for
thread groups, cancellation, and sending channel endpoints between threads.

## Native tests

A test is a public function that takes one `test.Context` and whose name starts
with `test_`. `titanc --test` finds these functions and links them into an
executable. You do not write a `main`. Save a module as `calc.titan`:

```titan
function twice(x: integer): integer
  return x * 2
end
```

And its tests as `calc_test.titan`:

```titan
local test = import "test"
local calc = import "calc"

function test_twice(context: test.Context)
  test.assert(calc.twice(21) == 42, "twice(21) should be 42")
end

function test_twice_of_negative(context: test.Context)
  test.assert(calc.twice(-4) == -8)
end
```

```sh
titanc -o out --test calc_test
./out/calc_test
./out/calc_test --filter='test_twice$' --verbose
```

`test.assert` raises an error when its condition is false. The runner reports
each failure with its source location and exits with status 1 if any test
failed. A run that finds no tests also exits 0, so check that the summary lists
the tests you expect. See [Testing Titan code](language/standard-library-test.md)
for subtests, cleanup, skipping, and async tests.

## Files, strings, PEGs, and generic iteration

This executable uses the file, string, regex, and PEG libraries together.
Save it as `parse_name.titan`:

```titan
local fs = import "fs"
local strings = import "string"
local peg = import "peg"

local function identifier(): peg.Pattern
  local first = peg.ranges("az", "AZ", "__")
  local rest = peg.ranges("az", "AZ", "__", "09")
  return peg.capture(peg.sequence(first, peg.zero_or_more(rest)))
end

function main(args: {string}): integer
  local path = args[1] or "name.txt"
  local subject = fs.read_file(path)
  local captured: value = identifier():match(subject)
  if not captured then return 1 end

  local name = captured as string
  local spelling = strings.compile_regex("^[A-Za-z_][A-Za-z0-9_]*$")
  if not spelling:match(name) then return 2 end

  local words = strings.compile_regex("[A-Za-z_][A-Za-z0-9_]*")
  local count = 0
  for match in words:gmatch(subject) do
    if #match:whole() > 0 then count = count + 1 end
  end

  fs.write_file("name.out", strings.upper(name))
  if count > 0 then return 0 else return 3 end
end
```

```sh
printf 'Titan language\n' > name.txt
titanc -o out parse_name
./out/parse_name name.txt
test "$(cat name.out)" = TITAN
```

Strings are byte sequences, not Unicode text, and regex and PEG character classes
work on bytes. `Pattern:match` matches only at the start of the subject.
`Regex:match` searches for the leftmost match unless the expression is anchored.
`Regex:gmatch` returns the iterator for Titan's generic `for`, and fills the
loop's missing state, initial-control, and close slots with `nil`.

For HTTP URLs, `url.parse(source)` returns `(url.Url?, url.Error?)`. On success
you get a normalized record and `nil`. On malformed input you get `nil` and an
error with a one-based byte position. It does not raise. If you already have the
scheme, authority, and request target separately, call
`url.parse_request(scheme, authority, target)`, which returns the same pair. The
parser works without the HTTP client.

## Child processes

Use `os.popen` when you want shell syntax and a single stream that carries the
child's stdout and stderr together. Read that stream to the end before calling
`wait`. This example uses POSIX shell syntax. Save it as `child.titan`:

```titan
local fs = import "fs"
local os = import "os"
local strings = import "string"

local function read_all(command: os.InputOutputStream): string
  local output = strings.writer()
  for chunk in command:read do
    output:write(chunk)
  end
  return output:drain()
end

function main(args: {string}): integer
  local command =
    os.popen("printf 'child output'; printf 'warning' >&2")
  defer command:close()

  local output = read_all(command)
  local status = command:wait()
  fs.write_file("child.output", output)
  if status.code == 0 and not status.signal then
    return 0
  else
    return 1
  end
end
```

```sh
titanc -o out child
./out/child
cat child.output
```

`os.popen` runs `/bin/sh -c` on Linux and macOS, and `cmd.exe /d /s /c` on
Windows, so the command string follows that shell's syntax. It captures stdin and
gives you one stream for the merged output. `wait` returns the full
`os.ExitStatus`, including the signal if a signal ended the child.

Use `os.spawn` when you do not want a shell. It runs the named executable
directly with the argument list you give it, and keeps stdout and stderr separate
unless you ask to merge them. Its capture and inherit options decide which of
`Process.stdin`, `stdout`, and `stderr` exist in the parent. Read captured output
while you write input and wait, or a full pipe can block both the child and the
parent.

## Math, iteration, GC, and dynamic Lua

`math` has typed signatures. Operations that produce floating-point values take
and return `float`, and integer-only operations are named as such. Its random
generator reproduces Lua 5.5's xoshiro256** sequence, including two-word seeds:

```titan
local math = import "math"

function numerical_example(): boolean
  math.randomseed(17, 29)
  local die = math.random(1, 6) as integer
  local hexadecimal? = math.tonumber("0xff")
  return die >= 1 and die <= 6 and
         hexadecimal == 255 and
         math.sqrt(81.0) == 9.0
end
```

`tonumber` returns `value?`, because a numeral can be an integer or a float.
`math` has no `type` function. Use Titan's static types, or `is` and `as` where a
`value` enters your code.

`iteration` provides the usual collection iterators without adding methods to
Array or Map:

```titan
local iteration = import "iteration"

function total(scores: {string: integer}): integer
  local result = 0
  for _, score in iteration.pairs(scores) do
    result = result + score
  end
  return result
end

function visit_holes(values: {value}): integer
  local positions = 0
  for _, _ in iteration.ipairs(values) do
    positions = positions + 1
  end
  return positions
end
```

Unlike Lua's `ipairs`, this Array iterator visits every position up to `#values`,
including an interior `nil`. Its first result is the integer index, which is never
`nil`, so a `nil` element does not end the loop.

`gc` controls the collector, sets weak Maps, and registers finalizers for tables
and full userdata. `pause()` stops the collector and `paused()` only reports
whether it is stopped:

```titan
local gc = import "gc"

local function finish_owner(_: {value: value}): ()
  -- Clear and release reachability-owned state here.
end

function configure_cache(cache: {value: value})
  gc.weak(cache)
  gc.finalizable<|{value: value}|>(cache, finish_owner)

  gc.pause()             -- maps to collectgarbage("stop")
  if not gc.paused() then raise "collector did not pause" end
  gc.resume()

  local previous = gc.pause_percent()
  gc.pause_percent(previous)
end
```

`pause_percent` reads or sets the incremental collector's pause parameter.
`gc.weak` and `gc.finalizable` keep the Map's existing metatable and change only
its `__mode` or `__gc` field. The finalizer receives the value as the exact type
you chose for `T`. Make cleanup clear the state it owns before releasing it, so
that running it again or after a partial run is safe.

Finally, `lua` is the dynamic boundary: it compiles Lua chunks, runs Lua files,
and loads modules. Arguments and results pass through unchanged, including inner
`nil` values:

```titan
local lua = import "lua"

function dynamic_results(): (...: value)
  local chunk = lua.load("return ...", "=quick-tour", nil)
  return chunk("first", nil, "third")
end
```

`load` uses the full byte length and accepts text and binary chunks. On a load
error it raises instead of returning `(nil, message)`. `load_from_reader` does not
close its Reader, and `dofile` closes the file it opens. `lua.require` searches
for source files with asynchronous filesystem calls, and otherwise follows Lua's
rules for preload, C modules, Titan loaders, and `package.loaded`. Use `lua`
sparingly: it can bypass static checks as thoroughly as the C interface can. See
the [Lua states and loading chapter](language/standard-library-lua.md) for the
full contracts.

## Where to go next

- The [language reference](language/index.md) describes the language and every
  standard-library module.
- The [style guide](style-guide.md) covers conventions for application and
  standard-library code.
- The [implementation documentation](implementation/index.md) explains the
  compiler, generated C, ABI, and the Lua boundary.
