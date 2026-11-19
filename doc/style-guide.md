# Effective Titan: style guide

This guide collects idiomatic conventions for writing clear, predictable Titan
code. It complements the normative [language reference](language/index.md);
where a style recommendation and a language rule differ, the reference and
compiler win.

## Keep types specific

Choose the narrowest static type that fits the problem. Reserve `value` for
genuine dynamic boundaries (Lua interop, heterogeneous JSON) and convert to
concrete Titan types close to that boundary.

Use each composite type for its distinct role:

- `record` for fixed nominal data and methods;
- `union` for a closed set of tagged alternatives;
- `interface` for a nominal behavioral view satisfied structurally at
  conversion sites;
- Array `{T}` (or `const { T }` / `const? { T }`) for positive integer
  positions that may contain holes; and
- Map `{K: V}` for key/value lookup and Lua table interop.

Do not use `{integer: T}` as a stand-in for an Array: Maps and Arrays have
different identities, `#` semantics, and Lua representations. Because `#arr`
is the highest present positive index rather than an element count, handle
potential `nil` entries whenever an Array can have interior holes.

## Let precise inference speak

Omit local and generic-`for` type annotations when the initializer or iterator
already gives the exact type:

```titan
local iteration = import "iteration"

function total(scores: {string: integer}): integer
  local result = 0
  for _, score in iteration.pairs(scores) do
    result = result + score
  end
  return result
end
```

Keep an explicit annotation when it adds information: public API declarations,
empty `{}` or `nil` initializers, contextual generic or lambda instantiation,
flexible/dynamic result demands, Interface or FFI conversions, or intentional
widenings.

Use `_` (not `_item` or `_unused`) for intentionally discarded local results
or loop variables; repeated `_` names are allowed in one declaration or loop
list:

```titan
local iteration = import "iteration"

function count_entries(values: {value}): integer
  local positions = 0
  for _, _ in iteration.ipairs(values) do
    positions = positions + 1
  end
  return positions
end
```

Omit unused `case` payload bindings unless deliberately forcing a checked
projection. In private callables with one unused positional parameter, `_` with
its type (`function ignore(_: value)`) is idiomatic; keep distinct names on
public parameters because they form the named-call surface.

## Make absence visible where it is expected

Indexed Array and Map reads produce option types (`T?`). An ordinary inferred
local unwraps the option and raises on `nil`; appending `?` to the variable
name preserves the option without repeating the base type:

```titan
function required_at(values: {string}, index: integer): string
  local required = values[index]        -- string; raises if absent
  return required
end

function optional_at(values: {string}, index: integer,
                     fallback: string): string
  local optional? = values[index]       -- string?; preserves nil
  return optional or fallback
end
```

Use the first form when absence is a bug and the second when absence is normal
control flow. Prefer `T?` over sentinel values, and handle `nil` near the
lookup. Option conversions do not lift through containers or function types.

Compare explicitly with `== nil` or `~= nil` when a present value can itself be
falsy—especially `boolean?`, where a plain `if` merges `false` and `nil`:

```titan
local function enabled_by_default(enabled: boolean?): boolean
  if enabled == nil then return true end
  return enabled
end
```

Method receivers, field accesses, indices, and operators automatically unwrap
options. After checking for `nil`, use the variable directly instead of adding
a redundant `as` cast:

```titan
local strings = import "string"

function whole_match(pattern: strings.Regex, subject: string): string?
  local found? = pattern:match(subject)
  if not found then return nil end
  return found:whole()
end
```

Write `found:whole()`, not `(found as strings.RegexMatch):whole()`. See
[A Tour of Titan](language/tour.md) for more option idioms.

## Distinguish fixed calls, variadic inputs, and flexible results

Fixed positional calls fill omitted parameters with `nil` (checked against the
parameter type) and evaluate-then-discard surplus arguments. Write optional
parameters as `T?` rather than adding a variadic tail `...: T`. Reserve
`...: T` for functions that consume an arbitrary number of trailing values, and
flexible returns `(...: T)` for runtime-sized result tails (preferring `{T}`
for conceptually unbounded collections).

Only the final expression in an expression list expands; parenthesize a call
when you want exactly one result.

Keep short, obvious calls positional (`Point(x, y)`). Use declaration-based
named calls (`f { ... }`) for long constructor parameter lists, adjacent
same-typed or boolean flags, and runs of `nil` or `0` placeholders. Match the
actual parameter names of the selected declaration (an overridden `Record.new`
may name parameters differently from record fields). Because named calls are
unavailable on arbitrary function values and variadic functions, avoid APIs
whose clarity depends on names that vanish at callable boundaries.

## Acquire, then defer the close

Place `defer` immediately after acquiring a resource so ownership and cleanup
stay visually paired across normal returns, `break`, and raised errors:

```titan
local fs = import "fs"

function first_chunk(path: string): string?
  local file = fs.open(path, "r")
  defer file:close()
  return file:read()
end
```

