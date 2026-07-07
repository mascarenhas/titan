# Error handling

Titan keeps the same fail-fast philosophy described in the
[design philosophy](philosophy.md): type mistakes and invalid dynamic
values should stop at the first point where Titan can prove something is
wrong. Many such mistakes are compile-time errors; the ones that depend
on Lua values, dynamic casts, arithmetic edge cases, or explicit
programmer intent are run-time errors.

Run-time errors are ordinary Lua errors. They can be caught by Lua
`pcall`/`xpcall`, they can be raised from Titan with `raise`, and they can
be handled inside Titan with `catch` and `finally` block trailers.

## Compile-time and run-time errors

A **compile-time error** is reported by `titanc` before any C is emitted.
The compiler typechecks all requested modules and their dependencies
first, reports all errors it finds, and exits with status 1:

```text
m.titan:3:11: type error: types in declaration of local variable x do not match, expected integer but found string
```

A **run-time error** is raised while compiled Titan code runs. It unwinds
through Titan and Lua with Lua's normal error machinery. Most Titan
run-time diagnostics carry a Titan source position:

```text
m.titan:2:1: type error, expected integer but found string
```

The colon after `type error` marks a compile-time type error; the comma
marks a run-time type error.

## Raising errors

`raise <exp>` raises a new run-time error. The expression may have any
Titan type; it is coerced to `value`, so strings, numbers, records,
arrays, maps, `nil`, and arbitrary Lua values can all be raised:

```lua
function fail(name: string)
    raise "unknown user: " .. name
end

function fail_with_value(v: value)
    raise v
end
```

From Lua, `pcall` receives exactly the raised value:

```lua
local ok, err = pcall(m.fail, "ada")
print(ok)   --> false
print(err)  --> unknown user: ada
```

A bare `raise` is a re-raise. It is legal only inside a `catch` block and
raises the original caught value again, preserving the original traceback
rather than replacing it with the shallower catch-site stack:

```lua
function checked_open(path: string): value
    return raw_open(path)
catch
    log("open failed: " .. traceback)
    raise
end
```

Using bare `raise` anywhere else is a compile-time error.

## `catch` and `finally`

Titan does not have a `try` keyword. Instead, `catch` and `finally`
attach to a block. A `do ... end` block is the most explicit spelling:

```lua
do
    risky()
catch
    handle(error, traceback)
finally
    cleanup()
end
```

The same trailers may appear on any construct whose body is a block:
function bodies, `while` bodies, `repeat` bodies, numeric `for` bodies,
`if`/`elseif`/`else` arms, anonymous function bodies, and nested
`do ... end` blocks. Either clause may appear by itself; if both appear,
`catch` comes before `finally`.

```lua
function parse(s: string): integer
    return parse_integer(s)
catch
    return 0
finally
    bump_attempt_counter()
end

while running do
    poll()
finally
    close_socket()
end
```

The `catch` block has two implicit locals:

* `error: value` — the caught Lua error value.
* `traceback: string` — the raw unified Titan/Lua traceback captured at
  the original raise or run-time fault. It contains frame lines only: no
  error message, no `stack traceback:` header, and no tab indentation.

These locals are read-only snapshots. Assigning to `error` or `traceback`
inside the catch is a compile-time error.

The body, catch, and finally are sibling scopes. Locals declared in the
body are not visible in the catch or finally, because the body may have
failed before those locals were initialized:

```lua
do
    local tmp = compute()
    risky(tmp)
catch
    -- tmp is not in scope here
    log(traceback)
end
```

## Propagation and cleanup semantics

`catch` handles errors raised by the body. If the catch completes normally,
the error is swallowed and execution continues after the whole construct.
If there is no catch, the error keeps propagating after any finally runs.

`finally` runs on every exit from its body or catch:

* normal fallthrough;
* a caught or uncaught run-time error;
* `return`;
* `break`.

If the finally completes normally, Titan resumes the pending action: it
falls through, returns the saved return values, breaks out of the target
loop, or re-raises the saved error.

If the finally raises — either with `raise <exp>` or by triggering another
run-time error — that new error overrides the pending action. There is no
exception chaining: errors are plain Lua values plus an out-of-band
traceback, so a new error in a catch or finally replaces the previous one.

```lua
function f(): integer
    return 10
finally
    raise "cleanup failed"   -- overrides the pending return
end
```

To keep that rule simple and predictable, Titan forbids explicit control
transfers that would leave a finally:

* `return` inside a finally is a compile-time error.
* `break` inside a finally is a compile-time error if it would break a
  loop outside the finally.
