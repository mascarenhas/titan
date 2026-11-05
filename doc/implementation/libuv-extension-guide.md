# Extending the public libuv binding and async adapters

The layers have separate ownership. `titan.uv` (`titan/uv/`) exposes native
operations through public Titan owners and callbacks. `titan.async` turns
callback completion into Task continuation through generic waits. Timer,
filesystem, network, process, and database modules own their domain policies and
acquired resources. Read the [public UV reference](../language/standard-library-uv.md)
for API contracts and the [async runtime chapter](libuv-runtime.md) for
scheduling and shutdown.

A library author adds an adapter with ordinary compiled imports of `uv` and
`async`. No `uv.titan` source import, scheduler variant, private Task field, or
compiler change is needed. Extend the UV implementation only when the native
operation itself lacks a suitable public binding.

## Start from the pinned native contract

Titan always builds bundled libuv 1.53.0 (`LIBUV_VERSION` in the `Makefile`)
with `vendor/libuv/libuv-1.53.0-spawn-close.patch`, which leaves a failed Unix
spawn's handle-queue removal to `uv_close`
([vendor notes](../../vendor/libuv/README.md)). A system libuv or its version
number is not a substitute. Check the pinned header, upstream documentation,
and the supported-platform implementations for the exact lifecycle. Wrappers
forward native results; for example `wtf8_length_as_utf16` returns libuv's
`EINVAL` for malformed WTF-8.

For every proposed operation, determine:

- whether it is synchronous, an accepted one-shot request, or persistent;
- whether callbacks can be inline, repeated, cancelled, or omitted on rejection;
- which inputs are copied and which stay borrowed, and for how long;
- which result storage must be copied before native cleanup;
- whether rejection leaves initialized state or separately acquired resources;
- the native result/status channels, units, ranges, nullable arguments, and
  platform restrictions; and
- whether it is safe on the Lua thread or is a C-only worker/thread entry.

Update the specific disposition in the
[native coverage map](../language/uv/coverage.md) rather than only a wrapper
count. Keep its function, nonfunction, field, callback, constant, and macro
inventories consistent with the public declarations; intentional omissions need
individual ownership explanations.

## Public native owners

A concrete owner holds its final native storage as private fields plus the
Titan references its native lifetime needs. Construct it before calling native
init: moving or copying initialized libuv state is invalid. Public `handle_t`,
`stream_t`, and `req_t` values are typed views that retain the concrete owner,
not second native objects. Keep native layouts and `uv.h` types out of public
signatures; use public records, copied values, and portable C-only function
types where a worker boundary requires them.

UV roots initialized handles and accepted requests in their owning `loop_t`
(`loop.handles` and `loop.requests`). These roots retain callback closures and
borrowed input owners independently of the caller's suspended stack. Native
`.data` is reserved for callback owner recovery. Public data is a separate
traced `value`: the concrete `fs_t`, `work_t`, `getaddrinfo_t`,
`connect_t`, `write_t`, and `shutdown_t` `get_data`/`set_data` methods read or
assign the owner's existing `userdata` field, sharing its tracing and write
barrier with the generic `req_t` methods. Clearing public data never retires
pending native work.

On terminal completion, the bridge retires the old registration before calling
user code while keeping the old owner, callback, and borrowed graph rooted for
the whole callback frame. This permits callback-time reuse without letting the
new operation overwrite storage the old native invocation still needs. Close
completion likewise retires the old handle lifetime before a supported
reinitialization.

`timer_close` stores a typed `timer_cb` (`typed_close_callback`) separately from
the generic close callback; the terminal handler `timer_closed` snapshots and
clears both before dispatch, so a named exact `timer_cb` needs neither a
forwarding closure nor a union view.

`write_string` (`titan/uv/stream_ops.titan`) stores one `uv_buf_t` in the
`write_t` (`string_buffer`) and retains the immutable string in the traced
`string_data` field. It shares the allocation-free `buf_check_length` check with
`buf_init` before acceptance; an adapter may call that check earlier when its
contract validates inputs before async admission. The foreign write callback
pushes the old string, vector owner, and descriptor roots onto its Lua stack
before calling the protected Titan handler, and the handler clears the old
string field before user code runs. Callback-time request reuse therefore cannot
erase the old native frame's byte root, even when user code raises after
submitting a successor. Immediate native rejection clears the attempted string
registration.