Multiple `defer` statements execute last-in-first-out; use `defer do ... end`
for multi-statement cleanup. Close resources explicitly rather than relying on
finalizers or runtime shutdown—an `fs.File`, for example, is an OS descriptor
that async runtime shutdown does not close automatically.

Attach `catch` and `defer` directly to the enclosing function, loop, or `if`
block—do not introduce an extra `do ... end` merely to hold them. Use bare
`raise` inside `catch` to rethrow with the original error and traceback. Note
that an error raised inside `defer` replaces any pending return or error.

Every concrete type satisfying `io.Closer` must make repeated `close()` calls
safe no-ops once closed.

## Return generic iterators in tuple order

Generic `for ... in` expects the four-slot tuple
`(iterator, state, initial_control, close)` with missing trailing slots filled
with `nil`. When `close` is supplied, Titan runs it on exhaustion, `break`,
`return`, or error, passing `state` if `close` takes an argument.

Return the full tuple directly and use the resource itself as `state` when
possible:

```titan
local fs = import "fs"

local function next_line(file: fs.File): string?
  return file:read_until("\n", true)
end

local function close_file(file: fs.File)
  file:close()
end

function lines(file: fs.File):
    (function (fs.File): (string?), fs.File, nil, function (fs.File): ())
  return next_line, file, nil, close_file
end
```

Generic `for` stops only on `nil` (`false` and `""` are real iteration values).
For any nil-terminated `io.Reader` stream, pass the bound `:read` method
directly instead of hand-writing a primed `while` loop:

```titan
local io = import "io"

function copy_all(reader: io.Reader, output: io.Writer)
  for chunk in reader:read do
    output:write(chunk)
  end
end
```

## Reuse the standard string writer

Accumulate multi-piece strings with `string.writer()` instead of repeatedly
concatenating in a loop or building a custom chunk array and join helper.
`string.writer()` handles linear-time assembly and size checks synchronously;
use `async.reader_writer_channel` when the stream itself needs Task
synchronization.

## Capture parameters directly

Closures capture parameters, locals, and `self` directly, and the closure
environment keeps them rooted for GC. Do not create dummy local aliases such as
`local rooted = self` solely to keep a value alive; introduce an alias only
when you need a distinct snapshot or narrowed value.

## Put behavior and state on their real owner

Prefer the shorthand `Record(...)`, `Record{...}`, or `Record "text"` when
constructing records. Keep `Record.new` when taking the constructor as a
function value or passing `new`'s own explicit generic type arguments.

Define custom construction on `[local] function Record.new(...)` using a
module-private `{ ... }` literal inside the record's module. Keep domain
factories such as `fs.open` and `net.connect` named for their action.

When a private helper primarily reads or mutates one record, write it as a
`local` method on that record:

```titan
local record Pending
  number: integer
end

local record Event
  number: integer
end

local record Watcher
  pending: {Pending}
end

local function Watcher:map(item: Pending): Event
  return Event(item.number)
end

local function Watcher:drain(): {Event}
  local pending = self.pending
  self.pending = {}
  local events: {Event} = {}
  for index = 1, #pending do
    events[index] = self:map(pending[index])
  end
  return events
end
```

Keep a free helper only when it coordinates multiple owners or serves as a
standalone callback value. Avoid speculative forwarding wrappers, shadow
indices, or duplicate validity flags around an existing owner.

## Use finalizers only for reachability ownership

Use `gc.finalizable` only as a reachability fallback for tables or full
userdata that own external resources, storing per-value state on the owner and
making cleanup idempotent. Never rely on a finalizer as a substitute for
explicit `close()`, and never let a finalizer race an in-flight libuv callback
whose owner must stay rooted until terminal completion.

## Treat async calls as ownership boundaries

Application code should import `async` alongside the high-level modules
(`timer`, `fs`, `net`, `ssl`, `url`, `http`, `websocket`, `os`). Reserve `uv`
for low-level library adapters that manage libuv handles directly.

- `async.run` schedules a Task and returns immediately. Observe Tasks via
  `Task:status()`, `join*`, `all*`, `race*`, `any*`, or shared channels, and
  explicitly cancel Tasks you do not need (`race*` and `any*` do not cancel
  losers).
- Uncaught Task errors log their traceback and end only that Task.
- Call `async.yield()` inside long CPU loops so other Tasks can run.
- Keep callback owners rooted until terminal completion and cleanup finish,
  even after cancellation.
- When coordinating a custom group of Tasks with terminal listeners, check
  current statuses first, allocate one fresh `async.ResumeToken`, register
  listeners capturing that token, `defer` every returned remover, and call
  `async.suspend(token)` once. Never poll in a loop.
- Use `os.popen` for simple shell commands with merged output (draining output
  before `wait`, or driving input and output concurrently to avoid pipe
  deadlocks). Use `os.spawn` for direct argv control, separate stdout/stderr,
  or inherited descriptors.

## Pick the right cross-thread tool

