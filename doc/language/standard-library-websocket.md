# WebSocket messages

Import `websocket` for RFC 6455 WebSocket version 13 over HTTP/1.1. Calls look
blocking and suspend their current Task. Both `ws` and verified `wss` clients
are supported. The server accepts inside an ordinary `http.Handler`, including
handlers passed to `http.listen_tls`.

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
Connection:subprotocol(): string?
Connection:close_status(): (integer?, string?)
```

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
read limit and unread WebSocket, HTTP upgrade and TCP/TLS bytes. Its private
protobuf schema contains copied WebSocket state and the known HTTP child bytes.
If outer serialization fails after the child detaches, the hook closes the
detached transport and leaves the source terminal.

Transfer rejects pending reader, writer, Ping, Pong, Close, shutdown or
retirement work, and rejects a closing or terminal session. An operation remains
pending until its public call finishes, including cancellation and deadline
cleanup after internal work completes. Its transport must
also satisfy the [TCP](standard-library-net.md#transferring-connections) and,
for `wss`, [TLS](standard-library-ssl.md#transferring-connections) idle rules.
The persistent Windows overlapped read normally makes an established session
ineligible even between application operations; rejection leaves it usable.

Successful encoding closes the source facade before delivery without sending
a WebSocket Close frame. The destination continues the existing protocol
session. Adopt the payload exactly once, or recover it locally after rejected
delivery. Replaying it can double close or access freed resources; dropping it
leaks the detached transport. No automatic replay protection, finalizer or
delivery rollback is provided. The representation is not suitable for storage
or another process.

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

Extensions and compression are not negotiated. Valid extension offers are
ignored by servers; malformed syntax fails. Clients offer none and reject an
unsolicited extension response. Nonzero RSV bits fail. HTTP/2/3, proxies,
redirects, reconnect, automatic heartbeat and streaming message readers/
writers are outside this interface.

The message limit bounds decoded-message accumulation. The existing net read
watcher can buffer immutable chunks without a high-water mark; this module's
message/scratch limits do not bound that transport queue. Nonces and each
client frame mask use synchronous public `uv.random`; entropy acquisition can
block. See [implementation and validation](../implementation/websocket-library.md),
[HTTP](standard-library-http.md), [TLS](standard-library-ssl.md), and
[async ownership](async-io.md).