* A `break` that targets a loop written inside the finally is allowed.
* `raise <exp>` inside a finally is allowed, because run-time errors can
  always happen during cleanup and must propagate.

The rule is lexical to the finally block itself. Nested anonymous
functions are checked as their own function bodies, so a `return` inside
such a nested function is legal and returns from that function, not from
the enclosing finally.

```lua
while true do
    risky()
finally
    -- compile-time error: this break would leave the finally
    break
end

do
    risky()
finally
    while true do
        break       -- ok: breaks the loop inside the finally
    end
end
```

Nested finally blocks run inside-out. A re-raised error keeps the original
trace as it passes through each cleanup.

## Interacting with Lua

Lua sees Titan errors as normal Lua errors:

```lua
local ok, err = pcall(m.risky)
if not ok then
    print("Titan failed:", err)
end
```

Titan can also catch errors raised by Lua functions it calls. The caught
`error` value is whatever Lua raised, and `traceback` is still a string.

An uncaught error in a standalone Titan executable is reported by the
generated top-level handler: it prints `<progname>: <error message>`,
then `stack traceback:`, then the unified traceback with tab-indented
frame lines through the Titan `main` frame, and exits non-zero. The
synthetic Lua bootstrap used to call `main` is not shown. A successful
`main` returns its integer result as the process exit status.

## `titan.backtrace()`

The optional Lua module `titan` exposes the last uncaught or re-propagated
Titan traceback for the current Lua state:

```lua
local titan = require "titan"
local ok, err = pcall(m.risky)
assert(not ok)
print(titan.backtrace())
```

The trace is captured by Titan's error handler at the original failure
site. It is one unified, innermost-to-outer traceback that interleaves
compiled Titan frames with Lua frames. Titan frames use source names such
as `m.func`, `m.Record:method`, `m.Record.static`, or
`anonymous function at m.titan:12`, and source lines are attributed to the
Titan `.titan` call or raise site when debug information is available.
The returned string is the raw frame list: it does not include the error
message, a `stack traceback:` header, or tab indentation.

When Titan catches and handles an error, the registry slot backing
`titan.backtrace()` is cleared; the handled trace is available as the
catch-local `traceback`. A bare re-raise pins that saved trace so the
outer handler sees the original stack. A fresh `raise <exp>` builds a
fresh trace.

The merged trace uses libbacktrace and the generated C debug information.
On macOS, the build may need `dsymutil` output for fully symbolized
standalone executables; the test suite and CI exercise that path.

## Other run-time errors

The explicit `raise` statement is only one source of run-time errors.
Titan also raises when a dynamic condition violates a static type or Lua
semantic rule:

| Source | Error shape |
| --- | --- |
| wrong argument type from Lua | `FILE:LINE:COL: type error, expected T but found U` |
| extra arguments from Lua | `calling Titan function NAME with N arguments, but expected at most M` |
| failed `value as T` or implicit `value` conversion | `FILE:LINE:COL: type error, expected T but found U` |
| float-to-integer conversion failure | `type error, number 'N' has no integer representation` |
| integer `//` or `%` by zero | `error at line LINE, divide by zero` / `% by zero` |
| option unwrap of `nil` | `FILE:LINE:COL: type error, expected T but found nil` |
| array/map element read with wrong Lua value | `FILE:LINE:COL: type error, expected T but found U` |
| unknown record field from Lua | `FILE:LINE:COL: field 'NAME' not found in record 'FQTN'` |
| unknown module member from Lua | `member 'NAME' does not exist in Titan module 'MOD'` |

For details of each source, see the chapters that define the construct:
[types](types.md), [option types](option-types.md),
[arrays and maps](arrays-maps.md), [records](records.md),
[functions](functions.md), and [Lua interoperability](lua-interop.md).

## Recoverable failures: prefer options

Use errors for exceptional failures and violated assumptions. For ordinary
"not found" or "not available" results, prefer [option types](option-types.md):

```lua
function find(xs: {integer}, v: integer): integer?
    for i = 1, #xs do
        if xs[i] == v then
            return i
        end
    end
    return nil
end

function find_or_first(xs: {integer}, v: integer): integer
    local i? = find(xs, v)
    return i or 1
end
```

`return nil` is a value-level result here, not an error. A caller can keep
the option (`local i? = ...`), test it (`if i then`), default it
(`i or 1`), or deliberately unwrap it into a plain `integer` and get a
fail-fast run-time error if it is absent.
