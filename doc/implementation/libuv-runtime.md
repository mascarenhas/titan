# Libuv continuation runtime

The asynchronous standard library has one low-level owner:

```text
titan/coroutine.so -> titan/uv.so
                         |-> titan/timer.so
                         |-> titan/fs.so
                         |-> titan/net.so
                         `-> titan/os.so
```

`titan/uv.so` extracts `titan_uv.o` from `libtitan.a` and links the selected libuv
exactly once. Both checkout and installed driver modes link the runtime archive,
never a direct `titan.o`; static selection extracts only referenced shim
members. `titan/timer.so`, `titan/fs.so`, `titan/net.so`, and `titan/os.so`
import the qualified binary `titan/uv.so` with the ordinary Titan loader; they
do not compile `titan/uv.titan`, extract `titan_uv.o`, or embed another libuv
archive. Dependency resolution is binary-first, while the explicit
`titanc titan.uv` build root is source-first. Installation writes exactly one
ordinary file per standard module under
`<root>/lib/titan/0.11/titan/`.
Lua's configured C-module path and ordinary qualified Titan lookup both
resolve those files, with no copied, symbolic-link, or hard-link aliases. Thus
every facade reaches the same `titan/uv.so` image. In the normal
bundled build, `titan/uv.so` is the process's sole complete libuv provider; its
private static archive is consumed only for that link and is not installed in
the Titan SDK, while the headers remain available under the installed include
directory. An ordinary extension DSO may call libuv directly without embedding
or linking it: it must import `uv` (desugared to `titan.uv`) as well as
foreign-import `uv.h`, leaving its ordinary `uv_*` function calls unresolved.
Titan's generic runtime loader maps every compiled runtime dependency with
`RTLD_LAZY | RTLD_GLOBAL`. Lazy binding lets the extension map before the
provider is available; the extension's generated initializer then loads its
explicit `uv` import globally before Titan code can make one of those calls.
`RTLD_NOW` would fail while mapping the extension, before its initializer could
load the provider, while a provider loaded `RTLD_LOCAL` later would not satisfy
the extension's lazy bindings. Compiler interface inspection remains
`RTLD_LAZY | RTLD_LOCAL`; neither path has libuv-specific metadata,
classification, or a provider-specific loader helper. The runtime path cannot
satisfy native constructors, imported data, or function-address relocations
that need libuv while the extension itself is being mapped. A Lua caller must
`require "titan.uv"` before requiring that extension directly. The installed
`titan/uv.lua` loader resolves the DSO with `package.searchpath`, maps it with
`package.loadlib(path, "*")`, and invokes its `luaopen_titan_uv` entry. Other
Lua C modules remain local. This public Lua package path works with stock Lua
5.5 on Linux and macOS, and `titan/uv.so` has no
self-dlopen/promotion helper. System mode may instead link the extension and
canonical `titan/uv.so` against the same shared libuv selected by pkg-config.
Statically embedding the bundled archive again would create a second native
instance. Lua's explicit global preload occurs before the extension is mapped,
so that route also supports eager libuv relocations and native constructors;
the normal Titan runtime route deliberately supports only lazy function calls.

Runtime/Task/resource state remains in registry/GC-owned objects. These
post-install files are outside the source rock's manifest. Bundled and system
acquisition, including Linux and macOS packages, is documented in the
[README](../../README.md#libuv-setup).

## GC-owned native storage

Every loop, timer, one-shot signal, filesystem/network/process request, TCP or
pipe handle, process handle, private process-grace timer, Titan-owned I/O
buffer or `uv_buf_t`, opaque address cell, argv cell, and scandir entry used by
the runtime is allocated in Lua full-userdata payload bytes. The `uv_buf_t`
passed to a stream allocation callback is the exception: libuv owns that
descriptor, while Titan owns and roots only the byte storage to which it
points. The Titan source uses
the imported foreign type's `<module>.<type>.sizeof` and `.alignof`, captures
the storage userdata once, and stores the resulting pointer in a local field
of an opaque record:

```titan
record uv_timer_t
  local handle: *uv.uv_timer_t
  local storage: value
  -- four more local owner fields
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
`os.Process`, whose native-handle field is itself local and which also owns
private stdout/stderr reader-state records. Private `uv_pipe_t`, `uv_write_t`,
and grace-timer records likewise retain exact native pointers.
Homogeneous ownership links use their exact record type, with `T?` only where
the link may be absent. `value` is reserved for opaque Lua roots, arbitrary
task/error payloads, and genuinely heterogeneous owner slots. Native handles
never use `value`; a process or pipe therefore pays for its record and storage
once, not for repeated pointer-to-`value` coercions on every operation.

