# Coroutines

Titan's `coroutine` standard module provides stackful asymmetric coroutines
with tagged nested yield. It is intended as the low-level control-transfer
building block for schedulers and async I/O libraries; it does not provide
a scheduler by itself.

Titan code imports it normally:

```lua
local coroutine = import "coroutine"
```

Lua code can load the same module with `require "titan.coroutine"`.
This does not replace Lua's standard coroutine library:
`require "coroutine"` continues to return Lua's own table.

## API

```text
record Coroutine
end

function create(func: function (value): (value), default_tag: value): Coroutine
function running(): Coroutine?
function Coroutine:resume(arg: value, tag: value): value
function Coroutine:error(err: value, tag: value): value
function Coroutine:transfer(payload: value, tag: value,
                            inject_error: boolean): (boolean, value, string?)
function Coroutine:status(): string

function yield(arg: value, tag: value): value
function is_yieldable(tag: value): boolean
```

The `Coroutine` record is opaque. Its handle and default tag are private to
the `coroutine` module.

Titan's ordinary argument adjustment makes the second argument to
`create`, `resume`, and `error` optional in practice: omitting it passes
`nil`. `nil` means "no tag supplied" and is not a legal tag. `transfer` takes
the same tag in the middle position; pass `nil` explicitly to use the default.

Payloads are ordinary `value`s, so `arg`, `err`, yielded values, and
returned values may be `nil`. Tags must be non-nil.

## Currently Running Coroutine

`coroutine.running()` returns the currently executing Titan `Coroutine`, or
`nil` when no Titan coroutine is executing. It takes no arguments and returns
the same record as `create`, so the result can be compared by identity with a
saved handle and used with the ordinary `Coroutine` methods.

In nested resumes it returns the innermost executing coroutine. When that
coroutine yields, returns, or raises an uncaught error, it reports the caller's
active Titan coroutine, or `nil` if control has returned outside Titan
coroutines. A tagged yield that skips several coroutines follows the same
rule; resuming the suspended handler makes the restored innermost coroutine
current again.

```titan
local coroutine = import "coroutine"

function running_status(): string
    local co? = coroutine.running()
    if co == nil then return "none" end
    return co:status()  -- "running"
end
```

Lua code uses `require "titan.coroutine"` to call this function. It observes
Titan coroutines, independently of Lua's own `coroutine.running()`.

## Tags

`create(func, default_tag)` stores an optional default tag on the
coroutine. `co:resume(arg, tag)` and `co:error(err, tag)` use the
explicit tag when it is non-nil; otherwise they use the stored default
tag. If the effective tag is nil, they raise in the caller.

`coroutine.yield(arg, tag)` and `coroutine.is_yieldable(tag)` require an
explicit non-nil tag. They do not use a coroutine's default tag.

Tags compare by raw Lua/Titan equality. Numbers compare by Lua numeric
equality, strings by contents, booleans by value, and tables, userdata,
threads, and functions by identity. Tag comparison does not call `__eq`
metamethods.

## Resume And Yield

`create(func, default_tag)` creates a suspended coroutine. The first
successful `resume` calls `func(arg)` in that coroutine.

```titan
local coroutine = import "coroutine"

function body(arg: value): value
    local next = coroutine.yield(arg, "io")
    return next
end

function run(): string
    local co = coroutine.create(body, "io")
    local first = co:resume("ready")  -- "ready"; body is suspended at yield
    local done = co:resume("done")    -- "done"; body returns
    return (first as string) .. ":" .. (done as string)
end
```

`coroutine.yield(arg, tag)` transfers control to the nearest active
resumer whose tag is raw-equal to `tag`. That resumer's `resume` or
`error` call returns `arg`.

Calling `coroutine.yield` outside a Titan coroutine raises in the caller.

If the immediate resumer's tag does not match, Titan walks outward
through the active chain of resumes. The matching resumer is the
coroutine whose `resume` or `error` call returns to its own caller; it
becomes `"suspended"` and is resumable. The inner coroutines between that
resumer and the yielder become `"stacked"` until the resumer is resumed
and restores the skipped stack.

