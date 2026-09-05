# The libuv continuation runtime

The private `titan.uv` folder module implements Titan's asynchronous standard
library on libuv. It is not a second scheduler layered over libuv. Its only
job is to translate between two equivalent control-flow spellings:

```text
submit operation(callback)
```

and:

```text
result = yield operation parameters
-- callback resumes here with callback parameters
```

The public `async`, `timer`, `fs`, `net`, `io`, and `os` modules normally
expose ordinary Titan records and Interfaces. `async.run_foreign` is the narrow
exception: its self-contained `foreign (*void) -> ()` and `*void` signature is
portable compiled metadata. Request owners, callback records, the yield union,
and libuv controls stay private to `titan.uv`.
The `ssl` and `http` standard modules are higher-level consumers of those
public facades; they do not add variants, callbacks, or handles here. The
standalone `url` module is synchronous and has no libuv dependency.

Contributor recipes for adding single-shot callbacks, persistent multi-shot
sources, and new handle types, together with the current binding-coverage
snapshot, are in [Extending the libuv binding](libuv-extension-guide.md).

## The non-reentrant loop invariant

Libuv specifies that `uv_run` is not reentrant and must not be called from a
callback. Titan uses that rule as the central invariant of the implementation:

- only top-level `async.loop()` or the generated standalone bootstrap calls
  `uv_run`;
- that call runs on the Lua main thread;
- no callback handler, resumed Task, or operation dispatcher calls `uv_run`;
- a Titan continuation runs to its next yield/return/error without another
  libuv callback interrupting it; and
- accepted work progresses only after the current callback returns to libuv.

Filesystem, DNS, and explicit `async.run_foreign` work may execute in libuv's
process-wide worker pool, but their completion callbacks still return on the
loop thread. Titan records are never accessed from those workers.

## Coroutine protocol

All Tasks are Titan `coroutine.Coro` values with one private module-identity
tag. A Task-to-runtime transfer is a local `Call` union. Every variant
represents one suspension action and carries one local record containing its
ordinary parameters. A one-shot variant normally submits one callback-taking
call. A persistent source may already be active, so its wait variant instead
consumes buffered state or installs one waiter. A callback-to-Task transfer is
the operation's result value or failure value. A cancellation-sensitive Call
may replace either with the stored `CancellationReason` before resumption;
ownership-retiring close and cleanup Calls deliberately receive their ordinary
completion while cancellation remains pending. Only operations with several
result components need a private result record.

The union is intentionally only a router. Each payload record implements its
own private `dispatch(task)` method. The callback continuation trampoline does:

```text
resume Task with callback result
if Task returned: finish that Task
if Task raised: report and finish that Task
if Task yielded Call.variant(record): record:dispatch(Task)
return from callback
```

For a one-shot operation, its dispatcher may perform direct synchronous libuv
calls before it submits the callback-taking call. After an accepted submission
it returns immediately. A documented negative submission result is special
because the callback will not run; the trampoline injects the error immediately
and lets the continuation yield its next call without recursive event-loop
entry. A persistent-source dispatcher may instead consume buffered state or
install one waiter without making a new native submission.

The all-value `run_internal` Task is primed by a zero-duration,
non-repeating `uv_timer_t`; public generic `async.run` only wraps the callback
and returns a shallow owner view. The timer callback submits `uv_close` and
does not resume the new Task. Its `close_cb` releases the timer owner and only
then resumes the Task for the first time. `async.yield` uses the same
close-before-resume timer protocol for an explicit later turn. Every one-shot timer follows
`timer_cb -> uv_close -> close_cb -> resume`.

There is no ready queue, scheduler pass, operation generation, or implicit
fairness turn. Application code is the body of the current libuv callback.

## Foreign worker requests

`async.run_foreign(f, arg)` yields `Call.run_foreign(WorkCall)`. Its dispatcher
allocates one `WorkOwner`, stores that owner in `Task.pending`, and submits the
owner's `uv_work_t` through `uv_queue_work` exactly once. `WorkOwner` retains
the request, a three-slot raw `WorkPointer` carrier, and the loop-thread Titan
completion callback. Only submission status zero is accepted; any nonzero
status is the no-callback case, so dispatch clears the pending owner and
returns an immediate `OperationError` whose operation is
`async.run_foreign`.

