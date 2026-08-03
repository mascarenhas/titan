# HTTP-library implementation

The public API and behavior are documented in the
[HTTP/1.1 standard-library chapter](../language/standard-library-http.md).
This chapter describes the `titan.http` folder module, its synchronous llhttp
callback bridge, streaming parser ownership, and high-level server composition.

## Folder-module structure and layering

The canonical `titan/http/http.titan` main uses the short `net`, `ssl`, `url`,
`io`, `async`, and `string` imports plus qualified `titan.math`. The parser
resolves every short spelling to its ordinary `titan.*` logical identity before
checking. Its immediate contributors share one module-private scope:

```text
titan/http/http.titan       imports and initialization
titan/http/client.titan     one-request client and ClientResponse
titan/http/headers.titan    ordered public Headers value
titan/http/native.titan     private parser owner and callback event Array
titan/http/server.titan     Request, Response, and per-connection serving
```

The only HTTP-owned native boundary is the synchronous callback bridge in
`titan/http/native/titan_httpshim.{c,h}`. It has no network or Task operation.
HTTP obtains every byte from the public `io.ReaderWriterCloser` view of either
a `net.Connection` or an `ssl.Connection`, and writes through that same view.
URL parsing calls the independent public `titan.url` module without an
HTTP-specific C bridge. The module neither imports nor changes `titan.uv`.

## Synchronous llhttp callback bridge

llhttp invokes callbacks synchronously inside `llhttp_execute` and
`llhttp_finish`, but a Titan closure is not a C function pointer. The private
`titan_httpshim.{c,h}` boundary therefore follows the established `titan.uv`
callback-owner protocol without introducing an asynchronous boundary.

The Titan `Parser` record owns its `llhttp_t` and `llhttp_settings_t` as
GC-managed foreign objects. Its first fields also hold the Lua state active for
the current synchronous parse and one exact Titan closure for each registered
llhttp callback: URL, status, header field, header value, header-value complete,
headers complete, body, and message complete. `llhttp_t.data` points back to
that Parser owner. Each correspondingly named C trampoline only recovers the
owner and active Lua state, extracts the fixed closure's module and native
entry, temporarily stack-roots the owner, invokes that exact generated Titan
signature, and restores the previous stack top.

The C boundary allocates no parser, event descriptor, arena, or copied byte
storage. It has no execute, finish, reset, getter, event-accessor, pause-policy,
or error-policy wrapper. There are no non-callback trampolines; Titan calls the
ordinary llhttp API directly.

Each Titan data callback copies its borrowed llhttp span into a Titan string
before returning and appends a typed `Event` to the Parser's GC-owned `{Event}`
Array. The headers-complete and message-complete callbacks snapshot the llhttp
metadata that belongs to their boundaries and select the documented llhttp
return codes. Callback code catches every Titan error before returning through
llhttp, stores the failure on the Parser, and returns `HPE_USER`; it never
unwinds through the C parser.
After the synchronous call returns, Titan either re-raises that stored failure
or drains the typed events into the high-level parser state.

`llhttp_execute` borrows its input while those callbacks may allocate and
collect. `execute_input` therefore stack-roots the immutable input string for
the entire execute, callback, consumed-suffix, and event-drain interval. The
span pointers remain valid only during their individual synchronous callbacks,
and no callback retains one. Both execute and finish first reserve Lua stack
space for the trampoline's temporary owner root and the generated callback
frame.

## Pausing and streaming ownership

Each parser pauses after headers and after message completion. A pause may
occur before the end of the supplied network chunk, so Titan subtracts
`llhttp_get_error_pos` from the still-rooted input pointer and retains the
unconsumed suffix. Resuming first consumes that suffix before another
high-level connection read. This is how a handler can begin before the request
body is buffered and how bytes already read for a later request survive one
message boundary.

A header pause at the exact end of a transport chunk can leave llhttp on an
epsilon transition to message completion. After resuming with no retained
suffix, Titan executes one empty input before attempting another socket read.
That lets a bodyless message reach its message-complete pause instead of
deadlocking with a peer that is waiting for the response.

