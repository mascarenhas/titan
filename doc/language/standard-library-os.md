# Operating-system standard library

The `os` standard module provides portable environment, path, process-identity,
and one-shot signal helpers backed by public libuv APIs. Titan imports its
canonical short name:

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

## Errors and current scope

Libuv failures raise [`uv.Error`](async-io.md#results-errors-and-cancellation)
with an operation name identifying the failed helper. A platform
`UV_ENOSYS` result is exposed as that error; the library does not silently
fall back to a POSIX-specific implementation.

Child-process spawning, stdio pipes, exit status, and `communicate` are the
remaining part of this standard module's Phase 6 implementation. They are not
part of the current public API yet. There is no implicit shell-string `popen`.
