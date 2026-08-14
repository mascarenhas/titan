# fs file watcher

```
record Watcher
  -- only local fields
end

union WatcherEvent
  created: string
  deleted: string
  modified: string
end

function fs.watcher(): Watcher
  -- public constructor
end

function Watcher:watch(path: string)
  -- starts watching folder or file
  -- idempotent, watcher can watch
  -- multiple files/folders
  -- watching folders does not recurse
  -- into subfolders
end

function Watcher:stop(path: string)
  -- stops watching path, no-op
  -- if not already watching
end

function Watcher:is_watching(path: string): boolean
  -- returns if the path is being watched or not
end

function Watcher:clear()
  -- stops watching all paths
  -- does not guarantee that events will
  -- stop arriving while this is ongoing,
  -- so caller should do a final `poll()`
end

function Watcher:poll(): {WatcherEvent}
  -- drains accumulated events
  -- blocks current task until events are available
  -- if actively watching, or immediately
  -- returns empty array if not watching anything
end

function fs.realpath(path: string): string
  -- calls libuv.uv_fs_realpath with a callback
  -- that will resume the current task, then
  -- pauses the task
end
```

Internally this uses a map of paths normalized with
`fs.realpath` to libuv `uv_fs_event_t` handles, each watching
a single path but all feeding into the same `foreign` callback.
The `foreign` callback unpacks from the handle's `data` the
main Lua state, the `_mod`, and the real callback,
which is a closure that captures both the `Watcher` instance
and the normalized watched path, then calls the callback
with the event code and filename.

These callbacks feed the internal event buffer in the `Watcher`
instance, converting the internal libuv event code into the
`WatcherEvent` union, then wakes the waiting Task (with `:resume()`)
if there is one. Note that the callback needs to call `fs.stat`
to determine if the event was a creation or deletion
(the return types of fs.stat and fs.lstat need to be fixed to be
an option type, and they should return nil in case of an UV_ENOENT result
from libuv instead of raising).

Calling `poll` with no events in the buffer puts the current task
as the waiter in the internal `Watcher` state (or raises if there
is a waiter already), then `async.suspend()`

Note that this can be done entirely through the FFI and the
`async` module task APIs, it does not need to add new operations
in the `uv` module.

Even `fs.realpath` can be implemented this way. It can call
`uv_fs_realpath` itself then `async.suspend()`, and when the callback
fires it will `task:resume()`. The actual callback the `foreign`
libuv callback calls can be a closure that closes over a local variable
used to write the `realpath` value.

The high-level `fs` module can get the main Lua state from the `uv`
module's `main_thread` module variable since it is a direct source
import. The module can also get the event loop reference the same way.
