# Titan quick tour

Titan is a statically typed, ahead-of-time compiled sister language to Lua.
Its syntax is intentionally familiar to Lua programmers, but its modules,
records, containers, calls, and Lua boundaries all have statically checked
types.

This tour uses only APIs implemented by the ABI-0.22 compiler and standard
library. It assumes that Titan has been installed as described in the
[README](../README.md#install), and that the installation's `bin` directory is
first on `PATH`. Run every `titanc` command from the directory that contains
the example source tree: the compiler accepts dotted module names, not source
paths.

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
titanc hello
./hello Titan
test "$(cat greeting.txt)" = 'Hello, Titan!!!'
```

This small program already shows several Titan rules:

- an import is a local module alias;
- every parameter and record field has a type;
- top-level functions are exported unless they are `local`;
- a record is nominal and has a synthesized positional `new` function;
- `args` is an Array, so its first user argument is at index 1 and an absent
  element produces an option value;
- `or` handles that absent value without an explicit unwrap; and
- importing `fs` installs the standalone async bootstrap, so asynchronous
  filesystem operations retain their direct, synchronous-looking spelling in
  `main`.

`strings.rep` has a third `separator: string?` parameter. The two-argument call
is legal because an omitted fixed argument is filled with `nil`, which that
option type accepts. This is Titan's general fixed-call rule, not a special
default-argument syntax.

## Values, containers, and options

An Array `{T}` uses positive integer positions and may contain holes. A Map
`{K: V}` is a key/value dictionary. They are distinct types and have distinct
run-time representations.

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

An indexed read has an option type because the position or key may be absent.
An unmarked local such as `word` immediately unwraps the option and raises if
the Array has a hole there. The marked local `count?` preserves absence so the
next line can handle it. Use that distinction deliberately: do not let an
unintended nil travel deeper into the program.

A method receiver is another automatic unwrap site. After a nil guard, call
the method directly on the option; no cast is needed:

```titan
local strings = import "string"

function whole_match(expression: strings.Regex,
                     subject: string): string?
  local found: strings.RegexMatch? = expression:match(subject)
  if not found then return nil end
  return found:whole()
end
```

If the receiver were nil, the call itself would raise. Here the preceding
guard makes that automatic unwrap known-safe.

For an Array, `#values` is the greatest present positive index, not the number
of present elements. Deleting an interior position does not reduce the length
while a later position remains present:

```titan
function length_with_a_hole(): integer
  local values: {value} = {10, 20, 30}
  values[2] = nil
  return #values -- still 3
end
```

Records model fixed nominal data. Unions model a closed set of tagged cases:

```titan
union Lookup
  found: string
  missing
end

function describe(result: Lookup): string
  case result
  when found: text then
    return "found " .. text
  when missing then
    return "missing"
  else
    return "unknown"
  end
end
```

Construct these values with `Lookup.found("Titan")` and `Lookup.missing()`.
Union constructors are positional, and each `when` arm is a full block with
ordinary `defer`, `catch`, and `finally` behavior.

## Functions and result lists

A function's return annotation describes its complete result list. Omitting
the annotation means zero results, not one nil result:

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

Some APIs return a run whose length is chosen at run time. The string module's
`byte` operation is one example, and an Array constructor is an open result
sink:

```titan
local strings = import "string"

function bytes(text: string): {integer}
  return {strings.byte(text, 1, -1)}
end
```

The final call expands into every byte that actually exists. A finite
consumer instead sees each requested flexible position as optional. Only the
last expression of an expression list expands; parentheses force a call to
one result. See [Functions](language/functions.md), [variadic
parameters](language/variadic-parameters.md), and [flexible
returns](language/flexible-returns.md) for the complete adjustment rules.

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

With no `main`, the module builds as a library:

```sh
titanc greeting
lua -e 'print(require("greeting").make("Lua"))'
```

Another Titan module uses `local greeting = import "greeting"`. Lua uses
`require "greeting"` for this application module. Standard-library names are
different: Titan uses established short imports such as `import "fs"`,
`import "url"`, and `import "http"`, while Lua uses the qualified identities
`require "titan.fs"`, `require "titan.url"`, and `require "titan.http"`.
Modules without short-import sugar use qualified Titan imports too, such as
`import "titan.math"`. The qualified names do not replace Lua's own `io`,
`os`, `math`, or `string` libraries.

A dotted module name maps to directories: `import "app.model"` resolves the
logical module `app.model`. One logical module may be a flat source
`app/model.titan` or a folder whose main source is
`app/model/model.titan`. Folder contributors share the same module namespace;
they are not independently importable submodules. The
[folder-module chapter](language/folder-modules.md) gives the exact layout and
ordering rules.

## Errors and deterministic cleanup

Run-time errors are ordinary Lua error values. Raise one explicitly with
`raise`, and attach `catch` or `finally` directly to any block—there is no
`try` keyword.

The most common cleanup pattern is to defer a close immediately after a
resource has been acquired:

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
  raise -- preserve the original value and traceback
end
```

`defer` runs on fallthrough, return, break, and error. Several defers in one
block run last-in-first-out. A cleanup error replaces the pending return or
error, just as an error in `finally` does. Every structural `io.Closer`
accepts repeated `close()` calls safely; consult the concrete resource for
its post-close read/write and cancellation behavior.

## Tasks and asynchronous work

The public asynchronous facade is `async`; `timer`, `fs`, `net`, `ssl`,
`http`, and `os` build on the same Runtime. The synchronous `url` parser is
also reusable without opening a connection. In a standalone program the event
loop is driven automatically:

```titan
local async = import "async"
local timer = import "timer"

function main(args: {string}): integer
  local results: {string: string} = {}
  async.run(function (): value
    timer.sleep(5)
    results["left"] = "ready"
  end)
  async.run(function (): value
    async.yield()
    results["right"] = "ready"
  end)
  -- The standalone Runtime stays alive until both Tasks finish, even though
  -- main itself returns first.
  return 0
end
```

```sh
titanc concurrent
./concurrent
```

`async.run` schedules a Task but does not run it inline. A Task executes in a
libuv callback until it finishes, raises, or starts another asynchronous
operation and yields. `async.yield()` is an explicit fairness turn; CPU-heavy
code that never yields blocks the loop. An uncaught Task error is logged with
its traceback and ends only that Task; `Task:status()` retains that exact
failure and traceback. Fixed-arity `any`, `race`, `all`, and `join`
combinators coordinate bounded Task groups without cancelling unfinished
inputs. The other Tasks continue. Close resources explicitly. Runtime
shutdown drains and closes its libuv handles,
but closing a process watcher does not terminate or reap its child, and raw
File descriptors remain caller-owned.

A Lua host drives the same Runtime explicitly and uses qualified module
names:

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

## Files, strings, PEGs, and generic iteration

This executable combines the shipped filesystem, byte-string, regex, and PEG
APIs. Save it as `parse_name.titan`:

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
  for match: strings.RegexMatch in words:gmatch(subject) do
    if #match:whole() > 0 then count = count + 1 end
  end

  fs.write_file("name.out", strings.upper(name))
  if count > 0 then return 0 else return 3 end
end
```

```sh
printf 'Titan language\n' > name.txt
titanc parse_name
./parse_name name.txt
test "$(cat name.out)" = TITAN
```

Strings are binary byte sequences. Regex and PEG character classes are not
implicitly Unicode. `Pattern:match` is anchored at its initial position,
whereas `Regex:match` performs a leftmost search unless its expression is
anchored. `Regex:gmatch` supplies the iterator to Titan's generic `for`; its
missing state, initial-control, and close tuple slots are filled with nil.

For ready-made HTTP URL parsing, `local url = import "url"` exposes
`url.parse(source): (url.Url?, url.Error?)`. Success returns a normalized
component record and nil; malformed input returns nil plus a structured
one-based byte diagnostic instead of raising. The module compiles its labeled
PEGs once and is usable independently of the HTTP client. Code that receives
an HTTP scheme, Host authority, and origin-form target separately can call
`url.parse_request(scheme, authority, target)` with the same result tuple;
scheme, authority, and target boundaries are then validated before
normalization.

## Child processes

Use `io.popen` when a program intentionally wants shell syntax and one stream
containing the child's merged stdout and stderr. Drain that stream before
waiting:

```titan
local fs = import "fs"
local io = import "io"
local strings = import "string"

local function read_all(command: io.InputOutputStream): string
  local output = strings.writer()
  for chunk in command:read do
    output:write(chunk)
  end
  return output:drain()
end

function main(args: {string}): integer
  local command =
    io.popen("printf 'child output'; printf 'warning' >&2")
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

`io.popen` invokes `/bin/sh -c`, captures stdin, and presents exactly one
facade over the merged output pipe. Its `wait` method preserves the complete
`os.ExitStatus`, including signal termination.

Use `os.spawn` when a shell is not wanted. It starts the named executable
directly with the supplied argv and keeps stdout and stderr separate unless a
spawn option explicitly merges them. Capture and inheritance options also
decide which of the optional `Process.stdin`, `stdout`, and `stderr` endpoints
exist in the parent. Drain captured output concurrently with input and `wait`,
or a full operating-system pipe can deadlock the child and parent. These
process APIs target Titan's current Linux and macOS hosts.

## Math, collection iteration, GC, and dynamic Lua

The newer `math`, `iter`, `gc`, and `lua` modules use qualified Titan names.
They do not replace Lua's libraries and do not add compiler short-import
sugar.

`titan.math` exposes a deliberately typed numerical surface. Operations that
produce floating-point values take and return `float`; integer-only operations
say so explicitly. Its random generator follows Lua 5.5's xoshiro256** stream,
including deterministic two-word seeds:

```titan
local math = import "titan.math"

function numerical_example(): boolean
  math.randomseed(17, 29)
  local die = math.random(1, 6) as integer
  local hexadecimal? = math.tonumber("0xff")
  return die >= 1 and die <= 6 and
         hexadecimal == 255 and
         math.sqrt(81.0) == 9.0
end
```

`tonumber` returns `value?` because a successful numeral may be an integer or
a float. `titan.math` deliberately has no `type` operation: use Titan's static
types or the ordinary `is`/`as` gradual checks at a `value` boundary.

`titan.iter` supplies the familiar collection iterators without adding methods
to Array or Map types:

```titan
local iter = import "titan.iter"

function total(scores: {string: integer}): integer
  local result = 0
  for _name: string, score: integer in iter.pairs(scores) do
    result = result + score
  end
  return result
end

function visit_holes(values: {value}): integer
  local positions = 0
  for _index, _item in iter.ipairs(values) do
    positions = positions + 1
  end
  return positions
end
```

Unlike Lua's `ipairs`, this Array iterator visits every position through
`#values`, including an interior nil element. Its first result is the nonnil
integer index, so the nil item does not end generic iteration.

`titan.gc` exposes explicit collector actions, observation, tuning, weak Map
configuration, and reachability-owned finalizers for tables and full
userdata. The stop action and status query are intentionally different
functions:

```titan
local gc = import "titan.gc"

local function finish_owner(_owner: value): ()
  -- Clear and release reachability-owned state here.
end

function configure_cache(cache: {value: value})
  gc.weak(cache)
  gc.finalizable(cache, finish_owner)

  gc.pause()             -- maps to collectgarbage("stop")
  if not gc.paused() then raise "collector did not pause" end
  gc.resume()

  local previous = gc.pause_percent()
  gc.pause_percent(previous)
end
```

`pause_percent` is the incremental collector's tuning accessor; `pause()` has
side effects, while `paused()` only reports whether the collector is stopped.
Weak and ephemeron configuration preserves an existing Map metatable and
changes only its raw `__mode` field. `finalizable` likewise preserves that
exact metatable while replacing raw `__gc`; its callback receives the
finalized value. Cleanup should clear owned state before releasing it so the
callback remains safe if cleanup is retried or partially completed.

Finally, `titan.lua` is the audited dynamic boundary for compiling Lua chunks,
executing Lua files, and loading modules. Flexible arguments and results,
including inner nil values, pass through unchanged:

```titan
local lua = import "titan.lua"

function dynamic_results(): (...: value)
  local chunk = lua.load("return ...", "=quick-tour", nil)
  return chunk("first", nil, "third")
end
```

`load` uses the complete byte length, accepts text and binary chunks, and
raises a load error instead of returning `(nil, message)`. `load_from_reader`
does not close its Reader. `dofile` owns and closes its File, and
`titan.lua.require` replaces the blocking source-file search with asynchronous
filesystem operations while retaining preload, C-module, Titan-shim, and
`package.loaded` behavior. See the four standard-library chapters in the
[language reference](language/index.md) for the complete contracts.

## Where to go next

- Read the [language reference](language/index.md) for normative semantics.
- Read the [style guide](style-guide.md) before adding application or standard
  library code.
- Read the [implementation documentation](implementation/index.md) when the
  compiler, generated C, ABI, or Lua boundary is relevant.
