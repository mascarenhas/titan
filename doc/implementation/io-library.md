# I/O-library implementation

The user-facing Interfaces, printing, line iteration, and process-stream
contracts are in the
[I/O standard-library chapter](../language/standard-library-io.md).
`titan/io.titan` is a flat Titan module over the existing Interface,
generic-for, string, and OS process machinery. It adds no compiler intrinsic,
Lua C API operation, or native code. It reaches the OS module's private stream
helpers through the explicit source import `import "os.titan"`.

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

## Shell process stream

`popen` calls the OS module's private `spawn_shell`, which builds the platform
shell command and captures writable stdin plus one merged stdout/stderr pipe;
the shell selection and Windows argument transport are described in
[spawn transaction and exit delivery](os-library.md#spawn-transaction-and-exit-delivery).
There are no CRT mode flags or text-mode conversions. `popen` narrows the
optional Process stream fields and constructs one `InputOutputStream`:

| Field | Meaning |
| --- | --- |
| `process` | Originating `os.Process`; nil on a transferred destination. |
| `input` / `output` | The writable and merged-readable stream facades. `os.spawn` stores the same InputStream in both `stdout` and `stderr`, so no second facade exists. |
| `input_packet` | A staged writable-pipe transfer payload (see below). |
| `status` | Cached `ExitStatus`. |
| `closed` | Set only after close has completed. |
| `pending_operations` | Count of running `read`, `read_until`, `write`, `wait`, and `close` calls. |

`read`, `read_until`, and `write` delegate directly to the facades, so the
record structurally satisfies all seven I/O Interfaces without another buffer
or dispatch layer. `wait` calls `Process:wait` only while `status` is nil and
returns the cached normal-or-signal result afterwards.

`close` returns early only when `closed` is set. It discards a staged input
packet, closes stdin, and, if no status is cached and `Process:is_running`
still reports a live child, sends `term` and calls the caching `wait`. A
`defer` closes the merged InputStream even if signalling or waiting raises,
and sets `closed` only when process cleanup succeeded, so a later call can
retry what did not complete. Signals address the launched shell; the facade
does not own a process tree or terminate descendants on close or Task
cancellation.

## Shell-stream transfer

The generic manual-handoff rules are in
[manual resource handoff](transfer-library.md#manual-resource-handoff). This
section covers only the shell-stream gate and schema.

The hooks move only the two captured pipes. The originating `Process` and its
UV exit callback stay in the source Runtime; that callback keeps the private
`ProcessOwner` rooted until exit even if the source `InputOutputStream` becomes
unreachable. After a successful transfer the source has no communication
facades but still owns wait and termination. The destination has no Process:
its `wait` raises, and its `close` only closes its two streams.

`to_transfer_payload` rejects a closed facade and a nonzero
`pending_operations`, then runs the OS module's `stream_transfer_preflight` on
both Stdio owners before detaching either, so a pending operation on the second
pipe cannot detach the first. Process creation starts the captured output read
before publishing the facade, so on Windows a fresh shell pipe commonly has a
pending overlapped read and preflight rejects it (`stdio.transfer`, `EBUSY`)
even after a yield. Live cross-state shell-pipe handoff therefore has a
classified Windows skip.

The writable pipe is detached first into `input_packet`. If detaching the
readable pipe then fails, that packet stays on the source facade:
`to_transfer_payload` can be retried, `write` reconstructs the owner through
`restore_input` (also updating `Process.stdin` and clearing the field only after
adoption succeeds), and `close` discards it with the OS module's
`discard_output_transfer_payload`. `close` clears the field after that native
close attempt and before reporting its status, so a close error is never
retried against a possibly reused descriptor. After both detach, the payload is
the private `stream_transfer_fields` protobuf schema holding the two OS child
payloads; a lexical guard discards both if final serialization raises.

`from_transfer_payload` decodes both strings and allocates the composite before
adopting either pipe. If the readable pipe fails to adopt, a guard calls the OS
module's `discard_unpublished_stdio` on the already adopted writable owner,
which starts native close without waiting and so keeps the hook nonyielding.

## Tests

The non-LuaCov native folder module `spec/stdlib/titan/io/tests/` has two
constituents. `core_test.titan` instruments string and output values to check
conversion order, conversion before output, one write, and late lookup of a
reassigned `os.stdout`, and uses structural ReaderCloser records to check every
exit path in the table above. `process_test.titan` covers Interface
conversion, merged output, binary delimiter reads, retained exit status,
idempotent close, running-child termination, parent-stdin plumbing through a
compiled standalone child, pipe transfer, destination wait rejection,
pending-reader rejection without detachment, malformed payloads, and use from
an independent Lua state.

`spec/support/check_io_transfer_failure.sh` (Linux only; other platforms report
a classified skip) takes an absolute installed SDK prefix and a new absolute
output directory. It compiles `spec/fixtures/stdlib/native/io_transfer_dup_failure.c`
into an object, links the `io_transfer_failure_app` fixture with that object
passed through `-X`, and adds `-Wl,--wrap=dup,--wrap=close` through
`TITAN_EXTRA_LDFLAGS`
to make the second pipe duplication fail, then checks write, retry, close, and
exit cleanup of the staged descriptor.
