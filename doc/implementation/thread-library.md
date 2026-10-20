# Thread-library implementation

The user-facing contract is in the
[thread standard-library chapter](../language/standard-library-thread.md).
`titan.thread` is a folder ensemble under `titan/thread/`:

- `titan/thread/thread.titan`: canonical folder main, public types (`Error`,
  `ThreadStatus`), shared waiter queue operations (`waiter_enqueue`,
  `waiter_unlink`, `waiter_wake_one`, `waiter_wake_all`) that retain and release
  a native external-wake target per registration, native message
  conversion and C-only discard wrappers (`value_to_thread_message`,
  `thread_message_discard`) delegating to `transfer.encode_message` and
  `transfer.discard_message`, public C-ABI channel retain/release callbacks
  (`channel_retain_sender_native`, `channel_retain_receiver_native`,
  `channel_release_sender_native`, `channel_release_receiver_native`),
  recursive unlocked ring draining (`channel_drain_and_discard`), and the C-only
  producer-side channel helpers.
- `titan/thread/channel.titan`: `Sender<|T|>`, `Receiver<|T|>`,
  `ReceiveResult<|T|>`, `channel`, endpoint cloning, registered nominal
  resource capabilities (`register_channel_resources`, `sender_resource`,
  `receiver_resource`, `sender_from_resource`, `receiver_from_resource`), and
  packet-scoped endpoint transfer hooks (`to_transfer_payload` /
  `from_transfer_payload`).
- `titan/thread/spawn.titan`: `Thread<|R|>`, `spawn` through `spawn_five`,
  isolated OS worker bootstrap with a joinable native token, cooperative
  cancellation, OS-join-enforcing `Thread:join()`, the native-retirement
  callbacks (`thread_control_register_retirement_native`,
  `thread_control_unregister_retirement_native`,
  `thread_control_retire_native`), `thread_control_join_native`, and the
  `async.run_with_cleanup` proxy behind `Thread:task()`.
- `titan/thread/group.titan`: `Group`, `group`, the private
  `{Thread<|nil|>: boolean}` membership map, exactly one memoized public
  `Thread:task` monitor per member, FIFO admission/completion queues,
  native-terminal-gated slot release, and `Group:wait()`'s explicit setup retry.
- `titan/thread/native.h`: C struct definitions (including
  `../transfer_native.h`) for `titan_thread_message` (aliasing
  `titan_async_message`), `titan_thread_waiter` with its retained
  `wake_target`, automatic `titan_thread_channel_wait` context,
  `titan_thread_waiter_queue`, `titan_thread_channel`, and
  `titan_thread_control` with its joinable `os_thread` token, proxy target and
  separate `cancel_reason_kind`/`result_reason_kind` metadata.

## Layering and cross-thread primitives

In accordance with the standard-library layering rules, `titan.thread` does not
import `<uv.h>` directly. Instead, `titan.uv` exports raw pointer-taking
`foreign function` wrappers for cross-thread synchronization and wakeups:

- `uv.mutex_t.create_native(): foreign *void`
- `uv.native_mutex_lock(handle: foreign *void)`
- `uv.native_mutex_unlock(handle: foreign *void)`
- `uv.native_mutex_destroy(handle: foreign *void)`
- `uv.async_send_native(handle: foreign *void): foreign int`
- `uv.native_external_wake_retain(target: foreign *void)`
- `uv.native_external_wake_release(target: foreign *void)`
- `uv.native_external_wake_notify(target: foreign *void): foreign int`
- `uv.create_native_thread(entry, argument): (integer, foreign *void)`
- `uv.native_thread_join(token: foreign *void): foreign int`
- `uv.native_thread_detach(token: foreign *void): foreign int`

`uv.async_send_native` wakes the child's root-cancellation handle;
channel and join waiters use the external-wake entries. The heap thread token
returned by `uv.create_native_thread` is the worker's single joinable owner:
`ctrl.os_thread` holds it until a successful `uv.native_thread_join` consumes
it, and only `thread_control_destroy_unreferenced` falls back to detach.
Waiter registration, ring-buffer operations, reference counting, and control
block transitions run inside `titan/thread/` under `uv.native_mutex_lock` and
`uv.native_mutex_unlock`. All Lua heap allocations (such as string copies and
record construction) and packet disposals (`thread_message_discard`) happen
outside `uv.native_mutex_lock` critical sections so an allocation error cannot
`longjmp` while a native mutex is held and recursive endpoint releases cannot
re-enter the same lock.

Furthermore, `titan.lua` exposes `Lua:detach(): foreign *lua_State` so
`spawn_raw` can prepare an independent `lua_State` with its preload/native
provider snapshot on the parent thread and transfer ownership of the raw
`lua_State *` to the worker OS thread.

## Native message packets and nested custom transfer hooks

Every channel item, thread entry closure, thread return value, failure error,
and cancellation reason is converted into a `titan_thread_message` heap packet
(aliasing `titan_async_message` from `titan/transfer_native.h`) via
`transfer.encode_message` and transfer's consuming raw-slot `decode_message`,
with all semantic encoding/decoding outside the channel/control mutex:

