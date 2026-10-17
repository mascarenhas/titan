# Thread standard library

The `thread` module (`import "thread"` from Titan, `require "titan.thread"` from
Lua) provides Go-inspired cross-thread concurrency over isolated Lua/Titan
states:

1. **Bounded, closeable cross-thread FIFO channels** (`Sender<|T|>` and
   `Receiver<|T|>`) whose endpoints can be cloned and transferred across OS
   threads, closures, records, and unions.
2. **Standalone OS worker threads** (`Thread<|R|>`) that run an isolated Lua
   state and asynchronous `titan.async` Runtime, with nonblocking status
   inspection, Task-suspending `join`, cooperative cancellation, and an
   `async.Task` proxy for combinator composition.
3. **Bounded thread groups** (`Group`) modeled on Go's `errgroup.Group` for
   running multiple worker threads with an optional concurrency limit and
   optional first-error cancellation propagation.

For single-thread cooperative Tasks, timers, and combinators within one state,
see [Asynchronous I/O and tasks](async-io.md). For manual independent-state
management, see [Lua states and loading](standard-library-lua.md).

## Public signatures

```text
record Error
  const error: value
  const traceback: string
end
function Error:raise()

union ThreadStatus<|R|>
  running()
  succeeded(R)
  failed(Error)
  cancelled(async.CancellationReason<|value|>)
end

function ThreadStatus:as_string(): string
function ThreadStatus:has_finished(): boolean
function ThreadStatus:has_succeeded(): (boolean, R?)
function ThreadStatus:has_failed(): (boolean, Error?)
function ThreadStatus:has_cancelled():
    (boolean, async.CancellationReason<|value|>?)

union ReceiveResult<|T|>
  message(T)
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
    (function (Receiver<|T|>, T?): (T?, nil), Receiver<|T|>, nil)
function Receiver:close()
function Receiver:is_closed(): boolean
function Receiver:clone(): Receiver<|T|>
function Receiver:to_transfer_payload(): string
function Receiver.from_transfer_payload(payload: string): Receiver<|T|>

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

## Cross-thread channels

`thread.channel<|T|>(capacity?)` allocates a thread-safe bounded FIFO channel
and returns its initial `(Sender<|T|>, Receiver<|T|>)` endpoint pair.

- `capacity` defaults to `1` when omitted or `nil`. Passing `capacity <= 0`
  raises `"channel capacity must be positive"`.
- Every message is serialized at `send` / `try_send` time into a native packet
  and reconstructed in the receiving state without sharing GC objects. Any
  value accepted by [transfer values](async-io.md#transfer-values) may be sent,
  including primitives, strings, public records and unions of transferable
  fields, closures with transferable captures, and records implementing
  `to_transfer_payload` / `from_transfer_payload` (including `Sender<|T|>` and
  `Receiver<|T|>` themselves, either at the top level or nested inside public
  records and unions). Top-level `Array` and `Map` values are not directly
  transferable; wrap an `Array` in a public `record` or `union` to send it across
  threads.

### Sending and receiving

- `Sender:send(message)` serializes `message` first (raising before touching the
  channel if `message` is not transferable). If the channel is closed, it raises
  `"channel is closed"`. If the buffer has space, it enqueues immediately and
  wakes one waiting receiver if present. If the buffer is full, it suspends the
  calling `async.Task` in the channel's FIFO send-waiter queue until a receiver
  frees a slot or the channel closes.
- `Sender:try_send(message)` serializes `message` first, raises
  `"channel is closed"` if the channel is closed, returns `true` if space was
  available immediately, and returns `false` without suspending if the buffer is
  full.
- `Receiver:receive()` dequeues the oldest message immediately if the buffer is
  non-empty (waking one blocked sender if present), or suspends the calling
  `async.Task` until a message arrives or the channel closes and drains. Once
  closed and drained, `Receiver:receive()` raises `"channel is closed"`.
- `Receiver:receive_result()` behaves like `receive()`, but returns
  `ReceiveResult.message(msg)` on delivery and `ReceiveResult.closed()` instead
  of raising when the channel is closed and drained.
- `Receiver:try_receive()` never suspends: it returns `(true, msg)` if a
  buffered item was available immediately, or `(false, nil)` if the buffer is
  empty (whether open or closed).
- `Receiver:incoming()` returns a generic-`for` iterator triple that yields
  messages in FIFO order until the channel is closed and drained:

```text
for msg in rx:incoming() do
  process(msg)
