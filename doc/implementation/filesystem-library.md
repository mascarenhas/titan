# Filesystem-library implementation

`titan/fs.titan` owns high-level File and Watcher policy through ordinary
compiled imports of public `titan.async`, `titan.uv`, and `titan.string`. Its
only native include is `fs_platform.h`, which defines the path separator
`TITAN_FS_DIRSEP` and has no libuv storage, callback, or scheduler dependency;
fs defines no foreign callback, so its one generated object uses the public
UV/async protocols exactly as an independently compiled library would. Native
filesystem requests, callbacks and borrowed-storage roots belong to UV, and
Task waits and subscription queues belong to async. See the
[filesystem API](../language/standard-library-fs.md),
[public UV filesystem operations](../language/uv/functions/fs.md), and the
[generic runtime](libuv-runtime.md).

## One-shot requests and File ownership

fs follows the generic
[one-shot Task adapter](libuv-extension-guide.md#one-shot-task-adapter) recipe;
its File adapter is the recipe's resource-ownership example. `perform<|T|>`
constructs one public `uv.fs_t` and awaits it with
`async.await_with<|FileOperation<|T|>, T, integer|>`. The terminal callback
`file_completed` copies any request-owned strings, stat or scandir data, calls
`uv.fs_req_cleanup`, and settles the typed result. Expected native failures
become `async.OperationError` with the public operation label.

`acquire<|T|>` handles operations that produce a descriptor. It stores a
successful native result in an existing, still-unpublished File before result
decoding or resolver publication, so cancellation after native success unwinds
without leaking the descriptor. `open` closes an abandoned descriptor
lexically, and `tmpname` closes its new descriptor before returning the
generated path. Request cleanup never closes the descriptor.

`File:close_with` uses `async.await_cleanup_with`. It takes the descriptor out
of the File and restores it only if submission failed before native acceptance.
An accepted close leaves the File terminal even when native completion reports
an error, and pending Task cancellation neither skips the close nor replaces
its completion. Close also clears retained delimiter excess. It does not
serialize unrelated in-flight operations; callers coordinate use of one
descriptor.

Reads allocate writable public buffers (default `READ_CHUNK_BYTES`, 64 KiB) and
copy exactly the completed byte count; each accepted request retains its own
buffer through callback return. Zero bytes is EOF, and retained delimiter
excess can satisfy a read without native I/O. Writes use read-only
string-backed buffer views and resubmit the unconsumed suffix after a short
write, preserving 1-based slice indices and the exact borrowed lifetime. File
mode mapping and creation permissions stay in this module.

## Lua-state close

A Lua state close cannot await a libuv request, so `File:close_with` tests
`titan_state_closing` after its idempotence check and then closes the
descriptor synchronously on the loop thread with `uv.fs_close` and a nil loop.
A suspended Task's `defer file:close()` therefore completes during the close.
`open` and `from_transfer_payload` register `finalize_file` with
`gc.finalizable` before the File holds a descriptor. It returns at once unless
the state is closing, so ordinary collection still leaves descriptors to their
owners, and during close it calls `close_with`. A transferred-out File holds
no descriptor, so its finalizer closes nothing.

A Task parked in a read, write or flush request is unwound before the request
completes, while a worker may still use the descriptor. Closing it then could
hand that request a reused descriptor number. `File:perform` therefore keeps a
local `pending` flag that a normal return or `catch` clears; `catch` never runs
during an unwind, so a `defer` that finds the flag still set marks the File
`abandoned`. Finalizers run newest first, so a File opened inside the Task is
finalized before that Task unwinds; its operation then still counts itself in
`pending_operations`. A state-close `close_with` therefore leaves the
descriptor open when the File is abandoned or another operation is still
counted; it is not released before the process exits. An in-flight `open` or
`mkstemp` instead never published its descriptor, and UV's abandonment handler
closes it when the request completes
([final state teardown](libuv-extension-guide.md#final-state-teardown-is-not-ordinary-shutdown)).

## File transfer

The generic manual-handoff rules are in
[manual resource handoff](transfer-library.md#manual-resource-handoff); File has
no `discard_transfer_payload` helper.

`File.pending_operations` counts entry to exit of every public read, write and
flush and the internal close, including a whole `read_until` composition and
its nested reads. It guards transfer admission and the
[state-close close](#lua-state-close), and does not change ordinary
concurrent-operation or close ordering. Deferred decrements keep it accurate
through accepted native callbacks, result publication, cancellation and error
unwinding.

`to_transfer_payload` requires an open File and a zero count, serializes the
descriptor and buffered excess with the private `file_transfer_fields` schema
(integer, string), and only then sets `handle` to -1 and clears `excess`.
`from_transfer_payload` decodes the same schema, validates the signed native
descriptor range, and returns a File that registers its state-close finalizer
before taking the descriptor. A descriptor
belongs to the process rather than a UV loop, so neither hook needs a Task,
Runtime, or native I/O, and the descriptor and its file position move intact
between Lua states.

## Metadata and canonical paths

`stat` and `lstat` copy public UV `stat_t` results into `Stat`. Only `uv.ENOENT`
becomes nil (`missing_path`); every other failure keeps its structured error and
traceback. `device` and `inode` carry the complete unsigned native bit patterns
through Titan's signed integer and form an opaque equality pair, not a portable
ordering or size.

`realpath` is an ordinary `perform` over `uv.fs_realpath` that copies the
result before cleanup. `list` copies each `uv.fs_scandir_next` entry before
cleanup. Path validation rejects embedded NUL before native submission.
Host-directory and executable-path helpers use the public UV capacity/status
APIs with explicit `ENOBUFS` handling, calling `uv.setup_process_args` where
required.

## Watcher ownership

A `Watcher` stores its Runtime `loop`, the dense `registrations` Array, the
`paths` Map from canonical path to registration, one
`BufferedSubscription<|WatcherNotification, integer|>` with its `publish`
function, and `operation_state`. Every operation checks that the active Runtime
still has that loop, then checks Task context; a later Runtime never rebinds an
old watcher.

Each `WatchRegistration` owns a public `uv.fs_event_t`, a prebuilt `uv.handle_t`
view, its canonical path, a directory flag, its dense `index`, and close
completion state. The callback receives copied filename text from UV and
publishes one notification; it does no filesystem I/O or classification. The
public UV owner roots the native callback state until close, so fs needs no
native callback header or GC root table.

Construction prepares the owner, view, closure, and domain indexes before
native init and start. The init status is checked, initialized ownership is
committed before start, and nothing fallible runs between a successful start
and the return. Rejection rolls back indexes and closes an initialized partial
registration. Close is deferred before index removal because the empty-batch
wake can itself fail while scheduling a continuation.

The subscription supplies the queue and its single reader reservation
([persistent source adapter](libuv-extension-guide.md#persistent-source-adapter)).
A blocked poll uses `next_batch`; cancellation detaches that reader and
preserves registrations and queued events. Removing the last registration
calls `wake_batch`, so the current poll returns an empty batch while the
subscription stays reusable. With no registrations, poll uses `drain_pending`
instead of waiting. The Watcher operation guard is still needed because a
detached batch is classified across asynchronous metadata calls.

A successful event start is acceptance, not backend readiness. On Darwin,
FSEvents activates asynchronously on its own CF thread and does not replay
mutations made before the subscription. Native tests must establish readiness
or progress rather than count Task yields.

## One-to-one drain mapping

`poll` detaches the buffered batch before classification, so callbacks that
arrive while `lstat` is pending go to a follow-on batch.
`Watcher:map_notification` maps each `WatcherNotification` to exactly one
`WatcherEvent`:

- a negative native status retires the registration and becomes `error`;
- for a directory registration, a missing watched root becomes `deleted` at the
  root path; otherwise `UV_RENAME` takes precedence and an asynchronous `lstat`
  of the child chooses `created` or `deleted`, and any other event is
  `modified`;
- a direct-file registration checks the watched path with `lstat` on every
  event, because Darwin reports deletion of that file as `UV_CHANGE`.

Directory filenames are joined to the canonical directory; a missing filename
or a direct-file notification names the registration path. When the watched
path itself no longer exists, the registration is stopped and retired. An
`OperationError` raised while mapping one notification becomes that
notification's `error` event; there is no batch rollback or watcher reset.

Mapping a deletion can stop a registration, and mapping a native error can
retire and close one, after callbacks from that registration have already
entered the follow-on queue. `Watcher:drain_notifications` therefore, after
each mapped batch, calls `subscription:drain_if` with the predicate
`registration.index == 0`. If any queued notification names a retired
registration, it takes that whole follow-on batch and maps it in callback
order; otherwise live-only notifications stay queued for the next `poll`.
Taking the complete batch rather than filtering the retired registration's
records preserves callback order across registrations.

The loop terminates: deletion retirement calls `uv.fs_event_stop`, native-error
retirement proceeds directly to close, and the waiting close has completed
before either mapping returns, so no further callback can enter for that
registration. A follow-on batch may retire another live registration, and the
rule repeats for a finite set. No raw notification is discarded or merged, and
a retirement-causing `poll` leaves no copied event of the retired registration
for the next call.

## Stopping, retirement, and close

`WatchRegistration:stop` checks the native stop result. A retiring registration
leaves the path Map and the dense Array before any yielding close, so a
concurrent clear cannot claim it again; native close is already armed in a
`defer` before that removal or its wake can raise.

The waiting close uses `async.await_cleanup_with` with the prebuilt handle
view, and resolves only after UV retires the native lifetime. Partial-start
rollback uses nonwaiting `uv.close`; the public owner retains itself until
close completion.

The four `operation_state` values are `WATCHER_IDLE`, `WATCHER_POLLING`,
`WATCHER_CLEARING`, and `WATCHER_POLLING_CLEARING`. They keep the still-running
half when the other operation finishes first, and reject a new poll or a second
clear during clear. `clear` retires registrations but leaves the notification
subscription reusable; that producer has no native handle of its own. Runtime
shutdown walks any remaining handles only after Tasks and their cleanup have
retired.

## Tests

Native behavior belongs in `spec/stdlib/titan/fs/tests.titan`: binary and
delimiter I/O, modes and validation, metadata and locations, symlinks,
independent continuations, watcher canonicalization and retirement,
cancellation, Runtime ownership, close acceptance, accepted-open abandonment,
preaccept-close restoration, accepted close errors, and File transfer (shared
position, source invalidation, malformed and closed payloads, hooks outside a
Task, use after source-state shutdown, and rejection while concurrent reads
are pending). Schema fixtures keep the File, Stat and Watcher declarations and
the canonical `async.OperationError` owner.
