# TCP networking

The `net` standard module provides asynchronous DNS and TCP with direct-style
Titan methods. Titan source imports it as:

```titan
local net = import "net"
```

Lua loads the same canonical module identity with:

```lua
local net = require "titan.net"
```

Network operations must run inside a Task started by `uv.run`, or inside a
standalone program whose imports installed the automatic UV bootstrap. They
suspend only the current Task. Callbacks and continuations run serially on the
loop thread; CPU-bound code still blocks other I/O until it yields.

## API

```titan
record Connection
record Server

function connect(host: string, port: integer): Connection
function listen(host: string, port: integer,
                backlog: integer): Server

function Connection:read_some(max_bytes: integer): string?
function Connection:read_exactly(bytes: integer): string
function Connection:read_until(delimiter: string,
                               max_bytes: integer): string
function Connection:write(data: string)
function Connection:shutdown()
function Connection:close()

function Server:accept(): Connection
function Server:close()
```

`Connection` and `Server` are opaque nominal records. Applications cannot
construct them or inspect their native handles.

## Connecting and listening

`connect` resolves `host` asynchronously, considers IPv4 and IPv6 TCP
addresses in resolver order, and closes each failed candidate before trying
the next. It accepts ports `1..65535`.

`listen` resolves and binds `host`, then starts a TCP listener. Its port may be
`0` to request an ephemeral operating-system port, although this initial API
does not expose the selected address or port. `backlog` must be positive and
also sets the maximum number of already accepted Connections retained in the
library's user-space accept queue.

Hosts are text and cannot contain an embedded NUL. Socket payloads are binary
and may contain any byte, including NUL.

## Reading

`read_some(n)` requires `n > 0`. It returns one nonempty binary string of at
most `n` bytes, or `nil` at EOF. EOF is permanent: later reads return `nil`
without restarting libuv. A reset or other read error raises `uv.Error` and is
also permanent; later reads re-raise the stored error without starting another
read.

Only one Task may read a Connection at a time. A second reader raises instead
of racing for bytes. Cancelling the waiting reader stops that read but does not
close the shared Connection; another Task may read afterward.

`read_exactly(n)` accepts `n >= 0`, returns exactly that many bytes, and returns
`""` for zero. EOF before `n` raises a `uv.Error` whose operation is
`net.read_exactly`; its message and subject contain the requested and partial
byte counts. It never returns a short string.

`read_until(delimiter, max_bytes)` requires a nonempty delimiter and a positive
limit at least as long as the delimiter. It returns through and including the
first delimiter. The delimiter may span multiple native reads. Bytes after it
remain buffered for the next read.

Both composite readers preserve bytes they already consumed if they raise or
are cancelled. In particular, a `read_until` limit failure does not discard
the first `max_bytes`; the caller can recover them with another read.

## Writing, shutdown, and close

Writes are FIFO per Connection. `write` returns only after libuv's callback,
and the complete binary input remains rooted until then. An empty write still
checks that the Connection and its write side are usable.

`shutdown` is ordered after earlier writes. Requesting it immediately rejects
later writes. The first call is cleanup-shielded until the physical
`uv_shutdown` callback, then leaves the read side open until EOF, error, or
`close`. Repeated shutdown calls are idempotent and do not enqueue another
native request.

`close` closes both directions and is idempotent. Concurrent callers wait for
the same terminal close transition. For a Connection, it stops a pending read
and rejects new work, but submitted and queued FIFO writes/shutdown keep their
order; the native handle closes only after that output drains. Close waits for
the required request and handle callbacks and returns only when the handle is
safe to reclaim. A Connection or Server retained from an earlier completed
loop session cannot be used in a later session.

Cancellation is logical first. A cancelled queued write is removed before
submission. Cancelling an active write does not close a potentially shared
Connection; its eventual callback only cleans storage and the Task receives
`uv.Cancelled`. Close and the first shutdown are shielded through their
terminal native callbacks before sticky cancellation is delivered.

## Accepting

`accept` waits for the next Connection or takes the oldest already accepted
Connection from the bounded queue. Only one Task may wait in `accept` at a
time. Cancelling that waiter leaves the Server listening.

Every incoming notification is accepted into a fresh GC-owned TCP handle. If
no Task is waiting and the bounded queue is full, the new client is immediately
closed; the Server stays active. `Server:close` closes queued clients and wakes
an accept waiter with an error.

## Errors

Immediate and asynchronous libuv failures raise the same `uv.Error` record:

```titan
record Error
  code: integer
  name: string
  message: string
  operation: string
  subject: string?
end
```

DNS errors use libuv's `EAI_*` names. EOF is normal for `read_some`; only a
composite read that promised more data turns premature EOF into an Error.

## Example

```titan
local net = import "net"
local uv = import "uv"

function client(): value
  local connection = net.connect("127.0.0.1", 8080)
  defer connection:close()
  connection:write("hello\0world\n")
  connection:shutdown()
  return connection:read_until("\n", 4096)
end

function main(args: {string}): integer
  local task = uv.run(client)
  task:join()
  return 0
end
```

## Availability

Linux and macOS are supported. The default build downloads, verifies, and
statically links the pinned libuv release:

```sh
make libuv
"$PREFIX/bin/luarocks" make
```

For a system development package, install libuv and `pkg-config`, then use:

```sh
LIBUV_MODE=system make libuv
LIBUV_MODE=system "$PREFIX/bin/luarocks" make
```

Typical packages are `libuv1-dev pkg-config` on Debian/Ubuntu,
`libuv-devel pkgconf-pkg-config` on Fedora, and `libuv pkgconf` through
Homebrew on macOS. Applications importing the installed binary `net` module do
not need libuv headers at compile time; all libuv and callback-shim linkage
remains in the qualified
`$ROCKS_TREE/lib/titan/0.11/titan/uv.so`. The supported installation currently
sets `ROCKS_TREE == PREFIX`; the former owns Titan's SDK/stdlib while the latter
owns Lua and LuaRocks. Repository contributors can still use
`make stdlib` for an in-checkout standard-library build.

UDP, Unix-domain/named pipes, socket options, and endpoint-inspection APIs are
follow-ups.
