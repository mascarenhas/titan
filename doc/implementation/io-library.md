# I/O-library implementation

The user-facing Interfaces, printing, and line-iteration contracts are in the
[I/O standard-library chapter](../language/standard-library-io.md).
`titan/io.titan` is a flat Titan module whose only imports are the ordinary
public `os` and `string` interfaces, so a source build composes with
compiled-only providers of both. It adds no compiler intrinsic, Lua C API
operation, or native code. Concrete streams, including the shell facade, live
with their resources in [`titan.os`](os-library.md#shell-process-stream) and
other owners; `titan.io` declares only the Interfaces they satisfy.

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

The non-LuaCov native folder module `spec/stdlib/titan/io/tests/` uses
`core_test.titan` to instrument string and output values and check conversion
order, conversion before output, one write, and late lookup of a reassigned
`os.stdout`. Structural ReaderCloser records check every exit path in the table
above. Shell-stream behavior, including its conversions to all seven
Interfaces, is tested by `os.process_tests`
([shell tests](os-library.md#shell-and-disposal-tests)).

