# Asynchronous I/O and tasks

Titan's asynchronous standard library is built around the `uv` module. Titan
code imports it with:

```titan
local uv = import "uv"
```

Lua code loads the same canonical module identity with
`require "titan.uv"`. The qualified Lua name avoids collisions with Lua
libraries. The module currently supports Linux and macOS.

On Unix, loading the module changes a default `SIGPIPE` disposition to ignored
so a closed stream produces a `uv.Error` instead of terminating the process.
An inherited ignored disposition or application-installed handler is left
unchanged. Embedders must serialize module initialization with their own
process-wide signal-handler changes.

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

Stream reads use this direct handoff without a ready queue: a positive read
callback clears the current waiter and resumes its yielded call with the binary
payload, while EOF resumes it with `nil` and an error is raised in that Task.
The resumed continuation may install the next waiter before the callback
returns. Callbacks that wake a different Task because another Task explicitly
closed a stream use the scheduled-drive path instead of nesting a second Task
drive.

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
The runtime closes and drains every remaining request/handle owner before
`uv_loop_close`; it does not let a Lua-GC finalizer reclaim native storage
before its terminal callback and cleanup. Persistent descriptor-close failure
is the bounded exception: after retry exhaustion the idle loop is closed, the
failed File and terminal Runtime remain rooted, and the saved error is reported
instead of retrying forever or claiming that the descriptor closed.

Filesystem cancellation distinguishes logical delivery from physical native
lifetime. Cancelling a queued File operation removes it from that File's FIFO.
A submitted request remains rooted through its callback even if `uv_cancel`
cannot stop it in time, and its stale result is not delivered. File close is
cleanup-shielded so cancellation is reinjected only after physical close.

Networking uses the same separation. A queued write can be removed, while
cancelling an active write is logical: its native callback still owns cleanup
and cannot deliver the stale result. The first `Connection:shutdown()` is
cleanup-shielded through its `uv_shutdown` callback; repeated calls are
idempotent. Connected and accepted streams start reading during initialization
and retain GC-owned chunks continuously, even without a waiter. Cancelling a
read detaches only that waiter and leaves the physical read active; explicit
close stops the read side, rejects new output or blocking read waits, and
serializes the native handle close behind already submitted and queued FIFO
output. Already completed read chunks remain drainable before closed-stream
state is reported.

Child-process stdio follows the same callback-ownership rule without treating
an anonymous pipe like a socket. Cancelling a queued stdin write removes it;
a submitted write remains rooted through its callback. `Process:close_stdin()`
is a cleanup-shielded FIFO close behind earlier writes and uses the pipe's
`uv_close` callback, not `uv_shutdown`. Cancelling a process wait only frees
that waiter: it does not signal the child, and another Task can wait for the
retained exit status. Stdout and stderr begin continuous reads after successful
spawn, use independent reader locks and queues, and likewise detach only a
cancelled waiter while continuing to drain the pipe.

`os.communicate` owns four pre-observed helper Tasks for stdin, stdout, stderr,
and exit. They run concurrently, so large bidirectional traffic cannot
deadlock because one pipe filled before another was drained. On a helper error
or parent cancellation, the runtime keeps the original error, cancels the
other helpers, terminates and reaps the child, drains every native callback,
and only then reports the error.

If a Runtime closes with a live child, it sends `term`, waits up to five
seconds, then sends `kill`. The loop still waits for the real exit and close
callbacks, so shutdown does not leave a zombie or let process/pipe storage be
collected early.

See the [filesystem standard library](standard-library-fs.md) and
[TCP networking standard library](standard-library-net.md) for their public
I/O APIs. The [operating-system standard library](standard-library-os.md)
documents portable synchronous helpers, one-shot signal waits, child-process
stdio, exit status, and `communicate` built on the same Runtime.
