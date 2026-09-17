# Asynchronous I/O and tasks

Titan's public asynchronous scheduling API is the `async` module. Titan code
imports it with `local async = import "async"`; Lua uses
`require "titan.async"`. The module supports Linux and macOS. Its private
`titan.uv` provider adapts libuv callbacks to Titan coroutines; application
code should import the public `async`, `timer`, `fs`, `net`, `io`, and `os`
modules instead of `uv`.

On Unix, loading the provider changes a default `SIGPIPE` disposition to
ignored so a closed stream produces an `async.OperationError` instead of terminating
the process. An inherited ignored disposition or application-installed
handler is preserved.

## Scheduling and driving Tasks

The facade re-exports `Task`, `TaskStatus`, `CancellationReason`, and
`ResumeToken` as constructor-preserving aliases of owners in the private
provider; it also re-exports the ordinary `Error` and `OperationError` records.
The aliases retain the underlying public static/constructor namespace. The
public `async` facade surface below includes methods available through those
aliases:

```text
type CancellationReason = uv.CancellationReason
type TaskStatus = uv.TaskStatus
type Task = uv.Task
type ResumeToken = uv.ResumeToken
type SuspendCancelAction = function (): ()

function run<|A, B|>(func: function (): (A)): Task<|A, B|>
function run_foreign(f: foreign function (*void): void, arg: foreign *void)
function loop()
function yield()
function running(): Task -- exactly Task<|value, value|>
function suspend(token: ResumeToken,
                 cancel_action: SuspendCancelAction?)
function channel<|T|>(size: integer?):
    (function (T): (), function (): (T), function (): ())
function reader_writer_channel(size: integer?):
    (ChannelReader, ChannelWriter)
function version(): string

record ChannelReader
record ChannelWriter

function ChannelReader:read(): string?
function ChannelReader:read_until(delimiter: string,
                                  chop: boolean?): string?
function ChannelReader:close()
function ChannelWriter:write(data: string)
function ChannelWriter:close()

function Task:cancel(reason: CancellationReason<|B|>?)
function Task:status(): TaskStatus<|A, B|>
function Task:add_terminal_listener(
    listener: function (TaskStatus<|A, B|>): ()): function (): ()
function Task:resume(token: ResumeToken)

function TaskStatus:as_string(): string
function TaskStatus:has_finished(): boolean
function TaskStatus:has_succeeded(): (boolean, A?)
function TaskStatus:has_failed(): (boolean, Error?)
function TaskStatus:has_cancelled(): (boolean, CancellationReason<|B|>?)
```

The aliased data owners are declared in the source-private `uv` provider, not
again in the `async` facade:

```titan
record ResumeToken
  const source: string?
end

record Error
  error: value
  traceback: string
end

record OperationError
  code: integer
  name: string
  message: string
  operation: string
end

union CancellationReason<|B|>
  simple(string)
  complex(B)
end

union TaskStatus<|A, B|>
  ready()
  running()
  waiting()
  succeeded(A)
  failed(Error)
  cancelled(CancellationReason<|B|>)
end
```

`Task<|A, B|>` uses `A` for a successful return and `B` for the payload of a
complex cancellation reason. A bare `Task`, `TaskStatus`, or
`CancellationReason` is the ordinary all-`value` application. `B` is
result-only in `run<|A, B|>`: result context selects it when available, and the
final carrier rule otherwise closes it to `value`. A caller may state the
complete pair, for example `async.run<|string, value|>(func)`; there is no partial
type-argument list. `running()` deliberately returns the bare all-value Task,
not an inferred application.

`async.run<|A, B|>(func)` creates and roots a Task, registers a zero-duration
libuv timer, and returns without calling `func`. Its public wrapper adapts the
exact `function (): (A)` callback to the Runtime's `function (): (value)` carrier and returns a
shallow `Task<|A, B|>` view of the same userdata. The timer callback submits
`uv_close`; its close callback releases the timer owner and only then starts the
Task on a later event-loop turn. Every one-shot timer uses this close-before-
resume order. Calling `run` from another Task is valid and still does not run
the new Task inline.