`uv_work_cb` is fundamentally different from every ordinary callback in this
module: it runs on a worker thread. The carrier's first slot is reserved for
the after-work owner lookup; the worker does not read it. It reads only the
erased `WorkFunction` and argument in slots one and two, calls `f(arg)`, and
returns. It does not recover a Task, closure, module, runtime, owner record, or
Lua state; access `TValue`/`Udata`; or call any Titan/Lua helper.

`uv_after_work_cb` runs on the event-loop thread and may recover the rooted
`WorkOwner`. Its `complete_work` callback translates status zero to ordinary
completion and a nonzero status to `OperationError`, then uses the normal Task
resumption path. That path clears `Task.pending`; the suspended native frame
keeps an adjusted owned argument alive until this terminal callback. Once
submission succeeds, cancellation neither invokes `uv_cancel` nor releases the
carrier early. The after-work callback remains authoritative and pending
cancellation is injected only when it resumes the Task.

The pool is shared with libuv filesystem and name-resolution requests. The
runtime adds no private queue, worker count, fairness policy, or concurrent
access protection around it.

## Explicit Task suspension and wake

The Runtime sets `current_task` immediately before entering a coroutine and
clears it with `defer` as soon as that coroutine yields, returns, or escapes.
`async.running()` returns that field as `Task<value, value>` and raises when
it is absent. Terminal
notification consequently runs on the Lua main thread after the terminating
coroutine is no longer the running Task.

The source-private `uv` provider owns this nominal public record:

```titan
record ResumeToken
  const source: string?
end
```

The `async` facade re-exports that owner and declares the public suspension
boundary separately:

```titan
type ResumeToken = uv.ResumeToken
type SuspendCancelAction = () -> ()
function suspend(token: ResumeToken,
                 cancel_action: SuspendCancelAction?)
function Task:resume(token: ResumeToken)
```

`async.suspend` yields a dedicated `SuspendCall` containing the exact token and
optional cancellation action. Its dispatcher marks the current Task explicitly
suspended, stores that token in the Task's optional `resume_token` field, and
installs a cancellation closure. Suspend submits no native request and
registers the Task on no persistent handle.

`Task:resume(token)` first compares the supplied record with the stored record by
nominal identity. The token's optional `source` does not participate in that
comparison; it only diagnoses a mismatch. Any mismatch raises synchronously in
the calling continuation with this exact message:
`Task resume token mismatch (expected source: <source>)`. The source is
`unknown source` when the stored token or its source is nil.
This comparison precedes every state guard. A Task that is not currently in an
explicit suspension stores no expected token, so a resume attempted before
suspension, after wake delivery, or after terminal completion also raises
unconditionally instead of becoming a no-op.

With the correct token, `Task:resume(token)` is synchronous, does not yield its caller,
and never enters the target coroutine inline. If no wake is pending, it sets one
coalescing bit and creates an ordinary target-owned zero-duration timer.
`timer_cb` initiates `uv_close`; only `close_cb`, after releasing the owner,
delivers the continuation. Before `advance_task` can re-enter user code, the
private completion clears `suspended`, `resume_token`, and `resume_pending`.
Repeated correct-token requests before close completion coalesce. The method
therefore works identically from the main-thread terminal-notification path or
another running Task, without promising one exact libuv iteration.

On cancellation, the installed closure first runs the optional
`SuspendCancelAction` synchronously so the exact waiter can detach, then calls
`resume` with the captured stored token. The action must neither yield nor
raise. Every user-Task terminal path calls the shared explicit-suspension clear
before `notify_terminal` stores the final status and invokes its snapshot.
This includes callback-boundary failure paths that do not pass through ordinary
resume delivery. Terminal listeners therefore cannot observe or reuse a stale
stored token; even the formerly exact record mismatches with expected source
`unknown source`. Retirement repeats the clear idempotently before unrooting the
Task. Calls outside an explicit suspension continue to mismatch until another
suspension deliberately stores a token.

`ResumeToken`, `SuspendCancelAction`, both required token parameters, and the
nil-accepting cancellation-action parameter are part of compiled-module ABI 2.
They appear in the serialized `titan.async` interface and exact native
signatures. A mismatched provider is rejected rather than migrated or adapted.

