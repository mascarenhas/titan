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
function Coroutine:status(): string

function yield(arg: value, tag: value): value
function is_yieldable(tag: value): boolean
```

The `Coroutine` record is opaque. Its handle and default tag are private to
the `coroutine` module.

Titan's ordinary argument adjustment makes the second argument to
`create`, `resume`, and `error` optional in practice: omitting it passes
`nil`. `nil` means "no tag supplied" and is not a legal tag.

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

## Status

`co:status()` returns:

| Status | Meaning |
| --- | --- |
| `"suspended"` | The coroutine is resumable, either new or stopped at `yield`. |
| `"running"` | The coroutine is currently executing. |
| `"normal"` | The coroutine is active and has resumed another coroutine. |
| `"stacked"` | The coroutine is inside a skipped chain created by a tagged nested yield; resuming the suspended matching handler restores the skipped stack. |
| `"dead"` | The entry function returned, an uncaught error escaped, or an error was injected before the entry function started. |

Calling `resume` or `error` on a `running`, `normal`, `stacked`, or
`dead` coroutine raises in the caller. For a tagged nested yield, resume
the suspended handler that received the yield instead.

Titan coroutines are not Lua coroutines. The `yield` function on Titan's
imported `coroutine` module does not call `lua_yield`, and Lua's
`coroutine.status` does not describe these coroutines.

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
- A coroutine that never started has no frames, so nothing runs. A coroutine
  that is running when its Lua state closes (the state was closed from inside
  it) is not unwound.

Cleanup that runs during unwinding runs inside a Lua finalizer, so:

- `coroutine.yield` raises `cannot yield from a finalizer`;
- `resume` and `error` raise `cannot resume a coroutine from a finalizer`;
- `is_yieldable()` returns `false`;
- the collector is stopped: `gc.collect` raises and `collectgarbage` returns
  fail;
- under ordinary collection, cleanup runs at whatever allocation triggered the
  collection, inside unrelated code, so it must not assume any program state;
- at state close, objects created after the coroutine may already be
  finalized, and `gc.finalizable` registrations are ignored.

An error raised by a `defer` statement or by a `__close` metamethod is reported
as a Lua warning, `error in coroutine cleanup (<message>)`, and dropped. The
rest of the unwind continues, and later `__close` methods still receive no
error value. Warnings are off by default in the stand-alone `lua`
interpreter; enable them with `-W` or `warn("@on")`. Lua's general finalizer
rules apply: cleanup must not resurrect the coroutine for further use. A
resurrected handle reports `"dead"`.

Cleanup that must also run at state close has to be synchronous. A `defer` can
hand slower disposal to `async.run` only while an ordinary collection unwinds
the coroutine and an `async` Runtime is active; the new Task then runs after
the rest of the unwind. While the Lua state closes, `async.run` raises
`cannot start a Task during Lua state close`, which the unwind reports as a
cleanup warning.

When an `async` Runtime's Lua state closes, its unfinished Tasks are unwound
the same way; see
[closing a Lua state with an active Runtime](async-io.md#closing-a-lua-state-with-an-active-runtime).