`async.run_foreign(f, arg)` submits the C function pointer and argument to
libuv's process-wide worker pool and suspends the current Task until the
after-work callback runs on the event-loop thread. It is intended for blocking
calls into an external C library. It is not a way to run Lua code or an
ordinary Titan function or closure on another thread. A restricted source
`foreign function` is permitted because the compiler emits it as an exact C
callback; its body must remain entirely within the raw-C restrictions below.

The worker performs exactly `f(arg)`. It must not inspect or mutate Titan or
Lua objects, call the Lua API, allocate through Titan, raise, resume a Task, or
touch `TValue`, `Udata`, or other GC-managed state. The argument must identify
native storage that remains alive until completion. Passing an `owned` C
allocation keeps that owner alive in the suspended caller, but the caller is
still responsible for synchronization and must not concurrently access bytes
that the worker may read or write.

A queue-submission failure raises immediately. After successful submission,
status zero resumes normally and a nonzero after-work status raises an
`OperationError`. Cancelling the waiting Task does not stop or detach the C
call: libuv completion remains authoritative and retains the request/carrier;
the suspended caller frame continues retaining any owned argument. Only after
the callback completes does the Task receive its pending cancellation. The
worker pool is shared with libuv filesystem and name-resolution work, so
long-running or numerous jobs can delay unrelated operations.

Raw pointers and foreign function pointers have no dynamic Lua coercion. The
serialized signature lets statically compiled Titan modules call
`run_foreign`; it does not make the function callable with arbitrary Lua
values.

`status()` is a snapshot. Its first three variants are nonterminal. Calling
`cancel` on an unfinished Task privately retains the first reason and starts
the current cancellation action, but does not manufacture an intermediate
public status: the snapshot remains `ready`, `running`, or `waiting` until the
Task reaches terminal `cancelled(reason)`. The concrete Runtime stores success
and complex-cancellation payloads as `value`; the exact `A` or `B` guard occurs
only when a typed view projects that payload. Returning the opaque Task,
checking a status tag, or calling `as_string()` needs no payload check. A
`failed` payload is the exact raised value and raw traceback wrapped in
`Error`. `as_string()` returns `"ready"`, `"running"`, `"waiting"`,
`"succeeded"`, `"failed"`, or `"cancelled"`. The predicate methods inspect
terminal states and payloads without spelling a `case`.

A Lua host drives scheduled work explicitly:

```lua
local async = require "titan.async"
local timer = require "titan.timer"

local result
local task = async.run(function()
    timer.sleep(10)
    result = "done"
end)

assert(task:status():as_string() == "ready")
async.loop()
assert(task:status():as_string() == "succeeded")
assert(result == "done")
```

A standalone Titan program that transitively imports an asynchronous module
needs no wrapper around `main`. Module initialization installs a private
bootstrap hook; the generated entrypoint schedules `main` as a Task and drives
the loop. The Runtime remains alive until every Task has finished, even if
`main` finishes first.
A standalone or test executable may instead pass `--no-uv-bootstrap`. Its
entrypoint calls `main(args)` directly while leaving module initialization and
the private hook intact. Such a `main` must explicitly use `async.run` and
`async.loop` for each Runtime session, and must close Runtime-bound resources
before that session returns.

`async.yield()` cedes one event-loop turn without waiting for an external
resource. `timer.yield()` is a facade over the same operation. Calling either
outside a Task raises.

`async.running()` returns the current Task and raises when called outside one.
`async.suspend(token, cancel_action)` suspends that Task without registering a
native operation or an implicit waiter; it likewise raises outside a Task. The
Task retains the exact `ResumeToken` record until that suspension ends. A token
is nominal: only the same record passed to `suspend` can later be passed to
`Task:resume(token)`. The optional `source` is diagnostic text, not part of the
comparison. Coordination abstractions should create a fresh token, keep it
private, and share that record only with the code allowed to wake their waiter.
Create it through the re-exported constructor, for example
`local token = async.ResumeToken.new("my gate")`.
The token authorizes only `Task:resume` of that explicit `suspend`; it is not a
general wake for a Task waiting on a native operation or persistent source.