A source-private condition-waiter callback publishes completion through its
request or queue, then calls tokenless
`resume_condition_waiter_from_callback`. Native callbacks do not call public
`Task:resume(token)` and do not receive or validate a `ResumeToken`; the token protects
only explicit suspension ownership. With no public wake pending, the helper
retains the ordinary direct operation-callback continuation. If a correct-token
wake is already pending, it leaves the Task-owned timer as the sole
continuation. The callback can therefore neither duplicate that wake nor
advance the Task into a later suspension that the older timer would incorrectly
resume. If callback-boundary failure retires the Task while such a timer is
closing, the timer completion clears the pending token state and returns
without entering the terminal coroutine.

## High-level bounded channels

`async.channel<T>` is implemented entirely in `titan/async.titan` over
`async.running`, token-bearing `async.suspend`, and `Task:resume(token)`; it adds no
`Call` variant, native handle, callback trampoline, or Runtime queue. Each
channel creates one fresh private `ResumeToken` shared by its send, receive,
close, and cancellation paths. Its one generic source body returns this closure
triple over one bounded circular buffer:

```titan
((T) -> (), () -> T, () -> ())
```

- the declared `transfer: {T}` stores the live payloads;
- `first` selects the next receive slot;
- `next` selects the next send slot;
- `count` distinguishes empty/full state and is authoritative when a stored
  value is `nil`;
- `capacity` is the validated positive size, defaulting to 1;
- `send_waiter` and `receive_waiter` are separate optional Tasks; and
- `closed` records whether the close closure has committed terminal state.

Send and receive first reject `closed`, then reject an occupied waiter slot in
their own direction before inspecting the buffer condition. That ordering
prevents barging: after an opposite operation changes `count` and requests a
wake, another same-direction Task cannot take the newly available value or slot
while the original waiter's timer is still pending.

If send finds the buffer full, it installs itself as the sender and suspends
once with the channel token. Only a receive that has already decremented `count`
or a committed close can normally wake it with that token. Empty receive is
symmetric: only a send that has already incremented `count` or close can
normally wake it. On normal progress, send writes at `next`, wraps the index,
increments `count`, and wakes an installed receiver; receive takes and clears
`first`, wraps the index, decrements `count`, and wakes an installed sender.
Both wakes use the channel token. The payload buffer is FIFO and never grows
beyond `capacity`.

There is at most one blocked Task in each direction. A second operation that
finds an occupied sender or receiver slot raises rather than barging or forming
a Task queue. Each blocking path installs the current Task and immediately
wraps that install in deferred conditional removal. Because the token is
private and the occupied waiter slot remains authoritative through delivery, a
normal return from the single suspension already has the required buffer
postcondition. An outside caller with a different token raises in its own
continuation and cannot wake the channel. Cancellation uses the suspension's
stored token only to inject the reason; it unwinds instead of returning
normally, and the defer removes the waiter. If close caused the normal wake,
the operation clears its slot and raises `"channel is closed"` unless
cancellation wins that unwind.

The close closure is synchronous and idempotent. Its first call sets `closed`,
replaces `transfer` with an empty Array, resets both indices and `count`, and
resumes each installed waiter with the private channel token. Replacing the
Array releases every buffered GC reference; close does not expose a drain
phase. A later or woken send/receive observes `closed` and raises the exact
`"channel is closed"` error, unless an authoritative Task cancellation wins
the same unwind; a repeated close returns immediately.

Generic lowering recursively erases `{T}` to `{value}` and both payload
callbacks to their all-value carriers, preserving the former native prototype
and one shared implementation. A closed use receives ordinary traced callback
wrappers: the send wrapper boxes a statically accepted `T`, and the receive
wrapper strictly projects the erased result to `T`. The wrappers may have fresh
identity and are retained directly by their caller; they are not witnesses,
Runtime state, or per-application channel objects. Lua invokes the erased
closure triple directly.

## String-specialized channel adapters

`async.reader_writer_channel` is also implemented in `titan/async.titan`. The
module imports the public synchronous `string` facade; `string` has no reverse
async dependency. The factory calls `channel<string>(size)` once and wraps its
three adjusted closures in two nominal records whose fields are all local:

- `ChannelReader` retains the receive and shared-close closures, an optional
  excess string, and its own `closed` flag;
- `ChannelWriter` retains the send and same shared-close closures.

Neither record exposes a constructor or a raw channel closure. The writer
stores an exact `(string) -> ()` callback and the reader stores an exact
`() -> string` callback; both are ordinary traced wrappers over the erased
channel body. `read` first consumes `excess`, if present, and otherwise
option-wraps the exact receive result without a written cast. The public
records deliberately remain non-generic string stream adapters.

