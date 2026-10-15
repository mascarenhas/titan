# Asynchronous I/O and tasks

Titan's public asynchronous scheduling API is the `async` module. Titan code
imports it with `local async = import "async"`; Lua uses
`require "titan.async"`. The module supports Linux and macOS; the Windows port remains experimental. The public
`titan.uv` binding supplies typed libuv owners and callbacks. `titan.async`
combines those callbacks with Titan coroutines to own Tasks and waits. Ordinary
applications can use `async`, `timer`, `fs`, `net`, `io`, and `os`; library
adapters may also import `titan.uv` through its public compiled interface.

On Unix, initializing async changes a default `SIGPIPE` disposition to
ignored so a closed stream produces an `async.OperationError` instead of terminating
the process. An inherited ignored disposition or application-installed
handler is preserved.

## Runtime close listeners

`add_close_listener(listener)` registers ordered, once-only cleanup on the
active Runtime and returns an idempotent remover. It does not create a Runtime
and rejects registration after shutdown begins. A listener runs outside any
Task, after every Task and native handle has retired and the loop has closed,
but before the Runtime is cleared. It must not yield, start Tasks, or use the
retired loop. It can release non-handle resources retained by a domain owner,
such as an idle connection's TLS engine. Ordinary active resources still need
lexical cleanup while their Tasks can perform asynchronous retirement.

Removing a later listener during notification skips it. Every remaining
listener runs even if another raises; `loop()` preserves the first Runtime or
listener failure and raises it after notification and Runtime clearing. A later
`run` can create a fresh Runtime. Listeners are released at retirement, and an
explicitly closed owner should remove its listener to release its capture early.

## Scheduling and driving Tasks

The async module defines `Task`, `TaskStatus`, `CancellationReason`,
`ResumeToken`, `Error`, and `OperationError`. They are ordinary public nominal
types owned by async, with the constructors, fields, tags, methods, and generic
positions shown below. Their move from the old private UV implementation does
not change these public programming contracts. Rebuild consumers against the
canonical provider; the defining-module metadata changes even though the
generated-code ABI remains at version 2.

```text
type SuspendCancelAction = function (): ()

function run<|A, B|>(func: function (): (A)): Task<|A, B|>
function run_foreign(f: foreign function (*void): void, arg: foreign *void)
function loop()
function add_close_listener(listener: function (): ()): function (): ()
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

Async owns the following public declarations:

```text
record ResumeToken
  const source: string?
end

record Error
  error: value
  traceback: string
end
function Error:raise()

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

`async.run<|A, B|>(func)` creates and roots a Task, queues its startup, and
returns without calling `func`. The Runtime retains an all-value view of that
same Task while its public type preserves `A` and `B`. One Runtime-owned
zero-duration timer services a FIFO queue of Task startups, explicit yields,
signal resumes, and peer-Task settlements. Each callback handles at most 64
entries present at its start; newly queued work waits for a later callback.
This gives other native callbacks opportunities to run during sustained Task
activity. Calling `run` from another Task is valid and still does not run the
new Task inline. Scheduling no longer creates and closes a timer per wake;
ordering relative to unrelated native close callbacks can therefore differ.

`Task:status()` returns a snapshot. Repeated observations during one state
transition return the same snapshot; a later transition gets a fresh snapshot,
even if its tag is again `running` or `waiting`. Retained snapshots never
change. Unobserved nonterminal transitions do not construct public snapshots.

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

A NULL worker function is rejected before submission. A queue-submission
failure raises immediately. After successful submission,
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
`failed` payload is the caught Lua error value and raw traceback wrapped in
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
Create it through the async constructor, for example
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

The first correct-token wake request appends the target Task to the Runtime's
ready queue; later requests before delivery coalesce. Acceptance arms a needed
shared wake before committing the request. Delivery clears the old suspension
and queue entry before resuming the Task. This guarantees callback-deferred
delivery but does not promise one exact libuv iteration.

## Adapting callbacks with await

Library code can combine ordinary imports of `titan.async` and `titan.uv` to
adapt a public libuv callback API into a direct-style operation. No source
import, private Task field, C callback trampoline, or operation-specific
scheduler registration is needed.

