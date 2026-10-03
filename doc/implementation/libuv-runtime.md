# The async continuation runtime

The continuation runtime lives in `titan.async` and uses only the public
`titan.uv` module interface. UV owns native allocations, callback roots, borrowed
native data, and the native loop boundary. Async owns Tasks, generic waits,
cancellation, subscriptions, and shutdown. Timer, filesystem, networking, I/O,
OS, and SQLite adapters own their domain records and result/resource policies.

The old private UV `Call` union, per-operation dispatch methods, Task association,
and domain-operation router are removed from this architecture. Adding an async
operation does not add a new scheduler variant. A registration closure expresses
its one native submission and receives capabilities for its exact wait.

## Module and type ownership

`Error`, `OperationError`, `ResumeToken`, `CancellationReason<|B|>`,
`TaskStatus<|A,B|>`, and `Task<|A,B|>` are now defined in async rather than aliased
from private UV owners. Public field names, result tags, constructor namespaces,
and generic positions remain those of the existing async API. The defining
module in nominal metadata changes; it is not byte-identical old metadata.
Consumers need the rebuilt canonical provider. This work does not bump the
existing generated-code ABI 2 or prerelease language-server API 1.

Tasks use tagged `coroutine.Coroutine` control transfer. Coroutine itself keeps
its existing public and native ownership contract; async uses one private tag
to route its yields. `coroutine.running()` still observes the exact public
Coroutine record and does not become an async Task lookup.

The generic runtime stores these private layers:

| Owner | Responsibility |
| --- | --- |
| `Runtime` | One public `uv.loop_t`, sparse live Tasks, current Task, driver/closing state, first fatal error/trace, exit status. |
| `Task` | One coroutine, public status, first cancellation reason, current exact Wait, terminal listeners, optional explicit suspend token/detacher. |
| `Operation<|T,E|>` | One registration and ordinary/cancellable/cleanup policy yielded by a Task. |
| `Wait` | One Task, policy, phase, outcome, payload, and optional accepted public request view. |
| Subscription `Core` | Queue, explicit count, terminal state, one reserved waiter, producer actions, cleanup drain capability. |
| Public UV owner | Native request/handle storage and callback rooting until its defined native terminal boundary. |
| Domain owner | Resources obtained from native completion, facade state, sharing rules, and lexical cleanup. |

There is no operation-generation key, native-request introspection to recover a
Task, additional scheduler-ready queue, or async Task table inside UV.

## Driver and registration trampoline

Only `async.loop()` or the standalone async bootstrap drives the
async-owned loop with `uv.run`. Independent low-level clients may explicitly
drive their own public UV loop; this restriction concerns Runtime ownership.
The driver runs on the Lua main thread and rejects reentry or calls from a
running Task. One Task
continuation runs to yield, return, or error without another loop callback
interrupting it. The Runtime sets `current_task` only around coroutine entry
and clears it before registration and terminal notification.

`run(func)` roots a ready Task and schedules a zero timer. Its timer callback
submits `uv.close`; the close callback retires the native timer before entering
the Task. Yield and correct-token explicit resumes use the same close-before-
continuation protocol. The public `run<|A,B|>` result and the Runtime's all-value
view refer to the same Task owner.

Each await constructs one generic Operation and yields it with the private tag.
The driver checks cancellation policy before invoking registration. It creates
a Wait in REGISTERING phase, stores it on the Task, and passes closures for
resolve, reject, and fatal. The Task is now waiting, but `async.running()` is
absent while registration executes. `current_loop()` accesses the active
Runtime loop without creating or driving it. `is_closing()` reads that same
active Runtime's closing flag, raises if there is no active Runtime, and has no
Task-context or cancellation check. Synchronous domain construction uses it when
shutdown admission must be rejected without adding an ordinary await boundary.

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
from a different running Task first accepts a deferred timer wake and then
commits the settled state using nonallocating field writes. If scheduling fails,
the Wait remains pending so retry/shutdown can still address it. Delivery checks
that the Wait is SETTLED and remains exactly `task.wait`; it clears the request,
Wait, token, and explicit-suspension state before entering the continuation.
Duplicate settlement raises rather than mutating an unrelated wait.

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
callback does so. Ordinary and cleanup registrations return no request view to
the async layer; their native owners remain retained by public UV and the
suspended lexical state.

