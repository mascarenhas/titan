# `titan.fs` file watcher

## Public API

The watcher is a high-level `titan.fs` facility. Its public declarations are
appended to the existing `titan.fs` interface so the slots of the existing
`File`, `Stat`, and path functions do not move.

```titan
record Watcher
  -- all fields are local
end

union WatcherEvent
  created: string
  deleted: string
  modified: string
  error: async.OperationError
end

function watcher(): Watcher
end

function Watcher:watch(path: string)
end

function Watcher:stop(path: string)
end

function Watcher:is_watching(path: string): boolean
end

function Watcher:clear()
end

function Watcher:poll(): {WatcherEvent}
end

function realpath(path: string): string
end
```

`watch(path)` requires an existing file or directory. It resolves `path` once
with `realpath`, follows symbolic links, and watches the resulting canonical
absolute path. A directory watch observes its immediate entries but does not
recurse. A file watch reports the canonical file path. Watching the same
canonical target more than once is idempotent, including through another
symlink or `.`/`..` spelling. On Darwin, libuv activates its FSEvents stream
asynchronously after accepting a registration, so portable tests let the
Runtime settle before issuing the mutation whose event they observe.

Event payloads are canonical absolute paths. `created` and `deleted` are
best-effort classifications of a native rename/entry-change notification:
`poll` checks `lstat` when it processes the notification. The target may have
changed again by then, and libuv or the operating system may coalesce,
duplicate, or omit detail. The stream is a change hint, not a durable journal,
and no total ordering or one-event-per-operation contract is promised. Each
native notification maps to exactly one `WatcherEvent`; `UV_RENAME` takes
precedence when libuv sets both rename and change flags.

`stop(path)` and `is_watching(path)` resolve the supplied spelling again and
look up the one canonical registration. An equivalent symlink or `.`/`..`
spelling therefore names the same watch without retaining a parallel alias
index. A missing or unwatched path is a no-op for `stop` and false for
`is_watching`. A direct file notification checks the watched path even when
libuv supplies only `UV_CHANGE`, because Darwin reports direct-file deletion
that way; a missing file maps to `deleted` and retires the registration.

`clear()` stops and closes every registration and is idempotent after it
finishes. Each explicit stop uses `uv_fs_event_stop`, removes the registration
from the Watcher's live identity state, transfers the rooted handle to the
ordinary asynchronous `uv_close` owner, and waits for close completion. While
that clear is active, a new `poll` or second `clear` raises. Notifications
already copied into the Watcher remain observable; unless a poll already
crossed and drained their registration's retirement batch, callers may use one
final `poll()` to drain them. `stop`, `clear`, a registration error, and
direct-target deletion wake a blocked poll when they remove the final live
registration.

`poll()` drains the notifications that are currently buffered. If mapping
retires a registration after callbacks for it entered the fresh queue, the same
poll drains that complete follow-on callback batch in order before returning.
This preserves one raw notification per public event while preventing a later
poll from observing an already-copied notification for a retired registration.
If none are buffered while at least one registration is active, it blocks the
current Task with the source-private `uv.suspend()`. If there are no
registrations, it returns an empty Array immediately. At most one `poll` may be
in progress for a Watcher.
Cancelling a blocked poll detaches only that Task's callback waiter. It neither
loses buffered notifications nor stops registrations that another Task may
poll. A wake requested through the public `Task:resume` method only causes the
poll to recheck notifications and registrations; it suspends again rather than
returning an empty Array while work remains to await.

A negative native watcher callback status is copied like every other raw
notification. Draining it closes that registration and produces a
`WatcherEvent.error(async.OperationError)` value; `poll` does not raise for an
ordinary event-conversion failure. No Titan error may unwind through libuv.

`watcher()` permanently binds the new Watcher to the active async Runtime and
its loop. Every later operation requires that same Runtime to remain active;
a Watcher is not reset or reused by another Runtime after shutdown.

## Metadata correction

The existing metadata functions become:

```titan
function stat(path: string): Stat?
function lstat(path: string): Stat?
```

Only `UV_ENOENT` returns `nil`. All other failures remain
`async.OperationError`. Consequently a dangling symlink returns `nil` from
`stat` but a `Stat` with `kind == "symlink"` from `lstat`; a missing entry
returns `nil` from both. Watcher classification uses `lstat`, so a newly
created dangling symlink still counts as an existing entry.

## ABI boundary

This feature advances the compiled-module ABI. The optional
`stat`/`lstat` result changes each raw native return carrier from `Udata *` to
`TValue`, and the optional cancellation action adds a `TValue` parameter to
`titan.async.suspend` and its source-private `titan.uv` entry. The new watcher
and cancellation declarations also extend serialized standard-module
interfaces. Advance the ABI marker, generated metadata, and ABI-sensitive cache
namespace coherently while keeping the semantic release and library layout
independently versioned. This is a clean-start prototype boundary:
incompatible providers are rejected, not migrated or reconciled.

## High-level implementation boundary