```text
union Result<|T, E|>
  success(T)
  error(E)
end

union CancellableResult<|T, E|>
  success(T)
  error(E)
  cancelled(CancellationReason<|value|>)
end

record Completion<|C, T, E|> -- opaque; no public constructor
function Completion:context(number: integer): C
function Completion:resolve(number: integer, result: T)
function Completion:reject(number: integer, error: E)
function Completion:fatal(number: integer, error: value, traceback: string)

function await_with<|C, T, E|>(context: C,
    start: function (Completion<|C, T, E|>, integer): (uv.req_t?)):
    Result<|T, E|>
function await_cleanup_with<|C, T, E|>(context: C,
    start: function (Completion<|C, T, E|>, integer): (uv.req_t?)):
    Result<|T, E|>
function await_cancellable_with<|C, T, E|>(context: C,
    start: function (Completion<|C, T, E|>, integer): (uv.req_t?)):
    CancellableResult<|T, E|>

function await<|T, E|>(op: function (
    function (T): (), function (E): (), function (value, string): ()): ()):
    Result<|T, E|>
function await_cleanup<|T, E|>(op: function (
    function (T): (), function (E): (), function (value, string): ()): ()):
    Result<|T, E|>
function await_cancellable<|T, E|>(op: function (
    function (T): (), function (E): (), function (value, string): ()):
    (uv.req_t?)): CancellableResult<|T, E|>
function current_loop(): uv.loop_t
function is_closing(): boolean
function checkpoint()
function request_exit(code: integer)
```

The `_with` forms pass one typed Completion and an operation number to `start`.
Prefer a named module function: it can obtain its inputs from
`done:context(number)` without allocating a captured registrar or three
capability closures. All three registrars have the same `uv.req_t?` return
shape. Ordinary and cleanup forms may return nil; returning a request there
does not request native cancellation. Only the cancellable form requires an
accepted request unless already settled inline. Construct a required request
view before native acceptance.

A Task reuses its private Completion storage. Each suspension has a checked,
increasing operation number. Capture the number supplied to this registration
alongside its Completion; never infer it from current Task state. `context`,
`resolve`, and `reject` reject a mismatched number. A duplicate settlement also
raises. Numbers do not wrap: exhausted suspension numbering raises
`async Task suspension epoch exhausted` before registration or enqueue.

Context access is scoped to the matching operation. Retirement clears the
context, registrar, request and payload before a continuation can start another
operation. Save context into callback locals or independently owned rollback
state **before** settlement or a registration exception. In particular, a
callback may settle A, synchronously run its Task into B, and then encounter an
exception while A's callback is still returning. Its saved `done` and A's
number remain the correct arguments for `fatal`; its context must already be
rooted locally. A stale `fatal` records Runtime failure without treating B as
A's completed native operation. Native ownership and normal shutdown
cancellation still apply to B.

For example, this complete adapter uses a canonical registrar and preserves
the public tagged result:

```titan
local async = import "async"
local uv = import "uv"

local function start_double(done: async.Completion<|integer, integer, nil|>,
                             number: integer): uv.req_t?
  local input = done:context(number)
  done:resolve(number, input * 2)
  return nil
end

function double(input: integer): async.Result<|integer, nil|>
  return async.await_with<|integer, integer, nil|>(input, start_double)
end
```

The callback-triple forms remain convenience facades over the same core.
Their registrations receive three capabilities for the exact operation:
`resolve(value: T)`, `reject(error: E)`, and
`fatal(error: value, traceback: string)`. The first two settle an expected
outcome once. The third reports an unexpected exception after that operation's
native terminal callback has been consumed; its stricter protocol is described
below. A typed rejection is an ordinary result, not a raised exception.
`success(nil)` and `success(false)` remain successful outcomes.

All await forms require a running Task. Registration runs after that Task has
yielded and outside a Task context: `async.running()` raises there. Capture the
current Task or any Task-only state before calling await when the adapter needs
it. `current_loop()` is valid during registration and callbacks. It returns the
active Runtime's public loop owner and raises when there is no active Runtime;
it does not create a Runtime or enter the loop. Treat that loop as borrowed.
The async driver owns its `uv.run` and final `uv.loop_close` calls, together
with its internal wake handle. Adapters may manage handles they created on the
loop; walking the borrowed loop does not authorize stopping, closing, or
unreferencing Runtime-owned handles. Like
`current_loop`, `is_closing()` raises when no Runtime is active; otherwise it
returns the Runtime's closing flag without requiring a Task or checking pending
Task cancellation. It is a synchronous admission query, not a suspension or
cancellation boundary. Requesting process exit is separate from a fatal closing
Runtime; code must not infer the exit policy from this flag alone.

