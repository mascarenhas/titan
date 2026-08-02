# Libuv simplification discussion

## Maintainer comment

What might have led you into a rabbit hole with the file issue is that I think a previous instance of yourself has severely overengineered the uv module, perhaps mistakenly trying to handle in uv module code things that libuv is already doing, or that are not issues with libuv's cooperative callback model (a libuv callback will not fire in the middle of another callback's execution unless the other callback deliberately pumps the event loop).

After the current goal is done I think it is worth it scoping a radical simplification of the low-level uv module, to go with a design more in line with what I had suggested at the beginning, where the coroutines are just a think wrapper around the callbacks to make them look like synchronous calls:

For libuv functions with one-shot callbacks:

1. Every libuv function that takes a one-shot callback that is meant to be called from a uv task gets turned into a pseudo-synchronous uv function that yields with a payload union with the libuv function to call as a variant and the parameters
2. The uv module in the main thread stores the coroutine in the data passed to the libuv function it is calling, then calls it; the uv module itelf should be running inside a libuv one-shot callback, so it just returns from this callback so control goes back to the libuv event loop
3. When a single-shot libuv callback function fires, it is certain to have a waiting coroutine in its data, and the callback handler resumes this coroutine, on a return from resume see 2

This pump is primed by the first timer_cb set on the `run` function of the main task. Then it is "libuv calls callback -> callback resumes coroutine -> resume returns with union encoding another call to a libuv function -> call function with a callback that will wake up coroutine and return" for every turn of the event loop.

For libuv functions with multi-shot callbacks (period timers, stream reads) it is a bit different, because the callback might not have a coroutine waiting, in that case it just appends the result to a buffer (for stream reads) or replaces the previous result with the current one (for timers), and returns to the event loop. At some point a task will read from an stream with an empty buffer, or wait for a timer that has not fired yet, and then a coroutine will be associated with that callback's handle.

That's it. If task A does, let's say, a socket write, and then is suspended until the callback for that write fires, and in the meantime another task tries to write to the same socket, uv does another write request to libuv this time with the other coroutine in the request data, and let libuv sort out the queueing. This is no different than a pure callback implementation where the code does a write request and while waiting for the callback for that to fire some other callback fires and the code executing for that callback does another write request.

For some uv functions that still use callbacks but are meant to be called from the main thread (because they are low-level, like the alloc_cb ones) the coroutine wrappers are not even needed; the uv module in the main thread calls them with the callback and then return to the event loop, and the callback will continue the operation.

Titan has closures, records, unions, a lot of high-level machinery where this binding to libuv should be very concise, without needing to basically reimplement a lot of what libuv is already doing.

## Response

Yes—this sounds like the right organizing model. The likely rabbit hole was treating callback arrival as if it were preemptive concurrency, then building ownership, generation, locking, and “late callback” machinery around hazards that cannot occur unless code explicitly re-enters `uv_run`.

The simplified design should rest on one invariant:

> Outside deliberate event-loop re-entry, Titan code runs only as the continuation of the current libuv callback. It submits the next operation and returns control to libuv.

That naturally produces three small mechanisms:

- One-shot requests: a request record owns the `uv_req_t`, arguments that must remain alive, and exactly one suspended coroutine. Completion resumes it.
- Multi-shot handles: a handle owns buffered state plus at most one waiting consumer. A callback either satisfies that waiter or updates the buffer/latest event.
- Direct callbacks: low-level callbacks such as allocation and stream plumbing operate directly on handle state without pretending to be synchronous task calls.

Multiple writes do not need a Titan queue. Each `uv_write_t` carries its own coroutine, and libuv owns ordering and completion. Titan only needs to keep each request and its buffers alive until its callback.

The few contracts that must be made explicit before rewriting are:

- A successful one-shot submission must produce exactly one callback; a synchronous negative return must resume the coroutine immediately because no callback will follow.
- Cancellation must leave the suspended coroutine/request alive until the terminal callback. It should change the eventual result, not manufacture a separate callback-lifetime system.
- Runtime shutdown must drain or close every submitted request/handle before releasing the Lua state. With that invariant, “callbacks from an old Runtime generation” should not require pervasive defensive machinery.
- Stream reads and repeating timers need a clear single-waiter rule. If concurrent readers are unsupported, reject the second waiter instead of constructing another scheduler.
- No callback or continuation may invoke `uv_run`; that keeps the entire non-reentrancy argument true.

When this is scoped, I would inventory every low-level operation into those three categories, define the small yield/request union and completion protocol first, and then identify machinery that becomes removable. Timer, filesystem operation, socket write, and stream read would make a good representative vertical slice. The public `async`, `timer`, `fs`, `net`, and `os` APIs should largely remain unchanged; the simplification belongs beneath them.

## Maintainer additional notes

Scrap the existing design and code of the uv module, including the tests, start from scratch.

Use a union for the payload of te "calls" a task makes to the uv module via `coroutine.yield`, each variant represents a function call that normally would take a callback, with a record as the variant payload with the function parameters. The suspended coroutine acts as the callback. A nil payload means the task is finished. An uncaught error in a task should print the stack trace to stderr (and the task is considered as finished) but not start a shutdown unless there are no more active tasks. Any cleanup of handles the task opened but not close will be done in the final shutdown (see below).

When resuming a task the payload is a record with the parameters that would be passed to the callback.

Do not keep linked lists of handles, libuv keeps this, the only reason to go through active handles is to close them because the runtime is getting shut down, in this case the uv module can spawn a special task that is going to call `uv_walk`, like any function with multi-shot callbacks the `uv_walk` callback should accumulate the handles it gets in a buffer, and the task drains this buffer in a loop (suspending if the buffer is empty). The task calls `uv_close` on each handle; `uv_close` is just like any other single-shot callback function, so it suspends the close task normally. While this is going on the main event loop should still be running as it is necessary to pump these callbacks, but all functions that create new handles should fail.

A variant of the yield payload should signal to the uv module that the close task has finished the walk and cleanup of the handles, the close task returns this from its main function (remember that when a coroutine finally returns from its entry point this is the payload of the resume call, so it is like a yield). This is the signal that the uv module in the main coroutine should finish the clean up.

You can leave out the capability of a task to "join" another task (wait until it finishes) out of this iteration, the high-level stdlib io modules do not need that. Once the initial simplified design is laid out we can come back to this.
