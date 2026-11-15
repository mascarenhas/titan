# HTTP/1.1 standard library

The `http` standard module provides a small streaming HTTP/1.1 client and
server. On native targets it is layered over public `net`,
[`ssl`](standard-library-ssl.md), [`url`](standard-library-url.md),
[`io`](standard-library-io.md), and [`async`](async-io.md) APIs. On the
browser target the same client API runs over the host's `fetch`; servers,
protocol upgrades, and connection handoff are native-only (see
[on the browser](#on-the-browser)). Titan source uses its short import:

```titan
local http = import "http"
```

The parser resolves that spelling to the canonical `titan.http` module
identity. Lua loads that identity directly with `require "titan.http"`.

All network operations and server handlers run in async Tasks. The native
client and server support only HTTP/1.1. The module does not expose its
llhttp parser, any native socket handle, or any browser `fetch` object.

## API

```text
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

union CacheMode
    default()
    no_store()
    reload()
    no_cache()
    force_cache()
    only_if_cached()
end

union CredentialsMode
    omit()
    same_origin()
    include()
end

union RequestMode
    cors()
    no_cors()
    same_origin()
end

union RedirectMode
    follow()
    error()
    manual()
end

record RequestOptions -- opaque; construct with RequestOptions.new
function RequestOptions.new(headers: Headers?, body: string?, ca_file: string?,
                            cache: CacheMode?, credentials: CredentialsMode?,
                            mode: RequestMode?,
                            redirect: RedirectMode?): RequestOptions

record ClientResponse
    status: integer
    reason: string
    headers: Headers
    url: string?
    redirected: boolean
end

record Client
function Client.new(): Client
function Client:request(method: string, source_url: string,
                        options: RequestOptions?): ClientResponse
function Client:get(source_url: string,
                    options: RequestOptions?): ClientResponse
function Client:close_idle_connections()
function Client:close()
function close_idle_connections()

function request(method: string, source_url: string,
                 options: RequestOptions?): ClientResponse

function get(source_url: string, options: RequestOptions?): ClientResponse

function request_upgrade_on(connection: io.ReaderWriterCloser,
                            abort: function (): (), source_url: string,
                            protocol: string,
                            supplied_headers: Headers?): ClientResponse

function ClientResponse:read(): string?
function ClientResponse:read_until(delimiter: string,
                                   chop: boolean?): string?
function ClientResponse:close()
function ClientResponse:take_upgrade(): io.ReaderWriterCloser

type Handler = function (Request, Response): ()

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
function Response:abort()
function Response:upgrade(request_value: Request, protocol: string,
                          supplied_headers: Headers?): io.ReaderWriterCloser
function Response:reject_upgrade(request_value: Request, status: integer,
                                 supplied_headers: Headers?)

record Server

function listen(host: string, handler: Handler,
                port: integer?, backlog: integer?,
                idle_timeout: integer?, reuse_port: boolean?): Server
function listen_tls(host: string, certificate_file: string, handler: Handler,
                    private_key_file: string?, port: integer?,
                    backlog: integer?, idle_timeout: integer?,
                    reuse_port: boolean?): Server
function Server:idle_timeout(timeout: integer?): integer
function Server:header_limit(limit: integer?): integer
function Server:serve()
function Server:read_ahead(enabled: boolean?): boolean
function Server:close()
```

`ClientResponse` satisfies `io.ReaderCloser`, `Request` satisfies `io.Reader`,
and `Response` satisfies both `io.Writer` and `io.Closer` through their exact
method shapes. The optional trailing arguments may be omitted. Plain `listen`
defaults to port 80, `listen_tls` defaults to port 443, and both default to a
backlog of 128. `reuse_port` defaults to false on both constructors. Setting it
to true forwards libuv's `UV_TCP_REUSEPORT` to the underlying TCP bind, through
`ssl.listen` for HTTPS. All listeners sharing a local address and port must
opt in. Platform restrictions and errors are the same as
[`net.listen`](standard-library-net.md#connecting-and-listening): unsupported
systems, including macOS and Windows, raise `async.OperationError` named
`"ENOTSUP"`. Closing one listener leaves the others independent. This supports
one server per independent Lua state or process; it does not change a single
Runtime's cooperative Task scheduling.

The server idle timeout defaults to 0, meaning no deadline. A
supplied port must be in `0..65535`, where 0 requests an ephemeral port, and a
supplied backlog must be in `1..2147483647`. A supplied idle timeout is in
milliseconds and must be non-negative. It is validated before opening a
listener or reading TLS PEM input. When `private_key_file` is omitted, TLS
reads the private key from the same PEM bundle named by `certificate_file`; a
separate key path remains supported.

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
`url.Url` returned by `url.parse_request` from the connection scheme, required
Host field, and received origin-form target.

The native HTTP client connects with `Url.host` and `Url.port`, sends
`Url.target` in the request line, and uses `Url.authority` when it generates
an absent Host field. Applications that only need to validate or inspect a URL
should import `url` directly and handle its nonthrowing `(Url?, Error?)`
result.

## Client requests

`request(method, source_url, options)` validates `method` as an HTTP token,
parses `source_url`, applies the [request options](#request-options), sends
one request, and returns after the final response headers have been parsed.
`options` is an optional `RequestOptions` snapshot; omitting it selects every
default. A native client chooses a plain or TLS connection from the URL's
scheme. Method names are case-sensitive; only exact `HEAD` selects
response-to-HEAD framing.

```titan
local http = import "http"

function post_form(source: string, form: string): integer
  local supplied = http.headers()
  supplied:add("Content-Type", "application/x-www-form-urlencoded")
  local response = http.request("POST", source, http.RequestOptions {
    headers = supplied, body = form,
  })
  defer response:close()
  return response.status
end
```

The `headers` option is copied when the options are constructed, and the
native client copies it again before adding framing fields. A native request
has at most one `Host` field. If absent, it is generated from the URL. A supplied
value must be one complete URI authority: a registered name, IPv4 address, or
bracketed IP literal, followed by an optional valid port. User information
and the `/`, `?`, and `#` delimiters are rejected, so a supplied Host cannot
consume or reinterpret the separately generated request target. These
failures raise the structured `url.Error` returned by `url.parse_request`. The
valid supplied spelling is preserved on the wire. The `body` option is one
in-memory string, not a streaming Writer. When a body is present,
`Content-Length` is generated unless supplied; an explicit length must
exactly match. Request `Transfer-Encoding` is not supported. Request `Expect`
is also rejected because the native client sends the optional body in the
same write as its preamble and does not expose a staged `100-continue` state
machine. HTTP/1.1 connections are persistent by default. A supplied
`Connection: close` is preserved and disables reuse for that exchange.

`get(source_url, options)` is `request` with method `GET`. It rejects options
that carry a body, even an empty one, with `"HTTP get does not accept a
request body"`; a native `request("GET", ...)` still sends a supplied body. It
does not attach semantics to any other method name.

The ordinary response parser consumes informational 1xx responses before
returning the final response. Its `status`, `reason`, `headers`, `url`, and
`redirected` fields are then available while its body remains streaming.
`url` is the normalized URL of the exchange that produced the response, which
is the last one when redirects were followed, or `nil` when the browser hides
it (see [on the browser](#on-the-browser)). `redirected` is true when at least
one redirect was followed. `read` returns decoded body chunks with HTTP chunk
framing removed; `read_until` has the ordinary binary `io.Reader` delimiter
contract. Content-Length, chunked, no-body, and connection-close-delimited
HTTP/1.1 responses are handled by the protocol parser. Response trailers,
when present, are appended to the same ordered `headers` collection as
parsing reaches them.

Reading through body EOF closes the response and makes a healthy persistent
connection available for reuse. Always defer `response:close()` immediately:
callers that stop reading early still own closing the response. Close is
idempotent; later reads return nil.

### Request options

`RequestOptions.new` validates and copies the options of a request. Call it
through the record, usually with named arguments, as in
`http.RequestOptions { headers = supplied, redirect = http.RedirectMode.follow() }`:

| Option | Meaning | `nil` selects |
| --- | --- | --- |
| `headers` | application request headers, copied | no headers |
| `body` | one in-memory, binary-safe request body | no body |
| `ca_file` | PEM trust file for native HTTPS | the default trust paths |
| `cache` | a `CacheMode` | `default()` |
| `credentials` | a `CredentialsMode` | `same_origin()` |
| `mode` | a `RequestMode` | `cors()` |
| `redirect` | a `RedirectMode` | `manual()` on native targets, `follow()` on the browser |

The record is opaque: its fields are private and never change after
construction. Changing the caller's `Headers` afterwards does not reach the
copy, and no request changes it either, because redirect handling works on its
own copy of the headers. One `RequestOptions` can serve any number of
requests and Clients. The constructor raises `"HTTP cache mode
'only-if-cached' requires request mode 'same-origin'"` when `cache` is
`only_if_cached()` and `mode` is not explicitly `same_origin()`; a `nil` mode
counts as `cors()`.

The four mode unions are closed sets of variants without payloads, named after
the [Fetch standard's](https://fetch.spec.whatwg.org/#requestinit) `RequestInit`
values (`no_store()` for `"no-store"`, `same_origin()` for `"same-origin"`, and
so on). Each call to a variant constructor creates a new value, and union
equality compares identity, so `http.CacheMode.reload() ==
http.CacheMode.reload()` is false. Inspect a mode with `case`:

```titan
local http = import "http"

function cache_label(mode: http.CacheMode): string
  case mode
  when default() then return "default"
  when no_store() then return "no-store"
  when reload() then return "reload"
  when no_cache() then return "no-cache"
  when force_cache() then return "force-cache"
  when only_if_cached() then return "only-if-cached"
  end
end
```

Each target applies the modes as its platform does. A native target behaves
like a browser with an empty HTTP cache, no cookie jar, and no CORS:

- **`cache`.** `default()`, `no_store()`, `reload()`, `no_cache()`, and
  `force_cache()` perform an ordinary network exchange and store nothing.
  `only_if_cached()` always misses: it raises `async.OperationError` named
  `"EIO"` with operation `"http.request"` and message `"HTTP response not in
  cache (only-if-cached)"` before opening a connection.
- **`credentials`.** No variant adds cookies or HTTP authentication; the
  request carries only the headers the application supplied.
- **`mode`.** `no_cors()` admits only the methods `GET`, `HEAD`, and `POST`,
  compared ASCII case-insensitively, and raises `"HTTP request mode 'no-cors'
  allows only GET, HEAD, or POST"` before any I/O. The browser applies the
  same check. Native targets enforce no CORS, so every mode otherwise
  performs an ordinary exchange.
- **`ca_file`.** For HTTPS it has exactly the trust-selection behavior
  documented by
  [`ssl.connect`](standard-library-ssl.md#verified-client-connections), on
  every HTTPS hop of a followed redirect chain. Plain HTTP ignores it.
- **`redirect`.** See [redirects](#redirects).

The browser applies `cache`, `credentials`, and `mode` through `fetch`, and
rejects a `ca_file`; see [on the browser](#on-the-browser).

### Redirects

The redirect statuses are 301, 302, 303, 307, and 308. The redirect mode
decides the outcome of every response with one of these statuses, whether or
not it carries a `Location` field; any other status returns normally.

- **`manual()`**, the native default, returns the redirect response itself.
  On a native target that is the received response: its 3xx status, reason,
  headers (with or without `Location`), a readable body, `url` naming the
  requested URL, and `redirected` false. On the browser it is the
  opaque-redirect response described in [on the browser](#on-the-browser).
- **`error()`** closes the response and raises `async.OperationError` named
  `"EIO"` with operation `"http.request"` and message `"HTTP redirect
  disallowed by RedirectMode.error"`, on both targets.
- **`follow()`**, the browser default, requests the `Location` target and
  returns the first response that is not followed, with `url` naming its URL
  and `redirected` true. A native target follows the rules of the
  [Fetch standard](https://fetch.spec.whatwg.org/#http-redirect-fetch):
  - A redirect response without `Location` is returned as it is.
  - A response with several `Location` fields, a 21st redirect after twenty
    followed ones, or a `Location` that cannot be followed raises
    `async.OperationError` named `"EIO"` with operation `"http.request"`.
  - `Location` loses surrounding spaces and tabs and any `#fragment`, and is
    resolved against the current URL as an RFC 3986 reference: absolute,
    network-path (`//host/path`), absolute-path, relative-path, and
    query-only references work, and `.` and `..` segments are removed. A
    target with a scheme other than `http` or `https`, user information, or
    no authority, or one that the `url` module rejects, cannot be followed.
  - Each intermediate response is closed through the ordinary
    `ClientResponse:close()`, with its bounded drain, before the next request,
    and cancellation is checked between hops.
  - A 301 or 302 response to `POST`, and a 303 response to a method other than
    `GET` or `HEAD`, change the next request to a bodyless `GET` and remove its
    `Content-Encoding`, `Content-Language`, `Content-Location`,
    `Content-Type`, and `Content-Length` headers. These method names compare
    ASCII case-insensitively. 307 and 308 keep the method and body.
  - When a hop changes origin, the `Authorization`, `Proxy-Authorization`,
    `Cookie`, `Cookie2`, and `Host` headers are removed for the rest of the
    chain, even if a later hop returns to the first origin. Origins compare
    normalized scheme, host, and effective port, so `HTTP://Example.COM:80/`
    and `http://example.com/` are one origin. A change from `https` to
    `http` changes the origin and is followed.

### Connection pools and early close

On native targets, module-level `get` and `request` share a default connection
pool within the current async Runtime. `http.Client()` creates an independent
pool with the same request methods. Use an explicit Client when a component
needs its own connection lifetime:

```titan
local http = import "http"
local string = import "string"

function fetch_pair(first: string, second: string): (string, string)
  local client = http.Client()
  defer client:close()
  local fetch = function (source: string): string
    local response = client:get(source)
    defer response:close()
    local output = string.writer()
    while true do
      local chunk? = response:read()
      if chunk == nil then return output:drain() end
      output:write(chunk)
    end
  end
  return fetch(first), fetch(second)
end
```

For repeated requests, retain that Client across the calls and close it when
the component finishes. A Client binds to the Runtime of its first request; construction alone
does not require a Runtime. The default helpers select a fresh pool in a later Runtime session.
Connections are never shared across schemes, normalized URL hosts and ports,
effective Host headers, or HTTPS CA-file selections. HTTP ignores `ca_file`.
A CA-file selection is the supplied path spelling, not a snapshot of its
contents; close the pool before changing trust files or default trust settings.

Only idle connections are shared. A response being read or drained holds its
connection exclusively; another request can open a new connection immediately.
There is no pipelining or limit on active requests. Each pool retains at most
100 idle connections in total and two for one destination/trust key. Idle
connections expire after 90 seconds, checked when the pool is next used;
there is no background expiry Task. Runtime shutdown closes the pools and releases their idle sockets and TLS
engines after native retirement.
`close_idle_connections()` retires idle connections in the default pool;
`Client:close_idle_connections()` does the same for an explicit Client.
`Client:close()` additionally prevents new requests and retires its background
drains. Responses still held by callers remain caller-owned and cannot return
their connections to a closed Client. Healthy TLS idle connections and fully
read nonpersistent responses attempt `close_notify` with a 50 ms timeout;
interruption or timeout falls back to abort and completes native cleanup.
Dirty/unread connections and Runtime retirement use abort directly.

Closing an unread persistent response marks it closed immediately and schedules
background draining for at most **50 ms** and **256 KiB** of unread decoded
body data. A new request does not wait for that drain. The connection becomes
idle only after the complete message, including chunk trailers, has been
validated. Already buffered transport chunks may contain more bytes than the
drain allowance; a background drain exceeding that allowance retires the
connection. If the whole message is already parsed and validated, close can
discard retained body bytes and release the connection without a drain.
Otherwise known oversized remainders, close-delimited responses, `Connection: close`,
protocol upgrades, parse failures, and truncated messages are retired without
pooling. Expiration or a drain error retires the connection quietly; it cannot
change a response that the caller has already closed. Trailers discovered by a
successful drain are appended to the response's headers.

These bounds follow the approach described in
[Go's HTTP connection-reuse article](https://go.dev/blog/http-connection-reuse).
They apply to Titan's HTTP/1.1 client; HTTP/2 is unsupported.

An ordinary `request` or `get` rejects protocol upgrades. It also explicitly
rejects `ws` and `wss` source URLs; use the
[`websocket` module](standard-library-websocket.md) for those schemes.

An idle input observer removes and retires a connection when new bytes, EOF,
or error arrive, even when no further HTTP request is made. It creates a cleanup
Task only on that event, so there is no permanently waiting Task or unbounded
idle receive queue. TLS control records may also cause conservative retirement.
Already observed input is rejected before reuse as well. If a reused connection fails before any response bytes arrive,
Titan retries at most once on a fresh connection, and only for exact `GET` or
`HEAD` with no request body and a recognized connection-closure error. It does
not replay other methods, a request with a body, partial or informational
responses, parse errors, or cancellation. Data detected on an idle connection
before any request bytes are sent causes a fresh dial without replaying output.

A response permits one reader at a time. Closing while that reader is active
retires the connection and lets the reader unwind; it does not start a competing
drain or return that connection to the pool. Transport retirement remains
cancellation-insensitive: when reuse is unavailable, close completes cleanup
before terminal cancellation is published. Background draining retains its
parser and transport until read cancellation and native cleanup finish.

A native client returns content codings such as gzip unchanged: `read`
delivers the encoded bytes, and the caller owns decompression. The browser
decodes them instead (see [on the browser](#on-the-browser)).

### Client errors

| Failure | Native targets | Browser target |
| --- | --- | --- |
| Malformed source URL, a scheme other than `http` or `https`, or a malformed supplied `Host` authority | `url.Error` | `url.Error` |
| Invalid method or option, another invalid or forbidden header (including a second `Host`); `only_if_cached()` without `same_origin()`; `no_cors()` with another method; `get` with a body; a browser-only restriction below; a request with no active Runtime | string | string |
| Task cancellation | `async.CancellationReason` | `async.CancellationReason` |
| `only_if_cached()` miss, `RedirectMode.error()` on a redirect status, more than twenty redirects, an unusable or repeated redirect `Location` | `async.OperationError`, name `"EIO"`, operation `"http.request"` | the same |
| DNS or connection failure | `async.OperationError` from `net` | `async.OperationError`, name `"EIO"`, operation `"http.request"` |
| Certificate or TLS failure | `ssl.Error` | the same `"EIO"` `OperationError` |
| CORS or same-origin block, mixed content, a cross-origin `no_cors()` request with `manual()` or `error()` | (no such check) | the same `"EIO"` `OperationError` |
| HTTP protocol or framing failure | string | the same `"EIO"` `OperationError` |
| Body stream failure after the headers | the transport's error, or a string for framing | `async.OperationError`, name `"EIO"`, operation `"http.read"` |

Request-option policy failures therefore raise the same `OperationError`
identity on both targets. Branch on its `name` and `operation`: the numeric
`code` is the platform's negative `EIO` value and differs between targets.
There is no `http.Error` record, and `ssl.Error` never reaches a browser
caller.

## On the browser

On `--target browser`, `http` provides the client: `Header`, `Headers`,
`headers`, the four mode unions, `RequestOptions`, `Client`, `ClientResponse`,
`request`, `get`, `close_idle_connections`, and the `Client` and
`ClientResponse` methods other than `ClientResponse:take_upgrade`. Each has
its native signature. Servers (`listen`, `listen_tls`, `Server`, `Handler`,
`Request`, `Response`), protocol upgrades (`request_upgrade_on`,
`ClientResponse:take_upgrade`, `UpgradedStream`), and `Exchange` handoff have
no browser declarations, so a browser build that names one fails to compile.

The host's `fetch` performs each request. The browser engine, or Node when a
browser image runs under Node, owns the HTTP version, connection reuse, TLS
trust, its HTTP cache, cookies, CORS, mixed-content blocking, and the
`Origin` and `Referer` it sends. A shared interface does not promise the same
outcome on both targets: a request that succeeds natively can fail in a
browser because of CORS, and the redirect default differs.

**Runtime.** A request needs the instance's active async Runtime. In a state
created by `lua.new()`, `request` and `get` raise `"async Runtime is not
active"`. Importing `http`, building headers and options, and `Client.new`
work there.

**Checks before the network.** Titan rejects these requests before it calls
the host, so nothing reaches the network:

- an invalid method token, and `CONNECT`, `TRACE`, or `TRACK` in any letter
  case;
- a method other than `GET`, `HEAD`, or `POST` with `RequestMode.no_cors()`,
  as on native targets;
- an invalid URL, or a scheme other than `http` or `https` (`url.Error`);
- any `ca_file`, with `"HTTP ca_file is unavailable on the browser target"`;
- any body, even an empty one, with `GET` or `HEAD` in any letter case; and
- a forbidden request header, below.

**Request headers.** Browsers refuse to send the
[forbidden request headers](https://fetch.spec.whatwg.org/#forbidden-request-header)
of the Fetch standard. Titan checks them first, so every engine behaves the
same. Names compare ASCII case-insensitively:

- A `Host` must be one valid authority. A malformed one raises the
  `url.Error` of `url.parse_request`, as natively, and a second `Host` raises
  `"HTTP request has more than one Host header"`. A `Host` whose host and
  port equal the URL's, compared after normalization so that an omitted
  default port matches an explicit one, is removed, because the browser sends
  its own; any other valid `Host` raises `"HTTP custom Host header is
  unavailable on the browser target"`.
- One `Content-Length` equal to the body length is removed; any other
  `Content-Length` raises.
- `Transfer-Encoding` and `Expect` raise, as on native targets.
- `Accept-Charset`, `Accept-Encoding`, `Access-Control-Request-Headers`,
  `Access-Control-Request-Method`, `Connection`, `Cookie`, `Cookie2`, `Date`,
  `DNT`, `Keep-Alive`, `Origin`, `Referer`, `Set-Cookie`, `TE`, `Trailer`,
  `Upgrade`, and `Via` raise `"HTTP request header '<name>' is forbidden on
  the browser target"`, as does any name that begins with `Proxy-` or `Sec-`.
- `X-HTTP-Method`, `X-HTTP-Method-Override`, and `X-Method-Override` raise
  when an element of their comma-separated value, with surrounding spaces and
  tabs removed, is `CONNECT`, `TRACE`, or `TRACK` in any letter case. A comma
  inside a double-quoted string does not separate elements, so `GET, TRACE`
  raises and `"foo,TRACE,bar"` passes to `fetch` unchanged. Firefox and WebKit
  then drop that quoted-list value themselves, so it reaches the server only
  from Chromium and Node.

Every other header goes to `fetch` as supplied. With `RequestMode.no_cors()`
the browser itself drops the headers that CORS does not safelist. Fetch sends
the methods `delete`, `get`, `head`, `options`, `post`, and `put` in upper
case whatever their spelling; a native client sends the method as written.

**Options.** `cache`, `credentials`, and `mode` select the matching `fetch`
values, and `redirect` defaults to `follow()`. `CacheMode.default()` uses the
browser's HTTP cache, so a fresh cached response can arrive without a network
request; choose `no_store()` or `reload()` to bypass it. Node has no HTTP
cache, so under Node `only_if_cached()` misses at once and raises the native
`"HTTP response not in cache (only-if-cached)"` `OperationError` without a
request. In a browser it reads the cache, and a miss raises `OperationError`
with name `"EIO"` and operation `"http.request"`, except on WebKit, whose
cache-only miss goes to the network and returns the network's response.
`fetch` reports nothing that would let Titan detect that. A browsing context
without an HTTP cache, such as WebKit's ephemeral automation context, serves
nothing from cache. `CredentialsMode.include()` sends cookies on cross-origin
requests too, and such a response passes CORS only when the server names the
page's origin rather than `*`.

**Responses.** `status` is the HTTP status, or 0 for an opaque response.
`headers` holds what the browser exposes: lowercase names in sorted order,
repeated fields joined by commas, and no trailers. `Set-Cookie` and
`Set-Cookie2` never appear, under Node either. A cross-origin response
exposes only the CORS-safelisted headers and those its server lists in
`Access-Control-Expose-Headers`. `reason` is the status text that the
browser reports. `url` is the final URL and `redirected` reports whether the
browser followed a redirect; a cross-origin hop must pass CORS as well.
A `follow()` response with a redirect status and no `Location` has the
right status, headers, and `url` everywhere, but Node aborts its body: reading
it there can raise `OperationError` with operation `"http.read"`. Browsers
deliver that body.
Two kinds of response are opaque, with `status` 0, an empty `reason` and
`headers`, `redirected` false, and a body whose first read returns nil:

- With `RedirectMode.manual()`, every redirect status, with or without
  `Location`, gives Fetch's opaque-redirect response, whose `url` names the
  requested URL. Titan returns the same response under Node, which otherwise
  exposes the raw 3xx response, and hides the body that WebKit exposes for a
  redirect without `Location`.
- A cross-origin request with `RequestMode.no_cors()` and the `follow()`
  default gives an opaque response whose `url` is nil. With `manual()` or
  `error()`, Fetch treats such a request as a network error, so it raises
  `OperationError` with name `"EIO"` and operation `"http.request"`. A
  same-origin `no_cors()` request behaves as an ordinary request.

**Bodies.** The browser decodes content codings: `read` and `read_until`
return the decoded body bytes, while `Content-Encoding` and `Content-Length`
in `headers` still describe the bytes on the wire. Do not decompress again
because of `Content-Encoding`, and do not bound reads by `Content-Length`. A
body streams: each `read` returns the next chunk that the host delivers.
Request bodies are one in-memory string; there are no streaming uploads.

**Closing and cancellation.** `ClientResponse:close()` aborts the fetch at
once without yielding, so it is safe in a cancellation `defer`, and there is
no background drain. Cancelling a Task while it awaits response headers or a
body read also aborts the fetch, and the server sees the connection end.

**Clients.** A `Client` binds to the Runtime of its first request and closes
when that Runtime closes. After `close()`, its requests raise `"HTTP Client is
closed"`; the module helpers then start a new default client. The browser
engine pools connections, so `close_idle_connections()` and
`Client:close_idle_connections()` do nothing.

**Errors.** Failures that the host reports, including DNS failures, refused
connections, untrusted certificates and host-name mismatches, CORS and
same-origin blocks, and mixed content, raise `async.OperationError` with name
`"EIO"` and operation `"http.request"`; browsers do not tell them apart. A
failure while reading the body raises the same error with operation
`"http.read"`. See [client errors](#client-errors).

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
suspend. Listener close is cancellation-insensitive: cleanup completes and
releases a blocked `serve()` call before terminal cancellation is published.
Every later `close()` is an immediate no-op.

`Server:idle_timeout(timeout)` changes the deadline used to acquire the next
request line and headers. A nonnil value is validated, installed, and the
previous value is returned. Nil only reads the current value (which is also
the returned previous value). Zero waits indefinitely. A positive value is an
absolute millisecond deadline measured from the start of each request-loop
iteration; partial header bytes do not reset it. A setter call affects the
next request on an existing keep-alive connection, not a read already in
progress. Expiration closes that accepted connection without invoking the
handler or reporting an uncaught timeout error; the listener and other
connections remain active.

When headers arrive first, the server cancels the timer-only deadline Task and
continues while that cancellation finishes in the background. When the
deadline arrives first, it cancels and joins the reader Task before releasing
the parser and connection state owned by that read. This asymmetry keeps the
ordinary success path moving without letting timeout cleanup race the
connection teardown.

For HTTPS, the timeout cancels the in-flight high-level SSL read. The SSL
connection's documented cancellation rule terminalizes its TLS engine, so the
peer observes `ssl.Error` with name `TLS_TRUNCATED_EOF`, not authenticated
`close_notify` EOF. Cancelling admitted TLS input remains terminal even though
TLS now supports one concurrent application reader and writer.

The handler is called as soon as the request line and headers are complete,
without waiting for the HTTP parser to consume the complete body.
If the request does not advertise an upgrade and has exactly one `Expect`
field whose optional surrounding whitespace and case-insensitive value are
`100-continue`, the server first
writes `HTTP/1.1 100 Continue` and then calls the handler. This lets a handler
stream a body from a client that deliberately withholds it until the interim
response arrives. Any unsupported, combined, or repeated expectation receives
a final `417 Expectation Failed` with `Content-Length: 0` and
`Connection: close`; the handler is not called and the server does not wait
for the rejected body. A request advertising an `Upgrade` field or a
`Connection` upgrade token receives a bodyless `400 Bad Request` for any
Expect, even when its counterpart field is missing. The server also sends this
400 when such a complete opening has a missing, repeated, or invalid Host
authority, an invalid request URL, or a version other than HTTP/1.1. These
checks precede Request construction and handler dispatch. No interim response
is emitted, and HTTP closes without waiting for a declared body.
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
delimiters are rejected by `url.parse_request`, which receives Host and target
as separate inputs so one cannot consume the other.

Each `Response` begins as `200 OK` with empty headers. `set_status` accepts a
final status from 200 through 999 and an optional reason phrase. A supplied
reason has the same permitted byte repertoire as a field value. Header and
status mutation is allowed only before the final header write starts, including
when that write later fails. Abort the exchange instead of retrying failed
header output with a different status. `headers()` returns a copy, so changing
that copy does not mutate the Response.

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
decision disables reuse; otherwise HTTP/1.1 keep-alive is preserved. A peer
closing an idle persistent connection before beginning its next request is a
normal disconnect. On HTTPS that includes a peer that drops the connection
without TLS `close_notify` before sending any byte of its next request: the
connection closes quietly instead of failing with `ssl.Error`
`TLS_TRUNCATED_EOF`. EOF after any byte of a next request is a parse error,
including after only empty request lines or a dangling CR. Empty request lines
remain accepted when an actual request follows them.

The server promises serial HTTP/1.1 keep-alive processing, not a concurrent
pipelining facility. Each connection dispatches one handler at a time; the
current handler returns, its response is finished, and any unread request body
is drained before the next request is acquired. Bytes a transport read already
obtained beyond the current message are retained for that next serial
iteration so input is not lost. There is no per-connection request queue or
concurrent handler scheduler.

If a handler raises or parsing/framing fails, that connection Task terminates
and its connection closes. Other accepted connection Tasks and the listening
Server remain independent.

## Strictness and limits

Parsing uses llhttp in strict mode. Malformed or truncated messages,
conflicting framing, and unsupported HTTP versions are errors. Strict llhttp owns received header-name, header-value, and
Content-Length grammar. Titan's public header/request/response APIs separately
validate values before serializing them. Because llhttp treats a received
reason phrase as opaque bytes up to its line ending, Titan also applies the
field-value byte repertoire before exposing any informational or final
response reason. HTTP/2 remains outside this API. The server has no routing abstraction: one Handler receives every
request and can dispatch on `Request.url`, `Host`, method, or path itself.

The server limits each start line and header block to 64 KiB by default.
`Server:header_limit(limit)` installs a finite positive byte limit and returns
the previous setting; nil reads the current setting. The connection snapshots
the limit at the start of each request, so a setter affects subsequent header
acquisitions. The count includes leading empty lines, separators, and line
endings. The parser bounds input before copying header text and stops counting
at the first complete header boundary. A coalesced request body or upgraded
protocol suffix does not count against that header limit. Exceeding it closes
the accepted connection before invoking its handler. There is no separate
field-count limit. Body data remains streaming and has an application-defined
size policy. Ordinary client responses retain their existing streaming parser;
the explicit upgrade client uses the finite opening limits below.

The server timeout covers only request-line and header acquisition. It does
not cover handler work, request-body reads, automatic body drain, or ordinary
response writes. It also bounds the server's bodyless malformed-upgrade
rejection output before handler dispatch. Applications can compose their own Task/timer policy around those
operations with the public `async` combinators. A body timeout must also
unwind the handler; merely closing the listener does not stop an accepted
connection or bypass the automatic drain performed after a handler returns.

`Response:abort()` ends the live request/response exchange and retires its
accepted TCP or TLS transport without sending headers, a chunk terminator, or
draining an unread request body. Use it when a streaming response fails after
output has started, or when an application deadline must interrupt accepted
body/output I/O. Catch the interrupted operation's failure in its owner before
joining it. Abort is idempotent and cancellation-insensitive. It is a no-op for
a completed exchange or a response whose transport was transferred by
`upgrade`; retaining an old response cannot close a later keep-alive exchange.
Ordinary `close()` still finishes HTTP framing and can suspend on output.

## Protocol upgrade and ownership

`request_upgrade_on` performs one bodyless GET on an already connected stream.
It performs no DNS lookup, TCP connection, or TLS handshake. Supply the public
cancellation-insensitive retirement action while the concrete transport is
known: `plain:close` for `net.Connection`, or `secure:abort` for
`ssl.Connection`. The URL is an absolute `http` or `https` URL used for the
normalized target and Host authority. Supplied headers are copied, body framing
and Expect are rejected, and Connection/Upgrade are set to the chosen protocol.
The protocol is a token name with an optional `/token` version. Upgrade offers
may contain a comma-separated list such as `websocket, IRC/6.9`; matching folds
ASCII letters in protocol names and compares version tokens exactly.
After argument validation, HTTP owns the supplied stream through failure,
rejection, or successful transfer.

Opening responses have a 64 KiB cap per start-line-plus-header block, and at
most sixteen interim responses may precede the final response. A 101 response
is returned as a pending upgrade; ordinary body reads fail. The caller validates
its protocol-specific response, then calls `take_upgrade()` exactly once.
Closing a pending response invokes its abort action. A non-101 final response
retains ordinary streaming body reads for rejection inspection, with the same
abort ownership on close. A malformed opening always retires parser and stream.

`Response:upgrade` checks that its Request belongs to the same live exchange,
that no response bytes have been sent, and that the request offers the selected
HTTP/1.1 upgrade without an HTTP body. It copies existing unsent response
headers and appends validated copies of supplied headers,
sets Connection/Upgrade, writes exactly one 101 header block without body
framing, and returns an owning `io.ReaderWriterCloser`. Header output is bounded
to 64 KiB. All fallible construction precedes output, and ownership transfers
without suspension after output succeeds. Failure or cancellation during output
aborts under the HTTP owner before waiting for accepted I/O to retire.

`Response:reject_upgrade` applies the same live-pair and unsent-output checks
even when malformed request fields did not register a parser upgrade. It
accepts statuses 400 through 599, preserves unsent response fields and appends
validated copies of supplied headers, emits one
bounded response with Content-Length zero and Connection close, and retires the
transport. It skips unread-body drain. This lets protocol validation reject an
invalid opening without accidentally sending the Response's default 200 or
reading untrusted protocol bytes as an HTTP body.

The returned stream first consumes unread parser bytes, preserving embedded
NUL and other binary values. Its `read_until` finds delimiters across that
prefix and later transport input. Its `close()` is immediate, idempotent,
cancellation-insensitive transport retirement; it does not perform WebSocket or
TLS protocol shutdown. A transferred Request rejects further body reads, and
the Response rejects further output. HTTP never resumes or resets the parser
after transfer and its outer connection cleanup disarms close ownership.

The handler must immediately defer the returned stream's close or give it a
new explicit owner. It may return after transferring the stream to another
owned Task; HTTP does not close that session on handler return. A candidate
that the handler does not upgrade receives the handler's ordinary response
and closes, without parsing or draining the upgraded-protocol suffix.
`Server:close` continues to stop only the listener. It does not keep a registry
of transferred sessions. A nonzero HTTP idle timeout bounds slow header
acquisition; protocol opening and session deadlines are separate policies.
Upgrade I/O failures preserve the original error value and traceback through
the supervising Task's transport cleanup.

## Resource handoff

For portable handoff after HTTP classification, call
`listener:read_ahead(false)` before serving connections. This setting defaults
to true; the method returns the previous value and an omitted argument only
queries it. Changes affect newly accepted TCP/TLS connections, before their
first header read or TLS handshake, and leave existing connections unchanged.
Demand-driven reads avoid posting another Windows overlapped read between
operations. Yield with `async.yield()` after the last read/write and before
synchronous encoding so its native callback can retire. Pending application
operations and native requests still reject handoff.

A handler's `Request` and `Response` share one parser and transport. Bundle them
with `http.Exchange(request, response)` and transfer that public record:

```titan
local packet = async.TransferValue.from_value(http.Exchange(request, response))
async.send(worker_handle, packet)
```

The origin hook rejects pending reads, writes, upgrades, or native transport
operations before detachment. Success invalidates the original endpoints and
lets the original handler return. The hook preserves request metadata, unread
body bytes, parser progress, trailers, response headers, framing, and already
written byte counts. The pair cannot be transferred independently.

In the destination's active Runtime, `Receiver:wait()` returns the
reconstructed `Exchange`, with public const `request` and `response` fields.
Either finish the current exchange and call `exchange:close()`, or call
`exchange:serve(handler, idle_timeout: integer?)` to handle it and subsequent
requests on that connection. `serve` preserves serial keep-alive processing and
unread next-request bytes; only one serving loop may own the exchange. The
optional timeout is a non-negative number of milliseconds, defaulting to zero
for an indefinite wait. A positive timeout bounds each subsequent request-line
and header acquisition with one absolute deadline, including partial headers.
It does not cover the already-parsed current exchange, handlers, request bodies,
automatic body draining, or response writes. A negative timeout is rejected
before serving ownership changes. The originating listener's timeout is not
inherited. `close` completes the current response and closes the transport.

`Exchange` and `UpgradedStream` implement the synchronous
`to_transfer_payload(): string` and
`from_transfer_payload(payload: string)` hooks. The latter returns the
same concrete record type. `UpgradedStream` is a public record with private
fields; upgrade APIs retain their `io.ReaderWriterCloser` return type. Its hook
preserves the already received protocol prefix. WebSocket transfer unwraps that
HTTP-owned stream and uses this hook automatically. Custom stream implementations
passed to `request_upgrade_on` do not gain native handoff support: these HTTP
hooks require a concrete `net.Connection` or `ssl.Connection` transport. If
serializing the enclosing value fails after the transport detached, the hook
closes the detached transport and leaves the source inactive.

`Exchange.discard_transfer_payload(payload: string): integer` and
`UpgradedStream.discard_transfer_payload(payload: string): integer` consume a
known unadopted payload without a Runtime and return its native close status.
A close attempt consumes the payload even on an error; do not adopt or discard
the bytes afterward.

This is the [manual resource handoff contract](standard-library-transfer.md#shared-manual-handoff-rules):
the source detaches before delivery, payloads must be adopted exactly once, and
the caller owns recovery after failed delivery. Raw parser state is process-local
and belongs to the same native provider. Windows pending overlapped reads reject
handoff even when no application Task is waiting.

## Example

```titan
local async = import "async"
local http = import "http"

local function handler(request: http.Request, response: http.Response)
  response:set_header("Content-Type", "text/plain")
  response:write(request.method .. " " .. request.url.path .. "\n")
  response:close()
end

local function run_server(): nil
  local server = http.listen("127.0.0.1", handler, 8080)
  defer server:close()
  server:serve()
end

function main(args: {string}): integer
  async.run(run_server)
  return 0
end
```

The default build always bundles the pinned llhttp 9.4.3 parser into the
coordinated standard provider. The HTTP module introduces no system-llhttp
mode.
