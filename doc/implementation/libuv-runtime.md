# The libuv continuation runtime

The private `titan.uv` folder module implements Titan's asynchronous standard
library on libuv. It is not a second scheduler layered over libuv. Its only
job is to translate between two equivalent control-flow spellings:

```text
submit operation(callback)
```

and:

```text
result = yield operation parameters
-- callback resumes here with callback parameters
```

The public `async`, `timer`, `fs`, `net`, `io`, and `os` modules expose
ordinary Titan records and Interfaces. Native pointers, callback records, the
yield union, and libuv controls stay private to `titan.uv`.

Contributor recipes for adding single-shot callbacks, persistent multi-shot
sources, and new handle types, together with the current binding-coverage
snapshot, are in [Extending the libuv binding](libuv-extension-guide.md).

## The non-reentrant loop invariant

Libuv specifies that `uv_run` is not reentrant and must not be called from a
callback. Titan uses that rule as the central invariant of the implementation:

- only top-level `async.loop()` or the generated standalone bootstrap calls
  `uv_run`;
- that call runs on the Lua main thread;
- no callback handler, resumed Task, or operation dispatcher calls `uv_run`;
- a Titan continuation runs to its next yield/return/error without another
  libuv callback interrupting it; and
- accepted work progresses only after the current callback returns to libuv.

Filesystem and DNS work may execute in libuv's worker pool, but their
completion callbacks still return on the loop thread. Titan records are never
accessed from those workers.

## Coroutine protocol

All Tasks are Titan `coroutine.Coro` values with one private module-identity
tag. A Task-to-runtime transfer is a local `Call` union. Every variant
represents one suspension action and carries one local record containing its
ordinary parameters. A one-shot variant normally submits one callback-taking
call. A persistent source may already be active, so its wait variant instead
consumes buffered state or installs one waiter. A callback-to-Task transfer is
the operation's result value, or an injected `async.Error`; only operations
with several result components need a private result record.

The union is intentionally only a router. Each payload record implements its
own private `dispatch(task)` method. The callback continuation trampoline does:

```text
resume Task with callback result
if Task returned: finish that Task
if Task raised: report and finish that Task
if Task yielded Call.variant(record): record:dispatch(Task)
return from callback
```

For a one-shot operation, its dispatcher may perform direct synchronous libuv
calls before it submits the callback-taking call. After an accepted submission
it returns immediately. A documented negative submission result is special
because the callback will not run; the trampoline injects the error immediately
and lets the continuation yield its next call without recursive event-loop
entry. A persistent-source dispatcher may instead consume buffered state or
install one waiter without making a new native submission.

`async.run` itself is primed by a zero-duration, non-repeating `uv_timer_t`.
The timer callback resumes the new Task for the first time. `async.yield` uses
the same kind of timer for an explicit later turn.

There is no ready queue, scheduler pass, operation generation, or implicit
fairness turn. Application code is the body of the current libuv callback.

## Native callback bridge

Titan functions and closures cannot be converted to C callback pointers. The
small `titan-runtime/titan_uv.c` bridge therefore provides one plain-C
trampoline per libuv callback shape: timer, close, filesystem, DNS, connect,
write, shutdown, alloc/read, connection, signal, process exit, and walk.

Each callback owner is the smallest record needed to hide its unexportable FFI
storage and keep the callback's Titan values reachable. A one-shot request
contains its native request and callback; that callback closure captures the
suspended Task and any arguments libuv still borrows. A multi-shot handle
additionally retains only its natural buffered state and at most one waiter.
There is no common control record wrapped around these operation-specific
owners.

The `titan.uv` initializer captures the stable Lua main-thread `lua_State *`
once in a private module variable. Each new Runtime stores that pointer in its
sole `uv_loop_t` with
`uv_loop_set_data`; the bridge recovers it with `uv_loop_get_data`. A common C
helper extracts that state plus the stored callback closure, its module, and
its native Titan entry. The exact closure is passed as Titan's hidden `_fn`
argument so captured callback values retain their ordinary generated-function
ABI. Before entry, the helper also pushes the owner on that main-thread stack.
This temporary root is necessary because a terminal handler can remove the
owner from its Runtime live set while the generated callback is still using
it. Each trampoline restores the saved stack top after its exact callback
returns. The helper does not dispatch. Each libuv-shaped C callback selects
the handler for its own callback shape, casts the corresponding exact Titan
signature, and calls it with only that callback's parameters. There is no
event-kind tag or generic callback payload at this boundary, and the manuals
do not make the owners' private record layouts part of the design contract.