end
```

### Closing, cloning, and transferring endpoints

- `Sender:close()` marks the shared channel closed (`is_closed() == true`) for
  all `Sender` and `Receiver` clones while retaining any already-buffered
  messages so receivers can drain them. All currently blocked senders are woken
  and raise `"channel is closed"`, and all blocked receivers are woken once the
  buffer is empty.
- `Receiver:close()` marks the shared channel closed (`is_closed() == true`) for
  all `Sender` and `Receiver` clones, immediately discards all unread messages
  in the ring buffer, and wakes all blocked senders and receivers.
- Both `Sender:clone()` and `Receiver:clone()` create a new local endpoint
  handle sharing the same underlying channel and increment the channel's active
  sender or receiver count.
- Dropping and garbage-collecting a single `Sender` or `Receiver` clone releases
  only that handle's reference. Only when **all** active `Sender` handles across
  all threads have been garbage-collected does the channel automatically close
  from the sender side (preserving buffered messages for receivers). Likewise,
  only when **all** active `Receiver` handles have been garbage-collected does
  the channel automatically close from the receiver side and flush unread
  buffered messages. Unread messages flushed by `Receiver:close()` or finalizer
  cleanup release their packet memory without decoding nested endpoints.
- Both `Sender` and `Receiver` implement `to_transfer_payload` and
  `from_transfer_payload` for internal use by `titan.thread`'s message transfer
  machinery using **clone-on-transfer** semantics: transferring an endpoint
  through `Sender:send`, `Sender:try_send`, `thread.spawn*`, or `Group:spawn*`
  retains a new sender or receiver reference at serialization time without
  invalidating the caller's handle, and adopts that reference into a fresh
  handle in the destination state. An in-flight transferred endpoint keeps the
  channel open even if the sender drops its local handle before the receiver
  decodes the message, and failed or cancelled sends automatically roll back or
  release the retained reference. `Sender` and `Receiver` endpoints can only be
  transferred through thread channels and `spawn*` arguments; calling
  `protobuf.serialize`, `transfer.TransferValue.from_value`, or
  `to_transfer_payload` / `from_transfer_payload` directly outside thread
  message transfer raises
  `"thread endpoints can only be transferred through thread channels or spawn arguments"`.

## Standalone OS threads

`thread.spawn` and its fixed-arity companions `spawn_one` through `spawn_five`
create an isolated Lua/Titan state, snapshot the entry closure and its arguments
synchronously on the caller thread, and launch a dedicated OS worker thread. Any
non-transferable capture or argument raises immediately in the caller before the
OS thread starts.

Inside the worker OS thread:

1. `titan.thread` is loaded into the child state.
2. An asynchronous `titan.async` Runtime is started with the reconstructed
   entry closure as its root `Task`, and driven to completion with
   `async.loop()`.
3. The worker can freely use `timer`, `fs`, `net`, `ssl`, `http`, `sqlite3`,
   `thread.channel`, or nested `thread.spawn` / `thread.group` calls on its own
   event loop.
4. When the root `Task` returns `val`, its return value is serialized and
   recorded as `ThreadStatus.succeeded(val)`. If the root `Task` returns
   normally while other child tasks or active event-loop handles remain
   scheduled on the worker's Runtime, `async.loop()` continues running until all
   active work completes before the OS thread exits.
5. If the root `Task` raises an uncaught error or returns a non-transferable
   value, the failure and child traceback are recorded as
   `ThreadStatus.failed(Error(err, traceback))` (degrading a non-transferable
   error value to its rendered string representation while preserving
   `Error.traceback`) and `async.request_exit(0)` stops the child event loop
   cleanly.

### Observing, joining, and cancelling a `Thread`

- `Thread:status()` returns a nonblocking `ThreadStatus<|R|>` snapshot
  (`running()`, `succeeded(val)`, `failed(err)`, or `cancelled(reason)`).
- `Thread:join()` suspends the calling `async.Task` until the OS thread exits
  and returns its terminal `ThreadStatus<|R|>` without raising on `failed` or
  `cancelled`. Calling `join()` multiple times returns the cached terminal
  status.
- `Thread:cancel(reason?)` requests cooperative cancellation of the worker
  thread's root `Task` and wakes the child's event loop. (Any child tasks
  spawned inside the worker must be cancelled by the root `Task`'s own `defer`
  or cleanup handlers if they should stop on root cancellation.) The first
  cancellation reason wins; non-transferable cancellation reason payloads
  degrade to their rendered string or `CancellationReason.simple("cancelled")`.
  Cancelling an already-finished thread is a no-op.
- `Thread:task()` lazily creates (and memoizes) a host-state
  `async.Task<|R, value|>` proxy that joins the thread and resolves with `R` on
  `succeeded(val)`, raises via `err:raise()` on `failed(err)`, or cancels with
  `reason` on `cancelled(reason)`. Cancelling the proxy Task propagates
  cancellation to the underlying `Thread` and waits for the OS thread to finish
  before completing.
- If a standalone `Thread` fails with an uncaught error and is never observed
  via `status()` (after completion), `join()`, or `task()` before its handle is
  garbage-collected, its formatted error and traceback are written to `stderr`.

## Thread groups

`thread.group(limit?, propagate_errors?)` creates a `Group` that coordinates a
dynamic set of worker threads:

- `limit`: optional maximum number of concurrently running OS threads in the
  group. When omitted or `nil`, concurrency is unbounded. Passing `limit <= 0`
  raises `"group limit must be positive"`.
- `propagate_errors`: when `true`, the first uncaught error from any thread in
  the group automatically cancels the group with
  `CancellationReason.simple("group thread failed")`, cancelling all currently
  running sibling threads and waking any suspended `spawn*` callers. Defaults to
  `false`.
- `Group:spawn`, `spawn_one`, `spawn_two`, and `spawn_three` schedule a worker
  closure in the group. All threads spawned in a `Group` are automatically
  marked as observed so their uncaught errors are collected by `Group:wait()`
  rather than printed to `stderr`. When `limit` is configured and
  `active >= limit`, `spawn*` suspends the calling `async.Task` in a FIFO
  admission queue until a running worker finishes and releases its slot (or the
  group is cancelled). If `Group:cancel` has already been called (or triggered
  by `propagate_errors`), queued and subsequent `spawn*` calls return
  immediately without launching a new thread.
- `Group:cancel(reason?)` marks the group cancelled, wakes any tasks waiting for
  an admission slot, and cancels all currently active threads in the group.
- `Group:wait()` suspends the calling `async.Task` until all active threads and
  admitted spawns in the group have finished, then returns `{Error}` containing
  all uncaught `Error` values in completion order (cancelled threads do not
  append to the error array).
