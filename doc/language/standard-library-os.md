# Operating-system standard library

The `os` standard module provides clocks, calendars, locales, environment
variables, host paths and identifiers, signal waiting, graceful program exit,
child processes, shell commands, and standard process streams. Titan imports it
with `local os = import "os"` (parser sugar for `import "titan.os"`); Lua loads
the same module with `require "titan.os"` without modifying Lua's global `os`
table.

**Target availability:** Native (complete on Linux and macOS; Windows omits
`"usr1"`/`"usr2"` signals and TCP parent streams) & Browser (subset: calendars,
wall time, locale, instance environment, Task `exit`, and embedding parent
streams; see [On the browser](#on-the-browser)).

## Example

This module spawns an external executable with an overridden child environment,
drains its `stdout` and `stderr` pipes concurrently so OS pipe buffers cannot
deadlock, and returns its exit code and captured output:

```titan
local async = import "async"
local os = import "os"
local strings = import "string"

local function read_all(stream: os.InputStream): string
  local buf = strings.writer()
  defer buf:close()
  for chunk in stream:read do
    buf:write(chunk)
  end
  return buf:drain()
end

function run_tool(program: string, args: {string}): (integer, string, string)
  local proc = os.spawn(
    program, args, os.with_parent_stdin, os.with_env("LC_ALL", "C"))
  local stdout = proc.stdout
  local stderr = proc.stderr
  defer stdout:close()
  defer stderr:close()

  local out_task = async.run(function (): string return read_all(stdout) end)
  local err_task = async.run(function (): string return read_all(stderr) end)
  local output, err_output = async.all_two(out_task, err_task)
  local status = proc:wait()
  return status.code, output, err_output
end
```

## Async Tasks and thread safety

- **Synchronous helpers:** `clock`, `difftime`, `date`, `time`, `setlocale`,
  `getenv`, `setenv`, `unsetenv`, `cwd`, `chdir`, `homedir`, `tmpdir`,
  `hostname`, `exepath`, `pid`, and `ppid` run synchronously without an async
  Task.
- **Task-requiring operations:** `wait_signal`, `exit`, `spawn`, `popen`,
  `Process` methods, and all `InputStream`/`OutputStream`/`InputOutputStream`
  operations require an active [async Task](async-io.md) (including non-yielding
  `is_running`, `is_tty`, and `kind`, which validate the owning Runtime). A
  standalone Titan executable importing `os` installs the async bootstrap
  automatically; Lua hosts schedule work with `async.run` and drive
  `async.loop`.
- **Process-global C state:** On native targets, `setlocale`, `date`, `time`,
  `getenv`, `setenv`, `unsetenv`, and `chdir` access process-global C state and
  must not race across OS threads. Titan's async callbacks execute serially on
  one loop thread; embedding hosts must provide equivalent exclusion.

## Clocks, calendars, and locale

```text
record Date
  year: integer
  month: integer
  day: integer
  hour: integer
  min: integer
  sec: integer
  wday: integer
  yday: integer
  isdst: boolean?
end
-- Synthesized constructor: Date(...)

function clock(): float
function difftime(later: integer, earlier: integer): float
function date(format: string?, timestamp: integer?): value
function time(year: integer?, month: integer?, day: integer?,
              hour: integer?, min: integer?, sec: integer?,
              isdst: boolean?): integer
function setlocale(locale: string?, category: string?): string?
```

- `clock()` sums user and system CPU time consumed by the process in seconds
  (not elapsed wall time). Absent on the browser target.
- `difftime(later, earlier)` returns `later - earlier` in seconds for integer
  timestamps.
- `date(format?, timestamp?)` formats `timestamp` (default: current time) using
  `format` (default: `"%c"`). A leading `"!"` selects UTC instead of local
  time.
  - Format `"*t"` (or `"!*t"`) returns a `Date` record (`wday` is `1` Sunday
    through `7` Saturday; `yday` starts at `1`; `isdst` is `nil` when unknown).
  - Any other format uses Lua 5.5's validated C99 `strftime` conversions
    (including `E`/`O` modifiers) and returns a `string` with automatic buffer
    growth. Invalid specifiers and embedded NUL bytes raise.
- `time(year?, month?, day?, hour?, min?, sec?, isdst?)` returns the current
  Unix timestamp when called with no arguments. Otherwise `year`, `month`, and
  `day` are required together; `hour` defaults to `12`, `min` and `sec` to `0`,
  and `isdst` defaults to auto-detection. Out-of-range fields normalize via the
  host calendar (call `date("*t", ts)` to inspect normalized values). Use named
  calls for clarity. Unrepresentable dates or fields outside C `int` raise.
- `setlocale(locale?, category?)` queries (`locale == nil`) or sets the C
  locale for `category`: `"all"` (default), `"collate"`, `"ctype"`,
  `"monetary"`, `"numeric"`, or `"time"`. Returns the active locale name, or
  `nil` if unavailable. `""` selects the native locale; `"C"` selects the
  portable C locale. Rejects NUL bytes and unknown categories.

```titan
local os = import "os"

function epoch_and_offset(): (integer, float)
  local result = os.date("!*t", 0)
  local epoch_year = 0
  if result is os.Date then
    local epoch: os.Date = result
    epoch_year = epoch.year
  end

  local noon = os.time { year = 2026, month = 7, day = 31 }
  local later = os.time {
    year = 2026, month = 7, day = 31,
    hour = 13, min = 30, sec = 0,
  }
  return epoch_year, os.difftime(later, noon)
end
```

## Environment

```text
function getenv(name: string): string?
function setenv(name: string, contents: string)
function unsetenv(name: string)
```

`getenv` returns `nil` when absent and preserves empty values as `""`. `setenv`
creates or replaces a variable; `unsetenv` succeeds even if the variable is
absent. Names and values reject embedded NUL bytes. Native targets modify the
process environment; browser instances keep an isolated per-instance map (see
[On the browser](#on-the-browser)).

## Directories and host identity

```text
function cwd(): string
function chdir(path: string)
function homedir(): string
function tmpdir(): string
function hostname(): string
function exepath(): string
function pid(): integer
function ppid(): integer
```

All eight helpers are native-only. `cwd` and `chdir` read and change the
process working directory; `homedir` and `tmpdir` follow libuv's platform and
environment-variable rules; `hostname` returns the host name; `pid` and `ppid`
return process and parent process IDs. `exepath` returns the executable path in
compiled Titan programs and raises `"os.exepath is only available in a compiled
Titan program"` under external embedding hosts. Paths reject embedded NUL bytes,
and buffer-backed queries resize automatically.

## Waiting for a signal

```text
function wait_signal(name: string): string
```

Native-only. `wait_signal` suspends the current Task on a one-shot signal
watcher and returns the canonical lowercase signal name when delivered.
Supported names on Linux and macOS are `"hup"`, `"int"`, `"quit"`, `"term"`,
`"usr1"`, and `"usr2"` (Windows rejects `"usr1"` and `"usr2"`). Unknown names
and `"kill"` raise before creating a watcher. Repeated standard signals may
coalesce. Cancelling the Task stops and closes the watcher cleanly. While a
watcher is active, libuv owns that signal disposition.

## Graceful program exit

```text
function exit(code: integer?)
```

`exit(code?)` requests a graceful shutdown of the active async Runtime with
exit status `code` (default `0`). Any Task may call it; the first exit code
wins and cannot be replaced. The caller receives sticky Task cancellation,
other Tasks settle and run their `defer` blocks, accepted callbacks and
requests drain, loop handles close, and standalone executables return the
requested exit code.

`exit` does not close open `fs.File` descriptors or signal/reap child
processes—release those in application `defer` cleanup. When loaded inside an
external Lua host, `exit` finishes Titan's Runtime without closing the host's
Lua state. On the browser target, calling `exit` outside an async Task raises
`"os.exit is unavailable outside an async Task on the browser target"`.

## Child processes

```text
record ExitStatus
  code: integer
  signal: string?
  signal_number: integer
end
-- Synthesized constructor: ExitStatus(...)

record SpawnConfig
type SpawnOption = function (SpawnConfig): (integer)

record Process
  stdin: OutputStream?
  stdout: InputStream?
  stderr: InputStream?
end

function with_stdin(config: SpawnConfig): integer
function with_stdout(config: SpawnConfig): integer
function with_stderr(config: SpawnConfig): integer
function with_parent_stdin(config: SpawnConfig): integer
function with_parent_stdout(config: SpawnConfig): integer
function with_parent_stderr(config: SpawnConfig): integer
function with_merged_output(config: SpawnConfig): integer
function with_env(name: string, contents: string): SpawnOption

function spawn(file: string, args: {string}, ...: SpawnOption): Process
function Process:wait(): ExitStatus
function Process:kill(signal: string)
function Process:is_running(): boolean
```

Native-only.

### Spawn configuration

`spawn(file, args, ...)` executes `file` directly without a shell, supplying
`file` as `argv[0]` and `args` as subsequent arguments. The child inherits the
current environment and working directory. File and argument strings reject
embedded NUL bytes.

By default, all three child standard descriptors are captured as pipes.
`SpawnOption` callbacks execute left to right, with later options overriding
earlier ones:

- `with_stdin`, `with_stdout`, `with_stderr` capture the child descriptor as a
  parent-facing pipe (`Process.stdin` is an `OutputStream`; `Process.stdout`
  and `Process.stderr` are `InputStream` values).
- `with_parent_stdin`, `with_parent_stdout`, `with_parent_stderr` inherit the
  parent's descriptor (`nil` on the corresponding `Process` field).
- `with_merged_output` connects child stdout and stderr to one shared pipe so
  `process.stdout` and `process.stderr` hold the exact same `InputStream`
  instance.
- `with_env(name, contents)` overrides one variable in the child only (later
  entries for the same name win; empty values are kept; empty names or names
  containing `=` or NUL raise).

If child creation succeeds but post-spawn setup fails, `spawn` closes captured
streams, sends `SIGTERM` (escalating to `SIGKILL` after 30 seconds), waits for
the child to exit, and rethrows the original error.

### Process lifecycle

- `Process:wait()` waits for the child to exit and returns an `ExitStatus`
  (`signal == nil` and `signal_number == 0` on normal exit; canonical lowercase
  signal name when recognized). Only one Task may wait at a time; cancelling a
  waiter does not kill the child. Subsequent sequential `wait()` calls return
  the cached status immediately. Drain captured stdout and stderr concurrently
  with writing stdin and waiting to prevent OS pipe-buffer deadlock.
- `Process:kill(signal)` sends `"hup"`, `"int"`, `"quit"`, `"term"`, `"usr1"`,
  `"usr2"`, or `"kill"` (Windows rejects `"usr1"` and `"usr2"`). Unknown names
  and signalling an already exited `Process` raise.
- `Process:is_running()` reports retained live state without yielding or
  reaping the child; safe to check immediately before `kill()`.
- Async Runtime teardown closes process watchers without killing or reaping
  live children; applications that own child lifetimes must explicitly `kill()`
  and `wait()`.

## Process and parent streams

```text
stdin: InputStream
stdout: OutputStream
stderr: OutputStream

record InputStream
record OutputStream

function InputStream:read(): string?
function InputStream:read_until(delimiter: string, chop: boolean?): string?
function InputStream:close()
function InputStream:is_tty(): boolean
function InputStream:kind(): string

function OutputStream:write(data: string)
function OutputStream:shutdown()
function OutputStream:close()
function OutputStream:is_tty(): boolean
function OutputStream:kind(): string
```

`InputStream` satisfies `io.Reader`, `io.Closer`, and `io.ReaderCloser`
exactly; `OutputStream` satisfies `io.Writer`, `io.Closer`, and
`io.WriterCloser` exactly.

`kind()` returns `"tty"`, `"pipe"`, `"file"`, or `"tcp"` (Linux and macOS);
`is_tty()` is `true` when `kind() == "tty"`. Open captured child endpoints
always report `"pipe"`. Both methods require an active Task and validate the
owning Runtime, raising on closed or transferred captured endpoints.

### Parent standard streams

`os.stdin`, `os.stdout`, and `os.stderr` are mutable module variables bound
lazily to the active Runtime (and rebinding cleanly in subsequent Runtimes
without carrying over buffered bytes or sticky EOF/errors). Supported native
descriptor backings are:

- `"tty"`: Runtime-owned `uv_tty_t` over a close-on-exec duplicate of the
  parent descriptor.
- `"pipe"`: Runtime-owned `uv_pipe_t` over a duplicate of a pipe or Unix stream
  socket. Sandboxed Unix launchers that deny socket family/type probes may set
  `TITAN_STDIO_PIPE_FDS=0,1,2` (exact comma-separated subset of `0`, `1`, `2`)
  to hint pipe-compatible Unix stream sockets when probes fail with
  `EPERM`/`EACCES`.
- `"file"`: Regular files, `/dev/null`, and non-TTY character devices (and `NUL`
  on Windows), served via libuv thread-pool `uv_fs_read`/`uv_fs_write` at
  offset `-1` over borrowed descriptor `0`, `1`, or `2` (do not rebind the raw
  descriptor mid-Runtime; blocking character devices hold Runtime shutdown
  until the OS request finishes).
- `"tcp"` (Linux and macOS only): Connected IPv4/IPv6 TCP socket; see
  [TCP-backed parent streams](#tcp-backed-parent-streams).

Unsupported parent descriptor kinds (such as UDP sockets, listening or
unconnected TCP sockets, and all sockets on Windows) raise
`async.OperationError` with `operation == "stdio.parent.kind"` and
`name == "ENOTSUP"`. Invalid descriptors raise `EBADF`.

Reading `os.stdin` starts lazily on the first `read` or `read_until`; calling
`kind()`, `is_tty()`, `close()`, or `with_parent_stdin` consumes no bytes.
Calling `close()` on parent `os.stdin`, `os.stdout`, or `os.stderr` is an
idempotent no-op that never closes the host descriptor or sends a TCP FIN. On
Unix, inheriting a parent TTY, pipe, or TCP descriptor clears `O_NONBLOCK` on
the shared open file description.

### TCP-backed parent streams

On Linux and macOS, parent descriptors `0`, `1`, or `2` may be connected IPv4
or IPv6 TCP sockets (for example, from `inetd`, systemd `Accept=yes`, or
launchd `Wait=false`). Listening or unconnected sockets are rejected with
`stdio.parent.kind` (`ENOTSUP`). Peer write-half close reads as EOF after any
buffered bytes; resets raise `stdio.read` or `stdio.write`.

`OutputStream:shutdown()` waits for accepted writes on that stream and
half-closes the TCP write side (`SHUT_WR`) so input stays readable:

- Once accepted, subsequent writes (even `""`) raise `stdio.write` (`EPIPE`),
  and repeated `shutdown()` calls return immediately.
- Calling `shutdown()` on `"tty"`, `"pipe"`, or `"file"` streams (including
  captured `process.stdin`) raises `stdio.shutdown` (`ENOTSUP`) without
  modifying the stream. To deliver EOF to a captured child, call
  `process.stdin:close()`.
- `shutdown()` acts on the underlying TCP connection shared by `os.stdout`,
  `os.stderr`, raw descriptors, and inheriting children. Parent `close()` never
  sends FIN; call `shutdown()` to half-close explicitly.

### Stream I/O semantics

- **Writes:** Nonempty writes to TTY, pipe, or TCP streams submit a `uv_write_t`
  and wait for completion; empty writes submit nothing (unless the stream is
  closed or shut down). File-backed parent streams serialize accepted writes in
  FIFO order on the libuv worker pool (continuing short writes automatically;
  graceful Runtime shutdown drains accepted writes, while abrupt Lua-state
  close finishes only the single in-flight OS write). On Unix, `titan.async`
  ignores default `SIGPIPE` so closed child pipes produce write errors instead
  of terminating the process. Closing a captured `process.stdin` sends EOF to
  the child.
- **Reads:** Captured child output pipes begin reading immediately upon `spawn`
  and buffer unread chunks in memory. File-backed `os.stdin` reads on demand in
  64 KiB chunks. `read()` returns retained delimiter excess first, then the
  next buffered chunk, or waits. EOF returns `nil` permanently for the current
  Runtime; read errors raise `stdio.read` permanently after buffered chunks
  drain. `read_until(delimiter, chop?)` rejects empty delimiters, returns
  unterminated EOF tails once before `nil`, and does not roll back consumed
  bytes on error. Only one Task may read a given `InputStream` at a time;
  cancelling a waiter detaches only that waiter. Closing a captured
  `InputStream` is idempotent, discards buffered bytes, wakes any blocked
  reader with `nil`, and does not terminate the child.

## Shell commands

```text
record InputOutputStream

function popen(command: string): InputOutputStream
function InputOutputStream:read(): string?
function InputOutputStream:read_until(delimiter: string, chop: boolean?): string?
function InputOutputStream:write(data: string)
function InputOutputStream:wait(): ExitStatus
function InputOutputStream:close()
```

Native-only. `popen(command)` runs `command` through `/bin/sh -c` on Unix or
`cmd.exe /d /s /c` on Windows with a captured binary stdin pipe and one merged
binary stdout+stderr pipe. `command` rejects embedded NUL bytes. Use `os.spawn`
when passing arguments directly without a shell or keeping stdout and stderr
separate.

`InputOutputStream` satisfies all seven
[`io` Interfaces](standard-library-io.md#standard-implementations). `wait()`
reaps the child and caches `ExitStatus`. `close()` is idempotent: it closes
stdin, sends `"term"` to the shell process if running, waits for exit, and
closes the merged output stream. Drain output before `wait()` (or read and
write concurrently) when output may exceed one pipe buffer.

```titan
local os = import "os"
local strings = import "string"

function shell_output(command: string): (integer, string)
  local stream = os.popen(command)
  defer stream:close()

  local out = strings.writer()
  defer out:close()
  for chunk in stream:read do
    out:write(chunk)
  end
  local status = stream:wait()
  return status.code, out:drain()
end
```

## Errors

Native libuv failures raise `async.OperationError` with an `operation` name
identifying the failed call. `UV_ENOSYS` is surfaced directly rather than
falling back silently. Browser stream errors follow
[Browser parent streams](#browser-parent-streams).

## Transferring process streams

```text
function InputStream:to_transfer_payload(): string
function InputStream.from_transfer_payload(payload: string): InputStream
function InputStream.discard_transfer_payload(payload: string): integer

function OutputStream:to_transfer_payload(): string
function OutputStream.from_transfer_payload(payload: string): OutputStream
function OutputStream.discard_transfer_payload(payload: string): integer
```

`InputStream` and `OutputStream` support custom
[`TransferValue`](async-io.md#transfer-values) handoff across Lua states under
the [shared manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules):

- **Captured child pipes:** `to_transfer_payload()` synchronously detaches an
  idle captured pipe (preserving excess bytes, queued chunks, and EOF/error
  state) for adoption by another state's active, nonclosing Runtime. Pending
  reads (including Windows overlapped background reads), waiting readers, or
  accepted writes are rejected before detaching. After detachment, source reads
  return `nil` and source writes raise. The owning `Process` stays in the
  originating Runtime, which must stay alive to reap the child.
- **Parent `stdin`/`stdout`/`stderr` facades:** Unused facades copy their
  descriptor identity (leaving the source usable) and resolve a fresh owner in
  the destination Runtime. Started `os.stdin` reads and pending `os.stdout` /
  `os.stderr` writes or shutdowns are rejected (`kind()`, `is_tty()`, `close()`,
  and `with_parent_*` do not prevent transfer). A completed TCP `shutdown()`
  transfers, keeping the connection write-closed.
- **Disposing undelivered payloads:** `InputStream.discard_transfer_payload`
  and `OutputStream.discard_transfer_payload` close a detached captured pipe
  without needing a Task or active Runtime (returning the native close status,
  or `0` for parent descriptor identities or already-closed pipes). Match the
  exact stream type; each payload may be adopted or disposed of at most once.

## Transferring shell streams

```text
function InputOutputStream:to_transfer_payload(): string
function InputOutputStream.from_transfer_payload(payload: string): InputOutputStream
```

`InputOutputStream:to_transfer_payload()` transfers both idle communication
pipes (stdin and merged output) under the same platform rules as
[Transferring process streams](#transferring-process-streams). On Windows,
captured output starts an overlapped read immediately on `popen`, so live shell
pipes typically reject transfer with `EBUSY` while leaving the source intact.

Child-process ownership stays in the originating Runtime: the origin keeps
`wait()` and child termination on `close()`, while the destination owns only
the pipes (calling `wait()` on a transferred `InputOutputStream` raises
`"transferred InputOutputStream has no child process owner"` and `close()`
closes only its pipes). `InputOutputStream` has no `discard_transfer_payload`;
recover an undelivered payload by adopting it and closing the result.

## On the browser

The browser build exposes the following subset (absent members are omitted from
the module interface rather than raising stubs):

| Members | Browser availability |
| --- | --- |
| `Date`, `date`, `time`, `difftime`, `setlocale` | Available (`time()` reads the host wall clock). |
| `getenv`, `setenv`, `unsetenv` | Available in the instance's isolated environment. |
| `exit` | Available inside an async Task. |
| `InputStream`, `OutputStream`, `stdin`, `stdout`, `stderr` | Available as [Browser parent streams](#browser-parent-streams). |
| `clock` | Absent. |
| `cwd`, `chdir`, `homedir`, `tmpdir`, `hostname`, `exepath`, `pid`, `ppid` | Absent. |
| `spawn`, `popen`, `with_*`, `wait_signal` | Absent. |
| `ExitStatus`, `SpawnConfig`, `SpawnOption`, `Process`, `InputOutputStream` | Absent. |

- **Instance environment:** `create({ env })` seeds the instance's environment
  map (empty by default, including `HOME` and `USER`). Mutations affect only
  that instance.
- **Time zone and locale:** Local calendar conversion uses the JavaScript
  host's time zone; changing `TZ` modifies only the environment variable, while
  a leading `"!"` in `date` selects UTC. Under `wasi-libc` (musl), `setlocale`
  uses the C/UTF-8 locale.
- **Exit:** Inside an async Task, `exit` triggers graceful Runtime exit without
  terminating the JavaScript host; outside a Task it raises
  `"os.exit is unavailable outside an async Task on the browser target"`.

### Browser parent streams

On the browser, `os.stdin`, `os.stdout`, and `os.stderr` connect to the
loader's [embedding options](browser-target.md#the-loader-api). All operations
require an async Task except `close()`, which is an idempotent no-op.

- **Output (`stdout`, `stderr`):** Nonempty writes execute FIFO per stream and
  wait for the embedding sink (including a returned Promise), copying raw bytes
  without UTF-8 decoding. Empty writes act as cancellation checkpoints.
  Cancelling an admitted write waits for its sink to settle before delivering
  cancellation. Sink failures raise `async.OperationError` (`EIO`,
  `stdio.write`).
- **Kinds and TCP shutdown:** Embeddings may declare `stdinKind`, `stdoutKind`,
  or `stderrKind` as `"tty"`, `"pipe"`, `"file"`, or `"tcp"`. `kind()` returns
  that string (`is_tty()` is `true` only for `"tty"`); undeclared kinds make
  `is_tty()` return `false` and `kind()` raise `ENOSYS`. `shutdown()` succeeds
  only for an output declared `"tcp"`, ordering the embedding's end hook after
  accepted writes (subsequent writes raise `EPIPE`; other or undeclared kinds
  raise `ENOTSUP` with `stdio.shutdown`; failures raise `EIO`).
- **Input (`stdin`):** An embedding `stdin` function returns a byte chunk or
  Promise (`null`/`undefined` signals EOF; an empty chunk is valid data). At
  most one reader may wait; cancelling it detaches only that waiter. EOF and
  read errors stay sticky for the Runtime and reset on the next Runtime.
  Without a `stdin` source, `read()` and `read_until()` raise `ENOSYS`.
- **Unavailable errors:** Missing `stdin` or undeclared kinds raise
  `async.OperationError` with code `-ENOSYS`, name `"ENOSYS"`, and operation
  `"os.InputStream.read"`, `"os.InputStream.read_until"`,
  `"os.InputStream.kind"`, or `"os.OutputStream.kind"`.
- **Transfer and disposal:** Transfer payloads carry only the descriptor
  identity and enforce the same refusal rules (started `stdin` read, pending
  output write/shutdown). Explicit instance disposal delivers sticky
  `"instance disposed"` cancellation to waiting writers.
