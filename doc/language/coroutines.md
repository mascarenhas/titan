# Coroutines

The `coroutine` module provides stackful asymmetric coroutines with tagged nested yields for generators and custom schedulers. Import it in Titan with `local coroutine = import "coroutine"` or load it in Lua with `require "titan.coroutine"` (Lua's own `require "coroutine"` remains unchanged).

**Target availability:** Native & Browser (full API on both targets; resuming and yielding are unavailable inside synchronous browser C callbacks — see [In a synchronous callback](#in-a-synchronous-callback)).

For high-level cooperative concurrency with an event loop, see [Concurrency: Tasks, Channels, and Threads](concurrency.md) and [Asynchronous I/O and tasks](async-io.md).

## Example

This program creates a Fibonacci generator coroutine and consumes seven values from it:

```titan
local coroutine = import "coroutine"
local io = import "io"

local function fibonacci(limit: value): value
  local count: integer = limit
  local prev = 0
  local curr = 1
  for _ = 1, count do
    coroutine.yield(prev, "fib")
    local next_val = prev + curr
    prev = curr
    curr = next_val
  end
  return nil
end

function main(args: {string}): integer
  local gen = coroutine.create(fibonacci, "fib")
  local sum = 0
  while gen:status() == "suspended" do
    local yielded = gen:resume(7)
    if yielded ~= nil then
      local n: integer = yielded
      sum = sum + n
    end
  end
  io.print("sum = " .. sum)
  return 0
end
```

## Core concepts

A `Coroutine` transfers control synchronously between caller and callee without an event loop or scheduler. `coroutine` is independent of Lua's standard coroutine library: Titan's `coroutine.yield` does not call `lua_yield`, and Lua's `coroutine.status` does not inspect Titan coroutines.

Every resume and yield carries a non-nil **tag** compared by raw equality (numeric equality for numbers, byte contents for strings, value for booleans, and identity for tables, userdata, threads, and functions, without invoking `__eq`). Tags allow nested coroutines to yield directly past intermediate frames to a matching outer handler.

Coroutine stacks are finite; deeply recursive coroutine bodies can overflow them.

## Creating, resuming, and yielding

```text
record Coroutine

function create(func: function (value): (value), default_tag: value): Coroutine
function running(): Coroutine?
function Coroutine:resume(arg: value, tag: value): value
function Coroutine:status(): string

function yield(arg: value, tag: value): value
function is_yieldable(tag: value): boolean
```

`Coroutine` is an opaque record. Payloads (`arg`, yielded values, and return values) are ordinary `value`s and may be `nil`. Tags must be non-nil.

- **`create(func, default_tag)`** creates a suspended coroutine that calls `func(arg)` on its first `resume`. Because omitted positional arguments default to `nil`, `default_tag` may be omitted when callers supply an explicit tag at `resume`/`error`/`transfer` time.
- **`Coroutine:resume(arg, tag)`** resumes a suspended coroutine with `arg`. When `tag` is non-nil it becomes the active tag for this resume; otherwise the coroutine's `default_tag` is used. If both are `nil`, `resume` raises in the caller.
- **`yield(arg, tag)`** transfers control to the nearest active resumer whose tag is raw-equal to `tag`, causing that resumer's `resume`, `error`, or `transfer` call to return `arg`. `tag` must be explicit and non-nil (default tags are not consulted). Calling `yield` outside a Titan coroutine raises.
- **`is_yieldable(tag)`** returns `true` if an active resumer in the current chain matches `tag` (requiring a non-nil `tag`), and `false` otherwise or outside a Titan coroutine.
- **`running()`** returns the innermost executing Titan `Coroutine`, or `nil` outside Titan coroutines. The returned handle is identical to the record returned by `create`.

```titan
local coroutine = import "coroutine"

function running_status(): string
  local co? = coroutine.running()
  if co == nil then return "none" end
  return co:status()
end
```

### Nested tagged yields

When `yield(arg, tag)` skips an immediate resumer to reach an outer resumer with a matching tag, the matching resumer returns `arg` and becomes `"suspended"`, while every skipped inner coroutine becomes `"stacked"`. Resuming that outer suspended coroutine restores the skipped chain and returns the resume payload from the inner `yield`:

```text
main resumes outer with tag "outer"
  outer resumes inner with tag "inner"
    inner yields "from-inner" to tag "outer"

main receives "from-inner"; outer is "suspended" and inner is "stacked".
main resumes outer again; outer and inner are restored and inner's yield returns.
```

```titan
local coroutine = import "coroutine"

function nested(): string
  local tag_outer = "outer"
  local tag_inner = "inner"

  local inner = coroutine.create(function (_)
    coroutine.yield("from-inner", tag_outer)
    return "inner-done"
  end, tag_inner)

  local outer = coroutine.create(function (_)
    local got: string = inner:resume("to-inner")
    return "outer:" .. got
  end, tag_outer)

  local first: string = outer:resume("start", tag_outer)
  local statuses = outer:status() .. "/" .. inner:status()
  local second: string = outer:resume("again", tag_outer)
  return first .. ":" .. statuses .. ":" .. second
end
```

Lua code uses the same API dynamically:

```lua
local coroutine = require "titan.coroutine"

local co = coroutine.create(function(arg)
  local next_val = coroutine.yield(arg, "io")
  return next_val
end, "io")

assert(co:resume("ready") == "ready")
assert(co:resume("done") == "done")
```

### Coroutine status

`Coroutine:status()` returns one of five strings:

| Status | Meaning |
| --- | --- |
| `"suspended"` | Resumable, either newly created or paused at `yield`. |
| `"running"` | Currently executing. |
| `"normal"` | Active and waiting on another coroutine it resumed. |
| `"stacked"` | Inside a skipped chain created by a tagged nested yield; restored when the matching outer `"suspended"` handler is resumed. |
| `"dead"` | Entry function returned, an uncaught error escaped, or an error was injected before the first resume. |

Calling `resume`, `error`, or `transfer` on any coroutine whose status is not `"suspended"` raises in the caller.

Lua code running inside a Titan coroutine can close its own Lua thread with Lua's `coroutine.close()` (no argument). That closes the thread's Lua to-be-closed variables and abandons the rest of the coroutine without running Titan `defer` statements; the coroutine ends `"dead"`, and its resumer returns `nil` (or raises a failing `__close` error). During an [abandoned unwind](#abandoned-coroutines), closing the thread lets the unwind continue instead, reports any `__close` error as a cleanup warning, and unwinds the resumer in turn. Cleanup running during an unwind must not close an enclosing genuine Lua coroutine.

## Injecting errors and non-raising transfer

```text
function Coroutine:error(err: value, tag: value): value
function Coroutine:transfer(payload: value, tag: value,
                            inject_error: boolean): (boolean, value, string?)
```

`Coroutine:error(err, tag)` resumes a suspended coroutine by raising `err` at its suspended `yield` site. If the coroutine catches `err`, execution continues normally; if `err` escapes (or if any other uncaught error escapes the body), the caller's `resume` or `error` re-raises `err` with the coroutine's traceback. Calling `error` before the first normal `resume` raises `err` immediately without entering the body.

```titan
local coroutine = import "coroutine"

local function guarded(arg: value): value
  coroutine.yield("ready", "step")
  return "missed"
catch
  local msg: string = error
  return "caught:" .. msg
end

function run_injected(): string
  local co = coroutine.create(guarded, "step")
  co:resume(nil)
  local result: string = co:error("cancelled")
  return result
end
```

`Coroutine:transfer(payload, tag, inject_error)` switches like `resume` when `inject_error` is `false` and like `error` when `inject_error` is `true` (pass `nil` for `tag` to use `default_tag`), but returns uncaught coroutine errors as data instead of raising:

| Outcome | Returned tuple |
| --- | --- |
| Coroutine yields or returns normally | `false, value, nil` |
| Uncaught error ends the coroutine | `true, error, traceback` |

The first result indicates failure, not completion; inspect `co:status()` to distinguish a yield from a normal return. Because `nil` and `false` are valid payloads and errors, always test the first result rather than the truthiness of the second. Raising `nil` delivers `"<no error object>"` (see [raising errors](error-handling.md#raising-errors)). The traceback string uses the same frame-only form as `catch`'s `traceback`; a successful transfer captures no traceback.

Misuse errors (missing tag, non-suspended coroutine, switching from a finalizer, or allocation/stack failure) still raise in the caller, and unwinding an abandoned coroutine remains uncatchable.

```titan
local coroutine = import "coroutine"

function run_step(co: coroutine.Coroutine, input: value): string
  local failed, _, trace? = co:transfer(input, nil, false)
  if failed then return "failed: " .. (trace or "") end
  if co:status() == "dead" then return "returned" end
  return "yielded"
end
```

## Abandoned coroutines

A suspended or stacked coroutine that becomes unreachable is **unwound** by the garbage collector before its stack is released; closing the Lua state unwinds every remaining suspended coroutine the same way.

Unwinding acts like an uncatchable error raised at the suspension point:

- Titan `defer` statements and generic-`for` close functions run innermost first.
- Lua to-be-closed variables (`local x <close>`) close with no error argument.
- `catch` blocks, `pcall`, `xpcall`, and Lua `coroutine.resume` do not intercept it.
- Any remainder of a `defer` body that was itself suspended is skipped.
- A tagged-yield chain unwinds from innermost coroutine outward, leaving every member `"dead"`.
- Genuine Lua coroutines active inside the Titan coroutine close after their own cleanup and become `"dead"`.
- A coroutine suspended inside a Lua `__close` handler during error handling still runs waiting `defer` statements and drops the original error.
- A module initializer suspended inside `require` runs its `defer` statements and leaves the module partially initialized, as after an initializer error.
- A never-started coroutine has no frames to unwind, and a coroutine running when its Lua state closes is not unwound.

Unwind cleanup executes inside a Lua finalizer and obeys the [finalizer rules](standard-library-gc.md#finalizers): it cannot yield, resume, or inject an error into a Titan coroutine (so any `async` wait raises), nor invoke the collector. Under ordinary collection, cleanup may run at any allocation point; at state close, objects created after the coroutine may already be finalized. Do not resurrect the coroutine handle (a resurrected handle reports `"dead"`).

Errors raised by `defer` or `__close` during unwinding are emitted as Lua warnings (`error in coroutine cleanup (<message>)`) and dropped so unwinding continues. Standalone Titan executables, `titanc --test` binaries, and [`lua.new()`](standard-library-lua.md) states enable warnings on stderr by default; the stock `lua` interpreter enables them with `-W` or `warn("@on")`.

Unfinished `async` Tasks unwind by the same mechanism at state close; see [closing a Lua state with an active Runtime](async-io.md#closing-a-lua-state-with-an-active-runtime).

### Cleanup that needs asynchronous I/O

Because unwinding runs in a finalizer and cannot await, it serves as last-resort resource reclamation rather than graceful protocol shutdown.

At Lua state close, native resources are still reclaimed: the `async` Runtime finalizer closes remaining loop handles, and standard-library owners whose ordinary `close()` awaits—[Files](standard-library-fs.md#closing-the-lua-state), [SQLite connections](standard-library-sqlite3.md#closing-the-lua-state), [TLS connections and servers](standard-library-ssl.md#closing-the-lua-state), and [independent Lua states running `run_async`](standard-library-lua.md#asynchronous-execution)—release native state synchronously so a `defer` calling `close()` succeeds during unwind. Native memory managed directly through the C FFI needs the matching [`abandoned` callback](async-io.md#foreign-work-at-state-close).

Graceful shutdown steps that require network round trips—such as TLS `close_notify`, WebSocket Close handshakes, or draining HTTP responses—must run before the state closes (for example, by waiting for `SIGINT` with [`os.wait_signal`](standard-library-os.md#waiting-for-a-signal) and signaling Tasks over channels).

### Unwinding limits

- **Structured entry:** Lua threads within one state may enter each other only through a resume (`coroutine.resume`, `coroutine.wrap`, or C `lua_resume`) or through protected calls on their own `lua_State`. C or FFI code that re-enters an active ancestor's `lua_State` directly with `lua_call`/`lua_pcall` violates this invariant and causes unwinding to abort with `titan: abandoned coroutine unwind: ...` (see [the built-in Lua state](ffi.md#the-built-in-lua-state) and [multiple Lua states](lua-interop.md#multiple-lua-states)).
- **Foreign C frames:** Native C frames between Titan and Lua frames are skipped, as during ordinary error propagation; resources owned solely by those C frames are not released.

## In a synchronous callback

On the browser target, C code can invoke Titan synchronously from a JavaScript event through [`titan_browser_call_sync`](standard-library-browser.md#synchronous-c-callbacks). Because no stack can suspend inside a synchronous callback:

- `Coroutine:resume`, `Coroutine:error`, `Coroutine:transfer`, and `coroutine.yield` raise `"coroutine.<op> is unavailable in a synchronous callback"` (catchable, leaving the coroutine unchanged).
- `coroutine.running()` returns `nil` and `coroutine.is_yieldable(tag)` returns `false`, even if the callback ran inside a binding invoked by a coroutine.
- `coroutine.create` succeeds, and the new coroutine may be resumed once the synchronous callback returns.
- An abandoned coroutine collected during a synchronous callback is deferred for re-finalization rather than unwound inline; the next collection outside a callback (or state close) unwinds it.
