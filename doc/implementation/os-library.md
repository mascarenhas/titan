# Operating-system library implementation

The folder module `titan/os/` implements the [OS API](../language/standard-library-os.md):
environment and host queries, calendars, parent standard streams, process
configuration, captured streams, the `popen` shell facade, signals, and
graceful exit. Its native contributors use ordinary compiled imports of public
`uv` and `async`. UV owns native storage and callback lifetimes and async owns
Task waits and subscriptions ([runtime](libuv-runtime.md)); all OS-specific
process and stdio policy stays here.

| Source | Responsibility |
| --- | --- |
| `os.titan` | Shared main: `Date`, `InputStream`, `OutputStream`, the stable parent-stream variables, calendar and locale operations, text and delimiter helpers, and the environment and exit facades. Its C imports are `time.h`, `locale.h`, and `string.h`; it imports no `uv` and names no libuv type. |
| `clock.native.titan` | CPU clock and current timestamp queries through public UV. |
| `environment.native.titan` | Process environment queries and mutations. |
| `stdio.native.titan` | Native `Stdio` owners, parent descriptor probes and caches, stream operations and transfer hooks, and native status translation. |
| `process.native.titan` | Child processes, shell streams, signals, host identity, graceful exit, and the sized-buffer helper shared with environment queries. |
| `os_platform.h`, `os_environment.h` | Native platform operations, beside the canonical main; imported only by native contributors. |
| `clock.browser.titan` | Current timestamp through libc `time`; no CPU-clock member. |
| `environment.browser.titan` | Instance-local libc environment operations and browser `OperationError` construction. |
| `environment.browser.h` | The two POSIX `setenv`/`unsetenv` declarations hidden by emsdk 6.0.13's `stdlib.h` without feature macros; a feature macro here would arrive too late in the generated translation unit. No function bodies. |
| `process.browser.titan` | Task-only graceful exit through `async.request_exit`. |
| `stdio.browser.titan` | SDK-backed parent streams, declared kinds, read state, and parent-only transfer hooks. |

Contributors share the module's private namespace. The main calls `os_time`,
`os_getenv`, `os_setenv`, `os_unsetenv`, `os_exit`, and `read_stream`; both
targets define those seams and the private `Stdio` named by the unchanged
stream fields. `captured_input_is_closed` is shared because it reads only
`InputStream` fields. Shared imports precede the stream variables and
transfer-field initializers. Native-only process, signal, host-query, and CPU
clock members have no browser declarations.