`checkpoint()` requires a running Task, raises its first pending cancellation
reason, then checks for Runtime shutdown, in that order. It returns normally
when ordinary work is admissible. It neither yields nor changes Task status,
registers a wait, or permits another Task or native callback to run. Use it at
an existing admission boundary before transferring buffered resources; use
`yield()` when a scheduling boundary is intended. Cleanup operations use
`await_cleanup_with` or `await_cleanup` and do not acquire an ordinary checkpoint.

Registration must either settle inline or arrange a later completion. Inline
resolve/reject stores the outcome until registration returns; it does not
reenter the suspended Task from inside registration. The driver then continues
the Task through its existing trampoline, without requiring a fresh loop turn.
A callback running outside a Task can resume the waiter directly. Settlement
from a different running Task instead schedules a deferred continuation, so it
never runs another Task reentrantly. Duplicate resolve/reject calls raise.

Build native owners, callbacks, borrowed-buffer retention, and rollback state
before submission. A documented negative submission status means that no
callback was accepted: clean the unaccepted request and reject inline. Once
submission is accepted, return normally and retain everything the native
operation still borrows until its promised terminal callback. A registration
exception is raised at await; it is not an automatic rollback for native work
that the registration already accepted.

The await policy determines how pending Task cancellation is delivered:

| Form | Cancellation pending before registration | After native acceptance | Completion with cancellation pending |
| --- | --- | --- | --- |
| `await_with` / `await` | Skip registration and raise the first reason. | Retain the operation; do not implicitly cancel it. | Wait for terminal completion, then raise that reason. |
| `await_cancellable_with` / `await_cancellable` | Skip registration and return `cancelled(reason)`. | Attempt `uv.cancel` on the returned request; retain it regardless of the attempt's result. | Wait for terminal completion, then return `cancelled(reason)`. |
| `await_cleanup_with` / `await_cleanup` | Run registration. | Retain the operation without requesting native cancellation. | Return the ordinary success/error result. |

For cancellable registration, return the public `uv.req_t` view of the one
accepted request. Return nil only after settling inline; nil with an unsettled
wait raises `cancellable registration returned nil without settling`. A native
cancellation attempt does not establish that the request stopped. Even successful
cancellation still has a terminal callback. The `cancelled` payload uses the
all-value `CancellationReason<|value|>` application because the current Task is
observed through that view.

Task cancellation stays sticky in every form: returning from a caught reason,
handling `cancelled`, or completing a cleanup wait does not clear the Task's
first reason or turn its final status into success. Use `await_cleanup` only
for retiring ownership, such as close, finalize, reset, or disposal of an
unpublished result. It remains available during Runtime shutdown. It does not
shield a callback exception or guarantee successful cleanup. Other new awaits
are refused once fatal Runtime shutdown begins.

### Unexpected terminal callback failure

Protect the terminal callback's result conversion, explicit request cleanup,
and settlement. Expected native/domain errors use `reject(E)`. An unexpected
exception uses the registration's third callback and then a bare rethrow:

```titan
local callback = function (completed: uv.fs_t)
  local result = uv.fs_get_result(completed)
  -- Capture acquired resources or copy borrowed results before cleanup.
  uv.fs_req_cleanup(completed)
  if result < 0 then reject(result) else resolve(result) end
catch
  uv.fs_req_cleanup(completed)
  fatal(error, traceback)
  raise
end
```

This snippet belongs inside an `await<|integer, integer|>` registration. For an
operation that acquires a descriptor or another resource, first put that
resource in a lexical owner as in the File example below; request cleanup does
not dispose of the acquired resource.