Body callbacks are copied into a Titan Array of chunks. `read` consumes that
array incrementally and clears it once drained; new network input is requested
only when no buffered body event remains. `read_until` composes over those
logical body chunks and retains only the bytes following its delimiter.
llhttp itself removes Content-Length and chunked framing. The parser reaches
the high-level Reader only after strict message-shape validation.

Request parsing pauses at headers, constructs the public `Request`, and hands
the same private parser owner to its Reader methods. On handler return, the
connection Task closes the Response and drains any unread request body before
resetting llhttp. Reset clears per-message Titan fields but preserves the
already retained network suffix and the response-to-HEAD policy where
applicable.

Response parsing likewise pauses at headers so `request` can return a
`ClientResponse`. Informational responses are drained and the parser reset
until a final status is reached. A HEAD request configures llhttp's response
semantics before all informational/final parsing. Reading body EOF releases
the parser and the one-use transport.

## Headers, URL consumption, and framing

Headers use an Array of public `Header` records. Lookup performs ASCII folding
without normalizing stored spelling, so duplicate order remains available to
protocol checks and applications. Construction/mutation rejects invalid token
names and field values containing controls other than HTAB or containing DEL.
The parser appends fields only on llhttp's complete
value event, after trimming optional whitespace.

The reusable grammar, labels, normalization, and `(Url?, Error?)` boundary are
owned by `titan.url` and documented in the
[URL-library implementation chapter](url-library.md). The HTTP-local
`parse_url_or_raise` adapter calls `url.parse`, raises its structured
`url.Error` when parsing fails, and otherwise unwraps the `url.Url`. HTTP does
not re-export either record or a second parse function.

The client connects with normalized `Url.host`, uses normalized
`Url.authority` when it generates an absent Host field, and sends normalized
`Url.target`. HTTPS passes its sole optional `ca_file` through to
`ssl.connect`; HTTP neither reads trust paths nor exposes a CA-directory
parameter. The SSL layer performs explicit CA-file I/O through high-level
`fs`. The server runs the same parser over `scheme://` plus the exact received
Host and origin-form target, after rejecting `/`, `?`, `#`, or `@` in Host so
it cannot consume or reinterpret the independently parsed target.
`Request.target` remains that received target, while `Request.url` provides
the normalized routing view.

The client copies supplied headers, validates Content-Length, rejects request
Transfer-Encoding and Expect fields, and forces `Connection: close`. Rejecting
Expect is deliberate: the initial client assembles the optional body with the
preamble in one write and must not advertise a `100-continue` handshake that
it does not honor. A supplied singleton Host
first rejects `/`, `?`, `#`, and `@`, then is parsed in isolation by the same
URL grammar as a complete authority; this enforces host, bracketed IP-literal,
and optional-port syntax before opening the connection. Its optional body is
assembled with the request preamble as one high-level write. Response bodies
alone are streaming.

The server derives response framing at first header send. A declared
Content-Length is counted exactly; explicit Transfer-Encoding must be one
`chunked` field; otherwise a body-capable response becomes chunked. HEAD, 204,
205, and 304 suppress body framing and remove Transfer-Encoding. Status 204
rejects Content-Length outright. Status 205 accepts only a zero
Content-Length and synthesizes `Content-Length: 0` when absent. Closing emits
the chunk terminator or verifies the declared length. llhttp's keep-alive
decision and an explicit Connection close token decide whether the
per-connection loop resets the parser.

Immediately after header parsing, the per-connection loop resolves `Expect`
before it can call a handler that waits in `Request:read`. An OWS-trimmed,
case-insensitive `100-continue` is accepted only as one complete singleton
field and writes the exact interim response synchronously. Every other value,
comma-combined value, or repeated field produces a framed zero-length 417 and
returns from the connection loop without draining the declared body. The
deferred transport close makes that rejection safe without parser reuse.

## Server Tasks and the interface conversion boundary

`Server:serve` owns the accept loop. Each accepted connection is converted to
`io.ReaderWriterCloser` and passed to a fresh `async.run` Task, so different
connections can progress independently while requests on one connection stay
ordered.

