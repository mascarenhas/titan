# HTTP-library implementation

The public API and behavior are documented in the
[HTTP/1.1 standard-library chapter](../language/standard-library-http.md).
This chapter describes the `titan.http` folder module, its synchronous llhttp
callback bridge, streaming parser ownership, and high-level server composition.

## Folder-module structure and layering

The canonical `titan/http/http.titan` main imports `titan.net`, `titan.ssl`,
`titan.io`, `titan.async`, `titan.peg`, `titan.string`, and `titan.math`. Its
immediate contributors share one module-private scope:

```text
titan/http/http.titan       imports and initialization
titan/http/client.titan     one-request client and ClientResponse
titan/http/headers.titan    ordered public Headers value
titan/http/native.titan     private parser owner and callback event queue
titan/http/server.titan     Request, Response, and per-connection serving
titan/http/url.titan        module-initialized RFC 3986 PEG and normalization
```

The only HTTP-owned native boundary is the synchronous callback bridge in
`titan/http/native/titan_httpshim.{c,h}`. It has no network or Task operation.
HTTP obtains every byte from the public `io.ReaderWriterCloser` view of either
a `net.Connection` or an `ssl.Connection`, and writes through that same view.
URL parsing calls the public `titan.peg` API without an HTTP-specific C bridge.
The module neither imports nor changes `titan.uv`.

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
body is buffered and how pipelined bytes survive one message boundary.

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

## Headers, URLs, and framing

Headers use an Array of public `Header` records. Lookup performs ASCII folding
without normalizing stored spelling, so duplicate order remains available to
protocol checks and applications. Construction/mutation rejects invalid token
names and field values containing controls other than HTAB or containing DEL.
The parser appends fields only on llhttp's complete
value event, after trimming optional whitespace.

The URL parser is a Titan translation, written in `titan.peg`'s Relabel source
notation, of the RFC 3986 URI grammar from daurnimator/lpeg_patterns commit
`0da7cadb867858f8fdf2bfbfbc92a51a7c28c3d7`. The derived grammar is used under
the upstream MIT license recorded in `THIRD_PARTY_NOTICES.md` and
`LICENSES/lpeg-patterns-LICENSE`.

The folder main's one-time module initializer calls `url_pattern()`, which
compiles the relabel source through public `titan.peg`, and stores the resulting
`peg.Pattern` in `http_url_pattern`. Every parse uses that stored pattern
directly. The grammar captures the component text plus the starting byte
positions needed for semantic errors. Its public specialization requires an
absolute authority URL and nonempty host, labels userinfo and fragments as
unsupported, requires brackets around IP literals, and constrains an explicit
port syntactically to digits. Titan code then accepts only `http`/`https` and
checks the numeric port range `1..65535`.

Relabel failures return a stable label and one-based byte position. The
`url_parse_message` boundary renders them as
`HTTP URL parse error [label] at byte N: detail`; semantic scheme and port
failures use the captured component positions and the same format.

`normalize_component` decodes percent-encoded RFC 3986 unreserved bytes and
uppercases the hexadecimal digits of every retained escape. Its lowercase
mode additionally canonicalizes schemes and registered-name hosts.
`normalize_host` distinguishes registered names, IPv4, IPv6, IPvFuture, and
RFC 6874 zones: connection identity omits URI brackets and decodes a zone's
`%25` separator to `%`, while the stored authority keeps brackets and the
encoded separator for `Host`. Default ports are assigned only when absent;
explicit ports are rendered from their parsed integer. An empty path becomes
`/`, and the normalized path plus optional normalized query forms `URL.target`.

The client connects with normalized `URL.host`, uses normalized
`URL:host_header()` when it generates an absent Host field, and sends
normalized `URL.target`. The server runs the same parser over `scheme://` plus
the exact received Host and origin-form target, after rejecting `/`, `?`, `#`,
or `@` in Host so it cannot consume or reinterpret the independently parsed
target. `Request.target` remains that received target, while `Request.url`
provides the normalized routing view.

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

## The idle-timeout composition blocker

HTTP/1.1 keep-alive and pipelined suffix preservation require no lower-level
primitive. A robust idle deadline does. The public async facade has Task
creation and cancellation plus timers, but no current-Task accessor, join,
race, or deadline operation. A timer Task cannot simply cancel and be joined
by the connection Task. Implementing the policy locally would require a
connection-specific watchdog, generation tokens around every reuse interval,
and carefully fenced close/cancellation behavior.

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
`luaopen_titan_http`. Together SSL and HTTP advance the coordinated current
standard image to sixteen logical modules and shims and seventeen DSO openers
including bare `luaopen_titan` support. A valid fourteen-module ABI-0.20 image
remains an explicitly recognized publication predecessor; that historical
migration count is not the current provider contract.

Focused standard-library tests run outside LuaCov. They fragment protocol
input down to individual bytes, exercise fixed/chunked/EOF bodies, duplicate
headers, streaming handlers, unread-body draining, keep-alive, pipelining, and
HTTPS over the public SSL facade. The sanitizer boundary uses that same
high-level path through TLS and llhttp rather than a private test transport.
