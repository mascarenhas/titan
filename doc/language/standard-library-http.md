# HTTP/1.1 standard library

The qualified `titan.http` standard module provides a small streaming HTTP/1.1
client and server. It is layered over public `titan.net`, [`titan.ssl`](standard-library-ssl.md),
[`io`](standard-library-io.md), and [`async`](async-io.md) APIs; its URL grammar
uses the public `titan.peg` module. Titan source imports it with its full name:

```titan
local http = import "titan.http"
```

Lua loads the same canonical module identity with `require "titan.http"`.
There is deliberately no short `import "http"` spelling.

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

record URL
    scheme: string
    host: string
    port: integer
    path: string
    query: string?
    target: string
end

function parse_url(source: string): URL
function URL:host_header(): string

record ClientResponse
    status: integer
    reason: string
    version: string
    headers: Headers
end

function request(method: string, source_url: string,
                 supplied_headers: Headers?, body: string?,
                 ca_file: string?,
                 ca_directory: string?): ClientResponse

function get(source_url: string, supplied_headers: Headers?,
             ca_file: string?,
             ca_directory: string?): ClientResponse

function ClientResponse:read(): string?
function ClientResponse:read_until(delimiter: string,
                                   chop: boolean?): string?
function ClientResponse:close()

type Handler = (Request, Response) -> ()

record Request
    method: string
    target: string
    url: URL
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

function listen(host: string, port: integer, backlog: integer,
                handler: Handler): Server
function listen_tls(host: string, port: integer, backlog: integer,
                    certificate_file: string,
                    private_key_file: string,
                    handler: Handler): Server
function Server:serve()
function Server:close()
```

`ClientResponse` satisfies `io.ReaderCloser`, `Request` satisfies `io.Reader`,
and `Response` satisfies both `io.Writer` and `io.Closer` through their exact
method shapes. The optional trailing arguments may be omitted.

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

`parse_url` accepts only an absolute `http://` or `https://` URL with an
authority and nonempty host. It returns the normalized scheme, connection
host, effective port, path, optional query, and origin-form `target` (`path`
plus `?query`). The default ports are 80 and 443. An explicit port must contain
decimal digits and have value `1..65535`; its spelling in `host_header()` is
the canonical decimal value. An explicitly written port remains present even
when it equals the scheme's default. An empty path becomes `/`, while an empty
query remains present and makes the target end in `?`.

The host grammar accepts RFC 3986 registered names, IPv4 addresses, bracketed
IPv6 addresses, and bracketed IPvFuture literals. IPv6 zone identifiers use
the RFC 6874 `%25` separator. Unbracketed IPv6 authorities are rejected.
For an IP literal, public `URL.host` omits URI brackets because it is the
spelling passed to DNS/TCP and TLS identity handling; `host_header()` restores
the brackets. A zoned address such as `[fe80::1%25eth0]` therefore has
`host == "fe80::1%eth0"` and keeps `[fe80::1%25eth0]` in the Host authority.

Normalization lowercases the scheme and registered-name host. In the host,
path, query, and zone identifier, a percent-encoded unreserved byte is decoded;
every retained escape keeps its meaning but uses uppercase hexadecimal digits.
Thus `%5f` becomes `_`, while encoded `/` remains `%2F`. IPv6 hexadecimal and
the IPvFuture version prefix are canonicalized to lowercase; an IPvFuture
suffix and zone-identifier letters otherwise retain their case.

User information and fragments are deliberately unsupported. Malformed
schemes, separators, authorities, IP literals, ports, percent escapes, paths,
and queries raise a stable diagnostic of the form:

```text
HTTP URL parse error [label] at byte N: detail
```

`N` is a one-based byte position in the supplied string. The label identifies
the rejected production or policy boundary, such as `userinfo`, `fragment`,
`ipv6_brackets`, `port`, or `percent_escape`.

`host_header()` returns the normalized authority, including brackets for an
IP literal and an explicit canonicalized port. The HTTP client uses the
normalized `target` for its request line and this authority when it generates
an absent `Host` field.

## Client requests

`request` validates `method` as an HTTP token, parses `source_url`, chooses a
plain or TLS connection from its scheme, sends one request, and returns after
the final response headers have been parsed. For HTTPS, `ca_file` and
`ca_directory` have exactly the trust-selection behavior documented by
[`ssl.connect`](standard-library-ssl.md#verified-client-connections); they are
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

Redirect status codes are returned unchanged; the client never follows them.
Content codings such as gzip are likewise returned unchanged. The caller owns
redirect policy and decompression.

## Servers and handlers

`listen` creates a plain `net.Server`. `listen_tls` creates an `ssl.Server`
with the given PEM certificate chain and private key. The returned Server does
not accept until `serve()` runs. `serve` loops until close, accepting each
connection and starting one independent async Task for it; requests on the
same persistent connection remain serial and ordered.

`Server:close()` is idempotent and stops the listener and accept loop. It does
not maintain a registry of already accepted connection Tasks, so those
connections finish or fail according to their own HTTP/transport lifecycle.

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
decision disables reuse; otherwise HTTP/1.1 keep-alive is preserved. The parser
retains bytes after one message, so correctly ordered pipelined requests are
processed in sequence on the same connection.

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
local http = import "titan.http"

local function handler(request: http.Request, response: http.Response)
  response:set_header("Content-Type", "text/plain")
  response:write(request.method .. " " .. request.url.path .. "\n")
  response:close()
end

local function run_server(): value
  local server = http.listen("127.0.0.1", 8080, 128, handler)
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
