# Operating-system standard library

The `os` standard module provides portable clocks, calendars, locales,
environment, path, process, graceful exit, one-shot signal, and child-process
helpers. Its
synchronous CPU/current-time queries and resource-owning operations use public
libuv APIs; calendar conversion, formatting, differences, and locale selection
use ISO C where libuv has no equivalent. Titan imports its canonical short
name:

```titan
local os = import "os"
```

Lua loads the same canonical module identity with `require "titan.os"`. The
qualified Lua name is deliberate: `require "os"` remains Lua's standard
library table and is never replaced.

The module currently supports Linux and macOS.

## Clocks and time differences

```titan
function clock(): float
function difftime(later: integer, earlier: integer): float
```

`clock` sums the portable libuv user and system CPU-usage clocks and returns
seconds consumed by the program. It is not elapsed wall time. `difftime`
returns `later - earlier` in seconds using the host's ISO C calendar-time
representation. Titan timestamps are integers on the supported 64-bit Linux
and macOS targets.

## Calendar formatting and decomposition

```titan
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

```titan
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

```titan
function setlocale(locale: string?, category: string?): string?
```

The categories are `"all"` (the default), `"collate"`, `"ctype"`,
`"monetary"`, `"numeric"`, and `"time"`. With `locale == nil`, `setlocale`
queries the current selection. Otherwise it requests that locale and returns
the selected name, or `nil` when the C library cannot satisfy the request.
`""` asks for the implementation-defined native locale and `"C"` selects the
portable C locale. Locale and category strings reject embedded NUL; unknown
categories raise.

Locale selection is process-global and the ISO C calendar/locale functions
used here have process-global or static storage. They are not safe to race from
multiple operating-system threads. Titan's v1 async callbacks execute serially
on one loop thread; embedding hosts must provide the same exclusion.

## Environment

```titan
function getenv(name: string): string?
function setenv(name: string, contents: string)
function unsetenv(name: string)
```

`getenv` returns `nil` when the variable is absent and preserves an existing
empty value as `""`. `setenv` creates or replaces a variable. `unsetenv` is
successful even when the variable is already absent.

Names and values are text. An embedded NUL is rejected before libuv is called.
These operations change process-global state and, like the underlying libuv
functions, are not thread-safe; Titan's v1 async runtime itself executes all
callbacks serially on one loop thread. An embedding host must likewise avoid
racing these helpers from another operating-system thread.

## Directories and host identity

```titan
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

```titan
function wait_signal(name: string): string
```

`wait_signal` is an asynchronous cancellation point and must run inside an
async Task. It installs a one-shot watcher and returns the canonical lowercase
name when the signal fires. Supported names on Linux and macOS are `"hup"`,
`"int"`, `"quit"`, `"term"`, `"usr1"`, and `"usr2"`.

Unknown names are rejected before a watcher is initialized. `"kill"` is also
rejected because it cannot be caught. Cancellation stops the watcher and
drains its close callback; a late signal cannot resume the Task a second time.
Signals are notifications rather than a queued history, so repeated standard
signals may coalesce. While a watcher is active, libuv owns that process signal
disposition; embedding code should not install a competing handler for it.

## Graceful program exit

```titan
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

## Child processes

```titan
record ExitStatus
  code: integer
  signal: string?
  signal_number: integer
end

record SpawnConfig
type SpawnOption = (SpawnConfig) -> integer

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
function OutputStream:write(data: string)
function OutputStream:close()
function OutputStream:is_tty(): boolean
```

Spawning, stream I/O, parent-stdio access, signalling, and waiting must run
inside an async Task. `is_running` and `is_tty` do not yield, but still
validate the exact Runtime that owns the resource. A Titan standalone
program that imports `os` gets the automatic async bootstrap; a Lua host should
call these APIs from a function passed to `async.run`, then drive that Task
with `async.loop` after loading `require "titan.async"`.

