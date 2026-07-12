# Libuv continuation runtime

The asynchronous standard library has one low-level owner:

```text
coroutine.so -> uv.so
                 |-> timer.so
                 |-> fs.so
                 |-> net.so
                 `-> os.so
```

`uv.so` links `titan_uv.o` and the selected libuv exactly once. `timer.so`,
`fs.so`, `net.so`, and `os.so` import the canonical binary `uv.so` with
`loadstdlib`; they do not compile `uv.titan`, link `titan_uv.o`, or embed
another libuv archive. Their `titan.*` Lua aliases are relative symlinks to the
canonical images. Bundled and system acquisition, including Linux and macOS
packages, is documented in the [README](../../README.md#libuv-setup).

## GC-owned native storage

Every loop, timer, one-shot signal, filesystem/network/process request, TCP or
pipe handle, process handle, private process-grace timer, I/O buffer,
`uv_buf_t`, opaque address cell, argv cell, and scandir entry used by the
runtime is allocated in Lua full-userdata payload bytes. The Titan source uses
the imported foreign type's `<module>.<type>.sizeof` and `.alignof`, captures
the storage userdata once, and stores the resulting pointer in a local field
of an opaque record:

```titan
record uv_timer_t
  local handle: *uv.uv_timer_t
  local storage: value
  -- six more local owner fields