This distinction also matters for the continuation graph. Recovering a record
from `value` must validate its record metatable at run time. Unwrapping `T?`
checks only for nil because the checker already guarantees the non-nil nominal
type. Runtime lists, FIFO links, waiters, operation-specific roots, and helper
references therefore keep their record identity in the static type instead of
revalidating it at every traversal.

Each callback owner has six stable record/uservalue slots: native pointer,
storage, the module-cached main Lua thread, dispatcher closure, operation
metadata, and family-specific native I/O storage. The C shim uses the
corresponding zero-based indices and recovers the module Udata from the
dispatcher closure's first upvalue. Metadata already roots each Task, resource,
or operation graph, so owners carry no duplicate root slot. Timer, signal,
process, process-grace, DNS, connect, shutdown, Pipe, and TCP owners type the
final slot as `nil`. Filesystem and write-request owners retain their submitted
`Buffer?` there. A Pipe or TCP control instead roots its current stream-read
allocation as a `Bytes?`; on a positive callback that same record moves into a
GC-traced `{Bytes}` queue, retaining the raw pointer, full-userdata root, and
completed length until the queue is drained.

## Runtime and continuation graph

One `uv` module instance owns one private coroutine tag, caches the main Lua
thread once, and has at most one active Runtime. A Runtime contains a
Titan-owned private `uv_loop_t`, separate linked lists for timer and signal owners, pending
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
error. Immediate results continue in that callback until the Task either
finishes or submits an operation that actually waits; `timer.yield()` is the
explicit way for user code to cede to a new loop turn.

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
it allocates and publishes a six-field `uv_fs_t` owner. It also validates
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
installs its trailing Titan catch, records any successfully opened descriptor
without allocating, then calls the allocating
dispatcher body. If even body-entry GC, extraction, or bookkeeping raises, the
catch performs any still-needed
non-allocating request cleanup, records the first Runtime failure, stops the
loop, marks the callback as needing logical repair, and returns through
libuv. The outer loop safe point repairs a completed File's current/FIFO state
before retiring its cleaned owner. It also converts a successfully opened but
undelivered descriptor into an internal close operation. A close callback is
terminal whether it succeeds or reports an error: retrying `close` could act on
a descriptor number the OS has already reused.

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
also invalidates the wrapper and reports that one error to the waiting Task, or
to the Runtime for an internal shutdown close. It is never submitted again.

`stat` uses public `uv_fs_stat`, which follows symbolic links. The narrow shim
copies the portable `uv_stat_t` size, mode, and modification fields and
classifies the resulting target kind. Titan exposes no `lstat` operation yet.
All actual I/O and path changes use public libuv APIs; the shim contains no
POSIX `open`, `read`, `write`, or `close` fallback.

## Portable OS helpers and signals

The `os.so` facade contains no foreign import. Its `_os_*` calls cross the
binary-only boundary into canonical `titan/uv.so`, which invokes public `uv_os_*`,
`uv_cwd`/`uv_chdir`, and `uv_exepath` APIs. Variable-size text results use
Titan-owned byte storage. A generic helper accepts the libuv buffer function
and an error-construction closure, keeps both the capacity and returned length
as `size_t`, and starts with a 256-byte GC-owned buffer. `UV_ENOBUFS` recurses
with the exact capacity reported through libuv's size pointer; success passes
that `size_t` directly to `lua_pushlstring`. `uv_os_getenv` additionally maps
`UV_ENOENT` to `nil`. Other failures become ordinary `uv.Error` values; there
is no hidden POSIX fallback or private checked-growth policy.

