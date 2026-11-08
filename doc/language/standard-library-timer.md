# Timer standard library

The `timer` standard module provides Task-friendly delays and recurring
timers. Titan imports the canonical module with `import "timer"`; Lua uses
`require "titan.timer"`.

```text
function sleep(milliseconds: integer)
function yield()

record Ticker
function ticker(milliseconds: integer): Ticker
function Ticker:tick(): boolean
function Ticker:close()
```

`Ticker` incidentally satisfies the exact
[`io.Closer`](standard-library-io.md#standard-implementations) Interface.

These functions must be called from a running
[`async.Task`](async-io.md#scheduling-and-driving-tasks).

## One-shot delays

`sleep(milliseconds)` waits at least until the corresponding one-shot libuv
timer fires. Negative durations raise. `sleep(0)` is valid and yields until a
callback on a later event-loop turn.

Pending cancellation is checked before validating the duration. Cancellation
of an accepted sleep wakes its Task and closes that sleep's native timer;
normal return and cancellation unwind both wait for native close completion.
Sleep does not expose a shared Ticker or leave a recurring producer behind.

`yield()` is the same cooperative scheduling point as `async.yield()`: it
appends the Task to the Runtime's bounded FIFO ready queue. It has no promised
delay or exact libuv phase. Use `sleep` for an actual duration.

```titan
local timer = import "timer"

function main(args: {string}): integer
  timer.sleep(25)
  timer.yield()
  return 0
end
```

The async bootstrap is installed transitively through `timer`, so this
standalone program does not need to import `async` explicitly.

## Recurring tickers

`ticker(milliseconds)` requires a strictly positive interval and returns an
opaque `Ticker`; callers cannot construct, forge, or extract its native timer.

`tick()` waits for the next firing and returns `true`. Only one Task may
wait on a Ticker at a time. A firing with no waiter records one pending tick;
later firings replace that same pending state rather than accumulating a
count. The next `tick()` consumes it immediately, so several missed intervals
coalesce into one result.

`close()` is idempotent. It stops and closes the native timer, wakes a current
waiter with `false`, and makes every later `tick()` return `false`.

```titan
local timer = import "timer"

function four_ticks(): integer
  local ticker = timer.ticker(100)
  local count = 0
  for i = 1, 4 do
    if ticker:tick() then count = count + 1 end
  end
  ticker:close()
  return count
end
```

Cancelling a Task waiting in `tick()` detaches that waiter; it does not close
the shared Ticker. A later Task can wait on it. The one-reader reservation stays
held until a queued tick is delivered, so a second overlapping waiter is still
rejected during that interval. Close uses cancellation-insensitive cleanup for
the native handle; it remains usable from a cancelled Task's cleanup.

A live Ticker belongs to the Runtime that created it. It cannot be used for
native work in another Runtime. A session closes any Ticker that application
code leaves open once no live Task remains.

## On the browser

`timer` is part of the
[browser standard library](browser-target.md#the-browser-standard-library),
with the same functions and contract. It runs on JavaScript timers that the
SDK owns instead of libuv, so their timing is the browser's:

- `sleep(milliseconds)` arms one `setTimeout` and resumes the Task when it
  fires. The delay is at least the requested time, subject to the browser's
  clamping and throttling: timers in a background tab can fire much later.
  Cancelling an accepted sleep clears its JavaScript timer at once.
- A negative duration raises the same `OperationError`, with name `"EINVAL"`
  and operation `"timer.sleep"`; its `code` is the browser's negated `EINVAL`.
- `sleep(0)` and `yield()` arm no JavaScript timer. The Task resumes in a
  later turn of the [browser driver](async-io.md#the-browser-target), after
  the driver gives the event loop one macrotask, so never in the same browser
  task. This also avoids the 4 ms minimum that nested `setTimeout` calls get.
- A Ticker runs on `setInterval`. Missed or throttled intervals coalesce into
  one pending tick, as above.
- A Ticker left open closes when its Runtime closes, after the last Task
  finishes, and later `tick()` calls return `false`.
- Disposing the instance cancels every Task with `"instance disposed"`, so a
  sleep in a Task's cleanup raises that cancellation, as natively. No new
  JavaScript timer starts after `dispose()`.