Call `fatal` only outside a running Task, after this operation's native
completion has been consumed and its callback-local ownership is safe. It is
not permission to abandon an accepted request, cancel arbitrary native work,
or settle a still-live multi-shot producer. Pass the catch's original `error`
and `traceback`. The bare `raise` lets the public low-level binding complete
its required stop-and-rethrow boundary.

Preservation starts with the caught Lua error: a raised nil has already become
`"<no error object>"` under the ordinary [error rules](error-handling.md#raising-errors).
Typed `reject(nil)` is result data and does not itself raise an exception.

The capability belongs to this exact wait. If it is still pending, `fatal`
retires it and injects the exception so the owning Task can run lexical cleanup
immediately. If the callback already settled it, `fatal` records Runtime
failure without changing that settled outcome or a newer wait. During
registration, the outcome is held until registration returns. The first Runtime
error and raw traceback remain authoritative; after Task cleanup and native
drain, `async.loop()` rethrows that same error with that trace. A Task whose
cancellation was already pending still finishes cancelled. An otherwise
uncaught exception at the associated pending wait produces a failed Task.

This exception is outside generic `E`; it never fabricates an `E` value or
becomes `Result.error(E)`. Ordinary exceptions that escape a Task body remain
Task failures and do not by themselves fail the Runtime. An unprotected raw
callback has no exact-wait association: the driver can stop and clean up, but
cannot infer which accepted operation the callback belonged to. Custom adapters
must follow the explicit catch/fatal/rethrow protocol when consuming one-shot
completions.

With Completion, the same protocol is `done:fatal(number, error, traceback)`
followed by bare `raise`. Snapshot the exact capability, number, and required
context before settlement. If a privately owned UV data slot carries them,
detach its old association before settlement; clearing it afterward could
erase a successor's state. A new context record, captured number, bound method
such as `done.resolve`, or native view has its own allocation cost. Reuse
existing domain state only when its ownership and concurrency permit it;
overlapping writes require independent request and completion associations.

### A public-only File adapter

The following read-only example keeps an unpublished descriptor owner in the
open frame before it yields. A successful native open fills that owner before
request cleanup and before resolving. Cancellation may replace the successful
await result, so the catch still closes the unpublished File. Close uses a
cleanup wait and restores the descriptor only when submission was rejected
before acceptance; an accepted close never resurrects it.

The complete [File adapter example](async-file-example.titan) also supplies a
small read method. It demonstrates ownership, not the full `titan.fs` interface:
mode parsing, writes, buffered reads, and broader operation guards remain domain
work.

```titan
local async = import "titan.async"
local uv = import "titan.uv"

-- Documentation example: minimal read-only adapter using public APIs.
record File
  local descriptor: integer
end

local function operation_error(code: integer, operation: string): async.OperationError
  return async.OperationError(code, uv.err_name(code), uv.strerror(code), operation)
end

local function close_on(file: File, loop: uv.loop_t)
  if file.descriptor < 0 then return end
  local request = uv.fs_t.new()
  local descriptor = file.descriptor
  local accepted = false
  file.descriptor = -1
  do
    local outcome = async.await_cleanup<|integer, integer|>(function (
        resolve: function (integer): (), reject: function (integer): (),
        fatal: function (value, string): ())
      local callback = function (completed: uv.fs_t)
        local result = uv.fs_get_result(completed)
        uv.fs_req_cleanup(completed)
        if result < 0 then reject(result) else resolve(result) end
      catch
        uv.fs_req_cleanup(completed)
        fatal(error, traceback)
        raise
      end
      local status = uv.fs_close(loop, request, descriptor, callback)
      if status < 0 then
        uv.fs_req_cleanup(request)
        reject(status)
      else
        accepted = true
      end
    end)
    case outcome
    when success() then
    when error(code) then raise operation_error(code, "fs.close")
    end
  catch
    if not accepted then file.descriptor = descriptor end
    raise
  end
end

function File:close()
  if self.descriptor < 0 then return end
  close_on(self, async.current_loop())
end

function File:is_closed(): boolean
  return self.descriptor < 0
end

function open(path: string): File
  local file = File(-1)
  local request = uv.fs_t.new()
  do
    local outcome = async.await<|File, integer|>(function (
        resolve: function (File): (), reject: function (integer): (),
        fatal: function (value, string): ())
      local callback = function (completed: uv.fs_t)
        local result = uv.fs_get_result(completed)
        -- Own the acquired descriptor before request cleanup or Task resumption.
        if result >= 0 then file.descriptor = result end
        uv.fs_req_cleanup(completed)
        if result < 0 then reject(result) else resolve(file) end
      catch
        uv.fs_req_cleanup(completed)
        fatal(error, traceback)
        raise
      end
      local status = uv.fs_open(async.current_loop(), request, path,
          uv.FS_O_RDONLY as integer, 0, callback)
      if status < 0 then
        uv.fs_req_cleanup(request)
        reject(status)
      end
    end)
    case outcome
    when success(opened) then return opened
    when error(code) then raise operation_error(code, "fs.open")
    end
  catch
    -- await can raise cancellation after successful native acquisition.
    file:close()
    raise
  end
end
```

The terminal FS callback must call `uv.fs_req_cleanup` explicitly; the public
request wrapper's callback retirement is not a substitute for that libuv
operation. For a read, copy the valid buffer prefix before cleanup and
settlement. The awaiting frame and accepted request retain their public owner
records through the terminal callback. No private UV header or native FFI
import is required by this adapter.

### Program exit control

`request_exit(code)` requires a running Task. It records the first requested
status, requests cancellation of all unfinished Tasks including the caller,
and raises the caller's retained cancellation reason. New `run` calls are
rejected after the request. Lexical defers and cleanup awaits still run, and
the standalone bootstrap returns the requested status after draining the
Runtime. Catching the raised reason does not withdraw the exit request or
clear cancellation. In a host that explicitly calls `loop`, draining the
Runtime does not terminate the host process. The `os.exit` facade can use this
public operation without private scheduler access.

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
is released. This normal-winner sketch assumes the observing parent is not
cancelled. It illustrates loser ownership, not cleanup on every parent exit.
A reusable wrapper must install lexical cleanup immediately after each child
is created. Its reader cleanup cancels that child and waits for a removable
terminal listener through `async.await_cleanup` before releasing shared state;
ordinary `async.join` is itself cancellation-sensitive. The timer-only child
needs unconditional cancellation cleanup but does not need a terminal join.
See the [HTTP implementation](../implementation/http-library.md) for this
parent-cancellation-safe ownership pattern.

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

An async Runtime has one non-reentrant event-loop driver. Only top-level
`async.loop()` or the standalone async bootstrap drives its borrowed Runtime
loop with `uv.run`, from the Lua main thread. Independent low-level clients may
construct and drive their own public UV loop as described in the
[UV reference](standard-library-uv.md#start-with-an-explicit-loop). Neither
registration, a callback, nor a resumed Task drives any loop recursively.

An ordinary completion follows this path:

1. Public UV invokes the adapter's callback with public request/handle owners.
2. The adapter copies borrowed results or commits acquired resources to its
   lexical owner, performs explicit native cleanup, and resolves or rejects.
3. The exact wait is retired before the Task resumes. The Task runs until it
   returns, raises, or yields another generic registration.
4. Registration runs outside the Task. An accepted callback operation returns
   control to libuv; an inline outcome continues through a bounded trampoline.

The Task-to-driver protocol carries one generic registration plus its ordinary,
cancellable, or cleanup policy. It contains no filesystem, TCP, timer, or other
operation-specific variant. Public UV knows native ownership and callbacks;
async knows Tasks and waits; domain adapters decide how native results become
application values.

Scheduling a Task, yielding, and explicitly resuming a token-bound suspension
append to one Runtime FIFO driven by its reusable zero timer. A callback drains
at most 64 entries that were present when it began; it detaches each old entry
before advancing the Task. New work waits for a later callback. This promises
deferred delivery, not an exact libuv iteration. Ordinary callback settlement
can enter its Task continuation directly, while settlement from another running
Task is deferred.
CPU-heavy code that neither finishes nor yields blocks the event loop.

Persistent sources publish into coalescing or buffered subscriptions. A queued
value belongs to its queue until an item/batch result or explicit drain transfers
it. Producer notifications use the same token-based deferred wake as other
explicit suspensions. The native handle may be shared or cover several sources;
the adapter's stop/close actions express that ownership.

Allocation callbacks, synchronous walk callbacks, and worker functions are not
await registrations. Follow the public UV contract for their permitted work and
paired native lifetimes. A worker function runs only raw C and never enters the
Lua/Titan runtime. A loop-thread callback must finish its native ownership
obligations before it raises through the public UV error boundary.

## Persistent callback subscriptions

Subscriptions connect a persistent producer to one waiting consumer. Use a
`CoalescingSubscription` when only the latest unconsumed value matters, such as
a tick. Use a `BufferedSubscription` when every event and its order matter.
Neither abstraction starts native work by itself; the producer supplies the
native start, stop, and close behavior through public APIs.

```text
record SubscriptionBatch<|T|>
  const count: integer
end
function SubscriptionBatch:get(index: integer): T

union SubscriptionResult<|T, E|>
  item(T)
  error(E)
  ended()
  closed()
end
union SubscriptionBatchResult<|T, E|>
  batch(SubscriptionBatch<|T|>)
  error(E)
  ended()
  closed()
end

record SubscriptionActions<|T|>
  const stop: function (): ()
  const close: function (function (): (SubscriptionBatch<|T|>)): ()
end

record CoalescingSubscription<|T, E|>
end
record BufferedSubscription<|T, E|>
end

function CoalescingSubscription.new(producer: function (
    function (T): (boolean), function (E): (boolean), function (): (boolean)):
    (SubscriptionActions<|T|>)): CoalescingSubscription<|T, E|>
function BufferedSubscription.new(producer: function (
    function (T): (boolean), function (E): (boolean), function (): (boolean)):
    (SubscriptionActions<|T|>)): BufferedSubscription<|T, E|>

function CoalescingSubscription:next(): SubscriptionResult<|T, E|>
function CoalescingSubscription:has_waiter(): boolean
function CoalescingSubscription:stop()
function CoalescingSubscription:close()
function BufferedSubscription:next(): SubscriptionResult<|T, E|>
function BufferedSubscription:has_waiter(): boolean
function BufferedSubscription:has_pending(): boolean
function BufferedSubscription:next_batch(): SubscriptionBatchResult<|T, E|>
function BufferedSubscription:stop()
function BufferedSubscription:close()
function BufferedSubscription:drain_pending(): SubscriptionBatch<|T|>
function BufferedSubscription:drain_if(predicate: function (T): (boolean)):
    SubscriptionBatch<|T|>?
function BufferedSubscription:wake_batch()
```

### Producer registration and ownership

Construction invokes `producer(publish, fail, finish)` synchronously. The
producer must prebuild its `SubscriptionActions` and rollback state before
accepting native resources. Until it returns those actions successfully, it
owns partial-registration rollback. Construction may publish inline; a current
Task is needed only when producer setup itself uses Task-dependent operations.

`publish(item)` returns true after queueing ownership and accepting any required
waiter wake. False means that the subscription is terminal and did not accept
the item. A synchronous exception also leaves the item with the producer; a
failed wake rolls the queue change back. For resource-bearing events, dispose
of the resource on either false or exception. After true, the consumer or the
subscription's close action owns disposal.

A coalescing queue replaces its previous unconsumed value. It does not return
or explicitly dispose of that old value, so its payload must be safely
discardable. Put accepted sockets, native allocations requiring disposal, and
other resource-bearing events in a buffered queue. Buffered publication has
no capacity bound or implicit producer backpressure; the domain adapter must
supply such a policy if its resource model needs one.

`fail(error)` and `finish()` select the first terminal error or normal end.
They return false once any terminal state has been selected. A failed wake
raises and leaves the prior terminal state intact. These capabilities do not
call the producer's stop or close action; a native source that must stop at
EOF/error should do so in its adapter. A callback that fails unexpectedly
must complete its local ownership rollback/transfer before raising. Runtime
failure then cancels pending subscription readers through ordinary Task
cancellation; subscriptions do not expose a one-shot `fatal` capability.

### Reading values and batches

`next()` returns `item(value)`, then the sticky terminal error/end after queued
items have drained. `closed()` has immediate priority and ordinary reads do
not drain unread items after close. A live empty queue suspends. The operation
requires a current Task even when data or terminal state is already available,
and it checks pending cancellation before transferring a queued item.

At most one pending reader is admitted across `next` and `next_batch`. A
notified reader keeps its reservation until it resumes or unwinds; a competing
reader raises `subscription already has a waiter`. Cancelling the reader
detaches its exact waiter and schedules the normal deferred token wake. It
does not stop or close the producer, discard events, or consume a queued
resource. Another Task may subsequently read the preserved queue. A read after
cancellation is still subject to the current Task's sticky cancellation.

`next_batch()` atomically detaches the entire current FIFO into a stable
`SubscriptionBatch`. Later publications enter a new queue. `count` is the
number of values, and `get(1)` through `get(count)` return them in publication
order; out-of-range access raises. Iterate using `count`, never Array length or
payload truthiness. Both nil and false are ordinary present payloads in a
single item or a batch. The generic result tags distinguish those payloads from
error, end, and close.

A batch transfers all its items to the receiver. If the domain needs additional
allocation, conversion, or classification after extraction, it must retain and
clean those items when that work raises or is cancelled. For accepted clients,
prebuild the public connection facade before publication so extraction does
not introduce an unowned native handle. A domain operation guard may need to
cover the entire later classification phase, since the subscription waiter
reservation ends when `next_batch()` returns.

`BufferedSubscription:has_pending()` is a synchronous, nonconsuming snapshot:
it is true for any queued item (including nil or false) or selected error, end,
or closed state. It does not reserve a reader or check Task cancellation. False
only means the live queue is currently empty; it does not predict later events.

`has_waiter()` is a synchronous query on either subscription type. It reports
the same reader reservation that cancellation detaches, including a reader whose
wake is queued but whose wait has not yet exited. It does not consume an event,
create a reservation, or check Task cancellation. A domain method can therefore
preserve its single-reader admission check even when it could otherwise return
already buffered data immediately. The query is a snapshot; use the actual
subscription operation to establish a wait, and keep any longer domain operation
guard separately.

### Stop and close

`stop()` is synchronous and idempotent. It records that stop was requested,
changes a live subscription to ended, and calls `actions.stop()` once. That
action must not suspend. Already queued items stay available before ended;
a prior error stays the terminal error. Stop is not native close and does not
await a close callback. The producer must arrange its native stop behavior and
keep any remaining owners alive.

`close()` requires a current Task on its first invocation. It marks the queue
closed before cleanup, prevents further ordinary delivery, and runs stop plus
`actions.close(drain)`. The close action is armed before a fallible stop/wake and
may suspend through `await_cleanup` to retire native resources. The supplied
`drain()` synchronously detaches all currently unread items as a counted batch;
the close action must dispose of unread resource-bearing items. It may drain
more than once; an empty drain has count zero. After the action returns or
raises, the core discards its remaining payload references and action closures.
Do not retain the drain callback beyond that cleanup operation.

Repeated close calls start no new cleanup, including while the first close is
suspended; they are not joins on that cleanup's completion. Arrange one lexical
owner for final close and use explicit domain coordination when other code
must wait for it. Cancellation of a read does not mean cancellation of this
shared owner. Several subscriptions may refer to one handle, or one subscription
may refer to several handles; their actions must express the actual ownership.
A subscription never assumes that its waiter owns every resource behind it.

### Domain controls for buffered queues

These producer-side controls are synchronous and do not suspend:

| Operation | Behavior |
| --- | --- |
| `drain_pending()` | Detach the entire current queue, including an empty one, without changing terminal state. |
| `drain_if(predicate)` | Inspect in FIFO order; if any item matches, detach the entire queue in its original order. Return nil without detaching when none match. |
| `wake_batch()` | Notify only an existing `next_batch` waiter. It stores no future wake credit and does not end the subscription. |

The `drain_if` predicate must not yield or mutate this subscription, including
publishing, draining, stopping, or closing it. Read domain state without changing
the queue. The scan and detach then remain one operation. A predicate exception
propagates before detachment; the queue keeps ownership. This is a conditional
whole-batch transfer, not an item filter.

When a domain control drains items reserved for an already notified reader,
finish the corresponding terminal/control transition in the same nonyielding
callback before that reader can run. Do not drain away a notified `next()`
reader's only outcome and leave the subscription live and empty.

`wake_batch()` may resume a live empty batch waiter with a zero-count batch.
It does nothing for a single-item waiter or when no batch waiter exists, and
repeated pending wakes coalesce. If events are already queued, they remain the
returned batch. This supports a reusable watcher whose final native registration
was removed: wake the current poll empty, then allow later registrations without
inventing a new terminal state or reopening the subscription.

A watcher can detach raw notifications, classify that batch while yielding, and
then use `drain_if` to collect the entire follow-on batch only if one entry
refers to a retired registration. New batches containing only live registrations
remain for the next poll. TCP reads similarly preserve copied chunks before
EOF/error. A TCP accept adapter whose contract puts listener failure ahead of
unread clients must instead drain and initiate retained closes for those clients
before publishing its terminal error. Generic queue ordering does not replace
these domain policies.

## Errors and cancellation

The standard domain facades raise `async.OperationError` for expected
libuv-facing failures. `operation` identifies the failed action. Generic await
adapters may instead return their chosen `E` through `Result.error` or
`CancellableResult.error`. The original path, host, signal, or other argument is not
duplicated in every record; callers already own that context when it matters.

If a value escapes a Task function without pending cancellation, the Runtime
stores `Error.new(error, traceback)` in `TaskStatus.failed`. A Task with a
pending reason instead reaches `TaskStatus.cancelled`. The `error` field keeps
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

### Preserving supervised errors

`async.Error(error, traceback):raise()` raises the original value with its saved
traceback. Use it when an owned I/O child catches a failure, returns it to its
supervisor without an uncaught Task diagnostic, and the supervisor retires
resources before propagating that same failure. It preserves nominal error
identity and the original failing operation's frames; it does not cancel Tasks
or transform the value into an `async.Error` at the catch boundary.

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
subscription wait detaches and wakes through its deferred token continuation
rather than resuming inside the Task that requested cancellation. An
explicitly suspended Task likewise receives one coalesced continuation in the
Runtime's FIFO, so deferred listener removal runs normally as cancellation
unwinds it.

## Resources and shutdown

Explicit resource close reports failures at the relevant call site and releases
native resources early. Close belongs to the lexical owner that knows what must
be disposed of. The generic Runtime cannot infer that a descriptor returned by
an open or a native object returned by a worker was never published.

A fatal callback/driver failure records the first error and cancels other Tasks.
Task-owned cleanup remains runnable through `await_cleanup`; accepted native
requests and their borrowed storage stay alive until their terminal callbacks.
The driver keeps scheduler wakes and cleanup handles available while Tasks
unwind. Only after all Tasks retire does it walk and close remaining non-closing
handles, drain their callbacks, and close the loop. It also visits initialized
inactive handles, which do not count toward native loop liveness. Successful
loop close completes the Runtime session; a later `run` creates a fresh one.

If the loop becomes idle while Tasks are still waiting without native progress,
the driver reports that failure and unwinds the exact stranded waits. It does
not substitute a new wait installed by cleanup for an older captured wait, or
discard an already scheduled explicit wake. A low-level callback failure with
no operation-local fatal association still cannot identify a consumed request's
wait early; custom one-shot adapters need the documented fatal protocol.

Closing a child-process watcher retires its handle; it does not signal, wait
for, or reap the child. Code that owns the child's lifecycle must use the domain
process kill/wait operations as required before its Tasks finish. A File owns
an operating-system descriptor, not a loop handle. The Runtime does not close
such descriptors through `uv.walk`; application code owns explicit File close.

Async maintains the sparse live-Task inventory needed for scheduling lifetime,
exit, and shutdown. Public UV separately roots live native requests/handles for
callback safety. Domain adapters own unpublished resources and shared-handle
policies. None of those layers replaces libuv's authoritative native handle
walk or invents an operation dispatcher in the low-level binding.

`os.exit(code)` uses `async.request_exit`: it requests cancellation and cleanup,
then lets the standalone entrypoint return the requested status. It does not
call ISO C `exit` around an embedding's Lua state.

See the [timer](standard-library-timer.md),
[filesystem](standard-library-fs.md), [network](standard-library-net.md),
[operating-system](standard-library-os.md), and
[I/O](standard-library-io.md) chapters for their public APIs.
