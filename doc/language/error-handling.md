# Error handling

Titan keeps the same fail-fast philosophy described in the
[design philosophy](philosophy.md): type mistakes and invalid dynamic
values should stop at the first point where Titan can prove something is
wrong. Many such mistakes are compile-time errors; the ones that depend
on Lua values, dynamic casts, arithmetic edge cases, or explicit
programmer intent are run-time errors.

Run-time errors are ordinary Lua errors. They can be caught by Lua
`pcall`/`xpcall`, they can be raised from Titan with `raise`, and they can
be handled inside Titan with `catch` block trailers.

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
Titan type; it is coerced to `value`, so strings, numbers, records, unions,
arrays, maps, `nil`, and arbitrary Lua values can all be raised:

```titan
function fail(name: string)
    raise "unknown user: " .. name
end

function fail_with_value(v: value)
    raise v
end
```

Lua 5.5 normalizes a raised `nil` error object to the string
`"<no error object>"`; Titan `catch` and Lua `pcall` observe that string.
Other raised values, including `false`, retain their value. This normalization
applies to raised exceptions, not ordinary nil results or typed rejection data.
For example, `pcall` receives the raised string unchanged:

```lua
local ok, err = pcall(m.fail, "ada")
print(ok)   --> false
print(err)  --> unknown user: ada
```

A bare `raise` is a re-raise. It is legal only inside a `catch` block and
raises the original caught value again, preserving the original traceback
rather than replacing it with the shallower catch-site stack:

```titan
function checked_open(path: string): value
    return raw_open(path)
catch
    log("open failed: " .. traceback)
    raise
end
```

Using bare `raise` anywhere else is a compile-time error.

### Raising with a saved trace

`raise <exp>, <trace>` raises a value with a trace that was captured earlier,
in place of the stack of the `raise` statement itself. Use it for an error that
a `catch` saved in order to raise it later or somewhere else. The trace is a
`string`, normally the `traceback` of that `catch`:

```titan
record Failure
    error: value
    trace: string
end

local pending: Failure? = nil

function attempt(work: function (): ())
    work()
catch
    pending = Failure(error, traceback)
end

function finish()
    local failure? = pending
    pending = nil
    if failure ~= nil then raise failure.error, failure.trace end
end
```

A `catch` that handles this error sees the given string as its `traceback`,
and `titan.backtrace()` returns it when the error reaches Lua. The trace
belongs to this one error: the next error gets its own. The value is evaluated
before the trace, and a trace cannot be written without a value.

## `catch`

Titan does not have a `try` keyword. Instead, `catch` attaches to a block.
When the whole function is protected, attach it directly to the existing
function body:

```titan
function quotient(a: integer, b: integer): integer?
    return a // b
catch
    return nil
end
```

The same trailer may appear on any construct whose body is a block:
function bodies, `while` bodies, `repeat` bodies, numeric `for` bodies,
`if`/`elseif`/`else` arms, union `when` arms and their `else`, anonymous
function bodies, and nested `do ... end` blocks. Use an extra `do` only when
its narrower protected region or local scope is intentional; it is not required
to gain a `catch`.

```titan
function parse(s: string): integer
    return parse_integer(s)
catch
    return 0
end
```

A union case binding is established outside its arm's protected block, so it
is visible in that arm's body and catch. Locals declared inside the body
remain hidden from the sibling catch clause. Each arm is an independent
error-handling boundary.

The `catch` block has two implicit locals:

* `error: value` — the caught Lua error value.
* `traceback: string` — the raw unified Titan/Lua traceback captured at
  the original raise or run-time fault. It contains frame lines only: no
  error message, no `stack traceback:` header, and no tab indentation.

These locals are read-only snapshots. Assigning to `error` or `traceback`
inside the catch is a compile-time error.

The body and catch are sibling scopes. Locals declared in the body are not
visible in the catch, because the body may have failed before those locals
were initialized:

```titan
do
    local tmp = compute()
    risky(tmp)
catch
    -- tmp is not in scope here
    log(traceback)
end
```

## Propagation semantics

`catch` handles errors raised by the body. If the catch completes normally,
the error is swallowed and execution continues after the whole construct.
If there is no catch, the error keeps propagating. Automatic cleanup via
`defer` statements is described in [Defer](defer.md).

Recovery works even when memory is exhausted: entering a `catch` or a
registered `defer` does not allocate, so both still run after a
`"not enough memory"` error. If that error was raised before Titan could
capture a traceback, `traceback` is the empty string, or a trace that an
earlier error left recorded. If recording the trace of a re-raised or
propagating error runs out of memory, enclosing `defer` and `catch` blocks
still run.