`ChannelReader:read_until` uses `string.find` and `string.sub` across message
boundaries. It keeps at most `#delimiter - 1` uncommitted tail bytes between
receives and appends each safe prefix to a synchronous `string.writer()`. When
a delimiter is found, it emits through the match unless `chop` is true and
stores the post-match suffix in `excess`; the next `read` or `read_until`
consumes that suffix before receiving another message. An empty delimiter is
rejected after the reader-local closed check and before any receive.

Both close methods invoke the same idempotent channel close. The reader first
sets its local `closed` flag and clears `excess`, making its own later `read`
and `read_until` calls return nil without touching the channel. The writer has
no separate closed state. Closing either endpoint discards buffered channel
values and wakes installed waiters. A read already blocked in the underlying
receive therefore gets the exact `"channel is closed"` error even when reader
close initiated that wake, and later writes get the same error. Reader-owned
`excess` is no longer in the channel buffer, so writer close preserves it. A
subsequent read can consume that excess, and `read_until` can satisfy a match
from it; the first path that next invokes the closed receive closure gets the
close error. Authoritative Task cancellation can instead win the same unwind.
The adapter adds no Task queue, native operation, or callback and inherits the
channel's capacity, single-waiter, no-barging, cancellation, and wake rules.

## Native callback bridge

Ordinary Titan functions and closures cannot be converted to C callback
pointers. The thirteen exact callbacks are instead source-defined
[`foreign function`](foreign-functions.md) declarations in the `file`, `os`,
`process`, `runtime`, `task`, and `tcp` contributors: filesystem, signal,
process exit, write, alloc, read, close, walk, timer, DNS, connect, shutdown,
and connection. Each has a plain libuv C signature and is assigned directly to
the corresponding callback parameter. The former `titan_uv.c` and
`titan/uv.h` callback bridge are gone.

Each callback owner is the smallest record needed to hide its unexportable FFI
storage and keep the callback's Titan values reachable. A one-shot request
contains its native request and callback; that callback closure captures the
suspended Task and any arguments libuv still borrows. A multi-shot handle
additionally retains only its natural buffered state and at most one waiter.
There is no common control record wrapped around these operation-specific
owners.

The `titan.uv` initializer captures the stable Lua main-thread `lua_State *`
once in a private module variable. Each new Runtime stores that pointer in its
sole `uv_loop_t` with `uv_loop_set_data`; each foreign callback recovers it with
`uv_loop_get_data`. The callback body then uses the four typed bridges in
`titan/ffi.h` to recover the exact owner userdata, stored callback closure,
closure module, and native Titan entry. It saves the stack top and calls the
entry with the original closure as Titan's hidden `_fn` argument, so captures
retain their ordinary generated-function ABI. The owner remains reachable
through its traced Runtime or callback/task ownership chain throughout the
callback, including terminal delivery, so a duplicate stack root adds no GC
protection. The body restores the saved stack top after its exact handler
returns.

There is no common native dispatcher. Each libuv-shaped foreign declaration
selects its own owner field and exact entry-pointer alias, and calls the handler
with only that callback's parameters. There is no event-kind tag or generic
callback payload at this boundary, and the manuals do not make the owners'
private record layouts part of the design contract.

The private callback-to-coroutine resume boundary catches errors raised by a
user continuation and retires only that Task. Operation callbacks use ordinary
`catch`/`finally` where a native result must first be released. A user-Task
callback failure therefore does not become a Runtime-wide failure. The outer
loop's final `uv_loop_close` remains the native cleanup proof.

The alloc and walk callbacks are direct. An alloc callback fills the supplied
`uv_buf_t` from storage on the stream owner. It cannot unwind a Titan
allocation exception through libuv, and a continuously drained stream may not
have a waiter at that instant. On allocation failure it therefore returns the
zero buffer that requires the paired `read_cb`, preserving the original
exception on the owner. That read boundary raises it into the waiter, or logs
it and terminalizes the unwaited stream. This is exception transport through
libuv's ordinary alloc/read pairing, not a fallback status, recovery path, or
guard against a read callback without its alloc callback.

During cleanup, each synchronous `uv_walk` selects at most one currently
non-closing `uv_handle_t *`; the Task submits that close immediately and walks
again only after `close_cb`. A raw handle pointer is therefore never retained
across an unrelated event-loop turn.

## One-shot requests

