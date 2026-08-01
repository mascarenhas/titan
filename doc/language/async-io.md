# Asynchronous I/O and tasks

Titan's public asynchronous scheduling API is the `async` module. Titan code
imports it with:

```titan
local async = import "async"
```

Lua code loads the same canonical module identity with
`require "titan.async"`. The qualified Lua name avoids collisions with Lua
libraries. The module currently supports Linux and macOS. Its implementation
forwards scheduling to the private `titan.uv` plumbing/provider module; user
code should import `async`, not `uv`.

On Unix, loading the module changes a default `SIGPIPE` disposition to ignored
so a closed stream produces an `async.Error` instead of terminating the
process.
An inherited ignored disposition or application-installed handler is left
unchanged. Embedders must serialize module initialization with their own
process-wide signal-handler changes.

## Scheduling and driving tasks

The facade re-exports `Task`, `Error`, and `Cancelled` as transparent,
type-only aliases of the nominal records owned by the private provider. Titan
code can therefore write `async.Task` in an annotation and call methods on a
value of that type, but neither Titan expressions nor Lua see runtime members
named `async.Task`, `async.Error`, or `async.Cancelled`. The callable interface
is:

```titan
function run(func: () -> value): Task
function loop()
function yield()
function Task:join(): value
function Task:cancel(reason: value)
function Task:status(): string
function version(): string
```

`async.run(func)` creates and roots a Task, registers its first zero-duration
libuv timer, and returns. It does not call `func` before returning. The next
event-loop callback starts the Task.

A standalone Titan program that transitively imports an asynchronous module
needs no wrapper around `main`. Import initialization installs a private
bootstrap hook; the generated entrypoint schedules `main` as the main Task
and drives the private event loop. Synchronous programs retain the ordinary
direct `main` path.

A Lua host schedules work explicitly and then calls `async.loop()`:

```lua
local async = require "titan.async"
local timer = require "titan.timer"

local task = async.run(function()
    timer.sleep(10)
    return "done"
end)

assert(task:status() == "ready")
async.loop()
assert(task:join() == "done")
```

`async.loop()` may run only on the Lua main thread and never from inside an
async Task or an active loop callback. Calling `async.run` from a Task is
valid: it schedules an independent Task and returns without running it inline.
After a session closes all native owners, a later `run`/`loop` pair creates a
new private loop.

`async.yield()` cedes one event-loop turn without waiting for an external
resource. It is the general scheduler-fairness primitive; `timer.yield()` is a
compatibility facade over the same private operation. Calling it outside a
running Task raises just like every other Task suspension operation.

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
event-loop turn; `async.yield()` is its general-purpose home. CPU-heavy code
that never performs an asynchronous operation
blocks the loop just as CPU-heavy code in a conventional callback would.

Stream reads use this direct handoff without a ready queue: a positive read
callback clears the current waiter and resumes its yielded call with the binary
payload, while EOF resumes it with `nil` and an error is raised in that Task.
The resumed continuation may install the next waiter before the callback
returns. Callbacks that wake a different Task because another Task explicitly
closed a stream use the scheduled-drive path instead of nesting a second Task
drive.

All async Tasks in one Lua state use one private coroutine tag. An async yield
can therefore cross nested Titan coroutines that use other tags and return
control to the async scheduler.

## Results, errors, and cancellation

A Task reports `"new"`, `"ready"`, `"running"`, `"waiting"`,
`"succeeded"`, `"failed"`, or `"cancelled"`. A completed Task retains its
immutable result or error, so `status` and an already-resolved `join` remain
usable after the loop closes. A live or pending Task cannot be joined from a
different Runtime generation.

`join()` waits when called from another live async Task. It returns the target's
dynamic `value` result, or raises the target's original error while appending
the join-site propagation traceback. Joining oneself raises.

Libuv failures are represented by the provider-owned record re-exported under
the type-only name `async.Error`. Its fields are `code: integer`,
`name: string`, `message: string`, `operation: string`, and
`subject: string?`. The alias preserves the provider record's identity; it is
not a second constructible record namespace.

Unobserved failed Tasks become session-fatal on the next event-loop turn,
giving an already-scheduled joiner an opportunity to observe the failure.
Cancellation is represented by the type-only `async.Cancelled` alias, whose
`reason` field is the exact
first value passed to `cancel`. Cancellation is sticky: catching it and
attempting another ordinary asynchronous wait injects the same cancellation
again. An unobserved cancelled non-main Task is not session-fatal; cancellation
of the main Task is reported.

