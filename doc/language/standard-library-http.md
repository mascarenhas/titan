# HTTP/1.1 standard library

The `http` standard module provides a small streaming HTTP/1.1 client and
server. It is layered over public `net`, [`ssl`](standard-library-ssl.md),
[`url`](standard-library-url.md), [`io`](standard-library-io.md), and
[`async`](async-io.md) APIs. Titan source uses its short import:

```titan
local http = import "http"
```

The parser resolves that spelling to the canonical `titan.http` module
identity. Lua loads that identity directly with `require "titan.http"`.

All network operations and server handlers run in async Tasks. The module
supports only HTTP/1.1. It does not expose its llhttp parser or any native
socket handle.

## API

```titan
record Header
    name: string
    contents: string
end

record Headers

function headers(initial: {Header}?): Headers
function Headers:add(name: string, contents: string)
function Headers:set(name: string, contents: string)
function Headers:get(name: string): string?
function Headers:values(name: string): {string}
function Headers:remove(name: string)
function Headers:all(): {Header}

record ClientResponse
    status: integer
    reason: string
    version: string
    headers: Headers
end

function request(method: string, source_url: string,
                 supplied_headers: Headers?, body: string?,
                 ca_file: string?): ClientResponse

function get(source_url: string, supplied_headers: Headers?,
             ca_file: string?): ClientResponse

function ClientResponse:read(): string?
function ClientResponse:read_until(delimiter: string,
                                   chop: boolean?): string?
function ClientResponse:close()

type Handler = (Request, Response) -> ()

record Request
    method: string
    target: string
    url: url.Url
    version: string
    headers: Headers
end

function Request:read(): string?
function Request:read_until(delimiter: string,
                            chop: boolean?): string?

record Response

function Response:set_status(status: integer, reason: string?)
function Response:add_header(name: string, contents: string)
function Response:set_header(name: string, contents: string)
function Response:headers(): Headers
function Response:send_headers()
function Response:write(data: string)
function Response:close()

record Server

function listen(host: string, handler: Handler,
                port: integer?, backlog: integer?): Server
function listen_tls(host: string, certificate_file: string, handler: Handler,
                    private_key_file: string?, port: integer?,
                    backlog: integer?): Server
function Server:serve()
function Server:close()
```

`ClientResponse` satisfies `io.ReaderCloser`, `Request` satisfies `io.Reader`,
and `Response` satisfies both `io.Writer` and `io.Closer` through their exact
method shapes. The optional trailing arguments may be omitted. Plain `listen`
defaults to port 80, `listen_tls` defaults to port 443, and both default to a
backlog of 128. A supplied port must be in `0..65535`, where 0 requests an
ephemeral port, and a supplied backlog must be in `1..2147483647`. When
`private_key_file` is omitted, TLS reads the private key from the same PEM
bundle named by `certificate_file`; a separate key path remains supported.

## Headers

`Headers` is an insertion-ordered collection, not a Map. It preserves each
field's original spelling and duplicate fields. Names are compared with ASCII
case folding:

- `add` appends one field;
- `get` returns the first matching field, or `nil`;
- `values` returns every matching value in insertion order;
- `set` removes every matching field and appends one replacement;
- `remove` removes every matching field; and
- `all` returns a new Array of copied `Header` records.

`headers(initial)` validates and copies its input Array. A field name must be a
nonempty HTTP token. A field value may contain HTAB, SP/VCHAR, and `obs-text`,
but no other control byte or DEL. This includes rejecting NUL, carriage return,
and line feed, preventing header injection. Parsed values have surrounding SP
and HTAB removed. The field is named `contents` because `value` is a Titan
keyword.

## URLs

URL parsing and normalization belong to the standalone
[`url` standard module](standard-library-url.md). HTTP accepts exactly that
module's absolute HTTP/HTTPS subset. A client request raises the structured
`url.Error` returned by `url.parse` when its source URL is invalid; no network
operation has begun at that point. A server `Request.url` is the normalized
`url.Url` obtained from the connection scheme, required Host field, and
received origin-form target.

