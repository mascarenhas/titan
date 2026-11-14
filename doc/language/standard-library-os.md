# Operating-system standard library

The `os` standard module provides portable clocks, calendars, locales,
environment, path, process, graceful exit, one-shot signal, child-process, and
shell-command helpers. Its
synchronous CPU/current-time queries and resource-owning operations use public
libuv APIs on native targets; calendar conversion, formatting, differences,
and locale selection use ISO C where libuv has no equivalent. Titan imports
its canonical short name:

```titan
local os = import "os"
```

Lua loads the same canonical module identity with `require "titan.os"`. The
qualified Lua name is deliberate: `require "os"` remains Lua's standard
library table and is never replaced.

The native module currently supports Linux and macOS.

## On the browser

The browser module provides the following subset; omitted members have no
declaration, rather than a placeholder that raises:

| Members | Browser availability |
| --- | --- |
| `Date`, `date`, `time`, `difftime`, `setlocale` | Available; `time()` reads the host wall clock, not CPU time. |
| `getenv`, `setenv`, `unsetenv` | Available in the instance's own environment. |
| `exit` | Available inside an async Task. |
| `InputStream`, `OutputStream`, `stdin`, `stdout`, `stderr` | Available as [embedding-provided parent streams](#browser-parent-streams). |
| `clock` | Absent: wall time is not a substitute for CPU time. |
| `cwd`, `chdir`, `homedir`, `tmpdir`, `hostname`, `exepath`, `pid`, `ppid` | Absent. |
| `spawn`, `popen`, every `with_*` option, `wait_signal` | Absent. |
| `ExitStatus`, `SpawnConfig`, `SpawnOption`, `Process`, `InputOutputStream` | Absent. |

The loader's `create({env})` copies the supplied environment into the instance.
Without that option it starts empty, including `HOME` and `USER`; mutations
never change the JavaScript host's environment or another instance.
Local calendar conversion follows the JavaScript host's time zone. Setting
`TZ` changes an environment variable, not that time zone; a leading `!` in
`date` still selects UTC.

## Clocks and time differences

```text
function clock(): float
function difftime(later: integer, earlier: integer): float
```

`clock` sums the portable libuv user and system CPU-usage clocks and returns
seconds consumed by the program. It is not elapsed wall time. `difftime`
returns `later - earlier` in seconds using the host's ISO C calendar-time
representation. Titan timestamps are integer seconds on both targets.

## Calendar formatting and decomposition

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

function date(format: string?, timestamp: integer?): value
```

`date` follows Lua 5.5's mixed result shape. Its declared result is `value`,
but the actual result is restricted to two types: an ordinary `string` for a
format string, or a `Date` record when the effective format is `"*t"`. Titan
callers narrow the result explicitly:

```titan
local result = os.date("!*t", 0)
if result is os.Date then
  local epoch = result as os.Date
  -- epoch.year == 1970
end
```

The default format is `"%c"`, and an absent timestamp means the current time.
A leading `!` selects UTC and is removed before interpreting the remainder;
otherwise conversion uses local time. `"*t"` returns the calendar fields.
`wday` uses 1 for Sunday through 7 for Saturday, and `yday` starts at 1.
`isdst` is `nil` when the C library cannot determine daylight-saving status.
Unlike Lua's general-purpose table result, `Date` is a nominal fixed-shape
record; its public fields retain the ordinary record mutability rules.

Other formats use the C99 `strftime` conversion set accepted by Lua 5.5,
including the standard `E` and `O` modifiers. Invalid conversions raise before
entering C. The output buffer grows automatically, so callers do not choose a
capacity; a long repeated format is not truncated. Format strings are text and
reject an embedded NUL.

## Constructing timestamps

```text
function time(year: integer?, month: integer?, day: integer?,
              hour: integer?, min: integer?, sec: integer?,
              isdst: boolean?): integer
```

With no arguments, `time` returns the current timestamp. When any calendar
field is supplied, `year`, `month`, and `day` are required together. `hour`
defaults to 12 (noon), while `min` and `sec` default to zero; absent `isdst`
asks the C library to determine daylight-saving time. Fields may be outside
their ordinary ranges and are normalized by the host calendar, as in Lua:

```titan
local noon = os.time { year = 2026, month = 7, day = 31 }
local normalized = os.time {
  year = 2026, month = 2, day = 30,
  hour = 4, min = 5, sec = 6,
}
```

Named arguments replace Lua's date-table input. There is consequently no input
table to update with normalized fields; call `date("*t", timestamp)` when the
normalized fields are needed. A field outside the host C `int` representation,
or a timestamp the host cannot represent, raises an error.

## Locale

```text
function setlocale(locale: string?, category: string?): string?
```

The categories are `"all"` (the default), `"collate"`, `"ctype"`,
`"monetary"`, `"numeric"`, and `"time"`. With `locale == nil`, `setlocale`
queries the current selection. Otherwise it requests that locale and returns
the selected name, or `nil` when the C library cannot satisfy the request.
`""` asks for the implementation-defined native locale and `"C"` selects the
portable C locale. Locale and category strings reject embedded NUL; unknown
categories raise.

On the browser, emsdk 6.0.13's musl accepts valid unknown locale names and
reports them as selected while using C.UTF-8 locale data; selecting an
unknown name therefore need not return nil or change calendar formatting.

Locale selection is process-global and the ISO C calendar/locale functions
used here have process-global or static storage. They are not safe to race from
multiple operating-system threads. Titan's v1 async callbacks execute serially
on one loop thread; embedding hosts must provide the same exclusion.

## Environment

```text
function getenv(name: string): string?
function setenv(name: string, contents: string)
function unsetenv(name: string)
```

`getenv` returns `nil` when the variable is absent and preserves an existing
empty value as `""`. `setenv` creates or replaces a variable. `unsetenv` is
successful even when the variable is already absent.

Names and values are text. An embedded NUL is rejected before accessing the
environment. On native targets these operations change process-global state
and are not thread-safe; an embedding host must avoid racing them from another
operating-system thread. On the browser they affect only the instance's
environment, as described [above](#on-the-browser).

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

`cwd` returns the current working directory and `chdir` changes it for the
whole process. `homedir` and `tmpdir` follow libuv's platform rules, including
their documented environment-variable precedence. `hostname` returns the host
name. `pid` and `ppid` return the current and parent process identifiers.

`exepath` returns the current executable path only inside a compiled Titan
program. Libuv requires the process's original `argc` and `argv` to be passed
through `uv_setup_args` before `uv_exepath`; Titan's generated executable
entrypoint performs that handoff when it loads `titan.uv`. A Lua or other
embedding host does not provide that entrypoint contract, so calling
`exepath` there raises `os.exepath is only available in a compiled Titan
program`.

Paths are text and reject embedded NUL. Buffer-sized results retry with the
capacity reported by libuv, so callers do not need to choose one. On Linux and
macOS, `exepath` also adapts libuv's saturated-success truncation convention
into the same automatic retry behavior.

## Waiting for a signal

```text
function wait_signal(name: string): string
```

`wait_signal` is an asynchronous cancellation point and must run inside an
async Task. It installs a one-shot watcher and returns the canonical lowercase
name when the signal fires. Supported names on Linux and macOS are `"hup"`,
`"int"`, `"quit"`, `"term"`, `"usr1"`, and `"usr2"`.

Windows does not provide `"usr1"` or `"usr2"`; Titan rejects both before
initializing a watcher. The remaining native signal constants do not imply
Unix delivery semantics on Windows. Watcher registration is delegated to
libuv, and a native registration error is reported as `signal.start`.

Unknown names are rejected before a watcher is initialized. `"kill"` is also
rejected because it cannot be caught. Cancellation stops the watcher and
drains its close callback; a late signal cannot resume the Task a second time.
Signals are notifications rather than a queued history, so repeated standard
signals may coalesce. While a watcher is active, libuv owns that process signal
disposition; embedding code should not install a competing handler for it.

## Graceful program exit

```text
function exit(code: integer?)
```

`exit` requests successful shutdown of the complete async Runtime. An absent
code means zero. The call may come from the main Task or a child Task; it exits
the program rather than merely returning from or cancelling that Task.
The first request fixes the program status. Its caller receives the same
sticky Task cancellation used for Runtime shutdown: a `catch` may run
synchronous cleanup, but it does not clear the exit request, and the
cancellation is injected again before that Task can submit another
asynchronous operation. A later `exit` call cannot replace the first code.

The request settles the other Tasks, runs their `defer` cleanup,
drains accepted callbacks and requests, closes the loop's handles, and then
closes the event loop. File descriptors are closed only by application cleanup
such as `defer file:close()`; the Runtime does not register or close them.
Closing a process watcher does not signal, wait for, or reap its child, so a
child may outlive this Runtime transition. Code that owns the child's
lifecycle must explicitly kill and/or wait for it during application cleanup.
The generated standalone entrypoint then returns the requested status through
its normal exit path. This is a distinct successful Runtime transition, not a
fatal error and not a direct call to ISO C `exit`.

`os.exit` does not accept Lua's boolean status or `close` flag. A Titan module
loaded by Lua or another embedding does not own the host Lua state and never
closes it; the embedding remains responsible for that state after Titan's
Runtime has finished.

On the browser, calling `exit` outside an async Task raises the string
`os.exit is unavailable outside an async Task on the browser target` and
leaves the instance usable. Inside a Task it uses the same graceful Runtime
exit request described above; it does not terminate the JavaScript host.

## Child processes

```text
record ExitStatus
  code: integer
  signal: string?
  signal_number: integer
end

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

function spawn(file: string, args: {string},
               ...: SpawnOption): Process
function Process:wait(): ExitStatus
function Process:kill(signal: string)
function Process:is_running(): boolean
function InputStream:read(): string?
function InputStream:read_until(delimiter: string,
                                chop: boolean?): string?
function InputStream:close()
function InputStream:is_tty(): boolean
function InputStream:kind(): string
function OutputStream:write(data: string)
function OutputStream:shutdown()
function OutputStream:close()
function OutputStream:is_tty(): boolean
function OutputStream:kind(): string
```

On native targets, spawning, stream I/O, parent-stdio access, signalling, and
waiting must run inside an async Task. `is_running`, `is_tty`, and `kind` do not
yield, but still validate the exact Runtime that owns the resource. A Titan
standalone program that imports `os` gets the automatic async bootstrap; a Lua
host should call these APIs from a function passed to `async.run`, then drive
that Task with `async.loop` after loading `require "titan.async"`.

`InputStream` and `OutputStream` are ordinary records with private fields.
They represent process standard streams only: the Titan process's own stdio
and the parent-facing endpoints of captured child stdio. They are not general
`fs.File` or `net.Connection` handles. One private `Stdio` owner backs each
stream. `kind()` returns its descriptor kind: `"tty"` for a terminal, `"pipe"`
for a pipe or Unix-domain stream socket, `"file"` for a file-backed parent
descriptor, or `"tcp"` for a connected TCP socket on a parent descriptor
(Linux and macOS). `is_tty()` is true
exactly when `kind()` is `"tty"`. Neither yields. Both require a running Task,
raising `async Runtime is not active` when no Runtime is active and
`asynchronous operation must be called from an async Task` when called outside a
Task. On a live captured endpoint owned by another Runtime they raise `stdio
stream belongs to a different async Runtime`. On a captured endpoint that was
closed or transferred they raise `InputStream is closed` / `OutputStream is
closed`. On a parent stream they classify descriptor 0, 1, or 2 on first use in
the Runtime. A parent descriptor of an unsupported kind raises the
`stdio.parent.kind` `async.OperationError` described below, and an invalid
descriptor raises its `EBADF` error.
An open captured child endpoint is always a pipe: `kind() == "pipe"`,
`is_tty() == false`, including after EOF.

### Spawn configuration

`spawn` starts `file` directly, without a shell. `args` contains the arguments
after `argv[0]`; the library supplies `file` as `argv[0]`. The child inherits
the current environment and working directory. File and argument strings are
text and reject embedded NUL before `uv_spawn`; the originals remain rooted
while that synchronous call borrows them.

With no options, all three child descriptors are captured. `spawn` constructs
one opaque `SpawnConfig` containing the actual libuv process options and stdio
array, installs those three defaults, then calls every supplied `SpawnOption`
from left to right. Each configurator immediately prepares the stream handles
and writes the corresponding stdio entry. It returns a libuv-style status, so
`spawn` stops at the first negative result, cleans up every stream still owned
by the configuration, and raises the corresponding error without calling later
options.

If native child creation succeeds but `spawn` then fails before returning its
`Process`, the configuration still owns that child. Rollback closes captured
streams, sends SIGTERM, and sends SIGKILL after 30 seconds if the child is still
running. It waits for the actual child exit and native handle close before
rethrowing the original error with its original traceback. Pending Task
cancellation does not interrupt this cleanup. A child that exits earlier
cancels escalation. The 30 seconds is a grace period, not an unconditional
cleanup deadline: if signaling cannot terminate the child, cleanup continues
to wait for its real exit. Successfully returned Processes retain their normal
explicit `kill` and `wait` behavior.

`with_stdin`, `with_stdout`, and `with_stderr` select a captured
parent-facing pipe. The corresponding `with_parent_*` function selects direct
inheritance of the current parent stream. Later options replace conflicting
earlier entries immediately, retiring any unsubmitted stream handles that are
no longer referenced. This includes a later choice that breaks an earlier
merge; repeating an option has the same observable result. Callers may compose
the supplied functions in their own integer-returning `SpawnOption` closures,
but cannot construct or inspect a `SpawnConfig` directly.

`with_env(name, contents)` returns an option that overrides one variable only
in the child. All other variables are inherited at spawn time; the parent
environment is unchanged. Later options for the same name win. Names compare
exactly on Unix and with ordinal case-insensitive Unicode comparison on Windows.
An empty value is retained as an empty value, not removed. Empty names, names
containing `=` or NUL, and values containing NUL fail during spawn configuration.
For example, `spawn(compiler, args, with_env("LANG", "C"),
with_env("LC_ALL", "C"))` controls compiler diagnostics without changing the
parent or requiring an environment-wrapper executable.

`with_merged_output` creates one pipe, wraps both ends as libuv streams, and
installs the child end into both stdout and stderr stdio entries with
`UV_INHERIT_STREAM`. The resulting nonnil `process.stdout` and
`process.stderr` fields contain the exact same parent `InputStream` value, not
two facades over one native handle. They consequently share buffered excess,
the low-level stream's one waiter, and native ownership.

Each public Process endpoint is optional. A captured descriptor has a
parent-side endpoint; an inherited descriptor does not, so its corresponding
field is `nil`. Stream names describe the Titan caller's direction:
`process.stdin`, when present, is an `OutputStream` because Titan writes to the
child, while captured `process.stdout` and `process.stderr` are `InputStream`
values because Titan reads from them. Pipe payloads are binary strings and
preserve embedded NUL.

For example, this inherits stdin and captures stdout and stderr separately;
the unmarked locals force the captured endpoint options where they are
required:

```titan
local process = os.spawn(
  "/usr/bin/tool", {"--version"}, os.with_parent_stdin)
local stdout = process.stdout
local stderr = process.stderr
```

### Parent standard streams

On native targets, the module exports three mutable stream variables:

- `os.stdin: InputStream` reads the parent process's descriptor 0;
- `os.stdout: OutputStream` writes descriptor 1; and
- `os.stderr: OutputStream` writes descriptor 2.

These are stable high-level records with lazily initialized owners for the
current Runtime. Parent input retains its read owner throughout that Runtime,
including queued bytes, delimiter excess, and sticky EOF or read error state.
A retained stream rebinds after one `async.run`/`async.loop` session ends and
another begins, without returning buffered input or terminal state from the
previous Runtime.

Parent standard streams support four descriptor backings:

- `"tty"` (`UV_TTY`): backed by a Runtime-owned `uv_tty_t` over a duplicate of
  the parent descriptor;
- `"pipe"` (`UV_NAMED_PIPE`, or a hinted Unix stream socket): backed by a
  Runtime-owned `uv_pipe_t` over a duplicate of the parent descriptor;
- `"file"` (`UV_FILE`, including regular files, `/dev/null` and other non-TTY
  character devices on Unix, and disk files and `NUL` on Windows): backed by
  libuv thread-pool filesystem requests (`uv_fs_read` and `uv_fs_write` at
  offset `-1`) over the borrowed parent descriptor `0`, `1`, or `2`. A
  file-backed read or write runs on a libuv worker thread and cannot be
  interrupted. A descriptor that blocks, such as a character device with no
  data, keeps that request, and therefore Runtime shutdown or Lua-state close,
  waiting until the operating system completes it; and
- `"tcp"` (`UV_TCP`, Linux and macOS only): a connected IPv4 or IPv6 TCP
  socket, backed by a Runtime-owned `uv_tcp_t` that adopts a close-on-exec
  duplicate of the parent descriptor with `uv_tcp_open`. See
  [TCP-backed parent streams](#tcp-backed-parent-streams).

Open captured child endpoints are always pipes and report `kind() == "pipe"` and
`is_tty() == false`; after `close()` or transfer detachment they raise as
described above. A parent descriptor of any other kind is rejected before I/O.
Rejected kinds include a UDP or other datagram socket, a listening or
unconnected TCP socket, and any socket on Windows. The error is an
`async.OperationError` with `operation == "stdio.parent.kind"` and
`name == "ENOTSUP"`, and its message names the descriptor and the unsupported
kind or state.

A sandboxed launcher may supply parent streams through Unix stream sockets
while denying the socket metadata calls that libuv uses to recognize them.
Such a launcher can set `TITAN_STDIO_PIPE_FDS=0,1,2` before starting Titan,
listing only the parent descriptors it knows are pipe-compatible Unix stream
sockets. Each token must be exactly `0`, `1`, or `2`, separated by commas;
whitespace, empty tokens, and any other character invalidate the entire hint.
Omitting the variable or setting it to an empty string supplies no hint.

The hint applies only when libuv reports an unknown kind, `fstat` identifies a
socket, and socket family or type inspection fails with `EPERM` or `EACCES`.
Titan still performs both inspections: any observed family other than
`AF_UNIX` or type other than `SOCK_STREAM` rejects the stream. Descriptors that
libuv classifies, including TCP sockets, never consult the hint, and it never
turns a TCP or datagram socket into a pipe. When both socket probes are
denied, Titan trusts the launcher's assertion about the hidden family and
type; the hint does not validate that unavailable metadata. An unsupported
kind or failed inspection raises `async.OperationError` with operation
`stdio.parent.kind` and a message naming the descriptor and probe. An invalid
descriptor retains its actual `EBADF` error.

On experimental Windows builds, known libuv pipe, console, and `UV_FILE`
(disk file and `NUL`) kinds use the same Runtime-owned `Stdio` owners.
Socket-backed parent stdio is not supported on Windows, although a custom
launcher can pass a socket as a standard handle. Windows reports sockets as
pipes, so before accepting a pipe or classifying an unknown handle Titan asks
Winsock whether the descriptor's handle is a socket. This query reads no data.
Any socket is rejected before a handle is duplicated or adopted. That includes
connected, listening, or unconnected TCP (overlapped or not) and UDP. The
error is `stdio.parent.kind` with name `ENOTSUP` and a message stating that
socket-backed parent stdio is not supported on Windows. A handle that is not
a socket keeps its usual classification. Any other Winsock failure raises
`stdio.parent.kind` with that error. A socket-to-pipe relay can connect a
Windows program's ordinary stdio to a network service. An unknown
non-socket handle also fails explicitly; the Unix socket-metadata fallback and
`TITAN_STDIO_PIPE_FDS` hint do not apply. Pipe and console wrappers own a
non-inheritable duplicate of the actual Windows handle, leaving the original
parent stream open when the Runtime ends. File-backed parent streams read and
write bytes unchanged on Windows (no CRT text-mode newline translation) and
pass descriptor `0`, `1`, or `2` directly to the child on inheritance.

The Runtime caches each usable initialized parent owner. The launcher must
update or clear `TITAN_STDIO_PIPE_FDS` when replacing inherited descriptors;
changing the variable while a cached owner remains usable does not reclassify
it.

The raw parent descriptors remain owned by the host process. A TTY, pipe, or
TCP parent owner uses a close-on-exec duplicate, whose teardown cannot close
the original descriptor. On Unix the duplicate shares the original's open file
description and, for a socket, its connection state. Adopting it makes that
description nonblocking for every alias. A file-backed parent owner borrows
descriptor `0`, `1`, or `2` directly without duplicating or closing it: the
host must keep that descriptor open and unreplaced while the Runtime's cached
owner and accepted requests use it, and rebinding descriptor `0`, `1`, or `2`
mid-Runtime is not supported. A `with_parent_*` configurator obtains a usable
cached owner, creating a replacement if an earlier stream duplicate retired.
TTY, pipe, and TCP owners bind `UV_INHERIT_STREAM`, so the child receives the
same open file description. File-backed owners bind `UV_INHERIT_FD` with CRT
descriptor `0`, `1`, or `2`, passing the raw descriptor on Unix and
duplicating the underlying `HANDLE` for the child on Windows. Several children
may inherit the same parent stream. On Unix, libuv clears `O_NONBLOCK` on each
standard descriptor it passes to a child. The description is shared, so later
parent I/O on an inherited TTY, pipe, or TCP stream can block the event loop.

Reading on parent `os.stdin` starts lazily when `read` or `read_until` is
called. Calling `kind()`, `is_tty()`, `close()`, or `with_parent_stdin` never
creates read state or consumes bytes intended for a child. Once parent reading
has started, bytes already read into Titan's buffers are not available to a
subsequently spawned inheriting child.

Closing any of the three stable parent stream facades is an idempotent no-op.
It closes neither a Runtime-owned duplicate nor a borrowed file descriptor,
does not send a TCP FIN, and does not change later operations on the facade.
Native EOF or a read error may retire a stream duplicate earlier; the same
Runtime's input facade and subscription still retain buffered bytes and sticky
terminal state. Runtime cleanup retires remaining native stream handles. This
is distinct from closing a captured child endpoint.

`InputStream` satisfies the standard `io.Reader`, `io.Closer`, and
`io.ReaderCloser` Interfaces exactly.
`OutputStream` satisfies `io.Writer`, `io.Closer`, and `io.WriterCloser`
exactly. These are structural conversions at typed use sites; neither the
records' private ownership metadata nor the low-level handle union is part of
any Interface.

### Browser parent streams

On the browser, the same `stdin`, `stdout`, and `stderr` records use the
loader's [embedding options](browser-target.md#the-loader-api), not host file
descriptors. All operations below require an async Task except `close()`,
which remains an idempotent no-op and never closes a sink or sends an end.
Their `io` Interface conversions have the same signatures as on native targets.

Each nonempty `stdout:write(bytes)` or `stderr:write(bytes)` is one FIFO entry
on that stream. It returns only after the embedding's sink has completed,
including a returned promise. Bytes are copied without UTF-8 decoding, so NUL
and `0xff` pass unchanged. An empty write is a cancellation checkpoint with no
host request. There is no ordering guarantee between stdout and stderr.
Cancelling an admitted write waits for its sink to settle before delivering
the cancellation; it does not retract accepted output. A sink failure raises
`async.OperationError` with name `EIO`, operation `stdio.write`, and the host
diagnostic when available.

The embedding can declare `stdinKind`, `stdoutKind`, and `stderrKind` as
`"tty"`, `"pipe"`, `"file"`, or `"tcp"`. `kind()` returns that declaration,
and `is_tty()` is true exactly for `"tty"`. Without a declaration,
`is_tty()` is false and `kind()` raises the unavailable error below.
An invalid declaration raises a plain error naming the option; no kind is
invented from the sink or source.

`shutdown()` is supported only for an output declared `"tcp"`. It orders the
embedding's end hook after accepted writes and waits for it just like a write.
Once shutdown is accepted, later shutdown calls return at once and every
write, including an empty write, raises `stdio.write` with name `EPIPE`.
A shutdown failure raises `EIO` with operation `stdio.shutdown`.
For every other or undeclared kind, shutdown raises `ENOTSUP` with operation
`stdio.shutdown` and changes nothing.

The optional `stdin` function supplies a byte chunk or a promise of one;
`null` or `undefined` means EOF, and an empty byte chunk is still data.
There can be one waiting reader. Cancelling it detaches only that waiter:
the stream keeps the request and retains its result for a successor.
EOF and read errors remain sticky for the Runtime. Ending the Runtime
clears them, buffered chunks, and delimiter excess before a later Runtime.
Without a `stdin` source, `read()` and `read_until()` raise, never return EOF.

Missing input and undeclared kinds raise `async.OperationError` with code
`-ENOSYS`, name `ENOSYS`, message
`<member> is unavailable on the browser target`, and operation `<member>`.
The member is `os.InputStream.read`, `os.InputStream.read_until`,
`os.InputStream.kind`, or `os.OutputStream.kind`, respectively.

Explicit instance disposal is not graceful Runtime exit: the SDK retires queued
and in-flight output requests with `TITAN_BROWSER_DISPOSED`, while waiting
Tasks and their cleanup writes receive the sticky `"instance disposed"`
cancellation. Already called sinks cannot be recalled. See the
[loader's output contract](browser-target.md#the-loader-api) for interruption
and finalizer-output rules.

### TCP-backed parent streams

On Linux and macOS, descriptor 0, 1, or 2 may be a connected TCP socket.
Launchers that supply one include inetd, systemd socket units with `Accept=yes`
and `StandardInput=socket`, and launchd `inetdCompatibility` with
`Wait=false`. A `"tcp"` stream supports the same `read`,
`read_until`, and `write` operations as the other stream kinds. It also keeps
their buffering, single-reader rule, write ordering, cancellation, and sticky
EOF or error. TCP chunks are not messages. After any retained bytes, a peer
write-half shutdown reads as EOF. A reset or other native failure raises a
`stdio.read` or `stdio.write` `async.OperationError`, never a synthetic EOF.

Only a connected socket that libuv identifies as IPv4 or IPv6 TCP is accepted.
A listening socket is rejected with the probe text `listening TCP socket`, and
a socket without a peer with `unconnected TCP socket`. Activation that hands
the program a listener, such as systemd `Accept=no` (`LISTEN_FDS`) or launchd
`Wait=true`, is not stdio support. Classification happens when a Runtime first
uses the stream or prepares it for inheritance. A connection that the
operating system no longer reports as connected at that point, for example
after a peer reset, is therefore also rejected as unconnected. An unexpected
inspection failure, such as a denied `getpeername`, raises
`stdio.parent.kind` with that native error. `TITAN_STDIO_PIPE_FDS` is never a
TCP hint.

`OutputStream:shutdown()` ends TCP output while input stays readable:

- It waits for every write already accepted on that output stream, then
  half-closes the socket's write side (`uv_shutdown`, then `SHUT_WR`). The
  peer reads those bytes followed by EOF. A Task cancelled before admission
  submits nothing. An accepted shutdown completes even if its Task is
  cancelled; that Task then raises its cancellation. A native failure raises
  `async.OperationError` with operation `stdio.shutdown`.
- Once a shutdown has been accepted, every later write through that output
  stream raises `stdio.write` with name `EPIPE`, including an empty write.
  Later `shutdown()` calls on it return at once. They neither wait for a
  pending shutdown nor report its result, which goes only to its own caller.
- On a `"tty"`, `"pipe"`, or `"file"` stream, including captured
  `process.stdin`, `shutdown()` raises `async.OperationError` with operation
  `stdio.shutdown` and name `ENOTSUP` and leaves the stream unchanged.
  Closing a captured `process.stdin` remains the way to send EOF to a child.

**Shutdown acts on the connection, not on one descriptor.** `os.stdout`,
`os.stderr`, the raw descriptors, and descriptors inherited by children may
all refer to the same connection, as they usually do under these launchers.
Shutting down any of them ends output for all. Writes through the
other aliases then fail with a native error such as `EPIPE`, whose exact code
can differ. Their owners are not notified: each still submits its own
`shutdown()` and reports what the operating system returns.

Parent `close()` never sends FIN. When a Runtime ends, closing its owned
duplicates does not deliver EOF to the peer while the raw descriptors, another
state, or a child still holds the connection. Use `shutdown()` to end output
explicitly.

A child that inherits a TCP-backed stream shares the connection. With
`os.stdin`, parent and child read the same byte stream, so whichever reads
first consumes the bytes. A child's `shutdown()` ends output for the parent
too. Transfers keep the descriptor-identity rule of
[transferring process streams](#transferring-process-streams), and a receiving
state adopts a fresh owner of the same connection. Concurrent use from several
states or processes is not serialized.

### Process stream I/O

Each nonempty write to a TTY, pipe, or TCP stream (including captured
`process.stdin`) immediately submits its own `uv_write_t` and returns only
after that request's callback. Libuv supplies stream write ordering; Titan adds
no operation queue for streams. An empty write submits nothing. Once the stream
is no longer writable, as after an accepted TCP `shutdown()`, every write,
empty or not, raises `stdio.write` with name `EPIPE`. The request retains the
original immutable string until its eventual callback while libuv borrows, but
does not mutate, its bytes. Overlapping calls retain independent requests and
strings. Cancelling the Task does not release that owner early or kill the
child.

Writes to a file-backed parent stream (`os.stdout` or `os.stderr` when
descriptor `1` or `2` is `UV_FILE`) use libuv thread-pool `uv_fs_write`
requests with offset `-1` so the loop thread never blocks on synchronous file
I/O. On Unix, `>>` opens the descriptor with `O_APPEND`, so every write
appends. On Windows, each write goes to the inherited handle's current file
position; `cmd` `>>` places that position at end of file before the program
starts, so output follows the existing bytes. Titan adds no append semantics of
its own: concurrent writers to the same file are ordered only by the operating
system. File-backed writes obey the following rules:

- **Admission and FIFO ordering.** A write is admitted only inside the
  `async.await_with` registration callback after the cancellation check; a Task
  cancelled before registration writes nothing, and an empty write is a checked
  no-op. Per stream, at most one `uv_fs_write` is in flight, and accepted
  writes execute in acceptance order. A callback-driven pump—not the calling
  Task—owns submission, short-write continuation over `uv.buf_t` slices, and
  advancement to the next queued entry before settling the completed entry, so
  a resumed writer cannot overtake older queued writes.
- **Completion and errors.** Each logical write settles once: success after all
  bytes are written, or `async.OperationError` with operation `stdio.write` and
  the native error code (`ENOSPC`, `EFBIG`, `EBADF`, and so on, or `EIO` if a
  nonempty write reports zero bytes) after any prefix already written. An
  errored entry retires and later queued entries still run.
- **Cancellation and teardown.** A Task cancelled after its write is accepted
  remains waiting until the entire logical write settles, and then receives its
  cancellation reason; written bytes are never rolled back. Graceful Runtime
  shutdown (`os.exit`/`async.request_exit`, or a fatal Runtime failure) refuses
  new writes but completes every already accepted write, in order, before the
  loop closes. If the Lua state instead closes while its Runtime is still active
  (see [closing a Lua state with an active Runtime](async-io.md#closing-a-lua-state-with-an-active-runtime)),
  there is no full-write guarantee. Only the write already submitted to the
  operating system finishes. Queued writes and unwritten remainders are dropped,
  so the file may end with a prefix of the accepted output. Waiting Tasks do not
  resume. Descriptors 0, 1, and 2 stay open.

On Unix, loading `titan.async` changes a default `SIGPIPE` disposition to ignored
so a child that closes stdin produces the ordinary libuv write error instead
of terminating the parent process. An already ignored signal or an
application-installed handler is preserved.
Windows has no `SIGPIPE` disposition; this initialization step does nothing
on Windows.

Closing a captured `process.stdin` is idempotent. Its first call marks the
stream terminal and submits the physical pipe's `uv_close`; later writes are
rejected, and any independently submitted write still receives its own libuv
callback. Closing the write-end pipe is what delivers EOF to the child;
`shutdown()` is not supported on pipes. Programs whose child waits for input
EOF must call `close()`.

Successful spawn initialization starts continuous reads on each captured
output pipe. Each pipe retains GC-owned chunks even when no Task is waiting,
with no maximum or high-water mark. This keeps draining the operating-system
pipes but means an undrained child can make application memory use grow. If a
read watcher unexpectedly cannot start, that stream closes with a stored error
which its first read reports; the successfully spawned Process remains usable
and waitable. The low-level module does not turn this setup failure into a
child-termination policy.

File-backed parent `os.stdin` uses the same single-reader subscription queue and
facade delimiter excess as stream-backed input, but pairs it with a
demand-driven `uv_fs_read` producer (64 KiB chunk buffer at offset `-1`)
instead of continuous read-ahead: at most one `uv_fs_read` is in flight, and an
admitted read call (after `async.checkpoint()` and the competing-reader check)
submits a request only when none is in flight and no buffered chunk or terminal
outcome is pending.

An `InputStream:read()` returns that stream's oldest facade excess first.
Otherwise it returns one oldest buffered native chunk, or waits for the next
positive callback. A positive chunk is nonempty, binary, and timing-dependent.
EOF returns `nil` permanently for the current Runtime, and a read error raises
its stored `async.OperationError` (`stdio.read` or `stdio.read.start`)
permanently for the current Runtime after any earlier queued chunks have
drained; file-backed `os.stdin` does not tail a growing file within the same
Runtime, while a later Runtime starts with fresh read state.

`InputStream:read_until(delimiter, chop)` rejects an empty delimiter and
consumes through its first occurrence. With `chop` absent or false, an actual
delimiter is included; with `chop == true`, it is omitted. A chopped delimiter
at the start returns `""`, not EOF. Bytes after the delimiter remain retained
for the next call.

EOF after a nonempty unterminated tail returns that tail unchanged and becomes
`nil` on later calls. A terminal tail never has a delimiter invented. Errors
and cancellation propagate normally; delimiter reading is composition over
several low-level reads and does not roll already consumed bytes back into the
stream.

Separately captured stdout and stderr have independent low-level waiters, so
the two pipes can be drained concurrently. Merged output has one stream and
therefore one waiter. A second Task that tries to wait on the same stream is
rejected; there is no additional facade lock or read queue. Cancelling a
waiting read detaches only its waiter, wakes that Task on a later loop turn,
and leaves the physical read active for another Task.

For file-backed `os.stdin`, cancelling a waiting reader likewise detaches only
that waiter; a replacement reader may wait immediately, and the in-flight chunk,
EOF, or read error is retained in the subscription and delivered once to the
next reader. Because `read_until` retains bytes beyond the delimiter in facade
excess from the 64 KiB read chunk, a child spawned with `with_parent_stdin`
observes the operating-system descriptor offset after the chunk read rather
than the logical delimiter offset. Concurrent I/O across parent and child
processes, independent Lua states, or aliased stdout/stderr descriptors has no
cross-owner serialization guarantee.

Closing a captured `InputStream` is idempotent. It stops and closes that
parent-side read pipe, discards facade excess and buffered native input, wakes
a blocked low-level reader with `nil` on a later loop turn, and makes later
`read` and `read_until` calls return `nil`. It does not terminate or reap the
child; closing the read end can instead make a child that continues writing
observe its ordinary broken-pipe behavior. Closing parent `os.stdin` remains
the no-op described above.

Every captured process stream belongs to the exact libuv Runtime that spawned
its child. Runtime cleanup closes its native handle through `uv_walk`. A
retained facade is not rebound for native I/O through a later replacement
Runtime. An `InputStream` already closed at the facade remains terminal: reads
return `nil` and repeated `close()` calls are no-ops without touching native
state. The default parent stdio records have the separate rebinding behavior
described above.

### Transferring process streams

`InputStream` and `OutputStream` implement `to_transfer_payload(): string` and
`from_transfer_payload(payload: string)` for the custom
[`TransferValue`](async-io.md#transfer-values) protocol. An idle captured pipe
can move to another state's active async Runtime. Encoding detaches the source
stream immediately; the receiving wrapper owns a fresh UV handle on its own
loop. Subsequent source input reads return nil, source output writes fail as
closed, and closing the source wrapper cannot close the destination pipe.
Handoff hooks are synchronous and require an active, nonclosing Runtime;
they can run between Tasks or from callbacks without a current Task. If
serializing the enclosing value fails after native detachment, the hook closes
the detached endpoint and leaves the source facade detached.

Input handoff preserves the facade's excess bytes, queued binary chunks, and
EOF or error outcome. A stream whose native pipe has already ended can still
transfer its remaining bytes and terminal outcome. A waiting reader, accepted
write, or pending native read is rejected before changing the source. In
particular, Windows background reads may remain pending after a watcher is
stopped and cannot be handed off in that state.

Unused `os.stdin`, `os.stdout`, and `os.stderr` facades copy their process-wide
descriptor identity and resolve a fresh Runtime-local wrapper when used. These
stable facades remain usable at the source. Two kinds of facade are rejected:
standard input that this Runtime has started reading, even if it has since
reached EOF or failed, and standard output or error with an accepted write or
shutdown still pending. Untouched facades of any kind (`"tty"`, `"pipe"`,
`"file"`, or `"tcp"`) transfer; `kind()`, `is_tty()`, `close()`, and
`with_parent_*` do not count as use. A completed TCP `shutdown()` leaves
nothing pending, so that facade transfers too. The connection's write side
stays shut down, however, and writes in the receiving state fail with the
native error. Captured child endpoints are always pipes; a TCP-backed stream
never hands off its native handle.

The `Process` itself remains in the originating Runtime, which must stay alive
to observe and reap the child. Its `wait`, `kill`, and exit handling continue
there while the destination reads or writes the transferred communication
pipes. Merged stdout/stderr fields already share one `InputStream`; transferring
that wrapper detaches both source aliases.

The payload follows the
[shared manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules).
Copies do not create additional owners, and dropping the bytes does not close
resources. To recover a payload that was not delivered, adopt it and close the
stream, or dispose of it without adopting it:

```text
function InputStream.discard_transfer_payload(payload: string): integer
function OutputStream.discard_transfer_payload(payload: string): integer
```

Each static accepts only an unadopted payload produced by the same type's
`to_transfer_payload`. It closes the payload's detached captured pipe, if any,
and returns the native close status. It runs in any live Lua state with the
`os` module loaded, needs no current Task or active Runtime, and still works
after Runtime shutdown has stopped adoption. It does not touch the
originating `Process`, which keeps its `wait` and `kill` obligations.

A payload copied from an unused `os.stdin`, `os.stdout`, or `os.stderr` facade
carries only the descriptor identity: disposing it returns `0` and never
resolves, opens, or closes the parent stream, whatever its `kind()`. A captured
payload whose pipe had already closed also returns `0` without a native close.

Disposal applies the same schema, terminal-outcome, and descriptor validation
as adoption and raises before any native close when they fail. Passing an
`InputStream` payload to `OutputStream.discard_transfer_payload`, or the
reverse, is not detected reliably and is a caller error. Once a native close is
attempted the capability is consumed even if the status is negative: clear any
retained copy before reporting that status, and never retry, adopt, or dispose
of the same bytes again.

These statics are explicit manual cleanup. Native packet disposal such as
`transfer.discard_message` never calls them, so a lossy or coalescing transport
still must not carry these payloads.

### Process lifecycle

`wait` returns after the operating system has reaped the child. Only one Task
may wait at a time; cancelling it does not kill the child, and a replacement
Task may wait. The cancelled Task is resumed on a later loop turn rather than
synchronously by the cancelling Task. Exit status is retained, so later
sequential waits return a fresh `ExitStatus` immediately.
On normal exit, `signal` is `nil` and `signal_number` is zero. Signal
termination preserves its native number and uses a canonical lowercase name
when it belongs to the documented common subset; an unknown signal has
`signal == nil` but keeps its number.

For a child that may produce output, drain stdout and stderr concurrently with
stdin and `wait`; waiting first can deadlock when an operating-system pipe
buffer fills.

`kill` accepts `"hup"`, `"int"`, `"quit"`, `"term"`, `"usr1"`, `"usr2"`,
and `"kill"` on Linux and macOS. Windows rejects `"usr1"` and `"usr2"`;
other recognized names are passed to libuv, whose native semantics and errors
apply. Recognizing a name does not guarantee Unix signal delivery. Unknown
names are rejected before libuv is called. Killing an
already exited Process is a lifecycle error, so a recycled process identifier
can never be targeted through an old wrapper.

`is_running` is a side-effect-free observation of the retained process state.
It becomes false once the exit callback has reported termination, but it does
not reap the child and does not replace `wait`. Code that conditionally signals
a Process can use it immediately before `kill`; neither operation yields
between the observation and signal request.

After the Runtime's Tasks have retired, the async driver discovers remaining
public process handles through `uv.walk` and closes them like other handles.
If a child is still alive at that point, closing its watcher does not own the
child's lifecycle. `uv_close` retires the watcher but does not signal, wait for, or reap
the child; the child may outlive the Runtime. Programs that require termination
or reaping must explicitly call `kill` and `wait` while that Runtime is active.

### Shell commands

```text
record InputOutputStream

function InputOutputStream:read(): string?
function InputOutputStream:read_until(delimiter: string,
                                      chop: boolean?): string?
function InputOutputStream:write(data: string)
function InputOutputStream:close()
function InputOutputStream:wait(): ExitStatus
function InputOutputStream:to_transfer_payload(): string
function InputOutputStream.from_transfer_payload(payload: string): InputOutputStream

function popen(command: string): InputOutputStream
```

`popen` is the standard library's shell-string convenience. On Linux and
macOS it invokes `/bin/sh -c command`. On Windows it selects `cmd.exe` from the
Windows system directory and invokes it with `/d /s /c`. Command strings use
the selected shell's syntax, including its quoting, expansion, operators, and
redirection rules; POSIX shell commands are not portable to `cmd.exe`.

Use `os.spawn` when an executable and arguments must be passed directly or
stdout and stderr must remain separate. The command is text and rejects an
embedded NUL before native process creation. `popen` has no mode argument; its
captured pipes carry byte strings without CRT text-mode translation. A child
program still chooses its own text encoding.

The child gets a captured stdin pipe and one captured pipe shared by stdout and
stderr. `InputOutputStream:write` writes the child's stdin, while `read` and
`read_until` consume that one merged output stream. There is exactly one
high-level facade over the merged pipe, so no second reader can race through a
separate stderr object. The record converts to all seven
[`io` Interfaces](standard-library-io.md#standard-implementations) and adds
`wait`; as with every Interface, satisfaction is checked structurally where
the conversion is written.

`wait` reaps the child and stores its complete `os.ExitStatus`. Later calls
return the stored status without waiting again; normal and signal termination
retain the same representation documented by `os.Process:wait`.

`close` is idempotent. Its first call closes stdin, requests `term` only when
the child is still running, and waits for that termination when necessary.
After stdin close succeeds, a final cleanup closes the one merged InputStream
and discards unread buffered output even when signalling or waiting raises.
The composite facade reaches its terminal closed state only after process
cleanup completes, so a later `close` can retry work that did not reach that
point. If `wait` has already stored a status, `close` does not signal the exited
child. A later `wait` returns the cached or already-retained process status;
after output disposal, later `read` and `read_until` calls return nil.
Signalling targets the launched shell process; neither `close` nor Task
cancellation guarantees termination of its descendants.

For large bidirectional traffic, schedule writing and reading concurrently so
neither operating-system pipe can fill while the other direction is waiting.
Read merged output through EOF before an ordinary `wait` when the child may
produce more than one pipe buffer. Errors and cancellation follow the same
Task and native-owner cleanup rules as direct process streams.

### Transferring shell streams

`InputOutputStream:to_transfer_payload()` transfers the idle writable stdin and
merged readable stdout/stderr pipes. Pending wrapper operations and underlying
pipe reads or writes are rejected before either pipe is detached. Native pipe
handoff follows the platform restrictions of
[`os.InputStream` and `os.OutputStream`](#transferring-process-streams).
`InputOutputStream.from_transfer_payload(payload)` adopts both pipes on the
current destination Runtime, including buffered output.

Captured shell output starts reading as soon as `popen` creates the process.
On Windows this normally leaves an overlapped read pending even before the
first `read()` call. Such live shell pipes reject transfer with `EBUSY`;
yielding alone does not make them idle. Rejection preserves the original
wrapper's writes, reads, and child `wait()`.

Child-process ownership remains at the origin. Keep the original Runtime
running to receive and reap the child's exit. The original wrapper's `wait()`
still returns the child status, and its `close()` still terminates a running
child when needed. Its transferred read side returns EOF and its writes
raise. The destination owns communication only: `wait()` raises
`transferred InputOutputStream has no child process owner`, while `close()`
closes its pipes without signalling or waiting for the child. Closing the
origin wrapper can therefore terminate a child still communicating through the
destination.

If native handoff of the second pipe fails after the first succeeded, the
source retains the first pipe's payload. A later transfer retries with that
payload; `write()` re-adopts it locally, while `close()` directly retires its
descriptor even after Runtime shutdown has closed transfer admission. If
serializing the payload after both pipes detach fails, the hook closes both
detached pipes and leaves the source communication facades closed; the original
child remains available through `wait()` and `close()`.

The payload follows the
[shared manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules):
deliver and adopt it exactly once within this process, recover failed delivery,
and explicitly close the destination. The composite has no
`discard_transfer_payload`; recover an undelivered payload by adopting it and
closing the result. Copying or dropping a payload does not duplicate or close
the owned pipes. A [`TransferValue`](async-io.md#transfer-values) carrying the
record names the module `titan.os` and the nominal type
`titan.os.InputOutputStream`; it is decoded only by a provider that declares
that type.

## Errors

Native libuv failures raise [`async.OperationError`](async-io.md#errors-and-cancellation)
with an operation name identifying the failed helper. A platform
`UV_ENOSYS` result is exposed as that error; the library does not silently
fall back to a POSIX-specific implementation. Browser stream errors follow
the [parent-stream contract](#browser-parent-streams).

Process and pipe setup, I/O, spawn, and signal failures use operation names
that identify the failed transition. Immediate validation and asynchronous
callback failures obey the same Task error and cancellation rules as the other
async standard modules.
