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
symlink or `.`/`..` spelling.

Event payloads are canonical absolute paths. `created` and `deleted` are
best-effort classifications of a native rename/entry-change notification:
`poll` checks `lstat` when it processes the notification. The target may have
changed again by then, and libuv or the operating system may coalesce,
duplicate, or omit detail. The stream is a change hint, not a durable journal,
and no total ordering or one-event-per-operation contract is promised. A
native notification with both `UV_RENAME` and `UV_CHANGE` contributes the
rename classification first and `modified` second.

`stop(path)` stops the one canonical registration, regardless of which stored
alias names it, and is a no-op for an unwatched or now-missing path.
`is_watching(path)` uses the same identity rule. The Watcher retains stable
absolute alias keys as well as the canonical key so the original spelling can
still stop/query a registration after the target has been deleted and a fresh
`realpath` is impossible. Stopping one alias is not reference counting: the
canonical registration and all of its aliases become inactive.

`clear()` logically stops every registration and is idempotent. It calls
`uv_fs_event_stop` before scheduling each handle's asynchronous `uv_close`, so
no new event callbacks begin after `clear` returns. Notifications already
copied into the Watcher remain buffered; callers may use one final `poll()` to
drain them. `stop`, `clear`, a registration error, and direct-target deletion
wake a blocked poll when they remove the final live registration.

`poll()` drains the notifications that are currently buffered. If none are
buffered while at least one registration is active, it blocks the current Task
with `async.suspend()`. If there are no registrations, it returns an empty
Array immediately. At most one `poll` may be in progress for a Watcher. The
predicate is checked in a loop because `Task:resume()` is public and wakes are
coalesced. Cancelling a blocked poll detaches only its waiter; it neither loses
buffered notifications nor stops shared registrations.

A negative native watcher callback status is contained inside the callback,
retires that registration, wakes the waiter, and makes the next `poll` raise an
`async.OperationError`. No Titan error may unwind through libuv.

A Watcher with live registrations belongs to their async Runtime. Once all
registrations are stopped it may be reused. If a forgotten registration is
closed by Runtime shutdown, the facade discards that stale generation before
it starts work in a later Runtime.

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

## High-level implementation boundary

This feature deliberately lives in `titan/fs.titan`, as requested. It uses the
public libuv FFI plus the existing direct-source access to `titan.uv`'s current
Runtime, error conversion, callback-entry types, and handle-root/close helpers.
It does not add a scheduler operation or a new `titan.uv` public API.

### `realpath`

`realpath` submits one `uv_fs_realpath` request on the running Task's Runtime
loop. Its source-defined foreign callback follows the standard exact callback
bridge: request data gives the owner Udata, owner slot 2 gives the Titan
closure, the loop gives the main Lua state, and the closure gives `_mod` and
its exact native entry. The callback copies `uv_fs_get_ptr(req)` to a Titan
string before `uv_fs_req_cleanup`.

A direct `async.suspend` is cancellation-sensitive, unlike a normal
`titan.uv` filesystem `Call`, so the accepted native request must not rely on
the suspended Task stack for lifetime. A traced module-owned request-root Array
keeps every accepted owner alive until its callback, including after Task
cancellation or an unrelated public `Task:resume`. The callback cleans the
request exactly once, removes that root, records its result/error, and resumes
the Task. The caller loops on `suspend` until the owner is complete. An
immediate negative submission performs cleanup/removes the root and raises
without suspending.

### Watch handles

Each canonical registration owns exactly one `owned *uv_fs_event_t`, one exact
callback closure, its Runtime/root index, canonical path, directory/file flag,
stable aliases, and dense Watcher index. The owner is placed in
`Runtime.handle_roots` before `uv_fs_event_init`. Init rejection unroots it;
start rejection transfers the initialized handle through the ordinary
asynchronous close owner. Successful stop uses `uv_fs_event_stop` and then the
same close transfer. Runtime `uv_walk` remains able to close a forgotten live
handle.

The foreign fs-event callback copies the nullable filename while libuv owns
it, records the integer event mask/status in a traced raw-notification Array,
and wakes the one waiter. It never yields and never calls `stat`/`lstat`,
because no async Task is current inside a libuv callback. A stored ordinary
Titan handler contains every error before the foreign entry returns.

`poll` detaches one raw snapshot while leaving callbacks free to append a newer
snapshot. It translates the detached records in callback order. A directory
filename is joined to the canonical watched directory; a missing filename is a
coarse notification for the watched directory itself. A file notification
always names the canonical watched file. For `UV_RENAME`, `poll` uses `lstat`
to choose `created` versus `deleted`; if the watched root itself is gone, the
root path is selected and the registration is retired. If classification is
cancelled or raises, the complete detached raw snapshot is restored ahead of
newer notifications so no accepted notification is lost.

## Validation and documentation

Behavioral coverage belongs only in the native Titan standard-library suite at
`spec/stdlib/titan/fs/`. It must cover:

- `stat`/`lstat` success, missing leaves/parents, dangling symlinks, and a
  non-`ENOENT` error;
- `realpath` canonicalization, symlinks, missing paths, NUL rejection,
  independent concurrent requests, and cancellation-safe completion;
- empty and buffered polls, a blocked poll, external resume, cancellation,
  second-poller rejection, and last-stop/clear wakeup;
- idempotent aliases, multiple watched paths, stop/clear/re-watch, and final
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