```titan
local coroutine = import "coroutine"

function nested(): string
    local tag_main: value = "main"
    local tag_a: value = "a"

    local b = coroutine.create(function (arg: value): value
        coroutine.yield("from-b", tag_main)
        return "b-done"
    end, tag_a)

    local a = coroutine.create(function (arg: value): value
        local got = b:resume("to-b")
        return "a:" .. (got as string)
    end, tag_main)

    local first = a:resume("start", tag_main)
    local statuses = a:status() .. "/" .. b:status()
    local second = a:resume("again", tag_main)
    return (first as string) .. ":" .. statuses .. ":" .. (second as string)
    -- "from-b:suspended/stacked:a:b-done"
end
```

```text
main resumes A with tag "main"
  A resumes B with tag "a"
    B yields "payload" to tag "main"

main receives "payload"; A is suspended and B is stacked.
main resumes A again; A and B are restored and B's yield returns.
```

`coroutine.is_yieldable(tag)` returns whether a yield with `tag` would
find a matching active resumer in the current chain. Outside a Titan
coroutine it returns `false`.

Lua code uses the same module dynamically:

```lua
local coroutine = require "titan.coroutine"

local co = coroutine.create(function(arg)
    local next_value = coroutine.yield(arg, "io")
    return next_value
end, "io")

assert(co:resume("ready") == "ready")
assert(co:resume("done") == "done")
```

## Errors

`co:error(err, tag)` resumes a coroutine by sending an error instead of
a successful value.

If the coroutine is suspended at a `coroutine.yield`, that yield raises
`err` at the yield site. The coroutine may catch it:

```titan
function body(arg: value): value
    do
        coroutine.yield("ready", "tag")
    catch
        return "caught:" .. (error as string)
    end
    return "missed"
end
```

If the injected error is uncaught, or if the coroutine body raises any
other uncaught error, the resuming `resume` or `error` call re-raises the
same error value in the caller while preserving the coroutine traceback.

Calling `co:error(err, tag)` before the first normal `resume` raises
`err` without calling the entry function.

## Non-raising transfer

`co:transfer(payload, tag, inject_error)` switches to the coroutine exactly as
`co:resume(payload, tag)` does when `inject_error` is `false`, and exactly as
`co:error(payload, tag)` does when it is `true`. Tags, tagged nested yield,
and injection before the first resume (which never calls the entry function)
behave the same. Only the way an uncaught error comes back differs:

| Outcome | Result |
| --- | --- |
| The coroutine yields or returns | `false, value, nil` |
| An uncaught error ends the coroutine | `true, error, traceback` |