Calendar, formatting, locale, and time-difference operations keep their ISO C
implementation, adapted from Lua 5.5.1 `loslib.c`, with Lua-compatible
validation. Native clocks, environment snapshots, paths, process identifiers,
and signal constants use public UV queries. Sized string queries go through
`os_sized_buffer`, which retries `ENOBUFS` and grows the buffer; a missing
environment variable is nil. `os.exepath` first calls `uv.setup_process_args()`
and raises in an ordinary Lua host, and treats a result that fills the buffer
as possibly truncated. The SIGPIPE policy and generated-main hook belong to
async initialization, not to this module
([startup policy](libuv-runtime.md#startup-policy)).

## Browser parent-stream owner

The browser composition imports public `async`, `browser`, `protobuf`, and
`reflect`, never `uv`. A module Array indexed by parent descriptor plus one
retains the three lazy `Stdio` owners. Each caches its SDK source handle and
optional declared kind for the state; input also owns a request, optional
chunk and failure, EOF, waiter Task, lazy ResumeToken, and Runtime registration.
Output owns its accepted-shutdown flag and pending-write count.

`kind` calls `titan:stdio` once and validates the four declared strings in
Titan. A missing declaration stays nil: `kind()` raises the documented
member-specific `ENOSYS` error and `is_tty()` is false. Invalid declarations
retain a plain diagnostic naming the option. Missing `titan:stdin` is cached
as unavailable, not converted to EOF.

Each nonempty output write registers one request with `async.await` and
`titan:stdout` or `titan:stderr`. Its completion and failure callbacks retire
the pending count before settling the wait, and `defer` closes the request.
There is no cancellation action: an admitted write keeps its request until
the sink settles. An empty write only checkpoints and checks an existing
owner's shutdown flag, without opening a source or allocating an owner.
Shutdown checkpoints, checks for declared TCP, and starts an argumentless
request on the same source. The accepted-shutdown flag changes only after
start succeeds, so failed admission cannot poison later writes.

Input checkpoints before contention, buffered host chunks, failure, and EOF.
The facade's delimiter excess precedes that checkpoint, matching native
`read_stream`'s Task-check, excess, then owner-read order.
One request belongs to the stream, not to its current waiter. Cancelling a
read clears only that Task reservation; completion can still retain an empty
or nonempty chunk, EOF, or sticky failure for a successor. The callback closes
the request and resumes only the current waiter with its token. A bad result
type becomes sticky `stdio.read: EIO`. Shared `read_input_until` owns delimiter
splitting and excess; the browser wrapper translates only primitive-read
unavailability to `os.InputStream.read_until`.

The first read registers one Runtime-close listener. It closes any request
and clears the waiter, chunk, failure, EOF, read-started flag, and facade
excess, so a later Runtime sees none of its predecessor's input state.
The source handle and declared kind remain state-owned. Parent `close()` has
no Task requirement and does nothing to those resources.

Parent transfer hooks use the native descriptor payload schemas. Adoption
returns the facade records that the contributor bound at module
initialization, not the assignable `stdin`/`stdout`/`stderr` variables, so a
state keeps one facade per descriptor and the read-state reset above always
reaches it. The hooks reject active input or pending output, and discarding a
valid parent payload releases nothing. There is no browser captured-stream
adoption path.

The browser error constructor uses negated libc errno values and the native
libuv names/messages. Host failure callbacks use `browser.failure_text` to
consume the thrown handle; the OS adapter chooses the operation and fallback
text. Environment calls capture errno immediately; `ENOMEM` is included
because libc `setenv` can allocate. Browser exit catches only failure of the
Task lookup, leaving the sticky cancellation from `request_exit` untouched.

The domain-owner table and native I/O sections below describe the native
composition.

## Domain owners

| Owner | Fields and responsibility |
| --- | --- |
| `StreamStdio` (private) | `native` (a `uv.stream_t` alternative: `pipe`, `tty`, or `tcp`), cached `handle` (`uv.handle_t`) view, and the prebuilt `alloc_read`/`deliver_read` callbacks. |
| `FileStdio` (private) | Borrowed CRT `descriptor` (`0`, `1`, or `2`), reusable `read_request` (`uv.fs_t`), lazy 64 KiB `read_buffer` (`uv.buf_t?`), `reading` flag, `deliver_read` `uv.fs_read` callback, subscription capabilities (`publish_read`, `fail_read`, `finish_read`), reusable `write_request` (`uv.fs_t`), `writing` flag, `deliver_write` callback, and intrusive FIFO queue (`write_head`, `write_tail` of `FileWriteOperation`). |
| `StdioBacking` (private) | Union of `stream(StreamStdio)` for pipe/TTY/TCP owners and `file(FileStdio)` for borrowed-descriptor file owners. |
| `Stdio` (private) | `backing` (`StdioBacking`), owning `loop`, optional `reads` (`BufferedSubscription`), and `pending_writes` (accepted writes plus an accepted TCP shutdown). |
| `ProcessConfig` (private) | Process `options`, stdio `slots`, `environment` overlay, owning `loop`, `consumed` flag, and the rollback `cleanup` capability. |
| `ProcessOwner` (private) | One `uv.process_t` (`native`), owning `loop`, retained exit `result`, and the coalescing `exits` subscription. |
| `InputStream` / `OutputStream` (public) | A captured `Stdio` `handle` or a stable `parent_descriptor`; InputStream also keeps delimiter `excess`. |
| `Process` (public) | The ProcessOwner `handle` and the parent-facing `stdin`, `stdout`, and `stderr` records. |
| `InputOutputStream` (public) | Shell facade over one Process: private `process`, `input`, `output`, staged `input_packet`, cached `status`, `closed`, and `pending_operations` ([shell process stream](#shell-process-stream)). |

A stream's concrete kind (`"tty"`, `"pipe"`, `"file"`, or `"tcp"`) comes from
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
  Inside registration, after cancellation admission, it runs three checks in
  order. It rejects a closed stream. It rejects a stream that
  `uv.is_writable` reports unwritable with `stdio.write: EPIPE`, as
  `net.Connection:write` does; this is how empty writes fail after an accepted
  TCP shutdown. It resolves an empty write without native work. A native
  request therefore exists only for a nonempty write to a writable stream.
  `uv.write_string` retains the original binary string
  and embeds its scalar buffer descriptor until the terminal callback, without
  per-write buffer views. A successful submission increments
  `Stdio.pending_writes`; the terminal callback `stdio_written` decrements it.
  Overlapping stream writes have independent contexts and requests.
- **TCP shutdown.** `os_stdio_shutdown` validates the Runtime and calls
  `async.checkpoint()`, so pending cancellation wins over the kind check.
  Non-`tcp` backings raise `stdio.shutdown: ENOTSUP` without touching state.
  For `uv.stream_t.tcp` it awaits `start_stream_shutdown` with a private
  `StreamShutdownOperation` context. libuv's writable flag is the only
  shutdown state. `uv_shutdown` clears that flag when it accepts a request and
  refuses later submissions with `ENOTCONN`. The registrar therefore resolves
  at once when `uv.is_writable` is false, as `net.Connection:shutdown` does,
  and otherwise submits `uv.shutdown(request, native, stdio_shut_down)`. libuv
  defers the actual `shutdown(2)` until previously accepted writes drain. An
  accepted request increments `Stdio.pending_writes` until `stdio_shut_down`
  decrements it and settles the operation with `stdio.shutdown` on a negative
  status. The ordinary `await_with` policy never cancels accepted work: a
  cancelled caller stays waiting until that callback, while UV roots the
  request and its data-slot context.
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
non-pipe backing (`tty`, `tcp`, or `file`), then asks `uv.stream_transfer_status`
about native pending state. `pending_writes` covers accepted stream writes,
queued and in-flight file writes, and an accepted TCP `uv.shutdown`, until
their terminal callbacks; both stdio rejection sites report it as pending
output. The stream read callbacks live on `StreamStdio`, so a failed handoff
can restart a stopped reader without replacing its queue.

The payloads use the private ordered `reflect.Type` schemas
`input_transfer_fields` (descriptor, facade excess, terminal marker, optional
`OperationError`, optional `uv.pipe_t` payload, and the queued strings from
`snapshot_pending`) and `output_transfer_fields` (descriptor and optional pipe
payload). A closed native pipe carries no pipe payload. Stable parent facades,
whatever their backing, carry only their descriptor identity and bypass
`stream_transfer_preflight`. Output rejects a nonzero `pending_writes`.
Input rejects nonempty `excess` or any started `reads` subscription, even
after drained EOF or error. Untouched parent facades transfer cleanly;
`kind()`, `is_tty()`, `close()`, and inheritance never create `reads`. A
completed TCP shutdown has already decremented `pending_writes`. The facade
then transfers its identity, and the destination adopts a fresh `uv_tcp_t`
over a socket whose write side remains shut down. Successful captured encoding
clears the source facade's `handle` and `excess`; the old subscription and
native owner retire through their ordinary paths. Reconstruction creates a
fresh subscription with destination closures and replays the copied strings
before resuming production or publishing the terminal state.

The exit watcher, `ProcessOwner`, and the reap obligation never move.
Transferring a stream leaves the source Process's field as an inert facade, so
process cleanup cannot close the adopted descriptor.

`InputStream.discard_transfer_payload` and
`OutputStream.discard_transfer_payload` are the public, adoption-free release
path for these payloads. Each decodes its own schema with the same validation
as the matching `from_transfer_payload` (terminal marker and failure presence,
inert parent identity, descriptor `0`/`1`/`2` or `-1`, and, for input, a live
marker only with a pipe payload) before touching native state. A parent
identity or a captured payload without a pipe payload returns `0`. Otherwise it
calls `uv.pipe_t.discard_transfer_payload`, which validates the descriptor and
issues one native `close`. Nothing reads the current Runtime, current Task,
parent `Stdio` cache, or loop, so disposal works in a fresh state and after
Runtime exit has closed adoption. They are ordinary Titan functions running in
a live Lua state, not C-only packet-resource release callbacks, and
`transfer.discard_message` never calls them. A native close attempt is
terminal even on `EINTR`: callers that retain a payload copy clear it before
reporting the status. The payload formats carry no type discriminator, so the
manuals require the caller to pass a payload to its producing type's disposer.

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
or dispatch layer. `titan.os` does not import `titan.io`: each consumer's
conversion site builds the Interface wrapper, while the nominal identity stays
`titan.os.InputOutputStream`. `wait` calls `Process:wait` only while `status`
is nil and returns the cached normal-or-signal result afterwards.

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
owner from `initialize_parent_stdio`. `configure_parent` selects
`uv.INHERIT_STREAM` for TTY, pipe, and TCP owners and `uv.INHERIT_FD` for file
owners. `bind_slot` installs `uv.stdio_data_t.stream(native)` or
`uv.stdio_data_t.fd(descriptor)` (CRT descriptor `0`, `1`, or `2`).

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
pipe, TTY, file, or (on Unix) TCP where possible. `parent_stdio_kind` finishes
every check before `initialize_parent_stdio` duplicates anything.

For a Unix `uv.TCP` guess, `titan_inspect_parent_tcp` reads
`getsockopt(SOL_SOCKET, SO_ACCEPTCONN)` on Linux (or `getsockopt(IPPROTO_TCP,
TCP_CONNECTION_INFO)` for `TCPS_LISTEN` on macOS) and `getpeername`. A listening
socket raises `stdio.parent.kind: ENOTSUP` with probe text `listening TCP
socket`. A
socket without a peer (`ENOTCONN` or `EINVAL`) raises the same error with
`unconnected TCP socket`. Any other probe errno keeps its translated code.
`getpeername` cannot tell a socket that never connected from one that a peer
reset or that has fully closed. A Runtime, state, or child that classifies the
descriptor after that point therefore rejects it the same way. The guess
already guarantees an `AF_INET`/`AF_INET6` stream socket, because libuv
checks the `getsockname` family, so the family is not checked again.
`initialize_parent_stdio` then duplicates the descriptor with close-on-exec,
creates the owner with `new_tcp_stdio` (`uv.tcp_init`), and adopts the
duplicate with `uv.tcp_open(native, uv.os_sock_t.from_integer(duplicate))`.
Until that call succeeds, the lexical `defer` owns the duplicate, and
`discard_unpublished_stdio` closes an initialized handle whose open failed.
Afterwards the handle owns it. `uv_tcp_open` sets `O_NONBLOCK` on the shared
open file description and marks the handle readable and writable without
consulting earlier shutdown state.

On Windows, `GetFileType` reports sockets as `FILE_TYPE_PIPE`. libuv maps
that to `uv.NAMED_PIPE` and never guesses `uv.TCP`. For both `uv.NAMED_PIPE`
and `uv.UNKNOWN_HANDLE` guesses, `parent_stdio_kind` therefore calls
`titan_probe_parent_stdio`. The probe asks Winsock about the CRT descriptor's
`HANDLE` with `getsockopt(SOL_SOCKET, SO_TYPE)`, which reads no data. Winsock
is already initialized, because the Runtime's `uv_loop_init` ran libuv's
Winsock setup. A successful query raises `stdio.parent.kind: ENOTSUP` with
probe text `socket-backed parent stdio is not supported on Windows`.
`WSAENOTSOCK` continues on the pipe or unknown-handle path. Any other Winsock
error raises with probe `getsockopt(SO_TYPE)`. The Windows
`titan_inspect_parent_tcp` exists only because foreign imports are
unconditional, and it reports the same rejection.

On Unix, an unknown descriptor is inspected explicitly instead of trusting
errno from a failed guess. Socket-family and socket-type contradictions defeat
a pipe hint; only the narrow `AF_UNIX` metadata-denial case may use the
`TITAN_STDIO_PIPE_FDS` hint (`parent_stdio_pipe_hint`), which a TCP guess never
consults. A stream duplicate stays lexically owned until a public UV handle
adopts it. Windows CRT descriptor/`HANDLE` differences for streams are handled
by the platform helper and public identifier queries, while `FileStdio` passes
integer CRT descriptors directly to `uv.fs_read`, `uv.fs_write`, and
`uv.stdio_data_t.fd` without `os_fd_t` conversion or `_setmode` changes.

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

## Shell and disposal tests

`spec/stdlib/titan/os/process_tests/shell_test.titan` covers conversion to all
seven IO Interfaces, merged output, binary delimiter reads, fixed shell
selection, quoting and Unicode arguments, retained exit status, repeated close,
termination, cancellation, and cross-state pipe handoff with the Process kept
at the origin. `disposal_test.titan` covers endpoint disposal in a fresh state
and after Runtime exit, parent identities, payloads without a pipe, and
malformed schemas and discriminators.

`spec/support/check_io_transfer_failure.sh` (Linux only; other platforms report
a classified skip) takes an absolute installed SDK prefix and a new absolute
output directory. It compiles `spec/fixtures/stdlib/native/io_transfer_dup_failure.c`
into an object, links the `io_transfer_failure_app` fixture with that object
passed through `-X`, and adds `-Wl,--wrap=dup,--wrap=close` through
`TITAN_EXTRA_LDFLAGS`. The wrappers fail the second pipe duplication of an
armed handoff and can make the close of a staged descriptor report `EINTR`
after really closing it. The fixture checks write, retry, and close recovery
of a staged shell pipe, that a terminal close error consumes the staged
payload without a retry, that both endpoint disposers return that status while
the originating Process stays usable, and exit cleanup with adoption closed.
After an injected close error the wrapper intercepts later closes of that
descriptor number instead of closing a possibly reused descriptor.
