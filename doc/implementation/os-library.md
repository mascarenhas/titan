# Operating-system library implementation

`titan.os` owns the [OS API](../language/standard-library-os.md): environment and
host policy, calendars, parent standard streams, process configuration, captured
streams, signals, and graceful exit. It uses ordinary compiled imports of
public `uv` and `async`. UV owns native storage and callback lifetimes; async
owns Task waits and subscription queues. Neither contains OS-specific process
or stdio policy.

Calendar, formatting, locale, and time-difference operations retain their ISO C
implementation and Lua 5.5-compatible validation. Clocks, environment snapshots,
paths, process identifiers, and supported signal constants use public UV
queries. Sized string queries retry `ENOBUFS`; missing environment variables
remain nil. `os.exepath` first calls `uv.setup_process_args()`, rejects an
ordinary Lua host, and grows its buffer when native exepath may have truncated
at the capacity boundary. Async initialization owns the generated-main hook and
SIGPIPE policy; importing UV alone applies neither.

## Domain owners

| Owner | Responsibility |
| --- | --- |
| `Stdio` | One public `uv.stream_t`, its cached `uv.handle_t` view, owning loop, and optional buffered read subscription. |
| `ProcessConfig` | Public process options, stdio slots, environment overlays, owning loop, and consumed state. |
| `ProcessOwner` | One `uv.process_t`, owning loop, retained exit result, and coalescing exit subscription. |
| Public `InputStream` / `OutputStream` | Stable parent-descriptor identity or a captured Stdio, plus InputStream delimiter excess. |
| Public `Process` | The ProcessOwner and the selected parent-facing stream records. |

These records keep domain policy separate from the public UV owner views. A
stream's concrete kind is represented by `uv.stream_t`'s alternatives; parent or
child provenance does not guess its native kind. Live process and captured
stream operations retain explicit current-Task and same-Runtime checks.
Terminal closed-facade behavior stays idempotent where the public API specifies
it. A cached view preserves its native owner; operations still query current
initialization and closing state instead of caching liveness.

## Reads, writes, and signals

A native input source publishes copied byte strings through
`BufferedSubscription`. Buffered bytes precede EOF or a terminal error. Zero
read notifications do not produce items. The subscription supplies the single
reader reservation; `has_waiter()` gives the domain its established contention
diagnostic without a shadow flag. `async.checkpoint()` checks ordinary
cancellation at the established admission point before contention and before
accepting a lazy read source, without constructing a wait or changing Task
status. Cancelling one waiter removes its reservation synchronously and leaves
the shared source alive.

Writes submit a fresh public request through ordinary `async.await_with` and
`uv.write_string`. A private per-write context supplies the Stdio and string to
a named registrar. Closed-stream validation and the empty-write fast path stay
inside registration, after ordinary cancellation admission; the native request
is constructed only for a nonempty write. The request retains the original binary string and embeds
its scalar descriptor through terminal completion, without per-write buffer
views or descriptor Arrays. Overlapping writes have independent requests;
their terminal UV callbacks root each old payload before clearing request
fields. Each context also captures the Task-owned Completion and its exact
suspension number, and the request's userdata carries that context to a named
callback. Close uses `async.await_cleanup_with` and its own handle context,
preserving the native close obligation under sticky Task cancellation. Named
terminal callbacks snapshot their Completion and number, then clear userdata
and the context's Completion reference before settlement can resume the Task.
Unexpected terminal callback failures call
`completion:fatal(number, error, traceback)` and bare rethrow; ordinary negative
statuses become `async.OperationError` with the existing operation label. The
per-write context replaces a captured registrar; overlapping writes retain
independent contexts and requests instead of sharing a mutable stream slot.

`wait_signal` validates the symbolic signal, calls `async.checkpoint()`, and
uses a coalescing subscription over a one-shot `uv.signal_t`.
The producer owns stop/close and partial-initialization rollback. Lexical cleanup
closes the subscription after delivery or cancellation; the signal handle is
never a Task-owned scheduler special case.

## Process stream transfer

The public stream records implement ordinary custom `TransferValue` hooks.
Transfer preflight checks the active Runtime's identity and shutdown state
directly, without the current-Task requirement used by ordinary stream I/O.
Encoding and reconstruction remain synchronous and never check cancellation.
They preflight reader reservations, accepted writes, and UV native pending
state before changing the source. `Stdio.pending_writes` counts accepted writes
through their terminal callbacks, including callbacks whose bytes have already
left the native write queue. Read callbacks are retained on the domain owner so
a failed handoff can restart a stopped watcher without replacing its queue.

Input hooks use `BufferedSubscription:snapshot_pending` to copy queued strings
and the terminal result before detachment. Private ordered `reflect.Type` Arrays
define the anonymous-root protobuf schemas. The input payload carries those
strings, facade excess, a terminal marker, an optional `OperationError`, and an
optional known `uv.pipe_t` byte payload. A closed native pipe needs no descriptor.
Successful encoding clears the original facade's handle and excess; its old
subscription and native owner retire through their existing ownership paths.
Reconstruction creates a fresh subscription with destination closures and
replays the copied strings before resuming production or publishing terminal
state. Output hooks only carry the pipe packet. Stable parent facades instead
copy descriptor identity, with active input state or pending writes rejected.
A lexical guard discards detached child bytes if outer serialization fails; it
uses the public UV cleanup method without adopting another native owner.

The Process exit watcher, process owner, and reap obligation never move.
Transferring a public endpoint leaves the original Process's stream field as an
inert facade, so existing process cleanup cannot close the adopted descriptor.
No resource registry or replay protection is introduced: the caller owns the
manual exactly-once handoff and failure recovery contract.