end
```

The native pointer is never converted through `value`. The wrapper is allocated
once, Titan's nominal/local-field rules prevent external forgery, and later
calls read the exact pointer field without pointer-boxing allocations. The
Runtime roots a timer wrapper through its close callback and an `uv_fs_t`
wrapper through completion and `uv_fs_req_cleanup`; each wrapper roots its
storage userdata. An initialized handle is never released by a GC finalizer
before its close callback.

Persistent file descriptors use a separate exported `uv_file` wrapper. Its
first local field has the exact scalar C type `uv_file`, followed by local
Runtime-generation, state, FIFO, and root links. `fs.File` contains that wrapper
in its own single local field. Neither layer boxes the descriptor as `value`,
and neither constructor is available outside its declaring module.

The process boundary uses the same pattern twice. The exported
`uv.uv_process_t` has an exact `*uv_process_t` local field and is wrapped by
`os.Process`, whose sole field is itself local. Private `uv_pipe_t`,
`uv_write_t`, and grace-timer records likewise retain exact native pointers.
Recursive and heterogeneous ownership links use `value`, but native handles
never do; a process or pipe therefore pays for its record and storage once,
not for repeated pointer-to-`value` coercions on every operation.

Each callback owner has eight stable record/uservalue slots: native pointer,
storage, main Lua thread, module Udata, dispatcher closure, Task/resource root,
operation metadata, and an additional buffer/resource root. The C shim uses
the corresponding zero-based indices.

## Runtime and continuation graph

One `uv` module instance owns one private coroutine tag and at most one active
Runtime. A Runtime contains a Titan-owned private `uv_loop_t`, the main Lua
thread, separate linked lists for timer and signal owners, pending
filesystem/network/process requests, persistent Files, TCP resources and
Process controls, and Tasks, the currently running Task, and the first fatal
error/trace. The lists reflect different terminal events: handle close,
request callback plus cleanup, descriptor close request, child exit followed
by process close, and coroutine completion. Sequential sessions reuse the tag
but allocate a fresh loop and generation.

`uv.run` constructs a Task and arms a zero timer; it never resumes the Task. A
callback drives the root coroutine until it finishes or yields a private
Request with the shared tag. The dispatcher validates the Task epoch and
either registers the new owner or iteratively injects an immediate submission
error. Consecutive immediate failures are bounded and deferred through a zero
timer so one callback cannot spin indefinitely.

Joiners are linked to the target and woken by independent zero-timer callbacks.
An observer count is acquired only while a join is pending. Observation becomes
permanent when the join-wake callback actually delivers the result;
cancellation before delivery revokes the claim and lets an otherwise-unobserved
failure be promoted on its next turn. Target and join-site tracebacks are staged
and combined when a failed join propagates.

## Filesystem requests and persistent Files

Every filesystem await yields the same private Request family used by timers
and joins, with an `FsOperation` as its subject. Path operations copy each text
argument into rooted, NUL-terminated userdata before submission and reject an
embedded NUL. Write payloads are copied byte-for-byte into rooted userdata;
read results are constructed with an explicit length, so file data remains
binary.

For reads and writes, `submit_fs_operation` finishes every allocating buffer
copy/descriptor preparation and roots it through the logical operation before
it allocates and publishes an eight-field `uv_fs_t` owner. It also validates
the private operation kind and caches the exact loop, path, descriptor, and
buffer arguments first. After publication, no Titan record cast or error path
can run before the public `uv_fs_*` call. Thus an OOM, buffer-validation error,
or internal operation invariant failure cannot leave a request for which libuv
owes no callback. A negative immediate return likewise cannot produce a
callback: the submission arm calls `uv_fs_req_cleanup` and injects the error
iteratively. A successful submission remains in `Runtime.fs_pending_head`
until the callback has extracted all borrowed data and cleaned the request
exactly once.

The filesystem callback records its terminal state before allocating a result.
It copies read bytes, stat fields, or scandir names while request-owned pointers
are valid, calls `uv_fs_req_cleanup`, updates File bookkeeping, and only then
drives user code. The direct native `fs_dispatch` is intentionally thin: it
installs its trailing Titan catch, records the callback result and any
successfully opened descriptor without allocating, then calls the allocating
dispatcher body. If even body-entry GC, extraction, or bookkeeping raises, the
catch performs any still-needed
non-allocating request cleanup, records the first Runtime failure, stops the
loop, records the callback result as needing logical repair, and returns through
libuv. The outer loop safe point repairs a completed File's current/FIFO state
before retiring its cleaned owner. It also converts a successfully opened but
undelivered descriptor into an internal close operation. A physical close that
reached the catch is distinguished from a failed close, so it is never
submitted twice; a failed close remains rooted for an internal retry.

Each persistent File owns one logical FIFO. Only its head can own a submitted
request. A partial `uv_fs_write` is resubmitted from the same logical operation
until all bytes have been consumed, so another Task's operation cannot
interleave between partial writes. Completion removes the old head only after
driving its captured Task; an operation enqueued by that continuation therefore
lands behind work that was already waiting. If advancing a File encounters an
immediate error for another Task, a task-specific zero timer delivers it rather
than directly resuming an independent root from the current callback.

Close changes the File to `closing` before it yields and rejects later ordinary
operations. The close request remains behind operations already in the FIFO;
additional close callers wait on the same physical request. A successful close
invalidates the descriptor, marks the File closed, wakes other close waiters
through task-specific callbacks, and removes the Runtime root. A failed close
is retried internally, but the retry chain is bounded. If every attempt fails,
the Runtime records the close error, finishes draining unrelated owners, closes
the now-idle libuv loop, and retains the failed File/Runtime instead of spinning
inside `UV_RUN_DEFAULT` or pretending that the descriptor was released. Later
work is rejected and another `uv.loop()` reports the saved failure without
re-entering libuv.

`stat` uses public `uv_fs_stat`, which follows symbolic links. The narrow shim
copies the portable `uv_stat_t` size, mode, and modification fields and
classifies the resulting target kind. Titan exposes no `lstat` operation yet.
All actual I/O and path changes use public libuv APIs; the shim contains no
POSIX `open`, `read`, `write`, or `close` fallback.

## Portable OS helpers and signals

The `os.so` facade contains no foreign import. Its `_os_*` calls cross the
binary-only boundary into canonical `uv.so`, which invokes public `uv_os_*`,
`uv_cwd`/`uv_chdir`, and `uv_exepath` APIs. Variable-size text results use
Titan-owned byte storage and checked growth. `UV_ENOSYS` is reported as an
ordinary `uv.Error`; there is no hidden POSIX fallback.

On the supported Linux and macOS implementations, `uv_exepath` reports success
even when its result filled the entire payload capacity. The runtime treats
that saturated result as ambiguous and retries with a larger GC-owned buffer.
Those two implementations do not consult `uv_setup_args`; adding another host
would require auditing that host's public `uv_exepath` prerequisite first.

A one-shot signal wait uses GC-owned `uv_signal_t` storage and the same fixed
owner layout as other callback handles. Host signal-number mapping is isolated
in the shim; the Titan interface exposes only the common lowercase Linux/macOS
names. Before arbitrary continuation code runs, the callback records the
signal, stops the watcher, clears its waiter epoch, and initiates `uv_close`.
Cancellation performs the same physical stop-and-close path without delivering
a stale signal.

## Child processes and stdio pipes

`os.spawn` copies the executable and every argument into rooted NUL-terminated
GC storage, then builds a GC-owned `char *` array containing `argv[0]`, the
caller arguments, and the final `NULL`. Before acquiring a descriptor it also
allocates the process, three pipe owners, descriptor/filler arrays, and one
GC-owned `uv_fs_t` used for synchronous raw-descriptor cleanup. From the first
descriptor acquisition through that cleanup, the submission frame performs no
Titan allocation.

The shim creates anonymous pipes through public `uv_pipe`. It temporarily
retains filler pairs containing descriptors 0, 1, or 2, ensuring a libuv pipe
handle never owns a descriptor that libuv's Unix stream-close path treats as
stdio. The three child ends are passed to `uv_spawn` as exactly three valid
`UV_INHERIT_FD` entries; the parent ends are opened into GC-owned `uv_pipe_t`
handles. Titan closes every still-caller-owned child end and filler through
public synchronous `uv_fs_close` plus `uv_fs_req_cleanup`. There is no POSIX
`pipe`, `dup`, or `close` fallback.

`ProcessControl`, `PipeControl`, `ProcessOperation`, and
`ProcessRequestControl` are separate from the TCP state machine:
anonymous-pipe lifetime, process reaping, and retained exit status are not
socket semantics. Once a spawn succeeds, the process
handle is never closed before its exit callback. That native callback first
records the exit code and termination signal, closes stdin, and starts
`uv_close` on the process; only the process close callback publishes the
retained result to a waiter. An ordinary negative `uv_spawn` result owes no
exit callback, but the initialized process and pipe handles are closed before
the spawn error reaches user code. If spawn itself succeeded but later
caller-owned descriptor cleanup failed, the unpublished child is terminated,
reaped, and drained before the setup error is delivered.

Stdin writes have a per-pipe FIFO of logical operations. A submitted
`uv_write_t`, its `uv_buf_t`, and copied binary payload remain rooted through
the write callback even if their Task is cancelled. `close_stdin` inserts a
cleanup-shielded, monotonic close operation behind preceding writes and rejects
new output immediately. Anonymous pipes do not support socket-style
`uv_shutdown` on the supported Unix hosts, so the FIFO finishes by calling
`uv_close` on the write pipe and wakes the closer from the handle close
callback. Stdout and stderr independently allow one reader; EOF and read
failure are persistent terminal states, and a terminal read closes that pipe.
Process exit does not synthesize pipe EOF, so output continues to drain through
the real stream callback sequence.

`os.communicate` creates a private HelperGroup with four child Tasks: stdout
reader, stderr reader, stdin writer/closer, and process waiter. Every helper is
linked to the group and marked permanently observed before its start timer is
armed, so even an immediate start failure cannot become an unrelated
unobserved-Task error. The parent waits for all four on success, while the first
helper failure wakes it early. Failure or parent cancellation preserves the
first error and traceback, cancels the siblings, terminates and reaps the
child, waits for every helper and native owner under the cleanup shield, then
rethrows the original error. Output chunks are pairwise joined to avoid
quadratic copying. This concurrent design prevents the sequential
stdin/stdout/stderr pipe deadlock that a series of ordinary joins would allow.

## Direct native callback boundary

`titan-runtime/titan_uv.c` recovers a rooted timer, signal, filesystem, DNS,
stream, pipe, write-request, or process owner through public libuv data
accessors, reads its main-thread/module/dispatcher slots, obtains the native
Titan function pointer, and calls:

```c
dispatch(L, M, NULL, owner, event_kind, result, size, pointer);
```

The fixed final payload is `NULL` for timer, signal, close, filesystem, stream,
pipe-write, and process-exit callbacks. A process exit uses `result` for the
exit status and `size` for the termination signal. DNS completion uses the
payload for libuv's borrowed `addrinfo` list, which the trusted dispatcher
copies into GC-owned opaque address storage and releases before returning to
libuv.

There is no `lua_pcall`, Lua entry wrapper, or VM generic-call path around this
call. Dispatchers are trusted library code. Each function-level trailing Titan
`catch` records a Runtime-fatal error and trace, calls `uv_stop`, and returns
normally to the C trampoline. For a function-scope catch, code generation
installs that catch's jump target before the entry GC check; the loop driver
reserves `LUA_MINSTACK` first, so emergency-GC and stack-preparation failures
cannot unwind through libuv. This remains the native Titan entry, not a C
protected call. The inner Task drive has its own catch to classify ordinary
Task failure/cancellation without turning it into a broken dispatcher.

Application code intentionally runs in the libuv callback until its next
asynchronous yield. Neither the dispatcher nor any callback invokes `uv_run`;
only `uv.loop` or the standalone bootstrap drives the loop from the outer
main-thread boundary.

## Cancellation and shutdown

Cancellation sets the first reason and advances the Task epoch synchronously.
A zero-timer callback injects `Cancelled`; if even that timer submission fails,
the outer loop driver performs the injection at a callback-free safe point.
Ordinary awaits remain sticky-cancelled. Library-owned cleanup can use the
private cleanup-shield state so physical teardown finishes before cancellation
is reinjected.

Filesystem cancellation is family-aware. An unsubmitted File operation is
unlinked from its FIFO. A submitted, non-cleanup request is passed to public
`uv_cancel`; whether cancellation succeeds or is too late, the promised
completion callback still owns physical cleanup and an obsolete normal result
cannot resume the Task. Filesystem close Requests are cleanup-shielded and are
never physically abandoned. Releasing one cleanup shield does not immediately
throw the saved cancellation: consecutive library cleanup calls may finish,
after which the next ordinary await or Task return delivers it. A delayed
close-wait wake carries the exact cleanup Request, so a later cancellation
epoch cannot invalidate its only completion.

Networking cancellation follows the same owner rule. Queued writes are
unlinked, but an active `uv_write_t` remains rooted through its callback and
its cancellation is only logical. The first shutdown request is
cleanup-shielded through the `uv_shutdown_t` callback; repeated shutdown calls
are idempotent. Explicit TCP close stops reads and forbids new output, but
leaves submitted and queued FIFO work in order and calls `uv_close` only after
that output drains. Runtime-wide forced shutdown may instead retire queued
operations while it closes every remaining TCP resource. The complete network
state machine is documented in [Libuv DNS and TCP
implementation](libuv-networking.md).

Process cancellation is also logical where libuv still owes a callback. A
queued stdin write can be unlinked; a submitted write remains rooted until its
callback. Cancelling a wait clears only that waiter, so another Task may wait
and later waits use the cached exit status. Cancelling `close_stdin` cannot
revoke the already-published FIFO close. Cancelling `communicate` is handled by
its HelperGroup cleanup path and does not expose a partially reaped child or an
unobserved helper failure.

Normal and fatal shutdown close remaining timer and signal owners, enqueue
internal closes for every persistent File, close remaining TCP resources, and
begin shutdown for every live child before repeatedly running the loop only
from the outer driver. Child shutdown closes its stdio pipes, sends `term`, and
arms a private five-second grace timer; if the exit callback has not arrived,
the timer sends `kill`. `UV_ESRCH` does not substitute for reaping: shutdown
still waits for the promised exit callback, then closes the process handle and
drains all pipe callbacks. The grace timer belongs to its ProcessControl rather
than the generic timer list, so ordinary timer sweeping cannot retire it
early.

The outer driver repairs late successful opens and aborted process/pipe
callbacks and drains all filesystem, network, and process request callbacks
and cleanups. Normally it continues until the timer, signal, request, File,
TCP, Process, pipe, and process-request root lists are empty. If
bounded descriptor-close retries are exhausted,
only those failed File roots remain; the idle loop is still closed, while the
terminal Runtime retains the wrappers and rejects reuse. An
unexpected `UV_EBUSY` uses public `uv_walk` and handle-type accessors to report
the remaining count/type rather than hanging on an unknown active handle; the
busy loop root is preserved rather than risking native use-after-free.
The known-owner drain also detects consecutive idle passes and preserves its
remaining roots while reporting `shutdown.no-progress`, rather than spinning
forever if future bookkeeping violates a lifecycle invariant.

## Bootstrap and tests

Module initialization installs an idempotent registry bootstrap. The generated
standalone entrypoint loads imports first, then calls that hook under its
existing outer protected entry. Programs without the hook retain direct
synchronous `main`.

The focused suites cover source and binary interfaces, native
timer/FS/network/signal/process/pipe owner layout, direct callbacks, callback
depth/main-thread dispatch, Task and timer behavior, filesystem and network
binary data, portable OS helpers, one-shot signals, child argv/environment/cwd,
retained exit status, binary stdio FIFO, replaceable wait/read cancellation,
deadlock-free `communicate`, TERM-resistant shutdown, FIFO/close state
machines, path operations, pre-submission allocation and bounded-close faults,
failed-spawn and exit-before-close ordering, callback repair, observed helper
failure, request cleanup/cancellation faults, trace propagation, GC, sequential
sessions, standalone bootstrap, canonical aliases, LuaRocks ownership, and
bundled/system libuv topology. Linux CI also rebuilds Lua, libbacktrace, libuv,
the Titan runtime, and standard modules under ASan/UBSan, then runs
representative timer/FS and core owner/callback suites plus production net/OS
smokes. Exhaustive transformed fault variants remain in regular Linux CI; the
sanitizer net smoke specifically keeps a large write pending across Task
cancellation, unwind, and forced GC. Its
stack-use-after-return coverage relies on `minicoro.h` announcing every native
coroutine stack switch to the ASan fiber API, including tagged and stacked
terminal transfers. In that mode minicoro retains its stack-corruption sentinel
but leaves address-range checking to ASan, because GCC's use-after-return
instrumentation can move an address-taken local onto the sanitizer fake stack.