Passing any other token raises synchronously in the caller of `resume`:
`Task resume token mismatch (expected source: <source>)`. The message uses the
stored expected token's source, never the supplied token's; a missing stored
token or nil expected source is shown as `unknown source`. The check is
unconditional whenever the Task has no current explicit suspension—including
before suspension, after wake delivery until another suspension, or after
terminal completion—so a wrong-time call raises with expected source
`unknown source`; it is not a no-op.

With the correct token, `resume` does not enter the target Task inline. It
synchronously requests a callback-deferred wake without yielding its caller,
so it is valid from a terminal listener's main-thread context or another
running Task. Repeated correct-token requests before the wake coalesce.

The optional zero-argument cancellation action runs synchronously in the
caller that requests cancellation, before the suspended Task's correct-token
wake is scheduled. It is for nonyielding, nonraising detachment of an exact
waiter or similar ownership state; an ordinary correct-token `resume` does not
call it. Omitting the second argument is equivalent to passing nil.

`ResumeToken`, `SuspendCancelAction`, the required token parameters, and the
nil-accepting cancellation-action parameter are part of the public compiled-
module contract. Both serialized `titan.async` metadata and the exact native
signatures include them. A mismatched ABI-2 provider is rejected rather than
migrated or adapted.

The first correct-token wake request uses a zero-duration timer owned by the
target Task; later requests before delivery coalesce. The timer callback
initiates `uv_close`, and the close callback releases the timer owner before
resuming the Task. This guarantees callback-deferred delivery but does not
promise one exact libuv iteration.

## Bounded channels

`async.channel<|T|>(size)` returns sending, receiving, and closing closures over
one bounded FIFO channel:

```titan
local send, receive, close = async.channel<|string|>()
send("message")
local message = receive()       -- string, with no written cast
close()
```

`size` carries no payload evidence. State `T` explicitly as above, or provide
an expected result shape for the returned callbacks. With neither, the final
carrier rule closes `T` to `value`, so a bare `async.channel()` retains the old
all-value surface. Like every erased generic application, `T` must satisfy the
ordinary recursive eligibility rules; erasure does not make an otherwise
ineligible FFI shape transferable.

The default capacity is 1. An explicit size must be at least 1; zero or a
negative value raises before the closures are returned. The channel retains at
most that many values and preserves send order. It can carry `nil` when the
chosen `T` admits nil, including `nil`, an option, or `value`.

Sending to a full channel suspends the sender until a receive frees a slot.
Receiving from an empty channel suspends the receiver until a send adds a
value. There can be at most one blocked sender and at most one blocked receiver.
While either waiter slot is occupied, another same-direction operation raises
instead of barging ahead—even if the buffer condition changed after the first
Task's wake was requested but before it was delivered. An operation that does
not need to block completes synchronously; a blocking path requires a running
Task.

After enqueueing a value, `send` requests a wake for the blocked receiver, if
any. After dequeueing a value, `receive` does the same for the blocked sender.
Each channel owns one private token shared by all of its blocking and wake
paths. These calls use that token with `Task:resume(token)`, so repeated wake
requests coalesce and never enter the other Task inline; code holding only the
Task cannot wake the channel with a different token. A blocking operation
suspends once. Its authorized normal wake comes only after the opposite
operation has established buffer progress or `close` has committed terminal
state, and the occupied waiter slot prevents another same-direction operation
from stealing that progress before delivery. Cancellation instead injects the
Task's reason and unwinds; deferred cleanup removes its waiter registration.

`close()` is synchronous and idempotent. Its first call marks the channel
closed, discards every buffered reference rather than making queued values
receivable, and requests wakes for installed send and receive waiters. Every
later send or receive raises `"channel is closed"`. A waiter woken by close
clears its registration through `defer` and raises that same error instead of
completing its pending operation, unless an authoritative cancellation of its
Task wins that unwind. Later calls to `close()` do nothing.