The Task-resume boundary catches errors raised by a user continuation and
retires only that Task. Operation callbacks use ordinary `catch`/`finally`
where a native result must first be released. A user-Task callback failure
therefore does not become a Runtime-wide failure. The outer loop's final
`uv_loop_close` remains the native cleanup proof.

The alloc and walk callbacks are direct. An alloc callback fills the supplied
`uv_buf_t` from storage on the stream owner. It cannot unwind a Titan
allocation exception through libuv, and a continuously drained stream may not
have a waiter at that instant. On allocation failure it therefore returns the
zero buffer that requires the paired `read_cb`, preserving the original
exception on the owner. That read boundary raises it into the waiter, or logs
it and terminalizes the unwaited stream. This is exception transport through
libuv's ordinary alloc/read pairing, not a fallback status, recovery path, or
guard against a read callback without its alloc callback.

During cleanup, each synchronous `uv_walk` selects at most one currently
non-closing `uv_handle_t *`; the Task submits that close immediately and walks
again only after `close_cb`. A raw handle pointer is therefore never retained
across an unrelated event-loop turn.

## One-shot requests

Each one-shot operation allocates one request record containing only its
GC-owned, immovable native request storage and operation-specific callback.
That callback closure captures the suspended Task and any buffer, address, or
argument that libuv still borrows.

The Task's `pending` field roots that request until its terminal callback.
Accepted operations produce exactly one callback. Titan does not suppress that
callback by cancelling an accepted request underneath its continuation. A
negative submission result produces none.

Filesystem callbacks extract their result, run `uv_fs_req_cleanup` exactly
once, and only then resume the Task. Read storage and the original string used
by a write remain rooted through that point. DNS callbacks copy normalized
address cells before `uv_freeaddrinfo`. Connect, write, and shutdown requests
likewise retain exactly the native storage and borrowed values required until
their callbacks.

Libuv queues stream `uv_write` requests in submission order. Titan submits one
request per Task call and does not duplicate that queue. Filesystem requests
are independent thread-pool jobs. Titan neither serializes them nor keeps an
active-operation count on the descriptor; callers coordinate a shared File
when ordering a close against other requests matters.

## Persistent callback handles

Repeating timers, stream reads, listening sockets, and the one-shot exit
callback on a persistent process handle own only the state inherent in their
callback protocol:

- a repeating timer has one pending-fired bit and at most one waiter;
- a readable stream has buffered chunks, terminal EOF/error state, and at most
  one waiter;
- a listener accepts immediately in its connection callback, then buffers the
  accepted client or satisfies one waiter; and
- a process caches its exit status and satisfies at most one current waiter.

A callback clears its waiter before resuming it. The continuation may install
the next waiter before the callback returns, with no reentrant `uv_run` and no
unrelated callback interleaving.

Stream allocation is paired directly with the next read result. Positive
reads copy the reported byte count, zero reads are ignored, `UV_EOF` becomes
nil EOF, and another negative result becomes an `async.Error`. After a terminal
read result the stream is not read again.

Process configuration is likewise direct rather than a second declarative
model. `uv_spawn_config` owns an actual zero-initialized
`uv_process_options_t`, its three-element `uv_stdio_container_t` array, and
the concrete configured streams. Each configurator initializes any required
pipe or parent stream immediately, writes the stdio entry, and returns a
status so the caller can stop the option sequence at its first failure.
Replacing a choice closes unsubmitted streams that are no longer retained.
Parent descriptors are always represented by the Runtime's pipe-or-TTY stream
wrappers and inherited with `UV_INHERIT_STREAM`, never `UV_INHERIT_FD`.
Merged output uses separate child-write and parent-read pipe handles, installs
the child stream in both child entries, and exposes the same parent stream as
both Process outputs.

A successful spawn returns the native process wrapper and its three optional
parent endpoints together. The public `os.Process` takes those streams
immediately; the private `uv_process_t` does not duplicate them and retains
only its callback-lived handle, Runtime, waiter, cached exit result, and root
slot.

Captured stdout and stderr begin draining after a successful spawn. Parent
stdin remains lazy until the parent facade reads it, so merely preparing that
stream for `UV_INHERIT_STREAM` does not consume the child's input. An
unexpected captured-read startup error closes and terminalizes only that
stream; the low-level module does not kill or reap the successfully spawned
child.

Closing a watcher stops callbacks that libuv says may be suppressed and uses
the asynchronous `uv_close` callback to settle any blocked continuation.
Repeated public close calls remain safe; the implementation does not build a
close-waiter queue.

## Rooting and ownership

Libuv's `data` fields are raw `void *` slots and do not root Lua objects. The
Runtime therefore has two monotonically indexed sparse Arrays:

- `handle_roots` is only the live-owner set required by the current C-to-Titan
  callback bridge. It is never traversed; and
