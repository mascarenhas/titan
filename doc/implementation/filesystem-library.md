# Filesystem-library implementation

The public `titan.fs` module is a high-level facade over the private
`titan.uv` continuation runtime. Ordinary file descriptors still use the
filesystem `Call` variants in `titan/uv/file.titan`; canonical-path resolution
and persistent filesystem watching are implemented in `titan/fs.titan`
because their public policy belongs to the facade.

This chapter covers the missing-path metadata rule, `realpath`, watcher
callback ownership, drain-time event classification, and native-handle close
protocol. The user-visible API and its best-effort notification contract are
in the [filesystem standard-library chapter](../language/standard-library-fs.md).

## Metadata and canonical paths

`stat` and `lstat` call the existing private `uv.fs_stat` and `uv.fs_lstat`
operations. Their facade catches an `OperationError` only when its code is
`UV_ENOENT`; that one result becomes `nil`. Every other error is re-raised with
its original value and traceback. The two public result types are therefore
`Stat?`, without changing the native request or `Stat` representation.

`realpath` owns one `owned *uv_fs_t` in a local `RealpathRequest`. The request
also stores its exact Titan callback, optional Task waiter, completion flag,
failure flag, and result payload. Accepted requests are keys in the traced
module-local `{RealpathRequest: boolean}` Map until their terminal callback,
independently of the suspended continuation stack.

The source-defined `fs_realpath_cb` follows the standard foreign callback
sequence: it recovers the owner through `uv_req_get_data`, reads the callback
closure from the owner's second user value, obtains the main Lua state from the
request loop, invokes the closure's exact native entry, and restores the Lua
stack top. The ordinary Titan handler copies `uv_fs_get_ptr` to a Titan string
before `uv_fs_req_cleanup`, removes the Map root, and records the result. While
the request still has a waiter it calls the source-private
`resume_condition_waiter_from_callback`. That helper directly advances the
ordinary callback path, but returns without advancing when the Task already has
a coalesced public-resume timer; that timer remains the sole continuation and
the caller reads the published request state. The optional action passed to
`uv.suspend` detaches that waiter synchronously when cancellation is requested,
before scheduling the next-turn wake. Titan's cooperative execution means no
libuv callback can interleave with that state change. The short accepted request
is not sent through `uv_cancel`; its eventual callback still performs cleanup
without resuming the Task. A negative submission result cleans and unroots the
request immediately because libuv will not call it back.

## Watcher ownership

A public `Watcher` is permanently associated with the active `Runtime` at
construction. It owns a dense Array of registrations, a canonical-path Map,
a raw-notification Array, at most one polling Task, and one integer operation
state covering idle, polling, clearing, and poll-plus-clear overlap. Operations
first prove that the same Runtime remains active; there is no generation reset
or cross-Runtime reuse path.

Each local `WatchRegistration` owns exactly the state needed by one
`uv_fs_event_t`:

- GC-owned native handle storage;
- the exact event callback closure;
- its Runtime and callback-root index;
- canonical watched path and directory/file flag; and
- its dense Watcher index.

The complete registration is placed in `Runtime.handle_roots` before
`uv_fs_event_init`, so the native handle and everything its callback reads stay
reachable. An init rejection removes that root because libuv never accepted
the handle. A start rejection transfers it to ordinary asynchronous close
ownership. Acceptance from `uv_fs_event_start` is not a backend-readiness
callback: on Darwin, libuv creates the FSEvents stream asynchronously on its CF
thread. Native watcher cases therefore let the Runtime settle after registration
before issuing the mutation under test; the facade does not claim replay of an
event that predates native subscription.

`fs_watcher_event_cb` recovers the registration from handle data and the main
Lua state from the handle's loop. Its Titan handler copies the nullable
filename while libuv owns it and appends one `WatcherNotification` containing
the registration, copied filename, event mask, and status. It then clears and
wakes an installed poller through the same condition-waiter helper. If a public
resume is already pending, its Task-owned timer remains the sole continuation;
the callback cannot advance the poller and leave that timer to resume a later
suspension. The callback does not perform filesystem I/O and does not
synchronously block the event loop. If copying or queue publication raises, the
outer handler retires the exact waiter; an already-closing public-resume timer
observes that terminal state and returns without entering the coroutine again.
A suspend cancellation action removes only its exact Task waiter before
requesting the next-turn wake; the scope defer
repeats that idempotent detach on every other exit. A wake requested through the
public `Task:resume` API does not end the poll: after every suspension, the poll
rechecks both the notification queue and registration set and suspends again
while it still has work to await. Shared registrations and every buffered
notification remain available to the next polling Task.

## One-to-one drain mapping

`poll` detaches the currently buffered raw Array and installs a fresh one before
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
entered the follow-on Array. After each detached batch is mapped, the drain
scans the fresh Array. If any notification now names a registration whose dense
index is zero, the drain detaches and maps that entire follow-on batch in
callback order before returning. Pulling the complete Array, instead of
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

## Stopping and closing handles

Stopping and closing are separate local `WatchRegistration` methods. `stop`
checks `uv_fs_event_stop`. A successfully stopped or callback-retired
registration leaves the Watcher's path Map and dense Array before any yielding
close wait, so a concurrent clear cannot claim it a second time. `close(wait)`
then transfers the rooted registration to the shared close machinery; start
rejection uses the nonwaiting form, while public `stop`, `clear`, native-status
retirement, and watched-root deletion use the waiting form.

The operation state rejects a new poll and a second clear while clear is in
progress. Its four transitions retain the polling half when clear finishes
first and retain the clearing half when the prior poll finishes first; completed
clear remains idempotent.

A waiting close yields the private, cancellation-insensitive
`HandleCloseCall`. Its dispatcher runs while the Task is already suspended,
calls `close_handle`, and returns only from `uv_close` completion. This is why
the high-level method neither treats `Task:resume` as a native completion nor
adds a second scheduler or close-waiter queue.

`begin_close` first checks `uv_is_closing`. An already-closing handle is not
submitted to `uv_close` a second time. Otherwise one `CloseOwner` takes the old
callback root, overwrites handle data for `uv_close_cb`, retains the original
registration through close, and invokes the waiting completion only after the
close callback has released that owner. Runtime shutdown's `uv_walk` already
skips closing handles and remains the fallback for a live watcher that
application code did not clear.

## Generated boundary and validation

The two restricted foreign declarations generate `titan/fs.titan.h` alongside
the module C source. The header is a source-build intermediate: Make cleanup
and `.gitignore` own it, and it is not installed. `titan/fs.o` defines
`fs_realpath_cb` and `fs_watcher_event_cb` and directly references only the
reviewed public libuv entry points; no C shim or runtime callback dispatcher is
added.

Behavioral coverage lives in `spec/stdlib/titan/fs/tests.titan` and runs in the
native aggregate outside LuaCov. Build-boundary coverage in
`spec/libuv_build_spec.lua` checks the exact callback declarations, generated
symbols, direct libuv references, close guard, and combined-provider ownership.
The serialized standard-library fixture pins the appended public
`titan.fs` interface.

These changes advance the compiled-module ABI from 0.24 to 0.25. In particular,
`stat` and `lstat` now return `Stat?`, changing their exact raw C return carrier
from `Udata *` to `TValue`, while the cancellation protocol adds an optional
action parameter to `titan.async.suspend` and its source-private `titan.uv`
entry. Both the serialized public interfaces and native signatures therefore
require the 0.25 marker; every other ABI-0.24 layout and contract is retained.
A 0.24 provider is rejected before either boundary is used and remains
preserved rather than migrated or cleaned up.
