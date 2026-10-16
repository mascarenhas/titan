# Filesystem-library implementation

`titan.fs` owns high-level File and Watcher policy using ordinary compiled
imports of public `titan.async`, `titan.uv`, and `titan.string`. Its only native
include is the small path-separator definition in `fs_platform.h`. Native
filesystem requests, callbacks and borrowed-storage roots belong to UV;
Task waits and subscription queues belong to async. See the
[filesystem API](../language/standard-library-fs.md),
[public UV filesystem operations](../language/uv/functions/fs.md), and
[generic runtime](libuv-runtime.md).

## One-shot requests and File ownership

`perform<T>` constructs one public `uv.fs_t` and registers its submission with
ordinary `async.await<T, integer>`. The terminal callback reads the native
result, copies any request-owned strings/stat/scandir data, calls
`uv.fs_req_cleanup`, and settles the typed result. Expected native failures
become `async.OperationError` with the public operation label; unexpected
callback failures clean the consumed request, invoke the exact wait's fatal
capability, and rethrow to the UV boundary. Immediate rejection cleans the
unaccepted request and rejects inline.

`acquire<T>` handles operations that produce a descriptor. It puts a successful
native result into an existing, still-unpublished File before result decoding
or resolver publication. `open` owns abandonment close lexically; `tmpname`
also closes the newly acquired descriptor before returning its generated path.
Cancellation after native success can therefore unwind without leaking an
unpublished descriptor. The descriptor remains separate from request memory:
request cleanup never closes it.

`File:close_with` uses `await_cleanup`. It builds the request and acceptance
state, takes the descriptor out of the File, and restores it only if submission
failed before native acceptance. An accepted close leaves the File terminal,
including when native completion reports an error. Pending Task cancellation
does not skip the close or replace its completion. Close also clears retained
delimiter excess. It does not serialize unrelated in-flight operations; callers
still coordinate use of one descriptor.

Reads allocate writable public buffers and copy exactly the completed byte
count. Each accepted request retains its buffer independently through callback
return. The default read size is 64 KiB; zero bytes is EOF. Retained delimiter
excess can satisfy a read synchronously. Writes use read-only string-backed
buffer views and resubmit the unconsumed suffix after a short write, preserving
1-based slice indices and exact borrowed lifetime. File mode mapping and native
creation permissions remain in this module.

## File transfer

`File` counts entry to exit of each public read/write/flush operation and the
internal close operation, including the complete `read_until` composition.
Nested reads contribute to the same count. The count is solely a transfer
admission guard; it does not change existing concurrent operation or close
ordering. Deferred decrements preserve the guard through accepted native
callbacks, result publication, cancellation, and error unwinding.

`to_transfer_payload` checks open ownership and a zero count, allocates the
descriptor/string payload, then clears `handle` and `excess` as its final
mutation. Adoption validates both slots and the signed native descriptor range
before constructing `File(descriptor, excess, 0)`. A descriptor is process-owned
rather than bound to a UV loop, so neither hook needs a Task or native I/O.
The descriptor and current file position move intact across independent Lua
states. The payload uses the existing trusted, exactly-once manual handoff
contract; it does not add a descriptor registry, destructor, or replay guard.

Native `fs.tests` cover retained binary delimiter bytes, shared file position,
source invalidation, malformed and closed payloads, hooks outside a Task, and
cross-state use after source-state shutdown. The existing deterministic
concurrent-read gate also rejects transfer of both accepted pending reads
before their completion callbacks can run, and verifies both source owners
remain open.

## Metadata and canonical paths

`stat` and `lstat` copy public UV `stat_t` results into the existing `Stat`
shape. Only `uv.ENOENT` becomes nil; every other failure preserves its
structured error/traceback. `device` and `inode` retain the complete unsigned
native bit patterns through Titan's signed integer channel and form an opaque
equality pair. They are not portable ordering or size values.

`realpath` is an ordinary one-shot await over `uv.fs_realpath`; it copies the
request's string before cleanup. It no longer owns a separate native callback,
Task token, or request-root Map. `list` similarly copies each scandir entry
before request cleanup. Path validation rejects embedded NUL before native
submission. Host-directory and executable-path helpers use the public UV
capacity/status APIs with explicit native ENOBUFS handling; process argument
setup is shared through `uv.setup_process_args` where required.

## Watcher ownership

A public Watcher stores its exact Runtime loop, a dense registration Array,
canonical-path Map, one `BufferedSubscription<WatcherNotification, integer>`,
its publish function, and the existing four-state operation guard. Every
operation checks that the active Runtime still has that same loop, then checks
Task context. A later Runtime never rebinds an old watcher.