Private input/output packet discard helpers support `io`'s handoff cleanup.
They decode their known protobuf schemas and delegate to the public pipe
discard method without a Runtime or native-handle adoption. The caller clears its retained packet after the native call, before
reporting a close error, because a close attempt is terminal even on EINTR.

## Stable parent streams and platform facts

The module-level stdin/stdout/stderr records remain stable across Runtime
sessions. Their native wrappers are acquired lazily and cached for the current
loop; a later Runtime creates its own wrappers. A stable input facade retains
its exact previous `Stdio` while that owner's loop is the current Runtime,
even if EOF or a read error has retired the native duplicate. Its subscription
queue and delimiter excess therefore remain readable in that Runtime. A later
Runtime reacquires a wrapper and clears old excess. Parent-facade close is an
idempotent no-op; Runtime cleanup retires any remaining native wrappers.
`with_parent_*` configuration separately obtains a usable native wrapper for
inheritance, which can replace a retired cache entry without replacing the
input facade's buffered read owner.

The OS platform helpers duplicate parent descriptors and inspect native facts.
They contain no libuv header, owner layout, callback, or Task protocol. UV
`guess_handle` selects pipe/TTY where possible. An unknown descriptor is
inspected explicitly rather than trusting errno left by a failed guess.
Socket-family and socket-type contradictions defeat a pipe hint; only the
existing narrowly permitted metadata-denial case can use
`TITAN_STDIO_PIPE_FDS`. The duplicate remains lexically owned until adoption by
a public UV handle is established. Windows descriptor/HANDLE differences are
handled by the platform helper and public identifier queries.

Captured stdout/stderr use the same buffered stream implementation. Merged
output stores exactly one public InputStream in both Process fields, so excess,
EOF, and close are shared. Domain slot replacement disposes an old owned capture
or merged endpoint only when no retained slot still refers to it.

## Spawn transaction and exit delivery

Process configuration applies options in order and owns every unpublished
stdio endpoint. Public UV process options carry the final argv, environment,
and stdio records. The default environment is inherited; explicit overlays are
constructed from a copied environment snapshot, using the platform's name
comparison policy. The OS header supplies platform environment and shell facts
without exposing UV internals. The Windows shell uses the system-directory
`cmd.exe` and the public verbatim-argument flag; `io.popen` consumes that OS
helper rather than duplicating transport policy.

Configuration creation and spawn reject an async Runtime whose closing flag is
set. Spawn deliberately introduces no ordinary cancellation checkpoint:
pending Task cancellation alone does not forbid spawning a child. It still
requires a running Task, so a native callback cannot bypass that boundary. See `async.is_closing()` for the observation used here.

The configuration retains lexical ownership until native spawn, captured-read
registration, and result construction are ready for publication. One private
Config completion capability owns a preinitialized native timer and the
unpublished process. Both handle views, callbacks, and signal numbers are
prepared before child acceptance. Empty slots and the public Process are
allocated before completion closes the unused timer; field-only assignments
then clear Config ownership and commit publication.

The protected public spawn body catches failures before Config cleanup and
uses a nested protected cleanup followed by bare rethrow. This preserves the
original error and traceback across yielding cleanup and secondary failures.
Config commits its consumed state and detaches the capability before invoking
it. Rollback selects its exit callback branch before discarding streams, and a
defer guarantees the cancellation-shielded `async.await_cleanup_with` even if stream
discard fails. The branch skips ExitStatus construction and subscription
publication, retaining the native watcher through the actual exit and close.

An active unpublished child receives SIGTERM, followed by a one-shot 30000ms
native timer that sends SIGKILL if the child remains active. Cached loop time is
refreshed at the initial signal request. The timer is initialized before spawn;
its fixed-duration, prebuilt-callback start is allocation-free under the pinned
native contract. Early child exit closes the timer; escalation also closes it.
Cleanup resolves only after both native close callbacks have retired their
owners. Registration checks for already completed retirement as well. Negative
signal results never abandon an active watcher: 30 seconds bounds the grace
period, not exit completion if signaling fails. No cleanup Task, saved-PID
poller, extra scheduler queue, or ProcessOwner state is introduced.
This cold rollback path retains its captured registration, retirement,
escalation, and Config-cleanup closures. Its shared state holds one Completion
and the number captured at registration; retirement snapshots and clears that
capability before settlement. The existing process exit and subscription
callbacks remain unchanged.

Native spawn failure follows actual handle state: an uninitialized process
needs no close, an initialized inactive process must close, and an active
process retains its exit obligation regardless of the returned status.
CREATE_PIPE eligibility and the pinned native failed-spawn repair are
documented in the [public process policy](../language/uv/PROCESS-POLICY.md).

The exit callback records the `ExitStatus`, closes the process handle, publishes
the coalesced result, and ends the subscription. Wait cancellation detaches only
the waiter: the accepted child remains retained until exit/reap. Repeated waits
return the stored result. A wait calls `async.checkpoint()`
before cached-result delivery and before the existing competing-wait diagnostic.
`is_running` and `kill` keep the same Runtime checks and symbolic signal policy;
closing captured streams does not kill the child.

Graceful `os.exit` delegates to `async.request_exit`. Async owns cancellation and
draining of the entrypoint session, including accepted requests and cleanup,
before returning the requested process exit code. See the
[Runtime shutdown protocol](libuv-runtime.md#shutdown-and-process-control).