A suspended coroutine that is collected, or whose Lua state closes, is
unwound as if by an error that no `catch` can handle: its `defer` statements
run, its `catch` blocks do not, and errors raised by that cleanup become Lua
warnings. See [abandoned coroutines](coroutines.md#abandoned-coroutines).

## Interacting with Lua

Lua sees Titan errors as normal Lua errors:

```lua
local ok, err = pcall(m.risky)
if not ok then
    print("Titan failed:", err)
end
```

Titan can also catch errors raised by Lua functions it calls. The caught
`error` value follows the normalization rule above, and `traceback` is still
a string.

An uncaught error in a standalone Titan executable is reported by the
generated top-level handler: it prints `<progname>: <error message>`,
then `stack traceback:`, then the unified traceback with tab-indented
frame lines through the Titan `main` frame, and exits non-zero. The
synthetic Lua bootstrap used to call `main` is not shown. A successful
`main` returns its integer result as the process exit status.

The message is the raised string's bytes or Lua's formatting of a raised
number. Integral floats retain their `.0` suffix, including `-0.0`. Other
values use a string-valued `__tostring` result when available, or
`(error object is a <type> value)` otherwise; a non-string metamethod result
does not become message text.

## `titan.backtrace()`

The Lua support module `titan` exposes the last uncaught or re-propagated
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
as `m.func` (including source `foreign function` definitions with Titan
bodies), `m.Record:method`, `m.Record.static`, or
`anonymous function at m.titan:12` when the module has been initialized in the
current Lua state (falling back to the raw C symbol if a trace taken in an
independent child state sees outer native frames from a module initialized only
in the parent state), and source lines are attributed to the Titan `.titan`
call or raise site when debug information is available.
The returned string is the raw frame list: it does not include the error
message, a `stack traceback:` header, or tab indentation.

When Titan catches and handles an error, the registry slot backing
`titan.backtrace()` is cleared; the handled trace is available as the
catch-local `traceback`. A bare re-raise pins that saved trace so the outer
handler sees the original stack, and `raise <exp>, <trace>` does the same with
the trace it is given. A fresh `raise <exp>` builds a fresh trace.

The merged trace uses libbacktrace and the generated C debug information
on Linux, macOS, and Windows. Windows providers retain their DWARF sections;
stripping that debug information prevents native source attribution.
On macOS, the build may need `dsymutil` output for fully symbolized
standalone executables; the test suite and CI exercise that path.

For the [browser target](browser-target.md#traces), a linked image traces
through its `<stem>.wasm.map`, loaded eagerly during Wasm instantiation before
Lua initialization, so nothing is fetched or awaited when an error is raised.
Embeddings may require that map with `create({requireTrace: true})`; the runner
does so unless degraded mode is explicitly allowed. A required-map failure
has no Titan trace because Lua has not run. Chromium, Firefox, and
Node provide the same unified Titan/Lua frame order, selected `.titan`
filenames, line numbers, display names, and pin/rethrow/append behavior as
native builds, while WebKit and Safari provide reduced, function-level fidelity
(`<basename>: in <display name>`, without line numbers). A web server serving a
browser image must serve `<stem>.wasm.map` next to `<stem>.wasm`; see
[Compiling for the browser target](browser-target.md#traces) for the
degraded-mode, capture-failure, and truncation markers and the per-engine depth
limits.

## Other run-time errors

The explicit `raise` statement is only one source of run-time errors.
Titan also raises when a dynamic condition violates a static type or Lua
semantic rule:

| Source | Error shape |
| --- | --- |
| wrong argument type from Lua | `FILE:LINE:COL: type error, expected T but found U` |
| more than 200 variadic arguments from Lua | `too many variadic arguments to Titan function NAME (N, max 200)` |
| more than 200 open flexible results | `too many flexible return values (max 200)` |
| failed `value as T` or implicit `value` conversion | `FILE:LINE:COL: type error, expected T but found U` |
| float-to-integer conversion failure | `type error, number 'N' has no integer representation` |
| integer `//` or `%` by zero | `error at line LINE, divide by zero` / `% by zero` |
| option unwrap of `nil` | `FILE:LINE:COL: type error, expected T but found nil` |
| array/map element read with wrong Lua value | `FILE:LINE:COL: type error, expected T but found U` |
| unknown record field from Lua | `FILE:LINE:COL: field 'NAME' not found in record 'FQTN'` |
| unknown union member from Lua | `FILE:LINE:COL: member 'NAME' not found in union 'FQTN'` |
| unknown module member from Lua | `member 'NAME' does not exist in Titan module 'MOD'` |

For details of each source, see the chapters that define the construct:
[types](types.md), [option types](option-types.md),
[arrays and maps](arrays-maps.md), [records](records.md), [unions](unions.md),
[functions](functions.md), and [Lua interoperability](lua-interop.md).

## Recoverable failures: prefer options

Use errors for exceptional failures and violated assumptions. For ordinary
"not found" or "not available" results, prefer [option types](option-types.md):

```titan
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
