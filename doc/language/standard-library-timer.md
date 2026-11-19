# Timer standard library

The `timer` module provides cooperative delays and recurring intervals for [`async.Task`](async-io.md#scheduling-and-driving-tasks) code. Import it in Titan with `local timer = import "timer"` or load it in Lua with `require "titan.timer"`.

**Target availability:** Native & Browser (full API on both targets; browser timing uses JavaScript timers — see [On the browser](#on-the-browser)).

## Example

The program below runs a recurring `Ticker` alongside a delayed worker Task that closes the ticker after 50 ms. Because `timer` imports `async`, a standalone executable automatically runs `main` inside a root Task and drives the event loop.

```titan
local async = import "async"
local io = import "io"
local timer = import "timer"

function main(args: {string}): integer
  local ticker = timer.ticker(15)
  defer ticker:close()

  local stopper = async.run(function (): nil
    timer.sleep(50)
    ticker:close()
    return nil
  end)

  local ticks = 0
  while ticker:tick() do
    ticks = ticks + 1
  end

  async.join(stopper)
  io.print("ticks before stop: " .. ticks)
  return 0
end
```

## Core concepts

Every function and method in `timer` must be called from a running `async.Task`. Calling them outside a Task raises.

A `Ticker` belongs to the `async` Runtime that created it and satisfies the [`io.Closer`](standard-library-io.md#standard-implementations) Interface. Pair `timer.ticker(...)` immediately with `defer ticker:close()` so the underlying timer stops when the owning scope exits.

## One-shot delays

```text
function sleep(milliseconds: integer)
function yield()
```

`sleep(milliseconds)` suspends the current Task until at least `milliseconds` have elapsed. Passing a negative duration raises an `async.OperationError` (with `name == "EINVAL"` and `operation == "timer.sleep"`). `sleep(0)` is valid and yields until a callback on a later event-loop turn.

Pending Task cancellation is checked before validating the duration. Cancelling a Task waiting in `sleep` stops and closes its native timer, and both normal return and cancellation wait for the native close to finish.

`yield()` appends the current Task to the Runtime's bounded FIFO ready queue without setting a duration, behaving identically to `async.yield()`. Use `sleep` when you need a real delay.

```titan
local timer = import "timer"

function pause_and_yield()
  timer.sleep(10)
  timer.yield()
end
```

## Recurring tickers

```text
record Ticker
function ticker(milliseconds: integer): Ticker
function Ticker:tick(): boolean
function Ticker:close()
```

`ticker(milliseconds)` creates an opaque `Ticker` that fires at a fixed period. `milliseconds` must be strictly positive (`> 0`); zero or negative intervals raise.

- **`Ticker:tick()`** suspends until the next interval fires and returns `true`, or returns `false` once the ticker is closed. At most one Task may wait on a `Ticker` at a time; a second overlapping waiter raises, including while a queued tick is still being delivered to the first waiter. If one or more intervals fire while no Task is waiting, they coalesce into a single pending tick that the next `tick()` consumes immediately.
- **Cancellation:** Cancelling a Task waiting in `tick()` detaches that waiter without closing the `Ticker`, allowing another Task to wait on it later.
- **`Ticker:close()`** is idempotent. It stops and closes the native timer using cancellation-insensitive cleanup (so it is safe inside a cancelled Task's `defer`), wakes any waiting Task with `false`, and makes all subsequent `tick()` calls return `false`.

A live `Ticker` belongs to its creating Runtime and cannot be used from another Runtime. When a Runtime drains after its last Task finishes, any `Ticker` left open is closed automatically.

## On the browser

`timer` is part of the [browser standard library](browser-target.md#the-browser-standard-library) with the same API and semantics, backed by JavaScript timers owned by the browser SDK:

- **`sleep(milliseconds)`** waits at least the requested duration, subject to browser timer clamping and background-tab throttling. Because JavaScript timers cap single delays at 2,147,483,647 ms (about 24.8 days), longer delays chain multiple timers automatically. Cancelling an active sleep clears its JavaScript timer immediately.
- **Negative durations** raise `async.OperationError` with `name == "EINVAL"`, `operation == "timer.sleep"`, and the browser target's negated `EINVAL` `code`.
- **`sleep(0)` and `yield()`** do not schedule a JavaScript `setTimeout`; instead, the Task resumes on a later turn of the [browser driver](async-io.md#the-browser-target) after one macrotask, avoiding the 4 ms clamping applied to nested `setTimeout` calls.
- **`Ticker`** uses `setInterval` for periods up to 2,147,483,647 ms and chains one-shot timers for longer periods, preserving missed-interval coalescing. Open tickers close automatically when the Runtime finishes, after which `tick()` returns `false`.
- **Instance disposal:** Calling `dispose()` cancels every Task with `"instance disposed"`, causing a `sleep` inside Task cleanup to raise that cancellation. No new JavaScript timer starts after `dispose()`.