The supported Linux and macOS `uv_exepath` implementations signal truncation
as a successful result whose reported length saturates `capacity - 1`, rather
than returning `UV_ENOBUFS`. Its small adapter translates only that result to
`UV_ENOBUFS` and supplies twice the previous capacity, after which the same
recursive helper handles the retry. There is no retry loop, attempt limit, or
fault-injection growth hook.

Libuv's public `uv_exepath` contract requires `uv_setup_args` to run once at
process startup. Before requiring the compiled main module, Titan's generated
entrypoint publishes its original `argc` and `argv` under private registry
keys. If `titan.uv` sees those keys during module initialization, this canonical
provider calls `uv_setup_args` exactly once, writes libuv's possibly replaced
`argv` pointer back to the registry, and records readiness in a module-local
boolean. The entrypoint rereads that pointer before constructing the Titan
argument table. A Lua or other embedding host has no published arguments, so
the provider skips setup and `os.exepath` raises instead of calling libuv
outside its documented prerequisite.

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
caller arguments, and the final `NULL`. It allocates the process and three
GC-owned pipe owners, initializes each with public `uv_pipe_init`, and passes
their handles to the spawn shim.

The shim describes stdin as `UV_CREATE_PIPE | UV_READABLE_PIPE` and stdout and
stderr as `UV_CREATE_PIPE | UV_WRITABLE_PIPE`. Public `uv_spawn` therefore
creates and opens the parent endpoints itself; Titan never manages raw pipe
descriptors or child ends. A failed initialization or spawn closes every
initialized handle through the ordinary libuv callback path. There is no POSIX
`pipe`, `dup`, or `close` fallback.

After `uv_spawn` succeeds, Titan starts continuous reads on both output pipes
before publishing the Process. If either `uv_read_start` fails, an
already-started sibling is stopped, all three pipes are closed, the child is
terminated and reaped through the ordinary grace/kill path, and its process
handle is closed before the spawn Task receives the original error.

`ProcessControl`, `PipeControl`, `ProcessOperation`, and
`ProcessRequestControl` are separate from the TCP state machine:
anonymous-pipe lifetime, process reaping, and retained exit status are not
socket semantics. Once a spawn succeeds, the process
handle is never closed before its exit callback. That native callback first
records the exit code and termination signal, closes stdin, and starts
`uv_close` on the process; only the process close callback publishes the
retained result to a waiter. An ordinary negative `uv_spawn` result owes no
exit callback, but the initialized process and pipe handles are closed before
the spawn error reaches user code.

Stdin writes have a per-pipe FIFO of logical operations. A submitted
`uv_write_t`, its `uv_buf_t`, and copied binary payload remain rooted through
the write callback even if their Task is cancelled. `close_stdin` inserts a
cleanup-shielded, monotonic close operation behind preceding writes and rejects
new output immediately. Anonymous pipes do not support socket-style
`uv_shutdown` on the supported Unix hosts, so the FIFO finishes by calling
`uv_close` on the write pipe and wakes the closer from the handle close
callback. Stdout and stderr independently allow one reader; EOF and read
failure are persistent terminal states. Each output pipe keeps reading into a
GC-owned `{Bytes}` queue even with no waiter, with no high-water mark. A plain
read drains its facade excess or the entire native queue, while a delimiter
read retains bytes beyond its first delimiter. Both methods share that pipe's
reader lock; stdout and stderr have independent locks. Cancellation clears only
the matching waiter and leaves physical reading active. EOF stops and may close
the output pipe while remaining sticky `nil`; another read failure initiates
close, but queued bytes and the sticky error remain logically readable in
order. Process exit does not synthesize pipe EOF, so output continues to drain
through the real stream callback sequence.

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
accessors, reads its main-thread and dispatcher slots, recovers the module from
the dispatcher's first upvalue, obtains the native Titan function pointer, and
calls:

