# The async continuation runtime

The continuation runtime lives in `titan.async` and uses only the public
`titan.uv` module interface. UV owns native allocations, callback roots, borrowed
native data, and the native loop boundary. Async owns Tasks, generic waits,
cancellation, subscriptions, coalescing cross-state receivers, and shutdown.
Timer, filesystem, networking, I/O, OS, and SQLite adapters own their domain
records and result/resource policies.

The old private UV `Call` union, per-operation dispatch methods, Task association,
and domain-operation router are removed from this architecture. Adding an async
operation does not add a new scheduler variant. A registrar expresses its one
native submission and receives a typed Completion with its exact operation number.

## Module and type ownership

`Error`, `OperationError`, `ResumeToken`, `CancellationReason<|B|>`,
`TaskStatus<|A,B|>`, and `Task<|A,B|>` are now defined in async rather than aliased
from private UV owners. Public field names, result tags, constructor namespaces,
and generic positions remain those of the existing async API. The defining
module in nominal metadata changes; it is not byte-identical old metadata.
Consumers need the rebuilt matching canonical provider. The generated-code ABI
remains 2; the prerelease language-server API remains 1. Other version numbers
are unchanged; baseline and ownership revisions are identified by hashes, not
by an ABI-version delta.

`titan.transfer` defines the canonical `TransferValue` union and native packet
helpers, and `titan.async` exports a transparent `TransferValue` alias while
owning `Receiver` and `ExternalWait`. Scalar `TransferValue` variants hold
ordinary Titan values, and the string variant retains its source string in a
traced slot. Record/union variants retain the defining module, nominal name,
and protobuf wire bytes in traced slots. State, native-function, and
raw-pointer variants hold portable borrowed C pointer types and do not root
their referents. `async.send` and `Receiver:wait` transport values and explicit
`TransferValue` policies through `titan.transfer`'s native
`titan_async_message` packets, while the Lua adapter owns its separate
`titan_lua_value` packets and copy/borrow conversion policy, described in
[the Lua implementation chapter](lua-library.md#cross-state-transfer).

Tasks use tagged `coroutine.Coroutine` control transfer. Coroutine itself keeps
its existing public and native ownership contract; async uses one private tag
to route its yields. `coroutine.running()` still observes the exact public
Coroutine record and does not become an async Task lookup.

The generic runtime stores these private layers:

| Owner | Responsibility |
| --- | --- |
| `Runtime` | One public `uv.loop_t`, reusable zero timer, FIFO ready nodes, sparse live Tasks, current Task and driver/closing state, first callback failure, exit status, optional `ExternalBridge`, and a separate retained `retirement_error` capability for explicit retry. |
| `Task` | Coroutine and scalar/public phase, checked epoch, ready node, sticky cancellation, exact Wait/listeners/suspend state, cleanup binding, traced pending terminal kind/value/trace, and `root_done`; terminal admission is separate from ordinary root/cleanup execution. |
| `Completion<|C,T,E|>` | One lazily allocated (or `run_with_cleanup` preallocated) reusable cell per Task: scoped context, registrar, Task, captured suspension epoch, policy, phase, outcome/payload and optional accepted request. |
| `Wait` | The private all-value Completion view; it has the same owner, not another record. |
| `ExternalBridge` | Lazily initialized per-Runtime `uv.external_wake_t`, sparse `waits` Map from 64-bit identity to `ExternalWait`, monotonic `next_identity`, and `closed` flag. |
| `ExternalWait` | Reserved target/identity, closure registrars or C-ABI registrars/context in the inline `titan_async_retirement` cell plus traced `native_owner`; optional native retirement callback and exact cleanup Task, attached Completion/epoch, and distinct `used`, `awaited`, `close_requested`, notified and retired state. |
| Subscription `Core` | Queue, explicit count, terminal state, one reserved waiter, producer actions, cleanup drain capability. |
| Public UV owner | Native request/handle storage and callback rooting until its defined native terminal boundary. |
| Domain owner | Resources obtained from native completion, facade state, sharing rules, and lexical cleanup. |

Suspension epochs and the ready queue belong to async. UV has no Task table,
scheduler queue, or native-request introspection to recover a Task.

## Driver and registration trampoline

Only `async.loop()` or the standalone async bootstrap drives the
async-owned loop with `uv.run`. Independent low-level clients may explicitly
drive their own public UV loop; this restriction concerns Runtime ownership.
The driver runs on the Lua main thread and rejects reentry or calls from a
running Task. One Task
continuation runs to yield, return, or error without another loop callback
interrupting it. The Runtime sets `current_task` only around coroutine entry
and clears it before registration and terminal notification.

`run(func)` roots a ready Task and appends its startup to the Runtime FIFO.
Yield, correct-token explicit resumes, and peer-Task settlement use the same
queue. Its normally referenced zero timer is active only while work is queued.
Named typed timer callbacks recover the Runtime from traced timer data without
constructing handle views or forwarding closures. The public `run<|A,B|>`
result and the Runtime's all-value view refer to the same Task owner.

`run_with_cleanup(body, cleanup, final_wait?)` marks `task.cleanup_start = true`
and eagerly allocates `task.completion` before enqueueing `READY_START`.
An ordinary `run` Task cancelled before startup finishes without entering its
coroutine; a cleanup Task is dispatched through its wrapper instead. On entry
the wrapper **installs** the cleanup defer before `checkpoint()` and `body()`.
That defer later sets `task.cleanup_active = true` and calls
`cleanup(task.cancel_value)` during exit/unwind. A preaccepted Task-level barrier,
not successful entry into either ordinary callback, must protect native
retirement before terminal status or listener publication.

The optional `final_wait` must be a live, unused, unbound native-retirement
capability from `prepare_native_retirement` in the same Runtime. Ordinary
closure-registered waits are rejected. Validation repeats after allocations.
`run_with_cleanup` binds `task.cleanup_wait` / `cleanup_task`, activates and
registers the native barrier before exposing the Task. Admission failure
rolls back native links/target ownership without entering body/cleanup or
claiming the original domain resource has retired.

`begin_suspension` reserves MAX only for owner-cleanup `WAIT_CLEANUP` with the
exact bound capability context and private canonical
`start_native_retirement_wait` registrar. Other operations in a designated Task
are capped at `LUA_MAXINTEGER - 1`, including generic cleanup awaits with an
aliased capability context. No arg3 means the ordinary MAX limit; `>=` rejects
exhaustion without wrapping. Explicit cleanup attachment is optional: native
terminal ownership remains independent of suspension epochs and successful
ordinary entry. See [native retirement barriers](#native-retirement-barriers).

Queue acceptance arms a needed wake before changing any node or reservation.
Only nonallocating field updates follow success. Each callback snapshots the
initial count, capped at 64. It pops and clears each node before entering a
continuation, retaining local copies of its intent, epoch and exact Wait.
Reentrant Task requeue cannot be erased by old-node cleanup. Cancelled and stale
entries still consume their place in the initial batch; new entries wait for
another callback. Undispatched entries remain linked and rooted after failure.

Private `yield()` yields one canonical marker, without an Operation, Wait,
capability closure or discarded Result. The driver checks admission, advances
the Task's suspension epoch, and queues it. Every admitted suspension advances
that epoch; reaching `LUA_MAXINTEGER` raises at the suspended call rather than
wrapping. Queue delivery and orphan snapshots validate both epoch and exact
Wait, including an absent Wait for private yield. Failed admission or enqueue
returns through the bounded coroutine trampoline.

Each `_with` await initializes the Task's Completion and yields it with the
private tag. The driver checks cancellation policy, advances the checked Task
epoch, installs that exact cell as its Wait, and calls the registrar with the
cell and captured epoch. All registrars return `uv.req_t?`; a named registrar's
nominal Completion argument retains one erased native callable shape, avoiding
a concrete-context adapter. The callback-triple APIs wrap this same core and
retain their three closure capabilities and any callable adjustment cost.
The Task is now waiting, but `async.running()` is
absent while registration executes. `current_loop()` accesses the active
Runtime loop without creating or driving it. `is_closing()` reads that same
active Runtime's closing flag, raises if there is no active Runtime, and has no
Task-context or cancellation check. Synchronous domain construction uses it when
shutdown admission must be rejected without adding an ordinary await boundary.

`checkpoint()` provides the same running-Task, first-cancellation-reason, then
Runtime-failure admission order for synchronous domain paths. It does not
construct an Operation, Wait, capability closures, result or transient status,
and does not yield. Domain callers retain their existing validation, reader
reservation and lazy-start ordering around this check. Cleanup paths remain
exempt from ordinary admission.

The usual lifecycle is:

```text
REGISTERING -- accepted, no inline result --> PENDING
REGISTERING -- inline resolve/reject -----> SETTLED --> RETIRED
PENDING ----- terminal resolve/reject ----> SETTLED --> RETIRED
PENDING ----- associated fatal callback ----------------> RETIRED
```

Inline settlement records outcome and returns to registration. Only after
registration returns does the trampoline retire that Wait and resume the Task.
This avoids recursive coroutine entry for synchronous rejection or immediately
available data. Registration exceptions retire their Wait and are injected at
the await expression. Adapters must not throw out of registration after native
acceptance while leaving a callback borrowing released state; partial native
rollback is the adapter's responsibility.

Normal terminal settlement outside a Task can deliver immediately. Settlement
from a different running Task first accepts a deferred queued wake and then
commits the settled state using nonallocating field writes. If scheduling fails,
the Wait remains pending so retry/shutdown can still address it. Delivery checks
that the Wait is SETTLED, remains exactly `task.wait`, and has the current
suspension epoch; it clears the request,
Wait, token, and explicit-suspension state before entering the continuation.
Duplicate settlement raises rather than mutating an unrelated wait.

Completion reuse checks both owner and epoch. Initialization temporarily uses
epoch zero, which no public method accepts, and registration publishes the
newly checked number. A callback captures this number at registration; looking
up the current wait later would confuse an old callback with a successor.
Retirement materializes the public tagged Result, then clears context,
registrar, request and payload before resuming the coroutine. Terminal Task
cleanup clears its cached cell even if result allocation failed after removing
`task.wait`. A retained completed Task or stale Completion does not retain old
operation context. The numeric counter never wraps at `LUA_MAXINTEGER`.

`context(number)` is available only for the matching, unretired operation.
Callbacks and partial-acceptance rollback must independently root any context
needed after settlement or registration failure. This is an ownership contract,
not an inference that retiring a wait proves native work ended. A private UV
data slot may hold a domain context plus Completion/number; terminal callbacks
copy these to local roots and detach the old slot before settling. Fresh
request/context allocations still count, and a shared stream cannot supply one
completion slot to overlapping writes. The legacy closures preserve their
existing duplicate-settlement diagnostic even after the cell is reused.

## Wait policies and native ownership

The result unions use explicit tags. Payload truthiness never selects success,
error, cancellation, or completion; nil and false are valid success values.
CancellableResult exposes the current Task's all-value cancellation reason.

| Policy | Before registration | Accepted request | At terminal delivery |
| --- | --- | --- | --- |
| Ordinary | Inject pending cancellation instead of registering. | Keep native ownership; no implicit `uv.cancel`. | Pending cancellation replaces success/error with the raised reason. |
| Cancellable | Return tagged pending cancellation instead of registering. | Keep the returned `uv.req_t`; `Task.cancel` attempts public `uv.cancel`. | Still await callback, then return tagged cancellation if pending. |
| Cleanup | Register even during cancellation/fatal shutdown. | Do not cancel ownership retirement. | Deliver ordinary result; unexpected fatal exception still raises. |

Cancellable registration returns nil only after inline settlement. An unsettled
nil return is a protocol error. Native `uv.cancel` success or failure never
retires the Wait or releases borrowed storage; only the request's terminal
callback does so. Ordinary and cleanup `_with` registrations may return a
request view or nil; their policy never implicitly cancels that view. Avoid
allocating it when unnecessary. Their native owners remain retained by public
UV and suspended lexical state.

Task cancellation retains its first reason and overrides final Task success or
failure. Cleanup shielding changes submission/result delivery, not this terminal
policy. New ordinary/cancellable operations during fatal shutdown receive the
Runtime failure; cleanup operations remain available to retire ownership.

## Operation-local fatal callback association

Every Completion registration may call `fatal(number, error, trace)`; the
callback-triple facade supplies the corresponding captured closure. This is an out-of-band exception channel,
not generic rejection and not a public native cancellation handle. An adapter
protects its terminal callback, captures borrowed/acquired results into owned
state, performs explicit request cleanup, calls fatal from catch, then uses
bare `raise`. The low-level boundary still sees the original exception and can
stop/rethrow it as required.

The capability may be invoked only outside a running Task and only once the
native terminal callback has been consumed with safe callback-local ownership.
It cannot abandon outstanding native work. Expected native/domain errors still
use typed reject. Shared or multi-shot sources finish their local rollback or
transfer before raising; they rely on cancellation of the subscription waiter
and lexical domain cleanup, not this one-shot capability.

For a pending exact Wait, fatal first retires it, clears its request and explicit
suspension state, records the Runtime's first error/trace, and cancels other
Tasks. It excludes the associated Task from newly imposed shutdown cancellation
so injecting the original error can produce its normal failed status. A reason
already pending on that Task remains sticky. The exception enters the Task
immediately, allowing lexical cleanup to make progress even if another accepted
native operation depends on that cleanup.

During REGISTERING, fatal stores a fatal outcome and leaves advancement to the
registration trampoline. After SETTLED or RETIRED, it only records Runtime
failure; it must not replace the settled payload or touch the Task's new Wait.
An old number on a reused cell likewise only records failure: it never treats
the successor's native request as consumed. Ordinary shutdown cancellation and
terminal ownership still govern that successor.
The first-error latch is separate from the once-only shutdown-cancellation pass.
When already driving, latching failure calls `uv.stop` so the outer driver can
cancel/unwind Tasks before waiting indefinitely for unrelated accepted work.

An arbitrary unprotected callback supplies no Wait association. The driver
handles its low-level error boundary and retains native owners, but cannot
identify a consumed request's Task early. That boundary is why custom one-shot
adapters must implement the explicit fatal protocol. This is not a claim of
universal recovery from every foreign callback mistake or memory failure.

## Explicit suspend, Task status, listeners, and combinators

`SuspendCancelAction` remains `function():()`. Suspend uses its ResumeToken as
Completion context and a named registrar. It stages the detacher, then publishes
the exact token only after admission; even a GC finalizer during cell setup
cannot observe an admitted suspension prematurely. A lexical defer clears
staged state if construction or admission fails. Task.resume
checks identity before any finished/pending shortcut. Matching pending wakes
coalesce; equal source strings do not authorize a different token. A failed
scheduling attempt leaves `resume_pending` unset, and completion retires the old token
before a new wait can be installed.

Cancelling an explicit suspension invokes its detacher and schedules the
ordinary token wake. It does not enter the target Task inline. Terminal status
publication clears the suspension, detaches the listener snapshot, and marks
its entries non-live before delivery. Removal before snapshot is idempotent;
removal during delivery cannot suppress a captured listener. Individual listener
exceptions are swallowed so later listeners still run. Registering after
termination does not replay the terminal event.

The private scalar phase drives internal finished checks. Each transition
invalidates the optional nonterminal status cache, and `status()` constructs
its snapshot on first observation. Repeated reads share that snapshot; later
transitions never mutate or reuse it. Terminal snapshots and listener delivery
are eager only after root completion and any native-retirement gate admit the
terminal outcome. TaskStatus ready/running/waiting remain unfinished, while
succeeded/failed/cancelled remain terminal. Predicate booleans remain authoritative for nil or
false payloads. Uncaught Task exceptions are reported and stored in Error with
the caught Lua error value and raw trace; they do not alone fail the Runtime.
Raised nil follows the ordinary [Lua error normalization](error-handling.md#runtime-trace-model).

The existing channel, reader/writer, and all 17 join/any/race/all functions keep
their public signatures and behavior. Fixed arities two through five preserve
independent Task result/cancellation positions. Fast paths inspect already
terminal operands in argument order. Suspended paths select by delivered
listeners. No combinator implicitly cancels losing operands, every operand is
checked for self-dependency, and lexical listener removers cover cancellation
or other unwind. The source review confirms the complete existing channel
through join_five block is unchanged; generic await and subscriptions do not
replace it.

Channels retain a bounded circular buffer, explicit item count, one reserved
blocked sender and receiver, and immediate discard on close. Writer close is
not automatic clean reader EOF: the existing reader excess/reader.close rules
remain in force. See the language chapter for the unchanged detailed contracts.

## Persistent subscriptions

Both public subscription records wrap one private Core. It stores explicit
count/first indices plus Item wrappers, so nil and false remain present payloads.
Buffered mode retains FIFO order; coalescing mode replaces the one unconsumed
value. Consumed FIFO prefixes are compacted amortizedly only after the consumed
prefix can pay for copying the remaining live items. The old queue stays owned
until replacement allocation/copy succeeds; indices do not grow forever under
sustained partially drained traffic.

A producer receives publish/fail/finish and returns prebuilt stop/close actions.
It owns partial-registration rollback until that return. Publish commits queue
ownership only when wake acceptance succeeds. If waking raises, it restores the
previous slot and count; wake itself restores its notified flag. False or a
synchronous exception therefore leaves resource ownership with the producer.
Error/end terminal changes similarly roll back on wake failure.

One Waiter reserves a Task/token pair and whether it requests a batch. Reads
check competing waiters and pending cancellation before transferring any item.
Suspension uses the existing nonyielding exact detacher. Notification retains the
reservation until that reader resumes or unwinds, so another reader cannot steal
its delivery. Cancellation only detaches that waiter; it does not stop the
source or discard its events.

Single-item result construction precedes removal from the FIFO. Batch result and
replacement storage construction precede wholesale detachment. A producer drain
also transfers a counted batch; the caller then owns all entries. These ordering
rules avoid a gap where native resources are neither queued nor held by their
consumer. The generic queue does not dispose of overwritten coalescing values;
resource-bearing events require buffered ownership or an explicit domain policy.

Both public `has_waiter()` methods test the Core's exact waiter reservation.
A queued wake retains that reservation until the reader exits; cancellation
clears it through the same detach path. Domain admission checks use this query
instead of accessing subscription internals or assuming a scheduled wake has
already freed the reader slot.

Queued values precede error/end, whereas closed takes precedence immediately.
Stop records its idempotence state, selects ended for a live queue, calls the
nonyielding producer stop once, and wakes via a defer. Close captures/arms cleanup
and final discard before any fallible stop/wake, marks closed, then runs the
producer close action. That action may await cleanup and use its supplied drain
to dispose of unread resources. Subsequent close calls initiate nothing and do
not wait for the first call's in-progress cleanup.

Buffered controls stay synchronous. `snapshot_pending` copies the complete unread FIFO and
returns its terminal outcome, or nil while live, without consuming entries or
reserving a reader. The copy retains values after the source drains or closes;
payloads themselves retain their ordinary reference semantics. Resource hooks
use it to allocate snapshots before detaching native ownership. `drain_if` uses a
nonyielding, nonmutating predicate and detaches the entire FIFO on any match; it is not a
filter. `drain_pending` detaches regardless of terminal state. A domain that
removes the outcome reserved for a notified reader must complete its terminal
or control transition before yielding back to that reader. `wake_batch` affects
only an existing batch waiter, stores no credit, and permits a live empty batch
without ending the queue.

Domains retain their own sharing and error-priority rules. One watcher queue
may collect callbacks from several native registrations, retain a guard across
yielding classification, and conditionally detach a whole retirement-crossing
batch. TCP reads drain copied chunks before error/EOF; accept may need to close
unread clients before delivering a listener failure. These policies do not
belong in Core and do not require new generic operation kinds.

## External wake bridge

`ExternalBridge` and `ExternalWait` adapt cross-thread readiness notifications
onto one Runtime-owned [`uv.external_wake_t`](../language/uv/types.md#external_wake_t)
bridge instead of initializing and closing a `uv.async_t` handle per wait:

The registration sequence below describes ordinary external waits: either
closure-registered or `wait_external_native` with C-ABI registrars/context and a
traced domain owner. [Native retirement barriers](#native-retirement-barriers)
use a separate preaccepted Task-level lifecycle; successful entry into a cleanup
callback is not their ownership guard.

1. **Lazy bridge creation and unreferenced initial handle**:
   `external_bridge(runtime)` lazily creates one `ExternalBridge` per `Runtime`
   and calls `uv.external_wake_init(runtime.loop, bridge.wake, callback)`.
   `external_wake_init` allocates `titan_uv_external_wake_core` (whose first
   member is `uv_mutex_t mutex`, followed by `uv_async_t *handle`, `references`,
   `registrations`, `active_waits`, intrusive `registered` list, intrusive
   pending FIFO `head`/`tail`, and a hard-bounded `free_targets`/`free_count`
   stack of up to 64 reference-zero retired targets), initializes the internal
   `async_t`, and immediately calls `uv_unref` on `core.handle`. The bridge
   handle is distinct from the scheduler's zero timer `runtime.wake`.
2. **Two-phase `reserve` (unreferenced) and `activate` (referenced liveness)**:
   - `prepare_external_wait(register_fn, unregister_fn)` calls `ensure_runtime()`
     (creating the Runtime if needed without requiring a running Task or driving
     its loop, and rejecting when `runtime.closing` or `runtime.exit_code ~= nil`),
     assigns a monotonic positive identity from `bridge.next_identity`
     (`1..LUA_MAXINTEGER`, transitioning `next_identity` to `0` after
     `LUA_MAXINTEGER` so exhaustion raises
     `"async external wait identity exhausted"` without wrapping or reusing
     IDs), stores `owner` in `bridge.waits[identity]`, and calls
     `bridge.wake:reserve(identity)`.
   - `external_wake_t:reserve(identity)` pops a reference-zero target from
     `core.free_targets` under `core.mutex` when available, or unlocks
     `core.mutex` (safe because the owning bridge's core reference cannot be
     dropped from another thread before same-thread `external_wake_detach`),
     allocates a fresh `titan_uv_external_wake_target` with `malloc`, and relocks
     `core.mutex`. On either path it checks `core.handle ~= nil`, freeing the
     popped or freshly allocated target and returning `UV_EINVAL` when the
     handle is already nil (closing bridge). It then resets every target field (`core`,
     `references = 1` for the registration, `identity`,
     `phase = TITAN_UV_WAKE_PREPARED`, `registered_prev`/`registered_next`,
     `next`/`prev`), increments `core.references` and `core.registrations`, and
     links the target into `core.registered`, **without** incrementing
     `core.active_waits` or referencing `core.handle`. Holding an unused
     prepared `ExternalWait` therefore never keeps an otherwise idle event loop
     alive.
   - When `ExternalWait:wait()` (`WAIT_ORDINARY`) or
     `ExternalWait:wait_cleanup()` (`WAIT_CLEANUP`) runs `start_external_wait`,
     it first calls allocation-free `bridge.wake:activate(owner.target)`. Under
     `core.mutex`, `activate` transitions the target from
     `TITAN_UV_WAKE_PREPARED` to `TITAN_UV_WAKE_ARMED`, increments
     `core.active_waits`, and calls `uv_ref(core.handle)` when `active_waits`
     transitions from `0` to `1`. While any external wait is active, the loop
     remains referenced so `loop()` never treats a Task waiting on another OS
     thread as an idle-loop orphan.
3. **Domain registration, lock order, and inline readiness**:
   - After `activate`, `start_external_wait` sets `owner.registered = true` and
     invokes `owner.register_fn(owner.target)`, or
     `owner.native.register_wait(owner.native.context, owner.target)` for an
     ordinary C-ABI wait. Both run after the tagged Task yield.
   - The domain callback locks its own native mutex first and, when it must
     wait, calls `uv.native_external_wake_retain(target)` (which locks
     `core.mutex` to increment `target.references`). The lock order is strictly
     **domain mutex $\to$ wake core mutex**, and loop-thread callbacks unlock
     `core.mutex` before scheduling Tasks.
   - If `register_fn` returns `false` (already ready), `start_external_wait`
     clears `owner.registered = false`, calls `owner:retire()` (which removes
     `bridge.waits[identity]` and calls `bridge.wake:unregister(target)`), and
     settles `done:resolve(number, nil)` inline without suspending. If
     `register_fn` raises, `start_external_wait` calls `owner:detach_domain()`
     and `owner:retire()` before rethrowing.
   - The C-ABI ordinary route uses `prepare_wait` with `native.retire = nil`.
     Register status `0` is inline-ready, `1` is linked, and negative status is
     clean rejection translated at `async.external_wait.register` with the same
     detach/retire unwind. `detach_domain` selects native unregister when present;
     its `registered` latch allows only one cancellation/failure unlink. No
     native-retirement poll, prearming, cleanup privilege or terminal gate is
     added. `native_owner` remains traced through callback return/unlink, then
     retirement clears it along with the context and callback pointers. The
     context itself is only borrowed: its caller must retain storage through the
     whole await. Channels use automatic storage in the suspended stackful frame
     and a traced endpoint owner, not a fresh per-wait context userdata.
4. **Native producer notification and bounded drain**:
   - Native producers on any OS thread call
     `uv.native_external_wake_notify(target)` (which under `core.mutex` links an
     `ARMED` target to the tail of `core.head`/`core.tail`, sets
     `TITAN_UV_WAKE_PENDING` without changing `target.references` or
     `core.references` because `PENDING` implies the target is registered, and
     calls `uv_async_send(core.handle)`) and then release their producer
     reference via `uv.native_external_wake_release(target)`. Producers never
     access Lua or GC state.
   - On the destination loop thread, `ExternalBridge:drain()` calls
     `self.wake:drain(identities, 64)` with a 64-slot stack array. Under
     `core.mutex`, `external_wake_drain_native` unlinks up to 64 pending targets
     in FIFO order, sets `TITAN_UV_WAKE_DELIVERED` without changing reference
     counts, copies their 64-bit `identity` values, and—if
     `core.head ~= nil`—calls `uv_async_send(core.handle)` to rearm the handle
     for the remaining work before unlocking.
   - After unlocking, `ExternalBridge:drain()` looks up each `identity` in
     `self.waits[identity]` and calls `owner:notify()`, which checks
     `not self.retired`, `not self.notified`, `done.epoch == self.number`,
     `task.epoch == self.number`, `task.wait == done`, and
     `done.phase == WAIT_PENDING`. Ordinary waits schedule through
     `task:resume(self.token)`; cleanup waits schedule through
     `enqueue_ready(task, READY_RESUME, done)`.
5. **Cancellation, retirement, and emergency detach**:
   - Cancelling an active ordinary wait runs `owner:cancel_wait()`, which
     synchronously calls `owner:detach_domain()` (`unregister_fn()`) and
     `owner:retire()` (`bridge.wake:unregister(target)`). Under `core.mutex`,
     `unregister` unlinks the target from `core.registered`, unlinks any
     `TITAN_UV_WAKE_PENDING` queue node in $O(1)$ time, marks the target
     `TITAN_UV_WAKE_RETIRED`, decrements `core.registrations` and (when not
     `PREPARED`) `core.active_waits`, unreferences `core.handle` when
     `active_waits` reaches `0`, and drops the registration reference
     (`external_wake_drop_target_locked`). Because the loop owns only the
     registration reference and unlinks any pending node before dropping it, a
     target reaches `references == 0` only after both registration and all
     producer references are gone; `external_wake_drop_target_locked` then
     decrements `core.references` (so cached targets hold no core pin) and
     either pushes the target onto `core.free_targets` (up to
     `TITAN_UV_WAKE_TARGET_CACHE_LIMIT = 64` per core, never across cores) or
     frees it with `free`.
   - Normal `ExternalBridge:close()` (invoked by `close_handles` after all Tasks
     retire) closes any remaining unused `ExternalWait` reservations and calls
     `self.wake:close()` (`external_wake_begin_close` rejects with `UV_EBUSY` if
     `registrations ~= 0`, otherwise clears `core.handle = nil` under
     `core.mutex` and closes the handle).
   - When `handle.close_handler` runs or `external_wake_t` is finalized by
     GC / `lua_close` without normal loop drain, `external_wake_detach` locks
     `core.mutex`, clears `core.handle = nil` and `core.head = core.tail = nil`,
     retires all remaining registrations (clearing both `registered_*` and
     `next`/`prev` links before dropping each registration reference), and drops
     the owner's core reference without touching libuv or GC objects. Targets
     still retained by background native producers (including a detached
     `Thread:task()` proxy retirement producer) are not cached while their
     producer reference remains nonzero; they keep only the C-heap `core` alive
     until their final `native_external_wake_release`, and any late
     `native_external_wake_notify` sees `core.handle == nil` and returns
     `UV_EINVAL`. When `core.references` reaches `0` (in `external_wake_detach`
     or `native_external_wake_release`), `external_wake_free_core` drains and
     frees all unpinned targets in `core.free_targets`, destroys `core.mutex`,
     and frees `core`. Lua/Titan wrapper lifetime (`ExternalWait`,
     `external_wake_t`, endpoint and task wrappers), in-flight transfer message
     lifetime, and native wake-target/core lifetime remain separate: the
     per-core target cache reuses only reference-zero native storage and is not
     stale-handle or dangling-borrow protection.

## Native retirement barriers

The generic native-barrier mechanics below are the authored contract. The thread
standard library uses this barrier for `Thread:task()` and suspends its channel
and join waits through the generic external-wait bridge; the concrete callbacks
and their owners are in the
[thread implementation](thread-library.md#join-proxy-retirement-and-the-native-terminal-barrier).
Exercised runtime, sanitizer, platform and performance results are the
integrator's evidence, not claims of this chapter.

`prepare_native_retirement(owner, context, register_fn, unregister_fn, retire_fn)`
constructs an `ExternalWait` with a traced `native_owner` and loop-thread-only
`titan_async_retirement` cell (`titan/async_receiver_native.h`). The cell stores
the raw context, three C callback pointers, and `armed`, `ready`, `status`.
Native producers retain only independent UV wake targets/cores, never pointers
into this GC-owned cell. The traced owner stays alive through callback return
and committed native retirement, including OS join; queued native
nodes/context need independent native lifetime through state close.

`retirement_poll_native` returns zero immediately when `ready` is latched and
returns a cached negative `status` without retrying it. Otherwise it calls the
native `retire`, stores the returned status, and sets `ready = 1` only on zero.
Callbacks are C-only/nonraising/nonyielding and execute on the loop thread with
no driver-held core or domain mutex; a callback may take its own domain mutex
briefly but must release it before blocking. It may block only for native final
completion after readiness—not unfinished domain work—and no bound is promised
on that native tail. Pending-path side effects and successful retirement must be
safe to repeat.

### Constructor admission and ownership

Task/coroutine/Completion allocation precedes exclusive binding. The constructor
revalidates the live unused same-Runtime capability, roots the Task, activates
its UV target and calls native `register_wait(context, target)` before enqueueing
startup or returning it. Result `1` means a retained linked producer waiter;
`0` means monotonic already-finished readiness with no producer reference and
must be followed by successful native retirement before Task exposure.
A negative result leaves no native link/reference and raises a synchronous
`OperationError`; activation/register operations are
`async.native_retirement.activate` / `async.native_retirement.register`.
Register `0` followed by pending retirement is a protocol error,
`"native retirement is not complete"`.
An immediate constructor retire error uses `async.native_retirement.retire`
synchronously and closes admission; it does not expose a Task for driver retry.

Before binding, failure leaves the caller's reservation intact. After bind/arm
admission starts, rollback calls native unregister only for an admitted domain
link, removes the map/target borrow, consumes the UV registration, clears
binding/context keepalives and closes the capability. It removes the unexposed
Task without calling body/cleanup or reporting an unrelated unhandled Task
failure. The original domain owner still owns any running resource; a closed
capability cannot be reused.
An unused unbound capability's `close()` releases the preparation without a
Task or native domain registration; it does not claim native resource retirement.

### Durable receipt, optional wait and logical close

In `ExternalBridge:drain`, native capabilities run `retirement_poll_native`
before any ordinary `owner:notify()` entry. Zero latches readiness before
removing the target/map registration; a negative result retains ownership,
records `runtime.retirement_error` and stops the current UV run. Pending receipt
remains recoverable as UV target PENDING/DELIVERED state, independently of the
current Task Completion/epoch.

The producer must notify only when the next retire poll can return zero or
negative. Once DELIVERED, further native notifications return without sending a
new wake; a post-notification pending result could strand a referenced wait.
Retire can also be polled from owner cleanup, terminal publication and failure
recovery, so positive-path side effects must be idempotent. A completion
notification can arrive while the host body still runs.

Native capabilities are final-wait-only. Unbound awaiting raises
`"native retirement is not bound to a cleanup Task"`; body/peer/ordinary-wait
use of a bound capability raises
`"external wait is reserved for its Task cleanup"`. Only owner cleanup may call
`:wait_cleanup()`, at most once. Its distinct `awaited` flag allows this
attachment despite constructor prearming having set `used = true`.
`start_native_retirement_wait` attaches the exact Completion/epoch to the
already-armed barrier; it does not register another waiter. Latched readiness
resolves inline, otherwise the wait remains cancellation-shielded.

`close_requested` is a logical close of the user-facing wait view. Owner cleanup
may set it while retirement is pending, but neither `close` nor a failed
ordinary cleanup entry detaches the accepted native barrier. Further awaiting
raises `"external wait is consumed or closed"`. Closing an active await raises
`"cannot close an active external wait"`; retired close is idempotent.
Normal successful retirement does not invoke domain unregister: the producer
already unlinks/releases its reference when notifying. That callback is for
constructor rollback.

### Terminal admission and recovery

The wrapper traces body return/error state before cleanup; the Task retains
pending terminal kind/value/trace and `root_done`. `publish_terminal` requires a
completed root and a terminal candidate, then polls the barrier. Pending native
retirement keeps the Task nonterminal. A separate `finish_task` readiness check
also refuses publication before `native.ready`, including startup/cleanup
ordinary-entry failure. Original body errors survive later cleanup-entry errors;
sticky cancellation still has final precedence.
An explicit first `Task:cancel` after `root_done` but before native readiness
therefore still overrides the pending success/error. Neither `root_done` nor
cleanup shielding makes a nonterminal Task immune to cancellation, and accepting
that reason does not publish terminal status before retirement.

`ExternalWait:notify` queues `READY_TERMINAL` when the root/terminal candidate is
complete; an attached cleanup wait instead uses existing exact-epoch ready
delivery. Neither path resumes a Task from the native callback.

Before a blocking UV run, loop-entry/failure recovery uses the existing Task
inventory to observe native pending/delivered receipt and poll retirement.
It is not a channel scan, new registry, or idle-only orphan pass. It recovers
dequeued startup via `READY_START`, settled delivery via `READY_DELIVER`, and
an unaccepted/no-outstanding-operation continuation via `READY_UNWIND`; none
of those repairs detach the preaccepted native barrier. Native readiness is
latched before fallible ordinary notification/publication, so losing such an
entry cannot lose the only native receipt.

### Explicit negative-status retry

For an admitted barrier, a negative native retire status is not a failed or
completed Task. The driver raises `OperationError` with the unchanged native
code and operation `"async.native_retirement.retire"` while the same Task,
native context/token, target registration, Completion/epoch and
Runtime/default context remain owned. It does not perform normal final Runtime
teardown, automatically spin, join unfinished work, or detach the resource.

A new explicit `loop()` invocation clears only `runtime.retirement_error` and
negative native status latches (back to pending `1`), then polls the same
capability before blocking—even if its UV target was already DELIVERED and no
new wake will arrive. Each negative capability is retried once for that new
invocation; another negative status is cached and surfaces another driver
error. Zero permits normal ready/terminal delivery. No new registration,
owner/Task recreation, or epoch reset occurs.

For Thread adapters, reasonless native cleanup cancellation is permitted only
after missed/failed ordinary forwarding with no child cancellation admitted,
at an exact owner cleanup attachment or pending terminal candidate. It must
not begin from an unfinished normal body or constructor register result `1`.
The original host error/first reason and accepted child reason remain intact;
actual OS join, not cancellation or a logical status, is the retirement proof.

## Cross-state receiver ownership

`Receiver` owns the public
[lossy cross-state notification](../language/async-io.md#cross-state-receivers)
boundary over `titan_async_receiver` (`titan/async_receiver_native.h`), which
pairs a borrowed `uv_async_t` address and C-only `send` function pointer with an
atomic `titan_async_message *message` slot (`titan_async_receiver_exchange`
using `__atomic_exchange_n(..., __ATOMIC_ACQ_REL)`) and `closed` flag. There is
no `mode` discriminator, `CoalescingSubscription`, native FIFO, or mutex.

Its opaque `foreign *void` handle names native receiver storage, not a Titan
record or public `uv.async_t`. The sender never follows a remote GC pointer or
enters the destination Lua state:

- **Guarded encode and atomic publication commit (`async.send`,
  `receiver_send_native`)**: `async.send(handle, candidate)` rejects a `nil`
  handle, encodes `candidate` (any transferable Titan value, including
  `thread.Sender` and `thread.Receiver` endpoints, or an explicit
  `TransferValue` policy) into a real local
  `raw = transfer.encode_message(candidate)` guarded by
  `defer transfer.discard_message(raw)`, and calls the local foreign
  `receiver_send_native(handle, raw)` directly at that local. In one C-only
  interval, `receiver_send_native` checks `receiver.closed ~= 0` (returning `2`
  so `async.send` raises `"receiver is closed"` while leaving `raw` untouched
  for the deferred `discard_message`), reads `source[0]`, atomically exchanges
  `receiver->message` with the new packet, clears `source[0] = nil`, disposes
  any overwritten packet via `transfer.discard_message(previous)`, and calls
  `receiver.send(receiver.handle)`. Pre-exchange rejection leaves the pending
  slot unchanged and discards any encoded copy natively. Caller-owned endpoint
  units and a retained `TransferValue` policy remain available, but a direct
  manual-handoff hook may already have detached its resource during encoding;
  rejection does not roll back that hook. For recoverability after rejection,
  construct and retain `TransferValue.from_value(resource)` for a manual handoff
  before sending the policy. Clearing the caller's raw slot before any release
  callback or status conversion ensures that once the atomic exchange commits,
  the slot owns the allocation even when `uv_async_send` returns a negative
  status and `check_status` raises `OperationError` (`"async.send"`).
- **Persistent reader state (`ReceiverReader`)**: `receiver()` allocates the
  Receiver's only reader state once: a `ReceiverReader` with an empty
  `task`, a `notified` bit, one `ResumeToken("async.Receiver.wait")`, and one
  `withdraw` cancellation action (`reader.task = nil`). The reservation is the
  reserving Task's identity in `reader.task`, so `wait()` allocates no reader
  record, token, or closure. Clearing `task` on release also drops the
  Receiver's reference to a finished reader Task.
- **Wake-only callback and direct slot retention (`Receiver:wake`)**: `Receiver`
  does not copy or decode payloads in its libuv callback. Its callback
  (`Receiver:wake()`) returns unless `reader.task` is reserved and
  `reader.notified` is clear; it then marks `reader.notified = true` and
  requests a deferred wake via `task:resume(reader.token)` (resetting
  `reader.notified = false` if `resume` raises). The owned
  `titan_async_message` remains in `self.native.message`—including while the
  reader's deferred wake is queued in the Runtime ready FIFO—until `wait()`
  takes it. Replacing or closing the slot before that take disposes unread
  packets directly in C through `transfer.discard_message`.
- **Single-reader reservation, direct raw-slot decode, stale wakes, and
  cancellation (`Receiver:wait`, `receiver_take_native`)**: `wait()` requires a
  running Task, rejects competing callers when `reader.task ~= nil`
  (`"receiver already has a waiting reader"`), registers
  `defer if reader.task == task then reader.task = nil end`, and sets
  `reader.task = task` and `reader.notified = false` **before** inspecting
  `checkpoint()`, `self.native.closed`, or `self.native.message`. This prevents
  a second caller from barging ahead while the first reader's wake is queued.
  On each loop turn after `checkpoint()`, a fresh `local raw: foreign *void = nil`
  receives the packet from the pure foreign
  `receiver_take_native(self.native, raw)`, which checks `closed` (`2` ->
  `"receiver is closed"`), atomically exchanges `receiver->message` with `nil`,
  and stores the packet in `raw` (`1` when non-nil, `0` when empty). Only on
  status `1` does `wait()` install `defer transfer.discard_message(raw)` and
  return `transfer.decode_message(raw)`, following the
  [consuming raw-slot decode contract](transfer-library.md#consuming-raw-slot-decode):
  the guard follows the native take, so no later write reaches `raw`, and
  decode clears that actual local on return and before any error propagates.
  Decode errors consume the packet and raise from `wait()` with no lazy retry;
  `nil` and `false` return as ordinary data. When
  the slot is empty (initially or after a coalesced/stale wake), `wait()` clears
  `reader.notified = false` and calls `suspend(reader.token, reader.withdraw)`;
  a `send` between the empty-slot check and `suspend` either sets
  `reader.notified` on the loop thread or leaves a pending `uv_async_send`
  signal for the next loop turn. Cancelling the waiting Task runs `withdraw` to
  clear `reader.task` without taking or discarding an unread packet in
  `self.native.message`. The unconditional action is exact: `Task:cancel` runs
  a suspend cancellation action only while its Task is suspended under that
  action, cancellation is sticky, and nothing else releases the reservation
  while its reader is suspended. The cancelled reader then unwinds through a
  queued wake, so a successor may reserve first; the exit `defer` compares Task
  identity and leaves that successor's reservation intact.

### Receiver lifecycle and teardown

`receiver()` uses `ensure_runtime` without requiring a current Task or driving
the loop, permitting synchronous independent-state bootstrap (and rejecting
creation once `runtime.closing` or `runtime.exit_code` is set). Explicit
`close()` marks `native.closed = 1`, atomically takes and disposes any pending
packet via `transfer.discard_message` (`receiver_disable_native`), wakes any
waiting reader with `"receiver is closed"`, and initiates `uv.close` on the
handle. The Runtime's handle walk (`close_handles`) disables `Receiver` owners
before generic handle close, and `Receiver`'s GC finalizer (`receiver_finalize`)
calls `receiver_disable_native` to release any unread native packet during
Lua-state destruction.

An exported `handle()` does not retain its `Receiver` owner or the originating
Lua state. Applications must retain the receiver owner, withdraw handles, and
complete all in-flight `send` calls before `close`, Runtime shutdown,
collection, or state destruction. The atomic packet slot synchronizes concurrent
sends and reader extraction; it does not synchronize concurrent send-versus-close
races or authorize use of a handle after its owner's lifetime.

## Foreign workers

`run_foreign(f,arg)` is now a public-work-request adapter over ordinary await and
`uv.queue_work`. It rejects NULL f before submission. The worker runs only
`f(arg)` using raw native state; the loop-thread completion callback resolves nil
or rejects an OperationError labelled `async.run_foreign`, and protects unexpected
failures with fatal plus bare rethrow. The argument's owned storage remains in
the suspended caller through completion.

Worker code must not inspect host Titan/Lua owners, call the Lua API on the
hosting state, raise into its frames, or resume its Tasks. The
[independent Lua-state adapter](lua-library.md#independent-state-ownership)
exclusively owns a separate state and may execute Lua and independently
initialized Titan modules in it. That state's collector never receives a host
GC object; copied values, opaque snapshot bytes, and borrowed addresses cross
the boundary. Synchronization of shared native bytes remains the caller's
job. The libuv worker pool is shared with other native work and async adds no
new queue or thread policy. Ordinary cancellation never detaches the accepted
job.

The UV binding embeds an ordinary `uv_work_t` and a separate native callback
data structure in one stable request owner. Before queueing, it sets
`uv_work_t.data` to the embedded callback data, containing the C worker,
argument, and owner address. The worker reads only the C worker and argument;
the terminal callback uses the owner address on the loop thread. Neither the
data pointer nor its payload is changed while native work is pending. Terminal
delivery clears the old worker and argument before calling user code, allowing
that code to requeue the request without later old-state cleanup. The public
`work_t:get_data`/`set_data` value remains a separate GC-traced slot and may be
changed while work is pending.

The named foreign-work registrar and callback use a private per-job context in
the public work request's traced data. They detach the old association before
settlement and retain the captured operation number through fatal reporting.
Ownership-retiring foreign work uses public `uv.queue_work` registered through
`await_cleanup_with`. SQLite's context and UV argument owner retain its packet.
The old source-private `uv.run_foreign_cleanup` and its router
variant are unnecessary. Adapters still retain arguments, interpret their native
results, and dispose of unpublished result resources lexically.

`timer.sleep` owns a dedicated one-shot timer and explicit ResumeToken, with
named typed callbacks. Firing and cancellation coalesce through Task.resume;
a deferred cleanup Completion waits for native timer close before returning
or finishing cancellation unwind. It does not construct a Ticker/subscription.
Ticker remains a persistent coalescing subscription and uses the typed close
callback only for ownership retirement. The public timing/cancellation
contracts remain unchanged; neither promises an exact libuv phase.

`BufferedSubscription:has_pending()` reads the Core's item count and liveness
without taking the reader reservation or consuming values. It includes terminal
states and counts nil/false payloads correctly; adapters use it as an observed
input snapshot, not a polling or readiness primitive.

## Shutdown and process control

A first callback/driver failure sets closing, latches the original Error, and
stops an active UV run. A separate once-only pass cancels remaining Tasks. Task
cleanup may need native requests or queued continuations, so a blanket handle
walk waits until all Tasks and ready entries have retired. Accepted callbacks
remain authoritative. A failed shared wake leaves ready entries rooted; the
outer driver drains a bounded recovery batch before blocking on unrelated
native handles, preserving the first failure. Pending native waits still await
their real completion. Borrowers must not manipulate Runtime-owned handles.

A negative `async.native_retirement.retire` result is a separate driver-return
path, not this ordinary callback-failure teardown. It leaves the active Runtime,
native barrier and pending Task intact for explicit same-context `loop()` retry;
see [negative-status retry](#explicit-negative-status-retry).

When native loop liveness is false and the ready queue is empty but Tasks
remain, the driver snapshots `(Task, exact Wait, epoch)`, requests shutdown
cancellation, and unwinds only an unchanged pending Wait (or unchanged absent
Wait) with the same epoch and no queued continuation or explicit resume.
Cleanup can settle another captured Wait or install a newer one; the
snapshot must not retire those changed/settled waits. This permits useful
lexical cleanup while avoiding a stale Task-only orphan snapshot.

Once no Tasks remain, `close_handles` closes the Runtime's `ExternalBridge` (if
initialized) and `uv.walk` closes remaining non-closing handles (disabling live
`Receiver` slots before closing their async handles). The
driver continues native callbacks and checks initialized inactive handles as
well as native liveness before `uv.loop_close`. Immediately after successful
`uv.loop_close`, it detaches and invokes
`add_close_listener` registrations in order with `closing` set. These callbacks
run outside Tasks and cannot yield or start work; domains may release native
objects after their underlying handles are known retired. A live bit permits
idempotent removal, including removal of a later detached registration. Errors
are caught individually and the first is retained unless an earlier Runtime
failure already exists. The callback pass cannot call `uv.stop` on the closed
loop. After notification, the driver clears the active Runtime and then
rethrows its first failure with the preserved raw trace. A subsequent run can
create a fresh Runtime. Native handle discovery and
ownership remain in UV; the generic listeners are not a domain-resource registry.

OS descriptors and native objects returned by workers are not automatically
libuv handles. Their lexical/domain owners must close or dispose of them.
Closing a process watcher does not kill or reap the process.

`request_exit(code)` obtains the current Task, records only the first code,
unbinds the Runtime's UV transfer loop before cancellation can enter cleanup,
cancels every unfinished Task, and raises the caller's retained cancellation.
The separate closing flag remains unchanged; accepted cleanup awaits and
native callbacks still retire through the ordinary driver.
The standalone bootstrap returns that code after ordinary cleanup. `run` refuses
to create new Tasks once exit is requested. A manual Lua/Titan host retains
control after its loop call; this operation does not call process-wide C exit.

## Startup policy

Async initialization owns the Unix SIGPIPE policy through an OS-only native
helper: change only a default disposition to ignored, preserve ignored/custom
handlers, and translate any native error through the public UV API. UV itself
is a general low-level binding and does not install async's process policy.

The public idempotent `uv.setup_process_args()` reads the argc/argv registry
published by a generated entrypoint. Async invokes it during initialization,
before construction of main's Titan argument Array, including when
`--no-uv-bootstrap` skips only invocation of the hook. A Lua host without those
entrypoint arguments simply has nothing to set up. Argument setup does not
create or drive a Runtime.

Async installs the private main bootstrap hook. It schedules main as an ordinary
Task, drives the Runtime until every Task and native cleanup has retired, then
returns the first requested exit code, main's successful integer, or failure
status. Explicit-drive clients continue to use `--no-uv-bootstrap` and pair
`run` with `loop` themselves.

### Supervised error handoff

The public `async.Error:raise()` method uses the existing runtime error-handoff
helper: install the captured trace with the runtime's pinned-trace marker, then
raise the original value. Domain supervisors can retain an ordinary `Error`
carrier during cancellation-insensitive cleanup and propagate it after abort
and drain without losing child-operation frames or reporting an uncaught
internal worker failure. This adds no new Lua/native boundary.
