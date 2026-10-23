# Thread-library implementation

The user-facing contract is in the
[thread standard-library chapter](../language/standard-library-thread.md).
`titan.thread` is a folder ensemble under `titan/thread/`:

- `thread.titan`: folder main; public `Error` and `ThreadStatus`; the intrusive
  waiter queue (`waiter_enqueue`, `waiter_unlink`, `waiter_wake_one`,
  `waiter_wake_all`); packet helpers (`value_to_thread_message`,
  `thread_message_discard`); the public C-ABI endpoint callbacks
  (`channel_retain_sender_native`, `channel_retain_receiver_native`,
  `channel_release_sender_native`, `channel_release_receiver_native`); and the
  C-only channel drain and destroy helpers.
- `channel.titan`: `Sender<|T|>`, `Receiver<|T|>`, `ReceiveResult<|T|>`,
  `channel`, cloning, endpoint finalizers, the registered resource capability
  (`register_channel_resources` and its accessors and constructors), the
  endpoint transfer hooks, and the wait registrars.
- `spawn.titan`: `Thread<|R|>`, `spawn` through `spawn_five`, worker bootstrap,
  cancellation, `Thread:join()`, the native-retirement callbacks and the
  `Thread:task()` proxy.
- `group.titan`: `Group`, `group`, membership, admission queues and
  `Group:wait()`.
- `native.h`: `titan_thread_message` (an alias of `titan_async_message`),
  `titan_thread_waiter`, the automatic `titan_thread_channel_wait` and
  `titan_thread_join_wait` cells, `titan_thread_waiter_queue`,
  `titan_thread_channel` and `titan_thread_control`.

## Layering and cross-thread primitives

