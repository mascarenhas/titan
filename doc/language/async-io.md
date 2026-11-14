# Asynchronous I/O and tasks

Titan's public asynchronous scheduling API is the `async` module. Titan code
imports it with `local async = import "async"`; Lua uses
`require "titan.async"`. The module supports Linux, macOS and the
[browser target](#the-browser-target); the Windows port remains experimental. The public
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
positions shown below. Rebuild consumers against the matching `titan.async`
provider; the generated-code ABI is version 2.

```text
type SuspendCancelAction = function (): ()

function run<|A, B|>(func: function (): (A)): Task<|A, B|>
function run_with_cleanup<|A, B|>(
    body: function (): (A),
    cleanup: function (CancellationReason<|B|>?): (),
    final_wait: ExternalWait?): Task<|A, B|>
function run_foreign(f: foreign function (*void): void, arg: foreign *void,
                     abandoned: foreign function (*void): void)
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

`async.run_with_cleanup<|A, B|>(body, cleanup, final_wait?)` starts a Task
through a wrapper instead of ordinary `run`'s shortcut for a Task cancelled
before it starts. On entry the wrapper **installs** a `defer` that calls
`cleanup(reason)`, and only then performs `checkpoint()` and `body()`. Cleanup
therefore runs when the body exits or unwinds, not before it. It receives the
first sticky `CancellationReason<|B|>?`, or nil when the Task was not
cancelled. Cleanup may perform cancellation-insensitive retirement work, but
entering an ordinary callback is not by itself a guarantee that native
ownership has retired. That is the job of the optional third argument.

The optional `final_wait` argument designates one prepared native-retirement
`ExternalWait`, created by `prepare_native_retirement`, as the Task's exclusive
ownership-retirement gate. An ordinary `prepare_external_wait` result is not
eligible. The capability must be live, unused, unbound, and prepared by the
same Runtime. A wrong-kind, other-Runtime, consumed, closed, or already-bound
capability is rejected before the Task is exposed. The constructor allocates
the Task's reusable Completion up front and revalidates the capability
afterwards. If admission fails, the constructor rolls back its native
registration and binding without treating the original domain resource as
retired: the caller still owns that resource.

The constructor arms the gate before returning the Task. The Task's terminal
status and terminal listeners stay blocked until native retirement completes,
even if an ordinary root or cleanup entry fails or no cleanup ever waits.
Ordinary callbacks can still allocate and fail; allocating the Completion up
front does not make them allocation-free.

An explicit `final_wait:wait_cleanup()` is optional. Only the bound Task's
cleanup may attach it to the already-armed gate. That exact capability, used
from that cleanup with its own registrar, may use the Task's last suspension
number (`LUA_MAXINTEGER`). Every other suspension of the designated Task is
limited to `LUA_MAXINTEGER - 1`: generic cleanup awaits, an aliased capability
with another registrar, body code, and peer Tasks cannot take the privilege.
Without a third argument the ordinary finite limit applies. Exhaustion raises
`"async Task suspension epoch exhausted"` without reset or wrapping. Native
retirement itself does not depend on an available suspension number. See
[native retirement capabilities](#native-retirement-capabilities). The thread
standard library supplies the concrete Thread callbacks and binds them to its
`Thread:task()` proxy
([thread retirement wiring](../implementation/thread-library.md#join-proxy-retirement-and-the-native-terminal-barrier)).

`Task:status()` returns a snapshot. Repeated observations during one state
transition return the same snapshot; a later transition gets a fresh snapshot,
even if its tag is again `running` or `waiting`. Retained snapshots never
change. Unobserved nonterminal transitions do not construct public snapshots.

`async.run_foreign(f, arg, abandoned)` submits the C function pointer and
argument to libuv's process-wide worker pool and suspends the current Task
until the after-work callback runs on the event-loop thread. It is intended
for blocking calls into an external C library. A restricted source
`foreign function` is permitted because the compiler emits it as an exact C
callback; its body must remain within the raw-C restrictions below. The
optional `abandoned` (omit it or pass nil) is a C-only release for `arg`,
called only when a Lua state close abandons the wait; see
[foreign work at state close](#foreign-work-at-state-close).

The worker performs exactly `f(arg)`. It must not inspect or mutate the
hosting Lua state's Titan/Lua objects, call the Lua API on that state, invoke
its Titan functions or closures, allocate through its runtime, raise into its
frames, or resume its Tasks. The argument must identify native storage that
remains alive until completion. Passing an `owned` C allocation keeps that
owner alive in the suspended caller, but the caller is still responsible for
synchronization and must not concurrently access bytes that the worker may
read or write.

`run_foreign` does not change the worker thread's floating-point state either.
A pool thread keeps whatever state its previous job left, and on Windows a new
thread starts with 53-bit x87 precision, so `long double` arithmetic there
can be less precise than on the main thread. A worker that depends on it
resets the state itself (on Windows, `_fpreset()` from `float.h`).
`Lua:run_async`, `sqlite3` and `thread` reset it before each work item
([Windows worker threads](windows-build.md#long-double-on-worker-threads)).

[`lua.Lua:run_async`](standard-library-lua.md#asynchronous-execution)
is the explicit independent-state use of this boundary. Its worker exclusively
owns a separate Lua state, and Lua or Titan code initialized there runs with
that state's own globals, registry, and collector. It does not share host
state values or attach a host Titan closure to another thread. Cross-state
values follow the Lua library's copy and borrowed-pointer protocol.

A NULL worker function is rejected before submission. A queue-submission
failure raises immediately. After successful submission,
status zero resumes normally and a nonzero after-work status raises an
`OperationError`. Cancelling the waiting Task does not stop or detach the C
call: libuv completion remains authoritative and retains the request/carrier;
the suspended caller frame continues retaining any owned argument. Only after
the callback completes does the Task receive its pending cancellation. The
worker pool is shared with libuv filesystem and name-resolution work, so
long-running or numerous jobs can delay unrelated operations. A long-lived
independent-state loop continues occupying its worker slot; leave pool capacity
for work that its Tasks need. See the [pool-capacity discussion](standard-library-lua.md#two-phase-receiver-bootstrap).
A Lua state close instead unwinds a waiting Task before its job returns; see
[foreign work at state close](#foreign-work-at-state-close).

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

A Task held nonterminal by native retirement is still unfinished even after its
body and ordinary cleanup have returned. A first explicit `cancel` during that
interval keeps the normal cancellation precedence over pending success or
failure; it does not bypass the retirement barrier.

A Lua host drives scheduled work explicitly, after `require "titan"` has
installed Titan's package searcher:

```lua
require "titan"
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
token or nil expected source is shown as `unknown source`.

A running Task is the exception. `Task:resume(token)` on a Task that is
running, or whose next wait the Runtime is still registering, latches `token`
instead of raising; the latest call wins and the same token coalesces. The
latch is consumed by the Task's immediately next suspension if that is
`async.suspend` with the identical token, which then returns at once. Any other
next suspension (another token, a native or external wait, `async.yield`), or
the Task finishing, discards the latch. Only the Task's own code, or a
finalizer that runs while it runs, can resume a running Task. A typical case is
a finalizer that closes a coordination primitive just before its waiter parks.

Because a running Task cannot tell an early wake from a stale one, a waker must
hold a live registration: clear its registration before calling `resume`, so
that each wait receives at most one `resume`, or make the waiter recheck its
condition after every return from `suspend`. Reusing one token across waits is
safe only under one of these two disciplines; a fresh token per wait makes a
stale latch unmatchable. Make the waiter discoverable before the last check of
its condition, so that a wake before that point is seen by the check and a wake
after it is latched, and do not yield, await or suspend on anything else
between that check and its `suspend`. An early wake meant for a later
suspension is dropped silently: if a resume with token `B` is latched and the
Task's next suspension is `suspend(A)`, that suspension parks and the latch is
discarded.

This one-waiter gate follows the first discipline, with a fresh token per wait:

```titan
local async = import "async"

record Gate
  local opened: boolean
  local waiter: async.Task?
  local token: async.ResumeToken?
end

function gate(): Gate
  return Gate(false, nil, nil)
end

function Gate:wait()
  if self.waiter ~= nil then raise "Gate already has a waiting Task" end
  local current = async.running()
  local token = async.ResumeToken.new("Gate.wait")
  -- Publish the registration before the last check of the condition.
  self.waiter = current
  self.token = token
  local detach = function ()
    if self.waiter == current then
      self.waiter = nil
      self.token = nil
    end
  end
  defer detach()
  if self.opened then return end
  async.suspend(token, detach)
end

function Gate:open()
  self.opened = true
  local waiter? = self.waiter
  local token? = self.token
  if waiter ~= nil and token ~= nil then
    -- Consume the registration before resuming: each wait gets one resume.
    self.waiter = nil
    self.token = nil
    waiter:resume(token)
  end
end
```

Every other wrong-time call still raises, with expected source
`unknown source`: before the Task first runs, while it waits in a native
operation or `async.yield`, and after terminal completion. It is not a no-op.

With the correct token, `resume` does not enter the target Task inline. It
synchronously requests a callback-deferred wake without yielding its caller,
so it is valid from a terminal listener's main-thread context or another
running Task. Repeated correct-token requests before the wake coalesce.

The optional zero-argument cancellation action runs at most once per
suspension. When the Task is already suspended, it runs synchronously in the
caller that requests cancellation, before the suspended Task's correct-token
wake is scheduled. When the cancellation arrives while the Runtime is still
registering the suspension, the action runs as the Runtime accepts it, and the
suspension then raises the cancellation at once. A cancellation that arrives
earlier, while the Task still runs, makes `suspend` raise without running the
action. It is for
nonyielding, nonraising detachment of an exact waiter or similar ownership
state; an ordinary correct-token `resume` does not call it, and scope cleanup
must still detach the waiter. Omitting the second argument is equivalent to
passing nil.

`ResumeToken`, `SuspendCancelAction`, the required token parameters, and the
nil-accepting cancellation-action parameter are part of the public compiled-
module contract. Both serialized `titan.async` metadata and the exact native
signatures include them. Use matching providers and consumers under
generated-code ABI 2, and rebuild consumers when the provider changes.

The first correct-token wake request appends the target Task to the Runtime's
ready queue; later requests before delivery coalesce. Acceptance arms a needed
shared wake before committing the request. Delivery clears the old suspension
and queue entry before resuming the Task. This guarantees callback-deferred
delivery but does not promise one exact libuv iteration.

## Transfer values

`TransferValue` is defined in `titan.transfer`; `async.TransferValue` is a
transparent alias. Import either module to construct or annotate these policies.
The transfer module does not create a Runtime or deliver messages.

```text
union TransferValue
  is_nil()
  is_boolean(boolean)
  is_integer(integer)
  is_float(float)
  is_string(string)
  is_lua_state(foreign *lua_State)
  is_function(foreign function (*lua_State): int)
  is_pointer(foreign *void)
  is_record(module: string, name: string, data: string)
  is_union(module: string, name: string, data: string)
  is_closure(module: string, entry: foreign const *void, data: string)
  is_record_payload(module: string, name: string, data: string)
end

function TransferValue.from_value(candidate: value): TransferValue
function TransferValue:to_value(): value
function TransferValue.from_closure_payload(module: string, entry: value,
    data: string): TransferValue
```

Nil, booleans, integers, and floats preserve their value kinds. Strings cross
as copies of their exact bytes, including embedded zeros; no collector adopts
another state's string object. The three pointer variants carry borrowed
addresses. They do not retain their source object or code, validate its
lifetime, or synchronize access to shared memory. Keep native storage, code,
and any required originating state and source-state root alive for the borrow.

`from_value` returns an existing `TransferValue` unchanged. Otherwise it
chooses a policy from the value itself:

- `nil`, booleans, integers, and floats keep their kind and value, including
  integral floats and `-0.0`. Strings become `is_string`.
- Light userdata becomes `is_pointer`, as does full userdata that is not a
  Titan value, using its payload address. A Lua thread becomes `is_lua_state`.
- A light C function or a C closure without upvalues becomes `is_function`; a
  NULL C function is rejected.
- A Titan closure becomes an `is_closure` snapshot, described below.
- A public record with the [custom hook pair](#custom-record-transfer) becomes
  `is_record_payload`. Other public records and public unions become
  `is_record` or `is_union`.
- A `thread.Sender` or `thread.Receiver` endpoint becomes `is_record_payload`
  whose bytes are a packet-local attachment index. Converting an endpoint in
  either direction requires an active packet scope; see packet-scoped
  resources [below](#custom-record-transfer).

Lua closures, C closures with upvalues, Arrays, Maps, Interfaces, and owned
foreign storage are rejected.

`is_record` and `is_union` carry the actual defining module, fully qualified
nominal name, and [protobuf bytes](standard-library-protobuf.md). The graph
must satisfy protobuf's public-data, supported-type, and acyclic-value rules.
`to_value` first queries the destination nominal registry. On a miss it calls
the recorded module's preload loader normally, then retries lookup.
It never derives a module name by splitting the nominal name. Module
initialization is memoized; an already initialized nominal needs no loader.

### Closure snapshots

Use `TransferValue.from_value(callback)` to snapshot a Titan closure.
Conversion validates the Titan closure header, brand, module userdata, and
manifest entry, then projects and roots **the complete immediate capture
frontier onto the Lua stack before running any capture's custom hook**, and
finally converts each snapshotted capture once in declaration order. Freezing
the immediate capture frontier before hooks prevents an earlier capture's custom
hook from mutating a shared cell before a later capture is read. Nested closures
and custom payloads become opaque bytes during this conversion. The returned
`is_closure` policy contains its defining module, immutable native entry token,
and protobuf snapshot bytes. Sending that policy later does not observe
subsequent changes to the origin's captures.

`from_closure_payload` wraps fields already copied by a trusted Lua/native
transport. Its `value` entry parameter explicitly checks the raw pointer at
that boundary. It does not validate the entry or decode captures; `to_value`
does that in the destination. Ordinary callers use `from_value(callback)`.

`to_value` initializes the destination module through its preload
entry, validates the token against that module's entry manifest before
dereferencing it, checks the complete capture frontier, and restores a fresh
callable. Invalid tokens or malformed capture arrays fail before any captured
resource's custom decoder runs. Module globals use the destination module
instance and are not copied.

Mutable captures become fresh destination cells. Related closures that shared
a mutable cell at the origin receive independent cells; alias identity is not
preserved between an outer closure and its nested captured closures. Separate
conversions and repeated `to_value` calls produce independent snapshots.
A captured `TransferValue` remains that union wrapper and preserves its
chosen policy; ordinary captures recover the semantic value of their policy.

Closure capture cycles, direct unsupported managed captures, and nominals
that fail their selected policy raise during `from_value`. Arrays inside a
supported nominal follow protobuf's ordinary rules. Native pointers retain
their borrowed-address lifetime rules. No source-state closure, mutable box,
string, or nominal heap object is retained by the policy.

### Custom record transfer

A public record can opt into custom transfer with these exact public members:

```text
function Record:to_transfer_payload(): string
function Record.from_transfer_payload(payload: string): Record
```

The instance method takes no arguments beyond its receiver and returns one
opaque byte string. The static function accepts that string and returns the
same record type. Reflection checks the erased signatures before invoking a
hook. Missing counterparts, wrong member kinds, or different signatures raise
instead of falling back to protobuf. Private methods do not opt into the
protocol. The record may have private fields because its hooks explicitly
select and reconstruct the payload.

`from_value` resolves the actual defining module before calling the encoder
once. It stores the module, qualified record name, and returned bytes in
`is_record_payload`. Native transport only copies those strings; it does
not interpret nested resources or invoke another hook. `to_value` resolves
the destination nominal, invokes its decoder, and verifies the returned
record identity. Each call invokes reconstruction again.

Hooks can use `protobuf.serialize_fields` and
`protobuf.deserialize_fields` with the same ordered field descriptors.
This supports private wrapper state without publishing a new nominal type or
serializing the live resource record. Raw pointer fields use protobuf's
same-process fixed64 representation; the codec never follows their addresses.
Known child resources can call their own hooks directly and embed the child's
opaque bytes as a string field.

Both hooks must be synchronous and must not yield. Recursive conversion of the
same active record or closure raises; active guards unwind when conversion
fails. Hook side effects are not rolled back. A hook that detaches a resource
can therefore change ownership during `from_value`, before any send.

Resources fall into two ownership categories. See
[native resource handoff](standard-library-transfer.md#native-resource-handoff)
for the built-in hooks' failure and cleanup rules.

- **Manual-handoff resources.** The programmer owns safe, exactly-once delivery
  and adoption of these payloads under the
  [shared manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules).
  The [supported API inventory](standard-library-transfer.md#manual-handoff-api-inventory)
  names the TCP/TLS/HTTP/WebSocket, file, process-stream, shell-stream, and
  SQLite Connection hooks; it does not make every type in those modules
  transferable. User hooks that do not register packet resources have the same
  responsibility. Copying or dropping bytes, or discarding a native packet with
  `transfer.discard_message`, does not decode payloads, invoke
  `from_transfer_payload`, or close these resources. A send that fails before
  delivery discards its own encoded packet but leaves a `TransferValue` policy
  that the caller passed to it intact. To keep a payload recoverable, construct
  and retain its explicit policy first and send that policy; likewise, when a
  closure capture must stay recoverable after a later capture fails, capture a
  retained policy.
- **Packet-scoped resources.** Resources registered with
  `transfer.attach_resource` and `transfer.claim_resource` (in the standard
  library, only
  [`thread.Sender` and `thread.Receiver`](standard-library-thread.md#closing-cloning-and-transferring-endpoints))
  need an active packet scope, which only `transfer.encode_message` and
  `transfer.decode_message` open. `async.send` and `Receiver:wait`, as well as
  `thread` channels, spawn functions, and Thread results, use those operations,
  so endpoints can cross them. Policy and protobuf conversion open no scope:
  outside a packet operation, converting an endpoint raises; inside one, the
  conversion reuses that packet, and the index bytes it produces own nothing
  apart from it. `lua.Lua:run` and `run_async` copy policies over a separate
  carrier that has no resource table, so they cannot move endpoints.

A successful `Receiver` send can still be coalesced or overwritten before
receipt. It is not an acknowledgement of delivery or adoption.

Records without hooks and unions retain structural protobuf transfer.

## Cross-state receivers

```text
record Receiver
function receiver(): Receiver
function Receiver:handle(): foreign *void
function send(handle: foreign *void, candidate: value)
function Receiver:wait(): value
function Receiver:close()
```

A `Receiver` is a single-slot mailbox in one Lua state that other states and OS
threads fill through a borrowed native handle. Each send replaces the unread
value: it is a notification mechanism, not a queue.

**Creating a receiver.** `receiver()` creates a receiver in the current state's
Runtime. It may be called outside a Task, including from a `Lua:run` or
`Lua:run_async` bootstrap that has not started Tasks in the destination state.
It creates the Runtime when needed without driving its loop, and raises
`"cannot create a receiver while async Runtime is shutting down"` once shutdown
or `request_exit` has begun. The `Receiver` must stay in the state that created
it, and `handle`, `wait`, and `close` run in that state. Only the opaque address
returned by `handle()` may cross to another state or thread, and its only use is
as the first argument of `async.send`. It is not a `uv.async_t` or a pointer
that applications may dereference.

**Sending.** `send(handle, candidate)` is synchronous and may run in ordinary
Titan code of any state, without a Task or Runtime there. `candidate` is any
transferable Titan value, including `thread.Sender` and `thread.Receiver`
endpoints, or an explicit `TransferValue` policy. `send` encodes it into a
native packet with `transfer.encode_message`, stores the packet in the
receiver's slot, disposes of any unread packet it replaces, and wakes the
receiver's loop. The wake carries no data: the packet stays in the slot until
`wait`, a later `send`, or `close` takes it. `send` allocates, so it is not safe
in a raw POSIX signal handler; an ordinary callback delivered by the event loop
can use it.

A send that fails before its packet reaches the slot leaves the slot unchanged
and disposes of the packet it encoded:

- a `nil` handle raises `"receiver handle must not be NULL"`;
- an unsupported value, or an `is_function` policy holding a NULL function,
  raises during encoding;
- a closed receiver raises `"receiver is closed"`.

After such a failure the caller still owns the endpoints it passed, and a
retained `TransferValue` policy is still usable. A manual-handoff hook that ran
during encoding may already have detached its resource, however, and the failed
send does not undo that. To keep such a resource recoverable, construct and
retain `TransferValue.from_value(resource)` first and send that policy, as the
[manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules)
describe. Once the packet is in the slot, the send has committed: if waking the
loop then fails, `send` raises `OperationError` with operation `"async.send"`,
but the slot keeps the packet and the caller must not send it again.

**Delivery is lossy and coalescing.** A `send` that arrives before `wait` has
taken the slot replaces the unread packet, whether or not the receiver's loop
has already been woken. The replaced packet is disposed of with
`transfer.discard_message`, which releases any `thread` endpoints it carried
without running Titan code or needing a Runtime. Several sends may produce a
single wake. A successful send therefore does not promise that a waiter will
receive that message. There is no FIFO, message count, or backpressure, and
concurrent senders must not depend on any ordering between their messages.

**What `wait` returns.** `wait()` decodes the packet in the receiving state and
returns the value itself, not a `TransferValue`; the receiver never sees the
policy variant or undecoded nominal bytes.

- Scalars keep their exact kind and value; `nil` and `false` arrive as ordinary
  data. Strings arrive as copies of their bytes, including embedded zeros.
- Records, unions, closures, and records with custom hooks are reconstructed
  inside `wait`, which claims any attached `thread.Sender` and
  `thread.Receiver` endpoints into destination wrappers. If initializing a
  destination module or running a decoder fails, `wait` raises that error. The
  packet is consumed either way, its unclaimed endpoints are released, and the
  message cannot be decoded again. Independent `Lua:run` and `Lua:run_async`
  likewise decode incoming arguments before the chunk runs and report
  reconstruction failures to their calling Titan code.
- Pointer policies (`is_lua_state`, `is_pointer`), light userdata, Lua threads,
  and non-Titan full userdata carry only borrowed addresses, retain nothing they
  point to, and arrive as light userdata. Recovering a typed pointer requires an
  explicit `as` cast.
- Discarding a packet never runs a decoder, so a `Receiver` that replaces or
  closes an unread packet does not close the manual-handoff resources in it
  (`http.Exchange`, `ssl.Connection`, `net.Connection`, `websocket.Connection`,
  and the rest of the
  [inventory](standard-library-transfer.md#manual-handoff-api-inventory)). See
  [native resource handoff](standard-library-transfer.md#native-resource-handoff)
  before sending such payloads, or closures that capture them.

**Waiting.** `wait()` requires a running Task in the receiver's owning Runtime.
At most one Task may wait on a `Receiver` at a time. `wait` takes the single
reader reservation before it checks for cancellation, closure, or a packet, so
a second caller raises `"receiver already has a waiting reader"` even when a
packet is already in the slot or the first waiter's wake is already queued. A
wake only schedules the waiting Task; it does not take the packet. If the
resumed waiter finds the slot empty, because a stale or coalesced wake arrived
first, it suspends again under the same reservation.

Cancelling the waiting Task releases its reservation without closing the
receiver or taking the unread packet; later sends may still replace that packet
before another waiter takes it. The reservation is free as soon as `cancel`
returns, so another Task may start waiting before the cancelled one has
finished unwinding, and that unwinding does not release the new reservation.

**Closing.** `close()` is idempotent and does not require a Task. It marks the
receiver closed, disposes of any unread packet with `transfer.discard_message`,
makes a waiting Task raise `"receiver is closed"`, and starts closing the native
handle; the owning `async.loop` must still run to complete that close. Runtime
shutdown and garbage collection of the `Receiver` also close the slot and
dispose of an unread packet. A decoder hook, or a finalizer that runs while
`wait` decodes, may close the receiver being waited on: `wait` still returns the
value it took, and the next `wait` raises `"receiver is closed"`. A finalizer
that closes it while `wait` is about to suspend makes that `wait` raise
`"receiver is closed"` too.

**Stop senders and finish every in-flight send before calling `close` or
letting the owning Runtime shut down.** Concurrent `send` and `close` are
unsupported. Receiving a stop message does not prove that its sender has
returned from `send`; arrange sender completion separately before tearing the
receiver down.

**Handle lifetime.** The address returned by `Receiver:handle()` keeps neither
the `Receiver` nor its Lua state alive. Keep the `Receiver` reachable in its
owning state, for example in a module variable, until every sender has stopped
using the handle and all in-flight `send` calls have returned. Only then close
it and drain the loop, release that reference, or close the state. Keeping the
`Receiver` reachable keeps the handle's storage valid after `close`, but does
not make a concurrent `send` and `close` safe: the slot synchronizes sends with
`wait`, not with `close`. A handle is invalid once its `Receiver` has been
collected or its state closed. See the
[two-phase independent-state example](standard-library-lua.md#two-phase-receiver-bootstrap)
for explicit close, native drain, and state cleanup, and
[closing a Lua state with an active Runtime](#closing-a-lua-state-with-an-active-runtime)
for a state that closes before its loop has been drained. The implementation
chapter describes
[receiver ownership](../implementation/libuv-runtime.md#cross-state-receiver-ownership).

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

record ExternalWait -- opaque; prepared by either factory below
function prepare_external_wait(
    register_fn: function (foreign *void): boolean,
    unregister_fn: function (): ()): ExternalWait
function prepare_native_retirement(
    owner: value, context: foreign *void,
    register_fn: foreign function (*void, *void): int,
    unregister_fn: foreign function (*void): void,
    retire_fn: foreign function (*void): int): ExternalWait
function ExternalWait:wait()
function ExternalWait:wait_cleanup()
function ExternalWait:close()
function wait_external(
    register_fn: function (foreign *void): boolean,
    unregister_fn: function (): ())
function wait_external_native(
    owner: value, context: foreign *void,
    register_fn: foreign function (*void, *void): int,
    unregister_fn: foreign function (*void): void)
function wait_external_cleanup(
    register_fn: function (foreign *void): boolean,
    unregister_fn: function (): ())
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
`success(nil)` and `success(false)` remain successful outcomes. Result values
have no identity: a successful wait without a payload may return a shared
`success(nil)` value. Inspect results with `case`; do not compare them with
`==`, use them as Map keys, or attach finalizers to them.

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

### External waits

Cross-thread subsystems can use the Runtime's shared external wake bridge to
suspend a Task without creating and closing a fresh `uv.async_t` for each wait.
This is a generic adapter API. The thread standard library waits through
`async.wait_external_native` for blocked channel sends and receives and for
`Thread:join()`, so all of them share one bridge
([thread waiter suspension](../implementation/thread-library.md#shared-external-wake-suspension)).

The rules in this section apply to `prepare_external_wait`. Native retirement
capabilities have a separate contract, described below, and are not
interchangeable with ordinary waits.

**Preparing a wait.** `prepare_external_wait(register_fn, unregister_fn)` may be
called outside a Task, for example to preallocate state before `async.loop()`
starts. Like `run`, `run_with_cleanup`, and `receiver`, it creates the current
state's Runtime when needed without driving its loop. It rejects preparation
once shutdown or `request_exit` has begun
(`"cannot prepare an external wait while async Runtime is shutting down"`).
Preparation lazily initializes the Runtime's shared
[`uv.external_wake_t`](uv/types.md#external_wake_t) bridge, assigns the wait an
immutable positive identity, and calls
[`external_wake_t:reserve(identity)`](uv/supplemental.md#external_wake_treserve)
to preallocate an **unreferenced** native wake target. Identities increase
monotonically from `1` to `LUA_MAXINTEGER` and are never reused; exhausting them
raises `"async external wait identity exhausted"`. A reserved target does not
reference the underlying `uv_async_t` handle, so an unused `ExternalWait` never
keeps an otherwise idle event loop alive.

**The `ExternalWait` owner.** An `ExternalWait` is a one-shot owner bound to the
Runtime that prepared it:

- `wait()` requires a running Task and performs an ordinary,
  cancellation-sensitive wait.
- `wait_cleanup()` requires a running Task and performs a
  cancellation-insensitive cleanup wait, which is admitted even when Task
  cancellation is pending or the Runtime is shutting down.
- Calling either from a Task on another Runtime raises
  `"external wait belongs to another async Runtime"`. Calling either on a used
  or closed `ExternalWait` raises `"external wait is consumed or closed"`.
- `close()` idempotently retires an unused `ExternalWait` and unregisters its
  reserved target. Calling it while the wait is actively pending raises
  `"cannot close an active external wait"`.

**Registration.** When a wait starts, the bridge first activates the reserved
target with the allocation-free
[`external_wake_t:activate(target)`](uv/supplemental.md#external_wake_tactivate).
Active waits reference the shared `uv_async_t` handle, so a Task waiting only on
another OS thread keeps the loop alive instead of triggering an idle-loop
failure. The bridge then calls `register_fn(target)` with the borrowed native
target pointer:

- Inside `register_fn`, the domain checks readiness under its native mutex. If
  the condition is already satisfied, `register_fn` returns `false`. The bridge
  then retires and unreferences the target and resolves inline without
  suspending.
- If the caller must wait, `register_fn` retains a producer reference with
  [`uv.native_external_wake_retain(target)`](uv/supplemental.md#native_external_wake_retain),
  links its native waiter under the domain mutex, and returns `true`.
- If `register_fn` raises, the bridge calls `unregister_fn()` and retires the
  target before rethrowing. Rollback must retire any partial native link.
- When `unregister_fn` unlinks a still-linked waiter, it must release the
  producer reference that `register_fn` retained. If a producer already
  unlinked, notified, or released it, do not release that reference a second
  time.

**Notification.** Native producers on any OS thread notify a retained target with
[`uv.native_external_wake_notify(target)`](uv/supplemental.md#native_external_wake_notify)
and release their reference with
[`uv.native_external_wake_release(target)`](uv/supplemental.md#native_external_wake_release);
neither accesses Lua or GC state. On the destination loop thread, the bridge
drains pending identities in bounded batches of 64 with
[`external_wake_t:drain`](uv/supplemental.md#external_wake_tdrain), rearming the
handle when more remain, and schedules each matching live wait through the
Runtime's deferred ready queue. It never re-enters a Task directly from the
native callback.

**Cancellation.** Cancelling or unwinding an active wait synchronously calls
`unregister_fn()` and
[`external_wake_t:unregister(target)`](uv/supplemental.md#external_wake_tunregister).
That unlinks any pending notification and unreferences the shared handle when
active waits reach zero. An ordinary `wait()` stays active until its Task
resumes, even after a producer has notified it: a `Task:cancel` that arrives
between the notification and the resumption still calls `unregister_fn()`, and
the wait raises the cancellation instead of completing. If the producer chose
this waiter over others when it notified it, for example to report that a
bounded queue has room again, `unregister_fn` must pass that wakeup on to
another waiter, or the wakeup is lost; the
[thread channels](standard-library-thread.md#sending-and-receiving) do this.
The bridge checks both the unique `ExternalWait` identity and the Task's
suspension epoch, so stale or duplicate native notifications are ignored and
can never wake a replacement wait on the same Task.

**Convenience wrappers.** `wait_external(register_fn, unregister_fn)` and
`wait_external_cleanup(register_fn, unregister_fn)` require a running Task. They
call `prepare_external_wait`, `defer owner:close()`, and run `owner:wait()` or
`owner:wait_cleanup()`.

**C callbacks.** `wait_external_native(owner, context, register_fn,
unregister_fn)` performs one ordinary wait like `wait_external`, but with C
callbacks in place of Titan closures, so a native domain can wait without
allocating registrar closures. It requires a running Task and keeps `owner`
reachable until it returns. It is not a native retirement capability: it adds
no cleanup shielding and does not hold back Task publication.

- Both callbacks must be non-NULL C-only functions that neither raise nor
  yield. NULL callbacks raise `"native external wait callbacks must not be NULL"`
  before any preparation. Both run on the loop thread with no Runtime-held
  domain or wake mutex: `register_fn` after the Task has yielded, and
  `unregister_fn` synchronously inside `Task:cancel`, during the waiting
  Task's own unwind, or at state close (see **State close** below).
- `register_fn(context, target)` rechecks readiness and publishes its waiter
  under the domain's mutex. It returns `0` when the wait is already satisfied
  (no waiter linked, no target reference kept), `1` when it has linked a waiter
  that retains `target`, or a negative status to reject the wait with nothing
  left linked or retained. A negative status raises `OperationError` with
  operation `"async.external_wait.register"`.
- `unregister_fn(context)` withdraws exactly that waiter, idempotently, when
  registration fails or the wait is cancelled, including a cancellation that
  arrives after a notification but before the Task resumes; it must then pass
  the consumed wakeup on, as described under **Cancellation** above. It is not
  called when the Task resumes after a notification or when `register_fn`
  returns `0`. Notification and target reference rules are otherwise those of
  `prepare_external_wait` above.
- `context` is borrowed; it is neither a GC root nor a native owner. Keep its
  storage, and every GC object it refers to, alive until the call returns,
  including through a cancellation unlink. A context in automatic storage is
  valid only because the Task's stack frame lasts for the whole call; a
  producer must not keep it after unlinking. Keeping `owner` reachable does not
  keep native storage alive past Lua-state close.
- **State close.** If the Lua state closes while the Task is still parked,
  `unregister_fn(context)` also runs during `lua_close`, before the Task's
  coroutine stack, and with it any automatic `context`, is released. The Task
  does not resume, but its stack is
  [unwound](coroutines.md#abandoned-coroutines): `unregister_fn` runs from the
  wait's own cleanup, and the Task's `defer` blocks run afterwards inside a
  finalizer. By then `owner` may
  already have been finalized, so the native object that `context` refers to
  must not depend on `owner` for its lifetime. From a linked registration
  until `unregister_fn` runs, or until the waiting Task's own next locked
  access after a notification, the registration must keep that object alive,
  for example with a count that defers its destruction. Do not drop that pin
  when a producer notifies the waiter, because the closing state may be about
  to withdraw it. Thread channels and `Thread:join()` keep one such pin per
  registration
  ([registration pins](../implementation/thread-library.md#registration-pins-and-state-close-withdrawal)).
  This `unregister_fn` call may be the native object's final release, so the
  object may be destroyed on the closing thread. The Runtime's wake bridge may
  already be detached by then: releasing the waiter's retained `target` is
  still valid, and a notification on it does nothing. Waits made with
  `prepare_external_wait`, `wait_external` or `wait_external_cleanup` are
  withdrawn the same way: their `unregister` function runs inside a finalizer,
  so it must not yield.
- A callback that later writes through a retained `context` pointer is not a
  tracked synchronous out-argument. Keep the underlying storage and every
  callback dependency alive through native completion; neither a borrowed
  pointer nor caught-error recovery extends that lifetime or authorizes
  asynchronous access after the block ends. Mutable out-arguments passed
  directly to C or Titan calls retain the callee's writes after a raise
  ([C storage after a caught error](c-ffi-expressions.md#c-storage-after-a-caught-error)).

#### Native retirement capabilities

`prepare_native_retirement(owner, context, register_fn, unregister_fn, retire_fn)`
prepares the native capability accepted by `run_with_cleanup`'s third argument.
Ordinary `prepare_external_wait` results are not eligible. Preparation may
create the Runtime outside a Task; the unused reservation is unreferenced.
Null callbacks raise `"native retirement callbacks must not be NULL"` before
native reservation.

**Native ownership and callbacks.** `owner` is a traced keepalive for the
context through native callback return and committed readiness, including the
OS join when retiring a Thread. The caller remains responsible for the validity
of `context` and every callback dependency; a raw pointer alone retains nothing.
Native producers must independently own queued native context/nodes and retain
their wake target through notification/unlink, including state close. A traced
GC owner is not a cross-state-close native lifetime pin.

The three callbacks are nonraising, nonyielding C-only entries: they receive no
Lua state, access no module/GC objects, run no user hooks, and perform no Lua
allocation:

- `register_fn(context, target): int` checks readiness under the domain's mutex.
  `0` means monotonic already-finished readiness with no linked waiter or
  producer reference; `1` means the waiter is linked after retaining `target`;
  a negative status rejects with no native link/reference left behind.
- `unregister_fn(context)` is exact unlink/release for **constructor rollback**.
  Normal successful retirement does not call it: the producer unlinks and
  releases its own reference when notifying.
- `retire_fn(context): int` returns `0` only after actual native retirement
  (finished plus successful OS join for a Thread), `1` while pending, or a
  negative native error while preserving its token/resource. It runs on the
  loop thread with no driver-held core or domain mutex; it may take its own
  domain mutex briefly but must release it before blocking. It may block only
  for native final completion after readiness — never for unfinished domain
  work — and no bound is promised on that native tail. Success is idempotent.

The producer must notify only when the next `retire_fn` call can return **zero
or a negative error**, not pending. A drained target remains DELIVERED; another
notify on it does not schedule another wake. Merely notifying an operation whose
retirement will still return `1` can therefore strand a referenced wait.
`retire_fn` can also be polled repeatedly while pending, including at an explicit
cleanup attachment, terminal publication or recovery; positive-path side effects
must be idempotent. A notification may retire the native resource before the
host Task body has finished.

**Binding and rollback.** A capability must be live, unused, same-Runtime and
exclusively unbound. Validation repeats after Task/Completion allocations.
The constructor activates/registers the barrier before exposing the Task.
Register result `0` must also retire successfully before exposure; result `1`
leaves the accepted waiter referenced. A still-pending retire after register
result `0` raises `"native retirement is not complete"`.

Failure before binding leaves the caller's reservation intact unless caller
finalizers changed it. Once bind/arm admission begins, later failure performs
native unlink if needed, removes the map/target borrow, consumes the UV
registration and closes the capability. No body/cleanup is called and no Task
is exposed; the original domain owner still owns a running resource. Do not
reuse the closed capability. Activation/register errors use `OperationError`
operations `"async.native_retirement.activate"` /
`"async.native_retirement.register"`.
Immediate constructor retirement errors use
`"async.native_retirement.retire"` synchronously and perform the same admission
rollback; no pending Task is exposed for driver retry in that case.
An unused unbound capability may be closed idempotently without a Task to
release its reservation; closing that preparation does not retire the original
domain resource.

**Optional attachment and logical close.** Wait methods require a Task in the
capability's owning Runtime. An unbound native wait then raises
`"native retirement is not bound to a cleanup Task"`. A bound ordinary `:wait()`,
body use or peer-Task use raises
`"external wait is reserved for its Task cleanup"`. Only the bound Task's
cleanup may call `:wait_cleanup()`. It attaches once to the prearmed barrier,
without another registration; earlier retirement completes inline, otherwise
it is cancellation-shielded. Completion remains durable independently of the
current Completion or Task epoch.

Owner-cleanup `:close()` with retirement pending closes the user-facing wait
view, not the native barrier. The Task retains that accepted barrier until
retirement; later waits raise `"external wait is consumed or closed"`.
Closing an active await raises `"cannot close an active external wait"`;
retired close is idempotent from any context. Neither a failed ordinary wait
entry nor deferred close may invalidate native ownership.

**Terminal publication and retry.** A Task's body result or error, and any
pending terminal outcome, stay held until both the Task's root and native
retirement have finished. Every terminal path and every terminal listener waits
for that, including when ordinary startup or cleanup entry fails. A body error
is not replaced merely because the cleanup entry later fails, and the first
sticky cancellation keeps its normal precedence.

For an admitted gate, a negative retire result is an error from `async.loop()`,
**not a Task outcome**. It raises `OperationError` with the native code
unchanged and operation `"async.native_retirement.retire"`. The Task, its
native context, wake registration, Completion, suspension number, and Runtime
all stay in place. The driver neither spins, detaches, blocks on unfinished
work, nor fabricates completion.

Calling `async.loop()` again explicitly clears the negative-result state and
retries that same retirement once at the start of the new invocation, before
blocking, even if the wake already arrived and no further wake will. It does
not register again, recreate the owner or the Task, or reset suspension
numbers. Another negative result raises another driver error with ownership
intact; zero lets ordinary continuation and terminal publication proceed.

A retirement adapter may request a reasonless cancellation of the native
resource's owner when ordinary reason forwarding was missed or failed and no
cancellation has already been accepted. It may do so only at the exact cleanup
attachment or while terminal publication is pending because ordinary cleanup
failed. It never does so for an unfinished normal body or because registration
returned `1`. The fallback preserves the host's original error or first reason,
never overwrites an accepted cancellation reason of the owner, and still
requires the actual native retirement. The thread library supplies this policy
for `Thread:task()`: its cleanup forwards the first reason and then waits on the
gate, and it requests a reasonless child cancellation only while the child has
no recorded outcome and no accepted cancellation request
([thread retirement wiring](../implementation/thread-library.md#join-proxy-retirement-and-the-native-terminal-barrier)).

### Program exit control

`request_exit(code)` requires a running Task. It records the first requested
status, requests cancellation of all unfinished Tasks including the caller,
and raises the caller's retained cancellation reason. New `run` calls are
rejected after the request, and the Runtime immediately stops admitting native
resource handoffs. This does not change the separate `is_closing()` flag.
Lexical defers and cleanup awaits still run, and
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
occupies its waiter slot and then waits until the opposite operation has
established buffer progress or `close` has committed terminal state; it
rechecks after every wake, so a stale wake on the shared token costs only
another suspension. The occupied waiter slot prevents another same-direction
operation from stealing that progress before delivery. Cancellation instead injects the
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
registration, a callback, nor a resumed Task drives any loop recursively. On
the browser target the driver gives the page's event loop back between turns
instead ([the browser driver](#the-browser-driver)).

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
Task is deferred. Settlement from inside a finalizer, including the cleanup of
an [abandoned coroutine](coroutines.md#abandoned-coroutines), is deferred the
same way, because a finalizer cannot resume the waiting Task. A
`Completion:fatal` made there likewise records the Runtime failure at once and
queues its own operation's error for the waiting Task, which raises it at its
`await` after the finalizer; the driver still reports the Runtime's first
error. A finalizer may also run while a Task
is about to suspend, after it began waiting and before the Runtime registered
its suspension. Closing, sending on or receiving from an `async.channel`, any
subscription notification (publish, fail, finish, stop), closing a `Receiver`,
or cancelling the Task there still ends that wait (see
[explicit suspension](#scheduling-and-driving-tasks)).
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
function BufferedSubscription:snapshot_pending(): (SubscriptionBatch<|T|>, SubscriptionResult<|T, E|>?)
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
| `snapshot_pending()` | Copy the unread queue without consuming it; return the batch and nil while live, or its ended/error/closed outcome. Later queue changes do not change the snapshot. Values keep their usual reference semantics. |
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
Besides process exit, only a
[Lua state close](standard-library-fs.md#closing-the-lua-state) closes a
forgotten File.

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

### Closing a Lua state with an active Runtime

A Runtime normally finishes when `async.loop()` returns. A Lua state can close
while its Runtime is still active: for example, after an independent-state
bootstrap created a `Receiver` and never drove the loop, or after a driver
raised and was not called again. Closing the state then closes the Runtime's
remaining handles and its native loop without running any user callback,
including close callbacks that were already requested. No Task resumes, and
Runtime-close listeners do not run. Accepted native requests still complete
first, so closing the state can block until running worker-pool jobs finish.
The low-level operation is
[`uv.loop_abandon`](standard-library-uv.md#abandoned-loop-retirement).

Before then, every unfinished Task is
[unwound](coroutines.md#abandoned-coroutines) where it is suspended. Its
`defer` statements run innermost first, inside a finalizer, and a parked wait
is withdrawn by its own cleanup before the stack is released (see
**State close** under [external waits](#external-waits)). Tasks blocked in
[`thread` channel operations](standard-library-thread.md#sending-and-receiving)
or `Thread:join()` are withdrawn this way, so channels and threads shared with
other states stay usable. The cleanup of `run_with_cleanup` then runs with the
Task's cancellation reason, or
`simple("async Runtime abandoned at Lua state close")` when there was none.

That unwind runs outside the scheduler. `async.running()` and every operation
that needs the current Task, including each `await`, raise
`asynchronous operation must be called from an async Task`; a direct yield or
resume raises as in any [finalizer](standard-library-gc.md#finalizers). Each
such error, like any other error a cleanup raises, is reported as a Lua warning
and the unwind continues.

Cleanup cannot start Tasks during state close: `async.run` and
`run_with_cleanup` raise `cannot start a Task during Lua state close`. Nor can
any code create a Runtime while the state closes: when no Runtime is active,
`async.receiver`, `async.prepare_external_wait`,
`async.prepare_native_retirement`, and library operations that would create
one raise `cannot create an async Runtime during Lua state close`, because Lua
registers no new finalizers then and that Runtime's loop would leak. Disposal
that must survive state close has to be synchronous. Handing disposal to
`async.run` from a `defer` works only while an ordinary collection unwinds an
abandoned coroutine and a Runtime is active; that Task runs after the rest of
the unwind.

The unfinished Tasks of that Runtime do not resume and do not call their
terminal listeners, but most of them still become terminal. Lua runs finalizers
newest first, so a finalizer registered before the Runtime was created runs
after this retirement. If it holds such a Task, `status()` returns a `cancelled`
status, whose `has_finished()` is true. Its reason is the first cancellation
requested before the close, or
`simple("async Runtime abandoned at Lua state close")` when there was none. A
body that had already returned or raised while its cleanup was still pending is
reported the same way. A Task whose native-retirement gate is still armed stays
nonterminal, because its terminal status follows native retirement: for
example, a `Thread:task()` proxy whose OS thread was not joined reports
`ready` or `waiting`, never a terminal status.

This only reclaims native memory and releases native handles. It does not
replace closing receivers, finishing or cancelling Tasks, and draining the loop
before closing the state, and it cannot perform a graceful protocol shutdown;
see [cleanup that needs asynchronous I/O](coroutines.md#cleanup-that-needs-asynchronous-io).

Ordinary garbage collection never retires an active Runtime, because the async
module keeps it reachable.

#### Foreign work at state close

A Task waiting in `async.run_foreign` when its state closes is unwound before
`f(arg)` returns. Its `defer` statements therefore run while `f` may still be
using `arg`, and the state close waits for the job only afterwards, when the
Runtime drains accepted work. Native memory or resources that the caller
releases itself must not be released in a `defer` around `run_foreign`.

An `owned` argument is safe, because the collector frees it only after that
drain. For other native state, pass the optional third argument (omit it or
pass nil otherwise): a C-only `abandoned` function, which takes `arg` like `f`. When a Lua state close
abandons the wait, the Runtime calls `abandoned(arg)` on the closing thread
once every accepted job, including `f(arg)`, has returned. It must not enter
Lua or Titan code of the closing state. It may block, for example to close an
independent Lua state; no abandoned job occupies a pool thread by then. In
every other case `abandoned` is never called, and the caller releases its state
after the call returns or in a `catch`, which an unwind never runs. The
caller's own `defer` must then skip that release: a flag that is set before
the call and cleared after it returns and in `catch` is still set only after
an abandoned wait. `lua.Lua:run_async` releases its independent state this
way.

## The browser target

`async` is available on the [browser target](browser-target.md). Tasks,
cancellation, `await` and `await_cleanup`, `suspend`, combinators, channels,
string streams, subscriptions, close listeners and `request_exit` behave as
this chapter describes. The members that need libuv or another thread are
absent: `current_loop`, `await_with`, `await_cleanup_with`,
`await_cancellable_with`, `await_cancellable`, `run_foreign`, the external-wait
functions (`prepare_external_wait`, `prepare_native_retirement`,
`wait_external`, `wait_external_cleanup`, `wait_external_native`), `version`,
and Receivers (`receiver`, `send`, `Receiver`). `ExternalWait` remains only as
a type, with no constructor and no methods, so the `final_wait` of
`run_with_cleanup` is always `nil`. Initializing `async` on the browser
changes no signal disposition and reads no process arguments.

### The browser driver

A page has one event loop, and Titan code shares it with the page. The driver
runs Tasks in turns. A turn first delivers the host work queued when it
begins: request settlements, listener events, notifications and queued calls,
in order. It then runs at most 64 Tasks that were ready before the turn, and
gives the event loop back for one macrotask (`setImmediate` in Node, a
`MessageChannel` message in browsers, never a clamped timer). With nothing
ready, it waits until host work settles or a call arrives. Work that a turn
makes ready runs in a later turn, so `async.yield()` never resumes in the same
browser task, and the page keeps running while Tasks wait or yield. A Task
that neither finishes nor waits still blocks the page, as it blocks the
native loop.

Titan's browser tests measure how responsive the page stays, on a page with a
10 ms `setInterval` and animation frames:

- While Tasks wait, the interval keeps within 10% of the page's own timer
  cadence, which the test measures on the same page with no Titan code running.
  The bound is relative to that cadence because engines differ. With no Titan
  code, a 10 ms interval fires about 60 times in 600 ms on Chromium 156, 57 to
  58 times on Firefox 157 and 50 to 51 times on WebKit 27.2 (about every
  12 ms).
- While 128 Tasks yield continuously, animation frames keep advancing, no
  driver turn shares a macrotask with the next, and the largest gap between
  interval ticks stays under 100 ms. The measured gaps were 11 to 16 ms on
  Chromium, 13 to 21 ms on Firefox and 16 to 17 ms on WebKit.

Those Tasks do no work between yields. A turn runs up to 64 ready Tasks before
the page runs again, so the gap grows with the work each Task does before it
waits or yields.

If every remaining Task is waiting and nothing can wake one (no queued host
work, open request or listener, or open
[`BrowserPin`](standard-library-browser.md#synchronous-c-callbacks)), the
driver stops the Runtime with
`"async Runtime became idle while Tasks were waiting"` and unwinds the waiting
Tasks, as a native drive does with its own message.

A Task waits for the host with `await`, `await_cleanup` or `suspend` around
[host requests](standard-library-browser.md#requests-and-listeners): the
request's completion settles the wait. Pass `suspend` a cancel action that
cancels the request when cancellation must end the wait early; an `await` of
host work that never settles keeps waiting through cancellation, as it does
natively. Authored C that suspends the whole WebAssembly stack inside a Task
(`emscripten_sleep`, `EM_ASYNC_JS`) stalls every other Task until it returns;
use host requests instead. `timer` waits on JavaScript timers this way
([timer on the browser](standard-library-timer.md#on-the-browser)).

### Drives and entries

A drive starts inside a JavaScript entry and ends with it:

- The program's `main` runs as a Task through the standalone bootstrap, and
  `run()` drives until every Task finishes.
- A `call()` whose callable calls `async.loop()` drives until the Runtime's
  Tasks finish.
- `instance.callTask(callable, args)` runs the callable as a Task and drives
  the Runtime ([Task-form calls](browser-target.md#task-form-calls)).

`run()` resolves `returned` with `main`'s integer. A failed `main` Task prints
its uncaught report on stderr, as natively, and `run()` resolves `failed` with
status 1 and the Task's message and trace. A cancelled `main` resolves
`returned` with status 1, and an exit that any Task requests resolves `exited`
with its code, even after `main` failed
([the loader's `run()`](browser-target.md#the-loader-api)).

A call or notification handler on an idle instance may start Tasks with
`async.run`; they run at the next drive. While a drive runs, JavaScript calls
and Task-form calls made outside any binding are queued and delivered between
turns ([calls during a drive](browser-target.md#calls-during-a-drive)). A
queued call runs outside any Task, and `async.loop()` inside it raises
`"async.loop is already being driven"`.

### Ownership

Only the instance's owner state, the Lua state that runs its entries, drives.
In any other state, such as one that C code created, `async.loop()` raises
`"async.loop must be driven by the browser instance's owner state"` at once,
whether or not the owner has Tasks waiting, and starting a Task raises
`"async Runtime is unavailable in a non-owner browser state"`. The owner's
drive continues, and synchronous work in other states runs as usual. While the
owner drives, calls and notifications for other states are refused before
they enter WebAssembly.

### Synchronous callbacks

A [synchronous C callback](standard-library-browser.md#synchronous-c-callbacks)
runs outside every Task, even when it runs inside a binding that a Task
called. While a Runtime is active, `async.running()` raises `"asynchronous
operation must be called from an async Task"` there, so every operation that
needs a Task, such as `await`, `yield` or `suspend`, raises that error too.
With no active Runtime it raises `"async Runtime is not active"`, as it does
anywhere else.

What a callback starts takes effect in a later turn of the drive:

- resolving or rejecting a `Completion` or an `await` operation;
- `Task:resume` and `Task:cancel`;
- publishing to a subscription;
- `async.run`.

The waiting Task does not resume inside the callback. A callback that runs
while the drive waits for host work wakes the drive.

Reporting a fatal failure, through the `fatal` capability of `await` or
`Completion:fatal`, still depends on the Task that is really current. Inside
a binding that a Task called, that Task is current even though
`async.running()` hides it, so `fatal` raises `"async fatal callback must run
outside an async Task"` as it would in the Task itself. A callback that no
Task called, such as one that runs while the drive waits for host work or
inside a request's settlement callback, can report it: the Runtime failure is
recorded at once, the waiting Task raises its own operation's error at its
`await` in a later turn, and `async.loop()` then rethrows the Runtime's first
error.

### Exit and disposal

`request_exit(code)` keeps its meaning inside a Task: the first code wins,
every Task is cancelled with `"program exit"`, and cleanup awaits still run.
When the drive ends, the instance is latched as exited
([exit](browser-target.md#exit)): the entry reports the status, later entries
reject with `TITAN_BROWSER_EXITED`, and nothing closes the page or the Node
process. An entry that failed reports its failure even when an exit was
requested.

`dispose()` with an active Runtime cancels every unfinished Task with
`"instance disposed"` and drives their cleanup before the state closes; with
no drive running, disposal drives that cleanup itself. Tasks that cleanup
starts are cancelled at the next turn. Cleanup can await host work started
before `dispose()`, but cannot start new host work: `start` and `listen` raise
`browser.BrowserError` with the message `"browser state is closing"`
([disposal with a running Runtime](browser-target.md#disposal-with-a-running-runtime)).
