# Asynchronous I/O and tasks

Titan's asynchronous standard library is built around the `uv` module. Titan
code imports it with:

```titan
local uv = import "uv"
```

Lua code loads the same canonical module image with
`require "titan.uv"`. The qualified Lua name avoids collisions with Lua
libraries. The module currently supports Linux and macOS.

## Scheduling and driving tasks

```titan
record Task
function run(func: () -> value): Task
function loop()
function Task:join(): value
function Task:cancel(reason: value)
function Task:status(): string
function version(): string
```

`uv.run(func)` creates and roots a Task, registers its first zero-duration
libuv timer, and returns. It does not call `func` before returning. The next
event-loop callback starts the Task.

A standalone Titan program that transitively imports an asynchronous module
needs no wrapper around `main`. Import initialization installs a private
bootstrap hook; the generated entrypoint schedules `main` as the main Task
and drives the private event loop. Synchronous programs retain the ordinary
direct `main` path.

A Lua host schedules work explicitly and then calls `uv.loop()`:

```lua
local uv = require "titan.uv"
local timer = require "titan.timer"

local task = uv.run(function()
    timer.sleep(10)
    return "done"
end)

assert(task:status() == "ready")
uv.loop()
assert(task:join() == "done")
```

`uv.loop()` may run only on the Lua main thread and never from inside a UV
Task or an active loop callback. Calling `uv.run` from a Task is valid: it
schedules an independent Task and returns without running it inline. After a
session closes all native owners, a later `run`/`loop` pair creates a new
private loop.

## Callback execution model

The runtime deliberately follows libuv's callback model. A native libuv
callback directly invokes the trusted Titan dispatcher through its native
Titan entry. The dispatcher resumes the Task, and application code runs
synchronously inside that callback until it:

- finishes;
- raises; or
- starts another asynchronous operation and yields its private request.

When a Task yields a request, the dispatcher registers the next libuv callback
and returns to libuv. That later callback resumes the same continuation. There
is no extra Lua entry wrapper, protected C call, ready queue, or implicit
fairness turn on this path. `timer.yield()` is the explicit way to cede one
event-loop turn. CPU-heavy code that never performs an asynchronous operation
blocks the loop just as CPU-heavy code in a conventional callback would.

All UV Tasks in one Lua state use one private coroutine tag. A UV yield can
therefore cross nested Titan coroutines that use other tags and return control
to the UV scheduler.

## Results, errors, and cancellation

A Task reports `"new"`, `"ready"`, `"running"`, `"waiting"`,
`"succeeded"`, `"failed"`, or `"cancelled"`. A completed Task retains its
immutable result or error, so `status` and an already-resolved `join` remain
usable after the loop closes. A live or pending Task cannot be joined from a
different Runtime generation.

`join()` waits when called from another live UV Task. It returns the target's
dynamic `value` result, or raises the target's original error while appending
the join-site propagation traceback. Joining oneself raises.

Libuv failures are represented by:

```titan
record Error
  code: integer
  name: string
  message: string
  operation: string
  subject: string?
end
```

Unobserved failed Tasks become session-fatal on the next event-loop turn,
giving an already-scheduled joiner an opportunity to observe the failure.
Cancellation is represented by `uv.Cancelled`, whose `reason` is the exact
first value passed to `cancel`. Cancellation is sticky: catching it and
attempting another ordinary asynchronous wait injects the same cancellation
again. An unobserved cancelled non-main Task is not session-fatal; cancellation
of the main Task is reported.

Resource cleanup is physically completed even after logical cancellation.
The runtime closes and drains every remaining owner before
`uv_loop_close`; it does not let a Lua-GC finalizer free an initialized
libuv handle.