The first result means **failed**; it is not a "dead" flag. Use `status()` to
tell a yield from a normal return. `nil` and `false` are ordinary values and
ordinary error values, so never infer the outcome from the truthiness of the
second result. Raising `nil` still delivers `"<no error object>"`, as in
[raising errors](error-handling.md#raising-errors).

The traceback is the one captured when the error escaped the coroutine body,
in the same frame-only form as a `catch` block's `traceback`. It is an
ordinary string owned by the caller; the next raising operation does not see
it. A caller that reports the failure can append its own propagation trace;
a caller that drops the failure pays for no extra capture. A successful
transfer captures no traceback and allocates no result object.

Everything else still raises in the caller: a missing tag, a coroutine that is
not suspended, a switch from a finalizer, and native, allocation, or stack
failures. Unwinding an abandoned coroutine stays uncatchable.

```titan
local coroutine = import "coroutine"

function run_step(co: coroutine.Coroutine, input: value): string
    local failed, _, trace? = co:transfer(input, nil, false)
    if failed then return "failed: " .. (trace or "") end
    if co:status() == "dead" then return "returned" end
    return "yielded"
end
```

## Status

`co:status()` returns:

| Status | Meaning |
| --- | --- |
| `"suspended"` | The coroutine is resumable, either new or stopped at `yield`. |
| `"running"` | The coroutine is currently executing. |
| `"normal"` | The coroutine is active and has resumed another coroutine. |
| `"stacked"` | The coroutine is inside a skipped chain created by a tagged nested yield; resuming the suspended matching handler restores the skipped stack. |
| `"dead"` | The entry function returned, an uncaught error escaped, or an error was injected before the entry function started. |

Calling `resume`, `error`, or `transfer` on a `running`, `normal`, `stacked`,
or `dead` coroutine raises in the caller. For a tagged nested yield, resume
the suspended handler that received the yield instead.

Titan coroutines are not Lua coroutines. The `yield` function on Titan's
imported `coroutine` module does not call `lua_yield`, and Lua's
`coroutine.status` does not describe these coroutines.

Lua code running inside a Titan coroutine can still close its own Lua thread
with Lua's `coroutine.close()` and no argument. Lua then closes that thread's
to-be-closed variables and abandons the rest of the coroutine without running
its Titan `defer` statements. The coroutine ends `"dead"`, and the `resume` or
`error` call that was running it returns nil, or raises the error of a failing
`__close`. If the coroutine was being [unwound](#abandoned-coroutines) when its
cleanup closed the thread, the unwind continues instead: the coroutine still
ends `"dead"`, an error from a `__close` becomes a cleanup warning, and its
resumer neither returns nor raises but unwinds in turn. Cleanup that runs
during an unwind must not close a genuine Lua coroutine it runs in: Lua then
returns from that coroutine's `coroutine.resume` or `coroutine.wrap` call, and
ordinary code after it runs inside the finalizer.

Coroutine stacks are finite. The current implementation uses large
virtual-memory-backed stacks, but deeply recursive coroutine bodies can
still overflow them. The `coroutine` module is a low-level
control-transfer primitive, not a scheduler or an async I/O policy by
itself.

## Abandoned Coroutines

A coroutine that is never resumed again does not leak its cleanup. When a
suspended or stacked coroutine becomes unreachable, the collector **unwinds**
it before its stack is released. Closing the Lua state does the same for every
suspended coroutine.

Unwinding behaves like an error that nothing can catch, raised at the point
where the coroutine stopped:

- `defer` statements and generic-`for` close functions run, innermost first;
- Lua to-be-closed variables (`local x <close>`) in Lua frames on the stack
  are closed, and their `__close` receives no error value;
- `catch` blocks do not run, and Lua `pcall`, `xpcall` and `coroutine.resume`
  do not return;
- the rest of a `defer` body that was itself suspended is skipped.

The coroutine then reports `"dead"`. Further rules:

- A tagged-yield chain is unwound from its innermost coroutine outward, and
  every member becomes `"dead"`.
- Genuine Lua coroutines running inside the coroutine (resumed with
  `coroutine.resume` or `coroutine.wrap`) are closed after their own cleanup
  and become `"dead"`.
- A coroutine that suspended inside a Lua `__close` method called while an
  error was being handled still runs the `defer` statements that were waiting
  for that error, and the error is dropped.
- A module initializer that suspended inside `require` runs its `defer`
  statements. The module stays partially initialized, as after an error in
  its initializer: a later `require` returns the same module without running
  the initializer again, and module variables keep the values they had when it
  suspended.
- A coroutine that never started has no frames, so nothing runs. A coroutine
  that is running when its Lua state closes (the state was closed from inside
  it) is not unwound.

Cleanup that runs during unwinding runs inside a Lua finalizer, so the
[finalizer rules](standard-library-gc.md#finalizers) apply: it cannot yield,
resume, or inject an error into a Titan coroutine, so every `async` wait
raises, and it cannot run the collector. In addition:

- under ordinary collection, cleanup runs at whatever allocation triggered the
  collection, inside unrelated code, so it must not assume any program state;
- at state close, objects created after the coroutine may already be
  finalized.

An error raised by a `defer` statement or by a `__close` metamethod is reported
as a Lua warning, `error in coroutine cleanup (<message>)`, and dropped. The
rest of the unwind continues, and later `__close` methods still receive no
error value. Lua states created with `luaL_newstate`, which include the states
of Titan standalone executables, `titanc --test` programs and
[`lua.new()`](standard-library-lua.md), start with warnings on and write them
to standard error. The stand-alone `lua` interpreter starts with them off;
enable them there with `-W`. Lua code can switch them with `warn("@on")` and
`warn("@off")`, and an embedding that installs its own `lua_setwarnf` function
decides where they go. Lua's general finalizer rules apply: cleanup must not
resurrect the coroutine for further use. A resurrected handle reports
`"dead"`.

When an `async` Runtime's Lua state closes, its unfinished Tasks are unwound
the same way; see
[closing a Lua state with an active Runtime](async-io.md#closing-a-lua-state-with-an-active-runtime).
That section also covers starting a Task from cleanup: it works during an
ordinary collection and raises while the state closes.

### Cleanup that needs asynchronous I/O

Unwinding is last-resort cleanup for resources tied to a scope. It cannot
await, so it cannot finish anything that needs another round trip.

Native resources are still released when the state closes. The Runtime's
finalizer closes the loop's remaining handles: sockets, pipes, timers,
watchers and process handles (see
[closing a Lua state with an active Runtime](async-io.md#closing-a-lua-state-with-an-active-runtime)).
Standard-library owners whose ordinary close needs a Task or the worker pool
release their native state synchronously instead:
[Files](standard-library-fs.md#closing-the-lua-state),
[SQLite connections](standard-library-sqlite3.md#closing-the-lua-state),
[TLS connections and servers](standard-library-ssl.md#closing-the-lua-state),
and [independent Lua states running `run_async`](standard-library-lua.md#asynchronous-execution).
A `defer` that closes one of them completes during the unwind instead of
raising. Native work that a worker is still running finishes first. What it
uses is then released, still during the state close, except that a File
whose read, write or flush was in flight keeps its descriptor until the
process exits ([details](standard-library-fs.md#closing-the-lua-state)).
Native memory that application code manages itself through the C FFI needs
the same care; see [`async.run_foreign`](async-io.md#foreign-work-at-state-close).

What is lost is graceful protocol shutdown that needs awaits, such as a TLS
`close_notify`, a WebSocket Close handshake, or draining an HTTP response.

An application that needs graceful shutdown arranges it before the state
closes. It keeps its Tasks reachable and running, waits for SIGINT with
[`os.wait_signal`](standard-library-os.md#waiting-for-a-signal), and uses its
own channels to tell its Tasks to wrap up. The runtime adds no mechanism for
this.

### Unwinding limits

- **Structured entry.** Lua threads of one state may enter one another only
  through a resume (Lua's `coroutine.resume` and `coroutine.wrap`, or
  `lua_resume` from C) or through protected calls on their own `lua_State`. C
  or FFI code that re-enters an active ancestor's `lua_State` with `lua_call`
  or `lua_pcall`, or runs another thread's code without a resume, breaks that
  rule. Unwinding such a coroutine aborts the process with
  `titan: abandoned coroutine unwind: ...`. See
  [the C FFI](ffi.md#the-built-in-lua-state) and
  [multiple Lua states](lua-interop.md#multiple-lua-states).
- **Foreign C frames.** Native C frames between Titan and Lua frames are
  skipped, as they are when an error propagates. Resources that only those
  frames own are not released.
- **Older modules.** The generated-code ABI does not record unwinding support,
  so modules compiled without it still load. Their `defer` statements do not
  run when a coroutine is abandoned, and their `catch` blocks are skipped as
  well. A coroutine library built without unwinding support never unwinds; see
  [mixed builds](../implementation/codegen-overview.md#compiled-module-abi).

## In a synchronous callback

On the browser target, C code can call Titan synchronously from a JavaScript
event, through
[`titan_browser_call_sync`](standard-library-browser.md#synchronous-c-callbacks).
No stack can suspend inside such a callback, so coroutines change behavior
there:

- `Coroutine:resume`, `Coroutine:error`, `Coroutine:transfer` and
  `coroutine.yield` raise `"coroutine.resume is unavailable in a synchronous
  callback"` (with `error`, `transfer` or `yield` in place of `resume`). The
  error can be caught in the callback, and the coroutine is left unchanged.
- `coroutine.running()` returns `nil` and `coroutine.is_yieldable(tag)` returns
  `false`, even when the callback runs inside a binding that a coroutine
  called.
- `coroutine.create` works. A coroutine created in a callback can be resumed
  after the callback returns.
- An abandoned coroutine that the collector finds during a callback is not
  unwound there. Unwinding would switch stacks, so the collector marks it to be
  finalized again instead. The next collection outside a callback unwinds it as
  described above, or the state close does. Until then the coroutine keeps its
  stack.
