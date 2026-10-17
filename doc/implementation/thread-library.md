# Thread-library implementation

The user-facing contract is in the
[thread standard-library chapter](../language/standard-library-thread.md).
`titan.thread` is a folder ensemble under `titan/thread/`:

- `titan/thread/thread.titan`: canonical folder main, public types (`Error`,
  `ThreadStatus`), shared waiter queue operations (`waiter_enqueue`,
  `waiter_unlink`, `waiter_wake_one`, `waiter_wake_all`), native message
  conversion and discard wrappers (`value_to_thread_message`,
  `thread_message_to_value`, `thread_message_discard`) delegating to
  `transfer.encode_message` and `transfer.decode_message`, and native waiter
  suspension (`wait_on_native_waiter`).
- `titan/thread/channel.titan`: `Sender<|T|>`, `Receiver<|T|>`,
  `ReceiveResult<|T|>`, `channel`, endpoint cloning, and cross-state endpoint
  transfer hooks (`to_transfer_payload` / `from_transfer_payload`).
- `titan/thread/spawn.titan`: `Thread<|R|>`, `spawn` through `spawn_five`,
  detached OS worker bootstrap, cooperative cancellation, and `Thread:task()`.
- `titan/thread/group.titan`: `Group`, `group`, bounded concurrency queue, and
  `Group:wait()`.
- `titan/thread/native.h`: C struct definitions for `titan_thread_message`
  (aliasing `titan_async_message`), `titan_thread_waiter`,
  `titan_thread_waiter_queue`, `titan_thread_channel`, and
  `titan_thread_control`.

## Layering and cross-thread primitives

In accordance with the standard-library layering rules, `titan.thread` does not
import `<uv.h>` directly. Instead, `titan.uv` exports raw pointer-taking
`foreign function` wrappers for cross-thread synchronization and wakeups:

- `uv.mutex_t.create_native(): foreign *void`
- `uv.native_mutex_lock(handle: foreign *void)`
- `uv.native_mutex_unlock(handle: foreign *void)`
- `uv.native_mutex_destroy(handle: foreign *void)`
- `uv.async_send_native(handle: foreign *void): foreign int`

Waiter registration, ring-buffer operations, reference counting, and control
block transitions run inside `titan/thread/` under `uv.native_mutex_lock` and
`uv.native_mutex_unlock`, calling `uv.async_send_native` directly on borrowed
`uv_async_t` pointers without storing C function pointers in native structs.
All Lua heap allocations (such as string copies and record construction) happen
outside `uv.native_mutex_lock` critical sections so an allocation error cannot
`longjmp` while a native mutex is held.

Furthermore, `titan.lua` exposes `Lua:detach(): foreign *lua_State` so
`spawn_raw` can prepare an independent `lua_State` with its preload/native
provider snapshot on the parent thread and transfer ownership of the raw
`lua_State *` to the detached OS thread.

## Native message packets and nested custom transfer hooks

Every channel item, thread entry closure, thread return value, failure error,
and cancellation reason is converted into a `titan_thread_message` heap packet
(aliasing `titan_async_message` from `titan/async_receiver_native.h`) via
`transfer.encode_message` and `transfer.decode_message` before crossing the
mutex boundary:

- Scalar values (`nil`, `boolean`, `integer`, `float`, pointers, C functions)
  allocate a single `titan_thread_message` struct directly via `calloc` without
  allocating intermediate `TransferValue` unions on the Lua GC heap. Strings
  and root custom-hook payloads copy into a single `titan_async_message` heap
  allocation (`titan_async_copy_message`) on send and allocate a destination Lua
  string on receive.
- Structural records, unions, and Titan closures initialize a heap-backed
  `owned *titan_protobuf_buffer` outside the Lua GC with
  `sizeof(titan_async_message)` reserved at the front
  (`titan_protobuf_buf_init_heap`), serialize the Protocol Buffers wire payload
  directly into that expandable buffer (growing by amortized doubling), append
  the nominal/module names into the same buffer, and detach the single
  `titan_thread_message *` allocation (`titan_protobuf_buf_take_data`) directly
  into the channel ring buffer or thread control block without copying the wire
  payload or allocating intermediate Lua strings.
- On the receiving thread, `transfer.decode_message` decodes structural
  records, unions, and closures in place directly from the native buffer slice
  (`protobuf.deserialize_nominal_buffer` and
  `protobuf.deserialize_fields_buffer`) and consumes and frees the message
  packet via `defer ffi.free`.

To allow `Sender<|T|>` and `Receiver<|T|>` (and any user record with
`to_transfer_payload` / `from_transfer_payload`) to be embedded inside outer
records and unions sent over channels or captured by closures, `titan.protobuf`
supports nested custom transfer hooks (`depth > 1`) via shared
`protobuf.find_transfer_hooks`:

- During `protobuf` schema generation (`titan/protobuf/schema.titan`), any
  nested record (`depth > 1`) that declares zero-argument
  `to_transfer_payload(): string` and static
  `from_transfer_payload(payload: string): R` maps to `optional bytes`,
  bypassing public-field structural traversal.
- During encoding (`titan/protobuf/encoder.titan`), nested records with custom
  transfer hooks invoke `protobuf.encode_transfer_payload` under the shared
  active-record cycle guard and write the returned payload as a
  length-delimited wire field directly into `titan_protobuf_buffer`.
