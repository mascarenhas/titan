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

```text
record Connection
record Server

function resolve(host: string, port: integer): {uv.sockaddr_t}
function Connection.new(): Connection
function Connection:connect_address(address: uv.sockaddr_t)
function connect(host: string, port: integer): Connection
function listen(host: string, port: integer,
                backlog: integer?, reuse_port: boolean?): Server

function Connection:read(): string?
function Connection:has_pending_input(): boolean
function Connection:add_input_listener(listener: function (): ()): function (): ()
function Connection:read_until(delimiter: string,
                               chop: boolean?): string?
function Connection:write(data: string)
function Connection:shutdown()
function Connection:close()

function Server:accept(): Connection
function Server:close()
```

`Connection` and `Server` are opaque nominal records. Applications cannot inspect their native handles. `Connection.new()` creates
an initialized, unconnected endpoint in the current Runtime; `Server` has no
public constructor.

`Connection`'s `read`, `read_until`, `write`, and `close` shapes exactly
satisfy all seven [`io` Interfaces](standard-library-io.md). `Server`
incidentally satisfies `io.Closer` through its exact `close()` method.

## Connecting and listening

`resolve(host, port)` returns copied, owned public `uv.sockaddr_t` values in
resolver order, restricted to IPv4/IPv6 TCP addresses. It accepts a nonempty
host without NUL and ports `1..65535`. Address values retain their bytes after
the native DNS result has been freed. DNS cancellation requests native request
cancellation and still waits for its actual callback; cancellation of already
running resolver work can fail, so safe retirement may extend a deadline.

For a protocol that needs to own a socket before dialing, create
`net.Connection()`, immediately defer its `close()`, then call
`connect_address(address)` with one complete IPv4/IPv6 address and a nonzero
port. This does no second DNS query. Only connect, close, and the synchronous input-state query are valid before a
successful dial. Repeat or concurrent connect attempts fail; a failed attempt
leaves the endpoint unusable until close. A supervisor can close the known
endpoint while its connect is pending, then drain the connecting Task. The
native request and selected address remain retained through its callback.


`connect` resolves `host` asynchronously and considers IPv4 and IPv6 TCP
addresses in resolver order. A failed candidate has its ordinary asynchronous
close initiated before the next address is tried; connection fallback does not
wait for that close callback. It accepts ports `1..65535`.

`listen` resolves and binds `host`, then starts a TCP listener. Its port may be
`0` to request an ephemeral operating-system port, although this initial API
does not expose the selected address or port. `backlog` must be in
`1..2147483647` and is passed directly to libuv's listener; when omitted, it
defaults to 128.

`reuse_port` defaults to false. When true, the bind uses libuv's
`UV_TCP_REUSEPORT`, allowing independent listeners to share one local address
and port. Every participating listener must enable it. The operating system
distributes incoming connections; no round-robin ordering or fairness is
promised. Each listener belongs to the Runtime that created it and closes
independently, making the option useful for servers in separate processes or
independent Lua states.

Support follows [libuv's TCP bind contract](https://docs.libuv.org/en/v1.x/tcp.html#c.uv_tcp_bind).
Linux supports this option; macOS and Windows currently raise
`async.OperationError` with name `"ENOTSUP"`. Titan preserves the native error
rather than silently binding without reuse. Omitted or false keeps the
ordinary exclusive listener behavior.

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
boundaries are timing-dependent. Each returned chunk is an immutable copy;
later receives cannot change its bytes. The Connection may reuse up to 64 KiB
of private scratch storage while reading, separately from the unbounded queue
of completed chunks. It releases that scratch storage on EOF, error, or
explicit close. A Connection retained after Runtime teardown can retain that
bounded scratch storage until it is closed, read again, or collected.
It returns `nil` at EOF or after explicit close, and later reads remain at EOF.
A reset or other read error stops the
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
added. Cancelling a waiting reader detaches only that waiter, wakes it on a
later loop turn, and leaves the physical read watcher and shared Connection
available to another Task.

`has_pending_input()` synchronously reports retained delimiter bytes, queued
native input, EOF/error/close, or an endpoint that is not connected. It does not
consume data, start reading, reserve a reader, check cancellation, or poll the
socket. False means no input or terminal state has been observed yet; bytes can
still be in the operating system or arrive later. Protocol pools can use this
conservative snapshot to reject a connection with unsolicited input.

`add_input_listener(listener)` registers a nonconsuming observer from a Task on
a connected endpoint and returns an idempotent remover. It does not start the
lazy read watcher or report old buffered input. After each new positive receive
or EOF/error is buffered, listeners run in registration order in the native
callback, outside Task execution. They must not yield or perform blocking I/O;
they may remove listeners or schedule a Task. Removing a later listener skips
it during the same notification. An observer error does not skip remaining
listeners, but propagates to Runtime failure. Explicit close clears listeners
without emitting an input event. Pair registration with `has_pending_input()`
when previously buffered data matters, and remove observers before reuse by a
different protocol owner.

## Writing, shutdown, and close

Writes are ordered per Connection by libuv itself. Titan submits one
`uv_write_t` per call instead of maintaining another queue. `write` returns
only after that request's callback and retains the original immutable input
while libuv borrows its complete binary payload. An empty write still checks
that the Connection and its write side are usable. Overlapping writes keep
independent requests and strings until their own terminal callbacks.

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

Immediate and asynchronous libuv failures raise the public async-owned record
`async.OperationError`. Its fields are `code: integer`, `name: string`,
`message: string`, and `operation: string`. Its public constructor can be
called directly as `async.OperationError(...)`
(or explicitly through `async.OperationError.new`); ordinary callers normally receive these values
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
  async.run<|value, value|>(client)
  return 0
end
```

## Availability

Linux and macOS are supported. The build downloads, verifies, and
statically links the pinned, patched libuv release:

```sh
make libuv
"$PREFIX/bin/luarocks" make
```

The Unix build includes a [failed-spawn cleanup correction](../../vendor/libuv/README.md).
System libuv is not supported. Applications importing the installed binary
`net` module do not need libuv headers at compile time; all native libuv and callback linkage
remains in the combined standard-library provider
`$ROCKS_TREE/lib/titan/0.6/titan.so`. The supported installation currently
sets `ROCKS_TREE == PREFIX`; the former owns Titan's SDK/stdlib while the latter
owns Lua and LuaRocks. Repository contributors can still use
`make stdlib` for an in-checkout standard-library build.

The [`ssl` standard module](standard-library-ssl.md) wraps this public
Connection and Server API with OpenSSL memory BIOs. It does not reach through
`net` to private libuv handles.

This high-level `net` module does not expose UDP, Unix-domain/named pipes,
arbitrary socket options, or endpoint inspection. The public
[`uv` binding](standard-library-uv.md) provides those native operations for
low-level clients and adapters.
