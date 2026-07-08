# Coroutines

Titan's `coro` standard module provides stackful asymmetric coroutines
with tagged nested yield. It is intended as the low-level control-transfer
building block for schedulers and async I/O libraries; it does not provide
a scheduler by itself.

Titan code imports it normally:

```lua
local coro = import "coro"
```

Lua code can load the same module with `require "coro"`.

## API

```lua
record Coro
end

function create(func: (value) -> value, default_tag: value): Coro
function Coro:resume(arg: value, tag: value): value
function Coro:error(err: value, tag: value): value
function Coro:status(): string

function yield(arg: value, tag: value): value
function is_yieldable(tag: value): boolean
```

The `Coro` record is opaque. Its handle and default tag are private to
the `coro` module.

Titan's ordinary argument adjustment makes the second argument to
`create`, `resume`, and `error` optional in practice: omitting it passes
`nil`. `nil` means "no tag supplied" and is not a legal tag.

Payloads are ordinary `value`s, so `arg`, `err`, yielded values, and
returned values may be `nil`. Tags must be non-nil.

## Tags

`create(func, default_tag)` stores an optional default tag on the
coroutine. `co:resume(arg, tag)` and `co:error(err, tag)` use the
explicit tag when it is non-nil; otherwise they use the stored default
tag. If the effective tag is nil, they raise in the caller.

`coro.yield(arg, tag)` and `coro.is_yieldable(tag)` require an explicit
non-nil tag. They do not use a coroutine's default tag.

Tags compare by raw Lua/Titan equality. Numbers compare by Lua numeric
equality, strings by contents, booleans by value, and tables, userdata,
threads, and functions by identity. Tag comparison does not call `__eq`
metamethods.

## Resume And Yield

`create(func, default_tag)` creates a suspended coroutine. The first
successful `resume` calls `func(arg)` on the coroutine's Lua thread.

```lua
local coro = import "coro"

function body(arg: value): value
    local next = coro.yield(arg, "io")
    return next
end

function run(): string
    local co = coro.create(body, "io")
    local first = co:resume("ready")  -- "ready"; body is suspended at yield
    local done = co:resume("done")    -- "done"; body returns
    return (first as string) .. ":" .. (done as string)
end
```

`coro.yield(arg, tag)` transfers control to the nearest active resumer
whose tag is raw-equal to `tag`. That resumer's `resume` or `error` call
returns `arg`.

Calling `coro.yield` outside a Titan coroutine raises in the caller.

If the immediate resumer's tag does not match, Titan walks outward
through the dynamic resume chain. The matching handler is the coroutine
whose `resume` or `error` call returns to its own caller; it becomes
`"suspended"` and is resumable. The inner coroutines between that
handler and the yielder become `"stacked"` until the handler is resumed
and restores the skipped stack.

```text
main resumes A with tag "main"
  A resumes B with tag "a"
    B yields "payload" to tag "main"

main receives "payload"; A is suspended and B is stacked.
main resumes A again; A and B are restored and B's yield returns.
```

`coro.is_yieldable(tag)` returns whether a yield with `tag` would find a
matching active handler in the current dynamic chain. Outside a Titan
coroutine it returns `false`.

## Errors

`co:error(err, tag)` resumes a coroutine by sending an error instead of
a successful value.

If the coroutine is suspended at a `coro.yield`, that yield raises `err`
at the yield site. The coroutine may catch it:

```lua
function body(arg: value): value
    do
        coro.yield("ready", "tag")
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

Titan coroutines are not Lua coroutines. `coro.yield` does not call
`lua_yield`, and Lua's `coroutine.status` does not describe these
coroutines.
