# Filesystem standard library

The `fs` standard module provides asynchronous file and path operations with a
synchronous-looking Titan interface. Titan imports the canonical module with
`import "fs"`; Lua loads the same module identity with `require "titan.fs"`.
The current supported hosts are Linux and macOS. The
[libuv setup instructions](../../README.md#libuv-setup) cover the default
pinned build and optional system-package mode on both platforms.

```titan
record File
record Stat
record Watcher

union WatcherEvent
  created: string
  deleted: string
  modified: string
  error: async.OperationError
end

function open(path: string, mode: string): File
function read_file(path: string): string
function write_file(path: string, data: string)

function File:read(max_bytes: integer?): string?
function File:read_until(delimiter: string, chop: boolean?): string?
function File:write(data: string): integer
function File:flush()
function File:close()
function File:is_closed(): boolean

function stat(path: string): Stat?
function lstat(path: string): Stat?
function realpath(path: string): string
function tmpname(): string
function tmpdir(): string
function homedir(): string
function pwd(): string
function chdir(path: string)
function mkdir(path: string)
function unlink(path: string)
function rmdir(path: string)
function rename(from: string, to: string)
function list(path: string): {string}

function watcher(): Watcher
function Watcher:watch(path: string)
function Watcher:stop(path: string)
function Watcher:is_watching(path: string): boolean
function Watcher:clear()
function Watcher:poll(): {WatcherEvent}
```

`File` structurally satisfies all seven
[`io` Interfaces](standard-library-io.md#standard-implementations). The
Interface wrapper adjusts the zero-argument `Reader.read` call to the optional
`max_bytes` parameter and discards `write`'s byte-count result; its
`read_until` and `close` slots are exact.

Operations that can wait must run inside an [async Task](async-io.md). Importing
`fs` transitively installs the standalone async bootstrap, so a Titan `main`
may call these functions directly. A Lua host schedules a Task with `async.run`
and drives it with `async.loop` after loading `require "titan.async"`.

## Opening and using files

`open(path, mode)` accepts these mode families:

| Mode | Meaning |
| --- | --- |
| `r` | Read an existing file. |
| `w` | Write; create the file or truncate it to zero bytes. |
| `a` | Write; create the file or append to it. |
| `r+` | Read and write an existing file. |
| `w+` | Read and write; create or truncate the file. |
| `a+` | Read and append; create the file if necessary. |

An optional `b` is accepted after the base letter or after `+`, where familiar:
for example, `rb`, `r+b`, and `rb+`. It does not change behavior on Linux or
macOS because Titan file payloads are already binary. Any other mode raises.
Files created by `open` request permissions `0666`, subject to the process
umask.

The returned `File` is an opaque wrapper around an operating-system descriptor;
callers cannot construct, forge, or extract that descriptor.

`read(max_bytes)` uses 64 KiB when `max_bytes` is omitted or `nil`. An
explicit size must be positive. It returns at most that many bytes, possibly
fewer, and returns `nil` only when no bytes are available at end of file.
Allocation failure raises normally. Reads use the File's current position;
there is no random-access offset API in this version.

A delimiter read may have already retained bytes beyond its result. A plain
`read(max_bytes)` consumes at most `max_bytes` from those bytes and returns
immediately, without topping up the result with another native read. Any
retained remainder stays with the File for the next read.

`read_until(delimiter, chop)` reads through the first literal delimiter. The
delimiter is included by default and omitted only when `chop` is `true`.
Delimiter matching and results are binary-safe, including embedded NUL bytes.
An empty delimiter raises. Bytes after the first delimiter are retained and
are observed by the next `read` or `read_until`.

```titan
local line = file:read_until("\n", true)
```

If EOF arrives after some bytes but before the delimiter, `read_until`
returns that unterminated tail. It returns `nil` only when EOF supplies no
bytes. EOF is not permanently sticky: if another descriptor later grows the
file, a subsequent read from this File can observe the new bytes.

`write(data)` writes the complete string and returns `#data`. A short native
write is continued internally before the method returns. Writing `""` returns
zero without submitting native work. Strings are binary: embedded NUL and all
byte values are preserved.

`flush()` asks the operating system to synchronize the File with
`uv_fs_fsync`.

```titan
local fs = import "fs"

function replace(path: string, data: string)
  local file = fs.open(path, "w")
  defer file:close()
  file:write(data)
  file:flush()
end
```

## Concurrency and closing

Each File operation submits its own libuv filesystem request. Libuv runs those
requests as independent thread-pool jobs and does not promise per-descriptor
ordering. Tasks that share one File must therefore coordinate externally when
operation order matters. A `read` satisfied entirely from facade-retained
excess submits no request and returns immediately.

`read_until` is high-level composition over repeated `read()` calls. Each
underlying native read is a separate operation, so another Task's read,
write, flush, or close may run between iterations. Code that shares one File
between Tasks must coordinate externally when it needs an uninterrupted
delimiter read.

`close()` submits an ordinary libuv filesystem close and consumes the wrapper's
descriptor once libuv accepts it. After that point `read` and `read_until`
return `nil` as ordinary Reader EOF, while `write` and `flush` reject the
closed File. Repeated close is idempotent, `is_closed()` reports that terminal
state, and close discards facade-retained delimiter excess. If another
filesystem request is already using the descriptor, its result follows the
host/libuv ordering; Titan does not add an active-operation counter or close
queue. Coordinate close with other File operations when that distinction
matters.

Task cancellation does not abandon or suppress accepted native work. The
runtime still consumes the terminal callback before releasing the request and
buffers, and only then injects sticky cancellation into the Task. If a
cancelled `open` succeeds, the runtime closes the descriptor that was never
delivered to the caller.
`read_until` is ordinary composition rather than a transaction: if it raises,
bytes already consumed by its earlier reads are not restored. A currently
pending native read retains the ordinary File-read cancellation semantics.
Cancellation remains sticky after the callback: it is delivered at the next
ordinary asynchronous operation or makes the Task terminally cancelled when it
returns.

Application code owns `File:close()`. A File is an operating-system descriptor,
not a libuv loop handle, so async Runtime shutdown neither tracks nor closes a
File left open. Such a descriptor remains open until application code closes
it or operating-system process teardown reclaims it. Once libuv accepts a
close submission, the File wrapper is terminal even if the callback reports an
error. The runtime reports that error once and never retries the close, because
the operating system may already have reused that descriptor number.

## Whole-file helpers

`read_file(path)` opens in `r` mode, iterates the bound `File:read` method with
its 64-KiB default until EOF, and closes the File on both success and error. It
does not trust `stat.size`: files
may change while they are read. Chunks accumulate in `string.StringWriter`,
which checks their aggregate length against Titan's integer/string limit and
joins them with one exact-size copy when drained.

`write_file(path, data)` opens in `w` mode, writes the complete binary string,
and closes the File on success or error.

These helpers keep all data in memory. Use `File:read` and `File:write` directly
when an application should stream or bound its memory use.

## Metadata and path operations

`stat(path)` returns:

```titan
record Stat
  size: integer
  kind: string
  mode: integer
  device: integer
  inode: integer
  modified_seconds: integer
  modified_nanoseconds: integer
end
```

`kind` is `"file"`, `"directory"`, `"symlink"`, or `"other"`. `stat` uses
`uv_fs_stat`, so **it follows symbolic links**: asking about an ordinary
symlink reports the target's metadata and kind. `lstat` returns the same
`Stat` shape but uses `uv_fs_lstat`, so asking about a symbolic link reports
the link itself with `kind == "symlink"`. `mode` is the platform mode bitset
supplied by libuv; its numeric permission/type bits are host-specific. The two
modification fields form one timestamp, with nanoseconds in the range 0
through 999,999,999. `device` and `inode` form an opaque physical-file
identity pair. Compare both fields for equality when identifying the same
physical file through aliases; do not interpret their numeric values. Either
field may be negative because Titan preserves the complete unsigned host value
through its signed integer carrier.

If the requested path does not exist, `stat` and `lstat` return `nil`.
Only libuv's `UV_ENOENT` result has that meaning; permission failures,
invalid path components, and every other error still raise
`async.OperationError`. A dangling symbolic link therefore returns `nil` from
`stat`, while `lstat` returns the link's own `Stat` value.

These optional results are part of the ABI-0.25 boundary. ABI 0.24 declared
both functions with an exact `Stat` result; changing them to `Stat?` changes the
serialized public `titan.fs` interface and each exact native result signature.
An ABI-0.24 provider remains preserved prior-version state and is rejected
rather than migrated or adapted.

The active, unreleased ABI-0.26 boundary adds `device` and `inode` to the
serialized public `Stat` record. Existing 0.26 provider metadata is rebuilt in
place during development; no additional ABI marker is introduced.

`realpath(path)` resolves symbolic links plus `.` and `..` components and
returns the canonical absolute path. The complete path must exist. It rejects
embedded NUL bytes and raises `async.OperationError` for a missing or otherwise
unresolvable path. Like metadata operations, it runs inside the current Task.
If the current Task is cancelled while the short native request is pending,
its waiter is detached before the next-turn cancellation wake. The result is
not delivered, but the accepted request still reaches its callback and
cleanup.

`mkdir(path)` requests mode `0777`, subject to the process umask. `unlink(path)`
removes a file or symbolic link; it does not stand in for directory removal.
`rmdir(path)` removes an empty directory. `rename(from, to)` uses libuv's
filesystem rename operation.

`list(path)` returns entry names without `.` or `..`. Names are copied before
the native scandir request is cleaned up. Titan does not specify their order;
sort them in application code when order matters.

Paths are text arguments. An embedded NUL is rejected instead of silently
truncating it; libuv copies paths for accepted asynchronous filesystem
requests. File contents remain unrestricted binary strings.

## Watching filesystem changes

`watcher()` creates a `Watcher` bound permanently to the current async Runtime
and event loop. Creating or using one requires a running Task. After that
Runtime stops, every operation on the Watcher raises; a Watcher is not reset
for reuse by a later Runtime.

`watch(path)` requires an existing file or directory. It calls `realpath` once
and registers the resulting canonical absolute target. Repeating the call for
the same target is idempotent, including through another symbolic link or an
equivalent `.` or `..` spelling. A directory watch covers its immediate
entries, not descendants of nested directories. A file watch reports only
that file. `watch` returns after libuv accepts the registration. On Darwin,
libuv activates the underlying FSEvents stream asynchronously, so a mutation
issued immediately afterward may predate the native subscription; let the event
loop settle before relying on a subsequent mutation.

`stop(path)` resolves the supplied spelling and stops its canonical
registration. A missing or unwatched path is a no-op. `is_watching(path)` uses
the same lookup and returns false for either case. The Watcher stores only
canonical identities; it does not retain every spelling used by callers.
`clear()` stops every registration. Both `stop` and `clear` wait until each
native watcher handle has closed, and `clear` is idempotent after completion.
While one clear is waiting for those closes, a new `poll` or second `clear`
raises.

`poll()` returns the currently buffered events. If none are buffered while a
registration is active, it suspends the current Task until a callback arrives
or the last registration is removed. If the Watcher has no registrations, it
returns an empty Array immediately. Only one Task may poll a given Watcher at a
time. Tasks that mutate one Watcher concurrently must coordinate those calls
externally. Cancelling a blocked poll detaches only that Task's waiter. It does
not discard buffered events or stop registrations that another Task may poll.
An unrelated call to the blocked Task's public `resume` method merely causes
`poll` to recheck its state; while registrations remain and no event is
buffered, it suspends again instead of returning an empty Array.

Classification may suspend while more native callbacks are copied. If one of
those callbacks belongs to a registration retired by the current `poll`, that
poll also drains the complete follow-on callback batch in order. This keeps the
retirement boundary complete: after a deletion event retires a direct file or
watched root, the next `poll` cannot return an already-copied notification for
that retired registration. Notifications for registrations that remain live
normally stay buffered for the next `poll`.

```titan
union WatcherEvent
  created: string
  deleted: string
  modified: string
  error: async.OperationError
end
```

Every path payload is canonical and absolute. A directory callback's filename
is joined to the watched directory; a file callback names the watched file.
Each native notification maps to one `WatcherEvent`. A native rename flag is
classified as `created` or `deleted` by calling `lstat` when `poll` drains the
notification; if rename and change flags are both present, rename takes
precedence. An ordinary directory change maps to `modified`. Every direct-file
notification checks the watched path as well, because Darwin may report that
file's deletion with only a change flag: a missing path maps to `deleted` and
retires the registration, while an existing change maps to `modified`. A
watched directory likewise retires when draining its own deletion event.

A negative native status or an `async.OperationError` raised while classifying
one notification maps to the `error` arm instead of making `poll` raise. Other
Task errors, including cancellation or use outside the Watcher's Runtime,
retain their ordinary behavior.

Filesystem notifications are hints rather than a journal. The operating
system or libuv may combine, duplicate, or omit changes, and the target may
change again before drain-time classification. Applications must not assume
one notification per filesystem operation, exact counts, or a total order.
Events copied before `stop` or `clear` remain observable. A poll that crosses
that registration's retirement drains its complete follow-on callback batch;
otherwise they remain buffered for a final `poll`.

## Temporary files and working directory

`tmpname()` atomically creates a unique empty regular file in the platform
temporary directory and returns its path. The file remains present and belongs
to the caller, which should eventually remove it with `unlink`. Titan closes
the descriptor acquired by `uv_fs_mkstemp` before `tmpname` returns; the API
does not return an open `File`.

Like every accepted filesystem request, temporary-file creation keeps its
native request alive until the callback even when its Task is cancelled. A
successful cancelled operation closes the descriptor that `uv_fs_mkstemp`
returned before delivering cancellation, but it does not unlink the path: the
operation is not transactional. Applications that need stronger cleanup
should create temporary files inside an application-owned directory.

`tmpdir()` returns the platform temporary directory without creating a file or
directory. `homedir()` returns the current user's home directory. They follow
the same libuv platform and environment-variable rules as
[`os.tmpdir()` and `os.homedir()`](standard-library-os.md#directories-and-host-identity),
respectively. Both functions are synchronous and do not require an active
async Task.

`pwd()` returns the process working directory. `chdir(path)` changes that
process-wide directory, so it affects relative paths used by every Task and by
the embedding host. These two helpers are synchronous and do not require an
active async Task. Coordinate `chdir` externally when Tasks can run
concurrently, and restore the previous directory with `defer` when the
change is temporary.

## Errors and current scope

Libuv failures raise [`async.OperationError`](async-io.md#errors-and-cancellation).
Its `operation` identifies the failing action (for example, `fs.open` or
`fs.rename`). Watcher notification and classification failures are the one
result-valued exception: `poll` returns them as `WatcherEvent.error`. The
library does not print errors.

This module does not provide random-access reads/writes,
permissions/ownership changes, link creation, recursive filesystem watching,
memory mapping, or synchronous file-content operations.
