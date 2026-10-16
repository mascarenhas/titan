# The async continuation runtime

The continuation runtime lives in `titan.async` and uses only the public
`titan.uv` module interface. UV owns native allocations, callback roots, borrowed
native data, and the native loop boundary. Async owns Tasks, generic waits,
cancellation, subscriptions, cross-state receiver queues, and shutdown. Timer, filesystem, networking, I/O,
OS, and SQLite adapters own their domain records and result/resource policies.

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
Consumers need the rebuilt canonical provider. The current generated-code ABI
is 2; the prerelease language-server API remains 1.

Async also owns the public `TransferValue` union used by independent-state
boundaries. Its nominal identity is `titan.async.TransferValue`; the Lua
library consumes that ordinary compiled import rather than defining an alias
or a second representation. Scalar variants hold ordinary Titan values, and
the string variant retains its source string in a traced slot. Record/union
variants retain a nominal name and protobuf wire bytes in two traced slots;
async transports these packets as opaque data. Its protobuf dependency supplies
the native loader used to encode and reconstruct nominal closure captures.
State, native-function, and raw-pointer
variants hold portable borrowed C pointer types and do not root their
referents. The Lua adapter owns its native packets and copy/borrow conversion
policy, described in [the Lua implementation chapter](lua-library.md#cross-state-transfer).

Tasks use tagged `coroutine.Coroutine` control transfer. Coroutine itself keeps
its existing public and native ownership contract; async uses one private tag
to route its yields. `coroutine.running()` still observes the exact public
Coroutine record and does not become an async Task lookup.

The generic runtime stores these private layers:

| Owner | Responsibility |
| --- | --- |
| `Runtime` | One public `uv.loop_t`, one reusable zero timer, FIFO head/tail/count, sparse live Tasks, current Task, driver/closing state, first fatal error/trace, exit status. |
| `Task` | One coroutine, scalar phase and optional public status snapshot, checked suspension epoch, intrusive ready node, first cancellation reason, current exact Wait, terminal listeners, optional explicit suspend token/detacher. |
| `Completion<|C,T,E|>` | One lazily allocated reusable cell per Task: scoped context, registrar, Task, captured suspension epoch, policy, phase, outcome/payload and optional accepted request. |
| `Wait` | The private all-value Completion view; it has the same owner, not another record. |
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
remain eager. TaskStatus ready/running/waiting remain unfinished, while succeeded/failed/
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

## Cross-state receiver ownership

`Receiver` owns the public [cross-state FIFO](../language/async-io.md#cross-state-receivers).
Its opaque `foreign *void` handle names native receiver storage, not a Titan
record or public `uv.async_t`. The host sending a message never follows a remote
GC pointer or enters the destination Lua state. Scalar tags/values and copied
string bytes live in native messages until the destination loop converts them
into its own `TransferValue`. Nominal packets copy the defining module, nominal
name, and wire bytes into one native allocation with independently checked lengths; no string
borrows the sending collector after `send` returns. The receiving loop copies
them into its own collector and preserves the record/union variant without
decoding. The one-slot string-copy transaction and
native-packet lifetime are recorded in the [trusted Lua API ledger](ffi-lua-api-followup.md#trusted-standard-library-discipline).
Borrowed pointer variants remain raw addresses.

Closure and custom record packets use the same flat string-copy boundary.
`from_value` snapshots closure captures and runs custom encoding hooks before
queue admission. A closure packet copies its module name and snapshot bytes,
and carries an immutable entry address. No origin closure, capture box, or
other origin GC pointer enters the queue. Accepted messages own only their
copied strings and native FIFO allocation; delivery or discard frees that
storage without traversing payloads or closing resources named inside them.

The receiving loop reconstructs `TransferValue.is_closure(module, entry, data)`
or `TransferValue.is_record_payload(module, name, data)` without decoding.
The consumer explicitly calls `:to_value()` to create a destination closure or
invoke the static reconstruction hook. Closure reconstruction resolves the
entry against the destination module's manifest before decoding its captures.
Every restored capture receives a fresh mutable cell. A captured
`TransferValue` retains its union wrapper. Active closure and custom-record
conversion cycles are rejected; repeated acyclic values retain copy semantics.
See the [transfer implementation](transfer-library.md) for the anonymous
protobuf snapshot and canonical preload lookup.

`TransferValue.from_value` validates the pair of public hook signatures through
ordinary reflection and permits private record fields when that pair is valid.
Its active-record guard prevents a hook recursively packing the same record;
deferred cleanup releases the guard after success or error. Hooks must run
synchronously. They may transfer native tokens under application policy, but
queue cleanup never closes or duplicates those tokens and cannot undo hook
side effects. The programmer must detach or clear an origin owner when needed
to prevent its finalizer from closing a handed-off resource.

Receiver construction uses `ensure_runtime` without requiring a current Task
or driving the loop, which permits synchronous independent-state bootstrap.
Waiting belongs to a Task in the same Runtime and uses the existing async wait
machinery. One waiter owns delivery; cancellation detaches that waiter while
preserving queue contents. Queue insertion and native-close admission are
serialized with the native receiver lock. FIFO order is the successful enqueue
order, and native notification coalescing cannot lose accepted messages.

Explicit close first marks the native receiver closed under that lock, then
releases queued packets and requests native close. A blocked waiter receives
the closed error. The operation is synchronous and idempotent; loop callbacks
still own native handle retirement. The Runtime's handle walk applies the same
admission shutdown to live receivers before generic close, including fatal
shutdown. A Receiver retained after close keeps its mutex and storage alive,
allowing a late send to reject safely without touching a retired UV handle.

An exported handle does not retain that owner or the originating Lua state.
Applications must retain the Receiver, withdraw handles, and complete sends
before permitting collection or state destruction. Keeping storage alive until
native close is necessary but insufficient to authorize use of an exported
handle after the Receiver's lifetime. No registry of process-wide tokens,
shared Titan closure, or cross-state GC object is part of this protocol.

`async.send` is an ordinary Titan entry with allocation and native locking.
Its cross-thread safety does not make it callable from a raw signal handler.
Only the receiving loop constructs destination GC objects and settles the
Task's wait. Error/cancellation delivery uses the existing continuation rules.

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

When native loop liveness is false and the ready queue is empty but Tasks
remain, the driver snapshots `(Task, exact Wait, epoch)`, requests shutdown
cancellation, and unwinds only an unchanged pending Wait (or unchanged absent
Wait) with the same epoch and no queued continuation or explicit resume.
Cleanup can settle another captured Wait or install a newer one; the
snapshot must not retire those changed/settled waits. This permits useful
lexical cleanup while avoiding a stale Task-only orphan snapshot.

Once no Tasks remain, `uv.walk` closes remaining non-closing handles. The driver
continues native callbacks and checks initialized inactive handles as well as
native liveness before `uv.loop_close`. Immediately after successful
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
