# Thread standard library

The `thread` module provides shared-nothing OS worker threads (`Thread<|R|>`), bounded multi-producer multi-consumer channels (`Sender<|T|>` / `Receiver<|T|>`), and structured worker pools (`Group`). Import it in Titan with `local thread = import "thread"` or load it in Lua with `require "titan.thread"`.

**Target availability:** Native only (unavailable on the browser target).

For a walkthrough of Tasks, channels, threads, and coroutines together, see [Concurrency: Tasks, Channels, and Threads](concurrency.md). For single-state cooperative Tasks, see [Asynchronous I/O and tasks](async-io.md); for manual independent-state control, see [Lua states and loading](standard-library-lua.md).

## Example

This program fans six jobs across a bounded two-worker `thread.Group`, embedding a reply `Sender<|integer|>` inside each `Job` record:

```titan
local io = import "io"
local thread = import "thread"

record Job
  const input: integer
  const reply: thread.Sender<|integer|>
end

function main(args: {string}): integer
  local jobs_tx, jobs_rx = thread.channel<|Job|>(4)
  local results_tx, results_rx = thread.channel<|integer|>(6)

  local pool = thread.group(2, true)
  for _ = 1, 2 do
    pool:spawn_one(function (rx: thread.Receiver<|Job|>)
      for _, job in rx:incoming() do
        job.reply:send(job.input * 10)
      end
    end, jobs_rx)
  end

  for i = 1, 6 do
    jobs_tx:send(Job(i, results_tx))
  end
  jobs_tx:close()

  local errs = pool:wait()
  if #errs > 0 then errs[1]:raise() end

  results_tx:close()
  local total = 0
  for _, scaled in results_rx:incoming() do
    total = total + scaled
  end
  io.print("total = " .. total)
  return 0
end
```

## Core concepts

Each spawned `Thread` runs a dedicated OS thread with its own isolated Lua/Titan state, garbage collector, and `async` event loop. Threads never share mutable GC objects: arguments, closure captures, channel messages, and return values are serialized into native message packets using the [`TransferValue`](standard-library-transfer.md) policy and reconstructed in the destination state.

Blocking channel operations (`send`, `receive`, `receive_result`, `incoming`), `Thread:join()`, `Group:spawn*` admission waits, and `Group:wait()` suspend only the calling `async.Task` via the Runtime's shared external wake bridge so other Tasks on the same loop keep running.

## Cross-thread channels

```text
union ReceiveResult<|T|>
  message(value: T)
  closed()
end

record Sender<|T|>
record Receiver<|T|>

function channel<|T|>(capacity: integer?): (Sender<|T|>, Receiver<|T|>)

function Sender:send(message: T)
function Sender:try_send(message: T): boolean
function Sender:close()
function Sender:is_closed(): boolean
function Sender:clone(): Sender<|T|>
function Sender:to_transfer_payload(): string
function Sender.from_transfer_payload(payload: string): Sender<|T|>

function Receiver:receive(): T
function Receiver:receive_result(): ReceiveResult<|T|>
function Receiver:try_receive(): (boolean, T?)
function Receiver:incoming():
    (function (Receiver<|T|>, boolean?): (boolean?, T?), Receiver<|T|>, nil)
function Receiver:close()
function Receiver:is_closed(): boolean
function Receiver:clone(): Receiver<|T|>
function Receiver:to_transfer_payload(): string
function Receiver.from_transfer_payload(payload: string): Receiver<|T|>

foreign function channel_retain_sender_native(raw: *void): void
foreign function channel_retain_receiver_native(raw: *void): void
foreign function channel_release_sender_native(raw: *void): void
foreign function channel_release_receiver_native(raw: *void): void
```

`thread.channel<|T|>(capacity?)` allocates a thread-safe, bounded FIFO channel and returns its initial `(Sender<|T|>, Receiver<|T|>)` pair.