Each one-shot operation allocates one request record containing only its
GC-owned, immovable native request storage and operation-specific callback.
That callback closure captures the suspended Task and any buffer, address, or
argument that libuv still borrows.

The Task's `pending` field roots that request until its terminal callback.
Accepted operations produce exactly one callback. Titan does not suppress that
callback by cancelling an accepted request underneath its continuation. A
negative submission result produces none.

The Titan filesystem handler reads its result with public
`uv_fs_get_result`, runs `uv_fs_req_cleanup` exactly once, and only then resumes
the Task; its source-defined foreign entry passes only the exact owner and
native callback parameters. Read storage and the original string used by a
write remain rooted through that point. DNS handling counts usable `addrinfo`
entries, allocates one GC-owned `sockaddr_storage` array, and copies each
reported byte prefix directly with `memcpy` before `uv_freeaddrinfo`; there is
no address-copy shim. Connect, write, and shutdown requests
likewise retain exactly the native storage and borrowed values required until
their callbacks.

Libuv queues stream `uv_write` requests in submission order. Titan submits one
request per Task call and does not duplicate that queue. Filesystem requests
are independent thread-pool jobs. Titan neither serializes them nor keeps an
active-operation count on the descriptor; callers coordinate a shared File
when ordering a close against other requests matters.

## Persistent callback handles

Repeating timers, stream reads, listening sockets, and the one-shot exit
callback on a persistent process handle own only the state inherent in their
callback protocol:

- a repeating timer has one pending-fired bit and at most one waiter;
- a readable stream has buffered chunks, terminal EOF/error state, and at most
  one waiter;
- a listener accepts immediately in its connection callback, then buffers the
  accepted client or satisfies one waiter; and
- a process caches its exit status and satisfies at most one current waiter.

A callback clears its waiter before delivering it. Repeating-timer, stream,
listener, and process callbacks resume directly through their tokenless private
callback path. A directly resumed continuation may install the next waiter
before the callback returns, with no reentrant `uv_run` and no unrelated
callback interleaving.

Stream allocation is paired directly with the next read result. Positive
reads copy the reported byte count, zero reads are ignored, `UV_EOF` becomes
nil EOF, and another negative result becomes an `async.OperationError`. After
a terminal read result the stream is not read again.

Process configuration is likewise direct rather than a second declarative
model. `uv_spawn_config` owns an actual zero-initialized
`uv_process_options_t`, its three-element `uv_stdio_container_t` array, and
the concrete configured streams. Each configurator initializes any required
pipe or parent stream immediately, writes the stdio entry, and returns a
status so the caller can stop the option sequence at its first failure.
Replacing a choice closes unsubmitted streams that are no longer retained.
Parent descriptors are always represented by the Runtime's pipe-or-TTY stream
wrappers and inherited with `UV_INHERIT_STREAM`, never `UV_INHERIT_FD`.
Classification preserves libuv's known TTY and named-pipe fast paths and
rejects its other known kinds. For `UV_UNKNOWN_HANDLE`, an explicit `fstat`
must identify a socket before independent `getsockname` and
`getsockopt(SO_TYPE)` probes run. Each failure's `errno` is captured
immediately; `errno` left by `uv_guess_handle` is not evidence. Available
metadata must agree with `AF_UNIX` and `SOCK_STREAM`. Only a missing probe
denied with `EPERM` or `EACCES` can use launcher knowledge from
`TITAN_STDIO_PIPE_FDS`; other errors preserve their translated code. The hint
parser validates the entire comma-separated sequence of single digits
`0`, `1`, and `2` before accepting the requested descriptor. It neither
overrides contradictory metadata nor accepts an unexplained unknown kind
whose metadata probes both succeeded.

The name probe uses `titan_posix_getsockname`, one inline adapter in the
POSIX-guarded part of `titan/ffi.h`. It exposes the ordinary `sockaddr *`
signature because glibc's GNU declaration uses a transparent-union parameter
outside the C importer's supported subset. The adapter performs exactly the
native call and preserves its return value and `errno`; it introduces no
runtime state or exported ABI entry.

Classification occurs before the existing close-on-exec duplication and
stream-owner transfer. Failed classification creates no descriptor or handle
owner. Successful wrappers retain the existing per-Runtime cache and teardown
contract. Classification errors use `stdio.parent.kind` and include the
descriptor and responsible probe in `OperationError.message`.
Merged output uses separate child-write and parent-read pipe handles, installs
the child stream in both child entries, and exposes the same parent stream as
both Process outputs.

