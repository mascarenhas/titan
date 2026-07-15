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

function open(path: string, mode: string): File
function read_file(path: string): string
function write_file(path: string, data: string)

function File:read(max_bytes: integer): string?
function File:write(data: string): integer
function File:flush()
function File:close()
function File:is_closed(): boolean

function stat(path: string): Stat
function mkdir(path: string)
function unlink(path: string)
function rmdir(path: string)
function rename(from: string, to: string)
function list(path: string): {string}
```

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

The returned `File` is opaque. Its exact native descriptor is stored once in a
local record field, so callers cannot construct, forge, or extract it.

`read(max_bytes)` requires a positive size. It returns up to that many bytes,
possibly fewer, and returns `nil` only at end of file. Reads use the File's
current position; there is no random-access offset API in this version.

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

## Ordering and closing

Each File serializes its operations in one FIFO, even when several Tasks share
it. Only one filesystem request for that File is submitted at a time. A
multi-request partial write remains one logical FIFO operation, so another
read, write, flush, or close cannot interleave with it.

`close()` immediately marks the File as closing. Operations already ahead of
the close finish in order; later reads, writes, and flushes raise. Concurrent
close callers share the same physical close request. `close()` is idempotent,
including after the Runtime session has ended, and `is_closed()` reports
whether physical close has completed.

Task cancellation does not abandon native lifetime work. An unsubmitted
ordinary File operation is removed from its FIFO. For submitted work, the
runtime requests cancellation where libuv supports it, suppresses a stale
result after cancellation wins, and still consumes the completion callback.
A Task cancelled while awaiting `close()` remains cleanup-shielded until the
physical close callback and request cleanup finish. Cancellation remains
sticky afterward: it is delivered at the next ordinary asynchronous operation,
or makes the Task terminally cancelled when it returns. This lets a `finally`
block close several Files in sequence instead of being interrupted after its
first physical close.

When the final Task ends, session shutdown closes any File that application
code left open. Explicit close is still preferred because it reports errors at
the relevant call site and releases the descriptor earlier. A native close
callback is terminal even when it reports an error: the File wrapper is marked
closed and the error is reported once. The runtime never retries a failed close,
because the operating system may already have reused that descriptor number.

## Whole-file helpers

`read_file(path)` opens in `r` mode, reads fixed 64 KiB chunks until EOF, and
closes the File on both success and error. It does not trust `stat.size`: files
may change while they are read. Chunk lengths are checked against Titan's
integer/string limit before joining them with a balanced concatenation tree.

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
  modified_seconds: integer
  modified_nanoseconds: integer
end
```

`kind` is `"file"`, `"directory"`, `"symlink"`, or `"other"`. The function
uses `uv_fs_stat`, so **it follows symbolic links**: asking about an ordinary
symlink reports the target's metadata and kind. There is no `lstat` operation
in this version. `mode` is the platform mode bitset supplied by libuv; its
numeric permission/type bits are host-specific. The two modification fields
form one timestamp, with nanoseconds in the range 0 through 999,999,999.

`mkdir(path)` requests mode `0777`, subject to the process umask. `unlink(path)`
removes a file or symbolic link; it does not stand in for directory removal.
`rmdir(path)` removes an empty directory. `rename(from, to)` uses libuv's
filesystem rename operation.

`list(path)` returns entry names without `.` or `..`. Names are copied before
the native scandir request is cleaned up. Titan does not specify their order;
sort them in application code when order matters.

Paths are text arguments. Every path is copied into operation-owned,
NUL-terminated storage and an embedded NUL is rejected instead of silently
truncating it. File contents remain unrestricted binary strings.

## Errors and current scope

Libuv failures raise [`async.Error`](async-io.md#results-errors-and-cancellation).
Its `operation` identifies the failing action (for example, `fs.open` or
`fs.rename`) and `subject` identifies the relevant path or File. The library
does not print errors.

This initial module does not provide random-access reads/writes, `lstat`,
permissions/ownership changes, links, filesystem watching, memory mapping, or
synchronous filesystem calls.