The HTTP client connects with `Url.host` and `Url.port`, sends `Url.target` in
the request line, and uses `Url.authority` when it generates an absent Host
field. Applications that only need to validate or inspect a URL should import
`url` directly and handle its nonthrowing `(Url?, Error?)` result.

## Client requests

`request` validates `method` as an HTTP token, parses `source_url`, chooses a
plain or TLS connection from its scheme, sends one request, and returns after
the final response headers have been parsed. For HTTPS, `ca_file` has exactly
the trust-selection behavior documented by
[`ssl.connect`](standard-library-ssl.md#verified-client-connections); it is
ignored for HTTP.

The supplied headers are copied before the module adds framing fields. There
must be at most one `Host` field. If absent, it is generated from the URL. A
supplied value must be one complete URI authority: a registered name, IPv4
address, or bracketed IP literal, followed by an optional valid port. User
information and the `/`, `?`, and `#` delimiters are rejected, so a supplied
Host cannot consume or reinterpret the separately generated request target.
The valid supplied spelling is preserved on the wire.
Client request bodies are one optional in-memory string, not a streaming
Writer. When a body is present, `Content-Length` is generated unless supplied;
an explicit length must exactly match. Request `Transfer-Encoding` is not
supported. Request `Expect` is also rejected because this initial client sends
the optional body in the same write as its preamble and does not expose a
staged `100-continue` state machine. The client always sets
`Connection: close`.

`get` is `request` with method `GET` and no body. It does not attach semantics
to any other method name.

The response parser consumes any informational 1xx responses before returning
the final response. `status`, `reason`, `version`, and `headers` are then
available while its body remains streaming. `read` returns decoded body chunks
with HTTP chunk framing removed; `read_until` has the ordinary binary
`io.Reader` delimiter contract. Content-Length, chunked, no-body, and
connection-close-delimited HTTP/1.1 responses are handled by the protocol
parser. Response trailers, when present, are appended to the same ordered
`headers` collection as parsing reaches them.

Reading through body EOF closes the parser and transport. `close()` lets the
caller discard the remaining response and is idempotent. The client has no
connection pool and never reuses its connection.

The response becomes logically closed before its transport close can suspend.
If Task cancellation prevents that call from recording completion, later
reads still return EOF and a later `close()` retries the idempotent transport
cleanup. Only a close call that returns records completion and makes every
later call a no-op.

Redirect status codes are returned unchanged; the client never follows them.
Content codings such as gzip are likewise returned unchanged. The caller owns
redirect policy and decompression.

## Servers and handlers

`listen` creates a plain `net.Server`. `listen_tls` creates an `ssl.Server`
with the given PEM certificate chain and its combined or separate private key.
The returned Server does not accept until `serve()` runs. `serve` loops until
close, accepting each connection and starting one independent async Task for
it; requests on the same persistent connection remain serial and ordered.

`Server:close()` is idempotent and stops the listener and accept loop. It does
not maintain a registry of already accepted connection Tasks, so those
connections finish or fail according to their own HTTP/transport lifecycle.
The Server becomes logically closed before the wrapped listener close can
suspend. If cancellation prevents that call from recording completion,
another `close()` retries the idempotent listener operation and releases a
blocked `serve()` call. Only a close call that returns makes later calls
immediate no-ops.

The handler is called as soon as the request line and headers are complete,
without waiting for the HTTP parser to consume the complete body.
If the request has exactly one `Expect` field whose optional surrounding
whitespace and case-insensitive value are `100-continue`, the server first
writes `HTTP/1.1 100 Continue` and then calls the handler. This lets a handler
stream a body from a client that deliberately withholds it until the interim
response arrives. Any unsupported, combined, or repeated expectation receives
a final `417 Expectation Failed` with `Content-Length: 0` and
`Connection: close`; the handler is not called and the server does not wait
for the rejected body.
`Request:read` and `read_until` stream the decoded body and hide Content-Length
and chunk framing. If the handler returns
without consuming the complete body, the server drains the remainder before
parsing the next message on that connection. Applications should impose their
own body-size policy; the module does not configure an application body limit.

For a server request:

- `method` is llhttp's canonical method spelling;
- `target` is the received origin-form path and query, before URL
  normalization;
- `url` parses and normalizes the connection's `http`/`https` scheme, the one
  required `Host` field, and that target;
- `version` is `HTTP/1.1`; and
- `headers` preserves order and duplicates.

Exactly one `Host` header is required, and only an origin-form target beginning
with `/` is accepted. Absolute-form proxy requests, authority-form `CONNECT`,
and asterisk-form requests are outside this initial server API. The Host value
must itself be an authority: user-information, path, query, and fragment
delimiters are rejected before it is combined with the separately received
target.

Each `Response` begins as `200 OK` with empty headers. `set_status` accepts a
final status from 200 through 999 and an optional reason phrase. A supplied
reason has the same permitted byte repertoire as a field value. Header and
status mutation is allowed only before headers are sent. `headers()` returns a
copy, so changing that copy does not mutate the Response.

`send_headers()` commits the status line and headers and is idempotent.
`write()` implicitly sends them, then writes one binary body chunk. When an
explicit `Content-Length` is present, writes may not exceed it and `close`
requires an exact match. A response may not combine Content-Length and
Transfer-Encoding, and the only supported response transfer coding is
`chunked`. With neither framing header, a body-capable response becomes
chunked automatically. `close()` sends the final chunk when necessary and is
idempotent. After a normal handler return, the connection Task calls `close()`
again so an omitted explicit close still commits and finishes the response.

HEAD responses and statuses 204, 205, and 304 do not permit a response body.
Writing nonempty data to one of them raises an error. A 204 response must not
include Content-Length. A 205 response must use `Content-Length: 0`; the server
adds it when absent and rejects an explicit nonzero value. Transfer-Encoding is
removed from every no-body response. A request or response `Connection: close`
decision disables reuse; otherwise HTTP/1.1 keep-alive is preserved.

The server supports ordered HTTP/1.1 request pipelining: a peer may send later
requests before reading the current response. Each connection dispatches
handlers strictly one at a time; the current handler returns, its response is
finished, and any unread request body is drained before the next handler runs.
Bytes already read beyond the current message are retained for that next
iteration. Responses remain in request order and never interleave; there is no
concurrent per-connection handler scheduler.

If a handler raises or parsing/framing fails, that connection Task terminates
and its connection closes. Other accepted connection Tasks and the listening
Server remain independent.

## Strictness and limits

Parsing uses llhttp in strict mode. Malformed or truncated messages,
conflicting framing, unsupported HTTP versions, and protocol upgrades are
errors. HTTP/2, WebSockets, and every other Upgrade protocol are out of scope.
The server has no routing abstraction: one Handler receives every request and
can dispatch on `Request.url`, `Host`, method, or path itself.

Headers are accumulated before a request or response object is returned, and
this version configures no header-byte or field-count limit. A handler can
reject the parsed collection but cannot impose a pre-parse cap through this
API. Body data remains streaming, so the handler can impose its own accepted
body size while reading. Deployments that require an earlier header cap must
enforce it outside this Server abstraction.

Persistent connections have no library-owned idle timeout. Titan's current
public async facade can create/cancel Tasks and wait on timers, but it has no
current-Task accessor, join, race, or deadline primitive. Implementing a safe
timeout entirely in `titan.http` would therefore require a connection-local
watchdog plus generation fencing rather than simple high-level composition.
This is a known API blocker, not a reason for HTTP to reach into or modify the
private `titan.uv` substrate. Applications that require an idle deadline must
currently enforce it outside this Server abstraction or close connections by
another policy.

## Example

```titan
local async = import "async"
local http = import "http"

local function handler(request: http.Request, response: http.Response)
  response:set_header("Content-Type", "text/plain")
  response:write(request.method .. " " .. request.url.path .. "\n")
  response:close()
end

local function run_server(): value
  local server = http.listen("127.0.0.1", handler, 8080)
  defer server:close()
  server:serve()
  return nil
end

function main(args: {string}): integer
  async.run(run_server)
  return 0
end
```

The default build always bundles the pinned llhttp 9.4.3 parser into the
coordinated standard provider. The HTTP module introduces no system-llhttp
mode.
