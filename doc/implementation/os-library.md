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
| `Stdio` (private) | `native` (a `uv.stream_t` alternative), cached `handle` view, owning `loop`, optional `reads` buffered subscription, the prebuilt `alloc_read`/`deliver_read` callbacks, and `pending_writes`. |
| `ProcessConfig` (private) | Process `options`, stdio `slots`, `environment` overlay, owning `loop`, `consumed` flag, and the rollback `cleanup` capability. |
| `ProcessOwner` (private) | One `uv.process_t` (`native`), owning `loop`, retained exit `result`, and the coalescing `exits` subscription. |
| `InputStream` / `OutputStream` (public) | A captured `Stdio` `handle` or a stable `parent_descriptor`; InputStream also keeps delimiter `excess`. |
| `Process` (public) | The ProcessOwner `handle` and the parent-facing `stdin`, `stdout`, and `stderr` records. |

A stream's concrete kind is the `uv.stream_t` alternative; parent or child
provenance never guesses it. Live process and captured-stream operations check
the current Task and the same Runtime. Closed facades stay idempotent where the
public API says so. Cached views keep their native owner, but operations query
current initialization and closing state rather than caching liveness.

## Reads, writes, and signals

The generic one-shot and persistent adapter recipes are in
[one-shot Task adapter](libuv-extension-guide.md#one-shot-task-adapter) and
[persistent source adapter](libuv-extension-guide.md#persistent-source-adapter).
The OS-specific choices are:

- **Reads.** A native input source publishes copied byte strings through a
  `BufferedSubscription`; queued bytes precede EOF or a terminal error, and
  zero-length reads publish nothing. `async.checkpoint()` runs before the
  `has_waiter()` contention diagnostic and before a lazy read source starts, so
  pending cancellation wins without constructing a wait. Cancelling one waiter
  leaves the shared source alive.
- **Writes.** `start_stdio_write` is the named registrar for
  `async.await_with`, with a private per-write `WriteOperation` context.
  Closed-stream validation and the empty-write fast path run inside
  registration, after cancellation admission, so a native request exists only
  for a nonempty write. `uv.write_string` retains the original binary string
  and embeds its scalar buffer descriptor until the terminal callback, without
  per-write buffer views. A successful submission increments
  `Stdio.pending_writes`; the terminal callback `stdio_written` decrements it.
  Overlapping writes have independent contexts and requests.
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
non-pipe stream, then asks `uv.stream_transfer_status` about native pending
state. `pending_writes` covers accepted writes until their terminal callbacks,
including writes whose bytes already left the native queue. The read callbacks
live on the `Stdio` owner, so a failed handoff can restart a stopped reader
without replacing its queue.

The payloads use the private ordered `reflect.Type` schemas
`input_transfer_fields` (descriptor, facade excess, terminal marker, optional
`OperationError`, optional `uv.pipe_t` payload, and the queued strings from
`snapshot_pending`) and `output_transfer_fields` (descriptor and optional pipe
payload). A closed native pipe carries no pipe payload. Stable parent facades
carry only their descriptor identity and reject active input state or pending
writes. Successful encoding clears the source facade's `handle` and `excess`;
the old subscription and native owner retire through their ordinary paths.
Reconstruction creates a fresh subscription with destination closures and
replays the copied strings before resuming production or publishing the
terminal state.

The exit watcher, `ProcessOwner`, and the reap obligation never move.
Transferring a stream leaves the source Process's field as an inert facade, so
process cleanup cannot close the adopted descriptor.

The private helpers `discard_input_transfer_payload` and
`discard_output_transfer_payload` decode these schemas and close an unadopted
pipe through `uv.pipe_t.discard_transfer_payload`, without a Runtime. `io`
uses them for shell-stream cleanup; callers clear their retained packet after
the native close attempt and before reporting its status, because a close
attempt is terminal even on `EINTR`.

## Stable parent streams and platform facts

The module-level `stdin`/`stdout`/`stderr` records are stable across Runtime
sessions. Their native wrappers are acquired lazily and cached for the current
loop; a later Runtime acquires its own and clears old excess. Within the same
Runtime, a stable input facade keeps its previous `Stdio` even after EOF or a
read error retired the native duplicate, so its queued bytes and excess stay
readable. Parent-facade close is an idempotent no-op; Runtime cleanup retires
remaining wrappers. `with_parent_*` configuration obtains a separate usable
wrapper for inheritance, which may replace a retired cache entry without
replacing the input facade's buffered read owner.

The platform helpers (`os_platform.h`) duplicate parent descriptors and inspect
native facts; they contain no libuv header, owner layout, callback, or Task
protocol. UV `guess_handle` selects pipe or TTY where possible. An unknown
descriptor is inspected explicitly instead of trusting errno from a failed
guess. Socket-family and socket-type contradictions defeat a pipe hint; only
the narrow metadata-denial case may use the `TITAN_STDIO_PIPE_FDS` hint
(`parent_stdio_pipe_hint`). The duplicate stays lexically owned until a public
UV handle adopts it. Windows descriptor/HANDLE differences are handled by the
platform helper and public identifier queries.

Captured stdout and stderr use the same buffered stream implementation. Merged
output stores one InputStream in both Process fields, so excess, EOF, and close
are shared. Replacing a configuration slot disposes an old owned capture or
merged endpoint only when no retained slot still refers to it.

## Spawn transaction and exit delivery

Process configuration applies options in order and owns every unpublished
stdio endpoint. Public UV process options carry the final argv, environment,
and stdio records. The environment is inherited by default; overlays are built
from a copied environment snapshot using the platform's name-comparison
policy. `os_shell_command` builds the shell command used by `io.popen` (through
the private `spawn_shell`): `/bin/sh -c COMMAND` on POSIX, and on Windows the
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