Each `WatchRegistration` owns a public `uv.fs_event_t`, a prebuilt handle view,
canonical path, directory flag, and dense index. The callback receives copied
filename text from UV and publishes one notification; it does no filesystem I/O
or event classification. The public UV owner roots native callback state until
close, so fs needs no native callback header or separate GC root table.

Construction prepares the owner, view, closure, and domain indexes before native
init/start. Init status is checked directly, then initialized ownership is
committed before start. No fallible allocation is placed after a successful
start before the registration returns. Rejection rolls back indexes and closes
an initialized partial registration. Close is deferred before index removal
because an empty-batch wake can itself fail while scheduling a continuation.

The subscription supplies its queue and exact one-reader reservation. A blocked
poll uses `next_batch`; cancellation detaches that reader and preserves native
registrations and queued events. Removing the final registration calls
`wake_batch`, allowing the current poll to return an empty batch without ending
the reusable subscription. With no registrations, poll uses `drain_pending`
instead of waiting. The Watcher operation guard remains necessary while a
detached batch is classified across asynchronous metadata calls.

A successful event start is acceptance, not backend readiness. On Darwin,
FSEvents activation occurs asynchronously on its native CF thread; the API does
not replay mutations that predate that subscription. Native tests must establish
readiness/progress rather than assume an exact number of Task yields.

## One-to-one drain mapping

`poll` detaches the currently buffered subscription batch before
classification, so callbacks that arrive while `lstat` is pending append to a
follow-on batch. It maps every `WatcherNotification` to exactly one result:

- a negative native status closes the registration and becomes `error`;
- `UV_RENAME` takes precedence and an asynchronous facade `lstat` chooses
  `created` or `deleted`;
- every direct-file notification also checks the watched path, because Darwin
  reports deletion of that file as `UV_CHANGE`; and
- every other ordinary directory notification becomes `modified`.

Directory filenames are joined to the canonical directory. A missing filename
or a direct file notification names the registration path itself. Before
classifying a directory child, the mapper checks whether the watched root still
exists. A deleted watched root is selected as the event path and its
registration is retired. A missing directly watched file is likewise emitted
as `deleted` and retired regardless of its native event bit. An `OperationError`
raised by one mapping becomes that notification's `WatcherEvent.error`; there
is no raw-batch rollback or watcher reset.

Mapping a deletion can stop a registration, and mapping a native error can
retire and close one, after callbacks from that registration have already
entered the follow-on queue. After each detached batch is mapped, the drain
scans the fresh queue. If any notification now names a registration whose dense
index is zero, the drain detaches and maps that entire follow-on batch in
callback order before returning. Pulling the complete batch, instead of
filtering only the retired registration's records, preserves callback order
across registrations. A batch containing only live registrations remains
buffered for the next `poll`.

The extension is bounded: deletion retirement calls `uv_fs_event_stop`, while
native-error retirement proceeds directly to close, and the waiting close has
completed before either mapping returns. No further callback can then enter for
that registration. A follow-on batch may retire another finite live
registration, in which case the same rule repeats. No raw notification is
discarded or merged, and a retirement-causing `poll` leaves no already-copied
event for that retired registration to leak into the next call.

## Stopping, retirement, and close

`WatchRegistration:stop` checks the native stop result. A retiring registration
leaves the path Map and dense Array before any yielding close, preventing a
concurrent clear from claiming it again. Native close is already armed in a
defer before that removal or its wake notification can raise.

The waiting close uses `async.await_cleanup` with the prebuilt public handle
view; its protected close callback resolves only after UV retires the native
lifetime. Partial start rollback uses nonwaiting `uv.close`, whose public owner
still retains itself until close completion. Native callbacks do not receive
or use `Task:resume` tokens.

The four operation states are idle, polling, clearing, and polling-plus-clearing.
They preserve the still-running half when the other operation finishes first,
and reject a new poll or second clear during clear. `clear` retires domain
registrations but deliberately leaves the notification subscription reusable;
its subscription producer has no independent native handle to close. Runtime
shutdown finally walks remaining handles only after Tasks and their cleanup
have retired.

## Compiled boundary and validation

The fs consumer includes no libuv header and defines no restricted foreign
callback. Its one generated object calls the public UV/async protocols just as
an independently compiled library could. The tiny platform-separator header
has no libuv storage, callback, or scheduler dependency.

Native behavior belongs in `spec/stdlib/titan/fs/tests.titan`: binary and
delimiter I/O, modes and validation, metadata/locations, symlinks, independent
continuations, watcher canonicalization and retirement, cancellation, Runtime
ownership, and close acceptance. Public compiled-client coverage must also
exercise accepted-open abandonment, preaccept-close restoration, and accepted
close errors. Schema fixtures retain File/Stat/Watcher declarations and the
canonical `async.OperationError` nominal owner. These ownership tests complement
rather than replace the complete provider, compiler and platform gates.
