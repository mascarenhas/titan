# WebSocket standard library

The `websocket` module provides message-oriented RFC 6455 (version 13) WebSocket clients over `ws`/`wss` and HTTP/1.1 server upgrades natively, and a host-`WebSocket` client on the browser target. Import it in Titan with `local websocket = import "websocket"` or load it in Lua with `require "titan.websocket"`.

**Target availability:** Native & Browser (client API on both targets; `accept`, `AcceptOptions`, `Connection:ping`, and connection transfer are native-only — see [On the browser](#on-the-browser)).

## Examples

### HTTP upgrade echo server

```titan
local http = import "http"
local websocket = import "websocket"

local function handler(request: http.Request, response: http.Response)
  if request.url.path ~= "/echo" then
    response:set_status(404)
    return
  end
  local conn = websocket.accept(request, response)
  defer conn:close()
  while true do
    local kind?, message? = conn:read()
    if kind == nil then break end
    conn:write(kind, message)
  end
end

function serve_echo(host: string, port: integer)
  local server = http.listen(host, handler, port, nil, 10000)
  defer server:close()
  server:serve()
end
```

### Verified client exchange

```titan
local websocket = import "websocket"

function echo_once(target_url: string, ca_file: string?,
                   payload: string): string?
  local conn = websocket.connect(target_url,
    websocket.DialOptions { ca_file = ca_file })
  defer conn:close()
  conn:write(websocket.TEXT, payload)
  local kind?, reply? = conn:read()
  if kind == nil then return nil end
  conn:shutdown()
  return reply
end
```

## Core concepts

All WebSocket operations run inside [`async.Task`](async-io.md#scheduling-and-driving-tasks)s and suspend only the current Task.

- Authenticate and authorize routes in your `http.Handler` before calling `websocket.accept` (which works identically under `http.listen` and `http.listen_tls`). Once accepted, HTTP transfers stream ownership to the WebSocket session: immediately `defer conn:close()` (or transfer ownership to another Task). Closing the HTTP `Server` stops new accepts without closing upgraded WebSocket sessions.
- `connect` always verifies TLS certificates against the original URL hostname (even when dialing a resolved IP); `ca_file` replaces OpenSSL's default trust roots, matching [`ssl`](standard-library-ssl.md#verified-client-connections). There is no insecure TLS mode or automatic HTTP redirect.
- One application reader and one application writer may progress concurrently on both `ws` and `wss`. Duplicate concurrent readers, writers, `ping` calls, or `shutdown` calls raise immediately.

## Public interface

```text
union MessageType
  text() | binary()
end
const TEXT: MessageType
const BINARY: MessageType

record Connection

record DialOptions
function DialOptions.new(headers: http.Headers?, ca_file: string?,
                         subprotocols: ({string})?, read_limit: integer?,
                         handshake_timeout: integer?): DialOptions

record AcceptOptions -- native only
function AcceptOptions.new(subprotocols: ({string})?,
                           allowed_origins: ({string})?,
                           read_limit: integer?,
                           handshake_timeout: integer?): AcceptOptions

function connect(source_url: string, options: DialOptions?): Connection
function accept(request: http.Request, response: http.Response,
                options: AcceptOptions?): Connection -- native only

function Connection:read(): (MessageType?, string?)
function Connection:write(kind: MessageType, data: string)
function Connection:ping(timeout_ms: integer?) -- native only
function Connection:shutdown(code: integer?, reason: string?, timeout_ms: integer?)
function Connection:close()
function Connection:subprotocol(): string?
function Connection:close_status(): (integer?, string?)
```

- **Option defaults and validation:** `DialOptions` and `AcceptOptions` validate positive limits/deadlines and copy supplied headers and arrays. Defaults: **1 MiB** incoming `read_limit`, **10 seconds** `handshake_timeout`, and **5 seconds** for `ping`, `shutdown`, and automatic control output. Deadlines trigger abort and safe cleanup (native DNS/connect/write callback retirement may extend return latency slightly beyond the nominal deadline).
- **Messages:** `read()` delivers one complete text or binary message (`""` is a valid message; binary preserves NUL bytes). `(nil, nil)` signals a valid peer Close after reciprocal handling completed; TCP EOF or TLS loss before a valid Close raises an abnormal error instead of returning `(nil, nil)`. `close_status()` returns the peer's Close `(code?, reason?)` (`(nil, nil)` for an empty Close; `(code, "")` for a code with no reason; local abnormal closure never synthesizes wire code `1006`).
- **Writing & framing:** Outgoing messages fragment at up to 16 KiB per frame so control frames can interleave between data frames without interleaving two data messages. Text messages validate UTF-8 on both send and receive (across chunks and fragments).

## Reader duty, closing and cancellation

- **`read()` services control frames:** There is no background reader Task or decoded-message queue. `read()` echoes incoming Ping payloads, matches incoming Pong replies, and handles incoming Close frames while assembling data messages (unsolicited Pong is ignored).
- **`ping(timeout_ms?)` requires a concurrent reader:** `ping` sends a fresh token and waits for `read()` to observe the matching Pong. A write-only application must keep a reader Task calling `read()`. If `timeout_ms` expires, `ping` closes the session and raises a catchable timeout `Error` without cancelling the calling Task.
- **`shutdown(code?, reason?, timeout_ms?)`:** Defaults to code `1000` and reason `""`. It stops new data writes, sends a Close frame, and waits for the peer's Close up to `timeout_ms`. An active `read()` keeps receive ownership until it returns one message or Close, then hands receive progress to `shutdown` (which discards further data while servicing controls). Reasons must be valid UTF-8 and at most 123 bytes. Valid native codes are `1000..1003`, `1007..1014`, and `3000..4999` (servers cannot initiate `1010` and reply to a client `1010` with `1000`; reserved codes are rejected).
- **`close()`:** Immediate, idempotent, cancellation-insensitive resource retirement without waiting for peer Close or TLS `close_notify`. Always use `defer conn:close()` even when also calling `shutdown()`.
- **Cancellation:** Cancelling while waiting solely for admission detaches the reservation; once transport I/O has been admitted (including an idle `read()` on `ws` or `wss`) or protocol bytes have been consumed/emitted, cancellation aborts and terminalizes the session.

## Opening policy and errors

```text
record Error
  const kind: string       -- "protocol", "utf8", "limit", "state", "timeout", "abnormal"
  const operation: string
  const message: string
  const close_code: integer?
end
function Error.new(kind: string, operation: string,
                   message: string, close_code: integer?): Error

record HandshakeError
  const message: string
  const status: integer?
  const headers: http.Headers?
end
function HandshakeError.new(message: string, status: integer?,
                            headers: http.Headers?): HandshakeError
```

- **Origin policy (`AcceptOptions.allowed_origins`):** Native clients sending no `Origin` are accepted. A browser `Origin` must be a single valid HTTP(S) origin matching the normalized request scheme, host, and effective port, or an exact entry in `allowed_origins` (`"null"`, malformed, and multiple origins are rejected; behind a reverse proxy, list public origins explicitly without wildcards).
- **Subprotocols & headers:** Subprotocol tokens are **case-sensitive** (first server-preferred match wins; invalid or duplicate tokens fail; clients reject unselected/unoffered protocols). Dial headers and pre-accept response headers cannot override reserved handshake/framing fields.
- **Rejection responses:** Inside `accept`, malformed openings send `400`, denied origins `403`, and unsupported versions `426` (`Sec-WebSocket-Version: 13`), then raise `HandshakeError` without running a default `200` or body drain. Pre-handler HTTP errors (upgrade with `Expect`, bad/missing/duplicate `Host`, bad URL, or non-1.1 version) emit `400` before the handler runs and do not raise `HandshakeError`.
- **Error preservation & native scope:** Underlying `ssl.Error`, `async.OperationError`, `url.Error`, and `async.CancellationReason` keep their exact identities and original tracebacks through cleanup. Incoming protocol, UTF-8, and size violations attempt bounded Close codes `1002`, `1007`, and `1009` before retiring the transport. Native connections negotiate no extensions or compression (rejecting unsolicited extensions and nonzero RSV bits), generate client masks via synchronous `uv.random`, and do not cap the underlying `net` receive buffer independently of `read_limit`.

## Transferring connections

*(Native only.)*

```text
function Connection:to_transfer_payload(): string
function Connection.from_transfer_payload(payload: string): Connection
function Connection.discard_transfer_payload(payload: string): integer
```

An idle open `Connection` moves between independent Lua states in the same process via `async.TransferValue.from_value(conn)` and `packet:to_value()`, preserving client/server role, selected subprotocol, `read_limit`, and unread WebSocket/HTTP/TCP/TLS bytes.

- Transfer rejects active readers, writers, Ping/Pong/Close/shutdown work, closing/terminal sessions, and any [TCP](standard-library-net.md#transferring-connections) or [TLS](standard-library-ssl.md#transferring-connections) transfer restriction (configure `server:read_ahead(false)` on the HTTP listener before serving and call `async.yield()` after the last I/O before encoding on Windows). Rejected transfer leaves the session usable.
- Encoding closes the source facade without sending a WebSocket Close frame; if enclosing serialization fails after transport detachment, the hook closes the detached transport. Follow the [shared manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules). `Connection.discard_transfer_payload(payload)` closes an unadopted payload without a Runtime, returning native close status and consuming ownership even on error.

## On the browser

On `--target browser`, `websocket` provides the client over the host's `WebSocket`: `MessageType`, `TEXT`, `BINARY`, `Error`, `HandshakeError`, `DialOptions`, `connect`, and `Connection`'s `read`, `write`, `shutdown`, `close`, `subprotocol`, and `close_status`. `accept`, `AcceptOptions`, `Connection:ping`, and transfer hooks are absent at compile time. The browser owns TCP/TLS, certificates, cookies, `Origin`, wire fragmentation, Pong replies, and `permessage-deflate`.

- **Opening:** `connect` requires the instance's owner `async` Runtime (`"async Runtime is not active"` in a `lua.new()` state), raises `url.Error` for malformed URLs, and raises a string for non-`ws`/`wss` schemes or `DialOptions` carrying `headers` or `ca_file`. When `subprotocols` are offered and the server selects none (or selects an unoffered token), opening fails on every engine (unlike native clients, which allow `subprotocol() == nil` when none is selected). Every pre-open failure (HTTP rejection, DNS, refusal, TLS) raises `HandshakeError(message, nil, nil)` (`"WebSocket opening handshake failed"` for HTTP rejection); `handshake_timeout` raises `Error("timeout", "websocket.open", ..., nil)`. Connections close automatically with their Runtime.
- **Messages:** `read_limit` applies to decompressed message length; an oversized message raises `Error("limit", "websocket.read", ..., 1009)` without copying it into Titan memory (unread small messages are not backpressured by the browser). `write` validates UTF-8, yields once, hands the message to the browser, and pauses while more than 256 KiB is queued until 64 KiB or less remains. Returning means the browser accepted the message while open, not server delivery; loss notification can lag queue drainage on Node and WebKit, so a subsequent write raises once loss is reported.
- **Closing:** `shutdown(code?, reason?, timeout_ms?)` accepts only `1000` and `3000..4999` (codes `1001..1014` or reasons >123 bytes raise `Error("state", "websocket.shutdown", ...)`; invalid UTF-8 raises `"utf8"`). `close()` retires the connection locally and synchronously, waking waiters with `Error("state", ...)` or the first failure, while the browser sends an empty Close after queued writes. Cancelling an admitted `read` or post-send `write` ends the connection. (Firefox may retain a cancelled/timed-out opening's TCP socket until handshake completion or browser close, and Node may retain a rejected opening's TCP socket until the peer closes.)
- **Close status and transport loss:** A valid server Close makes `read()` return `(nil, nil)` and populates `close_status()` even if followed immediately by a TCP reset. Transport loss or server protocol/UTF-8 violations without Close raise `Error("abnormal", operation, "transport ended before WebSocket Close", nil)` and leave `close_status()` at `(nil, nil)`.

| Failure | Native targets | Browser target |
| --- | --- | --- |
| Malformed URL | `url.Error` | `url.Error` |
| Non-`ws`/`wss` scheme; invalid `DialOptions`; browser `headers`/`ca_file`; no active Runtime | `string` | `string` |
| Opening timeout | `Error("timeout", "websocket.open", ..., nil)` | Same |
| HTTP rejection, invalid response, unoffered subprotocol | `HandshakeError` with status/headers when known | `HandshakeError(message, nil, nil)` |
| Subprotocols offered, none selected | Connection with `subprotocol() == nil` | `HandshakeError(message, nil, nil)` |
| Pre-open DNS, connect, or TLS failure | `async.OperationError` or `ssl.Error` | `HandshakeError(message, nil, nil)` |
| Outgoing invalid UTF-8 in `write`/`shutdown` | `Error("utf8", operation, ..., nil)` | Same |
| Closed/closing, duplicate op, invalid Close code, reason >123 bytes | `Error("state", operation, ..., nil)` | Same (codes `1000`, `3000..4999`) |
| Incoming message over `read_limit` | `Error("limit", "websocket.read", ..., 1009)` | Same |
| Post-open transport loss or peer violation | `Error("abnormal" \| "protocol" \| "utf8", ...)` | `Error("abnormal", operation, "transport ended before WebSocket Close", nil)` |
| `shutdown` deadline | `Error("timeout", "websocket.shutdown", ..., nil)` | Same |
| Task cancellation | `async.CancellationReason` | Same |
