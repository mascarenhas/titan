# Defer

`defer <statement>` is Titan's compact cleanup form. It schedules one
statement to run when the rest of the current statement-list exits.

```lua
function read_one(path: string): string
    local f = open_file(path)
    defer f:close()
    return f:read()
end
```

The exact model is a source-level transformation. A `defer` wraps the
rest of the `simpleblock` it appears in with a `finally`:

```lua
defer cleanup()
body()
return value()
```

behaves like:

```lua
do
    body()
    return value()
finally
    cleanup()
end
```

## What Counts As The Current Block

The current block is the statement list being parsed: a function body, a
`do ... end` body, a loop body, or an `if`/`elseif`/`else` arm. In a loop,
the deferred statement runs before that iteration leaves the loop body:

```lua
while more() do
    defer close_current_item()
    process_current_item()
end
```

## Ordering

Multiple defers in one block run in last-in-first-out order, because each
defer wraps the rest of the block:

```lua
defer first()
defer second()
work()
-- on exit: work(), second(), first()
```

This is true for normal fallthrough, `return`, `break`, and errors. If a
deferred statement raises, it overrides the pending action just like an
ordinary `finally` block.

Return expressions are evaluated before cleanup runs. For example, this
returns `"body"` even though the deferred statement mutates `log` before
control reaches the caller:

```lua
function f(): string
    local log = "body"
    defer log = log .. ":cleanup"
    return log
end
```

## Scope

The deferred statement is checked where the `defer` appears. It can use
locals that are already in scope, and it cannot use locals declared later
in the rest of the block:

```lua
local n = 1
defer use(n)       -- ok
local later = 2
```

```lua
defer use(later)   -- compile-time error
local later = 2
```

In a `repeat ... until` loop, the `until` condition still has Titan's
normal repeat-loop scope: it can see locals declared in the body after the
`defer`.

## Multiple Cleanup Statements

The grammar accepts exactly one statement after `defer`. Use a `do` block
when cleanup needs several statements:

```lua
defer do
    flush()
    close()
end
```

A `defer` may not directly defer another `defer` statement. Write the
two defers separately:

```lua
defer first()
defer second()
```

## Control Flow In Cleanup

Because `defer` is implemented as a `finally`, the deferred statement
uses the same cleanup restrictions:

* `return` inside the deferred statement is a compile-time error.
* `break` inside the deferred statement is a compile-time error if it
  would break a loop outside that deferred statement.
* `raise <exp>` is allowed and overrides any pending fallthrough,
  return, break, or error.

See [Error handling](error-handling.md) for the full `finally` semantics.