A successful spawn returns the native process wrapper and its three optional
parent endpoints together. The public `os.Process` takes those streams
immediately; the private `uv_process_t` does not duplicate them and retains
only its callback-lived handle, Runtime, waiter, cached exit result, and root
slot.

Captured stdout and stderr begin draining after a successful spawn. Parent
stdin remains lazy until the parent facade reads it, so merely preparing that
stream for `UV_INHERIT_STREAM` does not consume the child's input. An
unexpected captured-read startup error closes and terminalizes only that
stream; the low-level module does not kill or reap the successfully spawned
child.

Closing a watcher stops callbacks that libuv says may be suppressed and uses
the asynchronous `uv_close` callback to settle any blocked continuation.
Repeated public close calls remain safe; the implementation does not build a
close-waiter queue.

## Rooting and ownership

Libuv's `data` fields are raw `void *` slots and do not root Lua objects. The
Runtime therefore has two monotonically indexed sparse Arrays:

- `handle_roots` is only the live-owner set required by the current C-to-Titan
  callback bridge. It is never traversed; and
- `task_roots` keeps nonterminal Tasks alive and is the intentional Task
  inventory added above raw libuv. It determines when the last user Task has
  finished and lets `os.exit` cancel the other live Tasks.

A request is normally rooted directly by its Task. Closing swaps a handle's
callback data to a small close record that roots the original native owner
through the close callback. Entries are cleared to holes after terminal
callbacks. Neither Array is a parallel resource model or a source of shutdown
handle discovery; libuv's loop remains authoritative through `uv_walk`.

The shared `begin_close` checks `uv_is_closing` before it allocates a close
owner or calls `uv_close`; this is libuv's authoritative duplicate-close
protocol. Its boolean result lets a cancellation-insensitive
`HandleCloseCall` complete immediately when another path already initiated
close. Otherwise that Call remains suspended until `close_cb` releases the
owner and resumes its Task. The high-level filesystem watcher uses this local
Call when `stop` or `clear` must wait for closure, without adding a public
`uv` API.

Owned C objects and arrays provide stable native addresses. Automatic C
aggregates are used only for synchronous calls whose pointers cannot escape.
Stream and filesystem writes assign immutable Titan strings directly to
`uv_buf_t.base` through the documented `string`-to-`char *` conversion and keep
those original strings reachable until the callback. Libuv borrows but does
not mutate their bytes. It copies the submitted `uv_buf_t` descriptor,
asynchronous filesystem paths, and DNS text during submission;
`uv_spawn` consumes its file and argv text synchronously. Titan validates text
arguments for embedded NUL where required and keeps borrowed storage reachable
for every interval in which libuv needs it. Binary buffers always use exact
lengths and never depend on C-string termination.

## Task completion and errors

The public owners are `Task<A, B>`, `TaskStatus<A, B>`, and
`CancellationReason<B>`. The Runtime itself is deliberately concrete:
`task_roots: {Task}` and `current_task: Task?` are the exact bare
`Task<value, value>` application, as are every waiter, request owner, callback,
and operational helper. `run_internal` accepts `() -> value` and returns that
all-value Task. Public `async.run<A, B>` wraps its `() -> A` callback as the real
erased callable and returns a shallow view of the same userdata; no type
argument, witness, application descriptor, or parallel Task core enters
Runtime state. `async.running()` truthfully returns the all-value view.

A Task keeps its coroutine, its current suspension ownership, cancellation
request/reason, terminal-registration Array, explicit-suspension state, and one
public status value. Its live variants are `ready`, `running`, and `waiting`.
`Task:cancel` privately installs the first reason and invokes the current
cancellation action without publishing an intermediate variant; the public
state remains live until final `cancelled`. A dead coroutine's raw returned
value becomes `TaskStatus<value, value>.succeeded`. A terminal raised value and
its catch-local traceback become `async.Error { error, traceback }`; libuv
failures nested there retain their separate
`async.OperationError { code, name, message, operation }` identity.
The protected Task-error renderer recognizes that exact record and formats
its operation, symbolic name, numeric code, and message before appending the
existing traceback. Other raised values retain Lua's ordinary string
conversion. Both paths restore the exact entry stack top on success or error;
the Lua conversion path reserves its temporary stack space before pushing.
Rendering failures retain the conservative fallback text and cannot replace
the Task's original error payload.
Cancellation stores `CancellationReason<value>` privately until the terminal
`cancelled` variant. Its `simple` arm contains a string and its `complex` arm
retains an arbitrary Titan value; an omitted reason becomes
`CancellationReason.simple("cancelled")`. Constructor inference uses the
expected optional reason type when available and otherwise closes the result-only
binder to its declared carrier. Exact `A` and `B` checks occur
only when a typed public view projects a success or complex-cancellation
payload.

