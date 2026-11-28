# Filesystem standard library

The `fs` standard module provides asynchronous file I/O, metadata queries,
directory operations, temporary paths, and filesystem event watching behind a
synchronous-looking Titan API. Titan imports it with `local fs = import "fs"`
(parser sugar for `import "titan.fs"`); Lua loads the same module with
`require "titan.fs"`.

**Target availability:** Native (complete) & Browser (subset: 27 of 35 members;
omits `Watcher`, `WatcherEvent`, and `watcher`; see
[On the browser](#on-the-browser)).

## Example

The following module writes a file safely with `defer file:close()` and sums
the byte sizes of regular files in a directory:

```titan
local fs = import "fs"
local path = import "path"

function save_note(file_path: string, contents: string)
  local file = fs.open(file_path, "w")
  defer file:close()
  file:write(contents)
  file:flush()
end

function total_regular_bytes(dir: string): integer
  local total = 0
  local names = fs.list(dir)
  for i = 1, #names do
    local entry? = names[i]
    if entry then
      local info? = fs.stat(path.join(dir, entry))
      if info and info.kind == "file" then
        total = total + info.size
      end
    end
  end
  return total
end
```

## Tasks, concurrency, and errors

- **Async Task requirement:** File, metadata, directory, `realpath`, `tmpname`,
  and `Watcher` operations require an active [async Task](async-io.md) (running
  libuv work natively or coordinating browser storage durability). Importing
  `fs` installs the standalone async bootstrap for `main`; Lua hosts schedule
  work with `async.run` and drive `async.loop`. Only `tmpdir`, `homedir`,
  `pwd`, `chdir`, and `File` transfer hooks are synchronous and require no
  active Task.
- **`io` Interfaces:** `File` structurally satisfies all seven
  [`io` Interfaces](standard-library-io.md#standard-implementations) (adjusted
  dispatch for `read` and `write`, exact for `read_until` and `close`).
- **Paths vs. payloads:** Paths are text and reject embedded NUL bytes; file
  contents are unrestricted binary strings.
- **Errors:** Native libuv failures raise `async.OperationError` with
  `operation` naming the failing call (for example, `"fs.open"` or
  `"fs.rename"`). Two operations use non-raising results instead: `stat` and
  `lstat` return `nil` on `ENOENT`, and `Watcher:poll()` surfaces notification
  or classification failures as `WatcherEvent.error`.
- **Ownership and cancellation:** Application code owns `File:close()`; async
  Runtime shutdown does not track or close open `File` descriptors. Task
  cancellation lets accepted libuv requests complete before releasing buffers
  and delivering sticky cancellation (a cancelled `open` closes the acquired
  descriptor before raising cancellation).

### Closing the Lua state

When a Lua state closes, Titan synchronously closes every open `File` owned by
that state so a suspended Task's `defer file:close()` succeeds during unwind. A
`File` with an in-flight worker-pool `read`, `write`, or `flush` request stays
open until process exit so a reused OS descriptor number can never redirect
in-flight worker I/O.

## Opening, reading, and writing files

```text
record File

function open(path: string, mode: string): File
function read_file(path: string): string
function write_file(path: string, data: string)

function File:read(max_bytes: integer?): string?
function File:read_until(delimiter: string, chop: boolean?): string?
function File:write(data: string): integer
function File:flush()
function File:close()
function File:is_closed(): boolean
```

`open(path, mode)` accepts standard mode families (with an optional binary `b`
flag after the base letter or after `+`, such as `"rb"`, `"r+b"`, `"rb+"`; all
Titan file I/O is binary):

| Mode | Behavior |
| --- | --- |
| `r` | Read an existing file. |
| `w` | Write; create or truncate to zero bytes. |
| `a` | Write; create or append to end of file. |
| `r+` | Read and write an existing file. |
| `w+` | Read and write; create or truncate. |
| `a+` | Read and append; create if absent. |

Created files request mode `0666` (masked by the process umask). Unknown modes
raise.

- `File:read(max_bytes?)` reads sequentially from the current file position,
  defaulting to 64 KiB when `max_bytes` is omitted or `nil` (explicit values
  must be positive). If an earlier `read_until` retained excess bytes, `read`
  returns up to `max_bytes` from that buffer immediately without submitting a
  native read. Returns `nil` only at EOF; EOF is not sticky if the file later
  grows.
- `File:read_until(delimiter, chop?)` reads through the first literal,
  binary-safe `delimiter`, omitting it only when `chop` is `true`, and retaining
  trailing bytes for later reads. Rejects an empty delimiter. An unterminated
  tail at EOF is returned once before the next call returns `nil`. Because
  `read_until` composes repeated `read()` calls, already consumed bytes are not
  rolled back on error, and Tasks sharing one `File` must coordinate externally.
- `File:write(data)` writes every byte of `data` (continuing short native
  writes automatically) and returns `#data`. Writing `""` returns `0` without
  submitting native work.
- `File:flush()` synchronizes the descriptor with `uv_fs_fsync`.
- `File:close()` submits a native close and marks the wrapper terminal once
  libuv accepts the request (even if the close callback reports an error, so a
  reused descriptor number is never closed twice). Subsequent `close()` calls
  are idempotent no-ops, `is_closed()` returns `true`, `read` / `read_until`
  return `nil`, and `write` / `flush` raise. Coordinate `close()` externally
  with concurrent Task operations on the same `File`.
- `read_file(path)` reads an entire file in 64 KiB chunks into memory (without
  trusting `stat.size`) and closes the handle on success or error.
  `write_file(path, data)` creates or truncates `path`, writes all bytes, and
  closes the handle. Use `File:read` and `File:write` directly for streaming.

Each `File` operation submits an independent libuv thread-pool request without
per-descriptor serialization; Tasks sharing one `File` must coordinate
externally when operation order matters.

## Metadata, directories, and paths

```text
record Stat
  size: integer
  kind: string
  mode: integer
  device: integer
  inode: integer
  modified_seconds: integer
  modified_nanoseconds: integer
end
-- Synthesized constructor: Stat(...)

function stat(path: string): Stat?
function lstat(path: string): Stat?
function realpath(path: string): string
function mkdir(path: string)
function unlink(path: string)
function rmdir(path: string)
function rename(from: string, to: string)
function list(path: string): {string}
function tmpname(): string
function tmpdir(): string
function homedir(): string
function pwd(): string
function chdir(path: string)
```

- `stat(path)` follows symbolic links (`uv_fs_stat`); `lstat(path)` inspects
  the link itself (`uv_fs_lstat`). Both return `nil` on `ENOENT` (so a dangling
  symlink returns `nil` from `stat` and a `"symlink"` `Stat` from `lstat`),
  raising `async.OperationError` for other failures such as permission errors.
  - `kind` is `"file"`, `"directory"`, `"symlink"`, or `"other"`.
  - `mode` is the host-specific permission and type bitset.
  - `modified_seconds` and `modified_nanoseconds` (`0..999,999,999`) form the
    modification timestamp.
  - `(device, inode)` is an opaque physical-file identity pair for equality
    comparison across aliases (either field may be negative because Titan stores
    the full unsigned host value in a signed integer).
- `realpath(path)` resolves symbolic links, `.`, and `..` for an existing path
  and returns its canonical absolute path.
- `mkdir(path)` creates a directory with mode `0777` (masked by umask).
  `unlink(path)` removes a file or symlink; `rmdir(path)` removes an empty
  directory; `rename(from, to)` renames or moves an entry.
- `list(path)` returns an Array of entry names excluding `"."` and `".."` in
  unspecified order.
- `tmpname()` atomically creates an empty regular file in the temporary
  directory, closes its descriptor, and returns its path. The caller owns
  removing it with `unlink`.
- `tmpdir()`, `homedir()`, `pwd()`, and `chdir(path)` are synchronous and need
  no async Task. `tmpdir()` and `homedir()` follow the same platform rules as
  [`os.tmpdir()` and `os.homedir()`](standard-library-os.md#directories-and-host-identity).
  `chdir(path)` mutates the process-wide working directory; coordinate it across
  concurrent Tasks and restore the prior directory with `defer`.

```titan
local fs = import "fs"
local path = import "path"

function atomic_replace(target: string, payload: string): boolean
  local dir = path.dirname(target)
  local staging = path.join(dir, path.basename(target) .. ".tmp")
  fs.write_file(staging, payload)
  fs.rename(staging, target)
  local info? = fs.lstat(target)
  return info ~= nil and info.kind == "file"
end
```

## Watching filesystem changes

```text
record Watcher

union WatcherEvent
  created(value: string)
  deleted(value: string)
  modified(value: string)
  error(value: async.OperationError)
end

function watcher(): Watcher
function Watcher:watch(path: string)
function Watcher:stop(path: string)
function Watcher:is_watching(path: string): boolean
function Watcher:clear()
function Watcher:poll(): {WatcherEvent}
```

- `watcher()` creates a `Watcher` permanently bound to the current async
  Runtime. After that Runtime stops, all operations on the `Watcher` raise.
- `watch(path)` canonicalizes an existing file or directory via `realpath` and
  registers it (idempotent across equivalent paths or symlinks). A directory
  watch monitors immediate children only (not nested subdirectories); a file
  watch monitors that file. On macOS, FSEvents activates asynchronously after
  `watch` returns.
- `stop(path)` removes the canonical registration (no-op if unwatched or
  missing); `is_watching(path)` tests membership using the same lookup.
  `clear()` stops every registration and waits for native handles to close
  (idempotent after completion; concurrent `poll()` or `clear()` while clearing
  raises).
- `poll()` returns buffered `WatcherEvent` values, suspends if none are
  buffered while registrations are active, or returns `{}` immediately when no
  registrations remain. At most one Task may poll a `Watcher` at a time.
  Cancelling a blocked `poll()` detaches only that waiter without discarding
  buffered events or stopping registrations. After `stop` or `clear` removes
  the last registration, let the awakened `poll()` return before calling
  `watch` again.
- **Event payloads and classification:** Every path in `created`, `deleted`,
  and `modified` is canonical and absolute. Native rename flags classify as
  `created` or `deleted` via `lstat` at drain time (taking precedence over
  change flags). Direct-file notifications also check existence so deletion
  events retire the registration cleanly; watched directories likewise retire
  upon their own deletion. Classification or native status errors surface as
  `WatcherEvent.error` rather than raising from `poll()`. Filesystem
  notifications are OS hints—events may coalesce, duplicate, or omit changes.

```titan
local fs = import "fs"

function collect_next_events(dir: string): {string}
  local w = fs.watcher()
  defer w:clear()
  w:watch(dir)

  local summary: {string} = {}
  local events = w:poll()
  for i = 1, #events do
    local event = events[i]
    case event
    when created(p) then
      summary[#summary + 1] = "created: " .. p
    when deleted(p) then
      summary[#summary + 1] = "deleted: " .. p
    when modified(p) then
      summary[#summary + 1] = "modified: " .. p
    when error(err) then
      summary[#summary + 1] = "error: " .. err.message
    end
  end
  return summary
end
```

## Transferring files

```text
function File:to_transfer_payload(): string
function File.from_transfer_payload(payload: string): File
```

`File:to_transfer_payload()` moves an open, idle `File` (its OS descriptor and
any retained delimiter-read remainder) into a same-process opaque protobuf
payload. Serialization completes before detachment; pending `read`,
`read_until`, `write`, `flush`, or `close` operations are rejected before
changing the source. After detachment, the source behaves like a closed `File`.
`File.from_transfer_payload(payload)` adopts the descriptor without reopening
its path, preserving file offset and mode. Both hooks are synchronous and need
no active Task; subsequent I/O on the adopted `File` requires a Task as usual.

These hooks follow the [`async.TransferValue`](async-io.md#transfer-values)
contract and [shared manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules):
deliver and adopt each payload exactly once in the same process and close the
adopted `File` explicitly. `File` has no `discard_transfer_payload`; recover an
undelivered payload by calling `File.from_transfer_payload` and closing the
resulting `File`. Copying or dropping a payload does not duplicate or close the
descriptor.

## On the browser

On `--target browser`, `titan.fs` provides **27 of 35** members—everything
except filesystem watching (`Watcher`, `WatcherEvent`, and `watcher` are absent
at compile time). Importing `fs` automatically links the
[browser filesystem runtime](browser-target.md#filesystem-and-durable-storage).

- **Resident VFS and `io` Interfaces:** File reads, writes, metadata queries,
  directory scans, `realpath`, `pwd`, and `chdir` run against the instance's
  resident filesystem, so changes are immediately visible to C code, stock Lua
  `io.*`, and `titan.sqlite3`. `File` structurally satisfies all seven
  [`io` Interfaces](standard-library-io.md#standard-implementations) and works
  with `io.lines`.
- **Task admission and durability:** `open`, `read`, `read_until`, `write`,
  `flush`, `close`, `read_file`, `write_file`, metadata queries, directory
  operations, `realpath`, and `tmpname` require an active async Task as
  natively (`tmpdir`, `homedir`, `pwd`, `chdir`, and `File` transfer hooks are
  synchronous). `File:flush()`, writable `File:close()`, `fs.write_file()`, and
  `fs.tmpname()` wait for the storage worker to flush that descriptor's durable
  file on OPFS mounts; `fs.mkdir()`, `fs.unlink()`, `fs.rmdir()`, and
  `fs.rename()` wait for the storage worker's replay barrier so durable
  namespace updates settle without flushing unrelated open files. Capacity or
  storage failures raise `async.OperationError` (such as `ENOSPC`, `EBADF`, or
  `EIO`).
- **Temporary paths:** `fs.tmpname()` creates an empty file exclusively under
  `tmpdir()` (default `/tmp`) using platform entropy and returns its path.
- **Transfer and Lua-state close:** `File:to_transfer_payload()` and
  `File.from_transfer_payload()` move an open, idle descriptor and any retained
  delimiter remainder across `lua.new()` states within the same browser
  instance. During Lua-state close, open descriptors are retired synchronously
  without suspending, and any pending durable flush finishes before instance
  disposal completes.
