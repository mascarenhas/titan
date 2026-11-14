# I/O-library implementation

The user-facing Interfaces, printing, and line-iteration contracts are in the
[I/O standard-library chapter](../language/standard-library-io.md).
`titan/io.titan` is a shared flat Titan module whose only imports are the ordinary
public `os` and `string` interfaces, so a source build composes with
compiled-only providers of both. It adds no compiler intrinsic, Lua C API
operation, or native code. Concrete streams, including the shell facade, live
with their resources in [`titan.os`](os-library.md#shell-process-stream) and
other owners; `titan.io` declares only the Interfaces they satisfy.

The same shared source is delivered in the browser provider. Its `os` import
selects browser contributors, so one-write printing awaits the SDK sink and
the parent stream records satisfy the same Interfaces. No browser variant or
transport policy belongs in `titan.io`.

## One-write printing

`print(...: value)` converts its variadic arguments in a forward loop, so
`string.tostring` calls and any conversion error occur left to right. Each
converted value, with its leading tab when needed, and the final newline go
into one `string.writer()`; assembly does not yield. Only after every conversion
and the builder's `drain` succeed does `print` read the current mutable
`os.stdout` module variable and call `write` once. A conversion failure
therefore performs no write, and a concrete OutputStream error propagates
unchanged; this layer has no partial-write recovery.

## Line iteration

`lines` returns `next_line, reader, nil, close_reader`. The ReaderCloser
Interface wrapper is the generic-for state, and it keeps the concrete Reader
and its defining module rooted, so no private record or bound closure is
needed. The iterator's `string?` result is the loop control value: an empty
string is non-nil and reaches the loop body.

`next_line` calls `reader:read_until("\n", true)` once, returns a string
directly, and calls `close` before returning nil at EOF. `close_reader` only
calls `reader:close()`. `titan.io` keeps no buffer, newline scan, or closed bit:
delimiter spanning, retained excess, suspension, and cancellation belong to
the concrete Reader, and the `Closer` contract makes repeated close calls safe.

The checker treats the fourth tuple slot as a one-argument close function, so
generic-for passes it the ReaderCloser state, and `codeforin` places the
initial iterator call, body, update calls, and normal exit inside a synthetic
`finally` ([generic `for` lowering](codegen-constructs.md#the-generic-for--in)):

| Exit path | First close site | Generic-for final close |
| --- | --- | --- |
| nil EOF | `next_line` | idempotent repeat |
| `break` or `return` | synthetic `finally` | one call |
| Reader or body error | synthetic `finally` during unwind | one call |
| close error at EOF | `next_line` | safe repeat: retry or terminal no-op |

`next_line` has no catch: a `read_until` error already crosses the protected
region whose close slot owns cleanup. A close error has ordinary `finally`
precedence and can replace a pending body error, `break`, or `return`.

## Tests

The non-LuaCov folder module `spec/stdlib/titan/io/tests/` is an owner in both
native and browser suites. `core_test.titan` uses structural ReaderCloser
records to check every exit path in the table above; `memory_lines.titan`
checks empty lines and a final unterminated tail over a string Reader.
`printing.native.titan` instruments string and output values through captured
stdio to check conversion order, conversion before output, one write, and
late lookup of reassigned `os.stdout`. `streams.browser.titan` checks parent
stream Interface conversions and printing through SDK output.
Shell-stream behavior, including conversions to all seven Interfaces, stays
in the native-only `os.process_tests`
([shell tests](os-library.md#shell-and-disposal-tests)).