Every thread created by `thread.spawn*` runs its own isolated Lua state and
event loop; values cross by copy or move. Pick the primitive that matches your
delivery rule:

- **`async.channel<|T|>`** for Tasks inside the **same** Lua state (zero copy).
- **`thread.channel<|T|>`** for lossless FIFO message streams between OS
  threads (bounded with backpressure).
- **`async.Receiver`** to wake another state with only the **latest** value
  (coalescing; unread overwritten packets and attached channel endpoints are
  disposed automatically).

Wait for a worker thread with `Thread:join()` or compose `Thread:task()` with
`async` combinators; release shared external resources only after `join()`
returns or the proxy Task becomes terminal. For manual-handoff resources
(`fs.File`, `net.Connection`, `ssl.Connection`, `http.Exchange`,
`websocket.Connection`), follow the
[shared manual-handoff rules](language/standard-library-transfer.md#shared-manual-handoff-rules).
Never hold a `uv` OS mutex across a Task suspension; coordinate with channels
instead.

## Design one logical module before choosing its files

Start with a flat `pkg/name.titan`. When a module grows large, convert it to a
folder module (`pkg/name/name.titan` as canonical main plus immediate sibling
`.titan` contributors). Contributors share one namespace, interface, artifact,
and `local` scope—they are not submodules and cannot be imported individually.

Put the optional `do ... end` module initializer in the main file. Do not rely
on contributor filename order for function or type declarations; keep module
variables and prerequisite imports ordered cleanly before expressions that read
them, and order `foreign import` directives intentionally for C preprocessing.

## Use canonical Titan imports and qualified Lua loads

In Titan source (including standard-library code), always use the short
canonical names for standard modules, aliasing names that collide with type
words (such as `strings` for `"string"`):

```titan
local fs = import "fs"
local strings = import "string"
```

The 27 short names are `async`, `browser` (browser-only), `coroutine`, `fs`,
`gc`, `http`, `io`, `iteration`, `json`, `lua`, `math`, `net`, `os`, `path`,
`peg`, `protobuf`, `reflect`, `sqlite3`, `ssl`, `string`, `test`, `thread`,
`timer`, `transfer`, `url`, `uv`, and `websocket`.

From Lua, always load them by their qualified `titan.*` names so Lua's own
built-in libraries stay intact:

```lua
local fs = require "titan.fs"
local strings = require "titan.string"
```

Application modules use the same dotted name in both languages (`import
"app.model"` and `require "app.model"`).

## Write native tests as ordinary modules

Write discoverable tests as public `test_*` functions taking `test.Context`.
Keep reusable helpers as ordinary `local` functions; use `context:run` when
nested reporting or scoped cleanup is useful, giving subtests short local
names:

```titan
local strings = import "string"
local test = import "test"

function test_writer_accumulates(context: test.Context)
  local writer = strings.writer()
  context:cleanup(function() writer:close() end)
  writer:write("alpha")
  writer:write("-beta")
  test.assert(writer:drain() == "alpha-beta")
end
```

Use `defer` for cleanup tied to the current function body and `context:cleanup`
for teardown that must run after subtests finish. Do not `catch` `test.skip`
or assertion failures unless explicitly testing failure behavior.

## Keep Lua and C machinery behind narrow audited boundaries

Treat `foreign` calls, `foreign function` bodies, and raw-pointer handoff as an
explicit unsafe boundary: ordinary Titan code without them is memory-safe,
while foreign code and its callers uphold pointer, lifetime, ownership, ABI,
and threading invariants.

- Keep raw C pointers, borrowed Lua stack slots, and local FFI types private to
  the module that owns their lifetime, and return ordinary Titan records,
  unions, Interfaces, Arrays, Maps, options, strings, or numbers from public
  APIs.
- Use `titan.lua` only when runtime Lua loading or dynamic module discovery is
  genuinely required; narrow returned `value` results immediately. Remember
  that a custom Lua environment selects the chunk's `_ENV` and is not a security sandbox.
- Prefer `gc.weak` and `gc.ephemeron` over hand-crafted `__mode` metatables.
- Do not link private bundled standard-library archives (such as libuv or
  LPegLabel) into application extensions; import the public standard module
  instead.

## Write native bindings Titan-first

Contributors authoring C, Lua C API calls, or browser JavaScript inside Titan's
runtime or standard library follow the six layering, pinning, rooting, and
boundary rules documented in
[Standard-library maintenance](implementation/standard-library-maintenance.md#keep-c-and-the-lua-c-api-to-what-titan-cannot-do).

## Keep examples and documentation exact

- Every `titan` code block in documentation should be a complete module or
  executable that compiles cleanly with `titanc -o out`. Use `text` fences for
  signature fragments, grammar snippets, and intentionally invalid examples.
- Describe user-facing behavior in terms of what callers can observe—keep
  private fields, internal state machines, and compiler passes in
  [implementation documentation](implementation/index.md).
- Keep language documentation, implementation documentation, and tests updated
  together when behavior changes.
