# Concurrency: Tasks, Channels, and Threads

Titan separates concurrency into two distinct tiers so programs can scale I/O without locks and scale CPU work across cores without data races:

- **Cooperative `async` Tasks** run inside a single Lua/Titan state on one event loop (libuv natively, or the host event loop on the browser target). Tasks share state safely without mutexes because control switches only at explicit suspension points—I/O, timers, channels, yields, and combinators.
- **Shared-nothing OS `thread` workers** each own a dedicated OS thread, an isolated Lua/Titan state and garbage collector, and their own `async` event loop. Threads never share mutable GC objects; values cross boundaries by copying or transferring endpoints.

For synchronous control transfer without an event loop—such as generators or custom schedulers—Titan also provides low-level stackful **coroutines** (`import "coroutine"`).

| Need | Tool | Behavior |
| --- | --- | --- |
| Concurrent I/O, timers, or shared in-state logic | `async.run` + `timer` | Cooperative Tasks on one event loop; zero-copy shared state |
| Typed queue between Tasks in the same state | `async.channel<|T|>` | Bounded FIFO, zero serialization, single blocked sender/receiver |
| Multi-core CPU work or blocking isolation | `thread.spawn*` / `thread.group` | Dedicated OS threads with isolated Lua states and event loops |
| Lossless message stream across OS threads | `thread.channel<|T|>` | Bounded MPMC FIFO with backpressure, cloning, and drain-on-close |
| Latest-value wakeup across Lua states or threads | `async.Receiver` | Lossy, coalescing single-slot mailbox; newer sends overwrite older |
| Synchronous generator or custom scheduler | `coroutine.create` | Stackful asymmetric coroutines with tagged nested yields |

## Cooperative Tasks and the event loop

Every `async.Task` runs synchronously until it returns, raises, or suspends on an asynchronous operation (`timer.sleep`, `fs`, `net`, `ssl`, `http`, `websocket`, `os`, `sqlite3`, channels, or Task combinators). Another Task cannot preempt it between suspension points, so reading and updating shared in-state variables requires no locks. Conversely, a CPU-heavy loop that never suspends starves every other Task on the same loop; call `async.yield()` periodically inside long computations, or move CPU work to an OS thread.

When a standalone executable transitively imports any async-backed standard module (`async`, `timer`, `fs`, `net`, `http`, `os`, `thread`, and so on), the generated entrypoint automatically runs `main` inside a root Task and drives the event loop until all Tasks finish. In a Lua host—or an executable compiled with `--no-uv-bootstrap`—call `async.loop()` explicitly after scheduling initial Tasks.

```titan
local async = import "async"
local io = import "io"
local timer = import "timer"

local function fetch_step(label: string, delay_ms: integer): string
  timer.sleep(delay_ms)
  return label .. " (" .. delay_ms .. "ms)"
end

function main(args: {string}): integer
  local first = async.run(function (): string
    return fetch_step("profile", 30)
  end)
  local second = async.run(function (): string
    return fetch_step("permissions", 20)
  end)

  local profile, perms = async.all_two(first, second)
  io.print(profile .. ", " .. perms)
  return 0
end
```

`async.run` schedules the Task and returns a `Task<|A, B|>` handle immediately without running the function inline. `A` is inferred from the function's return type, and `B` defaults to `value` for the payload of a complex `CancellationReason`. When specifying a custom cancellation payload type `B` explicitly, supply both type arguments (`async.run<|A, B|>`).

For periodic work, `timer.ticker(milliseconds)` creates a recurring timer whose `tick()` method suspends until the next interval and returns `true` (or `false` after `close()`). Missed intervals coalesce into a single pending tick rather than accumulating a backlog:

```titan
local io = import "io"
local timer = import "timer"

function main(args: {string}): integer
  local ticker = timer.ticker(15)
  defer ticker:close()

  for step = 1, 3 do
    if not ticker:tick() then break end
    io.print("tick " .. step)
  end
  return 0
end
```

## Coordinating Tasks and cancellation

Every Task moves through nonterminal states (`ready`, `running`, `waiting`) to one terminal `TaskStatus<|A, B|>` variant: `succeeded(value)`, `failed(Error)`, or `cancelled(CancellationReason<|B|>)`.

Four families of fixed-arity combinators wait on heterogeneous Tasks without forcing them into a single type:

| Combinator | Waits until | Return / error behavior |
| --- | --- | --- |
| `join`, `join_two`..`join_five` | All inputs finish | Returns each `TaskStatus`; never raises a child's error |
| `all_two`..`all_five` | All succeed, or first fails/cancels | Returns `(A1, ...)` on all-success; raises `AllTwoError`..`AllFiveError` on first failure/cancel |
| `race_two`..`race_five` | First input finishes (any outcome) | Returns `RaceTwoResult`..`RaceFiveResult` carrying the winner's `TaskStatus` |
| `any_two`..`any_five` | First input succeeds, or all fail/cancel | Returns `AnyTwoResult`..`AnyFiveResult` with the winning value or `none()` |

Combinators **never cancel losing Tasks automatically**. Cancellation is explicit and cooperative:

- `task:cancel(reason?)` records the Task's first `CancellationReason` (`CancellationReason.simple(msg)` or `.complex(payload)`; omitting it uses `simple("cancelled")`).
- Cancellation is sticky and delivered at suspension points (`timer.sleep`, I/O, channels, combinators) or explicit `async.checkpoint()` calls.
- When cancellation triggers, the Task unwinds like a raised error—running every active `defer` statement in LIFO order—before publishing terminal status `cancelled(reason)`.
- Wait for a cancelled Task that owns shared resources with `async.join(task)` before releasing those resources. (Inside a `defer` cleanup path that may itself be running under cancellation, use a terminal listener with `async.await_cleanup` instead of ordinary cancellation-sensitive `async.join`.)

```titan
local async = import "async"
local io = import "io"
local timer = import "timer"

function main(args: {string}): integer
  local cleaned = false

  local work = async.run(function (): string
    defer cleaned = true
    timer.sleep(200)
    return "completed"
  end)

  local deadline = async.run(function (): nil
    timer.sleep(25)
    return nil
  end)

  local winner = async.any_two(work, deadline)
  case winner
  when first(result) then
    deadline:cancel(async.CancellationReason.simple("work finished"))
    io.print("result: " .. result)
  when second() then
    work:cancel(async.CancellationReason.simple("timed out"))
    local status = async.join(work)
    io.print("work " .. status:as_string() .. ", cleaned=" .. (cleaned and "yes" or "no"))
  when none() then
    io.print("both tasks failed")
  end
  return 0
end
```

## Communicating between Tasks in one state

Within one Lua state, `async.channel<|T|>(capacity?)` creates a bounded FIFO channel (default capacity `1`) and returns three closures: `(send, receive, close)`. Values pass by reference with zero serialization overhead:

- `send(item)` suspends only when the buffer is full; `receive()` suspends only when the buffer is empty.
- At most one Task may be blocked in `send` and at most one in `receive` at a time.
- Calling `close()` marks the channel closed immediately, discards any unread buffered items, and wakes blocked waiters with `"channel is closed"`. Use an explicit sentinel (such as `nil` on an optional type `T?`) when a producer wants a consumer to drain every item cleanly before closing.

```titan
local async = import "async"
local io = import "io"

function main(args: {string}): integer
  local send, receive, close = async.channel<|integer?|>(2)
  defer close()

  local producer = async.run(function (): nil
    for n = 1, 5 do
      send(n * n)
    end
    send(nil)
    return nil
  end)

  local sum = 0
  while true do
    local item? = receive()
    if item == nil then break end
    sum = sum + item
  end

  async.join(producer)
  io.print("sum of squares = " .. sum)
  return 0
end
```

For streaming byte data between two Tasks using the standard `io` interfaces, `async.reader_writer_channel(capacity?)` returns a `(ChannelReader, ChannelWriter)` pair implementing `io.ReaderCloser` and `io.WriterCloser` with `read_until`:

```titan
local async = import "async"
local io = import "io"

function main(args: {string}): integer
  local reader, writer = async.reader_writer_channel(2)
  defer reader:close()
  defer writer:close()

  local sender = async.run(function (): nil
    writer:write("alpha\nbet")
    writer:write("a\n")
    return nil
  end)

  local first? = reader:read_until("\n", true)
  local second? = reader:read_until("\n", true)
  async.join(sender)
  io.print((first or "") .. " | " .. (second or ""))
  return 0
end
```

## Parallelism with OS threads

`import "thread"` (native targets only) launches real OS worker threads. Each thread runs its own Lua/Titan state, garbage collector, and `async` event loop, so workers can run CPU-bound loops in parallel across cores and also perform their own async I/O (`timer`, `fs`, `net`, `http`, `sqlite3`, or nested threads).