This feature deliberately lives in `titan/fs.titan`, as requested. It uses the
public libuv FFI plus the existing direct-source access to `titan.uv`'s current
Runtime, error conversion, callback-entry types, and handle-root/close helpers.
Waiting close adds one local, cancellation-insensitive `HandleCloseCall` to the
private scheduler protocol; it does not add a public `titan.uv` API. The
existing suspend protocol gains an optional nonyielding, nonraising cancellation
action, exposed as `async.SuspendCancelAction?`, so owner-specific code can
detach its waiter before the ordinary next-turn wake.

### `realpath`

`realpath` submits one `uv_fs_realpath` request on the running Task's Runtime
loop. Its source-defined foreign callback follows the standard exact callback
bridge: request data gives the owner Udata, owner slot 2 gives the Titan
closure, the loop gives the main Lua state, and the closure gives `_mod` and
its exact native entry. The callback copies `uv_fs_get_ptr(req)` to a Titan
string before `uv_fs_req_cleanup`.

The accepted native request does not rely on the suspended Task stack for
lifetime. A traced module-owned request-root Map keeps each accepted owner alive
until its callback. The callback cleans the request exactly once, removes that
root, records its result/error, and wakes only an attached waiter through
`uv.resume_condition_waiter_from_callback`. That helper retains the ordinary
direct callback path, but if a coalesced public `Task:resume` timer already owns
the continuation, it leaves that timer as the sole wake; the caller reads the
published request state after either route. The caller waits with `uv.suspend`
until the owner is complete. Its optional suspend cancellation action detaches
the waiter synchronously before requesting the next-turn wake. Because Titan
execution is cooperative, a libuv callback cannot interleave with that detach.
The accepted short request is not passed to `uv_cancel`; its eventual callback
performs cleanup without resuming the cancelled Task. An immediate negative
submission performs cleanup, removes the root, and raises without suspending.

### Watch handles

Each canonical registration owns exactly one `owned *uv_fs_event_t`, one exact
callback closure, its Runtime/root index, canonical path, directory/file flag,
and dense Watcher index. One integer Watcher operation state distinguishes
idle, polling, clearing, and their supported poll-plus-clear overlap; it is not
a collection of independent lifecycle flags. The owner is placed in
`Runtime.handle_roots` before `uv_fs_event_init`. Init rejection unroots it;
start rejection transfers the initialized handle through the ordinary
asynchronous close owner. Successful stop uses `uv_fs_event_stop` and then the
same close transfer. Runtime `uv_walk` remains able to close a forgotten live
handle.

The foreign fs-event callback copies the nullable filename while libuv owns
it, records the integer event mask/status in a traced raw-notification Array,
and wakes the one waiter through the same condition-waiter helper. An already
pending public-resume timer remains the sole continuation, so an event cannot
advance the poller and leave that timer to resume a later suspension. The
callback never yields or calls `stat`/`lstat`, because no async Task is current
inside a libuv callback. A stored ordinary Titan handler contains every error
before the foreign entry returns. If publication fails, it retires the exact
waiter; any already-closing public-resume timer observes the terminal Task and
returns without entering its coroutine again.

`poll` detaches the currently buffered raw notifications while callbacks append
to a fresh Array, then maps the detached records one-for-one in callback order.
After each detached batch, it scans the fresh Array. If any record belongs to a
registration retired during mapping, it detaches and maps that entire follow-on
batch before returning; taking the whole batch preserves callback order across
registrations. A batch containing only live registrations remains for the next
poll. Stopping and waiting for close before a retirement mapping returns makes
this extension finite without a generation, lifecycle flag, or event drop.
A directory filename is joined to the canonical watched directory; a missing
filename is a coarse notification for the watched directory itself. A file notification
always names the canonical watched file. For `UV_RENAME`, `poll` uses `lstat`
to choose `created` versus `deleted`; every direct-file notification performs
the same existence check so Darwin's change-only deletion is classified. If
the watched root itself is gone, the root path is selected and the registration
is retired. A conversion failure
maps that notification to `WatcherEvent.error` and mapping continues; there is
no snapshot rollback or reset protocol.

## Validation and documentation

Behavioral coverage belongs only in the native Titan standard-library suite at
`spec/stdlib/titan/fs/`. It must cover:

- `stat`/`lstat` success, missing leaves/parents, dangling symlinks, and a
  non-`ENOENT` error;
- `realpath` canonicalization, symlinks, missing paths, NUL rejection,
  independent concurrent requests, and cancellation-safe completion;
- empty and buffered polls, a blocked poll, cancellation,
  second-poller rejection, and last-stop/clear wakeup;
- idempotent canonical paths, multiple watched paths, stop/clear/re-watch, and final
  draining;
- directory create/delete/modify hints, direct file watching, canonical
  payloads, and nonrecursive directory scope without assuming exact counts or
  ordering; and
- Runtime-bound cleanup registered with `support.runtime`, never a later
  `test.Context` cleanup.

Update `doc/language/standard-library-fs.md` with the public contract and add an
implementation-side filesystem chapter linked from
`doc/implementation/index.md`. Refresh the exact serialized
`titan.fs` interface fixture. No Lua-written behavioral filesystem test is
added. The full native standard-library suite and local project gates must pass
before the branch is pushed and a PR is opened; Linux CI is monitored to green,
and macOS CI is left for maintainer review.
