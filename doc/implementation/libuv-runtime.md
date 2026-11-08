# The async continuation runtime

`titan.async` (the `titan/async/` folder module) implements Tasks, generic
waits, cancellation, subscriptions, cross-thread external waits, coalescing
cross-state receivers, and shutdown. It uses only the public `titan.uv` module
interface. UV owns native allocations, callback roots, borrowed native data, and
the native loop boundary; extending it is covered in the
[extension guide](libuv-extension-guide.md). Timer, filesystem, networking, I/O,
OS, and SQLite adapters own their domain records and result/resource policies.

Adding an async operation adds no scheduler variant. A registrar expresses its
one native submission and receives a typed `Completion` together with its exact
operation number.

## Module and type ownership

`Error`, `OperationError`, `ResumeToken`, `CancellationReason<|B|>`,
`TaskStatus<|A,B|>`, and `Task<|A,B|>` are declared in `titan/async/async.titan`; UV
declares none of them. `titan.transfer` owns `TransferValue` and the native
packet format ([transfer policy](transfer-library.md)). Async re-exports
`TransferValue` as a transparent alias and owns `Receiver` and `ExternalWait`.
`async.send` and `Receiver:wait` move `titan_async_message` packets; `titan.lua`
uses its own `titan_lua_value` carrier
([Lua chapter](lua-library.md#cross-state-transfer)).

The folder's main, `async.titan`, is shared by every target. It holds the
public Task, wait, combinator, channel, and subscription surface and the
scheduling core. The native contributors hold the native-only parts:
`runtime.native.titan` the libuv backend (loop acquisition and Lua-state close,
the shared wake timer, the libuv-typed await helpers, the driver `loop`, and
`version`), `external.native.titan` the external wake bridge and
`ExternalWait`, `receiver.native.titan` the cross-state `Receiver`, and
`foreign.native.titan` `run_foreign`. On the browser target,
`runtime.browser.titan` is the [browser driver](#browser-driver) and
`external.browser.titan` keeps `ExternalWait` as an opaque record; the
`receiver` and `foreign` families have no browser member and are dropped
([target source selection](target-source-selection.md#the-resolver)).

The scheduling core reaches libuv and native retirement only through seams that
the native contributors define. Natively, `Runtime.backend` is a `Backend`
record holding the loop, the wake timer, the lazily created external bridge, and
the releases of abandoned `run_foreign` jobs; `new_backend` creates it and
`start_backend` acquires the loop after `new_runtime` registers the Runtime's
finalizer. `unbind_backend`, `stop_backend`, and `cancel_request` hold the
transfer-loop unbinding, `uv.stop`, and the `uv.cancel` of a cancellable wait;
`Request` is the registrar result type (`uv.req_t`); `arm_ready` arms the shared
wake; and `initialize_backend` performs the root initializer's process setup
([startup policy](#startup-policy)). A cleanup barrier is reached through
`ExternalWait` methods (`check_cleanup_binding`, `bind_cleanup`,
`unbind_cleanup`, `admit_cleanup`, `rollback_cleanup`, `designates`,
`retired_natively`, `complete_retirement`, `poll_retirement`,
`notify_if_ready`, and `unaccepted`), so the core reads no `ExternalWait` field.
`await`, `await_cleanup`, and `suspend` yield through `await_registered`; the
libuv-typed `await_with`, `await_cleanup_with`, and `await_cancellable_with`
yield directly. The driver's per-Task emergency recovery is the shared
`recover_task`, and `drain_ready(runtime, available)` dispatches at most the
first `available` queued entries, which natively is the current `ready_count`.

Tasks use tagged `coroutine.Coroutine` control transfer. Async routes its yields
with one private tag (`ASYNC_TAG`); Coroutine keeps its own public and native
ownership contract ([coroutines](coroutines.md)). `coroutine.running()` returns
the public Coroutine record, never a Task.

The private layers are:

| Owner | Responsibility |
| --- | --- |
| `Runtime` | The per-target `backend` (natively one `uv.loop_t`, the zero-delay `wake` timer, the lazily created `external` bridge, and `abandoned_work`); the intrusive ready FIFO (`ready_head`/`ready_tail`/`ready_count`, linked through `Task.ready_next`); sparse `tasks`; `current_task`; `driving`/`closing`; the first `failure`; `exit_code`; close listeners; and `retirement_error`, the native capability whose negative status awaits an explicit retry. |
| `Task` | Coroutine `root`; scalar `phase` and cached `state` snapshot; checked `epoch`; queued-continuation fields; sticky `cancel_value`; current `wait` and reusable `completion`; terminal listeners; explicit-suspension state; cleanup binding (`cleanup_start`, `cleanup_active`, `cleanup_wait`); and the pending terminal outcome (`terminal_kind`/`terminal_value`/`terminal_trace`, `root_done`). Terminal admission is separate from root and cleanup execution. |
| `Completion<\|C,T,E\|>` | One reusable cell per Task: context, registrar, Task, captured epoch, policy, phase, outcome kind and payload, and the optional accepted request. `Wait` is the all-`value` type alias for the same record. |
| `ExternalBridge` | The per-Runtime `uv.external_wake_t`, the `waits` Map from 64-bit identity to `ExternalWait`, the monotonic `next_identity`, and `closed`. |
| `ExternalWait` | Reserved target and identity; closure registrars, or C-ABI registrars and context in its embedded `titan_async_retirement` cell plus a traced `native_owner`; the attached Completion and epoch; the bound cleanup Task; and separate `used`, `awaited`, `close_requested`, `registered`, `notified`, and `retired` state. |
| Subscription `Core` | Queue with explicit count, terminal state, one reserved waiter, producer actions, and the cleanup drain capability. |
| Public UV owner | Native request/handle storage and callback roots until its native terminal boundary. |
| Domain owner | Resources obtained from native completion, facade state, sharing rules, and lexical cleanup. |

Suspension epochs and the ready queue belong to async. UV has no Task table,
scheduler queue, or request introspection that could recover a Task.

## Driver and registration trampoline

`async.loop()` and the standalone bootstrap are the only drivers of the
async-owned loop. `loop()` requires the Lua main thread and rejects reentry and
calls from a running Task. Independent low-level clients may drive their own
public UV loop. One Task continuation runs until it yields, returns, or raises;
no loop callback interrupts it. The Runtime sets `current_task` only around
coroutine entry and clears it before registration and terminal notification.

`run(func)` roots a ready Task and queues a `READY_START` entry. Yields,
correct-token resumes, and peer-Task settlements use the same FIFO:
`enqueue_ready` links an entry and `drain_ready`, called from the `ready_tick`
timer callback, dispatches it. The zero-delay `wake` timer is armed only while
work is queued, and `ready_tick` recovers its Runtime from the timer's traced
data. The public `run<|A,B|>` result and the Runtime's all-`value` view are the
same Task owner.

`enqueue_ready` arms the wake before it changes any node, so a failure leaves no
half-queued entry; only nonallocating field writes follow. Each `drain_ready`
call snapshots the queue count, capped at `READY_BATCH_LIMIT` (64). It pops and
clears each node before entering a continuation and keeps local copies of the
entry's kind, epoch, and exact Wait, so a continuation that requeues its own
Task is not erased by cleanup of the old node. An entry whose Task finished or
whose epoch or Wait changed is skipped but still consumes its batch slot;
entries queued during the batch wait for the next callback. If dispatch fails,
undispatched entries stay linked and rooted and `ready_tick` rearms the wake.

`async.yield()` yields the module marker `YIELD_TAG` without a Wait; the driver
checks admission, advances the epoch, and queues `READY_YIELD`. Every admitted
suspension advances the Task's epoch in `begin_suspension`, which raises
`"async Task suspension epoch exhausted"` at `LUA_MAXINTEGER` instead of
wrapping. A Task bound to a native retirement capability (`cleanup_wait`)
reserves that final epoch for its one designated owner-cleanup wait: cleanup is
active, the policy is `WAIT_CLEANUP`, the context is the bound capability, and
the registrar is `start_native_retirement_wait`. Every other suspension of such
a Task stops at `LUA_MAXINTEGER - 1`. See
[native retirement barriers](#native-retirement-barriers).

Each `_with` await prepares the Task's Completion (`completion`) and yields it
with the async tag. The driver checks the cancellation policy, advances the
epoch, installs the cell as `task.wait`, and calls the registrar with the cell
and the captured epoch. Registrars return `uv.req_t?`. A named registrar
receives the nominal Completion, so one erased native callable shape serves
every context type without an adapter. The callback-triple facade (`await`,
`await_cleanup`, `await_cancellable`) wraps the same core through
`old_start`/`old_void_start`. During registration the Task is waiting and
`async.running()` is absent. `current_loop()` borrows the active loop without
creating or driving it. `is_closing()` reads the active Runtime's `closing` flag
(raising when no Runtime is active) with no Task or cancellation check, so
synchronous domain construction can reject shutdown without adding an await.

`checkpoint()` gives synchronous domain paths the await admission order without
yielding or allocating: running Task, then sticky cancellation, then Runtime
failure (`closing`). Domain callers keep their own validation, reader
reservation, and lazy-start ordering around it. Cleanup paths are exempt from
ordinary admission.

`run_with_cleanup(body, cleanup, final_wait?)` constructs its Task with
`cleanup_start = true` and eagerly allocates the Completion before queueing
`READY_START`, so cancellation-shielded cleanup never needs its first Completion
allocation after cancellation. A cancelled ordinary `run` Task finishes without
entering its coroutine; a cleanup Task is still entered through its wrapper,
which installs the cleanup `defer` (setting `cleanup_active` and calling
`cleanup(task.cancel_value)`) before `checkpoint()` and `body()`. The wrapper
records a body error in the pending terminal outcome before cleanup runs.
Native retirement is protected by a preaccepted Task-level barrier, never by
successful entry into the body or cleanup. `final_wait`, when present, must be a
live, unused, unbound native-retirement capability from
`prepare_native_retirement` in the same Runtime
(`ExternalWait:check_cleanup_binding`); closure-registered waits are rejected,
and validation repeats after the constructor's allocations. See
[constructor admission](#constructor-admission-and-ownership).

The usual Completion lifecycle is:

```text
REGISTERING -- accepted, no inline result --> PENDING
REGISTERING -- inline resolve/reject -----> SETTLED --> RETIRED
PENDING ----- terminal resolve/reject ----> SETTLED --> RETIRED
PENDING ----- associated fatal callback ----------------> RETIRED
```

(The constants are `WAIT_REGISTERING`, `WAIT_PENDING`, `WAIT_SETTLED`, and
`WAIT_RETIRED`.) Inline settlement records the outcome and returns to
registration. Only after registration returns does the trampoline retire that
Wait and resume the Task, which avoids recursive coroutine entry for
synchronous rejection or immediately available data. A registration exception
retires its Wait and is injected at the await expression. An adapter must not
throw out of registration after native acceptance while a callback still
borrows released state; partial native rollback is the adapter's
responsibility.

Terminal settlement outside a Task can deliver immediately. Settlement from a
different running Task first accepts a deferred queued wake and then commits
the settled state with nonallocating field writes; if scheduling fails, the Wait
stays pending so retry or shutdown can still address it. Settlement from a
finalizer (`ffi.titan_in_finalizer(L)`) takes the same deferred path, because
`Coroutine:resume` raises there and an inline delivery would publish the Task
as failed with its root still suspended. `fatal` from a finalizer records the
Runtime failure, accepts a `READY_DELIVER` wake for the exact Wait, and then
commits `OUTCOME_FATAL` with the supplied error, detaching the consumed
request; delivery retires and releases the Wait, so the Task gets its own
operation's error rather than `runtime.failure`. Delivery
checks that the Wait is SETTLED, is still exactly `task.wait`, and has the
current epoch; it clears the request, Wait, token, and explicit-suspension
state before entering the continuation. Duplicate settlement raises rather than
mutating an unrelated wait.

Completion reuse checks both owner and epoch. Preparation temporarily sets
epoch zero, which no public method accepts, and registration publishes the new
number. A callback captures this number at registration; looking up the current
wait later would confuse an old callback with a successor. Retirement
materializes the public tagged result, then clears context, registrar, request,
and payload before resuming the coroutine. `wait_result` returns the shared
module constants `SUCCESS_NIL` or `CANCELLABLE_SUCCESS_NIL` for a nil success,
because unions are immutable and the Runtime never compares result identity;
every other outcome constructs a fresh union. Terminal Task cleanup clears the
cached cell even if result allocation failed after `task.wait` was removed, so
a retained completed Task or stale Completion retains no old operation context.

`context(number)` is available only for the matching, unretired operation.
Callbacks and partial-acceptance rollback must root any context they need after
settlement or registration failure themselves; retiring a wait does not prove
that native work ended. A private UV data slot may hold a domain context plus
the Completion and number; terminal callbacks copy these to local roots and
detach the old slot before settling. A shared stream cannot supply one
completion slot to overlapping writes. Legacy callback-triple closures raise
`"async operation already settled"` on duplicate settlement (`legacy_settle`).

## Browser driver

On the browser target `runtime.browser.titan` replaces the libuv backend. It
imports `titan.browser` and drives through its low-level
[drive interface](../language/standard-library-browser.md#driver-interface-low-level);
the loader side (relinquish import, turn source, admission, queue, disposal
and exit latch) is in [the browser target](browser-target.md). The browser
`Backend` holds one field, `relinquished`, true while the driver is suspended
in `browser.relinquish`; `Request` is `browser.BrowserRequest`.

The seams have browser bodies:

| Seam | Browser body |
| --- | --- |
| `new_backend` | `Backend {relinquished = false}` |
| `start_backend` | raises `"async Runtime is unavailable in a non-owner browser state"` unless `browser.is_owner()` |
| `arm_ready`, `stop_backend` | `browser.wake()` while `relinquished` (only Titan code that runs during a relinquished drive can queue work then) |
| `unbind_backend` | nothing: no transfer loop |
| `cancel_request` | `request:cancel()`; unreachable, because no browser member creates a cancellable wait |
| `runtime_finalize` | the native guards, `retire_tasks_at_close`, and `active_runtime = nil` |
| `initialize_backend` | in the owner state only, registers `spawn_call` and `shutdown_call` through the reserved `titan:driver` binding |
| `ExternalWait` methods | raise `"internal error: ExternalWait has no browser constructor"`: no browser value of the type exists, so every `cleanup_wait` and `final_wait` is nil |

`loop()` keeps the native entry rules (main thread, no current Task, no
second drive), first refuses a non-owner state, then calls
`browser.drive_begin()` and runs turns until no Task and no ready entry
remain:

1. After a failure, the shared per-Task recovery (`recover_task`) and
   `cancel_shutdown_tasks`.
2. `available = ready_count`, then `browser.deliver()` (request settlements,
   listener events, notifications and queued calls present when it starts,
   each outside any Task, then the deferred releases), then
   `drain_ready(runtime, available)`. Taking `available` before delivery puts
   a Task that a delivered completion resumed and that then yields in a later
   turn. Delivery or drain failures go to `fail_runtime`.
3. With no Task and no ready entry, `notify_runtime_closed`, clearing
   `active_runtime`, and re-raising the first failure, as natively.
4. Otherwise `browser.relinquish(ready_head == nil)`: a turn when work is
   ready, else a wait. `RELINQUISH_DISPOSING` cancels every unfinished Task
   with `"instance disposed"` (`cancel_for_disposal`; it repeats on each
   disposing relinquish, so Tasks that cleanup starts are cancelled too).
   `RELINQUISH_IDLE` records `"async Runtime became idle while Tasks were
   waiting"` unless a failure is already recorded, then runs the shared
   `unwind_orphans`.

A `defer` clears `driving` and `relinquished` and calls
`browser.drive_end(runtime.exit_code)`, which latches the instance as exited
when an exit was requested; the bootstrap still returns the exit code.

The loader reaches two entries through `titan:driver`. `spawn_call(target,
settle, ...)` implements `instance.callTask`: it starts the target as a Task,
reports `("started", cancel)` through the `settle` handle, then from a
terminal listener one of `("succeeded", result)`, `("failed", message,
trace)` (message by `error_text`), or `("cancelled", reason)`, and closes
`settle`. A Task cancelled while the Runtime has an exit code reports
nothing, so the drive's exit latch rejects the call with the exit status. It
drives with `loop()` unless a drive is already running, in which case it ran
as a queued call. `shutdown_call` serves `dispose()` with no drive active: it
cancels every Task for disposal and drives their cleanup.

## Wait policies and native ownership

The result unions use explicit tags. Payload truthiness never selects success,
error, cancellation, or completion; nil and false are valid success values.
`CancellableResult` exposes the current Task's all-value cancellation reason.

| Policy | Before registration | Accepted request | At terminal delivery |
| --- | --- | --- | --- |
| Ordinary | Inject pending cancellation instead of registering. | Keep native ownership; no implicit `uv.cancel`. | Pending cancellation replaces success/error with the raised reason. |
| Cancellable | Return tagged pending cancellation instead of registering. | Keep the returned `uv.req_t`; `Task:cancel` attempts public `uv.cancel`. | Still await the callback, then return tagged cancellation if pending. |
| Cleanup | Register even during cancellation or fatal shutdown. | Do not cancel ownership retirement. | Deliver the ordinary result; an unexpected fatal exception still raises. |

Cancellable registration returns nil only after inline settlement; an unsettled
nil return is a protocol error. Native `uv.cancel` success or failure never
retires the Wait or releases borrowed storage; only the request's terminal
callback does. Ordinary and cleanup registrations may return a request view or
nil, and their policy never cancels it. Their native owners stay retained by
public UV and the suspended lexical state.

Task cancellation retains its first reason and overrides final Task success or
failure. Cleanup shielding changes submission and result delivery, not this
terminal policy. During fatal shutdown, new ordinary and cancellable operations
receive the Runtime failure; cleanup operations stay available to retire
ownership.

## Operation-local fatal callback association

Every Completion exposes `fatal(number, error, trace)`; the callback-triple
facade supplies a closure for it. This is an out-of-band exception channel, not
generic rejection and not a native cancellation handle. An adapter protects its
terminal callback, copies borrowed or acquired results into owned state,
performs explicit request cleanup, calls fatal from `catch`, and then uses bare
`raise`, so the low-level boundary still sees the original exception
([recipe](libuv-extension-guide.md#one-shot-task-adapter)).

Fatal may be invoked only outside a running Task and only after the native
terminal callback has been consumed with safe callback-local ownership. It
cannot abandon outstanding native work. Expected native or domain errors use
typed reject. Shared or multi-shot sources finish their local rollback or
transfer before raising and rely on subscription-waiter cancellation and
lexical domain cleanup instead.

For a pending exact Wait, fatal retires it, clears its request and explicit
suspension state, records the Runtime's first error and trace, and cancels the
other Tasks. The associated Task is excluded from the newly imposed shutdown
cancellation, so injecting the original error produces its normal failed
status; a reason already pending on that Task stays sticky. The exception
enters the Task immediately, so lexical cleanup can progress even if another
accepted native operation depends on it.

During REGISTERING, fatal stores a fatal outcome and leaves advancement to the
registration trampoline. After SETTLED or RETIRED it only records Runtime
failure; it never replaces the settled payload or touches the Task's new Wait.
A stale number on a reused cell likewise only records failure (or raises inside
a Task) and never treats the successor's request as consumed. The first-error
latch is separate from the once-only shutdown cancellation pass. When the
driver is running, latching a failure calls `uv.stop` so the outer driver can
cancel and unwind Tasks before waiting on unrelated accepted work.

An arbitrary unprotected callback supplies no Wait association. The driver
handles its low-level error boundary and retains native owners but cannot
identify a consumed request's Task early. That is why custom one-shot adapters
must implement the explicit fatal protocol. It is not universal recovery from
every foreign-callback mistake or memory failure.

## Explicit suspend, Task status, listeners, and combinators

`SuspendCancelAction` is `function (): ()`. `suspend` uses its `ResumeToken`
as Completion context and the named registrar `start_suspend`. It stages the
cancel action first; `start_suspend` publishes the token (`suspended`,
`resume_token`) only after admission. A `defer` clears the staged state if
construction or admission fails.

The interval before publication contains GC safepoints, in the suspending Task
and in the driver, so a finalizer can wake or cancel a waiter that cannot yet
be resumed. One protocol covers it:

- **Wake.** `Task:resume` checks the Task's state before the token. While the
  Task is `TASK_RUNNING`, or its current Wait is still `WAIT_REGISTERING`, it
  stores any token in `latched_token` (the latest call wins) and never
  enqueues, so a registration keeps one settlement owner. Otherwise a different
  token raises the mismatch, a pending wake coalesces through `resume_pending`,
  and an exact token of a parked explicit suspension enqueues `READY_RESUME`
  once. A ready Task, a pending native wait, a queued yield or delivery, and a
  finished Task therefore raise.
- **Latch lifetime.** Only `start_suspend` reads the latch: after `done:context`,
  its last safepoint, it publishes the token and settles inline when
  `latched_token` equals it. `advance_task` clears the latch at the top of each
  run and `finish_task` clears it at termination, so a latch that the next
  suspension did not consume (another token, a native or external wait, a
  yield) is discarded. `clear_suspension` leaves it alone: the lexical defer of
  a delivered `suspend` runs after the Task is running again and must not erase
  a latch accepted since then.
- **Cancellation.** `Task:cancel` stores the sticky reason and acts only on an
  accepted, parked Wait (`WAIT_PENDING`): it cancels a cancellable request, and
  for a published explicit suspension it runs the cancel action and resumes the
  token. A running or ready Task meets the reason at its next admission check.
  A Task whose Wait is registering meets it at the acceptance boundary in the
  trampoline: once registration returns, with no safepoint before the
  `WAIT_PENDING` commit, a published non-cleanup suspension with a reason runs
  its cancel action and settles the Wait, so the cancellation is injected as
  for one delivered later. This covers `start_suspend` and `start_external_wait`
  alike, and the cancel action runs once.
- **Delivery.** `deliver_wait` and the trampoline's inline delivery set
  `TASK_RUNNING` before `clear_suspension` and the Result allocation, so a wake
  at that allocation latches and is discarded instead of raising.

The Runtime cannot tell "about to suspend" from "running past a delivered
wait", so every waker follows the caller rule of the
[public contract](../language/async-io.md#scheduling-and-driving-tasks): make the
waiter discoverable before the last condition check, then either consume the
registration before `resume` or recheck the condition after every return from
`suspend`, and do not suspend on anything else in between. `async.channel` keeps
one token and a waiter slot per side, so its blocking send and receive publish
the slot and then loop while the buffer is still full or empty and the channel
is open; a stale latch therefore costs one extra suspension. Subscriptions use
a fresh token and a `notified` flag per wait, and `Core:wait` rechecks the
queue and terminal state after publishing its waiter. `Receiver:wait` reserves
before its take and loops. Their wakers call `Task:resume` directly.
Combinator listeners run only from terminal publication, which never runs in a
finalizer, because settlement and `fatal` from a finalizer are queued and
`runtime_finalize` calls no listener.

`Task:resume` checks token identity before any pending shortcut, so equal
source strings never authorize a different token. Completion retires the old
token before a new wait can be installed. Cancelling an explicit suspension
never enters the target Task inline. Terminal
publication (`finish_task`) clears the suspension, marks every listener entry
non-live, and then delivers them in order. Removal before that snapshot is
idempotent; removal during delivery cannot suppress a captured listener. Each
listener runs inside its own `catch`, so one failure does not stop later
listeners. Registering after termination does not replay the terminal event.

The scalar `phase` drives internal finished checks. `set_phase` clears the
cached `state`, and `Task:status()` builds a nonterminal snapshot on first
observation; later reads in the same phase share it, and later transitions
never mutate it. `finish_task` builds the terminal status once and delivers
listeners, and only after root completion and any native-retirement gate admit
the terminal outcome. The ready/running/waiting variants are unfinished and
succeeded/failed/cancelled are terminal; predicate booleans stay authoritative
for nil or false payloads. An uncaught Task exception is reported and stored as
an `Error` with the caught Lua error value and raw trace; it does not by itself
fail the Runtime. Raised nil follows the ordinary
[Lua error normalization](error-handling.md#runtime-trace-model).

`advance_task` resumes the root through `resume_root`, which calls the public
[`Coroutine:transfer`](coroutines.md#entry-function) and passes its
`(failed, value, trace)` tuple back to `advance_task`. A root that dies with
an uncaught error therefore returns its error and the coroutine's own trace
instead of raising. `resume_root` adds the driver's propagation trace, by
raising and catching the error locally once and appending the catch's
`traceback`, only when the failure will be reported: the Task has no
cancellation reason and has not already recorded a failure. A cancellation is
sticky and wins publication, and a `run_with_cleanup` wrapper has already
recorded its body's failure with the body's trace, so neither pays for a
propagation capture. `advance_task` records the returned trace for the
terminal candidate; its own catch still handles a raise from the switch itself.
Successful switches allocate nothing for the outcome. The native regression in
`spec/stdlib/titan/async/tests/task_test.titan` pins the resulting capture
counts: one for a parked cancellation, two for an ordinary reported failure,
and one for an already recorded cleanup-body failure.

The 17 combinators (`join`, `join_two`..`join_five`, and
`any_`/`race_`/`all_` at arities two through five) keep independent
result/cancellation positions per operand. Fast paths inspect already terminal
operands in argument order; suspended paths select by delivered listeners. No
combinator cancels losing operands, every operand is checked for
self-dependency, and lexical listener removers cover cancellation and other
unwinds.

`async.channel` keeps a bounded circular buffer with an explicit count, at most
one blocked sender and one blocked receiver (a second raises), and discards
buffered items on close. A blocking operation occupies its waiter slot and then
suspends in a loop while the buffer is still full or empty and the channel is
open, so a wake before the slot was published is seen by the check and a stale
latched wake costs one extra suspension
([explicit suspension](#explicit-suspend-task-status-listeners-and-combinators)).
Writer close is not automatic clean reader EOF; see the
[language chapter](../language/async-io.md#bounded-channels).

## Persistent subscriptions

`CoalescingSubscription` and `BufferedSubscription` each wrap one private
`Core`. It stores explicit count and first indices plus `Item` wrappers, so nil
and false remain present payloads. Buffered mode keeps FIFO order; coalescing
mode replaces the one unconsumed value. `Core:compact` moves the live suffix
only once the consumed prefix is large enough to pay for the copy, so indices do
not grow forever under partially drained traffic; the old queue stays owned
until replacement allocation and copy succeed.

A producer receives publish/fail/finish and returns prebuilt stop/close actions
(`SubscriptionActions`); it owns partial-registration rollback until that
return. Publish commits queue ownership only when wake acceptance succeeds. If
waking raises, publish restores the previous slot and count, and wake restores
its notified flag, so false or a synchronous exception leaves the resource with
the producer. Error/end terminal changes roll back on wake failure the same way.

One waiter reserves a Task/token pair and records whether it requests a batch.
Reads check competing waiters and pending cancellation before transferring any
item. Suspension uses the nonyielding exact detacher. After publishing its
waiter, `Core:wait` rechecks the queue and the terminal state, so a
notification before publication is seen there and one after it is latched
through `Task:resume` with the wait's fresh token
([explicit suspension](#explicit-suspend-task-status-listeners-and-combinators)).
A notification keeps the
reservation until that reader resumes or unwinds, so another reader cannot
steal its delivery. Cancellation only detaches that waiter; it does not stop the
source or discard its events. Both `has_waiter()` methods report this
reservation; domain admission checks use them instead of reading subscription
internals or assuming a scheduled wake has freed the slot.

Single-item result construction precedes removal from the FIFO. Batch result
and replacement storage construction precede wholesale detachment, and a
producer drain transfers a counted batch that the caller then owns. This
ordering leaves no gap where a native resource is neither queued nor held by
its consumer. The generic queue never disposes of an overwritten coalescing
value: resource-bearing events need buffered ownership or an explicit domain
policy.

Queued values precede error/end, while closed takes effect immediately. Stop
records idempotence, selects ended for a live queue, calls the nonyielding
producer stop once, and wakes through a `defer`. Close captures and arms
cleanup and final discard before any fallible stop/wake, marks the queue
closed, and then runs the producer close action, which may await cleanup and use
its drain to dispose of unread resources. A later close initiates nothing and
does not wait for the first call's cleanup.

The buffered controls are synchronous `BufferedSubscription` methods.
`snapshot_pending` copies the complete unread FIFO and returns its terminal
outcome (nil while live) without consuming entries or reserving a reader;
resource hooks use it to allocate snapshots before detaching native ownership.
`drain_if` runs a nonyielding, nonmutating predicate and detaches the entire
FIFO on any match; it is not a filter. `drain_pending` detaches regardless of
terminal state. `wake_batch` affects only an existing batch waiter, stores no
credit, and permits a live empty batch without ending the queue.
`has_pending` reads the count and liveness, including terminal states and
nil/false payloads, without reserving or consuming; adapters use it as an input
snapshot, not a polling primitive. A domain that removes the outcome reserved
for a notified reader must finish its terminal or control transition before
yielding back to that reader.

Domains keep their own sharing and error-priority rules. One watcher queue may
collect callbacks from several native registrations, hold a guard across
yielding classification, and detach a whole retirement-crossing batch. TCP reads
drain copied chunks before error/EOF; accept may need to close unread clients
before delivering a listener failure. These policies stay out of `Core`.

## External wake bridge

`ExternalBridge` and `ExternalWait` put every cross-thread readiness wait of a
Runtime on one [`uv.external_wake_t`](../language/uv/types.md#external_wake_t)
instead of a `uv.async_t` per wait. The native target phases, reference counts,
target cache, lock order, and close/detach rules belong to UV and are specified
in the [extension guide](libuv-extension-guide.md#external-wake-bridge). This
section covers ordinary waits: closure-registered `prepare_external_wait` and
`wait_external_native` with C-ABI registrars and a traced domain owner.
[Native retirement barriers](#native-retirement-barriers) use the same bridge
with a preaccepted lifecycle.

1. **Bridge.** `external_bridge(runtime)` lazily creates the bridge and calls
   `uv.external_wake_init`, which leaves the shared handle unreferenced. It is
   distinct from the scheduler's `wake` timer.
2. **Prepare.** `prepare_wait` calls `ensure_runtime()` (creating a Runtime
   without requiring a Task or driving it, and rejecting a closing Runtime or a
   requested exit), assigns the next identity, stores the owner in
   `bridge.waits`, and reserves an unreferenced target. Identities run from 1 to
   `LUA_MAXINTEGER`; after the last one `next_identity` becomes 0 and the next
   prepare raises `"async external wait identity exhausted"` instead of reusing
   an identity. An unused prepared wait never keeps an idle loop alive.
3. **Activate and register.** `start_external_wait` runs after the Task's tagged
   yield. It activates the target, which references the shared handle while any
   wait is active so `loop()` does not treat a Task waiting on another thread as
   an orphan. It then sets `registered` and calls `register_fn(target)` or the
   C-ABI `register_wait(context, target)`. A closure registrar returning
   `false`, or C status `0`, means already ready: the wait retires
   (`ExternalWait:retire` removes the map entry and unregisters the target) and
   resolves inline. C status `1` means linked. A negative status is a clean
   rejection raised as `OperationError` with operation
   `async.external_wait.register`. A raise runs `detach_domain` and `retire`.
   The `registered` latch lets only one cancellation or failure path call the
   domain unregister.
4. **Domain side.** The domain locks its own mutex and, when it must wait,
   takes a producer reference with `uv.native_external_wake_retain` before
   publishing the target in its waiter. Producers on any OS thread call
   `uv.native_external_wake_notify` and then `uv.native_external_wake_release`;
   they never touch Lua or GC state. Lock order is always domain mutex, then
   wake-core mutex.
5. **Drain.** On the loop thread `ExternalBridge:drain` copies up to 64
   identities per callback, looks each one up in `waits`, and calls
   `ExternalWait:notify`. Notify requires a live, unnotified owner whose
   attached Completion is still `task.wait`, `WAIT_PENDING`, at the captured
   epoch. Ordinary waits wake through `task:resume(token)`, cleanup waits
   through `enqueue_ready(task, READY_RESUME, done)`. No Task runs reentrantly
   from the native callback.
6. **Cancel and close.** Cancelling an active ordinary wait runs `cancel_wait`:
   `detach_domain` (domain unregister), then `retire` (target unregister, which
   drops the handle reference with the last active wait). `close_handles` calls
   `ExternalBridge:close` after all Tasks retire; it closes the remaining
   reservations and then the wake handle.

C-ABI ordinary waits add no native-retirement poll, prearming, cleanup
privilege, or terminal gate. `native_owner` stays traced through callback return
or unlink; retirement clears it together with the context and callback
pointers. The context is only borrowed, so the caller keeps its storage alive
for the whole await. Thread channels keep it in automatic storage of the
suspended stackful frame with a traced endpoint owner
([thread waiters](thread-library.md#shared-external-wake-suspension)).

Lua wrapper lifetimes (`ExternalWait`, `external_wake_t`, endpoint and Task
wrappers), in-flight transfer packet lifetimes, and native target/core
lifetimes are separate. The per-core target cache reuses only reference-zero
native storage and is not stale-handle protection.

## Native retirement barriers

This section is the generic contract. `Thread:task()` is its user; its
callbacks and owners are described in the
[thread implementation](thread-library.md#join-proxy-retirement-and-the-native-terminal-barrier).

`prepare_native_retirement(owner, context, register_fn, unregister_fn,
retire_fn)` constructs an `ExternalWait` with a traced `native_owner` and an
embedded, loop-thread-only `titan_async_retirement` cell
(`titan/async/async_receiver_native.h`). The cell holds the raw context, the three C
callback pointers, and `armed`, `ready`, and `status`. Native producers retain
only independent UV wake targets and cores, never pointers into this GC-owned
cell. The traced owner stays alive through callback return and committed native
retirement, including an OS join; queued native nodes and the context need their
own native lifetime through state close.

`retirement_poll_native` returns zero once `ready` is latched and returns a
cached negative `status` without retrying it. Otherwise it calls the native
`retire`, stores the status, and latches `ready = 1` only on zero. Callbacks are
C-only, nonraising, and nonyielding, and run on the loop thread with no
driver-held core or domain mutex. A callback may take its own domain mutex
briefly but must release it before blocking. It may block only for native final
completion after readiness, not for unfinished domain work, and no bound is
promised on that tail. Pending-path side effects and successful retirement must
be safe to repeat.

### Constructor admission and ownership

`run_with_cleanup` allocates the Task, coroutine, and Completion before
exclusive binding, then revalidates the capability, roots the Task, activates
its UV target, and calls native `register_wait(context, target)` before queueing
startup or returning. Result `1` means a retained, linked producer waiter. `0`
means monotonic already-finished readiness with no producer reference; native
retirement must then succeed before the Task is exposed, and a pending result
raises `"native retirement is not complete"`. A negative register result leaves
no native link or reference and raises a synchronous `OperationError`. The
operations are `async.native_retirement.activate`,
`async.native_retirement.register`, and, for an immediate constructor retire
error, `async.native_retirement.retire`; that last error closes admission
instead of exposing a Task for driver retry.

Before binding, failure leaves the caller's reservation intact. After bind and
arm start, rollback calls native unregister only for an admitted domain link,
removes the map entry and target borrow, consumes the UV registration, clears
the binding and context keepalives, and closes the capability. It removes the
unexposed Task without calling body or cleanup and without reporting an
unrelated unhandled Task failure. The original domain owner still owns any
running resource, and a closed capability cannot be reused. Closing an unused,
unbound capability releases the preparation without a Task or native domain
registration; it does not claim native resource retirement.

### Durable receipt, optional wait and logical close

In `ExternalBridge:drain`, a native capability is polled with
`retirement_poll_native` before any `ExternalWait:notify`. Zero latches
readiness before the target and map registration are removed. A negative result
keeps ownership, records `runtime.retirement_error`, and stops the current UV
run. A pending receipt remains recoverable as UV target PENDING/DELIVERED state,
independently of the current Task Completion and epoch.

The producer must notify only when the next poll can return zero or negative.
Once a target is DELIVERED, further notifications return without sending a new
wake, so a pending result after notification could strand a referenced wait.
Retire may also be polled from owner cleanup, terminal publication, and failure
recovery, so positive-path side effects must be idempotent. A completion
notification can arrive while the host body is still running.

Native capabilities are final-wait-only. Awaiting an unbound one raises
`"native retirement is not bound to a cleanup Task"`; body, peer, or
ordinary-wait use of a bound one raises
`"external wait is reserved for its Task cleanup"`. Only owner cleanup may call
`:wait_cleanup()`, at most once; its separate `awaited` flag allows this even
though constructor prearming set `used`. `start_native_retirement_wait`
attaches the exact Completion and epoch to the already-armed barrier without
registering another waiter. Latched readiness resolves inline; otherwise the
wait stays cancellation-shielded.

`close_requested` is a logical close of the user-facing wait view. Owner cleanup
may set it while retirement is pending, but neither `close` nor a failed
ordinary cleanup entry detaches the accepted native barrier. Further awaiting
raises `"external wait is consumed or closed"`; closing an active await raises
`"cannot close an active external wait"`; retired close is idempotent. Normal
successful retirement never calls domain unregister, because the producer
already unlinks and releases its reference when it notifies; unregister exists
for constructor rollback.

### Terminal admission and recovery

The wrapper records body return or error before cleanup, and the Task keeps the
pending terminal kind, value, trace, and `root_done`. `publish_terminal`
requires a completed root and a terminal candidate and then polls the barrier;
pending native retirement keeps the Task nonterminal. `finish_task` separately
refuses publication before `native.ready`, including after a startup or cleanup
entry failure. The original body error survives a later cleanup-entry error, and
sticky cancellation still has final precedence: a first explicit
`Task:cancel` after `root_done` but before native readiness overrides the
pending success or error. Neither `root_done` nor cleanup shielding makes a
nonterminal Task immune to cancellation, and accepting the reason does not
publish terminal status before retirement.

`ExternalWait:notify` queues `READY_TERMINAL` when the root and terminal
candidate are complete; an attached cleanup wait uses ordinary exact-epoch
ready delivery instead. Neither path resumes a Task from the native callback.

At every `loop()` entry and after each driver failure, a recovery pass over the
Runtime's Task inventory polls barriers whose target is notified, whose root is
done, or whose cleanup wait is attached. It is not a channel scan, a new
registry, or an idle-only orphan pass. It also requeues dequeued startup
(`READY_START`), settled delivery (`READY_DELIVER`), and a continuation with no
outstanding accepted operation (`READY_UNWIND`); none of these repairs detaches
the preaccepted barrier. Native readiness is latched before any fallible
notification or publication, so losing such an entry cannot lose the only
native receipt.

### Explicit negative-status retry

For an admitted barrier, a negative native retire status is not a failed or
completed Task. The driver raises `OperationError` with the unchanged native
code and operation `"async.native_retirement.retire"` while the same Task,
native context and token, target registration, Completion and epoch, and
Runtime stay owned. It does not perform final Runtime teardown, spin, join
unfinished work, or detach the resource.

A new explicit `loop()` call clears `runtime.retirement_error`, resets every
negative native status to pending (`1`), and polls the same capability before
blocking, even if its UV target was already DELIVERED and no new wake will
arrive. Each negative capability is therefore retried once per `loop()` call;
another negative status is cached and raised again. Zero permits normal ready
and terminal delivery. No registration, owner or Task recreation, or epoch reset
occurs.

## Cross-state receiver ownership

`Receiver` owns the public
[lossy cross-state notification](../language/async-io.md#cross-state-receivers)
boundary over the native `titan_async_receiver` struct
(`titan/async/async_receiver_native.h`): a borrowed `uv_async_t` address, the C send
function from `uv.async_send_function()`, an atomic `titan_async_message *`
slot (`titan_async_receiver_exchange`, `__atomic_exchange_n` with
`__ATOMIC_ACQ_REL`), and a `closed` flag. There is no mode discriminator,
subscription, native FIFO, or mutex. `Receiver:handle()` returns the address of
this native struct, never a Titan record or a public `uv.async_t`; a sender never
follows a remote GC pointer or enters the destination Lua state.

- **Send (`async.send`, `receiver_send_native`).** `send` rejects a NULL handle,
  encodes the candidate into a real local `raw = transfer.encode_message(...)`
  guarded by `defer transfer.discard_message(raw)`, and calls the foreign
  `receiver_send_native(handle, raw)` directly on that local. In one C interval
  it returns `2` for a closed receiver (leaving `raw` for the guard, and `send`
  raises `"receiver is closed"`), or exchanges the slot, clears the caller's
  `raw`, discards any overwritten packet with `transfer.discard_message`, and
  calls the C send. Clearing `raw` before any release callback or status
  conversion means that once the exchange commits, the slot owns the packet even
  if `uv_async_send` fails and `check_status` raises `OperationError`
  (`"async.send"`). Pre-exchange rejection leaves the slot unchanged.
  Caller-owned endpoints and retained `TransferValue` policies survive
  rejection, but a direct manual-handoff hook may already have detached its
  resource during encoding; see [manual handoff](transfer-library.md#manual-resource-handoff).
- **Reader state (`ReceiverReader`).** `receiver()` leaves `reader` nil, so a
  notification-only Receiver allocates no reader state. The first `wait()` calls
  `Receiver:create_reader`, which builds the one `ReceiverReader`: `task`, a
  `ResumeToken("async.Receiver.wait")`, and a `withdraw` action that clears
  `task`. It is published only once complete, and later waits reuse it without
  allocating. Clearing `task` on release also drops the reference to a finished
  reader Task.
- **Wake (`Receiver:wake`).** The `uv.async_t` callback copies and decodes
  nothing. When a reader is reserved it calls `task:resume(reader.token)`: a
  reader suspended on the token is resumed, and `Task:resume` coalesces
  repeated wakes through `resume_pending`, so the reader keeps no notified flag
  of its own. A running reader, including one about to suspend, gets the wake
  latched ([explicit suspension](#explicit-suspend-task-status-listeners-and-combinators)).
  In particular, when a decode hook, or a finalizer run at an allocation inside
  decode, closes the Receiver that is decoding its first-pass packet, `wait`
  returns the value it already took and its next call raises
  `"receiver is closed"`; the latch is discarded at the reader's next
  suspension. The packet stays in the native slot, including while the
  reader's wake is queued, until `wait()` takes it.
- **Wait (`Receiver:wait`, `receiver_take_native`).** `wait()` requires a
  running Task and rejects a second reader with
  `"receiver already has a waiting reader"`. It reserves `reader.task`
  **before** `checkpoint()` or any slot inspection, so a second caller cannot
  barge ahead while the first reader's wake is queued; its exit `defer` releases
  the reservation only if it still names this Task. Each loop turn declares a
  fresh `raw` local and calls
  `receiver_take_native`, which returns `2` (closed, raising
  `"receiver is closed"`), `1` (taken), or `0` (empty). On `1` it installs
  `defer transfer.discard_message(raw)` and returns
  `transfer.decode_message(raw)` under the
  [consuming raw-slot decode contract](transfer-library.md#consuming-raw-slot-decode);
  decode errors consume the packet and raise from `wait()` with no retry, and
  nil and false are ordinary data. On `0` it calls
  `suspend(reader.token, reader.withdraw)` and loops. Because the reservation
  precedes the take, a close between an empty take and the registration, from
  a finalizer in the reader or in the driver, latches its wake, and the next
  turn raises `"receiver is closed"`. A send in that interval leaves a pending
  `uv_async_send` whose callback runs only after the reader has yielded with
  its token published.
- **Cancellation.** `Task:cancel` runs `withdraw` only while the reserving Task
  is suspended under it, so the reservation it clears is that Task's. An unread
  packet stays in the slot. The cancelled reader unwinds later through its
  queued wake, so a successor may reserve first; the exit `defer` leaves that
  successor's reservation intact.

### Receiver lifecycle and teardown

`receiver()` uses `ensure_runtime` without requiring a current Task or driving
the loop, which permits synchronous independent-state bootstrap; it rejects a
closing Runtime or a requested exit. The handle's data roots the Receiver until
close completes. `Receiver:close()` disables the receiver
(`receiver_disable_native` sets `closed` and discards a pending packet), wakes a
waiting reader, which then raises `"receiver is closed"`, and closes the handle.
`close_handles` disables each live Receiver inside its `uv.walk` before closing
the async handle. The GC finalizer `receiver_finalize` calls
`receiver_disable_native` to release an unread packet during Lua-state
destruction; when the state closes before its Runtime retired, the Runtime
finalizer then closes the handle and the loop
([state-close retirement](#lua-state-close-of-an-unretired-runtime)).

An exported handle retains neither its `Receiver` nor the originating Lua state.
Applications must keep the Receiver reachable, withdraw the handle from every
sender, and let all in-flight `send` calls return before `close`, Runtime
shutdown, collection, or state destruction. The atomic slot synchronizes
concurrent sends with reader extraction; it does not synchronize send against
close or authorize use of a handle after its owner's lifetime. The two-phase
bootstrap used by independent states is described in the
[Lua chapter](lua-library.md#receiver-bootstrap-and-teardown).

## Foreign workers

`run_foreign(f, arg, abandoned)` is an ordinary await over public `uv.queue_work`
(`start_foreign_work`). It rejects a NULL `f` before submission. The worker runs
only `f(arg)` on raw native state; the loop-thread completion callback resolves
nil or rejects an `OperationError` labelled `async.run_foreign`, and protects
unexpected failures with fatal plus bare rethrow. The argument's owned storage
stays in the suspended caller through completion. The optional `abandoned`
release is used only at Lua state close, as described below.

Worker code must not inspect host Titan/Lua owners, call the Lua API on the
hosting state, raise into its frames, or resume its Tasks. The
[independent Lua-state adapter](lua-library.md#independent-state-ownership)
exclusively owns a separate state and may run Lua and independently initialized
Titan modules there; that collector never receives a host GC object. Shared
native bytes are synchronized by the caller. The libuv worker pool is shared with
other native work, and async adds no queue or thread policy. Cancellation never
detaches an accepted job.

A Lua state close unwinds a Task parked in `run_foreign` before its job
returns; the job finishes only later, in `runtime_finalize`'s drain. The wait's
own cleanup releases nothing that the job uses, and `start_foreign_work`
passes no `argument_owner`, so the argument's lifetime stays the caller's. An
`owned` argument is safe, because `lua_close` frees no object before the drain.
For other native state the caller passes `run_foreign`'s optional `abandoned`
release. `run_foreign` keeps a `waiting` flag that a normal return or `catch`
clears. Its `defer` finds it still set only when an unwind abandoned the wait,
and then, while the state closes, calls `ForeignWork:abandon`. That appends the
work to the active Runtime's `abandoned_work`, or releases at once when no
Runtime is active any more, because `runtime_finalize` has already drained.
`runtime_finalize` calls each queued release after `uv.loop_abandon` returns,
on the closing thread, when every accepted job has returned. A release may
therefore block on the worker pool, as closing an independent Lua state with
queued pool work does: no abandoned job holds a pool thread then, whatever the
pool size. Releasing on the job's own worker thread instead could deadlock
once abandoned jobs occupy every pool thread
([independent states](lua-library.md#host-state-close-during-run_async)).
SQLite's [abandoned operations](sqlite3-library.md#lua-state-close) still
release on the worker, because that release calls only SQLite. The public
contract is in
[foreign work at state close](../language/async-io.md#foreign-work-at-state-close).

The UV `work_t` owner embeds a `uv_work_t` and a separate `titan_uv_work_data`
(`titan/uv/work-data.h`) holding the C worker, argument, and owner address.
Before queueing, `uv_work_t.data` points at that struct. The worker reads only
the C worker and argument; the terminal callback uses the owner address on the
loop thread. Neither changes while work is pending. `work_deliver` clears the old
worker and argument before calling user code, so that code may requeue the
request. The public `work_t:get_data`/`set_data` value is a separate traced slot
and may change while work is pending.

The named foreign-work registrar and callback keep a private per-job context in
the request's traced data, detach that association before settlement, and keep
the captured operation number for fatal reporting. Ownership-retiring foreign
work uses public `uv.queue_work` registered through `await_cleanup_with`; for
example, SQLite's context and UV argument owner retain its packet. Adapters
still retain arguments, interpret native results, and dispose of unpublished
result resources lexically.

`timer.sleep` (`titan/timer.native.titan`) owns a dedicated one-shot `uv.timer_t`, a
`Sleep` record, and a `ResumeToken`, with named callbacks. Firing and
cancellation coalesce through `Task:resume`, and a deferred cleanup Completion
waits for native timer close before returning or finishing cancellation unwind.
A `Ticker` is a persistent coalescing subscription that uses its typed close
callback only for ownership retirement. Neither promises an exact libuv phase.

## Allocation profile

These properties of the current design were established by matched allocation
measurements (archived with the issue #196 benchmarks; see
[benchmark archives](benchmark-archives.md)). Keep them when changing the
scheduler or adapter APIs:

- `async.yield()` allocates nothing per call: it yields `YIELD_TAG` and queues
  the Task with no Wait.
- `Task:status()` allocates one nonterminal snapshot per observed phase and
  none for repeated reads in that phase; the terminal status is built once by
  `finish_task`.
- Each Task allocates at most one Completion, lazily on its first await
  (eagerly for `run_with_cleanup`), and resets it for every later wait.
- A wait allocates one result union when it retires, except nil success, which
  returns `SUCCESS_NIL`/`CANCELLABLE_SUCCESS_NIL`.
- `await_with`, `await_cleanup_with`, and `await_cancellable_with` with a named
  registrar and an existing context allocate no closure. A capturing or bound
  registrar costs one closure per wait, and a fresh per-wait context costs its
  own allocation. The callback-triple facade allocates three closures per wait
  (`old_start`/`old_void_start`), plus any callable adjustment at a typed call
  site, so new adapters should use the named form.
- `timer.sleep` allocates a native timer owner, a `Sleep`, and a `ResumeToken`,
  and no closure.
- Zero steady-state allocation does not make module loading, first Task
  creation, or Runtime teardown free.

Coroutine owners are finalizable: `coro_gc` (`titan/coroutine.titan`) destroys
the native coroutine but leaves the traced uservalue graph for the collector, so
reclaiming a finished or cancelled Task graph can take more than one full
collection. A heap-retention test should run at least two full collections
before comparing against a baseline. Fewer allocations also do not imply lower
elapsed time for every workload. The scheduler is cooperative: these
measurements establish no timer deadline, real-time, or starvation-freedom
guarantee, and the archived timer samples are interarrival intervals, not
deadline lateness.

## Shutdown and process control

A first callback or driver failure sets `closing`, latches the original
`Error`, and stops an active UV run. A separate once-only pass
(`cancel_shutdown_tasks`) cancels the remaining Tasks. Task cleanup may need
native requests or queued continuations, so the blanket handle walk waits until
all Tasks and ready entries have retired. Accepted callbacks stay authoritative.
If the shared wake fails, ready entries stay rooted and the driver drains a
bounded recovery batch before blocking on unrelated native handles, preserving
the first failure. Pending native waits still await their real completion.
Borrowers must not manipulate Runtime-owned handles.

A negative `async.native_retirement.retire` result is a separate driver-return
path, not this callback-failure teardown; it leaves the Runtime, barrier, and
pending Task intact for an explicit `loop()` retry
([negative-status retry](#explicit-negative-status-retry)).

When native loop liveness is false and the ready queue is empty but Tasks
remain, the driver latches the failure
`"libuv loop became idle while async Tasks were waiting"` if none exists and
runs `unwind_orphans`. That snapshots `(Task, exact Wait, epoch)`, requests
shutdown cancellation, and unwinds only a Task whose pending Wait (or absent
Wait) and epoch are unchanged and that has no queued continuation or explicit
resume. Cleanup can settle a captured Wait or install a newer one, and the
snapshot must not retire those; this allows lexical cleanup without acting on a
stale Task-only snapshot.

Once no Tasks remain, `close_handles` closes the `ExternalBridge` (if any) and
`uv.walk` closes the remaining non-closing handles, disabling live `Receiver`
slots before their async handles close. The driver keeps running native
callbacks and checks initialized inactive handles as well as native liveness
before `uv.loop_close`. Immediately after a successful `uv.loop_close`,
`notify_runtime_closed` detaches and invokes the `add_close_listener`
registrations in order with `closing` set. They run outside Tasks and cannot
yield or start work; domains may release native objects whose handles are now
known retired. A live bit makes removal idempotent, including removal of a
later detached registration. Each listener error is caught; the first is kept
unless an earlier Runtime failure exists. The listener pass cannot call
`uv.stop` on the closed loop. After notification the driver clears the active
Runtime and rethrows its first failure with the preserved raw trace; a later run
can create a fresh Runtime. Native handle discovery and ownership stay in UV;
the generic listeners are not a domain-resource registry.

OS descriptors and native objects returned by workers are not libuv handles;
their lexical or domain owners close or dispose of them. Closing a process
watcher does not kill or reap the process.

### Lua-state close of an unretired Runtime

A Runtime retires its loop only when `loop()` completes. A state can close while
its Runtime is still active: an independent-state bootstrap that created a
`Receiver` (or another Runtime-owned handle) and never drove the loop, or a
state whose driver raised and was never retried. The initialized `uv.loop_t`
lives in GC memory, but libuv's loop internals and watcher arrays are C-heap
allocations that only `uv_loop_close` frees, and registered handles still sit in
the loop's queues.

`new_runtime` therefore registers `runtime_finalize` before `start_backend`
calls `uv.loop_init`.
`lua_close` runs every finalizer before freeing any object, latest registration
first, so this finalizer runs after those of the Runtime's later Receivers
(which disposed of unread packets natively), its external wake owner (which
detached its core), and its Task coroutines (which withdrew parked native waits
and destroyed their stacks). During ordinary GC an active Runtime cannot become
unreachable, because the async module roots it through `active_runtime`. The
finalizer returns immediately for a retired or never-activated Runtime, even
while a newer Runtime is active, before checking the thread or touching libuv.
For the active
Runtime it requires the main thread, sets `closing` and `driving`, unbinds the
transfer loop, and then `retire_tasks_at_close` detaches every Task from its
Wait and explicit suspension and empties the ready queue. Each Task without an
armed native-retirement gate is
marked finished with a terminal `state` together with its `phase`, so
`Task:status()` stays consistent for a finalizer that runs later and still
holds the Task: `cancelled` with its
sticky `cancel_value` when a cancellation was requested but never delivered,
otherwise `cancelled(simple("async Runtime abandoned at Lua state close"))`.
A pending recorded body outcome is not published, because its cleanup never
finished. A Task whose native-retirement gate is still armed stays nonterminal:
when `cleanup_wait` is present with `native.ready == 0`, the predicate on which
`finish_task` refuses, the finalizer detaches its Wait and suspension but
publishes neither phase nor state, so a later finalizer cannot mistake an
unjoined `Thread:task()` proxy for a retired one. Unlike `finish_task`, this
calls no terminal listener. Keeping the Runtime active and closing
preserves shutdown admission, and `driving` makes a recursive `async.loop()` fail
immediately. It never runs `close_handles`, `Receiver:disable`,
`ExternalBridge:close`, domain unregister functions, or close listeners.

While `lua_close` runs, `async.run` and `run_with_cleanup` refuse to start a
Task, before `ensure_runtime` and before creating the root coroutine. They test
`titan_state_closing` (`titan/ffi.h`, `G(L)->gcstp & GCSTPCLS`) and raise
`cannot start a Task during Lua state close`. Such a Task could never run:
the loop is never driven again, and `runtime_finalize` would only report it
cancelled. Lua also ignores finalizer registrations during close, so the new
root coroutine's `coro_gc` would never run and its stack mapping would leak.

`new_runtime` makes the same test and raises
`cannot create an async Runtime during Lua state close`. Every
Runtime-creating path reaches it through `ensure_runtime` when no Runtime is
active: `receiver()`, `prepare_wait` (behind `prepare_external_wait` and
`prepare_native_retirement`), and the Task constructors. A Runtime created then
would have no `runtime_finalize`, so its `uv` loop would leak. That happens to a
finalizer that runs after `runtime_finalize` cleared `active_runtime`, or in a
state that never had a Runtime. The refusal does not cover operations on a
Runtime that is still active during the close.

An unwinding `defer` that hits either refusal gets the error, which is reported
as `error in coroutine cleanup (...)`. During an ordinary collection, a
finalizer, including the unwind of an abandoned coroutine, may still start a
Task on the active Runtime. That Task runs after the finalizer returns.

The finalizer calls public `uv.loop_abandon`, not the ordinary driver. UV clears
all user callback slots before driving libuv, including callbacks on
already-closing handles and accepted requests, so no user Lua/Titan callback,
Task continuation, decoder, or domain cleanup runs. Although Lua has not freed
those objects yet, later-registered finalizers may already have released their
native resources: a requested callback capturing a finalized `thread.Thread`, for
example, could not safely call `status()`. Suppressing callback exceptions would
not protect against that native use. UV's abandonment sweep and its internal
terminal handlers are described in the
[extension guide](libuv-extension-guide.md#final-state-teardown-is-not-ordinary-shutdown).
`active_runtime` is cleared only after `uv.loop_abandon` returns a successful
`uv.loop_close`. The finalizer then calls the
[abandoned `run_foreign` releases](#foreign-workers) queued by unwound waits.

The application contract still applies: withdraw handles, finish sends, and
drain the ordinary loop before closing the state. Abandonment reclaims libuv's
loop internals and closes their handles, not application cleanup semantics such
as a graceful protocol shutdown; the public guidance is
[cleanup that needs asynchronous I/O](../language/coroutines.md#cleanup-that-needs-asynchronous-io).
Domain owners whose ordinary close awaits release their own native state
synchronously at state close, from their finalizers or from a close that tests
`titan_state_closing`:
[Files](filesystem-library.md#lua-state-close),
[SQLite connections](sqlite3-library.md#lua-state-close) and
[TLS engines and contexts](ssl-library.md#lua-state-close). Their finalizers
need no Runtime, so they work in either order with this one.

**Parked native waits.** A Task parked in a native wait lends the domain a
waiter node in its own coroutine frame: thread channel send and receive (the
automatic `titan_thread_channel_wait` cell), and `Thread:join` and the
`Thread:task` proxy body (the `titan_thread_join_wait` cell in
`Thread:wait_until_finished`). The domain queue can outlive the state, because
another state or thread may hold an endpoint clone, or the joined worker may
still be running. Finalizers run newest first, so the coroutine can be finalized
before or after the endpoint or `Thread` handle it waits on. In neither order
may a queue still link the node once `coro_gc` releases the stack (issue #262).

State close [unwinds](coroutines.md#unwinding-an-abandoned-coroutine) every
suspended coroutine before it releases the stack, so each parked wait is
withdrawn by its own lexical cleanup while its node is still live. Every Task
root is newer than its Runtime, so it is finalized before `runtime_finalize`. A
coroutine stacked under a Task root unwinds as part of the root's chain. The
unwind of one Task runs, innermost first:

1. the wait cleanup: `ExternalWait:await`'s `defer` calls `detach_domain()`,
   which runs the native `unregister_wait(context)` or the Titan closure
   `unregister`, then `retire()`, then clears the suspension;
   `wait_external_native`'s `wait:close()` and the channel `defer`s that
   discard a held `wait.message` run in the same pass;
2. the body's `defer`s and generic-`for` closes;
3. `run_with_cleanup`'s cleanup;
4. the coroutine floor, which ends the coroutine as dead.

Ordinary GC never finalizes the root of a Task that is still in the inventory:
an unfinished Task stays in `runtime.tasks` until `finish_task`, and
`active_runtime` roots its Runtime until `loop()` retires it or
`runtime_finalize` runs. Ordinary-GC unwinding therefore reaches plain
coroutines such as generators, and a Task root only when `resume_root` failed
before switching into it (for example on allocation failure in
`root_transfer`): `advance_task` then publishes the Task as failed and
`finish_task` drops it from the inventory while its root is still suspended.

`retire()` releases the bridge target through the owner method
`bridge.wake:unregister(target)`. The bridge's `uv.external_wake_t` is created
lazily with the first external wait. It is usually newer than the waiting
coroutine, so its finalizer may already have detached the core and consumed
every registration reference. The owner method then returns `EINVAL` instead of
dereferencing the consumed borrow. The domain's own retained target stays
valid, so releasing it in the unregister function is safe, while a
notification on the detached core returns `EINVAL` and wakes nothing.

Closure-registered waits (`prepare_external_wait`, `wait_external`,
`wait_external_cleanup`) are withdrawn too. Their Titan `unregister` closure runs
inside a finalizer and must not yield. It must also tolerate objects created
after the Task having already been finalized. Native retirement barriers are
not withdrawn, because their admission lives in heap storage, not on a stack.
Armed gates stay nonterminal.

When the Task has no cancellation reason, `run_with_cleanup`'s cleanup first
records `"async Runtime abandoned at Lua state close"`, the reason that
`runtime_finalize` publishes, but only while `ffi.titan_state_closing(L)` is
set. It does not test `titan_in_finalizer`: the failed Task above is unwound
inside an ordinary finalizer, and its cleanup receives the Task's actual
reason, nil for a failed body. During the close the unwind runs outside the
scheduler with `runtime.current_task == nil`, so `running()` and every
Task-context operation raise
`asynchronous operation must be called from an async Task`, and yields and
resumes raise as in any finalizer. A cleanup's first await therefore raises,
and that error is reported as a warning. A cleanup that was itself suspended,
because the body had already finished, is unwound rather than run again.

The `Thread:task` proxy's cleanup (`titan/thread/spawn.titan`) awaits the
native-retirement barrier through `final_wait:wait_cleanup()` and then closes
it. At state close it skips both, since they would raise outside a Task, and
only forwards its reason to `Thread:cancel` when the thread has not finished.
`runtime_finalize` then leaves the armed gate, and with it the proxy,
nonterminal.

The unregister function can run after the endpoint or `Thread` handle that the
wait used was finalized. Thread domains therefore keep a
[per-registration pin](thread-library.md#registration-pins-and-state-close-withdrawal),
and the withdrawal may be the domain's final release, destroying it on the
closing thread. Withdrawing a waiter that a producer already woke passes the
wake on, so a waiter in another state is not starved. A `Thread` method called
on a handle whose finalizer already ran raises `thread handle was finalized`.

The unwind calls neither `finish_task` nor the scheduler. `runtime_finalize`
then retires these Tasks without resuming them, as described above: no Task
resumes and no terminal listener runs. The application contract above still
applies.

`request_exit(code)` obtains the current Task, records only the first code,
unbinds the Runtime's transfer loop before cancellation can enter cleanup,
cancels every unfinished Task, and raises the caller's own cancellation. The
`closing` flag is unchanged; accepted cleanup awaits and native callbacks still
retire through the ordinary driver. The standalone bootstrap returns that code
after ordinary cleanup, and `run` refuses new Tasks once exit is requested. A
manual Lua/Titan host keeps control after its loop call; this operation never
calls process-wide C exit.

## Startup policy

Async initialization owns the Unix SIGPIPE policy through the native helper
`titan_async_ignore_sigpipe_if_default` (`titan/async/async_signal_platform.h`): it
changes only a default disposition to ignored, preserves ignored and custom
handlers, and translates a native error through the public UV API. UV is a
general low-level binding and installs no process policy.

The public idempotent `uv.setup_process_args()` reads the argc/argv registry
published by a generated entrypoint. Async initialization calls it before the
entrypoint builds main's Titan argument Array, including under
`--no-uv-bootstrap`, which skips only invocation of the bootstrap hook. A Lua
host without those arguments has nothing to set up. Argument setup neither
creates nor drives a Runtime.

Async registers its private main bootstrap hook under
`TITAN_MAIN_BOOTSTRAP_KEY`. The hook schedules main as an ordinary Task, drives
the Runtime until every Task and native cleanup has retired, and returns the
first requested exit code, main's successful integer, or a failure status.
Explicit-drive clients use `--no-uv-bootstrap` and pair `run` with `loop`
themselves.

On the browser target `initialize_backend` performs no signal or argument
setup. In the owner state it registers the [browser driver](#browser-driver)'s
Task-form and disposal entries; the bootstrap hook is registered on both
targets.

### Supervised error handoff

`async.Error:raise()` calls `rethrow_failure`, which installs the captured trace
with the runtime's pinned-trace marker and then raises the original value.
Domain supervisors can keep an ordinary `Error` carrier during
cancellation-insensitive cleanup and propagate it after abort and drain without
losing child-operation frames or reporting an uncaught internal worker failure.