- `task_roots` keeps nonterminal Tasks alive and is the intentional Task
  inventory added above raw libuv. It determines when the last user Task has
  finished and lets `os.exit` cancel the other live Tasks.

A request is normally rooted directly by its Task. Closing swaps a handle's
callback data to a small close record that roots the original native owner
through the close callback. Entries are cleared to holes after terminal
callbacks. Neither Array is a parallel resource model or a source of shutdown
handle discovery; libuv's loop remains authoritative through `uv_walk`.

Owned C objects and arrays provide stable native addresses. Automatic C
aggregates are used only for synchronous calls whose pointers cannot escape.
Titan strings are themselves stable while rooted: a stream or filesystem
write owner retains the original string until the callback, without making a
second payload copy. Libuv copies the submitted `uv_buf_t`, asynchronous
filesystem paths, and DNS text during submission; `uv_spawn` consumes its file
and argv text synchronously. Titan validates text arguments for embedded NUL
where required and keeps the originals reachable for every interval in which
libuv borrows them. Binary buffers always use exact lengths and never depend
on C-string termination.

## Task completion and errors

A Task keeps its coroutine and only the state required to drive and root its
current continuation. It has no joiner list and the initial
direct-continuation API has no `join` operation.

An uncaught Task error is not a Runtime fatal condition. The continuation marks
only that Task failed, renders the error, writes it and the preserved traceback
to standard error, and returns to libuv. Other Tasks remain active. When the
last Task finishes—successfully, by cancellation, or by uncaught error—the
Runtime starts ordinary cleanup.

Cancellation never releases native request storage early or suppresses an
accepted request's terminal callback. For a watcher whose event callback can
be suppressed, the cancellation action stops and closes the watcher and lets
`close_cb` resume the Task. Sticky cancellation is injected again at later
suspension boundaries if application code catches it. A waiter detached from a
shared multi-shot handle cannot close that shared resource; it receives its own
zero-duration timer callback on the next loop turn. Cancellation never resumes
one Task synchronously inside another Task.

## Runtime shutdown

The Runtime sets `closing` before cleanup, so dispatchers that create new
handles fail. A private cleanup Task then uses the same continuation protocol:

1. yield one cleanup step;
2. while that Task is suspended, synchronously call `uv_walk` to select one
   non-closing handle and submit its ordinary `uv_close`;
3. repeat after `close_cb` until a walk finds none; and
4. return normally, which marks Runtime cleanup complete.

The outer `uv_run` never stops during this sequence. It delivers outstanding
request and close callbacks until the loop becomes idle. Only then does the
top-level driver call `uv_loop_close`; a negative `UV_EBUSY` result is an
implementation failure, not something hidden by a second ownership graph.

A `uv_process_t` is an ordinary discovered handle during cleanup. Calling
`uv_close` retires its watcher; it neither signals the child nor waits for or
reaps it. A child may therefore outlive its Runtime. Explicit `Process:kill`
and `Process:wait` calls remain the application's child-lifecycle operations.
The Runtime needs no process registry or termination policy; its generic root
table keeps a live process owner reachable for callbacks but is never traversed
as an ownership list.

A `uv_file` is an operating-system descriptor rather than a `uv_handle_t`.
There is deliberately no Runtime File registry and no automatic File-close
shutdown phase. The wrapper and each in-flight filesystem request retain the
descriptor as needed; explicit `File:close()` owns its terminal callback, while
operating-system process teardown handles descriptors left open by the
application.

After successful close, the Runtime clears its roots. A later `run`/`loop`
pair creates a fresh loop. Retained loop resources from the prior session are
terminal. A File carries no Runtime identity, so an open descriptor can be
used by a Task in that later Runtime; application code still owns its explicit
close.

## Standalone bootstrap and host-process policy

Module initialization records the main Lua thread, applies `uv_setup_args`
when a generated entrypoint published argc/argv, and installs the private main
bootstrap hook. It also changes only a default Unix `SIGPIPE` disposition to
ignored so libuv can report closed-stream writes.

The standalone bootstrap schedules `main` as a Task and drives the same outer
loop. It waits for all Tasks through Runtime liveness, not Task joins. An
uncaught main-Task error is logged like any other Task error and produces an
unsuccessful executable status. `os.exit` records the requested code, cancels
every user Task including its requester, runs normal cleanup, and returns that
code through the generated entrypoint rather than calling ISO C `exit`. Only
the first request commits the code. The requester raises its stored
`Cancelled` value, so catching that exception cannot clear cancellation: the
continuation may run synchronous cleanup, but its next yield receives the same
exception before any new libuv operation is dispatched.