- Scalar values (`nil`, `boolean`, `integer`, `float`, pointers, borrowed
  `*lua_State`, and bare C functions) are classified directly from their Lua
  tags (`scalar_message_kind`) before acquiring a resource scope.
  `scalar_value_to_message` fills a single heap packet directly through
  `new_scalar_message`, without staging a header, copying it through
  `transfer.copy_message`, or allocating intermediate `TransferValue` unions
  or `reflect.Value` wrappers. Binary strings use the same direct heap encoding;
  decode copies them in its scope-free string branch inside its native catch.
  Explicit nominal `TransferValue` policies and opaque custom-hook roots
  allocate their single heap packet directly through `new_nominal_message`
  (attaching the scope's pending units into the aligned tail for opaque roots).
- Root `Sender<|T|>` and `Receiver<|T|>` values match
  `protobuf.find_resource_codec` by canonical erased metatable identity in
  `encode_packet`, reserve `sizeof(titan_async_message) + 4 + #name + #module`
  plus the aligned one-entry attachment tail in one heap-backed
  `owned *titan_protobuf_buffer` before attaching the endpoint via
  `codec.encode(scope, candidate)`, write the four-byte little-endian slot index
  via `protobuf.write_resource_index`, and finalize the
  `TITAN_ASYNC_MESSAGE_RECORD_PAYLOAD` packet in place without a Lua index
  string or staged `copy_message`. Policy conversions (`TransferValue.from_value`
  and `TransferValue:to_value`, including closure-captured endpoints) likewise
  dispatch registered `ResourceCodec` records before reflective hooks.
- Structural records, unions, and Titan closures initialize a heap-backed
  `owned *titan_protobuf_buffer` outside the Lua GC through
  `init_packet_buffer`, which reserves the message header plus a bounded credit
  for mandatory nominal/module metadata before serialization. They serialize
  the Protocol Buffers wire payload directly into that expandable buffer via
  `protobuf.serialize_inspected_record_to_buffer` (passing `scope`),
  `protobuf.serialize_inspected_union_to_buffer` (passing `scope`), or
  `protobuf.serialize_fields_to_buffer_with_context` (passing `scope`, without
  hydrating closure function signatures or re-inspecting the structural root),
  append the nominal/module names into the same buffer, detach the single
  `titan_thread_message *` allocation (`titan_protobuf_buf_take_data`), and
  commit the encode scope's `titan_transfer_resource_table` into
  `message.resources`.
- On the receiving thread, transfer's packet decode scope reconstructs
  structural records, unions, closures, and root endpoints directly from the
  native buffer slice (`protobuf.deserialize_nominal_buffer_with_context`,
  `protobuf.deserialize_fields_buffer_with_context`, and `codec.decode` for
  registered `RECORD_PAYLOAD` capabilities). Each caller gives a real local
  `void *` its packet in the local's own declaration, installs an immediate
  native discard defer, and returns or binds `transfer.decode_message(raw)`
  **directly** on that local. The recovery-sensitive address-exposed scalar
  has one volatile home, so no stale spill can replace decode's clear.
  Decode consumes and clears the
  local on return and before any decoder error propagates with its original
  traceback; an error from decode's own entry preamble leaves the packet for
  the guard. No ordinary raw-slot wrapper or Lua-stack ledger intervenes; see
  [consuming raw-slot decode](transfer-library.md#consuming-raw-slot-decode).

Cancellation reasons do not use the erased
`async.CancellationReason<|value|>` schema directly, because protobuf cannot
encode its `complex` arm's erased `value` field. The transport instead keeps the
variant in native metadata and the payload in an ordinary owned packet:

- `titan_thread_control` carries separate `cancel_reason_kind` and
  `result_reason_kind` fields, each committed atomically with its own packet
  under `ctrl.mutex`, so a request and a result phase cannot retag each other
  during child self-cancel/host-request races.
- `cancellation_to_thread_message` encodes only `simple(text)` or
  `complex(payload)` with ordinary `transfer.encode_message`, giving a complex
  endpoint/custom-hook payload the same active packet scope as every other
  Thread payload. Nil, `false`, empty text and endpoint attachments therefore
  round-trip unchanged.
- Only an unencodable payload falls back to rendering the reason text under the
  `DEFAULT` kind; a second failure propagates without admission, leaving the
  approved native reasonless retirement path able to cancel the child. The
  `DEFAULT` decoder deliberately ignores its encoded payload.
- `thread_message_cancellation` rebuilds `simple`/`complex` from the committed
  kind; an unknown or `DEFAULT` kind becomes
  `CancellationReason.simple("cancelled")` and never reconstructs the rendered
  text.

The child's outcome uses its own `async.checkpoint()` after the body unwinds.
That makes the root Task's first sticky cancellation reason authoritative even
when a different host reason packet arrived during the self-cancel window. The
host Task's original reason/error remains traced on the host side.

To allow `Sender<|T|>` and `Receiver<|T|>` (and any user record with
`to_transfer_payload` / `from_transfer_payload`) to be embedded inside outer
records and unions sent over channels or captured by closures, `titan.thread`
registers `Sender` and `Receiver` with `transfer.register_resource` at module
initialization (`register_channel_resources`), while `titan.protobuf` also
supports nested custom transfer hooks (`depth > 1`) via shared
`protobuf.find_transfer_hooks`:

- During `protobuf` schema generation (`titan/protobuf/schema.titan`), any
  nested record (`depth > 1`) that declares zero-argument
  `to_transfer_payload(): string` and static
  `from_transfer_payload(payload: string): R` maps to `optional bytes`,
  bypassing public-field structural traversal.
- During encoding (`titan/protobuf/encoder.titan`), nested `Sender` and
  `Receiver` fields match `find_resource_codec_by_name`, verify canonical erased
  metatable identity (`record_identity`), attach directly through
  `codec.encode(self.context, candidate)` using the packet's carried
  `ResourceScope`, and write the four-byte little-endian slot index into
  `titan_protobuf_buffer` via `write_resource_index` without calling
  `reflect.inspect`, `encode.callable`, or allocating a four-byte Lua string.
  Other nested records with custom transfer hooks invoke
  `protobuf.encode_transfer_payload` under the shared active-record cycle guard
  and write the returned payload as a length-delimited wire field.
- During decoding (`titan/protobuf/decoder.titan`), nested `Sender` and
  `Receiver` fields match `find_resource_codec_by_name`, validate wire type `2`,
  and invoke `codec.decode(message.context, message.base + field.offset,
  field.length)` (`sender_from_resource` / `receiver_from_resource`) directly on
  the borrowed packet slice without allocating a four-byte Lua string, calling
  `decode.callable`, or re-inspecting the constructed wrapper. Other nested
  records with custom transfer hooks slice the length-delimited wire field and
  reconstruct the record via `decode.callable(payload)` within the enclosing
  packet's top decode `ResourceScope`.

## Channel state machine and endpoint transfer

`Receiver:incoming()` uses a boolean continuation independently of its payload:
each delivered packet returns `(true, decoded_message)`, and a closed, drained
channel returns `(nil, nil)`. Generic `for` tests the first result for nil, so
using the message itself as that result would terminate on a delivered nil and
leave later packets buffered. The independent scalar continuation preserves
nullable and `value` messages without allocating a per-message wrapper. Callers
use `for _, message? in receiver:incoming() do` when nil must remain visible.

`titan_thread_channel` owns:

- `mutex`: heap-allocated `uv_mutex_t` protecting all fields.
- `active_senders` and `active_receivers`: counts of open `Sender` and
  `Receiver` endpoints (plus in-flight transferred endpoints) across all states.
  When both `active_senders` and `active_receivers` reach `0`, the ring buffer,
  mutex, and struct are freed (`channel_destroy_unreferenced`).
- `ring`: circular array of `*titan_thread_message` with `capacity`, `head`,
  `tail`, and `count` (all `size_t`).
- `overflow_waiters` and `underflow_waiters`: intrusive doubly linked FIFO
  queues (`titan_thread_waiter_queue`) of `titan_thread_waiter` nodes.

### Waiter suspension, shared external wake, and $O(1)$ cancellation unlink

When `Sender:send` encounters a full buffer, `Receiver:receive` encounters an
empty buffer, or `Thread:join` observes `ctrl.finished == 0`, the caller first
attempts a lock-protected fast check (`channel_try_enqueue_native` or
`channel_try_dequeue_native` with `waiter = nil`). Only when the fast check
must wait does the slow path register a `titan_thread_waiter` node in the
channel's `overflow_waiters` / `underflow_waiters` or thread control block's
`join_waiters` doubly linked FIFO queue under `ch.mutex` or `ctrl.mutex`.

#### Shared external-wake suspension

Channel send/receive suspend through `async.wait_external_native`; ordinary
join and the proxy body's logical-finish wait use `async.wait_external`. Both
use the Runtime's single shared `uv.external_wake_t`, so no path allocates,
initializes, or closes a per-wait `uv.async_t`.
`titan_thread_waiter.wake_target` holds the retained native target for exactly
one registration interval.

Channel calls use one automatic `titan_thread_channel_wait` cell containing
channel/message pointers, an embedded waiter and registrar status. The fast
send/dequeue path creates no registrar closure or mutable capture box. A full
or empty path passes its traced endpoint as the native wait's semantic owner
and borrows the cell until `wait_external_native` returns. The stackful Task
frame keeps the cell/waiter storage valid across suspension; all cancellation
and unwind paths unlink synchronously before that frame can unwind. Native
producers only access the waiter under the channel mutex, not the endpoint or
other GC state. This is a call-scoped borrow, not state-close protection for
arbitrarily abandoned native users.

The C registrars `channel_register_send_wait` /
`channel_register_receive_wait` perform the same locked inline recheck as the
fast path after yield. Their `0`/`1` return distinguishes inline-ready from
linked; the cell's separate status preserves a closed result. Send registration
clears the cell's packet pointer in the same foreign interval as enqueue;
receive registration commits the dequeued packet into that guarded cell.
Therefore cancellation that wins delivery after inline commitment never
discards a published packet or leaks a dequeued one. `defer` guards the cell's
remaining packet without a closure/capture box. Titan code reaches the cell
only through a `foreign *titan_thread_channel_wait` local: a by-value automatic
aggregate written in a protected body and read by its `defer` receives a
[longjmp-safe spill](c-ffi-expressions.md#longjmp-safe-aggregate-spills), and
recovery would reload the last Titan-written bytes over the registrar's raw
packet commit. Send installs its `defer` before the fast path because it owns
the encoded packet from the start; receive installs it only on a waiting
iteration, so an immediate dequeue has no protected boundary. Normal notified
waits retry the fast check; they still reserve no slot or message.

The proxy **cleanup** join is a different path on the same bridge. It never
registers a `titan_thread_waiter` and never calls `async.wait_external`: the
cleanup keeps its `defer final_wait:close()` / `defer final_wait:wait_cleanup()`
pair, and `wait_cleanup` awaits the capability's prearmed native retirement
through the native branch of `ExternalWait:await`, which polls
`retirement_poll_native` and otherwise suspends on that shared bridge.
`thread_control_register_retirement_native` retains the target into
`ctrl.proxy_wake_target`, so the prearmed capability—not a join-waiter node—owns
the reference that keeps the proxy's wake target valid.

- Both ordinary external-wait wrappers prepare an `ExternalWait` whose reserved target does not
  reference the idle handle. The wait yields, and only then activates the target
  without allocating, immediately before invoking the domain registrar. Active
  waits reference the Runtime's one shared async handle until retirement, and a
  sole send, receive or join wait keeps its loop alive through its native
  producer. `Sender:try_send` and `Receiver:try_receive` remain nonblocking and
  never prepare a wait.
- `channel_try_enqueue_native`, `channel_try_dequeue_native` and
  `thread_control_register_join_waiter` perform the readiness check and waiter
  publication in one step under `ch.mutex` or `ctrl.mutex`. Fast inline
  readiness neither links a waiter nor retains a producer target, and it returns
  `0` (or `2` for a closed channel) without suspending.
- Waiter publication retains the target (`waiter_enqueue` calls
  `uv.native_external_wake_retain`) under the domain mutex. Native
  `waiter_wake_one` unlinks the node, sets `active = 0` and `signaled = 1`,
  detaches the retained target, notifies that exact target, and releases the
  producer reference, all without touching remote GC objects. The lock order
  stays domain mutex, then wake-core mutex; bounded destination identity batches
  schedule the existing ready queue, never enter a Task reentrantly, and rearm
  remaining pending work before sleep. Normal notification completion does not
  invoke the unregister callback.
- Cancellation unregisters through the same queue: an active node is unlinked
  and its retained target released; an already-signaled node passes the wakeup
  baton to the next waiter when buffer space/messages or a closed state can
  still make progress, and `signaled` is then cleared so a repeated detach cannot
  pass the baton twice. Stale or duplicate notifications recheck and suspend
  again. Retrying Tasks can lose readiness again and re-register, so FIFO
  selection is not FIFO completion. The child cancellation handle and coalescing
  `Receiver` handles remain separate native owners.

#### Channel wake and cancellation invariants

- A channel wakeup does not pre-reserve a buffer slot or message for the woken
  Task: on resume, the Task loops and re-attempts `channel_try_enqueue_native`
  or `channel_try_dequeue_native`.
- If a suspended channel Task is cancelled before normal completion, the
  unregister callback (`channel_unregister_overflow_waiter` or
  `channel_unregister_underflow_waiter`) acquires `ch.mutex`: if
  `waiter.active ~= 0`, it unlinks the waiter from the doubly linked list in
  $O(1)$ time (`waiter_unlink`); if `waiter.signaled ~= 0` (meaning a peer had
  already dequeued and signaled this waiter before cancellation ran) and the
  channel still has buffer space/messages or is closed, it passes the wakeup
  baton to the next waiter via `waiter_wake_one`.

### Endpoint transfer, C-ABI release chain, and last-`Receiver` pin

`Sender` and `Receiver` transfer ownership through `titan.transfer`'s
[packet-scoped resource table](transfer-library.md#scoped-resource-table-and-manual-resource-ownership)
under three core invariants:

- **Each unit is owned by exactly one of: a live finalized wrapper, or an
  unconsumed message entry.** When a worker thread creates a channel pair and
  returns it through `Thread:join()`, `thread_worker_main`'s `lua_close`
  finalizes both worker wrappers before the parent reconstructs the result; the
  unconsumed result packet's entries hold the units that keep the channel alive
  until parent adoption. Likewise, if the sole source `Sender` wrapper is
  collected while its encoded copy is still queued, the unconsumed packet entry
  prevents premature EOF.
- **Adoption moves a unit; discard releases it; close changes state only.**
- **Message bytes, wake targets, loop liveness, and OS-thread retirement are
  separate lifetimes.** Wrapper counting simplifies none of them.

The direct registered capability and public hook paths share the same native
resource table, four-byte little-endian slot index format
(`protobuf.write_resource_index_bytes`), and validation order:

- At `titan.thread` initialization, `register_channel_resources` calls
  `transfer.register_resource` for `Sender<|value|>` and `Receiver<|value|>`
  with module-local accessors (`sender_resource`, `receiver_resource`), C-ABI
  retain/release callbacks (`channel_retain_{sender,receiver}_native`,
  `channel_release_{sender,receiver}_native`), and finalizer-first constructors
  (`sender_from_resource`, `receiver_from_resource`). Private `.native` field
  access stays inside `titan/thread/channel.titan`, and `protobuf` never imports
  `transfer` or `thread`.
- On the direct route (root endpoints and nested endpoint fields in records,
  unions, and Arrays) and on the hook route (`Sender:to_transfer_payload()` /
  `Receiver:to_transfer_payload()`, used by `TransferValue` policies such as
  closure captures and by opaque user hooks), each encoded occurrence reserves
  table capacity in the active encode `ResourceScope` before calling
  `channel_retain_*_native`. The first four entries use the scope's inline native
  scratch cell; the fifth spills to the C heap. Each occurrence increments
  `active_senders` or `active_receivers` under `ch.mutex` and writes the four-byte
  little-endian packet-local slot index. Packet finalization commits the entries
  into the aligned tail of the single packet allocation. If encoding later
  fails, unwinding the encode scope releases every attached entry via
  `channel_release_*_native`, zeroes its native cell, and returns the frame to
  the bounded state-local pool. A child Coroutine or other Task
  does not inherit permission from an enclosing packet operation in another
  execution. The index is packet-local, not a global anti-replay token; an
  identical number may name another packet's slot.
- Both `sender_from_resource` / `receiver_from_resource` (calling
  `transfer.claim_registered_resource` with the packet's carried `ResourceScope`
  and borrowed byte slice) and `Sender.from_transfer_payload(payload)` /
  `Receiver.from_transfer_payload(payload)` (calling `transfer.claim_resource`
  with the four-byte string) first call `new_sender` or `new_receiver`—which
  allocate a fresh wrapper with `native = nil` and register `sender_finalize` or
  `receiver_finalize` with `gc.finalizable<|value|>`—and then immediately assign
  `self.native` from the claim with no fallible ordinary entry, allocation, or
  yield after the slot's `resource` is cleared to nil. Both finalizers are
  declared exactly `function (value): ()` and strictly project their argument to
  `Sender<|value|>` / `Receiver<|value|>` themselves, matching `finalizable`'s
  erased callback formal. The generic call therefore passes the module closure
  unchanged, and every wrapper construction (`thread.channel`, `clone`, both
  adoption routes) allocates only its record userdata: no per-construction
  callable-adjustment closure, and the shared endpoint metatable's `__gc` stays
  that one closure, so finalization runs without an adapter hop. Claim
  validation checks direction, four-byte width, bounds (`0..count - 1`, `~= 0xffffffff`),
  expected release callback (`Sender` vs `Receiver`), and a non-nil resource
  pointer in that order. The release callback remains after consumption so kind
  checks precede duplicate checks. If a composite decode fails on a subsequent
  field, the native decode-scope disposer releases only remaining non-nil slots
  while already-claimed wrappers stay owned by the destination collector.
- `channel_retain_sender_native`, `channel_retain_receiver_native`,
  `channel_release_sender_native`, `channel_release_receiver_native`,
  `channel_drain_and_discard`, and `channel_destroy_unreferenced` are
  Titan-written `foreign function` declarations compiled to plain C-ABI
  functions. They take no `lua_State` or module userdata, touch no Lua GC
  objects, load no modules, and remain callable from `transfer.discard_message`
  even after the originating `lua_State` has closed.
  Their code remains mapped under the existing
  [process-lifetime provider binding](foreign-functions.md#source-collaboration-and-binary-isolation).
  Only this retain/release/drain/discard chain is no-Lua; worker bootstrap and
  `transfer_load_module` explicitly require a live, exclusively owned Lua state.
- **Last-`Receiver` lifetime pin and recursive unlocked drain**: When
  `channel_release_receiver_native` observes `active_receivers > 1`, it simply
  decrements `active_receivers` under `ch.mutex`. When `active_receivers == 1`,
  it keeps that last reference alive (`active_receivers` remains `1`), sets
  `ch.closed = 2`, wakes all overflow and underflow waiters, and unlocks
  `ch.mutex` before calling `channel_drain_and_discard(ch)`.
  `channel_drain_and_discard` detaches one `titan_thread_message *` at a time
  under `ch.mutex` and calls `thread_message_discard(msg)`
  (`transfer.discard_message`) **outside** `ch.mutex`. Because `active_receivers`
  remains `1` throughout the drain, a discarded message that releases a `Sender`
  on the same channel (or recursively drains another channel) cannot drop both
  counts to zero and free `ch` while its ring buffer is still being drained.
  Once `channel_drain_and_discard` returns, `channel_release_receiver_native`
  relocks `ch.mutex`, decrements `active_receivers` to `0`, and calls
  `channel_destroy_unreferenced(ch)` outside the lock if `active_senders == 0`.
- **Native reference cycles require explicit drain**: Packet attachments
  contribute to the same endpoint counts as wrappers. A ring containing its own
  `Receiver`, or channels retaining one another's receivers through queued
  packets, can keep `active_receivers` nonzero after all Lua wrappers disappear.
  Lua GC cannot collect this native graph, and the last-receiver transition is
  never reached. An application must retain a receiver and explicitly close it
  to drain/break the cycle; sender-side close preserves the queued attachments.
- Every losing or aborted packet path—full or closed `Sender:try_send`, closed
  or cancelled `Sender:send`, `dequeue_or_wait`'s `slow_msg` guard across waiter
  cleanup, `Receiver:close()`, last-`Receiver` finalization, `Thread:cancel`
  losing a race, failed `spawn_raw`, child bootstrap/exit cleanup, and abandoned
  `Thread` handles—disposes its single packet owner once outside locks via
  `thread_message_discard` (`transfer.discard_message`).

## Isolated OS thread lifecycle and cancellation

Worker diagnostics use direct native writes, including after a Lua state has
closed. Each write is bounded to 64 KiB and uses a private count typedef matching
the Windows CRT's `unsigned int` or POSIX `size_t`; offsets remain `size_t` so
partial writes and interruptions preserve the complete report.

`spawn_raw<|R|>(entry: function (): (R), initially_observed: boolean,
admission: {Thread<|R|>: boolean}?)` serializes the zero-argument `entry`
closure into `ctrl.entry_msg`, detaches a fresh `lua_State` from `lua.new()`,
sets `ctrl.refcount = 2` (one for the parent `Thread<|R|>` handle and one for
the worker thread), creates the worker through `uv.create_native_thread`, and
stores the uniquely owned joinable token in `ctrl.os_thread`. The spawner never
detaches that token: it stays owned until a successful `uv.native_thread_join`
consumes it, and only an abandoned control block detaches it. For a `Group`
member, `admission` is the group's membership map: `spawn_raw` publishes
`admission[handle] = false` only after the handle owns `ctrl`, and the `defer`
registered immediately after control-block creation removes that entry again, so
a pre-start preparation or native-create failure leaves no membership behind.
On any failure that `defer` also clears the handle's native pointer, closes a
detached `child_state`, and calls `thread_control_release_native(ctrl)` to
discard `ctrl.entry_msg` and destroy `ctrl`. Fixed-arity helpers (`spawn_one`
through `spawn_five` and `Group:spawn_one` through `Group:spawn_three`) wrap the
target function and arguments in a zero-argument closure
`function (): R return entry(...) end` so `transfer` snapshots the function and
its captured arguments uniformly.

Inside `thread_worker_main`:

1. `thread_worker_protected` calls `transfer.transfer_load_module(state,
   "titan.thread", 12 as foreign unsigned long long)`, stores `ctrl` as a
   lightuserdata in `LUA_REGISTRYINDEX["_TITAN_THREAD_CTRL"]`, and invokes the
   zero-argument `child_thread_bootstrap` registered in
   `LUA_REGISTRYINDEX["_TITAN_THREAD_BOOTSTRAP"]`.
2. `child_thread_bootstrap` detaches `ctrl.entry_msg` under a `defer` guard that
   discards any unconsumed `entry_msg` and `leftover_cancel` packet via
   `thread_message_discard`, schedules the child's root `async.Task` (which
   moves `entry_msg` into a local guarded `void *` slot and directly calls
   `transfer.decode_message` on it), registers an
   unreferenced `uv.async_t` cancellation handle in `ctrl.child_cancel_handle`,
   and runs `async.loop()`.
3. When the root `Task` finishes, its `defer` clears `ctrl.child_cancel_handle`
   and closes the cancellation handle. On uncaught error or cancellation, it
   records the terminal status in `ctrl` and calls `async.request_exit(0)` so
   any remaining child handles close cleanly. If `ctrl.abandoned` is already set
   because the parent finalized its `Thread` handle while the worker was still
   running, `thread_control_record_succeeded_native`,
   `thread_control_record_cancelled_native`, and
   `thread_control_record_failed_native` discard `result_msg` immediately
   outside `ctrl.mutex` via `thread_message_discard` instead of storing it on
   `ctrl`.
   After `async.loop()` returns, `child_thread_bootstrap` checks whether
   `ctrl.status_kind` is still `TITAN_THREAD_STATE_RUNNING`. Ordinary `async.run`
   can skip the root body on pre-start cancellation, and a checked root entry
   can fail before its outcome-recording catch is installed, so in that case it
   consults public `root_task:status()` and records the exact accepted
   cancellation reason or the original checked-entry failure. A child cancelled
   before its first body statement is therefore reported as
   `cancelled(reason)`, not as a generic failed thread.
4. After `lua_pcallk` returns, `thread_worker_main` clears
   `ctrl.child_cancel_handle`, closes the child `lua_State` with `lua_close`,
   records a fallback `TITAN_THREAD_STATE_FAILED` status via
   `record_bootstrap_failure_native` if `ctrl.status_kind` is still
   `TITAN_THREAD_STATE_RUNNING`, calls `thread_control_complete_native(ctrl)`
   (which detaches and discards any remaining `entry_msg` or `cancel_reason_msg`
   outside `ctrl.mutex`, marks `ctrl.finished = 1`, detaches and notifies the
   proxy wake target after that mark, and wakes all queued `join` waiters), and
   releases the worker's reference to `ctrl`.
   This `ctrl.finished` transition is logical native completion, not proof of
   OS-thread exit: the foreign worker callback and OS/TLS tail may still run.
   `ctrl.os_thread` still owns the joinable token at this point, so only a
   successful actual OS join retires the worker; a cached logical status never
   substitutes for it.
5. In the parent state, `Thread:reconstruct_terminal_status` detaches
   `result_msg` and `error_traceback` (or `Thread:cancel`'s `cancel_reason_msg`
   in the child) under `ctrl.mutex` and performs all Lua decoding
   (direct `transfer.decode_message(raw)` on the local `raw: void *` slot
   guarded by `defer thread_message_discard(raw)`, inside an `if raw ~= nil`
   arm whose own `catch` maps a decode failure), string allocation, and
   `defer ffi.free(trace_ptr)` outside the mutex. The reconstructed
   `ThreadStatus<|R|>` is cached on `self.cached_status`.
   If the parent instead drops and
   finalizes `Thread<|R|>` without reconstructing its status,
   `thread_control_abandon_and_release` sets `ctrl.abandoned = 1`, detaches any
   already-recorded `result_msg` (and `entry_msg` / `cancel_reason_msg` if
   `ctrl.finished ~= 0`), and discards them outside the mutex via
   `thread_message_discard` before releasing the parent's `ctrl` reference.
6. When `ctrl.refcount` reaches `0`, `thread_control_destroy_unreferenced`
   discards any remaining `entry_msg`, `cancel_reason_msg` and `result_msg`,
   releases any retained `proxy_wake_target`, detaches a still-owned joinable
   `os_thread` token, writes `ctrl.stderr_report` to `stderr` if
   `ctrl.status_kind == TITAN_THREAD_STATE_FAILED` and `ctrl.observed == 0`,
   frees the traceback/report buffers and mutex, and frees `ctrl`.
7. `Thread:task()` marks `ctrl.observed = 1` through the retirement registrar,
   prepares the native capability, and memoizes the resulting proxy. The
   constructor arms the barrier through
   `thread_control_register_retirement_native` before the proxy is exposed, so
   terminal publication is gated even when root or cleanup entry fails. The
   cleanup callback forwards the first reason—defaulting to
   `simple("cancelled")` when the body failed without one—then waits on the
   same prearmed barrier; a failed constructor admission closes only the
   capability and the original `Thread` keeps its worker and unjoined token.
   That worker is not necessarily still running: when the registrar reports
   ready `0`, the constructor performs the retirement poll before exposure, so
   a pending or negative result there also fails admission and leaves a
   finished worker with an unjoined token. Only the bound Task's cleanup and
   the private external registrar may use the reserved final suspension epoch.
   Required regressions cover cancellation before first proxy entry, during
   child unwind, and native setup failure before claiming the proxy; they always
   retire the OS worker before terminal status/listeners.

### Join, proxy retirement, and the native terminal barrier

`Thread:status()` stays a nonblocking logical-finish observer: it reads
`ctrl.finished` under `ctrl.mutex` and never joins. `thread_worker_main` sets
`finished = 1` inside `thread_control_complete_native` after closing the child
Lua state, so the flag is a logical native receipt, not OS-thread retirement,
and a terminal snapshot can precede the worker's final OS/TLS tail.

`Thread:join()` requires a running Task, checkpoints, waits for that receipt
through `async.wait_external`, and then calls
`thread_control_join_native(ctrl, 0)`. That helper inspects
`finished`/`os_joined`/`os_thread` under `ctrl.mutex`, releases the mutex, and
performs the blocking `uv.native_thread_join` on the retained joinable token:

- A not-yet-finished worker returns `1` (pending) without joining; that is what
  makes the same helper usable as the retirement poll. Public `Thread:join()`
  calls it only after the receipt, so it never blocks on unfinished work.
- Success consumes the token and latches `os_joined`; later joins return the
  cached outcome without joining again.
- A control that never held a joinable token (`ctrl.os_thread == nil`) returns
  `-1`; another nonzero native status is preserved, and `Thread:join()` raises
  `async.OperationError` with operation `"thread.join"` rather than publishing a
  status. The token survives that failure, so a later `join()` can retry.

Join and detach observers are serialized by the owning cooperative Runtime, so a
duplicate joining flag is unnecessary; the native join itself does not yield.
Cross-state concurrent joins of one handle are not supported. Logical finish is
published before the worker's foreign callback returns and before its OS/TLS
tail runs, so a join that starts at that point blocks until the OS thread
actually exits; this chapter promises no bound on that remaining tail.

`Thread:task()` builds the proxy from the generic barrier:

```
local final_wait = async.prepare_native_retirement(
  self, ctrl as foreign *void,
  thread_control_register_retirement_native,
  thread_control_unregister_retirement_native,
  thread_control_retire_native)
```

and passes `final_wait` as `run_with_cleanup(body, cleanup, final_wait)`'s third
argument. The `Thread` handle is the traced `owner`, so it stays alive through
native callback return and committed readiness; that GC root is not a
cross-state-close native pin, so the worker reference separately keeps the
control block and its native target slot valid. The three callbacks are
source-private `local foreign function` entries with direct C signatures — they
are not public API and are absent from provider metadata:

- `thread_control_register_retirement_native(context, target)` marks the outcome
  observed and returns `0` when `finished` is already set, `1` after retaining
  the proxy wake target under `ctrl.mutex`, and `-1` for nil arguments or a
  second monitor target. Result `0` retires inline before the proxy is exposed:
  the constructor performs the actual OS join and requires it to succeed.
- `thread_control_complete_native` detaches and notifies the proxy target after
  `finished = 1`, then releases the producer reference outside the mutex, so
  retirement after notification is join success or a preserved negative status,
  never pending.
- `thread_control_unregister_retirement_native(context)` is constructor rollback
  only: it clears the target under `ctrl.mutex` and releases it outside.
- `thread_control_retire_native(context)` is
  `thread_control_join_native(ctrl, 1)`. Only the unfinished predicate returns
  `1`; that path may request a reasonless child cancellation, and only when
  `ctrl.cancel_requested == 0` and
  `ctrl.status_kind == TITAN_THREAD_STATE_RUNNING`, matching the ordinary
  cancellation admission rule for a live root. The helper takes `ctrl.mutex`
  only to inspect and commit state and releases it before the blocking join, so
  no mutex is held across native retirement.

The proxy body awaits **logical finish only** through `wait_until_finished` and
projects the child's success, failure or cancellation. It deliberately does not
call normal `Thread:join`: an ordinary body join failure followed by cleanup
would retry the join inside the same driver invocation. Only the prearmed native
barrier owns the proxy's OS-join attempts.

The cleanup callback registers `defer final_wait:close()` and then
`defer final_wait:wait_cleanup()`, forwards its `reason` argument with
`self:cancel(reason)` while `finished` is still false, and lets the LIFO defers
run the shield wait and the view close afterwards. That argument is the Task's
first cancellation reason, or nil when the proxy body failed without one;
`Thread:cancel(nil)` then selects the default `simple("cancelled")` for the
child request without changing the host's preserved error. Terminal status,
terminal listeners and the proxy result are gated by the generic driver on
native retirement, so a cancelled proxy cannot publish before the child's own
cleanup and the OS join complete. Cancellation admission at that exact cleanup
wait, the preserved host/child reasons, negative-status retry and logical-close
rules are the generic
[native-retirement contract](../language/async-io.md#native-retirement-capabilities);
this module supplies only the Thread callbacks.

An abandoned handle is not retirement. Whenever the final `ctrl` reference drops
with a token still owned—observed or not—`thread_control_destroy_unreferenced`
detaches it (POSIX self-detach; Windows closes the real handle). That is
best-effort reclamation for an unowned handle, never proxy or join evidence, and
no status or join outcome is reported for it. The separate stderr diagnostic
still applies at that point: `ctrl.status_kind == TITAN_THREAD_STATE_FAILED`
with `ctrl.observed == 0` writes the formatted error and traceback before the
control block is freed.

### Group ownership and retry boundaries

`Group` replaces its former private active Array and extra observer Task with a
`{Thread<|nil|>: boolean}` membership map plus exactly one memoized public
`Thread:task()` per member and one terminal listener: `false` means admitted but
observer/listener setup did not return, `true` means the listener was installed,
and an absent entry means retired. FIFO admission/completion queues and their
grants are unchanged. The group never respawns or replaces an admitted child;
the same Thread and slot persist across setup failures.

- `Group:spawn_raw_entry` performs native admission before the OS thread exists:
  the private `spawn_raw` accepts the group's existing admission map, inserts the
  finalized handle as `false` **before** `uv.create_native_thread`, and rolls
  that entry back if pre-start preparation or native creation fails. That
  pre-start failure raises from `Group:spawn*`, starts no worker and returns the
  reserved slot. A proxy/listener setup failure after the worker exists retains
  the same admitted child and slot for the explicit `Group:wait()` retry; the
  member is never respawned. `Group:wait()` performs one observation pass over
  the membership map before suspending. `observe_thread` takes the memoized
  `monitor = spawned:task()` and checks `monitor:status()` first: a finished
  monitor retires the member inline. Otherwise it forwards a group abort if one
  is pending, installs one terminal listener, and marks the member `true`.
- On Runtime shutdown, each memoized member proxy is cancelled as an ordinary
  Task. Its cleanup forwards that cancellation to the worker, and terminal
  publication—therefore membership removal and slot release—still waits for the
  actual OS join.
- `finish_thread` runs only after the proxy's successful native gate. It checks
  membership, **deletes it**, registers `defer release_slot()`, and only then
  projects `spawned:status()` and falls back to the monitor's terminal error.
  Retiring before fallible projection is what keeps an isolated listener error
  from stranding admission or completion accounting; async isolates listener
  errors, and the deferred release runs regardless.
- The collected `Error` is the child's own failure when present; when the child
  did not fail but the host monitor failed during ordinary entry/cleanup, the
  monitor's error and traceback are collected instead, with no duplicate record.
  A failing member's standard public proxy still emits its normal uncaught-Task
  diagnostic on `stderr`; that diagnostic is intentional and is not suppressed.
- A linked live child whose later OS join fails escapes `async.loop()` as the
  unchanged driver `OperationError`; the same Task/control/token/Runtime and
  occupied slot survive, and an explicit later `async.loop()` retries it.
- A child that already finished before proxy construction makes the registrar
  return ready `0`, so synchronous native retirement can fail before any Task is
  exposed. `Group:spawn*` propagates that original constructor error while the
  `Thread` and its occupied slot stay `false`/admitted. An explicit later
  `Group:wait()` makes one observation pass and retries setup once; it does not
  spin or replace a successfully memoized proxy.
- `Task:add_terminal_listener` may install its callback and then fail allocating
  the returned remover. The `false` member and memoized Task remain owned; the
  next explicit `Group:wait()` checks that Task first and finishes inline when
  it is already terminal (the public API does not invoke new listeners on a
  terminal Task), otherwise it installs another listener. Callbacks guard with
  `active_threads[spawned] == nil`, so an earlier partially admitted listener
  and a later one cannot retire the same member twice or reinsert a retired
  member.