Each `add_terminal_listener` call creates a fresh local
`TerminalRegistration<A, B> { listener, live }`, appends it, and returns a
remover closure capturing that registration and Task. A live remover clears
`live` and deletes that exact record from the dense Array; repeated calls are
no-ops. Adjusted callbacks may have fresh closure identity, so neither removal
nor duplicate registration compares listener closures.

Terminal publication stores the final status before notifying observers. The
main-thread continuation driver detaches the current registration Array into a
stable snapshot, immediately installs an empty live Array on the Task, and
clears every snapshot registration's `live` ownership before invoking any
listener. It then traverses the snapshot in registration order without
consulting `live`, wrapping each call in its own empty `catch`. A remover called
during delivery is therefore a no-op and cannot shift this snapshot or skip a
later callback. A listener error neither changes the Task's outcome nor
prevents later listeners from running. Only after notification does the Runtime
retire the Task root and decide whether shutdown should begin. Registering on a
terminal Task returns an idempotent no-op remover.

An uncaught Task error is not a Runtime fatal condition. The continuation marks
only that Task failed, renders the error, writes it and the preserved traceback
to standard error, and returns to libuv. Other Tasks remain active. When the
last Task finishes—successfully, by cancellation, or by uncaught error—the
Runtime starts ordinary cleanup.

The high-level `async` combinators use that listener protocol directly. Each
fixed arity is generic over an independent `(A_i,B_i)` pair for every named
operand. It first obtains the bare all-value current Task, rejects it as any
operand, and scans the named operands from left to right. It never collects them
into a common `{Task}` Array, which would collapse every position to the
all-value application and discard the public result/status precision.

If the initial statuses do not decide the result, the implementation creates
one fresh, source-labelled private token for that combinator invocation and a
separate closure for each still-relevant named operand. Those listeners capture
the token with the result slots, terminal counter, or winner position required
by that family. The listener that makes the result decidable resumes the
suspended current Task with that token; resume only installs its coalesced zero-
timer wake and returns to the terminal publisher. The combinator suspends once
with the same token, then returns or raises from the captured state after that
wake. Every registration returns an idempotent remover that is called by a
matching `defer`. If another Task cancels the suspended combinator, its stored
token schedules the same timer wake and those defers remove all outstanding
registrations before it unwinds.

Winner and rejection guards, together with completion counters, arbitrate
multiple legitimate terminal listeners that can run before the deferred wake is
delivered. They prevent a later listener from replacing a selected result or
deciding it twice; they are not an early-resume defense. The per-position
`has_finished()` checks retained by `join*` are redundant local idempotence—each
positional registration is invoked once—and are unrelated to this boundary. The
private token makes a nullable `waiting` guard for outside callers unnecessary.

Because the loop is non-reentrant, no other Task can terminalize between the
initial scan, the listener registrations, and suspension. Already-terminal
ties are selected by the left-to-right scan. Later terminal events are observed
in publication order, and multiple listener registrations on a duplicate Task
run in registration order, preserving its leftmost position. There is no
`uv_check_t`, `uv_idle_t`, Task polling loop, scheduler joiner list, or Runtime
phase bridge in this composition.

`join` alone has a unary entry point. A one-input `any`, `race`, or `all` would
perform the same observation and waiting as `join` and merely repackage its
single outcome, so the implementation deliberately starts those families at
arity two.

Because failure reporting remains owned by the failed Task, a later
`race`/`all`/`join` inspection does not suppress its already emitted report.
The combinators likewise do not cancel unfinished inputs; HTTP's timeout
composition applies ownership-specific cleanup itself. A winning reader
cancels and detaches its timer-only deadline, whose close can finish in the
background. A winning deadline cancels and joins the reader before releasing
the parser, transport, and TLS busy state owned by that operation.