The high-level constructors keep required values before optional configuration:
plain `listen` takes host and handler before optional port/backlog, while
`listen_tls` takes host, certificate, and handler before optional private-key
path, port, and backlog. The plain/TLS port defaults are 80/443. Both pass the
optional backlog to `net.listen` (directly or through `ssl.listen`), where it
defaults to 128; TLS likewise delegates the omitted-key PEM-bundle behavior to
`ssl.listen`.

The Server record deliberately stores separate optional `net.Server` and
`ssl.Server` fields and branches while accepting. A tempting common Interface
would need an `accept(): io.ReaderWriterCloser` result, but Titan's structural
record-to-Interface conversion does not lift through a method's result type.
The concrete `accept(): net.Connection` and `accept(): ssl.Connection` methods
therefore cannot satisfy such an Interface by converting their returned value.
Branching on the listener owner and converting each accepted Connection is the
straight high-level expression of the current type model; it is not grounds
for uv access or a native identity workaround.

An uncaught parse, handler, or response-framing error exits only that
connection Task. Deferred parser and transport closers run while the accept
loop and other Tasks remain live, following the ordinary Task-local error
policy.

`ClientResponse:close` marks its Titan parser closed before calling the
suspending transport close, but records transport completion only after that
call returns. `Server:close` similarly marks the high-level listener closed
before delegating to `net.Server` or `ssl.Server`, then records listener
completion after the delegate returns. Sticky cancellation can therefore
leave either object logically closed without a recorded delegate completion;
a later `close()` skips the completed logical step and idempotently retries
exactly the transport or listener step. This is a concrete resource contract,
not an HTTP queue or scheduler.

## Serial pipelining and the idle-timeout composition blocker

The server supports ordered HTTP/1.1 request pipelining: a peer may send later
requests before reading the current response. Its one connection Task runs a
handler, finishes the response, drains any unread request body, and only then
resets the parser and dispatches the next handler. If one transport read
already contained bytes for a later request, the parser retains that
unconsumed suffix for the same loop to process afterward. Responses remain in
request order and never interleave; there is no concurrent per-connection
handler scheduler. Suffix preservation is the byte-retention mechanism that
enables this serial pipelined processing, not a concurrent request queue or
scheduler.

HTTP/1.1 keep-alive and this serial pipelined processing require no lower-level
primitive. A robust idle deadline does. The public async facade
has Task creation and cancellation plus timers, but no current-Task accessor,
join, race, or deadline operation. A timer Task cannot simply cancel and be
joined by the connection Task. Implementing the policy locally would require
a connection-specific watchdog, generation tokens around every reuse
interval, and carefully fenced close/cancellation behavior.

That protocol would duplicate scheduling machinery for one library and is not
part of this iteration. The server consequently has no internal idle timeout.
This limitation is explicitly treated as a blocker in high-level composition;
the implementation does not work around it by changing or reaching through
the fixed `titan.uv` substrate.

## Native build and provider composition

The build pins llhttp 9.4.3 and verifies its source tarball. The three generated
sources `llhttp.c`, `http.c`, and `api.c` compile as hidden PIC objects in a
private deterministic `libtitan-llhttp.a`; the adapter is a separate
`titan_httpshim.o`. Both are metadata-free standard-provider payload and are
force-carried into the DSO and flattened into the static provider. There is no
system-llhttp mode, and neither the private archive nor headers are installed
as runtime-SDK files.

The HTTP root adds one logical protocol, archive key, generated shim, and
`luaopen_titan_http`. Together URL, SSL, and HTTP advance the coordinated
current standard image to seventeen logical modules and shims and eighteen DSO
openers including bare `luaopen_titan` support. A valid fourteen-module
ABI-0.20 image remains an explicitly recognized publication predecessor; that
historical migration count is not the current provider contract.

Focused standard-library tests run outside LuaCov. They fragment protocol
input down to individual bytes, exercise fixed/chunked/EOF bodies, duplicate
headers, streaming handlers, unread-body draining, keep-alive, ordered
pipelined requests, and HTTPS over the public SSL facade, and prove
listener/response close retries
after cancellation. The sanitizer boundary uses that same high-level path
through TLS and llhttp rather than a private test transport.
