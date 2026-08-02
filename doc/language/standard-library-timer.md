# Timer standard library

The `timer` standard module provides Task-friendly delays and recurring
timers. Titan imports the canonical module with `import "timer"`; Lua uses
`require "titan.timer"`.

```titan
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

`yield()` is equivalent to a zero-duration Task delay. It is cooperative
scheduling, not a Lua coroutine yield.

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

A session also closes any Ticker that application code leaves open once no
live Task remains.