Cancellation never releases native request storage early or suppresses an
accepted request's terminal callback. For a watcher whose event callback can
be suppressed, the cancellation action stops and closes the watcher; the
close callback schedules its Task through the ordinary callback-deferred
one-shot wake. The stored request remains authoritative even if application
code catches or
transforms the injected nominal reason, so every user terminal path records
`cancelled` with the original union value. `Call:is_cancellation_affected`
keeps handle/file close, spawn-failure ownership retirement, and Runtime cleanup
dispatchable while cancellation is pending; their callbacks deliver ordinary
completion before a later sensitive boundary reinjects the reason. A waiter
detached from a shared multi-shot handle cannot close that shared resource; it
receives its own Task-owned one-shot timer and resumes from that timer's close
callback. Cancellation of an explicitly suspended Task first runs its optional
nonyielding, nonraising waiter-detachment action and then calls `resume` with
the stored token, which coalesces with any already requested correct-token wake.
Cancellation never resumes one Task synchronously inside another Task.

## Runtime shutdown

The Runtime sets `closing` before cleanup, so dispatchers that create new
handles fail. A private cleanup Task then uses the same continuation protocol:

1. yield one cleanup step;
2. while that Task is suspended, synchronously call `uv_walk` to select one
   non-closing handle and submit its ordinary `uv_close`;
3. repeat after `close_cb` schedules the cleanup Task's callback-deferred
   continuation, until a walk finds none; and
4. return normally, which marks Runtime cleanup complete.

The outer `uv_run` never stops during this sequence. It delivers outstanding
request and close callbacks until the loop becomes idle. Only then does the
top-level driver call `uv_loop_close`; a negative `UV_EBUSY` result is an
implementation failure, not something hidden by a second ownership graph.

A `uv_process_t` is an ordinary discovered handle during cleanup. Calling
`uv_close` retires its watcher; it neither signals the child nor waits for or
reaps it. A child may therefore outlive its Runtime. Explicit `Process:kill`
and `Process:wait` calls remain the application's child-lifecycle operations.
The Runtime needs no process registry or termination policy; its generic root
table keeps a live process owner reachable for callbacks but is never traversed
as an ownership list.

A `uv_file` is an operating-system descriptor rather than a `uv_handle_t`.
There is deliberately no Runtime File registry and no automatic File-close
shutdown phase. The high-level `fs.File` facade stores the raw descriptor, and each in-flight
filesystem request retains its submitted copy as needed. A full high-level
write reloads the facade's descriptor before every short-write submission, so
a close between chunks is observed instead of reusing a stale process integer.

`File:close()` constructs its source-private close attempt before installing the
closed `-1` sentinel, then suspends. Dispatch marks the attempt accepted only
after native submission succeeds. A caught failure restores the descriptor
only while that bit is false and uses a bare re-raise to preserve the original
traceback. Once submission is accepted, success, callback failure, and pending
cancellation all leave the facade terminal: retrying that integer could close
an unrelated descriptor after operating-system reuse. Close itself is not a
cancellation-affected operation, so an accepted request reaches its callback.
Operating-system process teardown handles descriptors deliberately left open
by the application.

After successful close, the Runtime clears its roots. A later `run`/`loop`
pair creates a fresh loop. Retained loop resources from the prior session are
terminal. A File carries no Runtime identity, so an open descriptor can be
used by a Task in that later Runtime; application code still owns its explicit
close.

## Standalone bootstrap and host-process policy

Module initialization records the main Lua thread, applies `uv_setup_args`
when a generated entrypoint published argc/argv, and installs the private main
bootstrap hook. It also changes only a default Unix `SIGPIPE` disposition to
ignored so libuv can report closed-stream writes. A generated entrypoint built
with `--no-uv-bootstrap` still performs this complete initialization and leaves
the hook installed, but takes its direct `main(args)` branch. This allows an
application or test runner to own sequential outer-loop sessions explicitly;
it does not create a second uv initialization mode.

The standalone bootstrap schedules `main` as a Task and drives the same outer
loop. It waits for all Tasks through Runtime liveness, not a low-level joiner
protocol. An
uncaught main-Task error is logged like any other Task error and produces an
unsuccessful executable status. `os.exit` records the requested code, cancels
every user Task including its requester, runs normal cleanup, and returns that
code through the generated entrypoint rather than calling ISO C `exit`. Only
the first request commits the code. The requester raises its stored
`CancellationReason`; catching that union value cannot change the Task's
authoritative cancelled terminal status or its original reason.
