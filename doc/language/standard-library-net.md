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

Network operations must run inside a Task started by `async.run`, or inside a
standalone program whose imports installed the automatic async bootstrap. They
suspend only the current Task. Callbacks and continuations run serially on the
loop thread; CPU-bound code still blocks other I/O until it yields.

## API

```titan
record Connection
record Server

function connect(host: string, port: integer): Connection
function listen(host: string, port: integer,
                backlog: integer?): Server

function Connection:read(): string?
function Connection:read_until(delimiter: string,
                               chop: boolean?): string?
function Connection:write(data: string)
function Connection:shutdown()
function Connection:close()

function Server:accept(): Connection
function Server:close()
```

`Connection` and `Server` are opaque nominal records. Applications cannot
construct them or inspect their native handles.

`Connection`'s `read`, `read_until`, `write`, and `close` shapes exactly
satisfy all seven [`io` Interfaces](standard-library-io.md). `Server`
incidentally satisfies `io.Closer` through its exact `close()` method.

## Connecting and listening

`connect` resolves `host` asynchronously and considers IPv4 and IPv6 TCP
addresses in resolver order. A failed candidate has its ordinary asynchronous
close initiated before the next address is tried; connection fallback does not
wait for that close callback. It accepts ports `1..65535`.

`listen` resolves and binds `host`, then starts a TCP listener. Its port may be
`0` to request an ephemeral operating-system port, although this initial API
does not expose the selected address or port. `backlog` must be in
`1..2147483647` and is passed directly to libuv's listener; when omitted, it
defaults to 128.

Hosts are text and cannot contain an embedded NUL. Socket payloads are binary
and may contain any byte, including NUL.

## Reading

A Connection starts its libuv read watcher lazily on the first `read` or
`read_until`. Once started, it keeps reading and retaining GC-owned chunks even
when no Task is waiting. The retained application buffer has no size limit, so
a peer that produces data faster than the program drains it can make memory
use grow.

`read()` returns the facade's retained delimiter excess first. Otherwise it
returns the oldest native chunk already buffered, or waits for the next
positive callback and returns that callback's nonempty binary string. Chunk
boundaries are timing-dependent. It returns `nil` at EOF or after explicit
close, and later reads remain at EOF. A reset or other read error stops the
watcher and remains stored; after earlier buffered chunks have been drained,
later reads raise that error until the Connection is closed.

`read_until(delimiter, chop)` requires a nonempty delimiter. It consumes
through the first delimiter, which may span native chunks, and retains bytes
after it for the next call. With `chop` absent or false, the returned string
includes an actual delimiter. With `chop == true`, the delimiter is omitted;
if it occurs at the start, `""` is a valid result distinct from EOF `nil`.

EOF after a nonempty unterminated tail returns that tail unchanged, then later
calls return sticky `nil`. With no tail, EOF returns `nil`. Errors and
cancellation propagate normally; a delimiter read is composition over several
low-level reads and does not roll already consumed bytes back into the
Connection.

The low-level stream has at most one suspended reader. A second Task that tries
to wait on the same Connection is rejected; no separate facade lock or queue is
added. Cancelling a waiting reader detaches only that waiter, wakes it through
its own later timer callback, and leaves the physical read watcher and shared
Connection available to another Task.

## Writing, shutdown, and close

Writes are ordered per Connection by libuv itself. Titan submits one
`uv_write_t` per call instead of maintaining another queue. `write` returns
only after that request's callback and retains the original immutable input
while libuv borrows its complete binary payload. An empty write still checks
that the Connection and its write side are usable.

`shutdown` uses libuv's `uv_shutdown`, which completes after earlier writes,
then leaves the read side open until EOF, error, or `close`. Repeated shutdown
calls are idempotent.

`close` closes both directions and is idempotent. For a Connection, it stops
the continuous read, discards facade excess and queued native input, and wakes
a blocking low-level reader with `nil` on a later loop turn. Later `read` and
`read_until` calls remain at EOF, and new output is rejected. Libuv settles any
already submitted stream requests through their terminal callbacks while the
native handle closes. Runtime shutdown likewise closes a Connection or Server
left open by the application.

Cancellation never releases an active write request or its bytes early. Its
terminal callback performs native cleanup, then the Task finishes with the
`cancelled` status and its original `async.CancellationReason` value.

## Accepting

`accept` waits for the next Connection or takes the oldest already accepted
Connection retained by the Server. Only one Task may wait in `accept` at a
time. Cancelling that waiter leaves the Server listening.

Every incoming notification is accepted into a fresh GC-owned TCP handle. If
no Task is waiting, that Connection remains buffered until a later `accept`;
this initial API has no application-level buffer limit beyond the listen
backlog supplied to libuv. `Server:close` closes buffered clients and wakes an
accept waiter with an error.

## Errors

Immediate and asynchronous libuv failures raise the same provider-owned error
record, re-exported through the transparent facade alias
`async.OperationError`. Its fields are `code: integer`, `name: string`,
`message: string`, and `operation: string`. Like every alias to a record with a
public constructor, its nominal namespace also exposes
`async.OperationError.new`; ordinary callers normally receive these values
from the operation that failed.

DNS errors use libuv's `EAI_*` names. EOF is normal for both `read` and
`read_until`; an unterminated final batch is returned before sticky EOF.

## Example

```titan
local net = import "net"
local async = import "async"

function client(): value
  local connection = net.connect("127.0.0.1", 8080)
  defer connection:close()
  connection:write("hello\0world\n")
  connection:shutdown()
  return connection:read_until("\n", false)
end

function main(args: {string}): integer
  async.run(client)
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
remains in the combined standard-library provider
`$ROCKS_TREE/lib/titan/0.24/titan.so`. The supported installation currently
sets `ROCKS_TREE == PREFIX`; the former owns Titan's SDK/stdlib while the latter
owns Lua and LuaRocks. Repository contributors can still use
`make stdlib` for an in-checkout standard-library build.

The [`ssl` standard module](standard-library-ssl.md) wraps this public
Connection and Server API with OpenSSL memory BIOs. It does not reach through
`net` to private libuv handles.

UDP, Unix-domain/named pipes, socket options, and endpoint-inspection APIs are
follow-ups.
