# Operating-system library implementation

`titan/os.titan` implements the [OS API](../language/standard-library-os.md):
environment and host queries, calendars, parent standard streams, process
configuration, captured streams, signals, and graceful exit. It uses ordinary
compiled imports of public `uv` and `async`. UV owns native storage and callback
lifetimes and async owns Task waits and subscriptions
([runtime](libuv-runtime.md)); all OS-specific process and stdio policy stays
here.

Calendar, formatting, locale, and time-difference operations keep their ISO C
implementation, adapted from Lua 5.5.1 `loslib.c`, with Lua-compatible
validation. Clocks, environment snapshots, paths, process identifiers, and
signal constants use public UV queries. Sized string queries go through
`os_sized_buffer`, which retries `ENOBUFS` and grows the buffer; a missing
environment variable is nil. `os.exepath` first calls `uv.setup_process_args()`
and raises in an ordinary Lua host, and treats a result that fills the buffer
as possibly truncated. The SIGPIPE policy and generated-main hook belong to
async initialization, not to this module
([startup policy](libuv-runtime.md#startup-policy)).

## Domain owners

| Owner | Fields and responsibility |
| --- | --- |
| `StreamStdio` (private) | `native` (a `uv.stream_t` alternative), cached `handle` (`uv.handle_t`) view, and the prebuilt `alloc_read`/`deliver_read` callbacks. |
| `FileStdio` (private) | Borrowed CRT `descriptor` (`0`, `1`, or `2`), reusable `read_request` (`uv.fs_t`), lazy 64 KiB `read_buffer` (`uv.buf_t?`), `reading` flag, `deliver_read` `uv.fs_read` callback, subscription capabilities (`publish_read`, `fail_read`, `finish_read`), reusable `write_request` (`uv.fs_t`), `writing` flag, `deliver_write` callback, and intrusive FIFO queue (`write_head`, `write_tail` of `FileWriteOperation`). |
| `StdioBacking` (private) | Union of `stream(StreamStdio)` for pipe/TTY owners and `file(FileStdio)` for borrowed-descriptor file owners. |
| `Stdio` (private) | `backing` (`StdioBacking`), owning `loop`, optional `reads` (`BufferedSubscription`), and `pending_writes`. |
| `ProcessConfig` (private) | Process `options`, stdio `slots`, `environment` overlay, owning `loop`, `consumed` flag, and the rollback `cleanup` capability. |
| `ProcessOwner` (private) | One `uv.process_t` (`native`), owning `loop`, retained exit `result`, and the coalescing `exits` subscription. |
| `InputStream` / `OutputStream` (public) | A captured `Stdio` `handle` or a stable `parent_descriptor`; InputStream also keeps delimiter `excess`. |
| `Process` (public) | The ProcessOwner `handle` and the parent-facing `stdin`, `stdout`, and `stderr` records. |

A stream's concrete kind (`"tty"`, `"pipe"`, or `"file"`) comes from
`Stdio.backing` (`os_stdio_kind`); parent or child provenance never guesses it.
Live process and captured-stream operations check the current Task and the same
Runtime. Closed facades stay idempotent where the public API says so. Cached
stream views keep their native owner, while operations query current
initialization and closing state (`Stdio:is_closed()`); a file-backed `Stdio`
borrows its host descriptor and is never closed within its Runtime.

## Reads, writes, and signals

The generic one-shot and persistent adapter recipes are in
[one-shot Task adapter](libuv-extension-guide.md#one-shot-task-adapter) and
[persistent source adapter](libuv-extension-guide.md#persistent-source-adapter).
The OS-specific choices are:

- **Stream reads.** A native `StreamStdio` input source publishes copied byte
  strings through a `BufferedSubscription`; queued bytes precede EOF or a
  terminal error, and zero-length reads publish nothing. `async.checkpoint()`
  runs before the `has_waiter()` contention diagnostic and before a lazy read
  source starts, so pending cancellation wins without constructing a wait.
  Cancelling one waiter leaves the shared source alive.
- **File reads.** `FileStdio` uses the same `BufferedSubscription` and single
  reader reservation with a demand-driven `uv.fs_read` producer (offset `-1`,
  `FILE_READ_CHUNK_BYTES = 64 * 1024`) instead of continuous read-ahead. After
  `async.checkpoint()`, `FileStdio:ensure_reads` initializes `Stdio.reads` and
  captures `publish`, `fail`, and `finish` on `FileStdio` without starting I/O;
  after the `has_waiter()` contention check, `FileStdio:demand_read` allocates
  `read_buffer` lazily and submits one `uv.fs_read` only when `not self.reading`
  and `not reads:has_pending()`. `FileStdio:complete_read` copies positive bytes
  before `uv.fs_req_cleanup`, then publishes data, finishes on `0` (EOF), or
  fails with `stdio.read` on negative status. Cancelling a waiting reader
  detaches only that waiter in `BufferedSubscription`, allowing immediate
  waiter replacement and retaining any completed chunk, EOF, or error for the
  next reader. EOF and read errors remain sticky in `reads` for the Runtime's
  lifetime.
- **Stream writes.** `start_stream_write` is the registrar for
  `async.await_with`, with a private per-write `StreamWriteOperation` context.
  Closed-stream validation and the empty-write fast path run inside
  registration, after cancellation admission, so a native request exists only
  for a nonempty write. `uv.write_string` retains the original binary string
  and embeds its scalar buffer descriptor until the terminal callback, without
  per-write buffer views. A successful submission increments
  `Stdio.pending_writes`; the terminal callback `stdio_written` decrements it.
  Overlapping stream writes have independent contexts and requests.
- **File writes.** `start_file_write` is the registrar for `async.await_with`,
  with a private `FileWriteOperation` context that also serves as an intrusive
  FIFO node (`write_head` / `write_tail` on `FileStdio`). Empty writes resolve
  immediately during registration; nonempty writes wrap the string in a
  readonly `uv.buf_t` view, increment `Stdio.pending_writes` (which counts both
  in-flight and queued entries), and either submit the first `uv.fs_write`
  (offset `-1`) on the reusable `write_request` when the FIFO is idle or append
  to `write_tail`. `FileStdio:complete_write` and `FileStdio:pump_writes` drive
  continuation from callbacks: a short write advances `entry.offset` and
  resubmits `buffer:slice(entry.offset + 1, #entry.data - entry.offset)` without
  copying suffix strings; a `0`-byte write result on a nonempty remainder fails
  with `uv.EIO` to prevent spinning; negative status fails with `stdio.write`.
  `FileStdio:pop_write` commits queue advancement (`write_head = entry.next`
  and `pending_writes` decrement) before settlement, so a writer resumed inline
  cannot overtake older queued entries. Retired entries retain their Completion,
  native result, and any caught error/trace in the preallocated
  `FileWriteOperation` nodes. The callback pump first links these nodes into a
  local retirement batch and submits the next accepted entry (or empties the
  FIFO), then settles that batch. Between catching a failure and reaching that
  tail-safety boundary, recovery allocates no Titan heap objects of its own and
  does not settle a Completion: it only cleans the request and detaches/links
  existing entries. A later entry whose submission fails is retired the same
  way, so recovery always advances. Fatal settlement and construction/rethrow
  of the first failure happen only after the tail is in flight or empty. The
  guarantee covers heap allocation only: a Lua stack-reservation failure in a
  generated function prologue on this path is not covered, as on every other
  callback path.
  `start_file_write` returns `nil` rather than a `uv.req_t`, so a Task cancelled
  after acceptance stays waiting until its full logical write settles and then
  receives cancellation via `await_with` terminal substitution. Each
  `uv.fs_write` cleans `write_request` via `uv.fs_req_cleanup` before reuse.
  During graceful Runtime end (`async.request_exit`/`os.exit` or Runtime
  failure), new writes are refused by `await_with` admission while the callback
  pump drains accepted FIFO entries without checking `async.is_closing()`.
  Under destructive Lua-state close (`lua_close` -> `runtime_finalize` ->
  `uv.loop_abandon`), UV clears request callbacks and drains only the already
  submitted `uv_fs_write` natively; unsubmitted FIFO entries and short-write
  remainders are dropped and borrowed descriptors `0`, `1`, and `2` remain open.
- **Close.** `close_native` uses `async.await_cleanup_with`, so native close
  completes under sticky Task cancellation.
- **Signals.** `wait_signal` validates the symbolic name, calls
  `async.checkpoint()`, and waits on a `CoalescingSubscription` over one
  `uv.signal_t` started with `uv.signal_start_oneshot`. The producer owns stop,
  close and partial-initialization rollback; lexical cleanup closes the
  subscription after delivery or cancellation.

## Process stream transfer

The generic manual-handoff rules are in
[manual resource handoff](transfer-library.md#manual-resource-handoff); this
section covers the stream gate and schemas.

The public stream records implement the custom `TransferValue` hooks.
`stream_transfer_preflight` requires the stream's loop to be the current
Runtime's loop and the Runtime not to be closing, but does not require a
current Task; encoding and reconstruction are synchronous and never check
cancellation. It rejects a nonzero `pending_writes`, a reserved reader, and any
non-pipe backing (`tty` or `file`), then asks `uv.stream_transfer_status` about
native pending state. `pending_writes` covers accepted writes until their
terminal callbacks (including queued and in-flight file writes). The stream read
callbacks live on `StreamStdio`, so a failed handoff can restart a stopped
reader without replacing its queue.

The payloads use the private ordered `reflect.Type` schemas
`input_transfer_fields` (descriptor, facade excess, terminal marker, optional
`OperationError`, optional `uv.pipe_t` payload, and the queued strings from
`snapshot_pending`) and `output_transfer_fields` (descriptor and optional pipe
payload). A closed native pipe carries no pipe payload. Stable parent facades
(including file-backed parent streams) carry only their descriptor identity and
bypass `stream_transfer_preflight`: output rejects nonzero `pending_writes`, and
input rejects non-empty `excess` or any started `reads` subscription (even after
drained EOF or error). Untouched file-backed parent facades transfer cleanly;
`kind()`, `is_tty()`, and inheritance never create `reads`. Successful captured
encoding clears the source facade's `handle` and `excess`; the old subscription
and native owner retire through their ordinary paths. Reconstruction creates a
fresh subscription with destination closures and replays the copied strings
before resuming production or publishing the terminal state.

The exit watcher, `ProcessOwner`, and the reap obligation never move.
Transferring a stream leaves the source Process's field as an inert facade, so
process cleanup cannot close the adopted descriptor.

The public `InputStream.discard_transfer_payload` and
`OutputStream.discard_transfer_payload` statics decode their own schemas and
close an unadopted pipe through `uv.pipe_t.discard_transfer_payload`, without a
Runtime or Task. They are ordinary stateful Titan APIs, not no-Lua C release
callbacks. Schema, input terminal-marker, and descriptor validation precede
native disposal. Parent descriptor identities and inert captured payloads
return zero without resolving parent stdio or initializing a Runtime.
Callers clear their retained packet after the native close attempt and before
reporting its status, because that attempt is terminal even on `EINTR`.
Manual capabilities remain exactly-once and are never automatically disposed by
native packet discard.

## Shell process stream

`popen` builds the platform shell command and directly calls `spawn` with
captured writable stdin plus one merged stdout/stderr pipe. Shell selection and
Windows argument transport are described in
[spawn transaction and exit delivery](#spawn-transaction-and-exit-delivery).
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
adoption succeeds), and `close` discards it with
`OutputStream.discard_transfer_payload`. `close` clears the field after that native
close attempt and before reporting its status, so a close error is never
retried against a possibly reused descriptor. After both detach, the payload is
the private `stream_transfer_fields` protobuf schema holding the two OS child
payloads; a lexical guard discards both if final serialization raises.

`from_transfer_payload` decodes both strings and allocates the composite before
adopting either pipe. If the readable pipe fails to adopt, a guard calls the OS
module's `discard_unpublished_stdio` on the already adopted writable owner,
which starts native close without waiting and so keeps the hook nonyielding.

## Shell and disposal tests

`spec/stdlib/titan/os/process_tests/shell_test.titan` exercises all seven IO
Interface conversions, merged output, binary delimiter reads, shell selection,
Unicode/quoting, retained exit status, repeated close, termination, cancellation,
and cross-state pipe handoff with the Process retained at origin.
`disposal_test.titan` checks endpoint disposal without a Task or adoptable
Runtime, identity-only parents, inert captures, and invalid schema/discriminators.

`spec/support/check_io_transfer_failure.sh` (Linux only; other platforms report
a classified skip) takes an absolute installed SDK prefix and a new absolute
output directory. It compiles `spec/fixtures/stdlib/native/io_transfer_dup_failure.c`
into an object, links the `io_transfer_failure_app` fixture with that object
passed through `-X`, and adds `-Wl,--wrap=dup,--wrap=close` through
`TITAN_EXTRA_LDFLAGS`
to make the second pipe duplication fail, then checks write, retry, close,
terminal close-error consumption without retry, and exit cleanup of the staged
descriptor. The close-error guard never closes a potentially reused descriptor.

## Stable parent streams and platform facts

The module-level `stdin`/`stdout`/`stderr` records are stable across Runtime
sessions. Their `Stdio` owners are acquired lazily and cached for the current
loop; a later Runtime acquires its own and clears old excess. Within the same
Runtime, a stable input facade keeps its previous `Stdio` even after EOF or a
read error retired a native stream duplicate (and `Stdio:is_closed()` is always
false for a `FileStdio` owner, keeping its sticky EOF or error in the cache),
so queued bytes, excess, and sticky terminal outcomes stay observable for that
Runtime. Parent-facade close is an idempotent no-op; Runtime cleanup retires
remaining native stream handles. `with_parent_*` configuration obtains a usable
owner from `initialize_parent_stdio`: `configure_parent` selects
`uv.INHERIT_STREAM` or `uv.INHERIT_FD` from the backing, and `bind_slot`
installs `uv.stdio_data_t.stream(native)` or `uv.stdio_data_t.fd(descriptor)`
(CRT descriptor `0`, `1`, or `2`).

For `UV_FILE` parent descriptors (regular files, `/dev/null` and other non-TTY
character devices, and Windows disk files and `NUL`), `parent_stdio_kind`
returns `uv.FILE` and `initialize_parent_stdio` constructs `FileStdio` borrowing
CRT descriptor `0`, `1`, or `2` directly without duplicating it. Unlike
`uv_pipe_t` and `uv_tty_t`, whose `uv_close` closes their descriptor and
therefore requires a close-on-exec duplicate, `uv_fs_read` and `uv_fs_write`
never close the descriptor, and a duplicate would still share the underlying open
file description's offset while requiring asynchronous and state-close release
machinery. Borrowing requires only that the host keep descriptors `0`, `1`, and
`2` open and unreplaced while the Runtime's cached owner and accepted requests
use them.

The platform helpers (`os_platform.h`) duplicate parent descriptors for
stream-backed stdio and inspect native socket facts; they contain no libuv
header, owner layout, callback, or Task protocol. UV `guess_handle` selects
pipe, TTY, or file where possible. An unknown descriptor is inspected explicitly
instead of trusting errno from a failed guess. Socket-family and socket-type
contradictions defeat a pipe hint; only the narrow metadata-denial case may use
the `TITAN_STDIO_PIPE_FDS` hint (`parent_stdio_pipe_hint`). A stream duplicate
stays lexically owned until a public UV handle adopts it. Windows CRT
descriptor/`HANDLE` differences for streams are handled by the platform helper
and public identifier queries, while `FileStdio` passes integer CRT descriptors
directly to `uv.fs_read`, `uv.fs_write`, and `uv.stdio_data_t.fd` without
`os_fd_t` conversion or `_setmode` changes.

Captured stdout and stderr use the same buffered stream implementation. Merged
output stores one InputStream in both Process fields, so excess, EOF, and close
are shared. Replacing a configuration slot disposes an old owned capture or
merged endpoint only when no retained slot still refers to it.

## Spawn transaction and exit delivery

Process configuration applies options in order and owns every unpublished
stdio endpoint. Public UV process options carry the final argv, environment,
and stdio records. The environment is inherited by default; overlays are built
from a copied environment snapshot using the platform's name-comparison
policy. `os_shell_command` builds the shell command used directly by `os.popen`:
`/bin/sh -c COMMAND` on POSIX, and on Windows the
`cmd.exe` in the `GetSystemDirectoryW` directory with `/d /s /c` and the command
in outer quotes. `COMSPEC` is not consulted. The private `with_shell_arguments`
option sets `uv.PROCESS_WINDOWS_VERBATIM_ARGUMENTS` on Windows only, so ordinary
`os.spawn` keeps its normal argument transport.

Configuration creation and spawn require a running Task and reject a Runtime
whose `async.is_closing()` is true. Spawn has no cancellation checkpoint: a
pending Task cancellation alone does not forbid spawning a child.

`os_process_spawn_with_config` keeps lexical ownership in the configuration
until native spawn, captured-read registration, and result construction are
ready to publish. One private Config completion capability owns a
preinitialized native timer and the unpublished process. Both handle views,
callbacks, and signal numbers are prepared before child acceptance. Empty slots
and the public Process are allocated before completion closes the unused timer;
field-only assignments then clear Config ownership and commit publication.

The protected spawn body catches failures before Config cleanup and runs a
nested protected cleanup followed by a bare rethrow, preserving the original
error and traceback across yielding cleanup and secondary failures. Config
commits its consumed state and detaches the capability before invoking it.
Rollback selects its exit-callback branch before discarding streams, and a
`defer` guarantees the cancellation-shielded `async.await_cleanup_with` even if
stream discard fails. That branch skips `ExitStatus` construction and
subscription publication but keeps the native watcher through the actual exit
and close.

An active unpublished child receives SIGTERM, and a one-shot 30000 ms native
timer sends SIGKILL if it is still active. Cached loop time is refreshed at the
initial signal. The timer is initialized before spawn, so its fixed-duration
start with a prebuilt callback cannot allocate. Early child exit or escalation
closes the timer, and cleanup resolves only after both native close callbacks
retired their owners; registration also checks for already completed
retirement. A failed signal never abandons an active watcher: the 30 seconds
bound the grace period, not exit completion. The rollback state holds one
Completion and the operation number captured at registration; retirement
snapshots and clears it before settlement. Do not add a cleanup Task, saved-PID
poller, or extra scheduler queue.

Native spawn failure follows actual handle state: an uninitialized process
needs no close, an initialized inactive process must close, and an active
process keeps its exit obligation whatever the returned status. CREATE_PIPE
eligibility and the pinned native failed-spawn repair are in the
[public process policy](../language/uv/PROCESS-POLICY.md).

The exit callback records the `ExitStatus`, closes the process handle,
publishes the coalesced result, and ends the subscription. Cancelling a wait
detaches only the waiter; the child stays retained until exit and reap.
Repeated waits return the stored result. `wait` calls `async.checkpoint()`
before cached-result delivery and before the competing-wait diagnostic.
`is_running` and `kill` keep the same Runtime checks and symbolic signal
policy; closing captured streams does not kill the child.

`os.exit` calls `async.request_exit`; async cancels and drains the entrypoint
session, including accepted requests and cleanup, before returning the exit
code ([shutdown protocol](libuv-runtime.md#shutdown-and-process-control)).
