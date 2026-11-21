# HTTP/1.1 standard library

The `http` module provides a streaming HTTP/1.1 client and server natively (layered over `net`, `ssl`, `url`, `io`, and `async`), and a `fetch`-backed client on the browser target. Import it in Titan with `local http = import "http"` or load it in Lua with `require "titan.http"`.

**Target availability:** Native & Browser (client API on both targets; servers, protocol upgrades, and resource handoff are native-only — see [On the browser](#on-the-browser)).

## Examples

### Client GET and POST

```titan
local http = import "http"
local strings = import "string"

function fetch_text(source: string): (integer, string)
  local response = http.get(source)
  defer response:close()
  local buf = strings.writer()
  for chunk in response:read do
    buf:write(chunk)
  end
  return response.status, buf:drain()
end

function post_json(source: string, payload: string): integer
  local supplied = http.headers()
  supplied:set("Content-Type", "application/json")
  local response = http.request("POST", source, http.RequestOptions {
    headers = supplied,
    body = payload,
  })
  defer response:close()
  return response.status
end
```

### Server handler

```titan
local http = import "http"

local function handler(request: http.Request, response: http.Response)
  response:set_header("Content-Type", "text/plain")
  response:write(request.method .. " " .. request.url.path .. "\n")
  response:close()
end

function serve_forever(host: string, port: integer)
  local server = http.listen(host, handler, port)
  defer server:close()
  server:serve()
end
```

## Core concepts

All network operations and server handlers execute inside [`async.Task`](async-io.md#scheduling-and-driving-tasks)s. `ClientResponse` satisfies `io.ReaderCloser`, `Request` satisfies `io.Reader`, and `Response` satisfies both `io.Writer` and `io.Closer`. Always `defer response:close()` immediately after obtaining a `ClientResponse`.

URLs are parsed and normalized by the [`url`](standard-library-url.md) module: clients raise `url.Error` on malformed URLs or non-`http`/`https` schemes before opening a connection, and server `Request.url` values come from `url.parse_request`. Native clients and servers speak HTTP/1.1 only; HTTP/2 and application-level routing are outside this module.

## Headers

```text
record Header
  name: string
  contents: string
end
function Header.new(name: string, contents: string): Header

record Headers
function headers(initial: {Header}?): Headers
function Headers:add(name: string, contents: string)
function Headers:set(name: string, contents: string)
function Headers:get(name: string): string?
function Headers:values(name: string): {string}
function Headers:remove(name: string)
function Headers:all(): {Header}
```

`Headers` is an insertion-ordered list (not a Map) that preserves original header spelling and duplicate fields while comparing names with ASCII case folding:

- `add` appends one field; `set` removes every matching field and appends one replacement; `remove` deletes every matching field.
- `get` returns the first matching value or `nil`; `values` returns all matching values in order; `all` returns a copied `{Header}` Array.

`headers(initial?)` validates and copies its input. Names must be nonempty HTTP tokens; values accept HTAB, SP/VCHAR, and `obs-text` (rejecting NUL, CR, LF, DEL, and other control bytes to prevent header injection). Parsed header values strip surrounding SP and HTAB.

## Client requests

```text
union CacheMode
  default() | no_store() | reload() | no_cache() | force_cache() | only_if_cached()
end
union CredentialsMode
  omit() | same_origin() | include()
end
union RequestMode
  cors() | no_cors() | same_origin()
end
union RedirectMode
  follow() | error() | manual()
end

record RequestOptions
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

function request(method: string, source_url: string,
                 options: RequestOptions?): ClientResponse
function get(source_url: string, options: RequestOptions?): ClientResponse
function close_idle_connections()

function ClientResponse:read(): string?
function ClientResponse:read_until(delimiter: string, chop: boolean?): string?
function ClientResponse:close()
```

- **`request(method, source_url, options?)`** validates `method` as an HTTP token (case-sensitive; exact `"HEAD"` selects HEAD framing), parses `source_url`, sends the request (choosing plain TCP or verified TLS from the scheme), consumes any 1xx interim responses, and returns once final response headers are parsed.
- **`get(source_url, options?)`** sends a `GET` request and rejects any `options` carrying a `body` (even `""`) with `"HTTP get does not accept a request body"`.
- **Native request framing:** At most one `Host` header is allowed (validated as one complete URI authority via `url.parse_request`, generated from `Url.authority` if absent). `body` is a single in-memory binary string; `Content-Length` is generated if absent and must match exactly if supplied. Request `Transfer-Encoding` and `Expect` are rejected. Connections are persistent unless `Connection: close` is sent. `ws` and `wss` URLs are rejected (use [`websocket`](standard-library-websocket.md)).
- **Streaming response body:** `ClientResponse.status`, `reason`, `headers`, `url` (normalized final URL, or `nil` for opaque browser responses), and `redirected` are populated before body reads begin. `read()` and `read_until(delimiter, chop?)` decode chunked/Content-Length/close-delimited framing and append trailers to `headers` when reached. Native clients return content codings (such as `gzip`) uncompressed; browsers decode them automatically. Reading to EOF closes the response and returns healthy persistent connections to the pool. `ClientResponse:close()` is idempotent.

### Request options

Construct immutable `RequestOptions` snapshots with named arguments (`http.RequestOptions { headers = supplied, redirect = http.RedirectMode.follow() }`); one snapshot can be reused across any number of requests and Clients:

| Option | Meaning | Default when `nil` |
| --- | --- | --- |
| `headers` | Application request headers (copied) | None |
| `body` | In-memory, binary-safe request body | None |
| `ca_file` | PEM trust file for native HTTPS (replaces default roots on every HTTPS hop) | Default trust paths |
| `cache` | `CacheMode` | `default()` |
| `credentials` | `CredentialsMode` | `same_origin()` |
| `mode` | `RequestMode` | `cors()` |
| `redirect` | `RedirectMode` | `manual()` natively; `follow()` on browser |

Passing `CacheMode.only_if_cached()` without an explicit `RequestMode.same_origin()` raises `"HTTP cache mode 'only-if-cached' requires request mode 'same-origin'"`. Each union constructor produces a fresh value compared by identity, so inspect modes with `case`:

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

On native targets (which have no HTTP cache, cookie jar, or CORS enforcement): `only_if_cached()` raises `async.OperationError` (`name == "EIO"`, `operation == "http.request"`, message `"HTTP response not in cache (only-if-cached)"`) before dialing; `RequestMode.no_cors()` admits only `GET`, `HEAD`, and `POST` (case-insensitively), raising `"HTTP request mode 'no-cors' allows only GET, HEAD, or POST"` otherwise; `credentials` sends only application-supplied headers; plain HTTP ignores `ca_file`.

### Redirects

Redirect handling applies to statuses `301`, `302`, `303`, `307`, and `308`:

- **`RedirectMode.manual()`** *(native default)* returns the 3xx response directly natively (or Fetch's opaque-redirect response on the browser).
- **`RedirectMode.error()`** closes the response and raises `async.OperationError` (`name == "EIO"`, `operation == "http.request"`, `"HTTP redirect disallowed by RedirectMode.error"`).
- **`RedirectMode.follow()`** *(browser default)* follows `Location` up to 20 hops (returning a redirect with no `Location` as-is, and raising `"EIO"` `OperationError` on multiple `Location` headers, a 21st hop, or an unfollowable/non-HTTP(S) target). Natively, `Location` resolves as an RFC 3986 reference (stripping `#fragment`), closes each intermediate response, checks cancellation between hops, rewrites 301/302 on `POST` and 303 on non-`GET`/`HEAD` to bodyless `GET` (stripping `Content-*` headers), keeps method/body on 307/308, and strips `Authorization`, `Proxy-Authorization`, `Cookie`, `Cookie2`, and `Host` across origin changes (including `https` -> `http`).

### Connection pools and early close

On native targets, module-level `get`/`request` share a per-Runtime default pool, while `http.Client()` creates an isolated pool bound to the Runtime of its first request:

```titan
local http = import "http"
local strings = import "string"

function fetch_pair(first: string, second: string): (string, string)
  local client = http.Client()
  defer client:close()
  local fetch = function (source: string): string
    local response = client:get(source)
    defer response:close()
    local output = strings.writer()
    for chunk in response:read do
      output:write(chunk)
    end
    return output:drain()
  end
  return fetch(first), fetch(second)
end
```

- Connections are keyed by scheme, normalized host and port, effective `Host` header, and `ca_file` path spelling (close the pool before rotating trust files).
- Each pool keeps at most **100** idle connections total, **2** per destination/trust key, with a **90-second** idle expiry checked on reuse; idle input listeners retire connections that receive unsolicited bytes, EOF, or errors.
- Closing an unread persistent response marks it closed immediately and drains up to **50 ms** and **256 KiB** in the background to reclaim the connection; larger or unpoolable responses retire immediately.
- If a reused idle connection fails before any response byte arrives, Titan retries at most once on a fresh connection for bodyless `GET` or `HEAD` on recognized closure errors.
- `close_idle_connections()` and `Client:close_idle_connections()` retire idle sockets (attempting 50 ms TLS `close_notify` on healthy idle TLS sockets). `Client:close()` additionally blocks new requests and drains background cleanup. A `ClientResponse` allows at most one active reader; closing while reading aborts and unwinds the reader.

### Client errors

| Failure | Native targets | Browser target |
| --- | --- | --- |
| Malformed URL, non-HTTP(S) scheme, or malformed supplied `Host` | `url.Error` | `url.Error` |
| Invalid method/option/header, `only_if_cached()` without `same_origin()`, `no_cors()` method violation, `get` with body, browser restriction, no active Runtime | `string` | `string` |
| Task cancellation | `async.CancellationReason` | `async.CancellationReason` |
| `only_if_cached()` miss, `RedirectMode.error()`, >20 redirects, invalid/duplicate `Location` | `async.OperationError` (`"EIO"`, `"http.request"`) | Same |
| DNS or connection failure | `async.OperationError` from `net` | `async.OperationError` (`"EIO"`, `"http.request"`) |
| TLS / certificate failure | `ssl.Error` | `async.OperationError` (`"EIO"`, `"http.request"`) |
| CORS / mixed-content / cross-origin `no_cors()` with `manual()`/`error()` | (N/A) | `async.OperationError` (`"EIO"`, `"http.request"`) |
| HTTP protocol / framing failure | `string` | `async.OperationError` (`"EIO"`, `"http.request"`), or `string` for forbidden header/reason bytes |
| Body stream failure after headers | Transport error or framing `string` | `async.OperationError` (`"EIO"`, `"http.read"`) |

Branch on `OperationError.name` and `operation` (`code` is platform-specific negated `EIO`).

## Servers and handlers

*(Native only.)*

```text
type Handler = function (Request, Response): ()

record Request
  method: string
  target: string
  url: url.Url
  version: string
  headers: Headers
end
function Request:read(): string?
function Request:read_until(delimiter: string, chop: boolean?): string?
function Request:local_address(): net.Address
function Request:peer_address(): net.Address

record Response
function Response:set_status(status: integer, reason: string?)
function Response:add_header(name: string, contents: string)
function Response:set_header(name: string, contents: string)
function Response:headers(): Headers
function Response:is_committed(): boolean
function Response:send_headers()
function Response:write(data: string)
function Response:close()
function Response:abort()

record Server
function listen(host: string, handler: Handler,
                port: integer?, backlog: integer?,
                idle_timeout: integer?, reuse_port: boolean?): Server
function listen_tls(host: string, certificate_file: string, handler: Handler,
                    private_key_file: string?, port: integer?,
                    backlog: integer?, idle_timeout: integer?,
                    reuse_port: boolean?): Server
function Server:local_address(): net.Address
function Server:idle_timeout(timeout: integer?): integer
function Server:header_limit(limit: integer?): integer
function Server:read_ahead(enabled: boolean?): boolean
function Server:serve()
function Server:close()
```

- **Listeners:** `listen` defaults to port `80`; `listen_tls` defaults to port `443` (omitted `private_key_file` reads the key from `certificate_file`). Both accept `port` in `0..65535`, default `backlog` `128` (`1..2147483647`), default `idle_timeout` `0` ms (no deadline), and `reuse_port` forwarded to [`net.listen`](standard-library-net.md#connecting-and-listening) (`ENOTSUP` on macOS/Windows). `Server:local_address()` returns the bound local [`net.Address`](standard-library-net.md#socket-addresses) of an open HTTP or HTTPS listener (including the OS-assigned port when bound with `port` `0`) and raises on a closed `Server`.
- **Serving & closing:** `Server:serve()` loops accepting connections and spawns one Task per connection, processing requests serially over keep-alive. `Server:close()` is idempotent, cancellation-insensitive, and stops accepting without cancelling already-accepted connection Tasks.
- **Idle timeout:** `Server:idle_timeout(timeout?)` queries or updates the non-negative millisecond deadline for acquiring each next request line and header block (partial headers do not reset it). Timeout closes that connection quietly; for HTTPS, cancelling the TLS read terminalizes the TLS engine so the peer sees `TLS_TRUNCATED_EOF`.
- **Request dispatch, addresses, & `Expect`:** Handlers run as soon as headers complete, with `Request.method`, raw origin-form `target` (must start with `/`), normalized `url`, `version` (`"HTTP/1.1"`), and `headers` (requiring exactly one valid `Host`). `Request:local_address()` and `Request:peer_address()` return immutable [`net.Address`](standard-library-net.md#socket-addresses) snapshots from the active request's underlying TCP or TLS transport (including across keep-alive exchanges and adopted `Exchange:serve` loops) and raise once the exchange has ended (after completion, `abort()`, `upgrade()`, or source detachment). A single `Expect: 100-continue` on a non-upgrade request sends `HTTP/1.1 100 Continue` before invoking the handler; unsupported expectations receive `417 Expectation Failed`; malformed upgrade openings (any `Expect`, invalid/missing/duplicate `Host`, bad URL, or non-1.1 version) receive `400 Bad Request` before handler dispatch. Unread request bodies are drained automatically only when the connection remains reusable for a subsequent keep-alive request: when the exchange is already non-reusable—for example because the request carried `Connection: close` or the handler set `response:set_header("Connection", "close")` (such as before sending a `413` rejection)—both `Server:serve` and `Exchange:serve` skip further server-side request-body reads after `response:close()` and close the connection instead.
- **Response framing & commitment:** Responses start at `200 OK` (`set_status` accepts `200..999` and optional valid reason before headers are written). `headers()` returns a copy. `is_committed()` reports `true` once final response headers have been committed by `send_headers()`, `write()`, `close()`, `upgrade()`, or `reject_upgrade()`, and `false` beforehand (an interim `100 Continue` does not commit final headers); commitment is reserved before the transport write begins, so `is_committed()` returns `true` even if that write subsequently fails, and remains readable as a historical flag after the exchange completes, upgrades, aborts, or detaches. `send_headers()` commits and flushes headers immediately (idempotently). When headers have not yet been sent, `write()` may coalesce the status line and headers with an initial valid body chunk into a single transport write, and `close()` may coalesce unsent headers with the terminal empty chunk on an empty chunked response; call `send_headers()` explicitly when headers must be flushed ahead of the body. Without `Content-Length`, body-capable responses use `Transfer-Encoding: chunked`; with `Content-Length`, writes cannot exceed it and `close()` requires an exact match. `HEAD`, `204`, `205` (enforces `Content-Length: 0`), and `304` forbid nonempty bodies and strip `Transfer-Encoding`. Returning from a handler calls `close()` automatically; handler errors close only that connection. An idle peer disconnect (`EOF`, `ECONNRESET`, or unauthenticated TLS drop) before any byte of the next request closes quietly.

## Strictness and limits

*(Native only.)*

Native parsing runs bundled llhttp in strict mode, validating header syntax, framing, and reason-phrase bytes.

- **`Server:header_limit(limit?)`** queries or sets the positive byte cap for each start line and header block (default **64 KiB**, including leading empty lines and line endings, excluding coalesced body or upgraded protocol bytes). Exceeding the limit closes the connection before handler dispatch. Body size limits are application-defined.
- **Timeout scope:** `idle_timeout` covers only header acquisition and pre-handler malformed-upgrade rejection output, not handler work, body reads/drains, or response writes.
- **`Response:abort()`** is idempotent and cancellation-insensitive: it ends the exchange and tears down the transport immediately without sending headers, chunk terminators, or draining unread request bodies (no-op after exchange completion or `upgrade`).

## Protocol upgrade and ownership

*(Native only.)*

```text
function request_upgrade_on(connection: io.ReaderWriterCloser,
                            abort: function (): (), source_url: string,
                            protocol: string,
                            supplied_headers: Headers?): ClientResponse
function ClientResponse:take_upgrade(): io.ReaderWriterCloser

function Response:upgrade(request_value: Request, protocol: string,
                          supplied_headers: Headers?): io.ReaderWriterCloser
function Response:reject_upgrade(request_value: Request, status: integer,
                                 supplied_headers: Headers?)
```

- **`request_upgrade_on(connection, abort, source_url, protocol, supplied_headers?)`** sends one bodyless `GET` with `Connection`/`Upgrade` headers over an already connected stream (`abort` should be `plain:close` for `net.Connection` or `secure:abort` for `ssl.Connection`). Opening responses are capped at 64 KiB per header block and at most 16 interim responses. A `101` response is a pending upgrade whose raw stream is claimed once via `ClientResponse:take_upgrade()`; closing a pending response invokes `abort`. Non-`101` responses remain readable for rejection diagnostics.
- **`Response:upgrade(request_value, protocol, supplied_headers?)`** verifies the live pair, unsent output, and matching protocol offer (ASCII case-insensitive name, case-sensitive `/version`), emits a `101` header block (capped at 64 KiB), and returns an owned `io.ReaderWriterCloser` (backed by `UpgradedStream`) that replays any prefetched protocol suffix before reading further from the transport.
- **`Response:reject_upgrade(request_value, status, supplied_headers?)`** emits a bodyless rejection (`400..599`, `Content-Length: 0`, `Connection: close`) without draining any unread body, then retires the transport.
- After `upgrade`, the handler owns closing the returned stream (immediately `defer stream:close()` or hand it to another Task) and may return without HTTP closing the transferred session.

## Resource handoff

*(Native only.)*

```text
record Exchange
  const request: Request
  const response: Response
end
function Exchange.new(request_value: Request, response: Response): Exchange
function Exchange:to_transfer_payload(): string
function Exchange.from_transfer_payload(payload: string): Exchange
function Exchange.discard_transfer_payload(payload: string): integer
function Exchange:serve(handler: Handler, idle_timeout: integer?)
function Exchange:close()

record UpgradedStream
function UpgradedStream:read(): string?
function UpgradedStream:read_until(delimiter: string, chop: boolean?): string?
function UpgradedStream:write(data: string)
function UpgradedStream:close()
function UpgradedStream:to_transfer_payload(): string
function UpgradedStream.from_transfer_payload(payload: string): UpgradedStream
function UpgradedStream.discard_transfer_payload(payload: string): integer
```

Because `Request` and `Response` share one parser and transport, bundle them as `http.Exchange(request, response)` to transfer an idle exchange across Lua states in the same process:

```text
local packet = async.TransferValue.from_value(http.Exchange(request, response))
async.send(worker_handle, packet)
```

- Call `server:read_ahead(false)` before `serve()` so newly accepted connections use demand-driven reads (avoiding pending Windows overlapped reads), and call `async.yield()` after the last I/O before encoding. Pending reads, writes, upgrades, or native requests reject handoff.
- Encoding detaches the source endpoints and preserves request metadata, unread body/keep-alive bytes, parser state, response headers, and framing. In the destination Runtime, `Request:local_address()` and `Request:peer_address()` query the adopted socket while the exchange is active; either complete the current exchange and call `exchange:close()`, or call `exchange:serve(handler, idle_timeout?)` to handle it and subsequent keep-alive requests with the same non-reusable skip-drain behavior as `Server:serve` (`idle_timeout` defaults to `0` and does not inherit the originating server's timeout).
- `UpgradedStream` transfers an upgraded `net.Connection` or `ssl.Connection` stream plus its prefetched protocol prefix (`websocket.Connection` transfer delegates to it). Custom `io.ReaderWriterCloser` streams passed to `request_upgrade_on` are not transferable.
- Both types follow the [shared manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules) and provide `discard_transfer_payload(payload)` to release an unadopted payload without a Runtime (consuming ownership even on error).

## On the browser

On `--target browser`, `http` provides the client (`Header`, `Headers`, `headers`, the four mode unions, `RequestOptions`, `Client`, `ClientResponse`, `request`, `get`, `close_idle_connections`, and `Client`/`ClientResponse` methods other than `take_upgrade`) backed by the host's `fetch`. Servers, upgrades, and `Exchange`/`UpgradedStream` handoff are absent at compile time.

- **Runtime:** Requests require the instance's owner `async` Runtime (`"async Runtime is not active"` in a `lua.new()` state; constructing headers, options, and `Client()` works there).
- **Pre-network checks:** Titan rejects invalid method tokens, `CONNECT`/`TRACE`/`TRACK`, non-`GET`/`HEAD`/`POST` under `no_cors()`, invalid or non-HTTP(S) URLs (`url.Error`), any `ca_file` (`"HTTP ca_file is unavailable on the browser target"`), any body on `GET`/`HEAD`, and Fetch's forbidden request headers before calling `fetch`:
  - `Host` must be a single valid authority matching the URL's normalized host and port (removed automatically since the browser sends its own; any other valid `Host` raises `"HTTP custom Host header is unavailable on the browser target"`).
  - Matching `Content-Length` is removed; mismatched `Content-Length`, `Transfer-Encoding`, and `Expect` raise.
  - `Accept-Charset`, `Accept-Encoding`, `Access-Control-Request-Headers`, `Access-Control-Request-Method`, `Connection`, `Cookie`, `Cookie2`, `Date`, `DNT`, `Keep-Alive`, `Origin`, `Referer`, `Set-Cookie`, `TE`, `Trailer`, `Upgrade`, `Via`, and any `Proxy-*` or `Sec-*` header raise `"HTTP request header '<name>' is forbidden on the browser target"`.
  - `X-HTTP-Method`, `X-HTTP-Method-Override`, and `X-Method-Override` raise if any unquoted comma-separated element is `CONNECT`, `TRACE`, or `TRACK` (for example `GET, TRACE` raises, whereas `"GET,TRACE,POST"` passes to `fetch`, though Firefox and WebKit drop quoted-list values themselves).
- **Methods & options:** Fetch uppercases `delete`, `get`, `head`, `options`, `post`, and `put`. `redirect` defaults to `follow()`. `CacheMode.default()` uses the browser HTTP cache (use `no_store()` or `reload()` to bypass it; under Node, which has no HTTP cache, `only_if_cached()` raises `"HTTP response not in cache (only-if-cached)"`; WebKit's `only_if_cached()` falls through to the network). `CredentialsMode.include()` requires an explicit server `Access-Control-Allow-Origin` matching the page origin rather than `*`.
- **Responses & bodies:** `headers` contains browser-exposed lowercase sorted headers with repeated fields comma-joined, no trailers, and no `Set-Cookie`/`Set-Cookie2`. `RedirectMode.manual()` produces Fetch's opaque-redirect response (`status == 0`, empty `reason`/`headers`, `url` set to the requested URL, `read()` returns `nil`); cross-origin `RequestMode.no_cors()` with `follow()` produces an opaque response with `url == nil` (with `manual()`/`error()` it raises `"EIO"` `OperationError`). On `follow()` with a 3xx lacking `Location`, browsers deliver the body while Node may abort body reads with `"http.read"`. The browser decodes `Content-Encoding` transparently while leaving the original `Content-Encoding` and `Content-Length` headers intact—do not decompress again or bound reads by `Content-Length`.
- **Closing, pooling, and errors:** `ClientResponse:close()` and Task cancellation abort the fetch immediately without yielding. `close_idle_connections()` and `Client:close_idle_connections()` are no-ops because the host manages pooling. Closed `Client` instances raise `"HTTP Client is closed"`. Host-reported network, TLS, CORS, and mixed-content failures all surface as `async.OperationError` with `name == "EIO"` and `operation == "http.request"` (or `"http.read"` during body reads).
