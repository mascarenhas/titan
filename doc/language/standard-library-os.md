# Operating-system standard library

The `os` standard module provides portable environment, path, process,
one-shot signal, and child-process helpers backed by public libuv APIs. Titan
imports its canonical short name:

```titan
local os = import "os"
```

Lua loads the same canonical module image with `require "titan.os"`. The
qualified Lua name is deliberate: `require "os"` remains Lua's standard
library table and is never replaced.

The module currently supports Linux and macOS.

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
name and `exepath` the current executable path. `pid` and `ppid` return the
current and parent process identifiers.

Paths are text and reject embedded NUL. Buffer-sized results grow and retry
with checked arithmetic, so callers do not need to choose a capacity.

## Waiting for a signal

```titan
function wait_signal(name: string): string
```

`wait_signal` is an asynchronous cancellation point and must run inside a UV
Task. It installs a one-shot watcher and returns the canonical lowercase name
when the signal fires. Supported names on Linux and macOS are `"hup"`,
`"int"`, `"quit"`, `"term"`, `"usr1"`, and `"usr2"`.

Unknown names are rejected before a watcher is initialized. `"kill"` is also
rejected because it cannot be caught. Cancellation stops the watcher and
drains its close callback; a late signal cannot resume the Task a second time.
Signals are notifications rather than a queued history, so repeated standard
signals may coalesce. While a watcher is active, libuv owns that process signal
disposition; embedding code should not install a competing handler for it.

## Child processes

```titan
record ExitStatus
  code: integer
  signal: string?
  signal_number: integer
end

record Process

function spawn(file: string, args: {string}): Process
function Process:wait(): ExitStatus
function Process:kill(signal: string)
function Process:write_stdin(data: string)
function Process:close_stdin()
function Process:read_stdout(max_bytes: integer): string?
function Process:read_stderr(max_bytes: integer): string?
```

Process operations are asynchronous and must run inside a UV Task. A Titan
standalone program that imports `os` gets the automatic async bootstrap; a Lua
host should call them from a function passed to `uv.run`, then drive that Task
with `uv.loop`.

`spawn` starts `file` directly, without a shell. `args` contains the arguments
after `argv[0]`; the library supplies `file` as `argv[0]`. The child inherits
the current environment and working directory. File and argument strings are
text and reject embedded NUL before any native resource is created.

Every child has separate stdin, stdout, and stderr pipes. Pipe payloads are
binary strings and preserve embedded NUL. Nonempty `write_stdin` operations
are FIFO across Tasks and return only after their native write callback; an
empty write is a checked no-op. Cancelling a queued write removes it;
cancelling a submitted write consumes its eventual callback without killing
the child.

`close_stdin` is idempotent and ordered after earlier writes. Its first call
immediately rejects later writes, then cleanup-shields the physical pipe close.
Closing the write-end pipe is what delivers EOF to the child; socket-style
half-shutdown is not used. Programs whose child waits for input EOF must call
it.

`read_stdout(n)` and `read_stderr(n)` require `n > 0`. Each returns one
nonempty chunk of at most `n` bytes, or `nil` at permanent EOF. A read error is
also permanent and is re-raised by later reads. Each output pipe permits one
waiting reader, while stdout and stderr are independent and can be drained
concurrently. Cancelling a read stops only that read.

`wait` returns after the operating system has reaped the child. Only one Task
may wait at a time; cancelling it does not kill the child, and a replacement
Task may wait. Exit status is retained, so later sequential waits return a
fresh `ExitStatus` immediately. On normal exit, `signal` is `nil` and
`signal_number` is zero. Signal termination preserves its native number and
uses a canonical lowercase name when it belongs to the documented common
subset; an unknown signal has `signal == nil` but keeps its number.

For a child that may produce output, drain stdout and stderr concurrently with
stdin and `wait`; waiting first can deadlock when an operating-system pipe
buffer fills. Use `communicate` when the four operations do not need separate
application control.

`kill` accepts `"hup"`, `"int"`, `"quit"`, `"term"`, `"usr1"`, `"usr2"`,
and `"kill"`. Unknown names are rejected before libuv is called. Killing an
already exited Process is a lifecycle error, so a recycled process identifier
can never be targeted through an old wrapper.

If a Runtime finishes while a child is still alive, shutdown sends `term`,
allows a five-second grace period, then sends `kill` if necessary. The Runtime
still waits for the exit callback and every process/pipe close callback; it
does not leave a zombie.

## Communicating without deadlock

```titan
function communicate(file: string, args: {string},
                     input: string?): (string, string, ExitStatus)
```

`communicate` is the argv-based, popen-style convenience. It starts the child,
drains stdout and stderr concurrently, writes `input` when it is non-`nil`,
closes stdin, and returns both complete binary outputs with the exit status.
`nil` means no input; `""` is valid empty input and still closes stdin.

The reader, writer, and waiter helpers are observed before they can start. If
one fails or the parent is cancelled, the library cancels its siblings,
terminates and reaps the child, drains every callback under the cleanup shield,
then reports the original failure. Large simultaneous stdin, stdout, and
stderr traffic therefore cannot deadlock on a full pipe.

There is no shell-string `popen`. To use shell syntax intentionally, spawn the
desired shell explicitly and pass its arguments as an array.

## Errors

Libuv failures raise [`uv.Error`](async-io.md#results-errors-and-cancellation)
with an operation name identifying the failed helper. A platform
`UV_ENOSYS` result is exposed as that error; the library does not silently
fall back to a POSIX-specific implementation.

Process and pipe setup, I/O, spawn, and signal failures use operation names
that identify the failed transition. Immediate validation and asynchronous
callback failures obey the same Task error and cancellation rules as the other
async standard modules.
