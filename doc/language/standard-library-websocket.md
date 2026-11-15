# WebSocket messages

Import `websocket` for RFC 6455 WebSocket version 13 over HTTP/1.1. Calls look
blocking and suspend their current Task. Both `ws` and verified `wss` clients
are supported. On native targets the server accepts inside an ordinary
`http.Handler`, including handlers passed to `http.listen_tls`. On the browser
target the client runs over the host's `WebSocket` and the server is absent
(see [on the browser](#on-the-browser)).

```titan
local http = import "http"
local websocket = import "websocket"

local function handler(request: http.Request, response: http.Response)
  if request.url.path ~= "/echo" then
    response:set_status(404)
    return
  end
  local connection = websocket.accept(request, response)
  defer connection:close()
  while true do
    local kind?, message? = connection:read()
    if kind == nil then break end
    connection:write(kind, message)
  end
end

function main(_args: {string}): integer
  local server = http.listen("127.0.0.1", handler, 8080, nil, 10000)
  defer server:close()
  server:serve()
  return 0
end
```

Authenticate and authorize the route before acceptance. On success HTTP
transfers the stream and prefetched bytes to the WebSocket connection. The
handler must immediately defer close or establish another owned Task. The
handler may then return; HTTP does not close the transferred stream. Closing
the HTTP listener stops accepts and does not close transferred sessions.

For a TLS server, use the same handler with
`http.listen_tls(host, certificate_file, handler, private_key_file, port,
backlog, idle_timeout)`. Use a certificate for the client-visible identity.
Server TLS and request-header acquisition have HTTP's existing timeout policy;
`accept` has its own response-output budget after HTTP supplies headers.

```titan
local websocket = import "websocket"

function main(args: {string}): integer
  local connection = websocket.connect("wss://localhost:8443/echo",
    websocket.DialOptions { ca_file = args[1] })
  defer connection:close()
  connection:write(websocket.TEXT, "hello")
  local kind?, message? = connection:read()
  if kind == nil or message ~= "hello" then return 1 end
  connection:shutdown()
  return 0
end
```

An explicit CA file replaces default OpenSSL trust paths, following `ssl`.
Verification always includes the original URL hostname, even when dialing a
resolved numeric address. There is no insecure mode or automatic redirect.

## Public interface

```text
union MessageType: text(), binary()
const TEXT, BINARY: MessageType
record Connection -- opaque; construct with connect or accept

DialOptions(headers: http.Headers?, ca_file: string?,
            subprotocols: ({string})?, read_limit: integer?,
            handshake_timeout: integer?)
AcceptOptions(subprotocols: ({string})?, allowed_origins: ({string})?,
              read_limit: integer?, handshake_timeout: integer?)

connect(source_url: string, options: DialOptions?): Connection
accept(request: http.Request, response: http.Response,
       options: AcceptOptions?): Connection
Connection:read(): (MessageType?, string?)
Connection:write(kind: MessageType, data: string)
Connection:ping(timeout_ms: integer?)
Connection:shutdown(code: integer?, reason: string?, timeout_ms: integer?)
Connection:close()
Connection:to_transfer_payload(): string
Connection.from_transfer_payload(payload: string): Connection
Connection.discard_transfer_payload(payload: string): integer
Connection:subprotocol(): string?
Connection:close_status(): (integer?, string?)
```

On the browser target, `accept`, `AcceptOptions`, `Connection:ping`, and the
three transfer hooks have no declarations.

Option constructors validate positive limits/deadlines and copy headers and
arrays. The incoming message limit defaults to **1 MiB**; choose a larger
finite positive limit for a known workload. Opening defaults to **10 seconds**.
Ping, shutdown and automatic control output default to **5 seconds**. Deadlines
initiate abort and safe ownership retirement. Native DNS/connect/write callback
retirement can extend return latency beyond the nominal deadline.

`read` returns one complete text or binary message. Empty strings are messages.
`(nil, nil)` means a valid peer Close was received and reciprocal closing
completed. TCP EOF or TLS loss before a valid WebSocket Close is an abnormal
error. `close_status` preserves the peer's actual code and reason. An empty
Close has no code/reason; a code with no reason has an empty reason. Local
abnormal closure never invents an on-wire 1006.

One application reader and one application data writer can progress together,
on plain or TLS streams. Duplicate readers, data writers, Ping waiters or
shutdown operations fail clearly. Outgoing messages use data fragments of at
most 16 KiB. Controls can be sent between frames; two data messages never
interleave. Text is validated before emission; binary strings preserve all
bytes, including NUL. Received UTF-8 is validated across chunks and fragments.

## Transferring connections

An idle open `Connection` implements
`to_transfer_payload(): string` and
`Connection.from_transfer_payload(payload: string): Connection`.
Use `async.TransferValue.from_value(connection)` and decode its custom record
policy with `packet:to_value()` in a state with an active async Runtime. The
same-process handoff preserves the client/server role, selected subprotocol,
read limit and unread WebSocket, HTTP upgrade and TCP/TLS bytes. If serializing
the enclosing value fails after the child transport detached, the hook closes
the detached transport and leaves the source terminal.

Transfer rejects pending reader, writer, Ping, Pong, Close, shutdown or
retirement work, and rejects a closing or terminal session. An operation remains
pending until its public call finishes, including cancellation and deadline
cleanup after internal work completes. Its transport must
also satisfy the [TCP](standard-library-net.md#transferring-connections) and,
for `wss`, [TLS](standard-library-ssl.md#transferring-connections) idle rules.
The persistent Windows overlapped read normally makes an established session
ineligible even between application operations; rejection leaves it usable.
A server session inherits demand-driven reading when its HTTP listener selected
`read_ahead(false)` before accepting it. Yield after its last completed I/O
before encoding; all WebSocket and native operation guards still apply.

Successful encoding closes the source facade before delivery without sending
a WebSocket Close frame. The destination continues the existing protocol
session. The payload is a manually owned, same-process capability: follow the
[shared manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules),
adopting it exactly once or recovering it locally after rejected delivery. It is
not suitable for storage or another process, and dropping it leaks the detached
transport.

`Connection.discard_transfer_payload(payload: string): integer` consumes an
unadopted session payload without a Runtime by discarding its HTTP child
transport. It returns the native close status. A close attempt consumes the
payload even on an error; never adopt or discard the bytes again.

## Reader duty, closing and cancellation

`read` services Ping, matching Pong and Close while assembling data. Ping
payloads are echoed exactly. Unsolicited Pong is ignored. There is no background
reader Task or decoded-message queue.

**`ping` requires a concurrent application reader.** It sends a fresh token and
waits for the matching Pong. A write-only application must deliberately keep
reading to service controls. A Ping deadline still applies if reading stops;
expiry closes the session and raises a catchable timeout without cancelling
the calling Task.

`shutdown` defaults to code 1000 and empty reason. It stops new data writes,
sends Close, and waits for peer Close until its deadline. An active reader
keeps receive ownership until it returns one message or Close; on its release
shutdown takes receive progress and discards subsequent data while servicing
controls. New reads cannot steal that reservation. A partially completed
writer stops at the next frame boundary and reports closing. Reasons must be
valid UTF-8 and at most 123 bytes. Valid sent codes are 1000–1003, 1007–1014,
and 3000–4999; servers cannot originate 1010. A server replying to a client
1010 sends 1000. Reserved codes are rejected.

`close` is immediate, idempotent resource retirement: it needs no peer
cooperation, works with pending cancellation, and waits for accepted native
ownership to retire. It sends no promised WebSocket/TLS graceful handshake.
Use it in `defer`, even when also calling `shutdown`.

Cancellation while waiting only for an admission/frame reservation detaches
that reservation. Once transport I/O has been admitted or protocol bytes have
been consumed/emitted, cancellation terminalizes the session. An idle admitted
read follows this rule on both ws and wss. Shutdown cancellation is terminal
once closing is committed. Cleanup aborts before draining accepted work and
waits for operation scopes, never unrelated application Tasks.

## Opening policy and errors

Absent Origin is accepted for native clients. A browser Origin must be a single
valid HTTP(S) origin matching the normalized request scheme, host and effective
port, or an exact entry in `allowed_origins`. Literal `null`, malformed and
multiple origins are denied. No wildcard or forwarded-header trust is
implicit. Behind a proxy, configure the allowed public origins explicitly.
Origin policy protects browser callers from cross-site access; it does not
authenticate native clients.

Subprotocol tokens are case-sensitive. The first server-preferred offered token
wins; no intersection means no protocol. Header names and HTTP Upgrade/
Connection tokens remain case-insensitive. Empty HTTP list elements in Upgrade
and Connection are ignored within the opening header bound. Invalid or duplicate subprotocol tokens
fail, and a client rejects a protocol it did not offer. Dial headers cannot
override handshake/framing fields. Server response headers configured before
acceptance are copied and checked for those reserved fields.

For requests that reach `accept`, malformed openings receive 400, denied
origins 403, and unsupported versions
426 with `Sec-WebSocket-Version: 13`. Acceptance then raises `HandshakeError`.
A rejection commits one response and prevents a default 200 or body drain.
Invalid API options or already committed responses fail before protocol
output. A failed rejection write preserves its transport error. HTTP applies its own
validation before invoking the handler: upgrade-indicated requests with any
`Expect` field receive 400 without interim output or a handler call; missing or
duplicate or invalid Host, invalid request URLs, or unsupported HTTP versions on a completely parsed upgrade
attempt receive 400 before the handler. Invalid HTTP syntax fails during
request parsing. These paths
do not call `accept` or raise a server-side `HandshakeError`.

```text
record Error
  const kind: string       -- protocol, utf8, limit, state, timeout, abnormal
  const operation: string
  const message: string
  const close_code: integer?
end
record HandshakeError
  const message: string
  const status: integer?
  const headers: http.Headers?
end
```

Lower-level `ssl.Error`, `async.OperationError`, URL errors and cancellation
retain their identities. The first terminal failure's exact value and captured
origin traceback survive cleanup and later valid operations. Incoming protocol, UTF-8 and size failures attempt bounded
Close codes 1002, 1007 and 1009 respectively, then retire the transport.

A native connection negotiates no extensions or compression. Valid extension
offers are ignored by servers; malformed syntax fails. Clients offer none and
reject an unsolicited extension response. Nonzero RSV bits fail. HTTP/2/3,
proxies, redirects, reconnect, automatic heartbeat and streaming message
readers/writers are outside this interface.

The message limit bounds decoded-message accumulation. The existing net read
watcher can buffer immutable chunks without a high-water mark; this module's
message/scratch limits do not bound that transport queue. Nonces and each
client frame mask use synchronous public `uv.random`; entropy acquisition can
block. See [implementation and validation](../implementation/websocket-library.md),
[HTTP](standard-library-http.md), [TLS](standard-library-ssl.md), and
[async ownership](async-io.md).

## On the browser

On `--target browser`, `websocket` provides the client over the host's
`WebSocket`: `MessageType`, `TEXT`, `BINARY`, `Error`, `HandshakeError`,
`DialOptions`, `connect`, and the `Connection` methods `read`, `write`,
`shutdown`, `close`, `subprotocol`, and `close_status`, each with its native
signature. The server (`accept` and `AcceptOptions`), `Connection:ping`, and
the transfer hooks are native-only. The browser engine owns the TCP and TLS
connection, certificate trust, cookies, the `Origin` it sends, wire
fragmentation, and the Pong replies to the server's Pings.

**Opening.** `connect` needs the instance's active async Runtime. In a state
created by `lua.new()` it raises `"async Runtime is not active"`, while
`DialOptions` works there. It raises `url.Error` for a malformed URL, and a
string for a scheme other than `ws` or `wss` and for options that carry any
headers or a `ca_file`: a browser `WebSocket` sends no application headers and
trusts the browser's certificates. The browser offers the `subprotocols`,
sends its cookies and HTTP authentication with the opening request, and
negotiates `permessage-deflate` compression itself. When subprotocols were
offered and the server selects none, the browser fails the opening; a native
client instead returns a connection whose `subprotocol()` is nil. Every
failure before the connection opens, whether an HTTP rejection, an invalid
response, a DNS failure, a refused connection, or a TLS failure, raises
`HandshakeError` with message `"WebSocket opening handshake failed"` and nil
`status` and `headers`, because the browser reports them alike.
`handshake_timeout` raises `Error("timeout", "websocket.open", ...)` as
natively.

**Messages.** `read` returns complete messages in arrival order. The
`read_limit` applies to each message's length after decompression. Messages
that arrived earlier are delivered first; the message over the limit raises
`Error` with kind `"limit"`, operation `"websocket.read"`, and close code 1009,
ends the connection, and is never copied into Titan memory. The browser
applies no backpressure to messages that are not yet read, so a flood of
small messages still accumulates in memory.

`write` checks text for valid UTF-8 before sending, as natively, and yields
once so that other Tasks run between writes. It then hands the message to the
browser and, while more than 256 KiB is queued, waits until 64 KiB or less
remains. A return means that the browser accepted the message while the
connection was open and that its queue drained to that mark; it does not mean
the server received it. If the connection is closing, closed, or failed when
`write` starts, after its yield, or while it waits, `write` raises the first
failure or `Error("state", "websocket.write", ...)` instead of letting the
browser drop the message silently.

**Closing.** `shutdown(code, reason, timeout_ms)` accepts code 1000, the
default, and 3000 through 4999; a code from 1001 through 1014 or a reason over
123 bytes raises `Error("state", "websocket.shutdown", ...)`, and a reason that
is not valid UTF-8 raises `Error("utf8", "websocket.shutdown", ...)`. An
active reader still receives one message before shutdown discards later data,
as natively, and shutdown waits up to `timeout_ms` for the server's Close.

`close()` retires the connection locally, synchronously and idempotently, and
wakes waiting operations with `Error("state", ...)` or the connection's first
failure. A native close aborts the transport at once; the browser instead
sends an empty Close frame after the messages it has already queued and
finishes the closing handshake itself. Cancelling an admitted `read` ends the
connection, as does cancelling a `write` after the browser accepted its
message.

**Close status and transport loss.** A valid Close frame from the server
makes `read` return `(nil, nil)` and lets `shutdown` complete, even when the
server resets the connection immediately after it. `close_status()` then
returns the server's code and reason; an empty Close leaves both nil. A
transport loss without a Close raises `Error("abnormal", operation,
"transport ended before WebSocket Close", nil)` from the waiting operation,
later operations raise the same error, and `close_status()` stays
`(nil, nil)`. The browser reports a protocol or UTF-8 violation by the server
the same way.

| Failure | Native targets | Browser target |
| --- | --- | --- |
| Malformed URL | `url.Error` | `url.Error` |
| Scheme other than `ws` or `wss`; invalid `DialOptions`; browser `headers` or `ca_file`; no active Runtime | string | string |
| Opening deadline | `Error("timeout", "websocket.open", ..., nil)` | the same |
| HTTP rejection, invalid opening response, unselected subprotocol | `HandshakeError` with the status and headers when known | `HandshakeError(message, nil, nil)` |
| DNS, connection, or TLS failure before opening | `async.OperationError` or `ssl.Error` | `HandshakeError(message, nil, nil)` |
| Outgoing invalid UTF-8 in `write` or `shutdown` | `Error("utf8", operation, ..., nil)` | the same |
| Closed or closing connection, duplicate operation, invalid Close code, reason over 123 bytes | `Error("state", operation, ..., nil)` | the same, with the browser's code range |
| Incoming message over `read_limit` | `Error("limit", "websocket.read", ..., 1009)` | the same |
| Transport loss or peer violation after opening | `Error("abnormal", ...)`, `Error("protocol", ...)`, or `Error("utf8", ...)` | `Error("abnormal", operation, "transport ended before WebSocket Close", nil)` |
| `shutdown` deadline | `Error("timeout", "websocket.shutdown", ..., nil)` | the same |
| Task cancellation | `async.CancellationReason` | the same |