`titan.thread` does not include `<uv.h>`. It uses the public C-ABI entries that
`titan.uv` exports
([synchronization entries](libuv-extension-guide.md#synchronization-entries-and-heap-thread-tokens)):
`uv.mutex_t.create_native` and `uv.native_mutex_lock`/`unlock`/`destroy`;
`uv.async_send_native` for the child's root-cancellation handle;
`uv.native_external_wake_retain`/`release`/`notify` for channel and join
waiters; and `uv.create_native_thread`, `uv.native_thread_join` and
`uv.native_thread_detach` for the worker's heap thread token. `ctrl.os_thread`
owns that joinable token until a successful `uv.native_thread_join` consumes it;
only `thread_control_destroy_unreferenced` falls back to detach.

Waiter registration, ring operations, reference counts and control-block
transitions run under the native channel or control mutex. Lua allocation and
packet disposal (`thread_message_discard`) always happen outside those critical
sections, so an allocation error cannot `longjmp` with a native mutex held and a
recursive endpoint release cannot re-enter the same lock.

`titan.lua` exposes `Lua:detach(): foreign *lua_State`, so `spawn_raw` prepares
the child state and its preload snapshot on the parent thread and hands the raw
pointer to the worker.

## Native message packets and nested custom transfer hooks

Channel items, the spawn entry closure, return values, failure errors and
cancellation reasons each travel as one owned `titan_thread_message` packet,
produced by `transfer.encode_message` and consumed by `transfer.decode_message`
outside every channel and control mutex. Packet classification, layout and the
caller's decode recipe are canonical in
[transfer packets](transfer-library.md#flat-packets-and-direct-classification)
and [consuming raw-slot decode](transfer-library.md#consuming-raw-slot-decode).
Every thread caller follows that recipe: a `foreign *void` local initialized
with the packet, an immediate `defer thread_message_discard(raw)`, and a direct
`transfer.decode_message(raw)`.

At initialization `register_channel_resources` registers `Sender<|value|>` and
`Receiver<|value|>` with `transfer.register_resource`, so endpoints transfer at
a packet root, nested in records, unions and Arrays, inside `value` fields, in
custom hooks and in closure captures. Nested endpoint fields and nested
custom-hook records are handled by protobuf
([encoding](protobuf-library.md#encoding),
[decoding](protobuf-library.md#decoding)).

### Cancellation reasons

The erased `async.CancellationReason<|value|>` schema cannot be encoded directly,
because protobuf cannot encode its `complex` arm's erased `value`. The variant
travels as native metadata and the payload as an ordinary packet:

- `titan_thread_control` has separate `cancel_reason_kind` and
  `result_reason_kind`, each committed with its packet under `ctrl.mutex`, so a
  host request and a child result cannot retag each other.
- `cancellation_to_thread_message` encodes the `simple` text or `complex` payload
  with `transfer.encode_message`, so nil, `false`, empty text and endpoint
  attachments round-trip. Only an unencodable payload falls back to rendered text
  under the `DEFAULT` kind; a second failure propagates without admission,
  leaving native reasonless retirement able to cancel the child.
- `thread_message_cancellation` rebuilds the arm from the kind. `DEFAULT` or an
  unknown kind becomes `CancellationReason.simple("cancelled")`; the rendered
  text is never reconstructed.

After the root body unwinds, the child records its outcome from its own
`async.checkpoint()`, so the root Task's first sticky reason wins even if a
different host reason arrived during a self-cancel. The host keeps its own
original reason or error.

## Channel state machine and endpoint transfer

`titan_thread_channel` holds:

- `mutex`: heap `uv_mutex_t` protecting every field;
- `active_senders`, `active_receivers`: endpoint reference counts across all
  states, including units held by in-flight packet entries;
- `waiter_pins`: one per waiter registration not yet withdrawn or acknowledged
  ([registration pins](#registration-pins-and-state-close-withdrawal)). When
  both endpoint counts and `waiter_pins` reach 0 (`channel_unreferenced`),
  `channel_destroy_unreferenced` frees the ring, mutex and struct;
- `ring` (pointer to `titan_thread_message *` slots) with `capacity`, `head`,
  `tail`, `count`;
- `overflow_waiters`, `underflow_waiters`: intrusive FIFO
  `titan_thread_waiter_queue`s;
- `closed`: 0 open, 1 closed by a sender (`Sender:close()` or the last sender
  release), 2 closed by a receiver (`Receiver:close()` or the last receiver
  release). Sender paths set 1 only while the channel is open; receiver paths
  set 2 unconditionally, so a receiver-side close overrides an earlier sender
  close (1 → 2).

`Receiver:incoming()` returns `(true, message)` per packet and `(nil, nil)` once
closed and drained. The independent continuation value keeps nil and `false`
messages as data without a per-message wrapper; callers bind `message?` when nil
is allowed.

### Waiter suspension, shared external wake, and $O(1)$ cancellation unlink

A send on a full ring, a receive on an empty ring, or a join on an unfinished
thread first runs the locked fast check (`channel_try_enqueue_native`,
`channel_try_dequeue_native`, or the `ctrl.finished` test). Inline
readiness links no waiter and retains no target, and `Sender:try_send` /
`Receiver:try_receive` never prepare a wait. Only the slow path links a
`titan_thread_waiter` into the channel's `overflow_waiters` /
`underflow_waiters` or the control block's join queue.

#### Shared external-wake suspension

Channel send/receive, `Thread:join` and the proxy body's logical-finish wait
(`Thread:wait_until_finished`) all suspend through `async.wait_external_native`
with C-ABI registrars, on the Runtime's one shared `uv.external_wake_t`
([external wake bridge](libuv-runtime.md#external-wake-bridge)); no path
creates a per-wait `uv.async_t`. `titan_thread_waiter.wake_target` holds the
retained target for exactly one registration interval.

Channel calls borrow one automatic `titan_thread_channel_wait` cell (channel and
message pointers, embedded waiter, registrar status) in the stackful Task
frame, and pass the traced endpoint as the wait's semantic owner. The fast path
allocates no registrar closure or capture box. Every cancellation and unwind
path unlinks synchronously before the frame unwinds, and native producers touch
the waiter only under the channel mutex. `Thread:wait_until_finished` likewise
borrows an automatic `titan_thread_join_wait` cell (control pointer and
embedded waiter) with the `Thread` as owner, registered by
`thread_control_register_join_wait` and withdrawn by
`thread_control_unregister_join_wait`. These are call-scoped borrows; closing a
state with a Task parked in one of them relies on
[state-close withdrawal](#registration-pins-and-state-close-withdrawal).

The registrars `channel_register_send_wait` / `channel_register_receive_wait`
repeat the locked fast check after the yield. They return `0` for inline-ready
and `1` for linked; the cell's status records a closed channel. Send
registration clears the cell's packet pointer in the same foreign interval as
the enqueue; receive registration commits the dequeued packet into the cell, so
cancellation that races an inline commit never discards a published packet or
leaks a dequeued one. A `defer` guards the cell's remaining packet. Titan code
reaches the cell only through a `foreign *titan_thread_channel_wait` local: a
by-value aggregate written in a protected body and read by its `defer` would get
a [longjmp-safe spill](c-ffi-expressions.md#longjmp-safe-aggregate-spills) whose
recovery reload would overwrite the registrar's packet commit. Send installs its
`defer` before the fast path because it owns the encoded packet from the start;
receive installs it only on a waiting iteration.

Waiter protocol:

- **Publication.** `waiter_enqueue` retains the target and takes the
  registration pin under the domain mutex. Lock order is domain mutex, then
  wake-core mutex.
- **Wake.** `waiter_wake_one` unlinks the node, sets `active = 0` and
  `signaled = 1`, detaches and notifies the exact target, and releases the
  producer reference, touching no GC object. The pin stays with the woken
  registration. Normal completion does not call the unregister callback.
- **No reservation.** A wake reserves no slot or message; the woken Task retries
  the fast check. Stale or duplicate notifications recheck and suspend again,
  so FIFO selection is not FIFO completion.
- **Acknowledgment.** The first attempt of a send or receive is the plain fast
  check. Every later attempt follows a wait and goes through
  `channel_retry_enqueue_native` / `channel_retry_dequeue_native`, and the join
  loop polls with `thread_control_poll_join_native` after each wait. Under that
  same lock `waiter_acknowledge` clears `signaled` and drops the pin of the wake
  that ended the previous wait.
- **Cancellation.** `channel_unregister_overflow_waiter` /
  `channel_unregister_underflow_waiter` take `ch.mutex`. An active node is
  unlinked in $O(1)$ (`waiter_unlink`) and its target released. A node that was
  already signaled passes the baton to the next waiter with `waiter_wake_one`
  when space, messages or closure can still make progress, then clears
  `signaled` so a repeated detach cannot pass it twice. Either way the pin is
  dropped, and a channel left unreferenced is destroyed after unlock.
  `thread_control_unregister_join_wait` unlinks without a baton, because
  completion wakes every joiner, and frees `ctrl` at `refcount == 0`.

The proxy **cleanup** join never links a `titan_thread_waiter`. Its
`final_wait:wait_cleanup()` awaits the prearmed native retirement through
`ExternalWait:await`'s native branch, polling `retirement_poll_native` and
otherwise suspending on the same bridge.
`thread_control_register_retirement_native` retains the target in
`ctrl.proxy_wake_target`, so the retirement capability, not a join waiter, owns
that reference.

#### Registration pins and state-close withdrawal

A parked waiter is borrowed storage in a suspended coroutine frame, linked into
a queue whose channel or control block can outlive the frame's Lua state. When
that state closes with the Task still parked, two mechanisms keep the native
queues safe (issue #262):

- **Withdrawal before the stack is released.** `coro_gc`
  [unwinds](coroutines.md#unwinding-an-abandoned-coroutine) a suspended stack
  before destroying it, so each parked C-ABI wait is withdrawn by its own
  cleanup ([state close](libuv-runtime.md#lua-state-close-of-an-unretired-runtime))
  through its unregister callback: `channel_unregister_send_wait`,
  `channel_unregister_receive_wait` or `thread_control_unregister_join_wait`.
  After that, no queue links a node on a destroyed stack, so neither a later
  endpoint finalizer of the same state nor another state's or thread's send,
  close, last release or worker completion can reach one.
  `channel_unregister_send_wait` takes the packet a withdrawn send still holds
  in `wait.message` and discards it natively after releasing `ch.mutex`, since
  discarding can release endpoints of the same channel. The send's `defer`,
  which runs afterwards on cancellation and on unwinding, finds the cleared
  pointer. A parked receive or join cell owns no packet when it is withdrawn;
  a packet already dequeued for it is disposed by the receive's `defer`.
- **Per-registration pin.** That unregister can run after the state's endpoint
  or `Thread` handle was finalized and released its reference. `waiter_enqueue`
  therefore takes one pin under the domain mutex it already holds:
  `ch.waiter_pins` for a channel, one `ctrl.refcount` unit for a join. A
  registration holds its pin while its node is linked (`active`) and, after a
  wake, until its own Task acknowledges it (`signaled`); `waiter_holds_pin`
  reports either state. A channel is destroyed only when `channel_unreferenced`
  finds both endpoint counts and `waiter_pins` at 0, and `ctrl` only at
  `refcount == 0`.
- **Only the waiting side drops a pin.** Unregister (cancellation, unwind,
  failed registration or state-close withdrawal) drops the pin of a linked or
  signaled node and destroys a channel or control block that it leaves
  unreferenced. A state-close withdrawal can therefore be the final release:
  the channel's unread packets are then disposed natively on the closing thread,
  and a `ctrl` whose handle was dropped unjoined detaches the OS thread token.
  Its join registration already set `observed`, so no unobserved-failure report
  is written. After a normal wake, the retry or join poll acknowledges the wake
  with `waiter_acknowledge`; the Task still holds its endpoint or `Thread`
  there, so that decrement never frees the domain and needs no destroy check.
  A waker never drops the pin: a waker on another thread could unlink the node,
  drop the pin and release the last remote reference while the closing state
  was about to lock that domain to withdraw the same node.
- **Destruction check.** `channel_destroy_unreferenced` and
  `thread_control_destroy_unreferenced` abort if a queue still links a node.
  Every linked node holds a pin, so this only fires on a pin-accounting bug,
  and it fails deterministically even in builds without a sanitizer.

Cost: the uncontended path is unchanged, because the first attempt of a send,
receive or join performs the same locked check as before. A registration adds
one increment of the pin under the lock it already holds. A retry after a wake
adds a test of `signaled`, its clear and one decrement under the lock the retry
takes anyway. Unregister adds one decrement and the `channel_unreferenced`
test, and a channel release tests `waiter_pins` too. There is no allocation,
extra lock or GC object on a channel path. A join that suspends takes one
extra uncontended `ctrl` lock, for the poll after its wake, while the native
registrars remove the two registrar closures it used to allocate.

### Endpoint transfer, C-ABI release chain, and last-`Receiver` pin

Endpoint reference units follow the ownership rules, scope authority, attachment
and claim order of the
[packet-scoped resource table](transfer-library.md#scoped-resource-table-and-manual-resource-ownership).
The thread-specific parts:

- **Registration.** `register_channel_resources` passes the accessors
  `sender_resource` / `receiver_resource`, the retain/release callbacks
  `channel_retain_{sender,receiver}_native` /
  `channel_release_{sender,receiver}_native`, and the constructors
  `sender_from_resource` / `receiver_from_resource`. Private `.native` access
  stays in `channel.titan`; `protobuf` imports neither `transfer` nor `thread`.
- **Retain.** Each encoded occurrence (direct capability route or
  `Sender`/`Receiver:to_transfer_payload` hook route) increments
  `active_senders` or `active_receivers` under `ch.mutex`.
- **Finalizer-first adoption.** Both adoption routes
  (`sender_from_resource`/`receiver_from_resource` with the carried scope, and
  `Sender`/`Receiver.from_transfer_payload` through `transfer.claim_resource`)
  call `new_sender`/`new_receiver`, which allocate the wrapper with
  `native = nil` and register `sender_finalize`/`receiver_finalize`, then claim
  and assign `native` with no intervening allocation or yield.
- **Allocation-free finalizer registration.** Both finalizers are declared
  `function (value): ()` and project their argument themselves, matching
  `gc.finalizable<|value|>`'s erased formal, so constructing a wrapper
  (`channel`, `clone`, both adoption routes) allocates only the record userdata
  and the shared metatable's `__gc` stays one closure.
- **No-Lua release chain.** `channel_retain_*_native`,
  `channel_release_*_native`, `channel_drain_and_discard` and
  `channel_destroy_unreferenced` are Titan `foreign function`s compiled to plain
  C. They take no `lua_State`, touch no GC object, load no module, and remain
  callable from `transfer.discard_message` after the originating state has
  closed; their code stays mapped under the
  [process-lifetime provider binding](foreign-functions.md#source-collaboration-and-binary-isolation).
  Worker bootstrap and `transfer_load_module` are not part of this chain and
  need a live state.
- **Last-`Receiver` pin.** `channel_release_receiver_native` decrements when
  more than one receiver remains. For the last one it sets `closed = 2`, wakes
  both queues and unlocks **without** decrementing, calls
  `channel_drain_and_discard` (which detaches one packet at a time under the
  mutex and discards it outside), then relocks, decrements to 0 and destroys the
  channel if no sender or registration pin remains. Because the count stays 1
  during the drain, a discarded packet that releases a `Sender` of the same
  channel, or recursively drains another channel, cannot free `ch` mid-drain.
  `Receiver:close()` uses the same drain.
- **Cycles need an explicit close.** Packet entries count like wrappers. A ring
  holding its own `Receiver`, or channels holding one another's receivers, keep
  `active_receivers` nonzero after every wrapper is gone, so the last-receiver
  transition never runs. The application must keep a receiver and close it;
  `Sender:close()` preserves queued packets.
- **Single disposal.** Every losing or aborted packet path (full or closed
  `try_send`, closed or cancelled `send`, the receive-wait cell guard,
  `Receiver:close()`, last-receiver finalization, a losing `Thread:cancel`, failed
  `spawn_raw`, child bootstrap and exit, abandoned handles) disposes its one
  packet once, outside locks, with `thread_message_discard`.

## Isolated OS thread lifecycle and cancellation

Worker diagnostics use direct native writes that work after the Lua state has
closed (`write_stderr_bytes`). Each write is capped at 64 KiB with a count type
matching the platform (`titan_thread_write_count`: `unsigned int` on the Windows
CRT, `size_t` on POSIX); offsets stay `size_t` so partial writes still emit the
complete report.

`spawn_raw<|R|>(entry, initially_observed, admission)` encodes the zero-argument
`entry` into `ctrl.entry_msg`, detaches a fresh `lua.new()` state, sets
`ctrl.refcount = 2` (parent handle and worker), creates the worker with
`uv.create_native_thread` and stores the token in `ctrl.os_thread`. For a
`Group` member, `admission` is the group's membership Map: `spawn_raw` publishes
`admission[handle] = false` once the handle owns `ctrl`, and the failure `defer`
registered right after control-block creation removes it, clears the handle's
pointer, closes a detached child state and releases `ctrl`. The fixed-arity
helpers wrap the target and its arguments in `function (): R return entry(...) end`
so transfer snapshots them as one closure.

Worker sequence:

1. `thread_worker_protected` loads `titan.thread` in the child with
   `transfer.transfer_load_module`, stores `ctrl` in
   `LUA_REGISTRYINDEX["_TITAN_THREAD_CTRL"]`, and calls the
   `child_thread_bootstrap` registered under `"_TITAN_THREAD_BOOTSTRAP"`.
2. `child_thread_bootstrap` takes `ctrl.entry_msg` under a `defer` that discards
   any unconsumed entry or leftover cancellation packet, schedules the root Task
   (which decodes the entry), registers an unreferenced `uv.async_t`
   cancellation handle in `ctrl.child_cancel_handle`, and runs `async.loop()`.
3. The root Task's `defer` clears and closes the cancellation handle. Its `catch`
   records a failure or cancellation in `ctrl` and calls `async.request_exit(0)`
   so remaining child handles close. If the parent already abandoned its handle
   (`ctrl.abandoned`), the `thread_control_record_*_native` functions discard the
   result packet outside the mutex instead of storing it. After `async.loop()`
   returns, a still-`RUNNING` status (pre-start cancellation skipped the body, or
   the checked entry failed before its catch) is recorded from
   `root_task:status()`, so a child cancelled before its first statement reports
   `cancelled(reason)`.
4. `thread_worker_main` closes the child state, records a fallback failure
   (`record_bootstrap_failure_native`) if the status is still `RUNNING`, and calls
   `thread_control_complete_native`: discard leftover packets outside the mutex,
   set `ctrl.finished = 1`, then notify the proxy target and wake every join
   waiter. It then drops the worker's `ctrl` reference. `finished` is logical
   completion, not OS-thread exit; the worker callback and OS/TLS tail may still
   run, and only a successful OS join retires the worker.
5. In the parent, `Thread:reconstruct_terminal_status` detaches the result and
   traceback under `ctrl.mutex` and decodes, allocates and frees outside it,
   caching the `ThreadStatus<|R|>`. A parent that drops its handle without
   reconstructing runs `thread_control_abandon_and_release`, which sets
   `ctrl.abandoned`, discards already-recorded packets outside the mutex and
   releases its reference.
6. When `ctrl.refcount` reaches 0, `thread_control_destroy_unreferenced`
   discards remaining packets, releases a retained `proxy_wake_target`, detaches
   a still-owned token, writes `ctrl.stderr_report` if the thread failed and was
   never observed (`ctrl.observed == 0`), and frees the control block.

## Join, proxy retirement, and the native terminal barrier

`Thread:status()` reads `ctrl.finished` under `ctrl.mutex`, returns `running()`
while it is 0, and never joins. A terminal snapshot can therefore precede the
worker's OS/TLS tail.

`Thread:join()` requires a running Task, checkpoints, waits for `finished`
through `Thread:wait_until_finished`, then calls
`thread_control_join_native(ctrl, 0)`, which inspects state under `ctrl.mutex`,
releases it, and performs the blocking `uv.native_thread_join`:

| Result | Meaning |
| --- | --- |
| `1` | not finished; nothing joined. This is what lets the same helper serve as the retirement poll. |
| `0` | joined now (token consumed, `os_joined` latched) or already joined |
| `-1` | the control never held a joinable token |
| other negative | native join failure; the token survives for a retry |

A nonzero result makes `Thread:join()` raise `async.OperationError` with
operation `"thread.join"` instead of publishing a status. The owning cooperative
Runtime serializes joins of one handle; cross-state concurrent joins are not
supported. No bound is promised on the remaining OS/TLS tail.

`Thread:task()` memoizes one `async.run_with_cleanup` proxy whose third argument
is

```text
local final_wait = async.prepare_native_retirement(
  self, ctrl as foreign *void,
  thread_control_register_retirement_native,
  thread_control_unregister_retirement_native,
  thread_control_retire_native)
```

The `Thread` handle is the traced owner, alive through callback return and
committed readiness. It is not a state-close pin; the worker's reference keeps
the control block and target slot valid. The three callbacks are source-private
`local foreign function`s, absent from provider metadata:

- `thread_control_register_retirement_native(context, target)` marks the
  outcome observed and returns `0` if already finished, `1` after retaining the
  proxy target, and `-1` for nil arguments or a second target. On `0` the
  constructor performs the OS join before exposing the proxy and requires
  success; a pending or negative result fails admission and leaves the finished
  worker with its unjoined token.
- `thread_control_unregister_retirement_native(context)` is constructor rollback
  only.
- `thread_control_retire_native(context)` is
  `thread_control_join_native(ctrl, 1)`. On the unfinished path it may request a
  reasonless child cancellation, only when `cancel_requested == 0` and the status
  is `RUNNING`. Because `thread_control_complete_native` notifies the proxy
  target only after `finished = 1`, retirement after notification is join
  success or a preserved negative status, never pending.

The proxy body awaits **logical finish only** (`wait_until_finished`) and
projects success, failure or cancellation. It does not call `Thread:join`: a
body join failure followed by cleanup would retry the join within one driver
invocation, so only the prearmed barrier attempts the proxy's OS join. The
cleanup forwards its `reason` with `self:cancel(reason)` while `finished` is
false. Outside Lua-state close it first registers a `defer` that runs
`final_wait:wait_cleanup()` and then `final_wait:close()`. That reason is nil
when the body failed without cancellation, so `Thread:cancel(nil)` sends the
default `simple("cancelled")`. At state close the cleanup runs outside any
Task, so it skips the barrier and only forwards cancellation, and the armed
gate stays nonterminal
([state close](libuv-runtime.md#lua-state-close-of-an-unretired-runtime)). The
generic driver gates terminal status, listeners and the result on native
retirement, so a cancelled proxy cannot publish before the child's cleanup and
OS join. Cancellation admission at the cleanup wait,
reason precedence, negative-status retry and logical close are the generic
[native-retirement contract](../language/async-io.md#native-retirement-capabilities)
([implementation](libuv-runtime.md#native-retirement-barriers)); this module
supplies only the callbacks. Regression tests must cover cancellation before the
first proxy entry, during child unwind, and native setup failure before claiming
the proxy, each retiring the OS worker before terminal status.

An abandoned handle is not retirement. When the last `ctrl` reference drops
with a token still owned, `thread_control_destroy_unreferenced` detaches it
(POSIX detach; Windows closes the handle). That is best-effort reclamation, never
join evidence, and reports no status.

## Group ownership and retry boundaries

`Group` tracks members in `active_threads: {Thread<|nil|>: boolean}`: `false`
means admitted but listener setup has not returned, `true` means the terminal
listener is installed, absent means retired. Each member has exactly one
memoized `Thread:task()` monitor and one terminal listener, and FIFO
admission/completion queues grant slots. The group never respawns or replaces
an admitted child; the same `Thread` and slot persist across setup failures.

- **Admission.** `Group:spawn_raw_entry` calls `spawn_raw` with the membership
  Map, which inserts the handle as `false` before `uv.create_native_thread` and
  rolls it back on pre-start failure. Such a failure raises from `Group:spawn*`,
  starts no worker and returns the slot. A spawn that finds the group full
  queues a waiter with a fresh token, then rechecks the group abort before it
  suspends, so a `Group:cancel` from a finalizer before the waiter was queued
  is not lost; one after it latches the waiter's wake
  ([explicit suspension](libuv-runtime.md#explicit-suspend-task-status-listeners-and-combinators)).
- **Observation.** `Group:wait()` makes one pass over the membership Map before
  suspending. `observe_thread` takes the memoized monitor and checks its status
  first: a finished monitor retires inline; otherwise it forwards a pending
  group abort, installs one terminal listener, and marks the member `true`.
- **Retirement.** `finish_thread` runs only after the proxy's native gate. It
  checks membership, deletes it, registers `defer self:release_slot()`, and only
  then projects `spawned:status()` with the monitor's error as fallback. Retiring
  before the fallible projection keeps an isolated listener error from
  stranding the slot.
- **Collected errors.** The child's own failure when present; otherwise the
  host monitor's error and traceback, never both. The public proxy's normal
  uncaught-Task diagnostic on `stderr` is intentional.
- **Shutdown.** Runtime shutdown cancels each member proxy as an ordinary Task;
  the cleanup forwards to the worker, and membership removal and slot release
  still wait for the OS join.
- **Retry boundaries.**
  - A live member whose OS join fails escapes `async.loop()` as the driver
    `OperationError`; Task, control, token, Runtime and slot survive, and a later
    `async.loop()` retries.
  - A child that finished before proxy construction makes the registrar return
    `0`, so synchronous retirement can fail before a Task exists.
    `Group:spawn*` propagates that error with the member still `false`; the next
    explicit `Group:wait()` retries setup once, without spinning or replacing a
    memoized proxy.
  - `Task:add_terminal_listener` can install its callback and then fail to
    allocate the remover. The member stays `false`; the next `Group:wait()`
    finishes inline for an already-terminal Task (terminal Tasks do not invoke
    new listeners) or installs another listener. Listeners check
    `active_threads[spawned] == nil`, so two partial registrations cannot retire
    a member twice or reinsert it.