### Spawning threads and bounded channels

`thread.channel<|T|>(capacity?)` creates a thread-safe, bounded MPMC FIFO channel (default capacity `1`) and returns a `(Sender<|T|>, Receiver<|T|>)` pair:

- Both endpoints can be cloned (`:clone()`) and sent to worker threads as spawn arguments, closure captures, or nested fields of records and unions.
- Unlike `async.channel`, **`Sender:close()` preserves buffered messages** so receivers drain every queued item cleanly. Once closed and drained, `Receiver:receive_result()` returns `ReceiveResult.closed()`, `Receiver:receive()` raises `"channel is closed"`, and `for _, item in rx:incoming() do` terminates normally.
- **`Receiver:close()`** closes the channel from the consumer side, discards unread buffered messages immediately, and wakes blocked senders with `"channel is closed"`.
- A channel also closes automatically once all `Sender` clones (or all `Receiver` clones) across all threads have been garbage-collected.

`thread.spawn` through `thread.spawn_five` start standalone worker threads, returning a `Thread<|R|>` handle:

- `th:status()` returns a nonblocking snapshot (`running()`, `succeeded(val)`, `failed(err)`, or `cancelled(reason)`).
- `th:join()` suspends the calling Task until the worker finishes **and** its OS thread is joined, returning the terminal `ThreadStatus<|R|>`. Always join standalone threads (or wait on a `thread.Group`) before releasing shared native state or exiting.
- `th:cancel(reason?)` cooperatively cancels the worker's root Task so its `defer` blocks run normally.

### Structured worker pools with `thread.Group`