- `capacity` defaults to `1` when omitted or `nil`; `capacity <= 0` raises `"channel capacity must be positive"`.
- Any value accepted by [transfer values](async-io.md#transfer-values) may cross a channel, including primitives, strings, public records and unions, Titan closures with transferable captures, custom-hook records, and `Sender<|T|>` / `Receiver<|T|>` endpoints (at top level or nested in records, unions, and their Array fields). Top-level Arrays and Maps are not directly transferable; wrap an Array in a public `record` or `union`.

### Sending and receiving

- **`Sender:send(message)`** serializes `message` first (raising before touching the channel if it is not transferable). If the channel is closed, it raises `"channel is closed"`. If space is available, it enqueues immediately and wakes one waiting receiver; otherwise it suspends the calling `async.Task` in a FIFO send-waiter queue until space opens or the channel closes. Waking does not pre-reserve a slot: the resumed Task retries admission and may contend with other senders.
- **`Sender:try_send(message)`** serializes `message` first, raises `"channel is closed"` if closed, enqueues and returns `true` if space is immediately available, or discards the packet and returns `false` without suspending if full.
- **`Receiver:receive()`** dequeues the oldest message immediately if buffered (waking one blocked sender if present), or suspends the calling `async.Task` until a message arrives or the channel closes and drains. Once closed and drained, it raises `"channel is closed"`.
- **`Receiver:receive_result()`** behaves like `receive()`, returning `ReceiveResult.message(msg)` on delivery and `ReceiveResult.closed()` once closed and drained instead of raising.
- **`Receiver:try_receive()`** never suspends, returning `(true, msg)` if a buffered item is ready or `(false, nil)` if the buffer is empty (open or closed).
- **`Receiver:incoming()`** returns a generic-`for` iterator triple yielding `(true, message)` in FIFO order and `(nil, nil)` once closed and drained. Because the first result controls iteration separately from the message, `nil` and `false` remain valid payloads. Discard the control flag with `_`, and append `?` to preserve optional `nil` messages (or omit `?` to force non-nil):

```text
for _, msg? in rx:incoming() do
  handle(msg)
end
```

A Task blocked in `send`, `receive`, `receive_result`, or `incoming` suspends through the Runtime's [external wake bridge](async-io.md#external-waits). Cancelling the Task withdraws its waiter before `Task:cancel` returns.

If the Lua state closes while a Task is blocked on a channel, the state withdraws that waiter before releasing the Task's stack, keeping the channel intact for clones held by other threads. The blocked Task unwinds its `defer` blocks inside a finalizer where awaits cannot run; drain Tasks before closing the state when cleanup must await ([closing a Lua state with an active Runtime](async-io.md#closing-a-lua-state-with-an-active-runtime)).

### Closing, cloning, and transferring endpoints

- **`Sender:close()`** marks the shared channel closed (`is_closed() == true`) for all clones while **preserving buffered messages** so receivers can drain them. Blocked senders wake with `"channel is closed"`, and blocked receivers wake once the buffer empties.
- **`Receiver:close()`** marks the shared channel closed for all clones, **discards all unread buffered messages immediately**, and wakes all blocked senders and receivers.
- **`Sender:clone()` / `Receiver:clone()`** create a new local endpoint handle sharing the channel and increment its active sender or receiver count.
- **Garbage collection:** Collecting one clone releases only that handle's reference. When the last active `Sender` across all threads is collected, the channel closes from the sender side (preserving buffered messages). When the last active `Receiver` is collected, the channel closes from the receiver side and discards unread messages via [`transfer.discard_message`](standard-library-transfer.md#native-message-packets) in C without entering Lua or requiring a Runtime.
- **Native reference cycles:** Unread packet attachments count as live native endpoints outside Lua GC (for instance, sending a channel's own `Receiver` into itself keeps its receiver count nonzero). Retain a reachable receiver and call `Receiver:close()` to flush unread packets and break cycles before dropping the final handle.
- **Packet-scoped endpoint transfer:** Every endpoint reference is owned by either a live wrapper or an undelivered packet. Passing an endpoint at packet root, inside a public record/union/Array field, or captured in a closure retains a fresh reference per occurrence and encodes a four-byte little-endian packet-local slot index (leaving the sender's handle valid). Custom hooks for records holding private endpoints can call `Sender:to_transfer_payload()` / `from_transfer_payload(payload)` and `Receiver:to_transfer_payload()` / `from_transfer_payload(payload)` (which use `channel_retain_{sender,receiver}_native` and `channel_release_{sender,receiver}_native` with `transfer.attach_resource` / `claim_resource`).
  - Endpoint conversion requires an active top-level encode or decode scope opened by `transfer.encode_message` or `transfer.decode_message` (`Sender:send`, `try_send`, `thread.spawn*`, `Group:spawn*`, `Thread:cancel`, thread outcomes, and [`async.Receiver`](async-io.md#cross-state-receivers)). Standalone `TransferValue.from_value`, `TransferValue:to_value`, `protobuf.serialize`, and `lua.Lua:run*` open no packet scope and reject endpoints outside one.
  - Claiming checks width, bounds, endpoint kind (`Sender` vs `Receiver`), and unclaimed state; decoding allocates the destination wrapper and registers its finalizer before claiming the slot.
  - A channel created in a worker and returned via `Thread:join()` or `Thread:task()` survives the worker's state close while the undelivered result packet holds its reference.
  - **Manual-handoff resources are not auto-disposed on channel discard:** `transfer.discard_message` releases only packet-table attachments (`Sender` and `Receiver`) and never invokes `from_transfer_payload`. Recover or explicitly dispose rejected or unread manual-handoff resources (`http.Exchange`, `ssl.Connection`, `net.Connection`, `websocket.Connection`, etc.) under the [manual-handoff rules](standard-library-transfer.md#manual-handoff-api-inventory).

## Standalone OS threads

```text
record Error
  const error: value
  const traceback: string
end
function Error.new(error: value, traceback: string): Error
function Error:raise()

union ThreadStatus<|R|>
  running()
  succeeded(value: R)
  failed(value: Error)
  cancelled(value: async.CancellationReason<|value|>)
end

function ThreadStatus:as_string(): string
function ThreadStatus:has_finished(): boolean
function ThreadStatus:has_succeeded(): (boolean, R?)
function ThreadStatus:has_failed(): (boolean, Error?)
function ThreadStatus:has_cancelled():
    (boolean, async.CancellationReason<|value|>?)

record Thread<|R|>

function spawn<|R|>(entry: function (): (R)): Thread<|R|>
function spawn_one<|A, R|>(entry: function (A): (R), first: A): Thread<|R|>
function spawn_two<|A, B, R|>(
    entry: function (A, B): (R), first: A, second: B): Thread<|R|>
function spawn_three<|A, B, C, R|>(
    entry: function (A, B, C): (R), first: A, second: B, third: C): Thread<|R|>
function spawn_four<|A, B, C, D, R|>(
    entry: function (A, B, C, D): (R),
    first: A, second: B, third: C, fourth: D): Thread<|R|>
function spawn_five<|A, B, C, D, E, R|>(
    entry: function (A, B, C, D, E): (R),
    first: A, second: B, third: C, fourth: D, fifth: E): Thread<|R|>

function Thread:status(): ThreadStatus<|R|>
function Thread:join(): ThreadStatus<|R|>
function Thread:cancel(reason: async.CancellationReason<|value|>?)
function Thread:task(): async.Task<|R, value|>
```

`spawn` through `spawn_five` snapshot `entry` and all arguments synchronously on the caller thread, then start a dedicated OS worker thread. Any non-transferable capture or argument raises immediately before the OS thread is created.

Inside the worker thread (which preserves the main thread's `long double` precision on every platform, including restoring x87 precision on Windows — see [long double on worker threads](windows-build.md#long-double-on-worker-threads)):

1. `titan.thread` is loaded into the child state.
2. An `async` Runtime starts with the reconstructed `entry` as its root `Task` and runs `async.loop()` to completion.
3. The worker can use `timer`, `fs`, `net`, `ssl`, `http`, `websocket`, `sqlite3`, `thread.channel`, and nested `thread.spawn*` / `thread.group` on its own loop.
4. When the root `Task` returns `val`, `val` is serialized as `ThreadStatus.succeeded(val)`. Any sibling Tasks or active handles started inside the worker continue running until `async.loop()` finishes.
5. If the root `Task` raises an uncaught error or returns a non-transferable value, the worker records `ThreadStatus.failed(Error(err, traceback))` (degrading a non-transferable error object to its string rendering while keeping `traceback`) and calls `async.request_exit(0)` to drain the child loop cleanly.
6. If cancellation is accepted before the root `Task` enters its body, the worker records `ThreadStatus.cancelled(reason)` with the accepted reason rather than a generic failure.

### Observing, joining, and cancelling a Thread

- **`Thread:status()`** returns a nonblocking snapshot (`running()`, `succeeded(val)`, `failed(err)`, or `cancelled(reason)`). It never waits or joins; a terminal snapshot may appear before the OS thread has finished exiting, so `status()` is not evidence that the OS thread has retired.
- **`Thread:join()`** requires a running Task. It checks pending cancellation and Runtime shutdown, suspends until the worker finishes, performs the real OS thread join, and returns the terminal `ThreadStatus<|R|>` without raising on `failed` or `cancelled`. Later `join()` calls return the cached outcome without joining again. If the OS join fails, `join()` raises `async.OperationError` with operation `"thread.join"` and leaves the thread joinable for retry. If the Lua state closes while a Task waits in `join()`, the wait is withdrawn without cancelling the worker thread.
- **`Thread:cancel(reason?)`** cooperatively cancels the worker's root `Task` and wakes its event loop so its `defer` and cleanup blocks run (child Tasks started inside the worker must be cancelled explicitly by the root Task). The first host request wins; omitting `reason` or passing `nil` sends `CancellationReason.simple("cancelled")`. Reasons transfer as native packets; a non-transferable host or child reason degrades to `CancellationReason.simple("cancelled")`. A child root's own first sticky cancellation reason takes precedence over a later host request.
- **`Thread:task()`** creates a memoized `async.Task<|R, value|>` proxy on first use, marking the `Thread` observed. It resolves with `R` on success, re-raises via `err:raise()` on failure, and reflects cancellation, allowing threads to compose directly with `async.all_*`, `async.any_*`, `async.race_*`, and `async.join*`:
  - **Terminal timing:** The proxy publishes terminal status and invokes terminal listeners only after the child finishes cleanup **and** its OS thread is joined (even if cancelled while `ready` or unwinding). Release shared native state only after `join()` returns or the proxy becomes terminal.
  - **Proxy cancellation:** Cancelling the proxy forwards its first cancellation reason (or `simple("cancelled")` if the proxy body failed without cancellation) to `Thread:cancel` and waits for the OS join. A first explicit `cancel` on an unfinished proxy—even after the child's body returned while waiting for the OS join—takes normal Task cancellation precedence over pending success or failure.
  - **OS join failure:** If the OS join fails during proxy retirement, `async.loop()` raises `async.OperationError` with operation `"async.native_retirement.retire"`, keeping the proxy nonterminal and ownership intact; calling `async.loop()` again retries the join. If proxy creation itself fails (including a failed immediate join of an already-finished child), no Task is exposed and `Thread` keeps ownership of the worker and unjoined handle.
  - **State close:** Closing the owning Lua state unwinds unfinished proxies and forwards their cancellation reason (or `simple("async Runtime abandoned at Lua state close")`) to `Thread:cancel`, cancelling running proxy workers and `Group` members without blocking for their OS joins.
- **Finalized or unobserved handles:** Calling `join()` or `cancel()` on a finalized `Thread` handle raises `"thread handle was finalized"` (`status()` returns a cached status if available or raises the same error). If a standalone `Thread` fails with an uncaught error and is never observed (`status()` after completion, `join()`, `task()`, or `Group`), its formatted error and traceback are written to `stderr` when collected. Dropping an unjoined handle detaches its OS thread as best-effort reclamation, not as retirement evidence.

## Thread groups

```text
record Group

function group(limit: integer?, propagate_errors: boolean?): Group
function Group:spawn(entry: function (): ())
function Group:spawn_one<|A|>(entry: function (A): (), first: A)
function Group:spawn_two<|A, B|>(
    entry: function (A, B): (), first: A, second: B)
function Group:spawn_three<|A, B, C|>(
    entry: function (A, B, C): (), first: A, second: B, third: C)
function Group:cancel(reason: async.CancellationReason<|value|>?)
function Group:wait(): {Error}
```

`thread.group(limit?, propagate_errors?)` creates a `Group` that coordinates a set of worker threads:

- **`limit`:** Optional maximum number of concurrently active threads. Omitting it or passing `nil` leaves concurrency unbounded; `limit <= 0` raises `"group limit must be positive"`.
- **`propagate_errors`:** When `true`, the first uncaught worker error cancels the group with `CancellationReason.simple("group thread failed")`, cancelling running siblings and waking suspended `spawn*` calls. Defaults to `false`.
- **`Group:spawn` .. `Group:spawn_three`:** Start a worker in the group. When `limit` active threads are running, the call suspends the calling `async.Task` in a FIFO admission queue until a worker retires (including its OS join) or the group is cancelled. After `Group:cancel` (direct or via `propagate_errors`), queued and subsequent `spawn*` calls return immediately without starting threads. Cancelling a Task waiting in the admission queue withdraws that call and passes any granted slot to the next waiter.
- **`Group:cancel(reason?)`:** Marks the group cancelled (first reason wins; omitted or `nil` uses `CancellationReason.simple("cancelled")`), wakes queued `spawn*` waiters, and cancels all active threads.
- **`Group:wait()`:** Makes one observation pass over admitted members and suspends until every active thread and admitted spawn finishes, returning all uncaught `Error` records in completion order (cancelled threads add nothing). Group members count as observed (`Group:wait()` collects their errors, while the underlying `Thread:task()` proxy's ordinary uncaught-Task diagnostic still writes to `stderr`).

### Group failure and retry boundaries

- **Failure before the worker starts:** Preparation or OS-thread creation errors raise from `Group:spawn*`, returning the reserved slot with no worker retained.
- **Setup failure after the worker starts:** If creating the member's proxy or installing its terminal listener (or allocating the listener remover) fails, the admitted `Thread` and its slot remain owned by the group without respawning; calling `Group:wait()` retries setup or retires an already-terminal proxy idempotently.
- **OS join failure for a running member:** Escapes `async.loop()` as `async.OperationError` (`"async.native_retirement.retire"`), keeping the member, `Thread`, and slot in place so calling `async.loop()` again retries the join.
- **Immediate join failure for an already-finished child:** `Group:spawn*` raises that error while keeping the `Thread` and slot admitted; a subsequent `Group:wait()` retries setup once.

On Runtime shutdown, every active member proxy is cancelled like any other Task, forwarding cancellation to the worker and releasing its slot only after the OS join completes.
