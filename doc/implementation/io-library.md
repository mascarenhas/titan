# I/O-library implementation

The user-facing Interfaces, printing, line iteration, and process-stream
contracts are in the
[I/O standard-library chapter](../language/standard-library-io.md).
`titan.io` remains a flat Titan module. All three helpers are ordinary Titan
over the existing Interface, generic-for, string, and os-process machinery;
they add no compiler intrinsic, Lua C API operation, or native runtime support.

## One-write printing

`print(...: value)` converts indexed variadic arguments in a forward loop, so
calls to `string.tostring` and any conversion error occur left to right. It
appends each converted value, its leading tab when needed, and the final
newline to `string.writer()`. Stdout's eventual write is the scheduling
boundary, so assembly itself does not yield. This reuses the string module's
bounded builder instead of maintaining a second chunk-array/join
implementation in `io`.

Only after every conversion and the builder's final `drain` succeed does
`print` read the current mutable `os.stdout` module variable and call `write`
once. There is no partial-write recovery in this layer: a conversion failure
performs no write, while a concrete OutputStream error is propagated unchanged.

## ReaderCloser iterator state

`lines` uses its Interface wrapper directly as the generic-for state. That
wrapper keeps the concrete Reader and its defining module rooted. No private
record or bound closure is needed, and the public return type states the
ownership literally:

```titan
((ReaderCloser) -> string?, ReaderCloser, nil,
 (ReaderCloser) -> ())
```

Initial control is nil. The iterator's nil-capable string result is the generic
loop control value; an empty string is nonnil and reaches the loop body.

## Step and close protocol

`next_line` calls `reader:read_until("\n", true)` once. A string is returned
directly. On nil EOF, it calls `close` before returning nil. A concrete closed
ReaderCloser returns nil, so the iterator needs no duplicate closed bit. No secondary buffer or
newline scan exists in `titan.io`; delimiter spanning, retained excess bytes,
asynchronous suspension, and cancellation remain the concrete Reader's
responsibility.

`close_reader` only calls the Interface's `reader:close()`. `Closer` itself
requires every later close call to be safe, so the iterator does not duplicate
a resource-state guard. The generic-for finalizer can safely call close after
EOF already did. If the first close raised, the concrete closer
either retries a pre-commit operation or observes a terminal state and returns.

The checker sees the fourth tuple slot as a one-argument close function, so
generic-for passes the ReaderCloser state. `codeforin` wraps the initial
iterator call, loop body, update calls, and normal exit in its existing
synthetic `finally`. Consequently:

| Exit path | First close site | Generic-for final close |
| --- | --- | --- |
| nil EOF | `next_line` | idempotent repeat |
| `break` or `return` | synthetic `finally` | one call |
| Reader or body error | synthetic `finally` during unwind | one call |
| close error at EOF | `next_line` | safe repeat: retry or terminal no-op |

There is no separate catch in `next_line`: an error from `read_until`
already crosses the generic-for protected region, whose close slot owns the
cleanup. A close error has the language's ordinary `finally` precedence and
can replace a pending body error, break, or return.

## Shell process stream

`popen` delegates parsing and execution to `/bin/sh` by calling:

```titan
os.spawn("/bin/sh", {"-c", command},
         os.with_stdin, os.with_merged_output)
```

The returned process must therefore have a writable stdin and captured
stdout. `popen` narrows those optional fields explicitly, then constructs one
public `InputOutputStream` whose five fields remain private: the Process, the
writable input facade, the one merged readable facade, an optional cached
`ExitStatus`, and the completed-close bit. It never constructs a second
facade for stderr; `os.spawn` has already stored the exact same InputStream in
both Process output fields.

The read and write methods delegate directly to those two facades, while close
coordinates both facades with process termination. Their exact public method
shapes make the record structurally satisfy all seven I/O Interfaces without
another buffer or dispatch layer. `wait` calls `Process:wait` only while the
cached status is nil, stores the complete normal-or-signal result, and returns
that same status on later calls.

`close` first checks only a successfully completed close bit. It closes stdin,
sends `term` only if `Process:is_running` still observes a live child, and
calls the caching `wait` when it requested that termination. After stdin close
succeeds, a `finally` closes the one merged InputStream even if signalling or
waiting raises. The completed bit is set only after process cleanup succeeds,
so a later call can retry whatever did not reach that point. A later `wait`
uses either the facade cache or the Process's retained exit status.

The focused non-LuaCov native `io.tests` folder module is rooted at
`spec/stdlib/titan/io/tests/tests.titan`; both `core_test.titan` and
`process_test.titan` are constituents of that one logical test owner. Its core
constituent runs against the canonical `titan.io` provider. Instrumented string
and output values prove
left-to-right conversion, conversion-before-output, builder result bytes,
the zero-argument newline, one write, and late lookup of reassigned stdout.
Its structural ReaderCloser records prove the literal delimiter/chop call,
empty-line preservation, nil exhaustion, `break`, `return`, Reader and body
errors, a retryable raising closer, and repeated manual close-function calls.
Normal exits reach one terminal physical close; successful EOF gets a harmless
idempotent repeat, while a close error gets one finalizer retry.

The process constituent runs against the canonical coroutine/uv/async, string,
os, and io modules. It covers structural Interface
conversion, interactive merged output, binary delimiter reads, retained exit
status, idempotent close, and explicit running-child termination/reaping.
Exact parent-stdin process plumbing also runs natively: a compiled Titan parent
launches a focused standalone child through C99 `system`, reads its temporary
result file, and removes that file with `defer`. Closed-facade behavior in a
later Runtime runs under two explicit `support.runtime` sessions.