Resource cleanup is physically completed even after logical cancellation.
The runtime closes and drains every remaining request/handle owner before
`uv_loop_close`; it does not let a Lua-GC finalizer reclaim native storage
before its terminal callback and cleanup. A descriptor-close callback is
terminal even when it reports an error: the wrapper reaches its closed state,
the callback cleanup finishes, and the error is reported once. Titan does not
retry a native descriptor close whose result is uncertain, because the
operating system may already have reused that descriptor number.

Filesystem cancellation distinguishes logical delivery from physical native
lifetime. Cancelling a queued File operation removes it from that File's FIFO.
A submitted request remains rooted through its callback even if `uv_cancel`
cannot stop it in time, and its stale result is not delivered. File close is
cleanup-shielded so cancellation is reinjected only after the terminal close
callback and request cleanup. Repeated close calls remain safe after either a
successful or an error-reporting terminal callback.

Networking uses the same separation. A queued write can be removed, while
cancelling an active write is logical: its native callback still owns cleanup
and cannot deliver the stale result. The first `Connection:shutdown()` is
cleanup-shielded through its `uv_shutdown` callback; repeated calls are
idempotent. Connected and accepted streams start reading during initialization
and retain GC-owned chunks continuously, even without a waiter. Cancelling a
read detaches only that waiter and leaves the physical read active; explicit
close stops the read side, discards retained and queued input, wakes a blocking
reader with `nil`, rejects new output, and serializes the native handle close
behind already submitted and queued FIFO output. Later reads remain at EOF.

Child-process stdio follows the same callback-ownership rule without treating
an anonymous pipe like a socket. `os.spawn` applies its configurators in order;
each prepares and validates a reusable native candidate, and the final
configuration supplies the child streams. An inherited descriptor therefore
has no newly created parent-facing Process endpoint and appears as `nil`, while
the borrowed parent pipe or TTY remains owned by the current Runtime. Captured
stdin writes use the ordinary FIFO: cancelling a queued write removes it, while
a submitted write remains rooted through its callback. Closing captured stdin
is cleanup-shielded behind earlier writes and uses the pipe's `uv_close`
callback, not `uv_shutdown`.

Cancelling a process wait only frees that waiter: it does not signal the child,
and another Task can wait for the retained exit status. Each separately
captured output starts continuous reads after successful spawn and has its own
reader lock and queue. Merged stdout/stderr instead has one native owner and
the exact same high-level InputStream in both Process fields, so it also has
one queue and reader lock. Cancelling any output read detaches only its waiter
while physical reading continues. Explicitly closing a captured InputStream
stops that pipe, discards its retained and queued input, wakes its reader with
`nil`, and leaves the child lifecycle under `Process` control.

Parent stdin, stdout, and stderr have independent borrowed controls owned by
the current Runtime. The stable `os.stdin`, `os.stdout`, and `os.stderr`
records resolve those controls lazily and rebind across sequential Runtime
generations. Closing one of these stable parent facades is an idempotent no-op:
it closes neither the Runtime's wrapper nor the host descriptor. A child that
inherits a descriptor likewise cannot close the parent's owner.

`io.popen` builds on the same process machinery with `/bin/sh -c`, captured
stdin, and one merged output stream. Its `InputOutputStream` stores one output
facade and an idempotent wait result. Closing it closes stdin, conditionally
requests `term`, and waits for reaping. Applications still schedule input and
output concurrently for large bidirectional traffic; the convenience does not
make operating-system pipe capacity unbounded.

If a Runtime closes with a live child, it sends `term`, waits up to five
seconds, then sends `kill`. The loop still waits for the real exit and close
callbacks, so shutdown does not leave a zombie or let process/pipe storage be
collected early.

`os.exit(code)` enters a distinct successful exit-request state from either
the main Task or a child Task. It settles the other Tasks, runs their language
cleanup, drains all native owners through the same shutdown path, and lets the
generated standalone entrypoint return the requested status. It is not an
unobserved Task failure and does not call ISO C `exit` around the Runtime. In
an embedding it never closes the host Lua state.

See the [filesystem standard library](standard-library-fs.md) and
[TCP networking standard library](standard-library-net.md) for their public
I/O APIs. The [operating-system standard library](standard-library-os.md)
documents portable synchronous helpers, one-shot signal waits, parent stdio,
configurable child-process streams, exit status, and graceful program exit.
The [I/O standard library](standard-library-io.md) documents `print`, line
iteration, and shell-command `popen` on the same Runtime.
