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

function File:read(max_bytes: integer?): string?
function File:read_until(delimiter: string, chop: boolean?): string?
function File:write(data: string): integer
function File:flush()
function File:close()
function File:is_closed(): boolean

function stat(path: string): Stat
function lstat(path: string): Stat
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

The returned `File` is opaque. Its exact native descriptor is stored once in a
local record field, so callers cannot construct, forge, or extract it.

`read(max_bytes)` uses 64 KiB when `max_bytes` is omitted or `nil`. An
explicit size must be positive and no larger than libuv's portable native
buffer bound. It returns at most that many bytes, possibly fewer, and returns
`nil` only when no bytes are available at end of file. Reads use the File's
current position; there is no random-access offset API in this version.

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

## Ordering and closing

Each File serializes the operations it submits to uv in one FIFO, even when
several Tasks share it. Only one filesystem request for that File is submitted
at a time. A multi-request partial write remains one logical FIFO operation.
A `read` satisfied entirely from facade-retained excess submits no request and
returns immediately.

`read_until` is high-level composition over repeated `read()` calls. Each
underlying native read is a separate FIFO operation, so another Task's read,
write, flush, or close may run between iterations. Code that shares one File
between Tasks must coordinate externally when it needs an uninterrupted
delimiter read.

`close()` immediately marks the File as closing. Operations already ahead of
the close finish in order; later reads, writes, and flushes raise while the
physical close is pending. Once close reaches its terminal state, `read` and
`read_until` return `nil` as ordinary Reader EOF, while `write` and `flush`
continue to reject the closed File. Concurrent close callers share the same
physical close request. `close()` is idempotent, including after the Runtime
session has ended, and `is_closed()` reports whether physical close has
completed. Terminal EOF and repeated close remain observable even from a
later Runtime generation because they inspect only the wrapper's monotonic
closed state; other operations retain the stale-generation error. A read
cannot bypass logical close through bytes retained by an earlier delimiter
read: close discards that facade excess even when the earlier read finishes
while physical close is pending.

Task cancellation does not abandon native lifetime work. An unsubmitted
ordinary File operation is removed from its FIFO. For submitted work, the
runtime requests cancellation where libuv supports it, suppresses a stale
result after cancellation wins, and still consumes the completion callback.
If `read_until` raises after consuming bytes, including cancellation between
an underlying read and committing those bytes to its result builder, all
consumed bytes are restored in order to the File's retained input before the
error propagates. A currently pending native read retains the ordinary
File-read cancellation semantics.
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
through 999,999,999.

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

## Temporary files and working directory

`tmpname()` atomically creates a unique empty regular file in the platform
temporary directory and returns its path. The file remains present and belongs
to the caller, which should eventually remove it with `unlink`. Titan closes
the descriptor acquired by `uv_fs_mkstemp` before `tmpname` returns; the API
does not return an open `File`.

If a Task is cancelled after the native operation has created a file, Titan
still consumes the callback and closes the acquired descriptor. The created
path remains present even though the cancelled Task does not receive it. This
avoids silently deleting a filesystem object that was successfully created;
applications that need stronger transactional cleanup should create temporary
files inside an application-owned directory.

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
concurrently, and restore the previous directory with `finally` when the
change is temporary.

## Errors and current scope

Libuv failures raise [`async.Error`](async-io.md#results-errors-and-cancellation).
Its `operation` identifies the failing action (for example, `fs.open` or
`fs.rename`) and `subject` identifies the relevant path or File. The library
does not print errors.

This module does not provide random-access reads/writes,
permissions/ownership changes, links, filesystem watching, memory mapping, or
synchronous file-content operations.
