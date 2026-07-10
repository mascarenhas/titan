# Libuv continuation runtime

The asynchronous standard library has one low-level owner:

```text
coroutine.so -> uv.so -> timer.so
```

`uv.so` links `titan_uv.o` and the selected libuv exactly once.
`timer.so` imports the canonical binary `uv.so` with `loadstdlib`; it does
not compile `uv.titan`, link `titan_uv.o`, or embed another libuv archive.
The Lua aliases `titan/uv.so` and `titan/timer.so` are relative symlinks to
the canonical images. Bundled and system acquisition, including Linux and
macOS packages, is documented in the [README](../../README.md).

## GC-owned native storage

Every loop and timer struct is allocated in Lua full-userdata payload bytes.
The Titan source uses the imported foreign type's
`uv.<type>.sizeof` and `.alignof`, captures the storage userdata once, and
stores the resulting pointer in a local field of an opaque record:

```titan
record uv_timer_t
  local handle: *uv.uv_timer_t
  local storage: value
  -- six more local owner fields
end
```

The native pointer is never converted through `value`. The wrapper is
allocated once, Titan's nominal/local-field rules prevent external forgery,
and later calls read the exact pointer field without pointer-boxing
allocations. The Runtime roots the wrapper until the close callback; the
wrapper roots the storage userdata. An initialized handle is never released by
a GC finalizer before its close callback.

Each callback owner has eight stable record/uservalue slots: native pointer,
storage, main Lua thread, module Udata, dispatcher closure, Task/resource root,
operation metadata, and an additional buffer/resource root. The C shim uses
the corresponding zero-based indices.

## Runtime and continuation graph

One `uv` module instance owns one private coroutine tag and at most one active
Runtime. A Runtime contains a Titan-owned private `uv_loop_t`, the main Lua
thread, linked Task and native-owner graphs, the currently running Task, and
the first fatal error/trace. Sequential sessions reuse the tag but allocate a
fresh loop and generation.

`uv.run` constructs a Task and arms a zero timer; it never resumes the Task.
A callback drives the root coroutine until it finishes or yields a private
Request with the shared tag. The dispatcher validates the Task epoch and
either registers the new owner or iteratively injects an immediate submission
error. Consecutive immediate failures are bounded and deferred through a
zero timer so one callback cannot spin indefinitely.

Joiners are linked to the target and woken by independent zero-timer callbacks.
An observer count is acquired only while a join is pending. Observation becomes
permanent when the join-wake callback actually delivers the result;
cancellation before delivery revokes the claim and lets an otherwise-unobserved
failure be promoted on its next turn. Target and join-site tracebacks are staged
and combined when a failed join propagates.

## Direct native callback boundary

`titan-runtime/titan_uv.c` recovers the rooted owner through public libuv data
accessors, reads its main-thread/module/dispatcher slots, obtains the native
Titan function pointer, and calls:

```c
dispatch(L, M, NULL, owner, event_kind, result, size);
```

There is no `lua_pcall`, Lua entry wrapper, or VM generic-call path around
this call. The dispatcher is trusted library code. Its function-level trailing
Titan `catch` records a Runtime-fatal error and trace, calls `uv_stop`, and
returns normally to the C trampoline. For a function-scope catch, code
generation installs that catch's jump target before the entry GC check; the
loop driver reserves `LUA_MINSTACK` first, so emergency-GC and stack-preparation
failures cannot unwind through libuv. This remains the native Titan entry, not
a C protected call. The inner Task drive has its own catch to classify ordinary
Task failure/cancellation without turning it into a broken dispatcher.

Application code intentionally runs in the libuv callback until its next
asynchronous yield. Neither the dispatcher nor any callback invokes
`uv_run`; only `uv.loop` or the standalone bootstrap drives the loop from
the outer main-thread boundary.

## Cancellation and shutdown

Cancellation sets the first reason and advances the Task epoch synchronously.
A zero-timer callback injects `Cancelled`; if even that timer submission
fails, the outer loop driver performs the injection at a callback-free safe
point. Ordinary awaits remain sticky-cancelled. Library-owned cleanup can use
the private cleanup-shield state so physical teardown finishes before
cancellation is reinjected.

Normal and fatal shutdown close remaining timer owners, repeatedly run the
loop only from the outer driver, retire owners whose close bookkeeping failed
after libuv marked them closed, and continue until the Runtime-owned graph is
empty. `uv_loop_close` then releases the loop-storage root. An unexpected
`UV_EBUSY` uses public `uv_walk` and handle-type accessors to report the
remaining count/type rather than hanging on an unknown active handle; the busy
loop root is preserved rather than risking native use-after-free.

## Bootstrap and tests

Module initialization installs an idempotent registry bootstrap. The generated
standalone entrypoint loads imports first, then calls that hook under its
existing outer protected entry. Programs without the hook retain direct
synchronous `main`.

The focused suites cover source and binary interfaces, native timer/FS owner
layout, direct callbacks, callback depth/main-thread dispatch, Task and timer
behavior, trace propagation, cancellation races, GC, sequential sessions,
isolated fault variants, standalone bootstrap, canonical aliases, LuaRocks
ownership, and bundled/system libuv topology.
