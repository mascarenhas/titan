# Async channels, combinators, terminal listeners, and HTTP idle timeouts

This is the final reviewed implementation plan. The author's original 242-line
draft is preserved byte-for-byte in commit `9fb88c6`, and the intermediate
check-phase design is preserved in commit `0257f1e`. This revision replaces
that polling design with Task terminal listeners and explicit Task suspension;
this final pass also adds bounded channels over those primitives and
string-specialized channel adapters. The type, cancellation, result, and
HTTP-composition decisions from the prior review remain in force.

## Reviewed semantic corrections

1. Restore the intended meaning of `async.Error`: it is the terminal Task
   failure envelope, while a Titan Task may raise any `value`:

   ```titan
   record Error
     error: value
     traceback: string
   end
   ```

   Rename the current libuv-operation record `{ code, name, message,
   operation }` to `OperationError`. `Error.error` is the exact raised value,
   including an `OperationError`, and `traceback` is the raw catch-local
   traceback without presentation headers.

2. Replace the public `Cancelled` record with a typed cancellation reason and
   structured terminal cancellation status:

   ```titan
   union CancellationReason
     simple: string
     complex: value
   end
   ```

   A Task privately stores whether cancellation was requested plus its original
   `CancellationReason`. Its public status remains its current live state until
   the Task reaches terminal `cancelled(reason)`. That request is authoritative
   when the coroutine later raises or returns, so catching, transforming, or
   returning from the injected reason cannot turn the Task into failed or
   succeeded.
   `cancel(nil)` uses `CancellationReason.simple("cancelled")`, and
   `async.Cancelled` is removed.

3. Every combinator scans statuses before registering listeners, installs one
   listener directly on each still-relevant named operand, then calls
   `async.suspend()` once. The listeners capture the combinator's result state
   and call `Task:resume()` only when its terminal condition is met. Each
   registration has a deferred removal so cancellation of the suspended
   combinator cannot leave a later callback into it. There is no status-polling
   loop, `uv_check_t` Waiter, Runtime `uv_idle_t` bridge, or `cancelling` state.

4. Add a bounded `async.channel` as send, receive, and idempotent close closures
   over a FIFO circular buffer. Capacity defaults to 1 and must be positive.
   The channel stores at most one blocked sender and one blocked receiver; any
   same-direction operation rejects while that waiter slot remains occupied,
   preventing barging before wake delivery. Close commits terminal state,
   discards buffered references, and wakes both waiters; every later or woken
   send/receive raises `"channel is closed"` unless an authoritative Task
   cancellation wins the same unwind.

5. Add opaque nominal `async.ChannelReader` and `async.ChannelWriter` records
   plus `async.reader_writer_channel`. They adapt the same general `value`
   channel to string ReaderCloser/WriterCloser methods without exposing record
   fields, constructors, or raw channel closures. Both endpoint closes share
   the channel close; read calls begun after reader close return nil, while an
   already-blocked read and peer-close operations retain the raw
   `"channel is closed"` error once reader-owned excess is exhausted.
   Remove the `yielding` option and state from ordinary `string.reader` and
   `string.writer`: in-memory reads and writes are always synchronous, while
   Task synchronization belongs to `reader_writer_channel`.

6. “First” means first observed: the initial status scan considers arguments
   from left to right, while later terminal publications notify their installed
   listeners sequentially. Duplicate Tasks therefore select their leftmost
   argument position.

7. Reject an input equal to `async.running()`. With the non-reentrant runtime,
   waiting for that Task would be a self-dependency. All arities validate this
   before registering a listener.

8. Preserve the runtime's existing failure-reporting rule. A Task failure is
   logged with its traceback when that Task terminates. A later combinator can
   inspect the stored `Error`, but does not retroactively mark the failure
   handled or suppress its report; terminal listeners do not change that
   ownership rule.

9. HTTP `idle_timeout` is an absolute deadline for acquiring the next request's
   line and headers, measured from the start of that loop iteration. It does
   not reset on partial bytes and does not cover handler work, request bodies,
   automatic body drain, or response writes.

10. An HTTPS timeout follows the existing high-level SSL cancellation contract:
   cancelling the in-flight read terminalizes the TLS engine and the peer sees
   `TLS_TRUNCATED_EOF`, not `close_notify`. The current SSL API has no operation
   that interrupts its serialized busy read and then performs graceful
   shutdown. Record that high-level composition blocker; do not reach into
   `uv` or add native state to manufacture a clean TLS close here.

11. Timeout cleanup is intentionally asymmetric. When the reader wins, cancel
    the timer-only deadline and let its close complete detached. When the
    deadline wins, cancel and join the reader before connection teardown,
    because that child owns the parser/connection operation and an SSL read's
    busy state persists until cancellation cleanup finishes.