Init and rejection rules belong to each native API. A failed initializer usually
establishes no lifetime, but partial poll initialization can leave a closeable
owner. Native spawn always establishes process-handle close ownership, even when
it returns a negative status. Filesystem rejection can leave request memory that
needs cleanup. Check explicit owner state where the public contract provides it;
never infer all ownership from a negative result.

## Foreign callback boundary

The UV source ensemble owns the actual libuv callbacks. Restricted foreign
functions recover the final nominal owner, its owning main Lua state, and the
exact callable entry through the typed FFI bridges (`titan/uv/callback.h`
`titan_uv_push_owner`, `titan_record_field`). Owner recovery uses
compiler-owned nominal field information; never hard-code uservalue indices.
The callback frame pins values that user code can unroot or replace,
saves and restores the Lua stack top, and calls an ordinary Titan handler whose
`catch` contains every fallible operation before native return.

The loop boundary keeps the first error and traceback, counts later callback
failures (`failure_count`), calls `uv_stop`, and rethrows only after the native
call returns, so no Lua exception unwinds through libuv. `uv.run` owns the
ordinary asynchronous boundary; synchronous `walk` and Windows inline TTY
read/mode callbacks have their own corresponding boundaries. Native alloc
callbacks must return the required buffer shape and preserve any failure for
their paired read/receive handling; they cannot throw through C.

