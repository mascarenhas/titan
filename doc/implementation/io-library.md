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

```text
(function (ReaderCloser): (string?), ReaderCloser, nil,
 function (ReaderCloser): ())
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

On Linux and macOS, `popen` delegates parsing and execution to `/bin/sh`
through the existing process and pipe implementation:

```titan
os.spawn("/bin/sh", {"-c", command},
         os.with_stdin, os.with_merged_output)
```

The Windows branch obtains the absolute `cmd.exe` path with
`GetSystemDirectoryW` and uses `/d /s /c`. It encloses the caller's command in
the shell's outer quotes and uses the OS module's verbatim-argument option for
public `uv.spawn` to preserve that command payload. It does not consult `COMSPEC`. Ordinary
`os.spawn` retains its existing argument transport.

Both shell branches use the existing asynchronous process owner and captured
libuv pipes, with writable stdin and one shared stdout/stderr pipe. There are
no CRT mode flags or text-mode byte conversions. `popen` narrows the optional
process stream fields explicitly, then constructs one
public `InputOutputStream` with private fields for the optional originating
Process, writable and merged-readable facades, an optional staged writable-pipe
payload, cached `ExitStatus`, completed-close bit, and pending-operation count. It never constructs a second
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
uses either the facade cache or the Process's retained exit status. Process
signalling addresses the launched shell; the facade does not own a process
tree or promise to terminate descendants on close or Task cancellation.

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

## Shell-stream transfer

The composite hooks move only the captured pipes. The originating `Process`
and its UV exit callback remain in the original Runtime; that callback retains
`ProcessOwner` until exit even if the original `InputOutputStream` becomes
unreachable. The destination facade has no Process. Its `wait` reports that
explicitly, while its `close` only disposes its two stream owners.

All five potentially waiting wrapper operations increment a count until their
continuations exit. Transfer rejects a nonzero count, then preflights both
private Stdio owners through io's existing explicit `os.titan` source import.
This prevents a pending operation on the second pipe from detaching the first.
Process creation starts captured output reads before publishing the facade.
Windows therefore commonly retains a pending overlapped read on a fresh shell
pipe, and preflight rejects it with `stdio.transfer`/`EBUSY` even after a yield.
Tests verify rejection without detachment and continued source traffic/reaping;
live cross-state shell-pipe handoff has a classified Windows skip.
The first detached writable-pipe packet remains on the source until the second
handoff succeeds. A failure therefore retains ownership locally; transfer can
retry, and write can reconstruct that owner. Successful reconstruction
also updates `Process.stdin` to preserve the original facade alias and clears
the staged field only after adoption succeeds. Close validates and directly
retires a retained packet's descriptor without adoption, so cleanup remains
available after transfer admission closes. It clears that packet after the
native close attempt, before reporting its status; a terminal close error must
not cause a retry against a potentially reused descriptor. No registry or
native multi-pipe transaction is introduced.

The isolated Linux regression `spec/support/check_io_transfer_failure.sh`
takes an absolute installed SDK prefix and a new absolute output directory.
It builds a child-only `dup` interposer and the native
`io_transfer_failure_app` fixture, then verifies write, retry, close, and exit
cleanup after the second pipe duplication fails. The exit case verifies both
closed native-adoption admission and retirement of the exact staged descriptor;
it reaps the child before requesting exit to keep cancellation of `Process.wait`
separate from this ownership test. Other platforms report a classified skip.

After successful transfer the source drops both communication facades but
retains child wait/termination ownership. The receiver validates both nominal
payload kinds before adoption and allocates its composite shell first. If
readable-pipe adoption fails, it schedules native close of the unpublished
writable owner without waiting, preserving the hooks' nonyielding contract.
The underlying hooks own platform-specific descriptor duplication and
read-buffer reconstruction.

Native `io.tests` cover pipe transfer with binary traffic and source reaping,
explicit destination wait rejection, pending-reader rejection without source
detachment, malformed payloads, and use from an independent Lua state while
the origin Runtime retains child ownership.
