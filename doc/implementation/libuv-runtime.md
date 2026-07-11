# Libuv continuation runtime

The asynchronous standard library has one low-level owner:

```text
coroutine.so -> uv.so
                 |-> timer.so
                 `-> fs.so
```

`uv.so` links `titan_uv.o` and the selected libuv exactly once. `timer.so` and
`fs.so` import the canonical binary `uv.so` with `loadstdlib`; they do not
compile `uv.titan`, link `titan_uv.o`, or embed another libuv archive. The Lua
aliases `titan/uv.so`, `titan/timer.so`, and `titan/fs.so` are relative symlinks
to the canonical images. Bundled and system acquisition, including Linux and
macOS packages, is documented in the [README](../../README.md#libuv-setup).

## GC-owned native storage

Every loop, timer, filesystem request, I/O buffer, `uv_buf_t`, and scandir
entry used by the runtime is allocated in Lua full-userdata payload bytes. The
Titan source uses the imported foreign type's `uv.<type>.sizeof` and
`.alignof`, captures the storage userdata once, and stores the resulting
pointer in a local field of an opaque record:

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

Each callback owner has eight stable record/uservalue slots: native pointer,
storage, main Lua thread, module Udata, dispatcher closure, Task/resource root,
operation metadata, and an additional buffer/resource root. The C shim uses
the corresponding zero-based indices.

## Runtime and continuation graph

One `uv` module instance owns one private coroutine tag and at most one active
Runtime. A Runtime contains a Titan-owned private `uv_loop_t`, the main Lua
thread, separate linked lists for timer owners, pending filesystem requests,
persistent Files, and Tasks, the currently running Task, and the first fatal
error/trace. The lists reflect different terminal events: handle close,
request callback plus cleanup, descriptor close request, and coroutine
completion. Sequential sessions reuse the tag but allocate a fresh loop and
generation.

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

## Direct native callback boundary

`titan-runtime/titan_uv.c` recovers a rooted timer or filesystem owner through
public libuv data accessors, reads its main-thread/module/dispatcher slots,
obtains the native Titan function pointer, and calls:

```c
dispatch(L, M, NULL, owner, event_kind, result, size);
```

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

Normal and fatal shutdown close remaining timer owners, enqueue internal closes
for every persistent File, and repeatedly run the loop only from the outer
driver. It repairs late successful opens and drains all filesystem request
callbacks and cleanups. Normally it continues until the timer, request, and
File root lists are empty. If bounded descriptor-close retries are exhausted,
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

The focused suites cover source and binary interfaces, native timer/FS owner
layout, direct callbacks, callback depth/main-thread dispatch, Task and timer
behavior, filesystem modes and binary data, File FIFO/close, path operations,
pre-submission allocation and bounded-close faults, request
cleanup/cancellation faults, trace propagation, GC, sequential sessions,
standalone bootstrap, canonical aliases, LuaRocks ownership, and bundled/system
libuv topology. Linux CI also rebuilds Lua, libbacktrace, libuv, the Titan
runtime, standard modules, and isolated fault variants under ASan/UBSan. Its
stack-use-after-return coverage relies on `minicoro.h` announcing every native
coroutine stack switch to the ASan fiber API, including tagged and stacked
terminal transfers. In that mode minicoro retains its stack-corruption sentinel
but leaves address-range checking to ASan, because GCC's use-after-return
instrumentation can move an address-taken local onto the sanitizer fake stack.
