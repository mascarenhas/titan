# Asynchronous I/O and tasks

Titan's public asynchronous scheduling API is the `async` module. Titan code
imports it with `local async = import "async"`; Lua uses
`require "titan.async"`. The module supports Linux and macOS. Its private
`titan.uv` provider adapts libuv callbacks to Titan coroutines; application
code should import the public `async`, `timer`, `fs`, `net`, `io`, and `os`
modules instead of `uv`.

On Unix, loading the provider changes a default `SIGPIPE` disposition to
ignored so a closed stream produces an `async.Error` instead of terminating
the process. An inherited ignored disposition or application-installed
handler is preserved.

## Scheduling and driving Tasks

The facade re-exports `Task`, `Error`, and `Cancelled` as transparent,
type-only aliases of records owned by the private provider:

```titan
function run(func: () -> value): Task
function loop()
function yield()
function version(): string

function Task:cancel(reason: value)
function Task:status(): string
```

`async.run(func)` creates and roots a Task, registers a zero-duration libuv
timer, and returns without calling `func`. The timer callback starts the Task
on a later event-loop turn. Calling `run` from another Task is valid and still
does not run the new Task inline.

This initial direct-continuation runtime deliberately has no Task `join`
operation. Coordinate Tasks through the resources and shared state owned by
the application. A Task reports `"ready"`, `"running"`, `"waiting"`,
`"succeeded"`, `"failed"`, or `"cancelled"` through `status()`.

A Lua host drives scheduled work explicitly:

```lua
local async = require "titan.async"
local timer = require "titan.timer"

local result
local task = async.run(function()
    timer.sleep(10)
    result = "done"
end)

assert(task:status() == "ready")
async.loop()
assert(task:status() == "succeeded")
assert(result == "done")
```

A standalone Titan program that transitively imports an asynchronous module
needs no wrapper around `main`. Module initialization installs a private
bootstrap hook; the generated entrypoint schedules `main` as a Task and drives
the loop. The Runtime remains alive until every Task has finished, even if
`main` finishes first.

`async.yield()` cedes one event-loop turn without waiting for an external
resource. `timer.yield()` is a facade over the same operation. Calling either
outside a Task raises.

## The callback/continuation model

There is one non-reentrant event-loop driver. Only top-level `async.loop()` or
the standalone bootstrap calls `uv_run`, and it does so from the Lua main
thread. Libuv explicitly forbids calling `uv_run` from a callback; therefore
no Task continuation, callback handler, or private dispatcher drives the loop.

Every asynchronous turn has the same shape:

1. libuv invokes an operation's callback;
2. the callback handler resumes the suspended Task with that operation's
   result, or raises its error at the suspension point;
3. the Task runs synchronously until it returns, raises, or calls another
   asynchronous operation;
4. that operation yields a private tagged union variant whose record contains
   the corresponding libuv call parameters;
5. the callback handler invokes that record's dispatcher, which performs any
   synchronous preparation, submits the next callback-taking libuv function,
   and returns; and
6. the callback handler returns to libuv.

The next progress comes from a later loop turn. The sole exception is a
negative synchronous submission result: libuv guarantees that no callback
will follow, so the dispatcher immediately raises that error back into the
same continuation before returning.

This is the logical equivalence at the center of the design: a coroutine
yield/resume pair is a direct-style spelling of a callback whose body is the
suspended coroutine's continuation. There is no ready queue and no central
scheduler state machine. CPU-heavy Titan code that neither finishes nor
yields blocks the loop just like CPU-heavy code in an ordinary callback.

One-shot requests each own their native request, one suspended Task, and only
the arguments libuv still borrows until the terminal callback. Multiple stream
writes retain their original Titan strings and submit multiple `uv_write_t`
requests; libuv supplies their native ordering. Titan does not duplicate that
queue or copy the payload into another string.

Repeating timers, stream reads, listeners, and other multi-shot handles keep
only their natural buffered state plus at most one waiter. A stream callback
appends data when there is no reader; a ticker remembers that at least one tick
occurred. A callback clears its waiter before resuming it, so the continuation
may install the next waiter before that callback returns.

Allocation callbacks and `uv_walk` callbacks are direct plumbing callbacks,
not coroutine-shaped calls. They update the owning record and return
immediately. Because an allocation callback cannot unwind through libuv, an
allocation exception is preserved for its required paired read callback,
which raises it at the Task boundary (or logs it when no Task is waiting).

## Errors and cancellation

Libuv failures use the provider-owned `async.Error` record:

```titan
record Error
  code: integer
  name: string
  message: string
  operation: string
  subject: string?
end
```

`operation` identifies the failed libuv-facing action. `subject` is optional
diagnostic context; callers must not depend on a particular operation
populating it.

An uncaught error terminates only the Task that raised it. The Runtime writes
the error and its preserved Titan traceback to standard error, marks that Task
`"failed"`, and returns to libuv. Other Tasks continue to run. A Task failure
does not request program shutdown; ordinary shutdown begins only after no
active Tasks remain.

`cancel(reason)` is sticky and preserves the first reason in an
`async.Cancelled` record. An accepted one-shot request and its buffer storage
remain alive and continue to their promised callback; that callback settles
the cancelled continuation. Watchers whose event callback can be suppressed
are stopped and closed, and their close callback performs the same job.
Catching cancellation does not make later asynchronous waits uncancelled: the
same cancellation is injected again at the next suspension boundary.

## Resources and shutdown

Explicit resource close remains preferable: it reports errors at the relevant
call site and releases native resources early. Close is idempotent at the
public facades. A second concurrent waiter for a one-reader resource is
rejected instead of creating a queue.

When the last Task finishes, the Runtime rejects creation of new handles and
starts a private cleanup Task. It calls `uv_walk` to discover the loop's
handles and closes each non-closing handle through the ordinary asynchronous
`uv_close` callback path while the one outer event loop continues to run. A
final `uv_loop_close` success is the proof that requests and handles were
drained.

A child-process watcher is an ordinary libuv handle during this traversal.
Closing it retires the watcher; it does not signal, wait for, or reap the
child, which may outlive the Runtime. Application code that owns a child's
lifecycle must explicitly call `Process:kill` and/or `Process:wait` as needed
before its Tasks finish.

A `uv_file` is an operating-system descriptor, not a libuv loop handle. The
Runtime neither registers nor closes File wrappers during shutdown: application
code owns explicit `File:close()`, and process teardown reclaims a descriptor
that was deliberately left open.

The Runtime keeps a sparse Task inventory and a sparse live-owner set for the
C-to-Titan callback bridge. The former determines when the last Task has
finished and lets `os.exit` cancel other Tasks; the latter exists only for GC
reachability and is never traversed. Neither is a parallel libuv-resource
list, scheduling queue, or source of shutdown traversal; libuv remains
authoritative for its handle set.

`os.exit(code)` requests successful program exit, cancels the remaining Tasks,
runs the same cleanup path, and lets the generated entrypoint return the
requested status. It does not call ISO C `exit` around an embedding's Lua
state.

See the [timer](standard-library-timer.md),
[filesystem](standard-library-fs.md), [network](standard-library-net.md),
[operating-system](standard-library-os.md), and
[I/O](standard-library-io.md) chapters for their public APIs.
