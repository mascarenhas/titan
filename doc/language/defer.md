# Defer

`defer <statement>` is Titan's compact cleanup statement. It executes its statement when leaving the current block (whether by reaching the end of the block, or by break, return, or an exception).

```titan
function read_one(path: string): string
    local f = open_file(path)
    defer f:close()
    return f:read()
end
```

## What Counts As The Current Block

The current block is the statement list being parsed: a function body, a `do ... end` body, a loop body, an `if`/`elseif`/`else` arm, or a union `when`/`else` arm. In a loop, the deferred statement runs before that iteration leaves the loop body:

```titan
while more() do
    defer close_current_item()
    process_current_item()
end
```

Case arms are ordinary full blocks. A defer in one arm applies only when leaving that arm; it cannot capture declarations from or fall through to another arm. A payload binding is already in scope when the arm executes, so deferred cleanup may use it.

## Ordering

Multiple `defer` statements in the same block execute in last-in-first-out (LIFO) order:

```titan
defer first()
defer second()
work()
-- on exit: work(), second(), first()
```

This is true for normal fallthrough, `return`, `break`, and errors, including out-of-memory errors: reaching registered cleanup does not itself allocate, so a deferred statement that does not allocate still runs. If a deferred statement raises, including through a failed allocation, its error replaces the pending action, and enclosing `defer` and `catch` blocks still run.

A coroutine suspended inside the block also runs its deferred statements when it is abandoned: collected while suspended, or still suspended when its Lua state closes. That cleanup runs inside a Lua finalizer and cannot yield; see [abandoned coroutines](coroutines.md#abandoned-coroutines).

Return expressions are evaluated before cleanup runs. For example, this returns `"body"` even though the deferred statement mutates `log` before control reaches the caller:

```titan
function f(): string
    local log = "body"
    defer log = log .. ":cleanup"
    return log
end
```

## Scope

The deferred statement is checked where the `defer` appears. It can use locals that are already in scope, and it cannot use locals declared later in the rest of the block:

```titan
local n = 1
defer use(n)       -- ok
local later = 2
```

```titan
defer use(later)   -- compile-time error
local later = 2
```

In a `repeat ... until` loop, the `until` condition still has Titan's normal repeat-loop scope: it can see locals declared in the body after the `defer`.

## Multiple Cleanup Statements

The grammar accepts exactly one statement after `defer`. Use a `do` block when cleanup needs several statements:

```titan
defer do
    flush()
    close()
end
```

A `defer` may not directly defer another `defer` statement. Write the two defers separately:

```titan
defer first()
defer second()
```

## Control Flow In Cleanup

A deferred statement has the following control-flow restrictions:

* `return` inside the deferred statement is a compile-time error.
* `break` inside the deferred statement is a compile-time error if it would break a loop outside that deferred statement.
* `raise <exp>` is allowed and overrides any pending fallthrough, return, break, or error.