`thread.group(limit?, propagate_errors?)` manages a pool of worker threads with an optional concurrency cap and optional fail-fast error propagation (modeled on Go's `errgroup.Group`):

- When `limit` workers are already active, `Group:spawn*` suspends the calling Task until a worker finishes and releases its slot.
- With `propagate_errors = true`, the first uncaught worker error cancels all running sibling workers and turns later `spawn*` calls into no-ops.
- `Group:wait()` suspends until every worker finishes and returns an Array `{thread.Error}` of uncaught errors in completion order.

The following complete program fans work across two OS worker threads, sending each job along with a reply `thread.Sender<|integer|>` embedded inside a public record:

```titan
local io = import "io"
local thread = import "thread"

record WorkRequest
  const n: integer
  const reply: thread.Sender<|integer|>
end

function main(args: {string}): integer
  local jobs_tx, jobs_rx = thread.channel<|WorkRequest|>(4)
  local results_tx, results_rx = thread.channel<|integer|>(5)

  local pool = thread.group(2, true)
  for _ = 1, 2 do
    pool:spawn_one(function (rx: thread.Receiver<|WorkRequest|>)
      for _, job in rx:incoming() do
        job.reply:send(job.n * job.n)
      end
    end, jobs_rx)
  end

  for i = 1, 5 do
    jobs_tx:send(WorkRequest(i, results_tx))
  end
  jobs_tx:close()

  local errs = pool:wait()
  if #errs > 0 then
    errs[1]:raise()
  end

  results_tx:close()
  local total = 0
  for _, square in results_rx:incoming() do
    total = total + square
  end
  io.print("total = " .. total)
  return 0
end
```

Because `main` waits for `pool:wait()` before reading from `results_rx`, `results_tx` is sized to hold all five replies without blocking the workers; for unbounded streams, drain `results_rx` in a concurrent Task while workers run.

## Crossing state boundaries: transfer rules and bridges

### Composing OS threads with `async` combinators

`Thread:task()` returns a memoized `async.Task<|R, value|>` proxy in the caller's state. It resolves with `R`, re-raises the worker's `Error` on failure, and forwards proxy cancellation to `Thread:cancel`—publishing its terminal status only after the worker's OS thread has actually joined. This lets OS threads participate directly in `async.all_*`, `async.any_*`, and `async.race_*`:

```titan
local async = import "async"
local io = import "io"
local thread = import "thread"
local timer = import "timer"

function main(args: {string}): integer
  local worker = thread.spawn_one(function (limit: integer): integer
    local sum = 0
    for i = 1, limit do
      sum = sum + i
    end
    return sum
  end, 1000)

  local deadline = async.run(function (): nil
    timer.sleep(500)
    return nil
  end)

  local result = async.any_two(worker:task(), deadline)
  case result
  when first(sum) then
    deadline:cancel()
    io.print("sum = " .. sum)
  when second() then
    worker:cancel()
    worker:join()
    io.print("worker timed out")
  when none() then
    io.print("worker failed")
  end
  return 0
end
```

### Coalescing cross-state notifications (`async.Receiver`)

When another OS thread or independent `lua.Lua` state only needs to wake an event loop with the *latest* state (such as a progress percentage or a stop signal) rather than a lossless stream, use `async.Receiver`:

- Create the receiver in the receiving state with `local rx = async.receiver()`, keep `rx` rooted there, and pass only the opaque address `rx:handle()` (`foreign *void`) to senders.
- Any state or thread calls `async.send(handle, payload)`, which encodes the value into a native packet, atomically replaces any unread value in the slot, and wakes the receiver's loop.
- The receiver awaits the latest decoded value with `rx:wait()`. Because `Receiver` is lossy and coalescing, stop all senders before calling `rx:close()`.

### What values can cross states

Values passed across `thread.spawn*`, `thread.channel`, `Thread` returns, `async.Receiver`, and `lua.Lua:run*` follow the shared [`TransferValue`](standard-library-transfer.md) policy:

| Value kind | Cross-state behavior |
| --- | --- |
| `nil`, `boolean`, `integer`, `float`, `string` | Copied with exact kind and bytes (including embedded NULs) |
| Public `record` / `union` (all-public fields) | Serialized and reconstructed cleanly across states (may contain Arrays of transferable elements) |
| Titan closures | Entry plus snapshotted captures; mutable captures become independent fresh cells in the destination; module variables bind to the destination's module instance |
| `thread.Sender<|T|>`, `thread.Receiver<|T|>` | Reference-counted packet attachments; automatically released if an unread packet is discarded |
| Manual-handoff resources (`net.Connection`, `ssl.Connection`, `http.Exchange`, `websocket.Connection`, `fs.File`, `os` streams, `sqlite3.Connection`) | Transferred via `to_transfer_payload` / `from_transfer_payload`; sender detaches ownership and caller must adopt once or explicitly discard |
| Top-level Arrays `{T}`, Maps `{K: V}`, Interfaces, Lua closures | Rejected directly; wrap an Array in a public `record` or `union` before sending |

Do **not** hold blocking OS locks (`uv.mutex_t`) across an `async` suspension point or wait for a sibling Task on the same event loop to unlock them: `uv.mutex_t` blocks the entire OS thread. Use `thread.channel` for cross-thread coordination instead.

## Low-level stackful coroutines

`import "coroutine"` provides stackful asymmetric coroutines with **tagged yields**, available on both native and browser targets. Unlike `async.Task`, a `Coroutine` has no event loop or scheduler: control moves only when code explicitly calls `co:resume(arg, tag?)` and `coroutine.yield(value, tag)`.

Tags allow nested coroutines to yield directly past intermediate frames to a specific enclosing handler. When an abandoned suspended coroutine becomes unreachable (or its Lua state closes), Titan automatically unwinds its stack so `defer` statements and generic-`for` close functions still run.

```titan
local coroutine = import "coroutine"
local io = import "io"

local function range_body(limit: value): value
  local n: integer = limit
  for i = 1, n do
    coroutine.yield(i, "next")
  end
  return nil
end

function main(args: {string}): integer
  local gen = coroutine.create(range_body, "next")
  local total = 0
  while gen:status() == "suspended" do
    local item = gen:resume(5)
    if item ~= nil then
      local n: integer = item
      total = total + n
    end
  end
  io.print("generated sum = " .. total)
  return 0
end
```

## Reference chapters

For full API signatures and edge-case contracts, see Part III:

- [Asynchronous I/O and tasks](async-io.md) (`async.Task`, combinators, `async.channel`, `async.Receiver`, `await_with`, `run_foreign`, and browser driver rules)
- [Timer standard library](standard-library-timer.md) (`timer.sleep`, `timer.yield`, `timer.Ticker`)
- [Thread standard library](standard-library-thread.md) (`thread.channel`, `thread.spawn*`, `thread.Group`, retirement and failure boundaries)
- [Transfer policies](standard-library-transfer.md) (`TransferValue`, manual resource handoff inventory, packet scopes)
- [Coroutines](coroutines.md) (`coroutine.create`, tagged nested yields, `transfer`, abandoned unwinding)