`InputStream` and `OutputStream` are ordinary records with private fields.
They represent process standard streams only: the Titan process's own stdio
and the parent-facing endpoints of captured child stdio. They are not unions
of files, sockets, parent resources, and child resources. The private
low-level handle is the tagged value, with pipe and TTY variants, so
`is_tty()` reports the actual native handle kind rather than the stream's
origin.

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

`with_stdin`, `with_stdout`, and `with_stderr` select a captured
parent-facing pipe. The corresponding `with_parent_*` function selects direct
inheritance of the current parent stream. Later options replace conflicting
earlier entries immediately, retiring any unsubmitted stream handles that are
no longer referenced. This includes a later choice that breaks an earlier
merge; repeating an option has the same observable result. Callers may compose
the supplied functions in their own integer-returning `SpawnOption` closures,
but cannot construct or inspect a `SpawnConfig` directly.

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

The module exports three mutable stream variables:

- `os.stdin: InputStream` reads the parent process's descriptor 0;
- `os.stdout: OutputStream` writes descriptor 1; and
- `os.stderr: OutputStream` writes descriptor 2.

These are stable high-level records rather than handles borrowed from the
first event loop that touches them. Each operation resolves the current
Runtime's lazily initialized pipe-or-TTY owner. A retained stream therefore
rebinds safely after one `async.run`/`async.loop` session ends and another
begins, without returning buffered input from the previous Runtime.

Process stdio supports TTY and named-pipe descriptors. A descriptor classified
by libuv as a regular file, TCP socket, or another kind is rejected instead of
turning `os.InputStream`/`OutputStream` into a `fs.File` or `net.Connection`
variant. Those records independently implement the relevant structural `io`
interfaces, but are not process-stream values. `is_tty()` checks the private
handle's TTY/pipe tag; captured child endpoints are pipes and report false.

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
`AF_UNIX` or type other than `SOCK_STREAM` rejects the stream. Known TTY and
pipe descriptors need no hint; regular files, TCP sockets, and datagram
sockets are rejected whenever libuv or either explicit probe identifies their
incompatible kind. When both socket probes are denied, Titan trusts the
launcher's assertion about the hidden family and type; the hint does not
validate that unavailable metadata. An unsupported kind or failed inspection
raises `async.OperationError` with
operation `stdio.parent.kind` and a message naming the descriptor and probe.
An invalid descriptor retains its actual `EBADF` error.

The Runtime caches each successfully initialized parent wrapper. The launcher
must update or clear the hint when replacing inherited descriptors; changing
the variable after a wrapper has been initialized does not reclassify it.

The raw parent descriptors remain owned by the host process. Each Runtime owns
one stream wrapper over a close-on-exec duplicate, whose teardown cannot close
the original descriptor. A `with_parent_*` configurator installs that wrapper
with `UV_INHERIT_STREAM`; libuv gives the child a duplicate of the descriptor
used by the stream. The wrapper stays owned by the Runtime, and several
children may inherit the same parent stream.

The read watcher for parent stdin starts lazily on an `os.stdin` read.
Preparing or inheriting that stream therefore does not consume bytes intended
for a child before either reader actually asks for them.

Closing any of the three stable parent stream facades is an idempotent no-op.
It neither closes the Runtime-owned duplicate nor changes later operations on
the facade; Runtime teardown alone retires that Runtime's wrapper. This is
distinct from closing a captured child endpoint.

`InputStream` satisfies the standard `io.Reader`, `io.Closer`, and
`io.ReaderCloser` Interfaces exactly.
`OutputStream` satisfies `io.Writer`, `io.Closer`, and `io.WriterCloser`
exactly. These are structural conversions at typed use sites; neither the
records' private ownership metadata nor the low-level handle union is part of
any Interface.

### Process stream I/O

