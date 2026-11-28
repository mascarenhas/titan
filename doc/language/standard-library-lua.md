# Lua states and loading standard library

`titan.lua` compiles and executes Lua chunks in the current Lua state, loads
modules through Lua's `package.loaded` cache and searchers, and creates
isolated `lua.Lua` states with independent globals, registries, and garbage
collectors.

- **Import:** `local lua = import "lua"` (Titan) · `require "titan.lua"` (Lua)
- **Targets:** Native & Browser (subset: `Lua:run_async` and `Lua:run_async_from_loader` are native-only; `dofile` and `package.path` source search work over the browser VFS; see [On the browser](#on-the-browser))

## Quick example

Compile a Lua chunk with a custom environment and call a Lua standard module in
the current state:

```titan
local lua = import "lua"
local io = import "io"

function main(_args: {string}): integer
  local env: {string: value} = { ["factor"] = 7 }
  local chunk = lua.load("local n = ...; return n * factor", "=scale", env)
  local product: integer = chunk(6)
  io.print(product) -- 42

  local math_mod: {string: value} = lua.require("math")
  local abs: function(integer): integer = math_mod["abs"]
  io.print(abs(-42)) -- 42
  return 0
end
```

## Loading chunks in the current state

```text
function load(chunk: string, name: string?,
              env: value): function(...: value): (...: value)
function load_from_reader(reader: io.Reader, name: string?,
                          env: value): function(...: value): (...: value)
function dofile(filename: string, ...: value): (...: value)
```

### `load`

`load` compiles all bytes in `chunk` as a Lua text or binary chunk using its
explicit byte length (embedded NUL bytes are preserved). Syntax or load errors
raise directly rather than returning `(nil, message)`. `name` sets the
diagnostic chunk name, defaulting to `chunk`.

The returned callable accepts and returns a flexible sequence of `value`s,
preserving `nil` slots. Omitting `env` (or passing `nil`) keeps the default
global environment; any non-nil `env` replaces the chunk's first upvalue
(`_ENV` for ordinary text chunks, or ignored for binary chunks with no
upvalues). `load` compiles without executing the chunk.

### `load_from_reader`

`load_from_reader` iterates `reader:read` until `nil` (EOF), buffers every
chunk (including `""`), and compiles the result with the same rules as `load`.
It never closes `reader`. If `reader:read` suspends, `load_from_reader` must
run inside an async Task:

```titan
local lua = import "lua"
local strings = import "string"

function load_passthrough(): (value, value, value)
  local reader = strings.reader("return ...")
  defer reader:close()
  local chunk = lua.load_from_reader(reader, "=passthrough", nil)
  return chunk("first", nil, "third")
end
```

### `dofile`

`dofile` opens `filename` via [`fs.open`](standard-library-fs.md), compiles its
contents with chunk name `@filename`, executes it with all trailing arguments,
and returns all results (preserving interior `nil`s). The file closes on
success, read/compile error, or runtime error. Because opening and reading use
asynchronous filesystem I/O, `dofile` must run inside an
[async Task](async-io.md).

## Requiring modules

```text
function require(modname: string): value
```

`require` shares Lua's registry-backed `package.loaded` table: a truthy cached
entry returns immediately, a loader's non-nil result is cached and returned,
and a `nil` result with no `package.loaded[modname]` entry installs `true` (a
cached `false` triggers a fresh load on the next call). Only the module value
is returned.

Searcher order mirrors Lua while using non-blocking source loading:

1. `package.searchers[1]` (the preload searcher).
2. Every template in `package.path` using asynchronous `fs` operations (dots
   become directory separators; `?` expands to the path), on both native and
   browser targets.
3. `package.searchers[3]` onward (Lua's C searchers, Titan's package searcher,
   and any custom searchers) up to the first `nil` slot.

Slot `package.searchers[2]` is reserved for step 2 and is not called directly.
Custom searchers in other slots receive `modname` and return either a loader
(plus optional loader data) or a diagnostic string; searchers and loaders run
across a non-yieldable Lua boundary and raise if they attempt to yield.

After each compiled Titan module finishes initialization, it registers its
native loader in the registry preload table (`package.preload`), so initialized
imports (including statically linked modules) resolve via step 1 without a
separate provider file. Unused linked modules are not published automatically.

Once a source candidate opens, read or syntax errors are terminal rather than
continuing to later searchers. Task cancellation during open or read takes
precedence with its original `async.CancellationReason`. Simultaneous or
recursive `require` calls for the same module raise
`module '<name>' is already being loaded` (distinct modules may load
concurrently), and the guard clears on both success and error.

## Independent Lua states

```text
record Lua

function new(): Lua
function Lua:close()
function Lua:detach(): foreign *lua_State

function Lua:run(chunk: string, name: string?,
                 ...: async.TransferValue): (...: async.TransferValue)
function Lua:run_from_loader(reader: io.Reader, name: string?,
                             ...: async.TransferValue): (...: async.TransferValue)
function Lua:run_async(chunk: string, name: string?,
                       ...: async.TransferValue): (...: async.TransferValue) -- native only
function Lua:run_async_from_loader(reader: io.Reader, name: string?,
                                   ...: async.TransferValue): (...: async.TransferValue) -- native only
```

`lua.new()` creates a fresh Lua state with its own globals, registry, loaded
module cache, and garbage collector, with the standard Lua libraries opened.
State persists across calls on the same `Lua` handle:

```titan
local lua = import "lua"
local transfer = import "transfer"

function run_isolated(text: string): string
  local state = lua.new()
  defer state:close()
  local result = state:run(
    "return string.upper(...)",
    "=isolated-upper",
    transfer.TransferValue.is_string(text))
  case result
  when is_string(upper) then return upper
  else raise "unexpected result from isolated Lua state"
  end
end
```

At creation, `new()` snapshots string-keyed, zero-upvalue native C loaders from
the creating state's registry preload table (including initialized Titan
modules and their native provider descriptors). Requiring a Titan module in the
child initializes a fresh independent instance there without needing a provider
file on disk; nested `lua.new()` calls inherit these loaders too. Custom native
loaders and their libraries must stay loaded while any child state uses them.

On native targets, the child state initializes its own `package.path`,
`package.cpath`, and [Titan path](modules.md#the-titan-path) from the
environment rather than copying host overrides. On the browser, file and
provider searches miss and only copied preload loaders resolve.

`run` compiles and executes `chunk` synchronously on the calling thread,
forwarding `...` arguments and returning all results (`name` defaults to
`chunk`; embedded NULs are supported). `run_from_loader` and
`run_async_from_loader` drain `reader` completely without closing it before
invoking `run` or `run_async` (state reservation starts only after reading
completes).

`close()` closes the state (idempotent after closure) and runs Lua `__gc`
finalizers; prefer `defer state:close()` for lexical lifetimes. An unclosed
unreachable `Lua` handle closes on finalization (in-flight `run_async` work
retains the handle until completion). `detach()` transfers ownership of an idle
open `foreign *lua_State` to the caller (who must eventually call `lua_close`)
and marks the wrapper closed; detaching a busy or closed handle raises.

### Transferring values

Values cross the independent-state boundary as
[`transfer.TransferValue`](standard-library-transfer.md) (`async.TransferValue`
is a transparent alias):

| Variant | Argument in child state | Returned from child state |
| --- | --- | --- |
| `is_nil` | `nil` | `nil` |
| `is_boolean` | `boolean` | `boolean` |
| `is_integer` | Lua integer | Lua integer |
| `is_float` | Lua float | Lua float (even if integral) |
| `is_string` | Copied byte string | Copied byte string |
| `is_lua_state` | Light userdata (borrowed `lua_State *`) | Lua thread (borrowed `lua_State *`) |
| `is_function` | Zero-upvalue C function | Light C function or zero-upvalue C closure |
| `is_pointer` | Light userdata (borrowed address) | Light userdata or full userdata payload pointer |
| `is_record(module, name, data)` | Fresh record decoded from protobuf | Public record serialized via protobuf |
| `is_union(module, name, data)` | Fresh union decoded from protobuf | Public union serialized via protobuf |
| `is_closure(module, entry, data)` | Reconstructed Titan closure | Titan closure (including adjusted/bound methods) |
| `is_record_payload(module, name, data)` | Reconstructed via static transfer hook | Public record with custom transfer hooks |

Key boundary rules:

- **Existing policies:** Returning an explicit `TransferValue` preserves its
  chosen variant (for example, keeping `is_record` bytes or `is_lua_state` kind
  verbatim).
- **Custom records and manual handoff:** Public records defining the
  [`to_transfer_payload` / `from_transfer_payload` pair](async-io.md#custom-record-transfer)
  cross via `is_record_payload`, preloading their declaring module on a registry
  miss. Resource-detaching hooks obey the
  [shared manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules):
  the caller ensures single adoption and handles recovery on failed delivery.
- **No packet attachments:** `Lua:run` and `Lua:run_async` open no transfer
  packet scope, so packet-attached endpoints (`thread.Sender`,
  `thread.Receiver`) cannot cross through them directly, nested in records, or
  in closure captures. Use [`titan.thread`](standard-library-thread.md) or
  [`async.Receiver`](async-io.md#cross-state-receivers) to transfer channel
  endpoints.
- **Closures:** Titan closures snapshot their captures via
  `TransferValue.from_value`, preload their owning module in the destination,
  and create fresh mutable capture cells
  ([transfer values](async-io.md#transfer-values)).
- **Records and unions:** All-public records without transfer hooks and
  all-public unions serialize via [`titan.protobuf`](standard-library-protobuf.md);
  cycles and unsupported fields raise.
- **Counts, pointers, and errors:** `nil` slots are preserved in arguments and
  results. Tables, Lua functions, C closures with upvalues, and `NULL`
  `is_function` pointers raise. Every returned value is validated even if the
  caller ignores trailing results. Strings and nominals are copied; pointer
  variants (`is_pointer`, `is_lua_state`, `is_function`) are borrowed addresses
  whose origin objects and states must stay alive and synchronized. Load and
  execution errors raise copied diagnostics in the caller and restore the child
  state's stack height without rolling back globals or side effects.

### Asynchronous execution

*(Native only.)* `Lua:run_async` and `Lua:run_async_from_loader` execute the
chunk on [`async.run_foreign`](async-io.md)'s shared libuv worker pool while
other Tasks in the hosting state continue running. The child state can require
Titan modules and run its own `async.loop()` completely isolated from the host
(on Windows, worker threads restore x87 precision before each job; see
[Windows build](windows-build.md)):

```titan
local lua = import "lua"
local async = import "async"

function uppercase(text: string): string
  local state = lua.new()
  defer state:close()
  local result = state:run_async([[
    local strings = require("titan.string")
    return strings.upper(...)
  ]], "=independent-uppercase", async.TransferValue.is_string(text))
  case result
  when is_string(upper) then return upper
  else raise "independent state returned an unexpected value"
  end
end
```

Only one call may occupy a `Lua` instance at a time; concurrent `run`,
`run_async`, `close`, or `detach` calls on a busy handle raise immediately
(separate `Lua` handles run concurrently).

Cancellation does not interrupt running Lua code: once accepted, the worker
finishes and posts completion before the waiting Task receives its pending
cancellation. If the hosting Lua state closes while `run_async` is in flight,
the waiting Task unwinds ([abandoned coroutines](coroutines.md#abandoned-coroutines)),
the `Lua` handle behaves as closed, and host teardown waits for the worker to
finish before closing the child state.

### Two-phase receiver bootstrap

*(Native only.)* Create an [`async.Receiver`](async-io.md#cross-state-receivers)
in a first `run_async` call, keep it rooted in the child state, return its
borrowed handle, publish messages with `async.send`, and run the child's event
loop in a second call:

```titan
local lua = import "lua"
local async = import "async"

function main(_args: {string}): integer
  local state = lua.new()
  defer state:close()
  defer state:run([[
    if control_receiver then control_receiver:close() end
    require("titan.async").loop()
    control_receiver = nil
  ]], "=receiver-cleanup")

  local exported = state:run_async([[
    control_receiver = require("titan.async").receiver()
    return control_receiver:handle()
  ]], "=receiver-bootstrap")
  defer exported = async.TransferValue.is_nil()
  case exported
  when is_pointer(handle) then
    -- Finish sending before the remote loop can begin teardown.
    async.send(handle, async.TransferValue.is_string("stop\0"))
    state:run_async([[
      local async = require("titan.async")
      local task = async.run(function()
        control_receiver:wait()
        control_receiver:close()
      end)
      async.loop()
      if not task:status():has_succeeded() then
        error("receiver Task failed")
      end
    ]], "=receiver-worker")
  else raise "receiver bootstrap returned no native handle"
  end
  return 0
end
```

For long-lived services that send while `run_async` is running, ensure every
`async.send` call has returned before closing the remote Receiver or shutting
down its Runtime (receipt of a stop message does not prove the sender has
returned), then wait for `run_async` to finish before releasing the Receiver
root or closing the state.

Long-lived `run_async` calls occupy worker threads from libuv's process-wide
pool shared with `fs`, `net` DNS, and `sqlite3`. Reserve worker capacity or
configure `UV_THREADPOOL_SIZE` before first pool use (see
[libuv threadpool](https://docs.libuv.org/en/v1.x/threadpool.html)).

## On the browser

| Members | Native | Browser |
| --- | --- | --- |
| `load`, `load_from_reader`, `dofile`, `require`, `new` | Available | Available |
| `Lua:run`, `Lua:run_from_loader`, `Lua:close`, `Lua:detach` | Available | Available |
| `Lua:run_async`, `Lua:run_async_from_loader` | Available | Absent |

On `--target browser`, importing `titan.lua` automatically links the
[browser filesystem runtime](browser-target.md#filesystem-and-durable-storage),
so `dofile` and `require`'s `package.path` search read from the instance's VFS.
`lua.new()` creates another Lua state inside the same WebAssembly instance and
executes calls synchronously on the owner thread. Browser async Tasks belong
exclusively to the instance's owner state; child states cannot run or drive
browser Tasks.

### Stock Lua libraries on the browser

Both the launcher state and every `lua.new()` state open Lua's standard
libraries with the following browser profile (for Lua chunks calling stock Lua
APIs, distinct from `titan.io` and `titan.os`):

| Stock Lua API | Browser behavior |
| --- | --- |
| `io.open`, `io.lines(file)`, `io.input(file)`, `io.output(file)`, `io.tmpfile`, `os.remove`, `os.rename`, `os.tmpname`, `dofile`, `loadfile` | Operate on the browser VFS when linked (`io.tmpfile` creates an unlinked file in `/tmp`; `os.tmpname` creates a unique path in `/tmp`); without a linked filesystem runtime (or `/tmp`), path calls fail with `ENOENT` (`"No such file or directory"`), `io.tmpfile()` returns `nil, "No such file or directory", 44`, and `os.tmpname()` raises `"unable to generate a unique filename"` |
| `io.popen`, `os.execute(cmd)` | Fail without starting a process (`os.execute()` reports no shell) |
| `io.read`, `io.stdin:read` | Fail with a read error (use `titan.os.stdin` for embedding input) |
| `package.loadlib` | Returns `nil, message, "absent"` |
| `package.path`, `package.cpath` searches | `package.path` searches the browser VFS when linked (misses without VFS); `package.cpath` misses (only copied preload entries resolve) |
| `os.getenv` | Reads the instance environment (initially empty) |
| `print`, `io.write`, `io.stdout`, `io.stderr` | Send bytes to the instance's output queues |
| `os.clock()` | Raises `os.clock is unavailable on the browser target (no process CPU-time clock)` |
| `os.exit(code)` | Delegates to linked `titan.os` exit request in an owner-state Task; otherwise raises |

Stock `os.exit` never calls C `exit()`. When `titan.os` is linked and called
from an owner-state async Task, it maps `true` to `0` and `false` to `1` and
issues Titan's [exit request](standard-library-os.md#on-the-browser); outside a
Task, without linked `titan.os`, or in any `lua.new()` child state, it raises
`os.exit is unavailable outside an async Task on the browser target`.

Stock output uses C stdio buffering (`print` flushes at newline; `io.flush`
flushes pending `io.write` bytes), preserving binary bytes and ordering with
Titan writes.