Task cancellation retains its first reason and overrides final Task success or
failure. Cleanup shielding changes submission/result delivery, not this terminal
policy. New ordinary/cancellable operations during fatal shutdown receive the
Runtime failure; cleanup operations remain available to retire ownership.

## Operation-local fatal callback association

Every await registration receives `fatal(error: value, trace: string)` alongside
resolve/reject. It captures that Wait. This is an out-of-band exception channel,
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
The first-error latch is separate from the once-only shutdown-cancellation pass.
When already driving, latching failure calls `uv.stop` so the outer driver can
cancel/unwind Tasks before waiting indefinitely for unrelated accepted work.

An arbitrary unprotected callback supplies no Wait association. The driver
handles its low-level error boundary and retains native owners, but cannot
identify a consumed request's Task early. That boundary is why custom one-shot
adapters must implement the explicit fatal protocol. This is not a claim of
universal recovery from every foreign callback mistake or memory failure.

## Explicit suspend, Task status, listeners, and combinators

`SuspendCancelAction` remains `function():()`. Suspend installs the caller's
exact ResumeToken, a nonyielding detacher, and one ordinary Wait. Task.resume
checks identity before any finished/pending shortcut. Matching pending wakes
coalesce; equal source strings do not authorize a different token. A failed
scheduling attempt clears `resume_pending`, and completion retires the old token
before a new wait can be installed.

Cancelling an explicit suspension invokes its detacher and schedules the
ordinary token wake. It does not enter the target Task inline. Terminal status
publication clears the suspension, detaches the listener snapshot, and marks
its entries non-live before delivery. Removal before snapshot is idempotent;
removal during delivery cannot suppress a captured listener. Individual listener
exceptions are swallowed so later listeners still run. Registering after
termination does not replay the terminal event.

TaskStatus ready/running/waiting remain unfinished, while succeeded/failed/
cancelled remain terminal. Predicate booleans are authoritative even for nil or
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

Buffered controls stay synchronous. `drain_if` must receive a nonyielding,
nonmutating predicate and detaches the entire FIFO on any match; it is not a
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

## Foreign workers

`run_foreign(f,arg)` is now a public-work-request adapter over ordinary await and
`uv.queue_work`. It rejects NULL f before submission. The worker runs only
`f(arg)` using raw native state; the loop-thread completion callback resolves nil
or rejects an OperationError labelled `async.run_foreign`, and protects unexpected
failures with fatal plus bare rethrow. The argument's owned storage remains in
the suspended caller through completion.

Worker code must not inspect Titan/Lua owners, call the Lua API, raise, or resume
a Task. Synchronization of shared native bytes remains the caller's job. The
libuv worker pool is shared with other native work and async adds no new queue
or thread policy. Ordinary cancellation never detaches the accepted job.

Ownership-retiring foreign work uses public `uv.queue_work` registered through
`await_cleanup`. The old source-private `uv.run_foreign_cleanup` and its router
variant are unnecessary. Adapters still retain arguments, interpret their native
results, and dispose of unpublished result resources lexically.

## Shutdown and process control

A first callback/driver failure sets closing, latches the original Error, and
stops an active UV run. A separate once-only pass cancels remaining Tasks. Task
cleanup may need native requests or scheduler timers, so a blanket handle walk
must wait until all Tasks have retired. Accepted callbacks remain authoritative.

When native loop liveness is false but Tasks remain, the driver snapshots pairs
of `(Task, exact Wait)`, requests shutdown cancellation, and unwinds only an
unchanged pending Wait (or unchanged absent Wait) without an explicit scheduled
resume. Cleanup can settle another captured Wait or install a newer one; the
snapshot must not retire those changed/settled waits. This permits useful
lexical cleanup while avoiding a stale Task-only orphan snapshot.

Once no Tasks remain, `uv.walk` closes remaining non-closing handles. The driver
continues native callbacks and checks initialized inactive handles as well as
native liveness before `uv.loop_close`. Successful close clears the active
Runtime and only then rethrows its first fatal error with the preserved raw
trace. A subsequent run can create a fresh Runtime. The native owner maps belong
to UV; async does not add a parallel domain-resource registry.

OS descriptors and native objects returned by workers are not automatically
libuv handles. Their lexical/domain owners must close or dispose of them.
Closing a process watcher does not kill or reap the process.

`request_exit(code)` obtains the current Task, records only the first code,
cancels every unfinished Task, and raises the caller's retained cancellation.
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