The implementation is one erased all-value body. A closed application returns
ordinary traced callback wrappers: sending accepts its precise `T`, while
receiving strictly projects the stored value back to `T`. No run-time type
argument or per-application channel identity exists. A Lua caller sees and uses
the erased value closure triple; Lua has no type-argument syntax.

## Channel-backed string streams

`async` also owns opaque string-specialized reader/writer records over the same
channel protocol:

```text
record ChannelReader
record ChannelWriter

function reader_writer_channel(size: integer?):
    (ChannelReader, ChannelWriter)
function ChannelReader:read(): string?
function ChannelReader:read_until(delimiter: string,
                                  chop: boolean?): string?
function ChannelReader:close()
function ChannelWriter:write(data: string)
function ChannelWriter:close()
```

Every record field is local, so neither generated constructor is public.
`reader_writer_channel` is the public factory, and neither endpoint exposes
the raw channel closures. The factory closes `channel<|string|>` internally and
stores exact `function (string): ()` and `function (): (string)` callbacks. The records remain
intentionally non-generic string ReaderCloser/WriterCloser adapters; use
`channel<|T|>` itself for other typed payloads. The ordinary `string.reader` and
`string.writer` remain synchronous in-memory values.

The optional size has the same rules as `channel`: omission or nil gives
capacity 1, and an explicit value must be positive. Each `write` sends one
string message. `read` returns one message, except that it first returns any
suffix retained by an earlier `read_until`. The pair inherits FIFO order, the
single blocked operation in each direction, unconditional same-direction
no-barging, cancellation, and deferred wake behavior from its channel.

`read_until` finds the first literal, binary-safe delimiter even when it spans
adjacent messages. It accumulates the safe prefix while retaining only the
possible delimiter tail between receives. On a match it returns through the
delimiter, or omits it when `chop` is true, and saves bytes after the delimiter
for the next read. On an open reader, an empty delimiter raises.

Both close methods call the same synchronous, idempotent channel close.
`ChannelReader:close` additionally marks that reader closed and discards its
saved suffix, so read calls begun after its close return nil. This does not
turn an already-blocked read into EOF: closing either endpoint wakes installed
channel operations, which raise `"channel is closed"`, as do later writes.
Writer close does not discard `ChannelReader`'s already received excess: a
reader may still return that suffix, or satisfy a delimiter match from it, but
the first operation that needs another channel receive raises the close error.
An authoritative Task cancellation can instead win the same unwind.

## Terminal listeners and Task combinators

Tasks expose terminal-state observation directly:

```text
function Task:add_terminal_listener(
    listener: function (TaskStatus<|A, B|>): ()): function (): ()
```

An unfinished Task creates one fresh registration, appends it in registration
order, and returns an idempotent no-argument remover for that exact
registration. Invoke the remover in `defer` immediately after registering. Two
registrations of the same listener remain distinct; removing one never depends
on original or adjusted closure identity. Adding a listener to an already
terminal Task returns an idempotent no-op remover.

Before publishing a final status, the Runtime retires any current explicit
suspension token and pending wake. A terminal listener that calls `resume` on
the terminating Task therefore receives the unconditional `unknown source`
mismatch, even when a callback-boundary failure ended the Task without an
ordinary wake delivery.

Once the final status has been stored, the main-thread continuation driver
detaches the registration Array as a stable delivery snapshot, installs an
empty live list, and marks every detached registration no longer live. It
invokes every snapshot listener in sequence without consulting the live bit and
ignores any error raised by a listener. Calling a remover during delivery is
therefore a no-op and cannot shift the snapshot or skip a later callback. A
listener observes the exact terminal `TaskStatus<|A, B|>` and cannot replace it.

The fixed-arity combinators build on listeners plus explicit suspension. Each
operand keeps its independent success and cancellation types; the parameter
order is the interleaved `(A1, B1, A2, B2, ...)` operand order:

```text
function any_two<|A1, B1, A2, B2|>(
    first: Task<|A1, B1|>, second: Task<|A2, B2|>): AnyTwoResult<|A1, A2|>
function any_three<|A1, B1, A2, B2, A3, B3|>(
    first: Task<|A1, B1|>, second: Task<|A2, B2|>,
    third: Task<|A3, B3|>): AnyThreeResult<|A1, A2, A3|>
function any_four<|A1, B1, A2, B2, A3, B3, A4, B4|>(...):
    AnyFourResult<|A1, A2, A3, A4|>
function any_five<|A1, B1, A2, B2, A3, B3, A4, B4, A5, B5|>(...):
    AnyFiveResult<|A1, A2, A3, A4, A5|>

function race_two<|A1, B1, A2, B2|>(
    first: Task<|A1, B1|>, second: Task<|A2, B2|>):
    RaceTwoResult<|A1, B1, A2, B2|>
function race_three<|A1, B1, A2, B2, A3, B3|>(...):
    RaceThreeResult<|A1, B1, A2, B2, A3, B3|>
function race_four<|A1, B1, A2, B2, A3, B3, A4, B4|>(...):
    RaceFourResult<|A1, B1, A2, B2, A3, B3, A4, B4|>
function race_five<|A1, B1, A2, B2, A3, B3, A4, B4, A5, B5|>(...):
    RaceFiveResult<|A1, B1, A2, B2, A3, B3, A4, B4, A5, B5|>

function all_two<|A1, B1, A2, B2|>(
    first: Task<|A1, B1|>, second: Task<|A2, B2|>): (A1, A2)
function all_three<|A1, B1, A2, B2, A3, B3|>(...): (A1, A2, A3)
function all_four<|A1, B1, A2, B2, A3, B3, A4, B4|>(...):
    (A1, A2, A3, A4)
function all_five<|A1, B1, A2, B2, A3, B3, A4, B4, A5, B5|>(...):
    (A1, A2, A3, A4, A5)

function join<|A, B|>(task: Task<|A, B|>): TaskStatus<|A, B|>
function join_two<|A1, B1, A2, B2|>(...):
    (TaskStatus<|A1, B1|>, TaskStatus<|A2, B2|>)
function join_three<|A1, B1, A2, B2, A3, B3|>(...):
    (TaskStatus<|A1, B1|>, TaskStatus<|A2, B2|>, TaskStatus<|A3, B3|>)
function join_four<|A1, B1, A2, B2, A3, B3, A4, B4|>(...):
    (TaskStatus<|A1, B1|>, TaskStatus<|A2, B2|>,
     TaskStatus<|A3, B3|>, TaskStatus<|A4, B4|>)
function join_five<|A1, B1, A2, B2, A3, B3, A4, B4, A5, B5|>(...):
    (TaskStatus<|A1, B1|>, TaskStatus<|A2, B2|>, TaskStatus<|A3, B3|>,
     TaskStatus<|A4, B4|>, TaskStatus<|A5, B5|>)
```

Only `join` has a single-Task form. Unary `any`, `race`, and `all` would have
the same scheduling behavior as `join` and would differ only in how they wrap
its one terminal status or result, so those APIs are intentionally absent.

`AnyNResult<|A1,...,AN|>` has positional `first`, `second`, `third`,
`fourth`, and `fifth` variants carrying the corresponding success type, as
applicable, plus a payload-free `none` variant. It needs no cancellation type
parameters because it never exposes a cancellation status. `any_*` returns the
first observed success, or `none` once every input failed or was cancelled.

`RaceNResult<|A1,B1,...,AN,BN|>` has the same positional variants, each carrying
the corresponding `TaskStatus<|Ai, Bi|>`. `race_*` returns when any input succeeds,
fails, or is cancelled.

`all_*` returns every exact `Ai` success payload as multiple results. On the
first observed failed or cancelled input it raises
`AllNError<|A1,B1,...,AN,BN|>`; these unions have positional variants carrying
that operand's exact terminal status. `join*` instead waits for every input and
returns all exact final statuses without raising them.

Each operation first inspects its named operands from left to right. If its
condition is not already satisfied, it installs a separate terminal listener
on each still-relevant operand and suspends exactly once. The listeners capture
the operation's counters, result slots, or winner and one fresh private token
for that invocation. The listener that makes the result decidable resumes the
suspended Task with that token. The combinator calls every returned remover
with `defer`, including when someone else cancels it while it is suspended. It
never collects the operand Tasks into an Array.