- During decoding (`titan/protobuf/decoder.titan`), nested records with custom
  transfer hooks slice the length-delimited wire field and reconstruct the
  record via `from_hook.callable(payload)`.

## Channel state machine and endpoint transfer

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

### Waiter suspension and $O(1)$ cancellation unlink

When `Sender:send` encounters a full buffer or `Receiver:receive` encounters an
empty buffer, `wait_on_native_waiter` initializes a per-wait `uv.async_t`
(`uv.async_t.new()`) on `async.current_loop()` and suspends the current Task
with `async.ResumeToken` and `async.suspend`. The waiter node is linked into the
channel's overflow or underflow FIFO queue under `ch.mutex`.

If a peer operation satisfies or closes the channel, `waiter_wake_one` unlinks
the waiter node, sets `waiter.signaled = 1`, and calls
`uv.async_send_native(waiter.async_handle)`. On normal wakeup, the waiter is
already unlinked and `finish_wait` simply closes the `uv.async_t` handle without
re-locking `ch.mutex`. If the suspended Task is cancelled before `async.suspend`
returns normally, `finish_wait` invokes `unregister_fn()` to unlink the waiter
from the doubly linked list in $O(1)$ time under `ch.mutex` (or pass the baton
to the next waiter if it was concurrently signaled) and closes the `uv.async_t`
handle.

### Endpoint transfer payload and rollback

`Sender:to_transfer_payload`, `Sender.from_transfer_payload`,
`Receiver:to_transfer_payload`, and `Receiver.from_transfer_payload` check that
the state-local `endpoint_transfer_depth` counter is positive so channel
endpoints can only be serialized and reconstructed inside `titan.thread`'s own
message paths (`value_to_thread_message`, `thread_message_to_value`, and
`thread_message_discard`), rejecting arbitrary `protobuf.serialize` or
`transfer.TransferValue.from_value` calls that could duplicate or drop reference
counts.

During `value_to_thread_message`, `Sender:to_transfer_payload` and
`Receiver:to_transfer_payload` increment `active_senders` or `active_receivers`
and record `self.native` in `pending_retained_senders` or
`pending_retained_receivers`. If `transfer.encode_message` raises partway
through a composite record, union, or closure, `value_to_thread_message` rolls
back all sender and receiver retains from that failed encode before re-raising.
If an already-encoded packet is discarded in a Titan state before delivery (for
example when `Sender:try_send` finds a full or closed channel, `Sender:send` is
cancelled while parked, or `Thread:cancel` loses a race),
`thread_message_discard` decodes composite packets under `catch` so any retained
endpoint references are adopted into GC-finalizable handles and released.

## Detached OS thread lifecycle and cancellation

`spawn_raw<|R|>(entry: function (): (R), initially_observed: boolean)`
serializes the zero-argument `entry` closure into `ctrl.entry_msg`, detaches a
fresh `lua_State` from `lua.new()`, sets `ctrl.refcount = 2` (one for the parent
`Thread<|R|>` handle and one for the worker thread), and launches
`thread_worker_main` via `uv.thread_t:create` followed by `os_thread:detach()`.
Fixed-arity helpers (`spawn_one` through `spawn_five` and `Group:spawn_one`
through `Group:spawn_three`) wrap the target function and arguments in a
zero-argument closure `function (): R return entry(...) end` so `transfer`
snapshots the function and its captured arguments uniformly.

Inside `thread_worker_main`:

1. `thread_worker_protected` calls `transfer.transfer_load_module(state,
   "titan.thread", 12)`, stores `ctrl` as a lightuserdata in
   `LUA_REGISTRYINDEX["_TITAN_THREAD_CTRL"]`, and invokes the zero-argument
   `child_thread_bootstrap` registered in
   `LUA_REGISTRYINDEX["_TITAN_THREAD_BOOTSTRAP"]`.
2. `child_thread_bootstrap` detaches `ctrl.entry_msg`, schedules the child's
   root `async.Task` (which decodes and frees `entry_msg` via
   `thread_message_to_value`), registers an unreferenced `uv.async_t`
   cancellation handle in `ctrl.child_cancel_handle`, and runs `async.loop()`.
3. When the root `Task` finishes, its `defer` clears `ctrl.child_cancel_handle`
   and closes the cancellation handle. On uncaught error or cancellation, it
   records the terminal status in `ctrl` and calls `async.request_exit(0)` so
   any remaining child handles close cleanly.
4. After `lua_pcallk` returns, `thread_worker_main` closes the child `lua_State`
   with `lua_close`, records a fallback `TITAN_THREAD_STATE_FAILED` status if
   `ctrl.status_kind` is still `TITAN_THREAD_STATE_RUNNING`, marks
   `ctrl.finished = 1`, wakes all queued `join` waiters via
   `uv.async_send_native`, and releases the worker's reference to `ctrl`.
5. In the parent state, `Thread:reconstruct_terminal_status` detaches
   `result_msg` and `error_traceback` (or `Thread:cancel`'s `cancel_reason_msg`
   in the child) under `ctrl.mutex` and performs all Lua decoding, string
   allocation, and `ffi.free` outside the mutex, caching the reconstructed
   `ThreadStatus<|R|>` on `self.cached_status`.
6. When `ctrl.refcount` reaches `0`, `thread_control_destroy_unreferenced`
   writes `ctrl.stderr_report` to `stderr` if `ctrl.status_kind ==
   TITAN_THREAD_STATE_FAILED` and `ctrl.observed == 0`.