```c
dispatch(L, M, NULL, owner, event_kind, result, size, pointer);
```

The fixed final payload is `NULL` for timer, signal, close, filesystem,
stream-read, pipe-write, and process-exit callbacks. A stream-allocation
callback passes libuv's borrowed output `uv_buf_t *`; the Titan dispatcher
initializes its base and length from freshly allocated, rooted GC storage
before returning. A process exit uses `result` for the exit status and `size`
for the termination signal. DNS completion uses the payload for libuv's
borrowed `addrinfo` list, which the trusted dispatcher copies into GC-owned
opaque address storage and releases before returning to libuv.

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
are idempotent. Cancelling a stream read clears only its waiter and epoch;
continuous physical reading and buffering remain active. Explicit TCP close
stops reads and forbids new output, but leaves submitted and queued FIFO work
in order and calls `uv_close` only after that output drains. Runtime-wide
forced shutdown may instead discard completed read queues and retire queued
operations while it closes every remaining TCP resource. The complete network
state machine is documented in [Libuv DNS and TCP
implementation](libuv-networking.md).

Process cancellation is also logical where libuv still owes a callback. A
queued stdin write can be unlinked; a submitted write remains rooted until its
callback. Cancelling a wait clears only that waiter, so another Task may wait
and later waits use the cached exit status. Cancelling `close_stdin` cannot
revoke the already-published FIFO close. Cancelling an output read likewise
clears only that pipe's waiter and does not stop its continuous read.
Cancelling `communicate` is handled by its HelperGroup cleanup path and does
not expose a partially reaped child or an unobserved helper failure.

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
TCP, Process, pipe, and process-request root lists are empty. An unexpected
nonzero `uv_loop_close` status becomes the `loop.close` failure, and the busy
loop root is preserved rather than risking native use-after-free.
If `uv_run` reports no live work while known owners remain, the driver preserves
those roots and reports `shutdown.no-progress` instead of running the same idle
loop again.

## Bootstrap and tests

Module initialization stores its private registry bootstrap. The generated
standalone entrypoint loads imports first, then calls that hook under its
existing outer protected entry. Programs without the hook retain direct
synchronous `main`.

The focused suites cover source and binary interfaces, direct callback
continuations, Task and timer behavior, filesystem and network
binary data, portable OS helpers, one-shot signals, child argv/environment/cwd,
retained exit status, binary stdio FIFO, continuous background stream reads,
sticky EOF and stream terminal tails, replaceable wait/read cancellation,
deadlock-free `communicate`, TERM-resistant shutdown, FIFO/close state
machines, path operations, failed-spawn and exit-before-close ordering,
observed helper failure, trace propagation, GC, sequential sessions,
standalone bootstrap, canonical installed DSOs, source-rock deployment, and
bundled/system libuv topology. Linux CI also rebuilds Lua, libbacktrace, libuv,
the Titan runtime, and standard modules under ASan/UBSan, then runs
representative timer/FS and core owner/callback suites plus production net/OS
smokes. Regular Linux runs the complete production behavior suites; the sole
isolated source variant delays selected FS callbacks to cover late
cancellation, disposal of a late successful open, and cross-generation
Runtime/File/Task/buffer/error rooting. The sanitizer net smoke specifically
keeps a large write pending across Task cancellation, unwind, and forced GC. Its
stack-use-after-return coverage relies on `minicoro.h` announcing every native
coroutine stack switch to the ASan fiber API, including tagged and stacked
terminal transfers. The main-stack fake-stack token, bottom, and size live in
the same GC-owned, module-local `mco_runtime` as the current-coroutine pointer,
so nested tagged transfers pair each sanitizer switch through one shared
runtime without registry lookups on coroutine hot paths.
In that mode minicoro retains its stack-corruption sentinel but leaves
address-range checking to ASan, because GCC's use-after-return instrumentation
can move an address-taken local onto the sanitizer fake stack.