Each nonempty write to a captured `process.stdin` immediately submits its own
`uv_write_t` and returns only after that request's callback. Libuv supplies
stream write ordering; Titan adds no operation queue. An empty write is a
checked no-op. The request retains the original immutable string until its
eventual callback while libuv borrows, but does not mutate, its bytes.
Cancelling the Task does not release that owner early or kill the child.
On Unix, loading `titan.uv` changes a default `SIGPIPE` disposition to ignored
so a child that closes stdin produces the ordinary libuv write error instead
of terminating the parent process. An already ignored signal or an
application-installed handler is preserved.

Closing a captured `process.stdin` is idempotent. Its first call marks the
stream terminal and submits the physical pipe's `uv_close`; later writes are
rejected, and any independently submitted write still receives its own libuv
callback. Closing the write-end pipe is what delivers EOF to the child;
socket-style half-shutdown is not used. Programs whose child waits for input
EOF must call it.

Successful spawn initialization starts continuous reads on each captured
output pipe. Each pipe retains GC-owned chunks even when no Task is waiting,
with no maximum or high-water mark. This keeps draining the operating-system
pipes but means an undrained child can make application memory use grow. If a
read watcher unexpectedly cannot start, that stream closes with a stored error
which its first read reports; the successfully spawned Process remains usable
and waitable. The low-level module does not turn this setup failure into a
child-termination policy.

An `InputStream:read()` returns that stream's oldest facade excess first.
Otherwise it returns one oldest buffered native chunk, or waits for the next
positive callback. A positive chunk is nonempty, binary, and timing-dependent.
EOF returns `nil` permanently. A read error closes that output pipe; after
completed chunks have drained, later reads raise its stored `async.OperationError`.

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
waiting read detaches only its waiter, wakes that Task through its own later
timer callback, and leaves the physical read active for another Task.

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

### Process lifecycle

`wait` returns after the operating system has reaped the child. Only one Task
may wait at a time; cancelling it does not kill the child, and a replacement
Task may wait. The cancelled Task is resumed by its own later libuv timer
callback rather than synchronously by the cancelling Task. Exit status is
retained, so later sequential waits return a fresh `ExitStatus` immediately.
On normal exit, `signal` is `nil` and `signal_number` is zero. Signal
termination preserves its native number and uses a canonical lowercase name
when it belongs to the documented common subset; an unknown signal has
`signal == nil` but keeps its number.

For a child that may produce output, drain stdout and stderr concurrently with
stdin and `wait`; waiting first can deadlock when an operating-system pipe
buffer fills.

`kill` accepts `"hup"`, `"int"`, `"quit"`, `"term"`, `"usr1"`, `"usr2"`,
and `"kill"`. Unknown names are rejected before libuv is called. Killing an
already exited Process is a lifecycle error, so a recycled process identifier
can never be targeted through an old wrapper.

`is_running` is a side-effect-free observation of the retained process state.
It becomes false once the exit callback has reported termination, but it does
not reap the child and does not replace `wait`. Code that conditionally signals
a Process can use it immediately before `kill`; neither operation yields
between the observation and signal request.

If a Runtime finishes while a child is still alive, its cleanup Task discovers
the `uv_process_t` watcher through `uv_walk` and closes it like any other
handle. `uv_close` retires the watcher but does not signal, wait for, or reap
the child; the child may outlive the Runtime. Programs that require termination
or reaping must explicitly call `kill` and `wait` while that Runtime is active.

For the shell-command convenience API with writable stdin and one merged
output stream, see [`io.popen`](standard-library-io.md#shell-commands).
`os.spawn` remains the direct executable/argv API for separate stream control.

## Errors

Libuv failures raise [`async.OperationError`](async-io.md#errors-and-cancellation)
with an operation name identifying the failed helper. A platform
`UV_ENOSYS` result is exposed as that error; the library does not silently
fall back to a POSIX-specific implementation.

Process and pipe setup, I/O, spawn, and signal failures use operation names
that identify the failed transition. Immediate validation and asynchronous
callback failures obey the same Task error and cancellation rules as the other
async standard modules.