## Public async and Task API

Own these types beside `Task` in `titan.uv` and transparently alias them from
`async`:

```titan
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

union CancellationReason
  simple: string
  complex: value
end

union TaskStatus
  ready
  running
  waiting
  succeeded: value
  failed: Error
  cancelled: CancellationReason
end

function TaskStatus:as_string(): string
function TaskStatus:has_finished(): boolean
function TaskStatus:has_succeeded(): (boolean, value?)
function TaskStatus:has_failed(): (boolean, Error?)
function TaskStatus:has_cancelled(): (boolean, CancellationReason?)

function Task:cancel(reason: CancellationReason?)
function Task:status(): TaskStatus
function Task:add_terminal_listener(listener: (TaskStatus) -> ())
function Task:remove_terminal_listener(listener: (TaskStatus) -> ())
function Task:resume()

function running(): Task
function suspend()
function channel(size: integer?):
    ((value) -> (), () -> value, () -> ())
```

Own the string-specialized channel records directly in `titan.async`, with all
fields local:

```titan
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

The helper predicates return a boolean discriminator plus the payload when
that terminal variant has one. The success payload is the exact value returned
by the Task function; the cancellation payload is the original nominal reason.
`cancel(nil)` constructs `CancellationReason.simple("cancelled")`.

Store `TaskStatus` directly in the Task. `Task:cancel` stores the first reason
privately and invokes the current cancellation action without manufacturing a
public intermediate state. The status remains `ready`, `running`, or `waiting`
as appropriate until final `cancelled`. `advance_task` already receives the
dead coroutine's return value and must retain it instead of discarding it. On
failure it constructs `Error.new(error, traceback)`. Make requested
cancellation win every user-Task
terminal path, including callback-boundary failure and a coroutine that catches
the injected reason and returns.

`async.running()` returns the current Task and raises outside one.
`async.suspend()` yields a suspension with no native request or persistent
waiter; only `Task:resume()` or cancellation makes it runnable again.
`Task:resume()` is synchronous whether called by the main-thread continuation
driver or from another running Task. It does not enter the target coroutine
inline or yield its caller. It coalesces repeated wake requests and starts one
target-owned zero-duration timer; `timer_cb` initiates `uv_close`, and
`close_cb` resumes the target after releasing the timer owner. External
cancellation of an explicitly suspended Task uses that same wake.

An unfinished Task accepts terminal listeners in registration order. After its
final status is published, the main-thread continuation driver detaches the
listener Array as a stable snapshot and immediately replaces the live list with
an empty one. It calls each snapshot listener in sequence and ignores an error
from one listener. Removal during delivery therefore cannot shift the snapshot
or skip a later callback. Registration on an already terminal Task is a no-op.
Removal is also a no-op when the registration is absent. Listener delivery
never runs inside the terminating coroutine: by that point it is dead or has
escaped with an uncaught error.

Remove `async.Cancelled` and the corresponding type test in `titan/lua.titan`.
The Lua loader may contextually wrap the in-flight cancellation value, but the
Task still terminates as `cancelled` with its stored original reason and is not
reported as a failure.

`async` transparently aliases the provider-owned union. The alias must retain
the underlying public constructor namespace, so callers can write
`async.CancellationReason.simple(...)` and `.complex(...)`. Fix the compiler's
alias-qualified nominal namespace lookup, retaining the existing visibility
rules: record aliases expose public statics and public `new`, union aliases
expose public statics and public variants, and local fields/variants do not
become public through an alias. Cover the checker, generated code, compiled
module re-export path, and both type-alias manuals.

## Task listener and suspension protocol

Add only the Task-local state needed by the public primitives: an Array of
terminal-listener closures, an explicit-suspension bit, and a coalescing
resume-pending bit. `async.suspend()` yields a dedicated `Call` variant whose
dispatcher marks the current Task suspended and installs cancellation as a
request to `Task:resume()`. No Task is registered on a native waiter.

Terminal publication occurs in the main-thread continuation driver after the
coroutine has returned or escaped with its uncaught error. Store the final
`TaskStatus` first, detach `task.terminal_listeners` into a local `listeners`
snapshot, and immediately assign an empty Array to the Task. Then iterate
`for index = 1, #listeners`, wrapping each listener call in an empty `catch`.
This makes later listeners independent of an earlier listener's error or
removal and prevents retained captures after delivery.