The initial scan supplies the left-to-right tie break when multiple operands
are already terminal. Later terminal notifications are observed in publication
order; listeners installed more than once on one duplicate Task run in
registration order, preserving the leftmost position. Passing the current
Task, obtained through `async.running()`, is rejected because a Task cannot
wait for itself. Returning or raising from a combinator never cancels
unfinished inputs.

For example, a read with a five-second deadline can wait for the first
successful Task, then clean up the loser according to what it owns. The timer
deadline owns no connection state, so after a successful read its cancellation
may finish in the background. The read owns the parser or connection operation,
so after the deadline wins its cancellation is joined before that shared state
is released:

```titan
local reading = async.run<|string?, value|>(function (): string?
  return connection:read()
end)
local deadline = async.run(function (): nil
  timer.sleep(5000)
end)

local result = async.any_two(reading, deadline)
case result
when first(data) then
  deadline:cancel(async.CancellationReason.simple("read completed"))
  consume(data)
when second() then
  reading:cancel(async.CancellationReason.simple("read timed out"))
  async.join(reading)
when none() then
  -- Both Tasks failed or were cancelled; inspect their final statuses.
  local read_status, deadline_status = async.join_two(reading, deadline)
  report(read_status, deadline_status)
end
```

## The callback/continuation model

There is one non-reentrant event-loop driver. Only top-level `async.loop()` or
the standalone bootstrap calls `uv_run`, and it does so from the Lua main
thread. Libuv explicitly forbids calling `uv_run` from a callback; therefore
no Task continuation, callback handler, or private dispatcher drives the loop.

An ordinary operation-completion turn has this shape:

1. libuv invokes an operation's callback;
2. the callback handler resumes the suspended Task with that operation's
   result, or raises its error at the suspension point;
3. the Task runs synchronously until it returns, raises, or calls another
   asynchronous operation;
4. that operation yields a private tagged union variant whose record contains
   the corresponding libuv call parameters;
5. the callback handler invokes that record's dispatcher, which performs any
   synchronous preparation, submits the next callback-taking libuv function,
   and returns; and
6. the callback handler returns to libuv.

One-shot timers have a stricter lifetime path: `timer_cb` submits `uv_close`
without resuming user code, then `close_cb` releases the owner and resumes the
suspended Task. Correct-token explicit resume and cancellation of
`async.suspend` use these Task-owned one-shot timers. Native operation and
persistent-source callbacks instead enter their source-private continuation
path; they do not invent, receive, or validate public resume tokens. There is no
taskless timer, check/idle phase bridge, or implicit ready queue.

After libuv accepts a one-shot callback-bearing submission, its next progress
comes from a later loop turn. A negative synchronous submission result is the
opposite case: libuv guarantees that no callback will follow, so the dispatcher
immediately raises that error back into the same continuation. A persistent
source may also complete dispatch immediately from already buffered or
terminal state; no new native submission was accepted in that immediate path.

This is the logical equivalence at the center of the design: a coroutine
yield/resume pair is a direct-style spelling of a callback whose body is the
suspended coroutine's continuation. There is no ready queue and no central
scheduler state machine. CPU-heavy Titan code that neither finishes nor
yields blocks the loop just like CPU-heavy code in an ordinary callback.

One-shot requests each own their native request, one suspended Task, and only
the arguments libuv still borrows until the terminal callback. Multiple stream
writes retain their original immutable strings through their `uv_write_t`
callbacks and let libuv supply native request ordering. Titan does not
duplicate that queue or copy the write payload.

Repeating timers, stream reads, listeners, and other multi-shot handles keep
only their natural buffered state plus at most one waiter. A stream callback
appends data when there is no reader; a ticker remembers that at least one tick
occurred. A callback clears its waiter before directly resuming or scheduling
it. A directly resumed continuation may install the next waiter before that
callback returns.