Only the owning main Lua thread drives callbacks. C-only worker, thread, and
once entries never inspect host Titan owners, enter the hosting Lua/Titan state,
or use its wrappers from a foreign thread; see the
[foreign-worker boundary](libuv-runtime.md#foreign-workers). Raw pointers and
code stay valid for the whole native interval, and an explicit
`argument_owner` retains the associated GC graph where permitted. A checked
`thread_t` with a retained `argument_owner` cannot detach (`thread_t:detach`
returns `EBUSY`), because detach cannot determine the graph's final use.

## Synchronization entries and heap thread tokens

`titan/uv/sync.titan` publishes 20 direct C-ABI synchronization entries
(`native_mutex_*`, `native_rwlock_*`, `native_sem_*`, `native_cond_*`,
`native_barrier_wait`, `native_key_get`/`set`, `native_once`) plus the heap-only
`native_mutex_destroy`; their exact signatures are in the
[entry map](../language/uv/supplemental.md#direct-synchronization-entry-map).
Ordinary compiled clients call or store them without a getter or `uv.h` import;
only UV owns libuv FFI.

The [synchronization ownership rules](../language/uv/types.md#synchronization-and-native-carrier-ownership)
distinguish three lifetimes:

- GC-backed mutex, rwlock, semaphore, condition, barrier, and TLS owners use a
  checked `SYNC_FRESH -> SYNC_LIVE -> SYNC_RETIRED` state, explicit
  initialization, and explicit destruction after every native user is
  quiescent. A failed initialization leaves fresh storage; retirement is
  terminal. Borrowed pointers do not root them, and no GC finalizer destroys
  their primitives.
- `mutex_t.create_native()` allocates and initializes independent process-heap
  storage. Only that result may be passed to `native_mutex_destroy`, which
  destroys and frees it after quiescence (NULL is a no-op). Never pass
  `:borrow()` storage to it.
- `once_t.new()` initializes its guard in final stable storage with
  `UV_ONCE_INIT` and has no init, reset, or destroy; root it through every
  participating native call. `key_t` stores a per-OS-thread borrowed pointer,
  not Task-local state, pointee ownership, or a GC root.

Raw entries bypass the checked owner guards and cannot diagnose dangling or
wrong-kind pointers. Lock and wait operations block the OS thread: never suspend
a Task while holding a blocking `uv` lock, or wait on the loop thread for a
sibling Task to release one. Cooperative coordination uses
[same-state channels](../language/async-io.md#bounded-channels) or
[cross-thread channels](../language/standard-library-thread.md#cross-thread-channels).

The [heap-thread-token API](../language/uv/supplemental.md#create_native_thread)
in `titan/uv/threading.titan` is separate. `create_native_thread(entry,
argument)` allocates token storage and returns `(0, token)` after native
acceptance; a NULL entry, allocation failure, or native creation failure returns
`(status, nil)` and frees any unpublished token. The worker may start before the
constructor returns. This route never retains a GC `argument_owner`: code and the
complete native argument graph stay manually owned through worker completion.
C-only `native_thread_join(token)` and `native_thread_detach(token)` free the
token only on `0`; any nonzero result preserves it, and NULL returns
`UV_EINVAL`. Join blocks the calling OS thread, so hold no worker-needed mutex
and require no progress from the blocked loop. Detach does not join, free
arguments, or prove quiescence. Serialize token retirement, never raw-free or
reuse a token after success, and never mix it with checked `thread_t` storage.

## External wake bridge

`titan/uv/external_wake.titan` and `titan/uv/external-wake-native.h` implement
the destination-loop wake bridge that `async.ExternalWait` uses
([async side](libuv-runtime.md#external-wake-bridge)). The reference-count
invariants are summarized in the ledger comment at the top of
`external_wake.titan`.

- **Owner and core.** `external_wake_t.new()` registers the GC fallback
  finalizer before any native acquisition. `external_wake_init` allocates a
  reference-counted heap `titan_uv_external_wake_core` whose first member is its
  `uv_mutex_t`, initializes an internal `async_t`, and immediately `uv_unref`s
  it. Neither target nor core contains a Lua/Titan GC value; keep the bridge and
  destination semantic state on traced loop-thread owners.
- **Reserve.** `:reserve(identity)` (`external_wake_reserve_native`) produces a
  `PREPARED` target holding one registration reference. It pops a
  reference-zero target from the core's free list (at most
  `TITAN_UV_WAKE_TARGET_CACHE_LIMIT`, 64, per core) or allocates outside the
  core mutex, then relocks and rechecks `core.handle`, returning `UV_EINVAL` for
  a closing bridge. It increments `core.registrations` but not `active_waits`, so
  a prepared target never keeps the loop alive. The returned pointer is
  borrowed from the destination's registration until exact unregister or
  detach.
- **Activate.** `:activate(target)` changes `PREPARED -> ARMED` without
  allocating, increments `active_waits`, and references the shared handle on the
  first active wait. Activate only when the wait is admitted and before
  publishing the retained native waiter.
- **Producer references.** Before publishing a target in a native domain
  waiter, take a separate producer reference with `native_external_wake_retain`;
  every such reference pairs with one `native_external_wake_release`. Lock order
  is always domain mutex, then wake-core mutex. Release core locks before
  consulting destination GC state or calling a domain unregister callback, and
  never call Titan/Lua code, allocate, construct errors, or suspend a Task under
  a domain lock.
- **Notify.** `native_external_wake_notify` links an `ARMED` target once
  (`PENDING`) and calls `uv_async_send` while holding the core mutex, which
  serializes the borrowed handle against close and detach. A `PENDING` target
  repeats the send without enqueueing; `DELIVERED` returns zero without
  sending. NULL, `PREPARED`, `RETIRED`, or detached targets return `UV_EINVAL`.
  The pending queue, not the callback count, records work, and a send failure
  does not retract publication. Notify and drain never change reference counts:
  `PENDING` implies registered, so the queue borrows the registration
  reference.
- **Query.** `native_external_wake_is_notified(target)` reads the phase under
  the core mutex and returns `1` for `PENDING` or `DELIVERED`, otherwise `0`
  (including NULL). The latch persists until exact unregister or detach. The
  caller must hold a registration borrow or producer reference for the whole
  call; the query takes no reference.
- **Drain.** On the destination loop, `:drain(output, capacity)` copies up to
  `capacity` identities into caller-owned native storage, marks them
  `DELIVERED`, and resends if entries remain. Process the returned count even if
  that resend fails. At most one pending node exists per target, and draining
  does not end the wait or drop loop liveness.
- **Unregister.** Clear the destination identity map and target borrow first.
  `:unregister(target)` unlinks the target from the registered list and any
  pending node in O(1), marks it `RETIRED`, drops `active_waits` (unreferencing
  the handle at zero) and `registrations`, and consumes the registration
  reference. A target whose references reach zero removes its core pin and is
  cached or freed. `native_external_wake_unregister(target)` is the same
  operation through the target's core; despite its C ABI it is
  destination-loop-thread-only because it may `uv_unref`. Call exactly one
  unregister form per registration and never inspect a consumed borrow
  afterward, since it may alias a later reservation on the same core.
  Unregister never releases a producer reference: a retained target stays out of
  the cache until its final release and receives `UV_EINVAL` on later notify.
- **Close and detach.** Normal `:close()` requires zero registrations, including
  `PREPARED` targets (`UV_EBUSY` otherwise), clears `core.handle` under the core
  mutex, and closes the handle; close completion detaches the owner's core
  reference. Drive that close before releasing loop ownership. The GC fallback
  `external_wake_detach` clears the handle borrow and pending queue, retires
  every remaining registration, and drops the owner reference without calling
  Lua or driving the loop. When `core.references` reaches zero,
  `external_wake_free_core` frees cached targets and destroys the mutex and core.
  The fallback neither completes native handle close nor licenses skipping normal
  loop cleanup.

Wrapper, in-flight packet, and native target/core lifetimes are separate.
References pin only native storage, not the bridge, Lua state, handle, or code
image, and the target cache is not stale-handle or dangling-borrow protection.
C-only calls after state close require the
[provider image to remain mapped](foreign-functions.md#source-collaboration-and-binary-isolation).

The independent-state fixture (`spec/stdlib/titan/lua/receiver_fixture.titan`)
exercises the GC detach during `lua_close` by registering its loop-cleanup
finalizer before constructing the wake, so reverse finalization detaches the
wake first. It asserts that `reserve` returns `EINVAL` before closing the handle,
because the handle's close handler would otherwise mask a missing detach. Assert
results from host-owned storage: finalizer errors are only Lua warnings.

## One-shot Task adapter

An adapter allocates its request owner and rollback state, then calls one of:

| Wait | Policy |
| --- | --- |
| `async.await_with` / `async.await` | Ordinary operation; pending cancellation skips submission, accepted work finishes before cancellation is delivered. |
| `async.await_cancellable_with` / `async.await_cancellable` | Return the accepted public request view so cancellation can attempt native `uv.cancel`; terminal completion still owns retirement. |
| `async.await_cleanup_with` / `async.await_cleanup` | Ownership retirement proceeds despite pending Task cancellation and during Runtime shutdown. |

The registrar runs outside Task context: capture Task-only state before
awaiting, and use `async.current_loop()` in registration to borrow the active
loop. Prefer a named `_with` registrar taking `Completion<|Context, Result,
Error|>` and the integer operation number; the callback-triple facade costs
three closures per wait ([allocation profile](libuv-runtime.md#allocation-profile)).
Every `_with` registrar returns `uv.req_t?`; ordinary and cleanup registrars may
return nil and never implicitly cancel a returned request. Inline settlement is
valid: the trampoline resumes the Task only after registration returns.

The Task reuses its Completion. Snapshot the operation number and context at
registration, keep them independently through native completion, and pass the
saved number to `context`, `resolve`, `reject`, and `fatal`. Context access ends
at retirement or registration failure. A stale number cannot settle a successor;
a stale fatal still reports Runtime failure without treating the successor's
native work as completed. Callback locals or independently owned rollback state
must retain any context needed after settlement. An exclusive UV data slot can
carry a per-operation context, but clear its old association before settlement
and never overwrite caller-owned slots. Concurrent requests need separate owners.

Prepare callbacks, view conversions, borrowed-buffer retention, and rollback
before accepting native work. A native rejection with no callback cleans its
request and rejects inline. After acceptance, return normally; no implicit
rollback service exists behind a thrown registration exception.

The terminal callback copies transient results, commits acquired resources to a
lexical or domain owner, performs mandatory native cleanup, and then resolves or
rejects. A descriptor from open belongs to an unpublished File before result
conversion or publication can fail; if cancellation wins delivery, lexical
unwind closes it through a cleanup wait.

Unexpected exceptions after the native completion has been consumed use the
operation-local fatal protocol
([runtime semantics](libuv-runtime.md#operation-local-fatal-callback-association)):

```titan
local completed = function (request: uv.fs_t)
  local result = uv.fs_get_result(request)
  uv.fs_req_cleanup(request)
  if result < 0 then reject(result) else resolve(result) end
catch
  uv.fs_req_cleanup(request)
  fatal(error, traceback)
  raise
end
```

This sketch handles a non-resource result; the complete
[File adapter](../language/async-file-example.titan) shows unpublished resource
ownership and preaccept-close restoration. `fatal` is legal only outside a
running Task after native ownership is safe, and must be followed by a bare
rethrow so the outer UV boundary also records the failure. Never use it to
release a still-pending request or as a logger. The `_with` spelling is
`done:fatal(number, error, traceback)` with the captured number.

File close shows the acceptance split: consume the published descriptor before
cleanup submission, restore it only when submission was not accepted, and keep
it terminal after accepted completion even if native close reports an error.
Accepted native work always determines the last borrowed-use boundary.

## Persistent source adapter

Choose the public subscription by ownership
([subscription semantics](libuv-runtime.md#persistent-subscriptions)):

- `CoalescingSubscription` keeps only the latest value. Its payload must be
  safely replaceable, because it cannot dispose of an overwritten resource.
- `BufferedSubscription` keeps every accepted value in order and can transfer an
  explicit-count batch. Use it for resource-bearing events such as accepted
  connections, and dispose of unread values in the producer's close action.

The producer receives publish/fail/finish and returns prebuilt stop/close
actions. `publish` returning true commits event ownership; false or an exception
leaves ownership with the producer, whose callback must then dispose of the
unaccepted resource. Error/end follow queued values, while closed stops further
delivery immediately. Nil and false payloads stay data.

One subscription has one reserved reader, including while its wake is queued;
cancelling that reader detaches only its wait. `has_waiter()` exposes this
reservation for domain admission checks. Longer classification or mutation
guards remain domain-owned. Repeated close does not join an already running
close; coordinate completion separately when another owner must observe it.
Several subscriptions may share one handle, or one subscription may aggregate
several handles; native close belongs to the actual domain owner. The
filesystem watcher uses `drain_if` and `wake_batch` to drain complete
callback-order batches across registration retirement
([filesystem library](filesystem-library.md)). Do not build a second generic
queue or scheduler.

## Workers, startup and shutdown

Ordinary blocking work can use `async.run_foreign`. A domain cleanup worker uses
public `uv.work_t` and `uv.queue_work` inside `await_cleanup`, retaining its
argument graph until after-work completion; SQLite's reset/finalize/close
adapter is one example. Cleanup policy never lets C workers touch Titan or free
an argument still in native use, including when a Lua state close unwinds the
waiting Task before the job returns
([foreign workers](libuv-runtime.md#foreign-workers)).

`uv.setup_process_args()` (`titan/uv/startup.titan`) configures only the
original argc/argv published by a generated executable entrypoint; it is
idempotent and returns false in an ordinary Lua host. Async initialization calls
it, installs the main bootstrap hook, and owns the Unix SIGPIPE policy
([startup policy](libuv-runtime.md#startup-policy)); UV itself installs neither.

Runtime failure cancels Tasks and lets their cleanup waits finish before final
handle discovery and close. `uv.walk` discovers handles, not descriptors or
other worker-acquired resources; an adapter owns those itself.
`async.is_closing()` is a synchronous admission query. See
[runtime shutdown](libuv-runtime.md#shutdown-and-process-control).

### Final state teardown is not ordinary shutdown

Public `uv.loop_abandon` (`titan/uv/uv.native.titan`) is the destructive boundary for
an exclusively owned loop during final Lua-state teardown. It returns zero for
uninitialized storage, raises off the owning main thread, and returns `EBUSY`
during an active run, walk, or inline dispatch. Async's Runtime finalizer calls
it ([ordering](libuv-runtime.md#lua-state-close-of-an-unretired-runtime)).

It unbinds the transfer loop and clears each handle's and request's user
callback slots once, before any native drive, while keeping the accepted owners
and borrowed storage. Internal terminal bridges still retire handle and request
roots. Abandoned FS and DNS requests get internal handlers (`fs_abandoned`,
`getaddrinfo_abandoned`) that release native results without creating public
copies: FS request allocations, undelivered `open`/`mkstemp` descriptors and
`opendir` results, and DNS address lists. External-wake close repeats its
native-only detach. No callback capture, public userdata, or domain object is
asked to clean up, because an earlier finalizer may already have released its
native resources, and no user callback, Task continuation, unregister function,
or Runtime-close listener runs. It returns `uv.loop_close`'s status.

A new binding that adds a callback slot must extend this one-time sweep, and an
independently allocated request result needs abandonment-only cleanup. Do not
add an abandonment branch to ordinary operation paths. Native work still
finishes before its borrowed storage is released. Resources owned by arbitrary
workers or domains, and results already delivered, are not UV's to dispose.
A domain whose ordinary close awaits releases its own native state
synchronously, from a finalizer or a close that tests `titan_state_closing`
(see [the owners](libuv-runtime.md#lua-state-close-of-an-unretired-runtime)).
Successful `uv.loop_close`, not suppressed callback counts, is the retirement
oracle. See the [public contract](../language/standard-library-uv.md#abandoned-loop-retirement).

## Native socket and pipe handoff

`titan/uv/transfer.titan` owns the custom transfer hooks for TCP and non-IPC
pipe endpoints. They use ordinary protobuf anonymous-field payloads
(`tcp_transfer_fields`, a foreign-pointer field written as fixed64;
`pipe_transfer_fields`, an integer field), so UV does not import async. Async
binds its state-local loop through `bind_transfer_loop` and clears that exact
binding at shutdown admission; destination hooks (`require_transfer_loop`)
refuse to allocate or adopt without it and never inspect Runtime state.

`stream_transfer_status` is the preflight. It rejects nonnil public userdata
(`EINVAL`), a connection callback, and any request still rooted in the owning
loop (accepted connect, write, or shutdown whose terminal callback has not run).
The native check in `transfer-native.h` rejects Unix bound pipes (native close
would unlink their pathname) and Windows pending reads, even after `read_stop`.
IPC framing and half-closed TCP direction are not reconstructible by descriptor
adoption. Callbacks are rebuilt by the destination domain. `transfer-native.h`
also duplicates the platform resource and handles the Windows socket versus CRT
descriptor distinction.

`to_transfer_payload` duplicates the resource, encodes the payload, and only then
closes the source owner, which keeps the old owner rooted through its ordinary
close callback; a lexical guard closes the duplicate if serialization fails.
`from_transfer_payload` allocates fresh native storage, initializes it on the
bound loop, and adopts the duplicated identifier; failed adoption closes that new
lifetime and leaves the identifier under the caller's manual recovery contract.
These are manual handoffs: `transfer.discard_message` neither decodes nor closes
them ([manual handoff](transfer-library.md#manual-resource-handoff)). The static
`discard_transfer_payload` methods decode the known schema and close the
unadopted resource directly, without a loop or Runtime; a close attempt consumes
ownership even when its status is an error.

## Validation and integration

Behavior belongs in public native Titan tests that exercise the canonical
compiled provider through ordinary imports: success, immediate rejection,
terminal error, cancellation, GC during native borrows, callback-time reuse, and
explicit close. Use public progress observations and bounded process deadlines.
Add a compiler or FFI test only for a compiler-boundary behavior. Keep
source-transforming test providers and scheduler injection hooks out of ordinary
behavior tests; if an ownership boundary is unreachable through a public client
or a standalone native fixture, agree on that exception before adding
instrumentation.

When adding a contributor, update the explicit source, header, and native-input
Make manifests, and keep one logical UV object and one canonical provider pair.
Regenerate the coverage map and provider-metadata fixtures from the exported
protocol of the coherently built provider; do not synthesize serialized schemas
or hand-normalize them from source text. The repository's commands, platform
gates, and isolation rules are in [AGENTS.md](../../AGENTS.md).