`Task:resume()` returns immediately when the Task is not explicitly suspended,
already has a pending wake, or is terminal. Otherwise it marks the wake pending
and creates the ordinary Task-owned zero timer. The timer callback only starts
close; the close callback clears suspension state and resumes the Task. This is
callback-deferred, but the plan does not promise one exact libuv iteration.
The same method works from a terminal listener in the main-thread driver or
from another running Task.

No new libuv handle kind, public `uv_*` function, callback trampoline, or
`UV_TITAN_SOURCES` contributor is required. Remove the intermediate check and
idle source, shims, direct-call inventories, and their API-coverage credit.
Refresh the source-derived snapshot to 6/14 concrete handles, 75/318 public
functions, 75/316 nondeprecated functions, Check 0/3, Idle 0/3, 13/94
concrete-handle functions, and 28 of 75 handle-related functions.

## Bounded channels

Add this public constructor to `async`:

```titan
function channel(size: integer?):
    ((value) -> (), () -> value, () -> ())
```

Normalize nil to capacity 1 and reject a capacity below 1 before returning the
closures. Capture a bounded circular buffer as a `{value}` Array plus `first`,
`next`, and `count` integers, and capture a `closed` boolean. `count`, rather
than Array length or slot presence, is authoritative so the channel can carry
`nil`. Wrap both indices at the validated capacity and clear each consumed
slot; the buffer therefore stays FIFO and retains at most `capacity` live
values.

Capture separate `send_waiter: Task?` and `receive_waiter: Task?` slots. Send
and receive first reject a closed channel, then reject an occupied waiter slot
in their own direction before checking whether the buffer is full or empty.
This makes same-direction contention unconditional while a waiter is installed:
another Task cannot barge into progress made after the original waiter's wake
was requested but before it was delivered. A blocking operation stores
`async.running()` in its waiter slot, installs a deferred conditional clear,
and suspends while the channel remains open and its full/empty condition still
holds. After that loop it clears the waiter and raises the exact
`"channel is closed"` error if close caused its wake. This supports at most one
blocked sender and one blocked receiver without introducing a Task queue.

Enqueue before calling `receive_waiter:resume()` and dequeue before calling
`send_waiter:resume()`. Resume is only a coalesced wake request: someone holding
the waiter may call `resume()` directly before the buffer condition changes.
Keep the condition loops around `suspend()` so buffer state, not a wake,
authorizes the operation. For the normal opposite-operation wake, the occupied
same-direction waiter slot prevents another Task from consuming or filling the
released progress before delivery. If someone cancels a blocked Task, the same
resume timer wakes it and its `defer` clears the matching waiter before
cancellation escapes.

The third closure closes the channel synchronously and idempotently. Its first
call sets `closed`, replaces the transfer Array with an empty Array, resets the
indices and `count`, and requests wakes for both installed waiters. This
discards every buffered reference instead of exposing a drain phase. Every
later send or receive, and every pending operation woken by close, raises
`"channel is closed"` unless an authoritative cancellation of that Task wins
the same unwind; repeated close calls return immediately.

The initial API intentionally uses `value` in both closure types. It can evolve
to `channel<T>` by replacing those positions with `T`; the circular buffer,
single-waiter rules, close protocol, and suspension protocol do not need
redesign.

## String-specialized channel adapters

First simplify the existing in-memory APIs to `reader(contents: string)` and
`writer()`. Remove both records' `yielding` fields, every `async.yield()` in
their read/write methods, and boolean arguments at all call sites. These
in-memory operations are synchronous; the new channel pair owns Task
synchronization instead.

Add these public opaque records and factory to `async`:

```titan
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

Keep every record field local. `reader_writer_channel` is the only constructor:
it calls `channel(size)` once, gives the reader the receive and close
closures, and gives the writer the send and same close closures. This is the
string-specialized adapter for the general `value` channel, not a separate
lower- or higher-level channel abstraction. The records satisfy the existing
ReaderCloser/WriterCloser method shapes without importing `io`. With ordinary
string streams now synchronous, `async` imports the public `string` module for
`find`, `sub`, and `writer`; `string` no longer imports `async`.

`ChannelWriter:write` sends one string. `ChannelReader:read` first returns any
post-delimiter excess and otherwise receives and casts `string?`.
`ChannelReader:read_until` uses the existing binary-safe `find` and `sub`
operations to recognize a literal delimiter across message boundaries. Retain
only the possible delimiter tail between receives, append committed prefixes
to a synchronous string writer, and save the post-match suffix as excess for
the next read. Preserve the existing `chop` behavior and reject an empty
delimiter.

Both endpoint close methods invoke their shared idempotent channel close. The
reader also marks itself closed and discards excess, so its own later reads
return nil without calling receive. Do not translate an already-blocked read or
peer closure into EOF: installed operations woken by either endpoint close,
later writes, and reads that need the receive closure after writer close get
the raw `"channel is closed"` error unless authoritative Task cancellation
wins. Preserve any reader-owned excess across writer close so `read` can return
it and `read_until` can satisfy a match from it before the closed receive is
needed. The adapter exposes no raw send/receive closure and inherits channel
capacity, waiter contention, cancellation, wake, buffer-discard, and
no-barging behavior.

## Combinators

Implement arities two through five exactly as fixed public unions/functions:

- `any_two` ... `any_five`, returning `AnyTwoResult` ... `AnyFiveResult` with
  positional success variants plus `none`;
- `race_two` ... `race_five`, returning `RaceTwoResult` ... `RaceFiveResult`
  whose positional variant carries `TaskStatus`;
- `all_two` ... `all_five`, returning success values as multiple results and
  raising `AllTwoError` ... `AllFiveError` whose positional variant carries
  the failed/cancelled `TaskStatus`; and
- `join`, `join_two` ... `join_five`, returning every final `TaskStatus`.

There are intentionally no single-Task `any`, `race`, or `all` functions: a
unary form has exactly the scheduling behavior of `join` and would differ only
in how it repackages the one Task's terminal status or result.

Implement each fixed arity directly over its named Task operands. Do not
collect the operands into `{Task}` or route the public functions through an
array-based helper: the separate entry points preserve the type shape needed
for a future polymorphic `Task<R, C>` without rewriting the combinators. Each
implementation obtains `async.running()`, rejects that Task as any operand,
then scans the named statuses from left to right. If the result is already
decided, it returns or raises immediately. Otherwise it creates separate
per-operand listener closures over shared result/counter state, registers each
still-relevant listener with a matching deferred removal, and suspends exactly
once:

```text
scan named operands left to right
if the terminal condition is met, return or raise
install named per-operand listeners, each with deferred removal
suspend the current Task once
listener state decides and requests one coalesced resume
return or raise from the captured state
```

Do not collapse listener installation into a helper that accepts a Task Array.
The listener for each named operand stores that operand's final status or
payload, updates the combinator-specific counter/winner state, and calls
`current:resume()` only when the result is decided. Listener calls made during
one Task's terminal publication run in registration order; an already-terminal
initial scan and duplicate operands therefore retain the left-to-right rule.
The non-reentrant loop leaves no interleaving window between the initial scan,
listener installation, and suspension.

`any` returns on the first observed success or `none` once all inputs are
failed/cancelled. `race` returns the first observed terminal status. `all`
returns only when every Task succeeded and raises on the first observed failed
or cancelled status. `join` returns only once all are terminal. No combinator
cancels unfinished Tasks.

Correct the example deadline to 5000 ms and include `when none`.

## HTTP idle timeout

Add a local `idle_timeout_ms: integer` backing field to `http.Server`; Titan
does not permit a record field and method with the same name. Extend the
constructors with a trailing optional argument to preserve every existing
positional call:

```titan
function listen(host: string, handler: Handler,
                port: integer?, backlog: integer?,
                idle_timeout: integer?): Server

function listen_tls(host: string, certificate_file: string, handler: Handler,
                    private_key_file: string?, port: integer?,
                    backlog: integer?, idle_timeout: integer?): Server