Allocation callbacks and `uv_walk` callbacks are direct plumbing callbacks,
not coroutine-shaped calls. They update the owning record and return
immediately. Because an allocation callback cannot unwind through libuv, an
allocation exception is preserved for its required paired read callback,
which raises it at the Task boundary (or logs it when no Task is waiting).

## Errors and cancellation

Libuv-facing failures raise `async.OperationError`. `operation` identifies the
failed action. The original path, host, signal, or other argument is not
duplicated in every record; callers already own that context when it matters.

If any value escapes a Task function, the Runtime stores
`Error.new(error, traceback)` in `TaskStatus.failed`. The `error` field keeps
the exact value, so an operation failure remains available as an
`OperationError`; the traceback is the raw unified Titan/Lua trace captured at
the terminal Task boundary. An uncaught error still terminates and is reported
by the Task that raised it. Inspecting that status later with `race`, `all`, or
`join` does not suppress the existing report. Other Tasks continue, and
ordinary shutdown begins only after no active Tasks remain.

An uncaught `OperationError` report includes the operation, symbolic error
name, numeric code, and message before the traceback. Other raised values use
Lua's ordinary string conversion. Rendering preserves the original error
value in the failed Task even if conversion itself fails.

`cancel(reason)` is sticky and preserves the first `CancellationReason<|B|>`
directly in the Task. Nil selects
`CancellationReason.simple("cancelled")`. The expected
`CancellationReason<|B|>?` parameter supplies `B` through the ordinary option
wrap; without such context the generic final carrier rule chooses `value`. The
`simple` arm covers ordinary
text reasons; `complex` retains a payload of `B` for protocols that need a
structured reason. The reason remains private while the public snapshot stays
in its current nonterminal state. The stored union value is injected at
cancellation-sensitive suspension boundaries, while the outstanding request
determines the final `cancelled` status even if user code catches, transforms,
or returns from that value. Ownership-retiring close and cleanup calls are
cancellation-insensitive: they are still submitted and receive their ordinary
completion while cancellation remains pending. An accepted one-shot request
and its buffer storage remain alive through its promised callback. A
multi-shot wait detaches and wakes on its own later callback rather than being
resumed synchronously inside the Task that requested cancellation. An
explicitly suspended Task is likewise woken through its coalesced Task-owned
timer, so deferred listener removal runs normally as cancellation unwinds it.

## Resources and shutdown

Explicit resource close remains preferable: it reports errors at the relevant
call site and releases native resources early. Close is idempotent at the
public facades. A second concurrent waiter for a one-reader resource is
rejected instead of creating a queue.

When the last Task finishes, the Runtime rejects creation of new handles and
starts a private cleanup Task. It calls `uv_walk` to discover the loop's
handles and closes each non-closing handle through the ordinary asynchronous
`uv_close` callback path while the one outer event loop continues to run. A
final `uv_loop_close` success is the proof that requests and handles were
drained.

A child-process watcher is an ordinary libuv handle during this traversal.
Closing it retires the watcher; it does not signal, wait for, or reap the
child, which may outlive the Runtime. Application code that owns a child's
lifecycle must explicitly call `Process:kill` and/or `Process:wait` as needed
before its Tasks finish.

A File owns an operating-system descriptor, not a libuv loop handle. The
Runtime neither registers nor closes these descriptors during shutdown:
application code owns explicit `File:close()`, and process teardown reclaims a
descriptor that was deliberately left open.

The Runtime keeps a sparse Task inventory and a sparse live-owner set for the
C-to-Titan callback bridge. The former determines when the last Task has
finished and lets `os.exit` cancel other Tasks; the latter exists only for GC
reachability and is never traversed. Neither is a parallel libuv-resource
list, scheduling queue, or source of shutdown traversal; libuv remains
authoritative for its handle set.

`os.exit(code)` requests successful program exit, cancels the remaining Tasks,
runs the same cleanup path, and lets the generated entrypoint return the
requested status. It does not call ISO C `exit` around an embedding's Lua
state.

See the [timer](standard-library-timer.md),
[filesystem](standard-library-fs.md), [network](standard-library-net.md),
[operating-system](standard-library-os.md), and
[I/O](standard-library-io.md) chapters for their public APIs.
