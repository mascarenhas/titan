# Errors and Resource Cleanup

Titan separates ordinary absence from exceptional failure. Use [option types](types.md#option-types-t) (`T?`) for routine "not found" or end-of-stream outcomes, and use `raise`, `defer`, and `catch` for exceptional errors and deterministic resource cleanup.

```titan
local fs = import "fs"

function find_index(values: const? { integer }, wanted: integer): integer?
    for i = 1, #values do
        if values[i] == wanted then
            return i
        end
    end
    return nil
end

function first_line_or_empty(path: string): string
    local file = fs.open(path, "r")
    defer file:close()
    return file:read_until("\n", true) or ""
catch
    return ""
end
```

In `find_index`, a missing element is an expected result and returns `nil`. In `first_line_or_empty`, failing to open or read the file raises a runtime error, `defer file:close()` releases the handle if `fs.open` succeeded, and `catch` recovers with `""`.

## Compile-time and runtime errors

`titanc` reports **compile-time errors** before generating code, using a colon after `type error`:

```text
app.titan:3:11: type error: types in declaration of local variable x do not match, expected integer but found string
```

**Runtime errors** occur while compiled code runs and unwind through both Titan and Lua frames using Lua's standard error mechanism. Runtime type errors carry a source location and use a comma after `type error`:

```text
app.titan:2:1: type error, expected integer but found string
```

## Resource cleanup with `defer`

`defer <statement>` schedules a cleanup statement to run when execution leaves the **current block**—whether by normal fallthrough, `return`, `break`, or a runtime error. Acquire a resource, then defer its release on the very next line:

```titan
local fs = import "fs"

function read_chunk(path: string): string?
    local file = fs.open(path, "r")
    defer file:close()
    return file:read()
end
```

### Block scope and LIFO order

The "current block" is the enclosing statement list: a function or lambda body, a `do ... end` block, a loop body, an `if`/`elseif`/`else` arm, or a union `case` arm. Inside a loop, each `defer` runs at the end of that iteration—not when the entire function exits.

Multiple `defer` statements in one block run in **last-in, first-out (LIFO)** order. Return expressions are evaluated and saved **before** any deferred statements execute:

```titan
function defer_order(log: {string}): integer
    log[#log + 1] = "body"
    defer log[#log + 1] = "first"
    defer log[#log + 1] = "second"
    return #log -- returns 1; `log` then becomes {"body", "second", "first"}
end
```

### Scope, compound cleanup, and control flow

- **Registration-point scope:** A deferred statement is checked where the `defer` appears. It can access locals already in scope (including union `case` arm bindings), but cannot refer to locals declared later in the same block. (In a `repeat ... until` loop, the `until` condition still sees locals declared after a `defer`.)
- **Multiple statements:** `defer` accepts one statement. Wrap multi-statement cleanup in `defer do ... end`. You cannot defer another `defer` directly; write two separate `defer` statements instead.

```titan
function with_hooks(flush: function (): (), finish: function (): (), work: function (): ())
    defer do
        flush()
        finish()
    end
    work()
end
```

- **Control flow inside `defer`:** `return` inside a deferred statement is a compile-time error, as is a `break` targeting a loop outside the `defer`. `raise` is permitted: an error raised during cleanup replaces the pending fallthrough, `return`, `break`, or earlier error, while outer `defer` and `catch` blocks still run.
- **Memory exhaustion and abandoned coroutines:** Entering a registered `defer` allocates no memory, so non-allocating cleanup still runs after `"not enough memory"`. If a suspended coroutine is garbage-collected or still suspended when its Lua state closes, its `defer` statements run inside a Lua finalizer where yielding raises and `catch` blocks do not run (see [Coroutines](coroutines.md#abandoned-coroutines)).

## Raising errors

`raise <expr>` converts `<expr>` to `value` and raises an ordinary Lua error. Any Titan value—strings, numbers, records, unions, containers, or `false`—can be raised:

```titan
record ParseError
    line: integer
    message: string
end

function fail_parse(line: integer, msg: string)
    raise ParseError(line, msg)
end
```

Lua 5.5 normalizes a raised `nil` error object to the string `"<no error object>"`; every other raised value, including `false`, arrives unchanged in `catch` and Lua `pcall`.

### Re-raising with bare `raise`

Inside a `catch` block, a bare `raise` rethrows the original caught error **and preserves its original traceback** instead of replacing it with a shallower trace at the `catch` site:

```titan
local io = import "io"

function checked_divide(a: integer, b: integer): integer
    return a // b
catch
    io.print("division failed:\n" .. traceback)
    raise
end
```

Using bare `raise` outside a `catch` block is a compile-time error.

### Raising with a saved trace

When code catches an error to rethrow it later or on another task, pass the saved traceback string as a second expression: `raise <expr>, <trace>`. The value expression evaluates before the trace expression:

```titan
record Failure
    err: value
    trace: string
end

local pending: Failure? = nil

function capture(work: function (): ())
    work()
catch
    pending = Failure(error, traceback)
end

function rethrow_pending()
    local failure? = pending
    pending = nil
    if failure ~= nil then
        raise failure.err, failure.trace
    end
end
```

A downstream `catch` observes the supplied string as its `traceback`, and `titan.backtrace()` returns it if the error reaches Lua.

## Handling errors with `catch`

Titan has no `try` keyword and no `finally` clause (use `defer` for cleanup). Instead, `catch` attaches directly as a trailer on any existing block—function or lambda bodies, loop bodies, `if`/`elseif`/`else` arms, union `when`/`else` arms, the root module initializer, or an explicit `do ... end`:

```titan
function safe_quotient(a: integer, b: integer): integer?
    return a // b
catch
    return nil
end
```

Do not add an extra `do ... end` solely to attach `catch`; add a nested `do ... end` only when you want a narrower protected region.

Inside `catch`, two implicit read-only locals are in scope:

- `error: value` — the raised error object.
- `traceback: string` — the raw unified Titan/Lua stack trace captured at the failure site (frame lines only, with no error message, no `stack traceback:` header, and no tab indentation).

Assigning to `error` or `traceback` is a compile-time error.

The protected body and its `catch` clause are **sibling scopes**: locals declared inside the body are not visible in `catch`, because the body may have failed before initializing them. (In a union `case` arm, variant payload bindings are established before the arm's protected block and remain visible in that arm's `catch`.)

```text
do
    local tmp = compute()
    risky(tmp)
catch
    -- compile error if you reference `tmp` here
    log(traceback)
end
```

If `catch` finishes normally, the error is handled and execution continues after the construct. Entering `catch` does not allocate memory, so recovery still runs after an out-of-memory error (in which case `traceback` may be empty if trace capture could not allocate).

## Lua `pcall`/`xpcall`, standalone errors, and `titan.backtrace()`

Titan errors and Lua errors use the same unwinding mechanism. Lua code catches Titan errors with `pcall` or `xpcall`, and Titan `catch` blocks catch errors raised by Lua functions:

```lua
local titan = require "titan"
local app = require "app"

local ok, err = pcall(app.checked_divide, 10, 0)
if not ok then
    print("failed:", err)
    print(titan.backtrace())
end
```

### `titan.backtrace()`

In Lua, `require("titan").backtrace()` returns the raw unified Titan/Lua traceback for the most recent uncaught or re-propagated Titan error in the current Lua state.

- Frames appear innermost-to-outermost, interleaving Titan frames (`mod.func`, `mod.Record:method`, `mod.Record.static`, `anonymous function at mod.titan:12`) and Lua frames, with `.titan` filenames and line numbers when debug information is present.
- Catching and handling an error in Titan clears the stored trace; a bare `raise` or `raise err, trace` pins the original trace for outer handlers; a fresh `raise err` captures a new trace.
- On the browser target, unified traces come from the `<stem>.wasm.trace` file served alongside `<stem>.wasm` (see [WebAssembly and the Browser Target](browser-target.md)).

### Standalone executable errors

When an uncaught error escapes `main` in a standalone executable, Titan prints `<progname>: <message>`, `stack traceback:`, and the tab-indented unified frames through `main`, then exits with a non-zero status. Error messages print string bytes directly, format numbers using Lua formatting (keeping `.0` on integral floats), call a string-returning `__tostring` metamethod if present, or fall back to `(error object is a <type> value)`.

### Common runtime errors

Besides explicit `raise`, Titan raises runtime errors when a dynamic boundary or partial operation fails:

| Cause | Error message shape |
| --- | --- |
| Wrong argument type from Lua | `FILE:LINE:COL: type error, expected T but found U` |
| Failed `value` projection or `as` cast | `FILE:LINE:COL: type error, expected T but found U` |
| `nil` option unwrap | `FILE:LINE:COL: type error, expected T but found nil` |
| Strict Array/Map element read mismatch | `FILE:LINE:COL: type error, expected T but found U` |
| Float-to-integer narrowing failure | `type error, number 'N' has no integer representation` |
| Integer `//` or `%` by zero | `error at line LINE, divide by zero` / `% by zero` |
| More than 200 variadic args or flexible results | `too many variadic arguments ... (N, max 200)` / `too many flexible return values (max 200)` |
| Unknown record, union, or module member from Lua | `field 'NAME' not found ...` / `member 'NAME' ...` |
