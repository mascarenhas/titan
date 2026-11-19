# Asynchronous I/O and tasks

The `async` module provides Titan's cooperative single-loop Task scheduler, cancellation, fixed-arity Task combinators, same-state channels, callback adapters, and cross-state mailboxes. Import it in Titan with `local async = import "async"` or load it in Lua with `require "titan.async"`.

**Target availability:** Native & Browser (subset; libuv loop access, `await_*_with`, `await_cancellable*`, `run_foreign`, external waits, `version`, and `Receiver` are native-only — see [On the browser](#the-browser-target)).

For a walkthrough of Tasks, timers, channels, threads, and coroutines together, see [Concurrency: Tasks, Channels, and Threads](concurrency.md).

## Example

This program schedules two concurrent Tasks with `async.run` and waits for both results with `async.all_two`:

```titan
local async = import "async"
local io = import "io"
local timer = import "timer"

local function load_section(name: string, delay_ms: integer): string
  timer.sleep(delay_ms)
  return name .. ":ok"
end

function main(args: {string}): integer
  local users = async.run(function (): string
    return load_section("users", 20)
  end)
  local billing = async.run(function (): string
    return load_section("billing", 15)
  end)

  local users_res, billing_res = async.all_two(users, billing)
  io.print(users_res .. ", " .. billing_res)
  return 0
end
```

## Core concepts

Titan async runs **cooperatively on one event loop** (libuv natively, or the host event loop on the browser). A Task runs synchronously until it returns, raises, or suspends on I/O, a timer, a channel, a combinator, or `async.yield()`. Another Task cannot preempt it between suspension points; long CPU loops must call `async.yield()` periodically or run in an OS [`thread`](standard-library-thread.md).

- **Standalone executables:** When a program transitively imports any async-backed standard module (`async`, `timer`, `fs`, `net`, `ssl`, `http`, `websocket`, `os`, `sqlite3`, `thread`), the generated entrypoint runs `main` as a root Task and drives the loop until every Task finishes. Executables compiled with `--no-uv-bootstrap` call `main(args)` directly and must drive each session explicitly with `async.run` and `async.loop()`.
- **Lua hosts:** Load Titan's searcher with `require "titan"`, schedule Tasks with `async.run`, and drive them with `async.loop()`:

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

- **Unix `SIGPIPE`:** On Unix, initializing `async` ignores a default `SIGPIPE` disposition so writing to a closed peer raises `async.OperationError` instead of terminating the process; an inherited ignore or custom handler is preserved.
- **Non-reentrant driver:** Only top-level `async.loop()` or the standalone bootstrap drives the Runtime loop. Registration callbacks and Tasks never call `async.loop()` recursively.

## Scheduling and driving Tasks

```text
type SuspendCancelAction = function (): ()

record ResumeToken
  const source: string?
end
function ResumeToken.new(source: string?): ResumeToken

record Error
  error: value
  traceback: string
end
function Error.new(error: value, traceback: string): Error
function Error:raise()

record OperationError
  code: integer
  name: string
  message: string
  operation: string
end
function OperationError.new(code: integer, name: string,
                            message: string, operation: string): OperationError

union CancellationReason<|B|>
  simple(value: string)
  complex(value: B)
end

union TaskStatus<|A, B|>
  ready()
  running()
  waiting()
  succeeded(value: A)
  failed(value: Error)
  cancelled(value: CancellationReason<|B|>)
end

record Task<|A, B|>

function run<|A, B|>(func: function (): (A)): Task<|A, B|>
function run_with_cleanup<|A, B|>(
    body: function (): (A),
    cleanup: function (CancellationReason<|B|>?): (),
    final_wait: ExternalWait?): Task<|A, B|>
function loop()
function yield()
function running(): Task<|value, value|>
function checkpoint()
function request_exit(code: integer)
function suspend(token: ResumeToken, cancel_action: SuspendCancelAction?)
function version(): string -- native only

function Task:cancel(reason: CancellationReason<|B|>?)
function Task:status(): TaskStatus<|A, B|>
function Task:resume(token: ResumeToken)

function TaskStatus:as_string(): string
function TaskStatus:has_finished(): boolean
function TaskStatus:has_succeeded(): (boolean, A?)
function TaskStatus:has_failed(): (boolean, Error?)
function TaskStatus:has_cancelled(): (boolean, CancellationReason<|B|>?)
```

`Task<|A, B|>` carries success type `A` and complex-cancellation payload type `B`. A bare `Task`, `TaskStatus`, or `CancellationReason` means the all-`value` application. In `run<|A, B|>`, `B` is inferred from result context when present and otherwise defaults to `value`; explicit type arguments supply both (`async.run<|string, value|>(fn)`). `running()` always returns `Task<|value, value|>` and raises outside a Task.

- **`run(func)`** schedules a Task on the Runtime's bounded FIFO ready queue and returns its handle without calling `func` inline. Each event-loop turn services at most 64 already-queued entries so I/O callbacks continue making progress during sustained Task activity.
- **`run_with_cleanup(body, cleanup, final_wait?)`** wraps the Task so `defer cleanup(reason)` is installed before `checkpoint()` and `body()`. Cleanup runs whenever the body exits or unwinds, receiving the Task's first sticky `CancellationReason<|B|>?` (or `nil` if uncancelled). The optional `final_wait` binds one live, unbound native-retirement `ExternalWait` from `prepare_native_retirement` as the Task's exclusive retirement gate before exposing the Task, holding terminal status and terminal listeners until native retirement finishes (even if root or cleanup entry fails). If admission fails, registration rolls back without retiring the caller's resource. A Task has a finite suspension count (exhaustion raises `"async Task suspension epoch exhausted"` without wrapping); a bound `final_wait:wait_cleanup()` called from that Task's cleanup reserves the Task's final suspension slot so cleanup can attach even after ordinary suspensions run out.
- **`Task:status()`** returns an immutable snapshot. Nonterminal tags are `ready`, `running`, and `waiting`; calling `cancel` records the reason privately without creating an intermediate public status. `as_string()` returns the variant name, and `has_finished`, `has_succeeded`, `has_failed`, and `has_cancelled` inspect terminal states without writing a `case`.
- **`yield()`** queues the current Task onto the ready queue for a later turn (raising outside a Task).
- **`checkpoint()`** requires a running Task, raises its first pending cancellation reason if any, then checks for fatal Runtime shutdown—without yielding or scheduling other Tasks.
- **`request_exit(code)`** requires a running Task. It records the first requested exit code, cancels every unfinished Task (including the caller) with `"program exit"`, raises the caller's cancellation reason, and stops admitting new `run` calls and native resource handoffs (without changing `is_closing()`). Cleanup `defer`s and `await_cleanup` still run, and standalone executables return `code` after draining. In a Lua host calling `async.loop()`, draining does not exit the host process.
- **`version()`** *(native only)* returns the bundled libuv version string.

### Explicit suspension and `ResumeToken`

`async.suspend(token, cancel_action?)` suspends the current Task without registering native work; `Task:resume(token)` wakes it with a deferred continuation.

- `ResumeToken` is matched by **nominal record identity** (`source` is diagnostic text only). Calling `resume` with any other token raises `"Task resume token mismatch (expected source: <source>)"` (using `unknown source` when absent or nil). Calling `resume` on a ready, native-waiting, yielding, or terminal Task likewise raises with `unknown source`.
- **Running-Task latch:** Calling `Task:resume(token)` while the target Task is currently running (or registering its next wait)—for example from a finalizer—latches `token` (latest wins, identical token coalesces). If the Task's immediately next suspension is `suspend` with that exact token, it returns immediately; any other next suspension or Task exit discards the latch. Publish the waiter registration before checking the wait condition, clear it before calling `resume` (or recheck the condition after `suspend`), and use a fresh token per wait to make stale wakes unmatchable.
- **`cancel_action`:** Runs synchronously at most once when cancellation interrupts an already-suspended or registering `suspend` (not if cancellation was already pending before `suspend` or on normal `resume`). Keep it non-yielding and non-raising; detach the waiter in `defer` as well.
- Repeated valid `resume` calls before delivery coalesce onto the ready queue and never reenter the target Task inline.

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
  local token = async.ResumeToken("Gate.wait")
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

### Blocking C work (`run_foreign`)

```text
function run_foreign(f: foreign function (*void): void,
                     arg: foreign *void,
                     abandoned: foreign function (*void): void)
```

*(Native only; callable from statically compiled Titan code only, as raw C pointers have no Lua coercion.)*

`async.run_foreign(f, arg, abandoned)` runs `f(arg)` on libuv's shared worker thread pool and suspends the current Task until the after-work callback runs on the event-loop thread. `f` may be a restricted source `foreign function`; a NULL `f` is rejected before submission.

- **No Lua/Titan access:** `f` must not touch the host Lua state, call Lua/Titan functions, allocate via the runtime, raise, or resume Tasks. Keep native storage pointed to by `arg` alive and synchronized until completion (`owned` allocations stay rooted by the suspended caller frame).
- **Floating-point state:** Pool threads retain whatever FP state prior jobs left; on Windows new threads start with 53-bit x87 precision, so a worker needing extended `long double` precision must reset it (unlike `Lua:run_async`, `sqlite3`, and `thread`, which restore it automatically — see [long double on worker threads](windows-build.md#long-double-on-worker-threads)).
- **Completion and cancellation:** Status zero resumes normally; nonzero raises `OperationError`. Cancelling the waiting Task does not stop `f(arg)`: the caller frame retains `arg` until `f` finishes, then delivers the pending cancellation. Long jobs share the pool with libuv filesystem and DNS work (see [pool capacity](standard-library-lua.md#two-phase-receiver-bootstrap)).
- **State close:** Pass the optional C-only `abandoned(arg)` callback (or omit/`nil`) to release caller-owned native state if a Lua state close unwinds the Task before `f(arg)` returns; see [Foreign work at state close](#foreign-work-at-state-close).

## Terminal listeners and Task combinators

```text
function Task:add_terminal_listener(
    listener: function (TaskStatus<|A, B|>): ()): function (): ()

union AnyTwoResult<|A1, A2|>
  first(value: A1) | second(value: A2) | none()
end
union AnyThreeResult<|A1, A2, A3|>
  first(value: A1) | second(value: A2) | third(value: A3) | none()
end
union AnyFourResult<|A1, A2, A3, A4|>
  first(value: A1) | second(value: A2) | third(value: A3) | fourth(value: A4) | none()
end
union AnyFiveResult<|A1, A2, A3, A4, A5|>
  first(value: A1) | second(value: A2) | third(value: A3) | fourth(value: A4) | fifth(value: A5) | none()
end

union RaceTwoResult<|A1, B1, A2, B2|>
  first(value: TaskStatus<|A1, B1|>) | second(value: TaskStatus<|A2, B2|>)
end
union RaceThreeResult<|A1, B1, A2, B2, A3, B3|>
  first(value: TaskStatus<|A1, B1|>) | second(value: TaskStatus<|A2, B2|>)
  | third(value: TaskStatus<|A3, B3|>)
end
union RaceFourResult<|A1, B1, A2, B2, A3, B3, A4, B4|>
  first(value: TaskStatus<|A1, B1|>) | second(value: TaskStatus<|A2, B2|>)
  | third(value: TaskStatus<|A3, B3|>) | fourth(value: TaskStatus<|A4, B4|>)
end
union RaceFiveResult<|A1, B1, A2, B2, A3, B3, A4, B4, A5, B5|>
  first(value: TaskStatus<|A1, B1|>) | second(value: TaskStatus<|A2, B2|>)
  | third(value: TaskStatus<|A3, B3|>) | fourth(value: TaskStatus<|A4, B4|>)
  | fifth(value: TaskStatus<|A5, B5|>)
end

union AllTwoError<|A1, B1, A2, B2|>
  first(value: TaskStatus<|A1, B1|>) | second(value: TaskStatus<|A2, B2|>)
end
union AllThreeError<|A1, B1, A2, B2, A3, B3|>
  first(value: TaskStatus<|A1, B1|>) | second(value: TaskStatus<|A2, B2|>)
  | third(value: TaskStatus<|A3, B3|>)
end
union AllFourError<|A1, B1, A2, B2, A3, B3, A4, B4|>
  first(value: TaskStatus<|A1, B1|>) | second(value: TaskStatus<|A2, B2|>)
  | third(value: TaskStatus<|A3, B3|>) | fourth(value: TaskStatus<|A4, B4|>)
end
union AllFiveError<|A1, B1, A2, B2, A3, B3, A4, B4, A5, B5|>
  first(value: TaskStatus<|A1, B1|>) | second(value: TaskStatus<|A2, B2|>)
  | third(value: TaskStatus<|A3, B3|>) | fourth(value: TaskStatus<|A4, B4|>)
  | fifth(value: TaskStatus<|A5, B5|>)
end

function any_two<|A1, B1, A2, B2|>(first: Task<|A1, B1|>, second: Task<|A2, B2|>): AnyTwoResult<|A1, A2|>
function any_three<|A1, B1, A2, B2, A3, B3|>(...): AnyThreeResult<|A1, A2, A3|>
function any_four<|A1, B1, A2, B2, A3, B3, A4, B4|>(...): AnyFourResult<|A1, A2, A3, A4|>
function any_five<|A1, B1, A2, B2, A3, B3, A4, B4, A5, B5|>(...): AnyFiveResult<|A1, A2, A3, A4, A5|>

function race_two<|A1, B1, A2, B2|>(first: Task<|A1, B1|>, second: Task<|A2, B2|>): RaceTwoResult<|A1, B1, A2, B2|>
function race_three<|A1, B1, A2, B2, A3, B3|>(...): RaceThreeResult<|A1, B1, A2, B2, A3, B3|>
function race_four<|A1, B1, A2, B2, A3, B3, A4, B4|>(...): RaceFourResult<|A1, B1, A2, B2, A3, B3, A4, B4|>
function race_five<|A1, B1, A2, B2, A3, B3, A4, B4, A5, B5|>(...): RaceFiveResult<|A1, B1, A2, B2, A3, B3, A4, B4, A5, B5|>

function all_two<|A1, B1, A2, B2|>(first: Task<|A1, B1|>, second: Task<|A2, B2|>): (A1, A2)
function all_three<|A1, B1, A2, B2, A3, B3|>(...): (A1, A2, A3)
function all_four<|A1, B1, A2, B2, A3, B3, A4, B4|>(...): (A1, A2, A3, A4)
function all_five<|A1, B1, A2, B2, A3, B3, A4, B4, A5, B5|>(...): (A1, A2, A3, A4, A5)

function join<|A, B|>(task: Task<|A, B|>): TaskStatus<|A, B|>
function join_two<|A1, B1, A2, B2|>(...): (TaskStatus<|A1, B1|>, TaskStatus<|A2, B2|>)
function join_three<|A1, B1, A2, B2, A3, B3|>(...): (TaskStatus<|A1, B1|>, TaskStatus<|A2, B2|>, TaskStatus<|A3, B3|>)
function join_four<|A1, B1, A2, B2, A3, B3, A4, B4|>(...): (TaskStatus<|A1, B1|>, TaskStatus<|A2, B2|>, TaskStatus<|A3, B3|>, TaskStatus<|A4, B4|>)
function join_five<|A1, B1, A2, B2, A3, B3, A4, B4, A5, B5|>(...): (TaskStatus<|A1, B1|>, TaskStatus<|A2, B2|>, TaskStatus<|A3, B3|>, TaskStatus<|A4, B4|>, TaskStatus<|A5, B5|>)
```

`Task:add_terminal_listener(listener)` registers a callback invoked once when an unfinished Task publishes its terminal `TaskStatus<|A, B|>`, returning an idempotent remover (install it in `defer`). Registering on an already-terminal Task returns a no-op remover without invoking `listener`. At terminal publication, the Runtime snapshots the registration list, runs every listener in registration order, and ignores listener errors (removers called during delivery are no-ops).

The four combinator families wait on heterogeneous Tasks using interleaved `(A1, B1, A2, B2, ...)` type parameters:

| Family | Completes when | Outcome |
| --- | --- | --- |
| `join`, `join_two`..`join_five` | All inputs finish | Returns each `TaskStatus`; never raises a child's error |
| `all_two`..`all_five` | All succeed, or first fails/cancels | Returns `(A1, ...)` on all-success; raises `AllTwoError`, `AllThreeError`, `AllFourError`, or `AllFiveError` on the first non-success status |
| `race_two`..`race_five` | First input finishes (any status) | Returns `RaceTwoResult`..`RaceFiveResult` carrying the winner's `TaskStatus` |
| `any_two`..`any_five` | First input succeeds, or all fail/cancel | Returns `AnyTwoResult`..`AnyFiveResult` with the winning value or `none()` |

Each combinator scans its operands left-to-right first (breaking ties among already-terminal operands), then listens in publication order. Passing the current Task (`async.running()`) raises. Combinators never cancel unfinished inputs automatically:

```titan
local async = import "async"
local io = import "io"
local timer = import "timer"

function read_with_deadline(reader: io.Reader, timeout_ms: integer): string?
  local reading = async.run(function (): string?
    return reader:read()
  end)
  local deadline = async.run(function (): nil
    timer.sleep(timeout_ms)
    return nil
  end)

  local result = async.any_two(reading, deadline)
  case result
  when first(data) then
    deadline:cancel(async.CancellationReason.simple("read completed"))
    return data
  when second() then
    reading:cancel(async.CancellationReason.simple("read timed out"))
    async.join(reading)
    raise "read timed out"
  when none() then
    local read_status, _ = async.join_two(reading, deadline)
    local failed, err? = read_status:has_failed()
    if failed and err ~= nil then err:raise() end
    return nil
  end
end
```

When a Task owns shared state that must outlive cancellation of the parent Task too, install lexical `defer` cleanup immediately after spawning that cancels the child and waits on a removable terminal listener through `async.await_cleanup` (since ordinary `async.join` is cancellation-sensitive).

## Bounded channels

```text
function channel<|T|>(size: integer?):
    (function (T): (), function (): (T), function (): ())
```

`async.channel<|T|>(size?)` creates a bounded same-state FIFO channel and returns `(send, receive, close)` closures that pass values directly without serialization.

```titan
local async = import "async"
local io = import "io"

function main(args: {string}): integer
  local send, receive, close = async.channel<|string|>(2)
  defer close()

  send("alpha")
  send("beta")
  io.print(receive() .. "," .. receive())
  return 0
end
```

- **Type and capacity:** Specify `T` explicitly (or via expected return types); with neither, `T` defaults to `value`. `size` defaults to `1` (`size <= 0` raises). `nil` is an ordinary payload whenever `T` admits `nil`.
- **Single waiter per direction:** `send` suspends only when full and `receive` only when empty; non-blocking paths complete synchronously without requiring a Task. At most one blocked sender and one blocked receiver are allowed at a time; a competing same-direction call raises even while a previous waiter's wake is pending.
- **Closing:** `close()` is synchronous and idempotent. It marks the channel closed, discards unread buffered items, and wakes blocked waiters with `"channel is closed"` (unless Task cancellation wins the unwind). Later sends and receives raise `"channel is closed"`.

## Channel-backed string streams

```text
record ChannelReader
record ChannelWriter

function reader_writer_channel(size: integer?): (ChannelReader, ChannelWriter)
function ChannelReader:read(): string?
function ChannelReader:read_until(delimiter: string, chop: boolean?): string?
function ChannelReader:close()
function ChannelWriter:write(data: string)
function ChannelWriter:close()
```

`reader_writer_channel(size?)` constructs an opaque `ChannelReader` (`io.ReaderCloser`) and `ChannelWriter` (`io.WriterCloser`) over a `channel<|string|>(size)`.

- Each `write(data)` sends one string chunk; `read()` returns any suffix left over from an earlier `read_until`, or receives the next chunk.
- `read_until(delimiter, chop?)` matches a literal binary-safe delimiter across chunk boundaries, returning up to the delimiter (omitting it when `chop` is `true`) and retaining trailing bytes for subsequent reads. An empty delimiter raises on an open reader.
- `ChannelReader:close()` closes the underlying channel, marks the reader closed, and discards its buffered suffix so subsequent reads return `nil`. `ChannelWriter:close()` closes the channel without discarding the reader's already-received suffix: the reader can still consume that suffix, and the first operation needing another receive raises `"channel is closed"`. Closing either side wakes an already-blocked peer with `"channel is closed"`.

## Adapting callbacks with await

Library adapters combine ordinary compiled imports of `async` and `uv` to wrap callback-based libuv APIs into direct-style Task calls.

```text
union Result<|T, E|>
  success(value: T)
  error(value: E)
end

union CancellableResult<|T, E|>
  success(value: T)
  error(value: E)
  cancelled(value: CancellationReason<|value|>)
end

record Completion<|C, T, E|>
function Completion:context(number: integer): C
function Completion:resolve(number: integer, result: T)
function Completion:reject(number: integer, error: E)
function Completion:fatal(number: integer, error: value, traceback: string)

function await_with<|C, T, E|>(
    context: C,
    start: function (Completion<|C, T, E|>, integer): (uv.req_t?)): Result<|T, E|>
function await_cleanup_with<|C, T, E|>(
    context: C,
    start: function (Completion<|C, T, E|>, integer): (uv.req_t?)): Result<|T, E|>
function await_cancellable_with<|C, T, E|>(
    context: C,
    start: function (Completion<|C, T, E|>, integer): (uv.req_t?)): CancellableResult<|T, E|>

function await<|T, E|>(op: function (
    function (T): (), function (E): (), function (value, string): ()): ()): Result<|T, E|>
function await_cleanup<|T, E|>(op: function (
    function (T): (), function (E): (), function (value, string): ()): ()): Result<|T, E|>
function await_cancellable<|T, E|>(op: function (
    function (T): (), function (E): (), function (value, string): ()): (uv.req_t?)): CancellableResult<|T, E|>

function current_loop(): uv.loop_t   -- native only
function is_closing(): boolean
```

The `_with` functions *(native only)* pass a reusable `Completion<|C, T, E|>` and a monotonically increasing operation `number` to `start`, avoiding per-wait closure allocation when `start` is a named function. Always capture the supplied `number` alongside `done`: `context`, `resolve`, and `reject` reject mismatched numbers and duplicate settlements. Save any needed context into callback locals *before* settling, because settlement clears the completion slot before the continuation runs.

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

`await`, `await_cleanup`, and `await_cancellable` wrap the same mechanism with three per-operation closures: `resolve(T)`, `reject(E)`, and `fatal(error, traceback)`. Inspect returned `Result` / `CancellableResult` values with `case` (never compare them with `==` or use them as Map keys; payload-free `success(nil)` may be shared).

All await forms require a running Task. The registration callback runs outside any Task (`async.running()` raises there); `current_loop()` returns the active Runtime's borrowed `uv.loop_t`, and `is_closing()` reports whether fatal Runtime shutdown has begun (both raise when no Runtime is active). Never stop, close, or unref Runtime-owned handles on the borrowed loop.

| Form | Pending cancel before start | After native acceptance | Completion with cancel pending |
| --- | --- | --- | --- |
| `await_with` / `await` | Skip registration; raise first reason | Retain operation; no native cancel | Wait for terminal callback, then raise reason |
| `await_cancellable_with` / `await_cancellable` | Skip registration; return `cancelled(reason)` | Attempt `uv.cancel` on returned `uv.req_t`; retain regardless | Wait for terminal callback, then return `cancelled(reason)` |
| `await_cleanup_with` / `await_cleanup` | Run registration | Retain operation; no native cancel | Return ordinary `success`/`error` result |

Cancellable registrations must return the accepted `uv.req_t` unless already settled inline (returning `nil` without settling raises `"cancellable registration returned nil without settling"`). Pending cancellation remains sticky across all forms; reserve `await_cleanup*` for ownership-retiring cleanup, which stays admissible during Runtime shutdown.

Inline settlement inside registration resumes the Task once registration returns; callback settlement from libuv resumes directly, while settlement from another running Task or a finalizer queues a deferred continuation.

### Unexpected terminal callback failure

Use `reject(E)` for expected domain or libuv errors. For an unexpected exception inside a one-shot terminal callback, clean up the native request, report the failure via `fatal(error, traceback)` (or `done:fatal(number, error, traceback)`), and re-raise:

```text
local callback = function (completed: uv.fs_t)
  local result = uv.fs_get_result(completed)
  -- Move acquired resources or copy borrowed bytes before cleanup.
  uv.fs_req_cleanup(completed)
  if result < 0 then reject(result) else resolve(result) end
catch
  uv.fs_req_cleanup(completed)
  fatal(error, traceback)
  raise
end
```

Call `fatal` only outside a running Task after the operation's native completion has been consumed. If the wait is still pending, `fatal` injects the exception into that Task immediately; if already settled, it records Runtime failure without disturbing a newer wait. After Task cleanup and native drain, `async.loop()` rethrows the first Runtime error with its original traceback.

### A public-only File adapter

This minimal read-only adapter (extended with `read` in [async-file-example.titan](async-file-example.titan)) illustrates ownership across cancellation: `open` stores the acquired descriptor on its lexical `File` before cleanup and closes it in `catch` if cancellation replaces the await result; `close` uses `await_cleanup` and restores the descriptor only if submission failed before native acceptance.

```titan
local async = import "async"
local uv = import "uv"

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
    local outcome = async.await_cleanup<|integer, integer|>(function (resolve, reject, fatal)
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
    local outcome = async.await<|File, integer|>(function (resolve, reject, fatal)
      local callback = function (completed: uv.fs_t)
        local result = uv.fs_get_result(completed)
        if result >= 0 then file.descriptor = result end
        uv.fs_req_cleanup(completed)
        if result < 0 then reject(result) else resolve(file) end
      catch
        uv.fs_req_cleanup(completed)
        fatal(error, traceback)
        raise
      end
      local status = uv.fs_open(async.current_loop(), request, path,
          uv.FS_O_RDONLY, 0, callback)
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
    file:close()
    raise
  end
end
```

### External waits

*(Native only; `ExternalWait` exists on the browser solely as an opaque type.)*

```text
record ExternalWait

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
function wait_external_cleanup(
    register_fn: function (foreign *void): boolean,
    unregister_fn: function (): ())
function wait_external_native(
    owner: value, context: foreign *void,
    register_fn: foreign function (*void, *void): int,
    unregister_fn: foreign function (*void): void)
```

Cross-thread adapters (such as `thread.channel` and `Thread:join()`) suspend Tasks over the Runtime's shared [`uv.external_wake_t`](uv/types.md#external_wake_t) bridge without allocating a `uv.async_t` per wait.

- **Preparation:** `prepare_external_wait(register_fn, unregister_fn)` may run outside a Task (creating the Runtime if needed, raising `"cannot prepare an external wait while async Runtime is shutting down"` after shutdown or `request_exit`). It assigns a monotonically increasing positive identity (exhaustion raises `"async external wait identity exhausted"`) and reserves an unreferenced native wake target via [`external_wake_t:reserve`](uv/supplemental.md#external_wake_treserve) so unused waits never keep the loop alive.
- **One-shot `ExternalWait`:** Bound to its creating Runtime (`"external wait belongs to another async Runtime"` otherwise; `"external wait is consumed or closed"` if reused or closed). `wait()` is cancellation-sensitive; `wait_cleanup()` is cancellation-insensitive and admitted during shutdown; `close()` idempotently retires an unused wait (`"cannot close an active external wait"` while pending).
- **Registration & notification:** When waiting starts, the bridge activates the target ([`external_wake_t:activate`](uv/supplemental.md#external_wake_tactivate)), referencing the shared handle, and invokes `register_fn(target)`. Returning `false` resolves inline; returning `true` means `register_fn` retained a producer reference via [`uv.native_external_wake_retain(target)`](uv/supplemental.md#native_external_wake_retain) and linked its native waiter. Producers on any thread call [`uv.native_external_wake_notify(target)`](uv/supplemental.md#native_external_wake_notify) and [`uv.native_external_wake_release(target)`](uv/supplemental.md#native_external_wake_release). The loop thread drains batches of up to 64 identities and schedules matching Tasks onto the deferred ready queue.
- **Cancellation:** Cancelling an active wait—even after a producer notified it but before the Task resumed—synchronously calls `unregister_fn()` and [`external_wake_t:unregister`](uv/supplemental.md#external_wake_tunregister). If a producer targeted this waiter exclusively (as in a bounded channel), `unregister_fn` must relay the wakeup to another waiter.
- **Convenience wrappers:** `wait_external` and `wait_external_cleanup` prepare, `defer close()`, and run `wait()` or `wait_cleanup()`.
- **C callbacks (`wait_external_native`):** Performs one ordinary wait using non-NULL, non-raising, non-yielding C callbacks instead of Titan closures (NULL raises `"native external wait callbacks must not be NULL"`), keeping `owner` reachable until return. `register_fn(context, target)` returns `0` (already ready), `1` (waiter linked with retained `target`), or a negative status (raises `OperationError` with operation `"async.external_wait.register"`). `unregister_fn(context)` withdraws the waiter idempotently on failed registration, cancellation, or state close.
- **State close:** If the Lua state closes while parked, `unregister_fn` runs before the coroutine stack and automatic `context` are freed. Because `owner` may already be finalized by then, each linked registration must hold its own native reference pin on the shared native object until `unregister_fn` runs or the resumed Task's next locked step completes. Keep `context` and all callback storage alive through native completion ([C storage after a caught error](ffi.md#c-storage-after-a-caught-error)).

#### Native retirement capabilities

`prepare_native_retirement(owner, context, register_fn, unregister_fn, retire_fn)` creates the exclusive native-retirement `ExternalWait` accepted by `run_with_cleanup`'s third argument (NULL callbacks raise `"native retirement callbacks must not be NULL"`).

- **C-only callbacks:** None receive a Lua state or allocate:
  - `register_fn(context, target): int` returns `0` (already finished, nothing linked), `1` (waiter linked retaining `target`), or negative status (rejects cleanly).
  - `unregister_fn(context)` unlinks and releases during constructor rollback only.
  - `retire_fn(context): int` runs on the loop thread and returns `0` once native retirement completes (idempotently), `1` while pending, or a negative error while keeping the native token intact. Producers notify only when the next `retire_fn` call can return `0` or a negative error.
- **Binding and rollback:** `run_with_cleanup` validates that the capability is live, unused, same-Runtime, and unbound, then arms the barrier before exposing the Task (`0` from `register_fn` must retire immediately, or `"native retirement is not complete"` raises). Admission failures roll back cleanly (`OperationError` with `"async.native_retirement.activate"`, `"async.native_retirement.register"`, or `"async.native_retirement.retire"`) without retiring the caller's domain resource.
- **Optional cleanup attachment:** Calling `:wait_cleanup()` outside the bound Task's cleanup raises `"native retirement is not bound to a cleanup Task"` or `"external wait is reserved for its Task cleanup"`. Calling `:close()` from cleanup closes only the user view while the Task keeps the barrier until retirement.
- **Terminal publication and driver retry:** Pending Task outcomes and terminal listeners wait until both the Task root and native retirement complete. A negative `retire_fn` status on an admitted barrier escapes `async.loop()` as `OperationError` (`"async.native_retirement.retire"`) while keeping the Task, barrier, and Runtime intact; calling `async.loop()` again retries retirement once before blocking.

## Persistent callback subscriptions

Subscriptions bridge a persistent native producer to one waiting Task. Use `CoalescingSubscription` when only the latest unconsumed value matters (such as ticks) and `BufferedSubscription` when every event and its order matter.

```text
record SubscriptionBatch<|T|>
  const count: integer
end
function SubscriptionBatch:get(index: integer): T

union SubscriptionResult<|T, E|>
  item(value: T)
  error(value: E)
  ended()
  closed()
end

union SubscriptionBatchResult<|T, E|>
  batch(value: SubscriptionBatch<|T|>)
  error(value: E)
  ended()
  closed()
end

record SubscriptionActions<|T|>
  const stop: function (): ()
  const close: function (function (): (SubscriptionBatch<|T|>)): ()
end
function SubscriptionActions.new(
    stop: function (): (),
    close: function (function (): (SubscriptionBatch<|T|>)): ()): SubscriptionActions<|T|>

record CoalescingSubscription<|T, E|>
record BufferedSubscription<|T, E|>

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
function BufferedSubscription:next_batch(): SubscriptionBatchResult<|T, E|>
function BufferedSubscription:has_waiter(): boolean
function BufferedSubscription:has_pending(): boolean
function BufferedSubscription:stop()
function BufferedSubscription:close()
function BufferedSubscription:drain_pending(): SubscriptionBatch<|T|>
function BufferedSubscription:snapshot_pending():
    (SubscriptionBatch<|T|>, (SubscriptionResult<|T, E|>)?)
function BufferedSubscription:drain_if(predicate: function (T): (boolean)):
    SubscriptionBatch<|T|>?
function BufferedSubscription:wake_batch()
```

- **Producer setup & publishing:** Construction invokes `producer(publish, fail, finish)` synchronously; prebuild `SubscriptionActions` and rollback state before accepting native resources. `publish(item)` returns `true` once ownership is queued and any wake is accepted, or `false` if terminal (dispose of resource-bearing items on `false` or exception). Coalescing queues overwrite unread values without disposing of them, so put resource-bearing events in a `BufferedSubscription`. `fail(err)` and `finish()` latch the first terminal state and return `false` afterward.
- **Reading:** `next()` yields `item(v)`, then sticky `error(e)` or `ended()` after buffered items drain; `closed()` takes immediate priority without draining unread items. `next_batch()` detaches the entire current FIFO into a `SubscriptionBatch` indexed `1..batch.count` (both `nil` and `false` are valid payloads; always iterate via `count`). At most one reader may wait across `next` and `next_batch` (`"subscription already has a waiter"` otherwise); cancellation detaches the waiter without stopping the producer or discarding queued items. `has_waiter()` and `has_pending()` are synchronous, non-consuming snapshots.
- **Stop & close:** `stop()` is synchronous and idempotent: it marks a live subscription ended and runs `actions.stop()` once (non-yielding), leaving queued items readable. `close()` requires a Task on its first call, marks the queue closed, runs stop plus `actions.close(drain)` (which may use `await_cleanup` and must dispose of unread resource-bearing items returned by `drain()`), and drops all action closures afterward. Repeated `close()` calls are no-ops and do not wait for an in-progress close.
- **Producer-side buffered controls (synchronous, non-yielding):**

| Method | Behavior |
| --- | --- |
| `drain_pending()` | Detaches the entire current queue (possibly empty) without changing terminal state. |
| `snapshot_pending()` | Copies the unread queue without consuming it, returning `(batch, terminal_or_nil)`. |
| `drain_if(predicate)` | Scans FIFO; if any item matches, detaches the whole queue in order, else returns `nil`. `predicate` must not yield or mutate the subscription. |
| `wake_batch()` | Wakes a waiting `next_batch()` reader (returning a zero-count batch if empty) without storing credit or ending the subscription. |

## Errors and cancellation

Standard domain modules raise `async.OperationError` for libuv-level failures, identifying the failed action in `operation`, the symbolic libuv error in `name`, the numeric code in `code`, and human-readable text in `message`.

An uncaught error escaping a Task without pending cancellation produces `TaskStatus.failed(Error(err, traceback))` and logs a diagnostic report (without killing sibling Tasks). A Task with pending cancellation instead finishes `TaskStatus.cancelled(reason)` even if user code catches or returns from the raised reason.

`async.Error(err, traceback):raise()` re-raises the original error value with its captured traceback, preserving nominal error identity across supervised child Tasks.

`Task:cancel(reason?)` records the Task's first `CancellationReason<|B|>` (`nil` selects `CancellationReason.simple("cancelled")`), injects it at cancellation-sensitive suspension points, and lets `defer` and `await_cleanup` retire resources cleanly.

## Resources and shutdown

Explicit lexical `close()` owns resource teardown. When a fatal callback or driver error occurs, the Runtime records the first error, cancels remaining Tasks (allowing `await_cleanup` and accepted native requests to finish), walks and closes remaining libuv handles, closes the loop, and rethrows that error from `async.loop()`. If the loop becomes idle while Tasks remain suspended without native progress, the driver reports the deadlock and unwinds the stranded waits.

Note that `fs.File` owns an OS descriptor rather than a libuv handle, so Runtime loop walking does not close forgotten files (see [closing the Lua state](standard-library-fs.md#closing-the-lua-state)), and closing a child-process watcher does not signal or reap the child process.

### Runtime close listeners

```text
function add_close_listener(listener: function (): ()): function (): ()
```

`add_close_listener(listener)` registers an ordered, once-only cleanup callback on the active Runtime and returns an idempotent remover. It does not create a Runtime and rejects registration once shutdown begins.

Listeners run outside any Task after every Task and native handle has retired and the loop has closed, just before the Runtime is cleared. A listener must not yield, start Tasks, or use the retired loop; it is intended for releasing non-handle resources retained by domain owners (such as an idle connection's TLS context). Removing a later listener during notification skips it. Every remaining listener runs even if another raises, and `async.loop()` raises the first Runtime or listener error after clearing the Runtime. Remove listeners on explicit owner close to release captures early.

### Closing a Lua state with an active Runtime

If a Lua state closes while a Runtime is still active (without draining `async.loop()`), every unfinished Task is [unwound](coroutines.md#abandoned-coroutines) in a finalizer (running `defer` blocks and withdrawing parked external waits), `run_with_cleanup` cleanups run with the Task's reason (or `simple("async Runtime abandoned at Lua state close")`), and remaining loop handles are abandoned via [`uv.loop_abandon`](standard-library-uv.md#abandoned-loop-retirement) without running user callbacks or Runtime close listeners. Accepted worker-pool jobs still finish before `lua_close` returns.

During state close, operations requiring a Task raise `"asynchronous operation must be called from an async Task"`, `run`/`run_with_cleanup` raise `"cannot start a Task during Lua state close"`, and operations that would create a new Runtime raise `"cannot create an async Runtime during Lua state close"`. Abandoned Tasks become terminal `cancelled(...)` unless an armed native-retirement gate keeps them nonterminal.

#### Foreign work at state close

A Task parked in `async.run_foreign` unwinds during state close *before* `f(arg)` returns, so do not free `arg` inside a `defer` around `run_foreign`. An `owned` allocation stays alive until the Runtime drains accepted worker jobs. For other native memory, pass the optional C-only `abandoned(arg)` third argument: the Runtime calls `abandoned(arg)` on the closing thread only after `f(arg)` has returned (it must not enter the closing Lua state). In every non-abandoned path `abandoned` is never called; release the memory after `run_foreign` returns or in `catch` (skipping it in `defer` via a flag).

## Transfer values

`async.TransferValue` is a transparent alias of [`transfer.TransferValue`](standard-library-transfer.md):

```text
union TransferValue
  is_nil()
  is_boolean(value: boolean)
  is_integer(value: integer)
  is_float(value: float)
  is_string(value: string)
  is_lua_state(value: foreign *lua_State)
  is_function(value: foreign function (*lua_State): int)
  is_pointer(value: foreign *void)
  is_record(module: string, name: string, data: string)
  is_union(module: string, name: string, data: string)
  is_closure(module: string, entry: foreign const *void, data: string)
  is_record_payload(module: string, name: string, data: string)
end

function TransferValue.from_value(candidate: value): TransferValue
function TransferValue.from_closure_payload(module: string, entry: value,
                                            data: string): TransferValue
function TransferValue:to_value(): value
```

- **Scalars & strings:** `nil`, `boolean`, `integer`, and `float` (including integral floats and `-0.0`) preserve exact kind; `string` copies all bytes including embedded NULs.
- **Borrowed addresses:** Light userdata and non-Titan full userdata become `is_pointer`; Lua threads become `is_lua_state`; light C functions and upvalue-free C closures become `is_function` (NULL rejected). Borrowed addresses retain nothing—keep storage, code, and originating roots alive across the borrow.
- **Nominals:** Public records with [custom hooks](#custom-record-transfer) become `is_record_payload`; `thread.Sender` / `thread.Receiver` become packet-scoped `is_record_payload` (requiring an active packet scope); other public records and unions serialize via [protobuf](standard-library-protobuf.md) as `is_record` / `is_union`, recording their defining module and qualified name so `to_value()` can load the module on demand.
- **Rejected:** Lua closures, C closures with upvalues, top-level Arrays and Maps, Interfaces, and owned foreign storage.

### Closure snapshots

`TransferValue.from_value(callback)` snapshots a Titan closure by validating its manifest entry, projecting its entire immediate capture frontier before running any capture's custom hook (preventing an earlier hook from mutating a shared cell seen by a later capture), and converting each capture in declaration order into `is_closure`. `from_closure_payload` wraps already-copied closure fields from a trusted transport, checking the raw entry pointer and deferring manifest validation and capture decoding to `to_value()`.

In the destination state, `to_value()` loads the defining module, validates the entry token against the module manifest, validates every capture before running any custom decoder, and creates a fresh callable bound to the destination's module variables. Mutable captures become independent fresh cells in the destination (shared aliasing is not preserved across snapshots). Captured `TransferValue` values remain wrapped policies; ordinary captures recover their decoded values.

### Custom record transfer

A public record opts into custom transfer by declaring two synchronous, non-yielding public members:

```text
function Record:to_transfer_payload(): string
function Record.from_transfer_payload(payload: string): Record
```

Reflection checks exact signatures before invoking either hook (incomplete or mismatched pairs raise instead of falling back to protobuf). The record may contain private fields, and hooks may use `protobuf.serialize_fields` / `protobuf.deserialize_fields` for structured private state. Recursive conversion of the same active record or closure raises, and hook side effects (such as detaching a manual-handoff resource) are not rolled back if a later step fails.

Resources follow either packet-scoped attachment (`transfer.attach_resource` / `claim_resource`, used by `thread.Sender` and `thread.Receiver`, requiring an active `encode_message` / `decode_message` scope) or manual handoff under the [shared manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules) and [API inventory](standard-library-transfer.md#manual-handoff-api-inventory).

## Cross-state receivers

*(Native only.)*

```text
record Receiver

function receiver(): Receiver
function Receiver:handle(): foreign *void
function send(handle: foreign *void, candidate: value)
function Receiver:wait(): value
function Receiver:close()
```

A `Receiver` is a **lossy, coalescing single-slot mailbox** in one Lua state that other states or OS threads wake through a borrowed native handle. Each `send` overwrites any unread value; use [`thread.channel`](standard-library-thread.md#cross-thread-channels) when you need a lossless FIFO queue.

- **Creating:** `receiver()` creates a receiver in the current state's Runtime (bootstrapping it outside a Task without driving the loop; raising `"cannot create a receiver while async Runtime is shutting down"` after shutdown or `request_exit`). Only the opaque address from `Receiver:handle()` may cross states, and solely as the first argument to `async.send`.
- **Sending:** `send(handle, candidate)` is synchronous and needs no Task or Runtime in the sender's state (not safe in a POSIX signal handler). It encodes `candidate` (any transferable value, `thread` endpoint, or explicit `TransferValue`) via `transfer.encode_message`, atomically swaps the packet into the slot (disposing of any overwritten packet with `transfer.discard_message`), and wakes the receiver's loop. Pre-swap errors (`"receiver handle must not be NULL"`, encoding errors, `"receiver is closed"`) leave the slot unchanged and discard the encoded copy (keep a retained `TransferValue` policy when sending a manual-handoff resource so failed sends remain recoverable). Once swapped, the send has committed even if waking raises `OperationError` (`"async.send"`).
- **Waiting:** `Receiver:wait()` requires a running Task in the owning Runtime, takes the single-reader reservation first (`"receiver already has a waiting reader"` for a second concurrent caller), and eagerly decodes and returns the semantic value (`nil` and `false` arrive as ordinary data; borrowed pointers arrive as light userdata requiring an explicit `as` cast). Decode failures still consume the packet and raise. Cancelling a waiter frees the reservation immediately without closing the receiver or dropping an unread packet.
- **Closing & handle lifetime:** `Receiver:close()` is idempotent, needs no Task, disposes of any unread packet via `transfer.discard_message`, wakes a waiting Task with `"receiver is closed"`, and starts closing the native handle (drain `async.loop()` to finish close). Automatic packet disposal releases attached `thread` endpoints but never runs `from_transfer_payload` decoders for manual-handoff resources. Because `handle()` retains nothing and concurrent `send` / `close` is unsupported, keep the `Receiver` rooted and stop all senders (waiting for every in-flight `send` to return) before calling `close()` or closing the state; see the [two-phase receiver bootstrap](standard-library-lua.md#two-phase-receiver-bootstrap).

## The browser target

`async` runs on the [browser target](browser-target.md) with Tasks, cancellation, `await` / `await_cleanup`, `suspend` / `ResumeToken`, combinators, bounded channels, string streams, subscriptions, close listeners, and `request_exit`.

The native-only members are absent on the browser: `current_loop`, `await_with`, `await_cleanup_with`, `await_cancellable_with`, `await_cancellable`, `run_foreign`, `prepare_external_wait`, `prepare_native_retirement`, `wait_external`, `wait_external_cleanup`, `wait_external_native`, `version`, `Receiver`, `receiver`, and `send`. `ExternalWait` remains type-only (so `run_with_cleanup`'s `final_wait` is always `nil`), and `Completion` keeps its methods though no browser API constructs one. Initializing `async` on the browser changes no signal disposition.

### The browser driver

Titan shares the page's single event loop. Each driver turn delivers queued host settlements, listener events, notifications, and queued calls in order, runs at most 64 ready Tasks, and returns control to the host event loop for one macrotask (`MessageChannel` in browsers, `setImmediate` in Node) so page timers and rendering stay responsive. Work made ready during a turn runs in a later turn, so `async.yield()` never resumes within the same browser task; a Task that loops without yielding still blocks the page.

If every remaining Task is suspended with no pending host work, open request/listener, or open [`BrowserPin`](standard-library-browser.md#synchronous-c-callbacks), the driver stops with `"async Runtime became idle while Tasks were waiting"` and unwinds the waiting Tasks.

Tasks wait on host operations with `await`, `await_cleanup`, or `suspend` around [browser requests](standard-library-browser.md#requests-and-listeners) (pass `suspend` a cancel action that cancels the request when cancellation should end the wait early). Do not use stack-suspending Emscripten helpers (`emscripten_sleep`, `EM_ASYNC_JS`) inside Tasks, as they stall every other Task.

### Drives and entries

A drive begins inside a JavaScript entry (`run()` for `main`, `call()` invoking `async.loop()`, or `callTask(callable, args)` — see [the loader API](browser-target.md#the-loader-api)) and ends when all Tasks finish. Calls arriving while a drive is active queue between turns and execute outside any Task (calling `async.loop()` there raises `"async.loop is already being driven"`).

### Ownership

Only the browser instance's owner Lua state drives `async`. Calling `async.loop()` in another state raises `"async.loop must be driven by the browser instance's owner state"`, and starting a Task there raises `"async Runtime is unavailable in a non-owner browser state"`.

### Synchronous callbacks

A [synchronous C callback](standard-library-browser.md#synchronous-c-callbacks) runs outside every Task, even when invoked inside a binding called by a Task. `async.running()`, `await`, `yield`, and `suspend` raise `"asynchronous operation must be called from an async Task"` while a Runtime is active (or `"async Runtime is not active"` otherwise). Operations triggered from a synchronous callback (`Completion` settlement, `Task:resume`, `Task:cancel`, subscription publish, `async.run`) take effect on a later driver turn and wake an idle drive. Reporting `fatal` inside a binding invoked by a Task raises `"async fatal callback must run outside an async Task"`; callbacks invoked while no Task is running may report `fatal` normally.

### Exit and disposal

`request_exit(code)` latches the first exit status, cancels all Tasks with `"program exit"`, runs cleanup awaits, and marks the browser instance exited once the drive completes (subsequent entries reject with `TITAN_BROWSER_EXITED` without closing the page or Node process).

`dispose()` with an active Runtime cancels every unfinished Task with `"instance disposed"` and drives their cleanup before closing the state. Cleanup may await already-started host work, while starting new host requests or listeners raises `browser.BrowserError` with `"browser state is closing"` ([disposal with a running Runtime](browser-target.md#disposal-with-a-running-runtime)).
