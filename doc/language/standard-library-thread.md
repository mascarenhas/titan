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
  frees a slot or the channel closes. A wakeup does not pre-reserve a buffer
  slot or message for the woken Task: the resumed Task retries admission and may
  race other senders or receivers on the shared channel.
- `Sender:try_send(message)` serializes `message` first, raises
  `"channel is closed"` if the channel is closed, returns `true` if space was
  available immediately, and returns `false` without suspending (and disposes the
  serialized packet) if the buffer is full.
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
  `(true, message)` in FIFO order, then `(nil, nil)` once the channel is closed
  and drained. The first result controls iteration independently of the
  message, so nil and false remain ordinary payloads. Discard that continuation
  with `_` and mark the payload binding `?` to preserve a delivered nil:

```text
for _, msg? in rx:incoming() do
  process(msg)
end
```

For a nonnullable message type, an ordinary payload binding such as
`for _, job in rx:incoming() do` forces the optional iterator result to that
required message type.

A Task blocked in `send`, `receive`, `receive_result`, or `incoming` suspends
through the Runtime's shared
[external wake bridge](async-io.md#external-waits); other Tasks in its state
keep running. Cancelling the Task removes its waiter from the channel before
`Task:cancel` returns.

The channel links a waiter that lives on the blocked Task's coroutine stack. If
the Lua state closes while the Task is still blocked, the state withdraws that
waiter before it releases the stack, and the channel stays alive until then
even if every endpoint of the closing state is already gone. Clones held by
other states or threads keep working: the blocked Task never receives or sends,
and the channel closes as usual once its last sender or receiver is released.
The blocked Task does not finish, but it is unwound: its `defer` blocks run
inside a finalizer, where they cannot await. Cancel and join such Tasks and
drain their Runtime before closing the state when their cleanup needs to wait
([closing a state with an active Runtime](async-io.md#closing-a-lua-state-with-an-active-runtime)).

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
  cleanup release any retained nested `Sender` or `Receiver` endpoints through
  [`transfer.discard_message`](standard-library-transfer.md#native-message-packets)
  in C without entering Lua, loading modules, invoking user decoders, or
  requiring an active Runtime, including after the originating `lua_State` has
  closed.
- Packet attachments count as live native endpoints even while unread in a
  channel or `async.Receiver` slot. Native reference cycles are not collected by
  Lua GC: for example, enqueueing a channel's own `Receiver` can keep its
  receiver count nonzero after every public wrapper is dropped. Retain a
  reachable receiver and call `Receiver:close()` to drain and break such cycles
  before dropping the last application handle. `Sender:close()` alone preserves
  the unread packets.
- Every endpoint reference has exactly one owner: a live `Sender` or `Receiver`
  wrapper, or an undelivered packet that carries it. Decoding the packet moves
  the reference to a new wrapper, and disposing of the packet releases it.
  `Sender:close()` and `Receiver:close()` change the channel's state but release
  no reference; a wrapper's reference is released when the wrapper is
  collected.
- Endpoints transfer as
  [packet-scoped resource attachments](standard-library-transfer.md#scoped-resource-attachments-and-packet-local-indexes):
  - An endpoint can be sent at the packet root, nested in public records,
    unions, or their Array fields, captured by a closure, or converted with
    `TransferValue.from_value` and `to_value` inside a packet operation. Each
    occurrence retains its own reference and is encoded as a four-byte
    little-endian packet-local slot index; the sender's handle stays valid.
    `titan.transfer` encodes and claims endpoints directly, without calling
    their hook methods.
  - `Sender:to_transfer_payload()` and `Receiver:to_transfer_payload()` attach
    the endpoint with `transfer.attach_resource`, using the public C-ABI
    `channel_retain_{sender,receiver}_native` and
    `channel_release_{sender,receiver}_native` callbacks, and return the
    slot-index bytes. A custom hook of a record that keeps an endpoint in a
    private field can call them to embed the endpoint in its own payload.
  - Decoding an endpoint, directly or through
    `Sender.from_transfer_payload(payload)` or
    `Receiver.from_transfer_payload(payload)`, creates the destination wrapper
    and registers its finalizer before claiming the slot. Once the claim
    succeeds, the wrapper owns the endpoint even if decoding a later field of
    the same packet fails.
  - A channel created inside a worker thread and returned through
    `Thread:join()` or `Thread:task()` survives the close of the worker's state:
    the undelivered result packet owns the endpoint references until the parent
    reconstructs the result.
  - Only the current execution's exact top encode or decode scope, opened by
    `transfer.encode_message` or `transfer.decode_message`, authorizes
    attachment and claim. Endpoints can therefore cross `Sender:send`,
    `Sender:try_send`, `thread.spawn*`, `Group:spawn*`, and
    [`async.Receiver`](async-io.md#cross-state-receivers) (`async.send` /
    `Receiver:wait()`), as well as public records, unions, Array fields inside
    transferable roots, custom hooks, and closure captures within a packet.
  - `protobuf.serialize`, `transfer.TransferValue.from_value`, and
    `transfer.TransferValue:to_value()` do not create packet scopes. Outside the
    current execution's matching top scope, endpoint conversion raises
    `"transfer: resource attachment requires an encode scope"` or
    `"transfer: resource claim requires a decode scope"`. Opaque hooks and
    closure-policy conversion within such a scope reuse its packet, but the
    index bytes and policies they produce own no attachments. Independent
    `lua.Lua:run` and `run_async` copy those bytes over a separate carrier
    without the packet's resource table, so they cannot move endpoints. Other
    Tasks and separately resumed child Coroutines do not inherit a caller's
    packet authority. Custom hooks remain synchronous and nonyielding.
  - Duplicate occurrences of the same `Sender` or `Receiver` in one packet attach
    and claim separate slot entries. Claiming with a wrong byte width, an
    out-of-bounds or `0xffffffff` index, a mismatched endpoint kind (`Sender` vs
    `Receiver`), or an already-claimed slot raises before touching any native
    pointer.
    These are current-packet checks, not global anti-replay tokens: the same
    index bytes may select a different valid slot in another packet.
  - An in-flight packet keeps its retained channel references alive even if the
    sender drops its local handle before the receiver decodes the message.
    Encoding failures after earlier attachments, failed or cancelled sends,
    unread messages flushed by `Receiver:close()` or last-`Receiver`
    finalization, overwritten or closed `async.Receiver` slots, and unconsumed
    results, entry closures, or cancellation reasons of abandoned `Thread`
    handles automatically release their unclaimed retains via
    `transfer.discard_message`. If a composite decode fails after some endpoints
    were already claimed into finalized wrappers, `decode_message` releases only
    the remaining unclaimed entries while the adopted wrappers stay owned by the
    destination collector.
  - **Manual-handoff resources are not auto-disposed by channel discard**:
    native packet discard releases only resources registered in the packet's
    resource table (in the standard library, only `Sender` and `Receiver`
    endpoints) and never runs `from_transfer_payload` decoders. Sending an
    `http.Exchange`, `ssl.Connection`, `net.Connection`, `websocket.Connection`,
    or custom manual resource over a channel still requires the caller to
    recover or explicitly dispose rejected payloads through that type's actual
    API and to drain and dispose unread payloads before `Receiver:close()`.
    See the
    [manual-handoff inventory](standard-library-transfer.md#manual-handoff-api-inventory);
    not every native-backed type exports `discard_transfer_payload`.

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
6. A root `Task` that never entered its body is still reported from its actual
   outcome: when cancellation is accepted before the first statement, the worker
   records `ThreadStatus.cancelled(reason)` with the accepted reason, and a
   checked entry failure is recorded as the original failure. A pre-start
   cancellation is not reported as a generic failed thread.

### Observing, joining, and cancelling a `Thread`

- `Thread:status()` returns a nonblocking snapshot of the thread's logical
  outcome: `running()`, `succeeded(val)`, `failed(err)`, or `cancelled(reason)`.
  It never joins and never waits. A terminal snapshot can appear before the
  worker's OS thread has finished exiting (its final cleanup and thread-local
  destructors may still be running), so it is not evidence that the OS thread
  has retired.
- `Thread:join()` requires a running Task. It suspends that Task until the worker
  has finished and its OS thread has actually been joined, then returns the
  terminal `ThreadStatus<|R|>` without raising on `failed` or `cancelled`.
  Every return path performs the real join: an already-finished worker, an
  outcome that `status()` cached earlier, and a fresh suspension all end in it.
  A later `join()` of the same handle returns the same outcome without joining
  again. `join()` first checks for pending cancellation or Runtime shutdown, so
  a cancelled joiner observes its own cancellation. The OS join itself does not
  yield, and the owning cooperative Runtime serializes joins of one handle.
  A worker publishes its outcome before its OS thread finishes exiting. A
  `join()` that starts at that point blocks until the thread actually exits;
  no bound on that final tail is promised.
  If the OS join fails, `join()` raises `async.OperationError` with operation
  `"thread.join"` instead of returning a status. The thread stays joinable, so
  a later `join()` can retry. A terminal `status()` is never a substitute for
  joining. If the Lua state closes while a Task is suspended in `join()`, the
  state withdraws that join before it releases the Task's stack, so a worker
  that finishes later finds nothing to wake; the suspended `join()` never
  returns.
- `Thread:cancel(reason?)` asks the worker's root `Task` to cancel cooperatively
  and wakes the child's event loop; the root's `defer` and cleanup handlers run
  normally. Child Tasks started inside the worker are not cancelled
  automatically: the root `Task` must cancel them in its own `defer` or cleanup
  handlers if they should stop. The first request from the host wins. Later
  calls, and calls on an already-finished thread, do nothing. Omitting `reason`
  or passing `nil` requests `CancellationReason.simple("cancelled")`.
  - The reason is transferred like any other thread message: `simple(text)`
    carries the text and `complex(value)` carries the value, so empty text,
    `nil`, `false`, and packet-scoped endpoint payloads arrive unchanged.
  - If the reason cannot be transferred, the child receives
    `CancellationReason.simple("cancelled")` instead. No rendered text is
    promised to reach it. The host-side `Thread:task()` proxy still retains the
    exact first reason.
  - The child's own cancellation outcome degrades the same way. If the child's
    reason cannot be transferred, `status()`, `join()`, and the `Thread:task()`
    proxy all report `CancellationReason.simple("cancelled")` rather than the
    child's real payload or any rendered text.
  - The child root's own first cancellation reason decides its terminal status.
    A host reason that arrives later, even while an earlier self-cancellation is
    still unwinding, does not replace it. The host Task's original reason or
    error is preserved separately.
- `Thread:task()` creates the thread's `async.Task<|R, value|>` proxy on first
  use and returns the same proxy afterwards. The proxy runs in the calling state
  and marks the `Thread` observed. It resolves with `R` when the thread
  succeeds, raises the child's error through `err:raise()` when the thread
  fails, and is cancelled with `reason` when the thread was cancelled. Compose
  it with the `async` combinators like any other Task.
  - **Terminal timing.** The proxy publishes its terminal status, runs its
    terminal listeners, and delivers its result only after the child has
    finished its own cleanup and its OS thread has been joined. This holds when
    the proxy is cancelled while still `ready`, when it is cancelled while the
    child unwinds, and when the proxy fails before its body or cleanup starts.
    A terminal proxy therefore means the OS thread has been joined; release
    state shared with the thread only after that, or after `join()` returns.
  - **Cancelling the proxy.** Cancelling the proxy cancels the thread. The
    proxy passes its first cancellation reason to `Thread:cancel`, or the
    default `CancellationReason.simple("cancelled")` when the proxy body failed
    without any cancellation, and then waits for the child to finish and be
    joined. A cancellation request is not by itself evidence that the child has
    retired: until the proxy is terminal or `join()` returns, keep every
    resource the thread may still use.
  - **Which reason wins.** The proxy keeps the first cancellation reason it
    accepts, and the child keeps a cancellation reason it already accepted. A
    later cancel request replaces neither, and cancelling never substitutes for
    the OS join.
    A first explicit `cancel` on the proxy that arrives before the
    proxy is terminal takes precedence over a pending success or error, as for
    any unfinished Task. That includes the interval after the child's body has
    finished and only the OS join remains. The terminal status still follows the
    OS join.
  - **Fallback cancellation.** If forwarding the reason was missed or failed,
    the thread library may ask the child to cancel without supplying a reason.
    It does so only when no cancellation was already accepted by the child and
    the child has no recorded outcome, and never merely because the proxy body
    is still running normally.
  - **OS join failure.** If the OS join fails while the proxy waits for the
    child, `async.loop()` raises an `async.OperationError` with operation
    `"async.native_retirement.retire"`. That error is not a Task outcome: the
    proxy stays nonterminal and keeps ownership of the thread, and calling
    `async.loop()` again retries the join without any further setup.
  - **Proxy creation failure.** If the proxy cannot be created, no Task is
    exposed and the `Thread` keeps ownership of its worker and its unjoined
    OS-thread handle. The worker is not necessarily still running: when the
    child had already finished but the immediate attempt to join it did not
    complete, the failure leaves a finished worker whose OS thread is still
    unjoined.

  See the
  [implementation wiring](../implementation/thread-library.md#join-proxy-retirement-and-the-native-terminal-barrier)
  for the mechanism.
- If a standalone `Thread` fails with an uncaught error and nobody observes it
  (through `status()` after completion, `join()`, or `task()`) before its handle
  is garbage-collected, the formatted error and traceback are written to
  `stderr`.
- Dropping a `Thread` handle is not retirement. When the last reference to the
  thread's native state goes away without a recorded join, whether or not the
  outcome was observed, any OS-thread handle still owned is detached (POSIX
  self-detach; Windows closes the real handle). Detaching is best-effort
  reclamation: it never counts as a join or as evidence that the child retired,
  and no status or join outcome is reported for it. The `stderr` diagnostic
  above still happens at that same moment for an unobserved failure.

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
- `Group:spawn`, `spawn_one`, `spawn_two`, and `spawn_three` start a worker
  closure in the group. When `limit` is set and that many workers are already
  running, the call suspends the calling `async.Task` in a first-in, first-out
  admission queue until a running worker finishes and releases its slot or the
  group is cancelled. Once `Group:cancel` has been called, directly or through
  `propagate_errors`, queued and later `spawn*` calls return immediately without
  starting a thread.
- A worker keeps its slot until it has fully retired. The slot is released when
  the member's `Thread:task()` proxy becomes terminal, which includes the
  actual OS join. A group member is exactly one memoized `Thread:task()` proxy
  plus one terminal listener; there is no extra observer Task. Retiring a member
  removes it from the group and arranges the release of its slot before
  projecting its status or error, so an error raised by a listener cannot strand
  admission or completion accounting.
- Threads started in a `Group` count as observed: `Group:wait()` collects their
  uncaught `Error` instead of leaving it to the `stderr` report. Because the
  group uses the standard proxy, that proxy's usual uncaught-Task failure
  diagnostic for a failing member still appears on `stderr`. It is intentionally
  not suppressed.
- `Group:cancel(reason?)` marks the group cancelled, wakes every Task waiting
  for an admission slot, and cancels all currently active threads in the group.
  Omitting `reason` or passing `nil` selects
  `CancellationReason.simple("cancelled")`. The first group reason wins.
- `Group:wait()` makes one observation pass over the admitted members, then
  suspends until every active thread and admitted spawn has finished. It
  returns the uncaught `Error` values in completion order; cancelled threads add
  nothing to the Array. If the child itself did not fail but its host-side proxy
  failed during ordinary startup or cleanup, the proxy's error and traceback are
  collected instead, with no duplicate record.

### Group failure and retry boundaries

Failures while starting or retiring a member fall into four cases:

- **Failure before the worker exists.** A preparation or thread-creation failure
  raises from `Group:spawn*`. No worker was started, the reserved slot is
  returned, and nothing is retained.
- **Failure setting up the member after the worker exists.** If creating the
  proxy or installing its listener fails, the same admitted child and slot stay
  in the group and an explicit `Group:wait()` retries the setup. The group never
  respawns an admitted child. When `Group:wait()` finds the member's proxy
  already terminal, it retires the member immediately, because a terminal Task
  does not invoke new listeners. The same recovery applies if the listener was
  installed but allocating its returned remover failed: the member and its proxy
  stay owned, and the next `Group:wait()` either retires the member or installs
  another listener. Retirement is idempotent, so an earlier listener and a later
  one cannot release the same member twice.
- **OS join failure for a running member.** The failure escapes `async.loop()` as
  the same `async.OperationError` described for
  [`Thread:task()`](#observing-joining-and-cancelling-a-thread). The member,
  its `Thread`, and its slot stay in place, and calling `async.loop()` again
  retries the join.
- **Child already finished before its proxy is created.** The immediate attempt
  to join it can fail before any Task exists. `Group:spawn*` then raises that
  original error while the `Thread` and its slot stay admitted, and an explicit
  later `Group:wait()` makes one observation pass and retries the setup once.

None of these cases spins, replaces the proxy, or grants the slot early.

On Runtime shutdown, each member's proxy is cancelled like any other Task. That
cancellation is forwarded to the worker, and the member is retired and its slot
released only after the actual OS join.