function Server:idle_timeout(timeout: integer?): integer
```

Normalize omitted timeout to 0 and reject a negative value before opening the
plain listener or synchronously reading TLS PEM input. The setter validates
before mutation, sets only for nonnil input, and always returns the previous
value; passing nil therefore returns the current value.

Pass the Server itself to each connection Task. At the start of each request
loop, snapshot `idle_timeout_ms`; changes affect the next request on an
existing keep-alive connection, not a header read already in progress.

At 0, call `read_request` directly. At a positive value:

1. start one Task returning `read_request(parser, encrypted)` and one Task
   sleeping for the snapshot milliseconds;
2. `race_two` them;
3. when the reader wins, cancel the timer-only deadline with a
   `CancellationReason.simple(...)` value and continue without joining it; its
   close owns no parser or transport state and may finish in the background;
4. when the deadline wins, cancel and join the reader before unwinding, so its
   parser/connection ownership and an SSL read's busy state survive through
   terminal cancellation cleanup;
5. on reader success, continue with its `Request?` result;
6. on timeout success, return silently and let the existing deferred parser
   and transport close run; and
7. on a child failure, avoid re-raising it from the parent connection Task—the
   failed child already logged its exact error/traceback—apply the same
   ownership rule to its peer and return.

This iteration does not add body, drain, or write timeouts. `Server:close`
still closes only the listener, not accepted connections. An application that
times out a body read must unwind its handler (and may close the Server to stop
new accepts); merely returning after `Server:close` would still enter the
automatic body drain.

No HTTP C or `uv` reach-through is needed.

## Tests, migrations, and documentation

The implemented coverage lives in the native `async.tests` folder module under
`spec/stdlib/titan/async/tests/`, run directly outside LuaCov. Its combinator
constituents cover every arity and variant, nil success values,
all-failed/cancelled `any`, success/failure/cancellation races, left-to-right
ties and duplicates, all success/error unions, joins, already terminal Tasks,
real timer/I/O sleeping, self-dependency rejection, and the rule that failures
remain logged, plus `OperationError` as an exact `Error.error` payload.

The channel constituent covers default and explicit capacity validation, FIFO
order through circular wraparound, `nil` payloads, blocking send and receive,
rejection of a second blocked operation in either direction, unconditional
same-direction no-barging between a wake request and delivery,
opposite-operation wakeup, repeated/coalesced resumes with condition rechecks,
cancellation clearing each installed waiter through `defer`, close idempotence,
buffered-reference discard, wakes of blocked senders and receivers, and the
exact `"channel is closed"` error from every later or woken send/receive when
no authoritative Task cancellation races with close.

In the same async channel suite, cover the opaque ChannelReader/ChannelWriter
factory, string message order, delimiters split across messages, chopped and
retained delimiters, post-match excess, empty-delimiter rejection, capacity
validation, reader-local close-to-nil, shared-close idempotence, raw peer-close
errors after preserved reader excess, blocked-operation wakes, and cancellation.
Update the string suite and all production call sites for `reader(contents)`
and `writer()` with no policy argument, and prove those in-memory read/write
methods work synchronously without a running Task.

Extend the focused uv suites for:

- success payload, exact arbitrary failure value plus raw traceback, and
  authoritative simple/complex/default cancellation status;
- `async.running()` inside and outside a Task, explicit suspension and resume,
  coalesced resume requests, resume from both the main-thread driver and a
  different running Task, stable-snapshot terminal-listener order/error
  isolation/removal (including removal during delivery), and cancellation of
  an explicitly suspended Task;
- one-shot timer close-before-resume ordering for Task creation, yield,
  explicit resume, cancellation wake, and other deferred continuations;
- listener-driven combinator wakeup, cancellation-time deferred listener
  removal, and no retained callbacks after either normal or cancelled return;
- direct native callback/function/source inventories.

Extend HTTP behavior tests for default/getter/setter/previous values, validation
before listener creation, zero-timeout delayed requests, positive initial and
keep-alive idle closes, partial-header deadlines, buffered next requests,
plain/TLS parity, no handler invocation on timeout, no uncaught timeout log,
the HTTPS peer's documented `TLS_TRUNCATED_EOF`, and complete
listener-registration/read/timer cleanup. Prove that reader success does not
wait for its cancelled deadline, while timeout waits for reader cancellation
before connection teardown. Keep handler/body/drain/write work outside this
timeout and test that boundary.

Migrate all Task string-status uses in production sources, stdlib specs,
packaging/production smokes, README, and quick tour to `as_string()` or the
new predicates. Do not alter `coroutine.Coro:status()` string call sites.

Update:

- `doc/language/async-io.md` and its index summary;
- `doc/implementation/libuv-runtime.md` and its index summary;
- `doc/language/standard-library-string.md` and its index summary;
- `doc/implementation/string-library.md` and its index summary;
- `doc/implementation/libuv-extension-guide.md` lifecycle language and
  coverage snapshot;
- `doc/language/standard-library-http.md`;
- `doc/implementation/http-library.md`;
- cancellation wording in the Lua/net language and implementation chapters;
- `doc/style-guide.md`, README, and quick tour examples; and
- `AGENTS.md` source-count and async-runtime testing invariants; and
- serialized `titan.uv`, `async`, `string`, and `http` interface fixtures,
  mechanically extracted from the rebuilt canonical provider.

Also update the language and implementation type-alias manuals for nominal
constructor/static namespaces and add checker/runtime coverage for local,
qualified re-export, chained, hidden-member, first-class-function, DSO, and
archive-backed alias use.

## Delivery gates

Run focused checker/build/runtime suites first, then the complete uncovered
library group, isolated bundled/system production smokes, and `make test` from
an environment without ambient provider/build-policy overrides. Perform an
adversarial review after tests are green, commit all code/tests/docs/plan
revisions, push the feature branch, open the PR, and wait for all required
Linux, sanitizer, consumer, and Codecov checks. The user explicitly waived the
manual macOS dispatch for this PR.
