# HTTP-library implementation

The public API and behavior are documented in the
[HTTP/1.1 standard-library chapter](../language/standard-library-http.md).
This chapter describes the `titan.http` folder module, its synchronous llhttp
callback bridge, streaming parser ownership, and high-level server composition.

## Folder-module structure and layering

The `titan/http/http.native.titan` main imports `async`, `io`, `math`, `net`,
`protobuf`, `reflect`, `ssl`, `string`, `timer` and `url`; `server.titan` adds
`uv`. The contributors (`Makefile` `STDLIB_HTTP_SOURCES`) share one
module-private scope:

```text
titan/http/http.native.titan       imports and initialization
titan/http/client.titan     request/response exchanges and ClientResponse
titan/http/pool.titan       Client pools, idle leases, bounded background drains
titan/http/headers.titan    ordered public Headers value
titan/http/native.titan     private parser owner and callback event Array
titan/http/server.titan     Request, Response, and per-connection serving
titan/http/transfer.titan   paired Exchange handoff and parser snapshots
titan/http/upgrade.titan    owned upgrade stream, opening supervisor, handoff
```

The only HTTP-owned native boundary is the eight synchronous source
`foreign function` callbacks in `titan/http/native.titan` (`llhttp_url_cb`
through `llhttp_message_complete_cb`). They have no network or Task operation.
HTTP obtains every byte from the public `io.ReaderWriterCloser` view of either
a `net.Connection` or an `ssl.Connection`, and writes through that same view.
URL parsing calls the independent public `titan.url` module without an
HTTP-specific C bridge. HTTP imports public `titan.uv` for the borrowed Runtime-loop identity, monotonic
`hrtime` deadlines, and the `uv.req_t?` type of named Completion registrars. It adds no native
network boundary and does not change UV.

## Synchronous llhttp callback bridge

llhttp invokes callbacks synchronously inside `llhttp_execute` and
`llhttp_finish`. Ordinary Titan closures are not C function pointers, so
`native.titan` defines the exact restricted source foreign entries and follows
the same callback-owner protocol without introducing an asynchronous boundary.

The Titan `Parser` record embeds its `llhttp_t` and `llhttp_settings_t` in
its own native payload (`new_parser`). Construction precedes settings/llhttp initialization,
so native self-pointers target the final stored objects. Its fields also hold the Lua state active for
the current synchronous parse and one exact Titan closure for each registered
llhttp callback: URL, status, header field, header value, header-value complete,
headers complete, body, and message complete. `llhttp_t.data` points back to
that Parser owner. Each correspondingly named source callback recovers the
owner and uses `ffi.titan_record_field` to read its active Lua state and
callback without assuming UV indices. It extracts the closure's module and native
entry, invokes that exact generated Titan signature, and restores the previous
stack top. The synchronous caller and ordinary callback keep the Parser traced
through the invocation.

The foreign-function boundary allocates no parser, event descriptor, arena, or
copied byte storage. It has no execute, finish, reset, getter, event-accessor, pause-policy,
or error-policy wrapper. There are no non-callback trampolines; Titan calls the
ordinary llhttp API directly.

Each Titan data callback copies its borrowed llhttp span into a Titan string
before returning and appends a typed `Event` to the Parser's GC-owned `{Event}`
Array. The headers-complete and message-complete callbacks snapshot the llhttp
metadata that belongs to their boundaries and select the documented llhttp
return codes. Callback code catches every Titan error before returning through
llhttp, stores the failure on the Parser, and returns `HPE_USER`
(`callback_failure`); it never unwinds through the C parser.
After the synchronous call returns, Titan either re-raises that stored failure
or drains the typed events into the high-level parser state.

`llhttp_execute` borrows its input while those callbacks may allocate and
collect. The immutable input string is `execute_input`'s parameter, so its
caller's argument roots it for the entire execute, callback, consumed-suffix,
and event-drain interval, and the function pushes nothing to root it. The
span pointers remain valid only during their individual synchronous callbacks,
and no callback retains one. Both execute and finish first reserve Lua stack
space for the source foreign entry's temporary owner root and the generated
callback frame.

## Pausing and streaming ownership

Each parser pauses after headers and after message completion
(`headers_complete_callback`, `message_complete_callback`). A pause may
occur before the end of the supplied network chunk, so `execute_input` subtracts
`llhttp_get_error_pos` from the still-rooted input pointer and retains the
unconsumed suffix in `Parser.input_excess`. Resuming first consumes that suffix before another
high-level connection read. This is how a handler can begin before the request
body is buffered and how bytes already read for a later request survive one
message boundary.

A header pause at the exact end of a transport chunk can leave llhttp on an
epsilon transition to message completion. After resuming with no retained
suffix, `advance_parser` executes one empty input before attempting another socket read.
That lets a bodyless message reach its message-complete pause instead of
deadlocking with a peer that is waiting for the response.

Body callbacks are copied into a Titan Array of chunks. `parser_read` consumes that
array incrementally and clears it once drained; new network input is requested
only when no buffered body event remains. `parser_read_until` composes over those
logical body chunks and retains only the bytes following its delimiter.
llhttp itself removes Content-Length and chunked framing. The parser reaches
the high-level Reader only after strict message-shape validation.

Request parsing pauses at headers, constructs the public `Request`, and hands
the same private parser owner to its Reader methods. On handler return, the
connection Task closes the Response and drains any unread request body before
resetting llhttp. Reset (`parser_reset_message`) clears per-message Titan fields but preserves the
already retained network suffix and the response-to-HEAD policy where
applicable.

Response parsing likewise pauses at headers so `request` can return a
`ClientResponse`. Informational responses are drained and the parser reset
until a final status is reached. An exact, case-sensitive `HEAD` request
configures llhttp's response semantics before all informational/final parsing;
case-distinct extension methods retain ordinary body semantics. Reading body
EOF releases the parser and returns an eligible transport to its owning Client pool.

## Client pooling and abandoned-body draining

`Client` owns idle `ClientConnection` leases and `ClientDrain` workers. A lease
captures its public ReaderWriterCloser, concrete abort capability, conservative
input-state query, pool key, and idle timestamp before Interface erasure. The
key length-prefixes scheme, normalized host, port, effective Host, and HTTPS
trust path (with default trust distinct from a file); HTTP ignores the CA path.
There is no DNS-address coalescing, native socket access, or private net/SSL import.

Acquisition binds a Client to `async.current_loop()` and installs one
`async.add_close_listener` (`pool.titan` `Client:bind`). Explicit close detaches the listener, marks the
Client closed, detaches idle leases and drains before any suspension, then
retires them. Runtime notification runs only after every Task and raw handle
has retired, when idle TCP close and TLS abort are synchronous. The default
Client reference is cleared on exact owner identity. Caller-owned active
responses retain their existing explicit-close responsibility. A Lua state
close runs no close listener; the abandoned loop closes idle sockets and the
[TLS state-close finalizer](ssl-library.md#lua-state-close) frees idle engines.

Acquisition removes the newest matching lease before I/O. Pool mutation and
selection finish before closing expired or dirty connections, because abort
may yield. Release admits only complete, persistent, non-EOF messages with no
parser suffix or transport input. A fresh parser is allocated per exchange.
The caps are 100 idle leases overall, two per key, and 90 seconds idle age
(`CLIENT_MAX_IDLE`, `CLIENT_MAX_IDLE_PER_KEY`, `CLIENT_IDLE_NS`);
age checks happen on pool activity without a keepalive timer Task. Active
responses and drains are never in the idle Array. Input is checked on release,
on acquisition, and again inside the supervised exchange before output, so
bytes delivered while that child is queued cannot become the next response.
While idle, a lease also registers the concrete public input observer
(`Client:watch_idle`). An
arrival removes the observer, roots a `ClientRetirement`, schedules its abort
Task, and removes the idle lease before that Task can run. Scheduling failure
leaves the original idle root available to Runtime cleanup. The retirement
registry also covers a worker cancelled before its first instruction. This
prevents an unused socket from accumulating unbounded data. Observers are
removed from every captured idle lease before potentially yielding close work;
no persistent waiting Task delays Runtime shutdown.
Once shutdown begins, native handle retirement and the Client close listener
own final cleanup. This implements the no-unsolicited-response requirement of
[RFC 9112 section 9.2](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.2).

Healthy TLS eviction and fully framed nonpersistent response retirement run
ordinary `ssl.close` in a supervised child with a 50 ms timer
(`ClientConnection:close_idle`, `CLIENT_CLOSE_MS`). Timeout, failure,
or cancellation aborts before draining that child. All watchers are detached
before close may suspend; a selected lease stays lexically guarded across
expiration cleanup, followed by a Client rebind/check before transfer. Dirty
input and Runtime retirement take the direct abort path. Response ownership
commits before graceful close can yield, so a repeated close cannot interrupt
its already-owned cleanup. Supplied upgrade abort capabilities retain their
retry-after-failure behavior.

A stale reused connection gets one fresh attempt only for exact GET/HEAD with
nil body, no received response byte (including interim responses), and selected
EOF/reset errors (`Client:request`, `stale_client_failure`). `Parser.input_received` is sticky across interim resets;
`input_seen` remains message-local. A cancellation checkpoint precedes retry.
Other failures propagate with their original error and traceback. Detecting
dirty idle input before output instead discards the lease and fresh-dials any
method because no request was sent. Ordinary request I/O uses the same
abort-before-child-drain supervisor as protocol takeover.

Response close relinquishes reader ownership immediately. A complete eligible
message releases directly; an incomplete eligible body transfers its parser
and lease to one supervised drain (`ClientResponse:close`, `ClientDrain:run`).
The worker measures an absolute 50 ms budget from close with `uv.hrtime`, races
an owned reader against the remaining time, and limits unread decoded bytes to
256 KiB (`CLIENT_DRAIN_NS`, `CLIENT_DRAIN_BYTES`). Known larger Content-Length
remainders, nonpersistent messages, EOF framing, errors, and upgrades skip the
drain. The response captures wire framing/persistence at header completion;
mutating public headers later cannot change reuse eligibility.
`Parser.body_consumed` includes delivered decoded chunks and subtracts retained
`read_until` suffixes, so the allowance counts bytes still unread by the caller.

A drain succeeds only after message completion and trailer validation. Before
release, it detaches from the drain registry; otherwise a concurrent Client
close could abort a lease already used by another request. Its fallback abort
is armed before worker allocation/publication. On timeout, cancellation, or
failure it aborts first, then waits for the exact reader's terminal cleanup
before closing parser state. Closing during a foreground read instead retires
the transport and leaves parser cleanup to that reader's defer. Background
errors are contained because the response is already logically closed. The
bounds follow [Go's connection-reuse design](https://go.dev/blog/http-connection-reuse).

## Bounded opening and protocol takeover

Each server request snapshots `Server.header_limit_bytes`, defaulting to
65536. The explicit upgrade client uses the same bound per response header
block. Ordinary client response parsers have no header-byte limit
(`new_parser` defaults `header_limit` to `math.maxinteger`). Before
`llhttp_execute`, `execute_input` limits the native span to the remaining raw header
budget, then counts the actual consumed offset. This bounds callback event
copies before they allocate attacker-controlled text and counts all raw bytes,
including leading lines, the start line, punctuation, and line endings. The
first header-complete pause ends accounting; bytes beyond that pause remain
in `input_excess`, including a coalesced binary protocol suffix. Reset clears
the header count for the next block. An incomplete header block that exhausts
its budget raises before another parse or transport read. The upgrade client
also rejects a seventeenth interim response.

Request parsers retain llhttp's upgrade indication. Complete header acquisition
is separate from HTTP/1.1 version validation: an Upgrade field, a Connection
upgrade token, or llhttp's indication selects the opening prefilter. Before
constructing a Request, it validates HTTP/1.1, one Host field, the public
`url.parse_request` result, and absence of Expect. Semantic failure sends a
fixed bodyless 400 and closes without dispatch or body drain. Acquisition I/O
and Task failures are outside these synchronous checks and keep their own
error and cancellation outcomes. Valid candidates reach the ordinary handler.
Ordinary HTTP response parsers continue rejecting upgrades.
`request_upgrade_on` uses an upgrade-enabled response parser, stops at 101, and
returns a pending ClientResponse instead of draining it as informational input.
Its supplied public abort action is retained before transport erasure; HTTP
does not dial. A pending 101 rejects body reads. `take_upgrade` constructs the
owning stream and Interface view before committing one-shot transfer, clears
the parser's suffix ownership, closes parser state, and disarms the response's
transport close. Non-101 responses keep their streaming body and abort owner.

The server records one `Exchange` identity per request/response pair. That
owner holds the parser, concrete-captured transport capability, live state,
response-output state, and transfer/rejection state. `Response:upgrade` checks
exact Exchange identity, live state, and no prior output, including an emitted
100 Continue. It checks Upgrade/Connection, rejects HTTP body framing, and
prepares validated 101 bytes plus the owning stream and Interface before
output begins. A successful write is followed by a nonyielding transfer commit.
Request body and Response output operations then reject reuse. The connection
Task skips response finishing, body draining, parser reset, and its outer
transport close when transferred. An unaccepted candidate instead completes
the handler's ordinary closing response and returns at the first header pause;
its opaque suffix is never parsed as HTTP.

`reject_upgrade` validates the same live pair even for malformed openings that
llhttp did not classify as upgrades. It accepts a 400..599 status and copied
headers without supplied framing, adds Content-Length zero and Connection
close, and writes one bounded rejection through `Response:write_upgrade_output`. It marks the exchange rejected,
closes the parser, retires transport, and tells the connection loop to skip
body drain. Both success and rejection output blocks have a 64 KiB cap.
Both paths start from copied unsent Response fields and append copied supplied
fields, preserving handler header customization before controlling framing and
Connection/Upgrade.

Suspending upgrade I/O runs in an owned child with a cancellation-sensitive
parent join (`upgrade.titan` `supervised_http_io`). The parent's lexical cleanup remains independently runnable while
the child awaits accepted transport output. On interruption it invokes the
captured abort action before requesting child cancellation and draining the
child with `await_terminal_cleanup`. This order lets cancellation retire
backpressured accepted native writes before releasing parser or immutable
output state. Child exceptions retain an `async.Error` containing the exact
value and origin traceback; the parent uses `Error:raise` after cleanup.
Cleanup failures do not replace an earlier failure. No operation
joins an unrelated handler or session Task.

The opaque `UpgradedStream` retains `Transport` (the public
ReaderWriterCloser plus abort action) and the unread immutable prefix. Its
first reads consume that prefix before transport reads. Delimiter search
retains a delimiter-length tail across prefix/transport boundaries and stores
only input following the delimiter as new prefix. It admits one stream reader
and forwards writes directly. Closing marks it closed, discards prefix, and
invokes abort, including when its reader is suspended. HTTP captures
`net.Connection:close` or `ssl.Connection:abort` while the concrete accepted
type is known. There is no identity inspection, private TLS/UV access, or
native socket bypass.

## Headers, URL consumption, and framing

Headers use an Array of public `Header` records. Lookup performs ASCII folding
without normalizing stored spelling, so duplicate order remains available to
protocol checks and applications. The folding (`headers.titan` `lower_header_name`) uses `string.gsub` over
`[A-Z]`, rather than locale-sensitive `string.lower`, because HTTP field-name
case is ASCII-defined even after an application changes the process C locale.
Cached `string` regex matching validates token names and rejects field values
containing controls other than HTAB or containing DEL. The parser appends
fields only on llhttp's complete value event, after trimming optional
whitespace.

Upgrade fields use a separate protocol-name[/protocol-version] parser, so a
versioned offer does not invalidate another offered protocol. Matching folds
only the protocol name and compares version tokens exactly. Connection keeps
its bare-token option grammar. Both upgrade entry points validate their selected
protocol with the Upgrade grammar before adopting a transport or writing bytes.

Strict llhttp already applies the same name/value checks to received fields
and parses inbound Content-Length syntax and framing. Titan repeats the
name/value checks when constructing `Headers` to preserve the public record's
invariant and still validates outbound fields, methods, response reasons, and
Content-Length values before serializing them. llhttp treats a received reason
phrase as an opaque span up to CR/LF, so the client applies Titan's field-value
byte check to every informational and final response reason as well.

The reusable grammar, labels, normalization, and `(Url?, Error?)` boundary are
owned by `titan.url` and documented in the
[URL-library implementation chapter](url-library.md). HTTP's local adapters
call `url.parse` for an absolute client URL and `url.parse_request` for a
separate scheme, Host authority, and origin-form target, raise the structured
`url.Error` when parsing fails, and otherwise unwrap the `url.Url`. HTTP does
not re-export either record or either parse function.
Absolute client entry points additionally require exactly `http` or `https`,
so URL's additive `ws`/`wss` policy cannot route a secure WebSocket URL through
plain HTTP transport selection.

The client connects with normalized `Url.host`, uses normalized
`Url.authority` when it generates an absent Host field, and sends normalized
`Url.target`. HTTPS passes its sole optional `ca_file` through to
`ssl.connect`; HTTP neither reads trust paths nor exposes a CA-directory
parameter. The SSL layer performs explicit CA-file I/O through high-level
`fs`. The server passes the scheme, exact received Host, and origin-form target
to the URL module as separate values, so an authority delimiter cannot consume
or reinterpret the independently parsed target. `Request.target` remains that
received target, while `Request.url` provides the normalized routing view.

The client copies supplied headers, validates Content-Length, rejects request
Transfer-Encoding and Expect fields, and preserves supplied Connection fields.
An explicit close token disables reuse; HTTP/1.1 is otherwise persistent. The
optional request body is assembled with the preamble as one high-level write;
only response bodies stream. Rejecting Expect is therefore deliberate: the
client must not advertise a `100-continue` handshake that it does not honor. A
supplied singleton Host is parsed by the URL module's separate-input request
entry; this enforces authority boundaries, host, bracketed IP-literal, and
optional-port syntax before opening the connection.

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
(`server.titan` `accept_request_expectation`) before it can call a handler that waits in `Request:read`. An OWS-trimmed,
case-insensitive `100-continue` is accepted only as one complete singleton
field and writes the exact interim response synchronously. Every other value,
comma-combined value, or repeated field produces a framed zero-length 417 and
returns from the connection loop without draining the declared body. The
deferred transport close makes that rejection safe without parser reuse.
Upgrade-indicated requests carrying any Expect take the preconstruction
bodyless 400 path described above. Checking both parsed fields also covers
malformed openings that llhttp does not classify as upgrades, preventing 100
output before a handler's one-shot upgrade or rejection.

## Server Tasks and the interface conversion boundary

`Server:serve` owns the accept loop. Each accepted connection is converted to
`io.ReaderWriterCloser`, paired with its public abort capability, and scheduled
in a fresh `async.run` Task. The accept
loop retains lexical close ownership until the child acknowledges that its own
close defer is armed. An `await_cleanup_with` startup wait and terminal listener
cover both normal entry and termination before entry. Failed scheduling or
registration leaves fallback cancellation, terminal draining, and close with
the accept loop. No yield count proves ownership transfer.

A private `ConnectionHandoff` context (`start_connection_handoff`) holds the
connection, Server, child, transfer flag, notification flag, and listener remover. Its named registrar captures the
Completion and exact suspension number in the acknowledgment callbacks; those
callbacks keep using that number even if settlement starts another wait on
the parent Task. Connection-close fallback is installed before allocating the
context. The notification flag is committed only after successful settlement,
and the terminal listener is still removed by lexical cleanup. Child-entry,
acknowledgment, notification, and terminal-listener closures remain part of the
handoff; naming the registrar does not remove their ownership roles.

The child arms connection close before acknowledgment and parser construction,
so even parser construction failure has a transport owner. Different connection
Tasks then progress independently while each one's requests remain ordered.

The high-level constructors keep required values before optional configuration:
plain `listen` takes host and handler before optional port, backlog, idle
timeout, and `reuse_port`, while `listen_tls` takes host, certificate, and
handler before optional private-key path, port, backlog, idle timeout, and
`reuse_port`. The plain/TLS port defaults are 80/443. Both pass the optional
backlog and reuse flag unchanged to `net.listen` (directly or through
`ssl.listen`), which owns their defaults and the `uv.TCP_REUSEPORT` bind; TLS
likewise delegates the omitted-key PEM-bundle behavior to `ssl.listen`. Idle
timeout defaults to zero and is validated before listener creation or TLS PEM
reads.

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

`Response:abort` uses the existing `Exchange.active` ownership guard. It marks
the exchange inactive and the response closed before invoking the exchange's
captured public transport-abort capability. No new transport identity lookup,
native handle, or duplicated retirement state is needed. The server checks
that guard after handler return and skips response finishing and request-body
draining for an aborted exchange. Its existing deferred parser/transport
cleanup remains responsible for final retirement. An inactive retained
response cannot affect a later keep-alive exchange or an upgraded stream.
TCP close and TLS abort retain their cancellation-insensitive contracts.
Ordinary header output reserves `headers_sent` before its first transport write,
so a failed or pending header write cannot be retried with mutated status or
fields. Informational `100 Continue` does not reserve the final response.
Upgrade output rechecks the live exchange after its supervised writer returns,
before transferring ownership, because a sibling may have aborted it meanwhile.

`ClientResponse:close` marks the public response closed before transferring an
unread reusable parser/transport to bounded background draining. A completed
message can return its transport immediately. Non-reusable exchanges close the
parser and retire transport cancellation-insensitively. A read failure always
retires its connection and preserves the original error. `Server:close`
similarly marks the high-level listener closed before
delegating to `net.Server` or `ssl.Server`, then records listener completion
after the delegate returns. Those underlying ownership-retiring close operations are
cancellation-insensitive: pending cancellation neither prevents submission
nor replaces their ordinary callback completion. Cleanup therefore finishes,
the completion flag is recorded, and only then can the Task publish terminal
cancellation; every later `close()` is an immediate no-op. This is a concrete
resource contract, not an HTTP queue or scheduler.

## Serial keep-alive and idle-timeout composition

The server implements one serial request/response cycle per connection Task.
It does not expose a pipelining API or schedule concurrent handlers for one
connection. A handler finishes its response and the server drains any unread
request body before resetting the parser for the next keep-alive request.
The retained parser suffix ([pausing](#pausing-and-streaming-ownership)) only
preserves bytes a read happened to include; it is not a pipelining queue.

After a keep-alive reset, header acquisition treats EOF with no next request as
a normal idle peer disconnect. `llhttp_finish` also succeeds after some
non-message input, including complete leading CRLF request lines and a dangling
first CR. A Titan flag therefore records every nonempty parser input after
construction or reset; internal empty executions used for llhttp epsilon
transitions do not set it. Only byte-empty EOF is idle. CRLF-only input, a
dangling CR, and every other request prefix take the existing
incomplete-message or llhttp parse-error path. Leading empty lines followed by
a real request remain accepted. The server maps only the idle outcome to normal
connection-Task return; a client awaiting its first or final response maps the
same outcome back to an incomplete-message error.

At the start of each serial request iteration, the connection Task reads the
Server's `idle_timeout_ms`; the shared header-acquisition helper
(`server.titan` `read_request_with_idle_timeout`) takes the encryption mode and
timeout as explicit values, so either serving loop passes its own per-request
snapshot. Zero reads directly. A positive value starts a header-reader Task and
a timer Task and uses `async.race_two`:

- **Reader.** Always owned by a cancel-and-terminal-cleanup defer, including
  when parent cancellation interrupts the race or deadline creation fails.
  Before draining an unfinished reader, the parent calls the captured public
  transport abort: the reader may own malformed-upgrade rejection output whose
  accepted native write cannot detach. The terminal wait uses
  `async.await_cleanup_with` plus a removable terminal listener
  (`TerminalCleanup`, `start_terminal_cleanup`), so pending parent cancellation
  cannot release the shared parser or connection before the child finishes. An
  SSL read retains its directional operation scope until that cleanup finishes.
- **Timer.** Has unconditional, idempotent cancellation cleanup but is never
  joined: its native close owns no parser or transport state, and waiting would
  change observable successful-reader ordering.

Reader success supplies the `Request?` and cancels the timer. Timer success
cancels the reader with the timeout reason and is an ordinary silent connection
return. A failed child has already emitted its Task-local error and traceback,
so the parent applies the same ownership rule to its peer and returns instead
of raising the same failure a second time.

On HTTPS, cancelling the child read follows `ssl.Connection`'s existing
terminal cancellation path: it frees the TLS engine and closes the transport
without `close_notify`, so the remote peer observes `TLS_TRUNCATED_EOF`.
TLS cancellation remains terminal under the full-duplex contract. HTTP neither
reaches through to `uv` nor adds native state to simulate a graceful timeout.

The deadline is absolute from that iteration's start and does not reset on
partial header bytes. The setter changes only later iterations. Handler work,
request bodies, automatic draining, and ordinary response writes remain outside
the policy. The pre-handler malformed-upgrade output uses the existing upgrade
I/O supervisor inside the header reader, so the same absolute deadline covers
its completion. Transport and scheduling use high-level `async`, `timer`, and public
connection operations. The UV import supplies the registrar return type;
there is no connection-local watchdog or generation protocol.

## Cross-state exchange ownership

The generic manual-handoff rules (exactly-once adoption, explicit discard,
lossy carriers, buffered-input snapshots, stream eligibility including Windows
pending reads) are in
[manual resource handoff](transfer-library.md#manual-resource-handoff). This
section covers the HTTP gate and schema.

`Server:read_ahead(enabled?)` stores a listener policy, defaulting to true.
`accept_connection` applies it through the public TCP/TLS Connection method
before parser or lazy TLS handshake input. It affects future accepted sockets
only. Demand mode stops each native read before publication, allowing Windows
header classification followed by an explicit callback-retirement yield and
ordinary Exchange handoff.

`ExchangeState` (`upgrade.titan`) remains the shared private owner of the
parser, captured transport, and admission flags. Public `Exchange`
(`transfer.titan`) bundles its matching `Request` and `Response`; its custom
hook detaches that shared owner once. Request reads, response output/close, and
supervised upgrade output hold `pending` across their entire operation,
including queued native completion. The `serving` flag rejects nested or
competing `Exchange:serve` loops while permitting an idle handler to transfer
the pair. Destination reconstruction starts without a serving owner and
registers one when `serve` starts.

`Exchange:to_transfer_payload` validates state, snapshots metadata and buffers,
then delegates the transport move to the concrete public TCP/TLS hook
(`transfer_transport`). Only after successful detachment does it mark the
source exchange transferred/inactive and close its old parser. The private
anonymous-root protobuf schema (`exchange_transfer_fields`) contains copied
scalar, header-array, URL and parser fields plus the known transport kind and
child bytes. If that final encoding raises, a lexical guard discards the
detached transport; the source stays inactive, so the original server's defer
cannot close an adopted transport. `Exchange:serve` follows the same serial
request/framing loop with a destination-supplied handler; subsequent
transfers/upgrades retain the same ownership guard. Its optional non-negative
`idle_timeout` defaults to zero and uses the shared header-acquisition helper
only after the current handler, response closing, body draining, and keep-alive
reset. The current exchange was already parsed before adoption; its handler and
response are never covered by this deadline. Each later header wait gets the
supplied absolute deadline, independent of the originating Server. Negative
values are rejected before any serving ownership changes. A single-exchange
consumer uses `Exchange:close` to finish its response and retire the transport.

`parser_handoff_bytes` copies the pinned llhttp state as process-local bytes
and clears the source `data`, `settings`, `_span_pos0`, `error_pos` and
`reason` pointers. The remaining pointer-typed fields are safe to copy: llhttp's
`_current` is an integer state selector represented as a pointer, and
`_span_cb0` names immutable native parser code. The decoder constructs fresh
Parser settings, callbacks, and Lua-state ownership, then installs its local
`data`/`settings` pointers. A live span is restored with a local nonnil
`_span_pos0` marker: llhttp restarts every live span at the next input before
reading it. Copied semantic fields preserve partial body and trailer state,
delimiter excess, and buffered next-request input. The usual
`Request.headers`/`Parser.parsed_headers` alias is restored so later trailers
remain visible through the request.

`UpgradedStream` is public with private fields so it can participate in the
custom record protocol. It transfers the native transport plus its unread prefix
and rejects active reads/writes. Ordinary upgrade retirement continues to use
the captured abort capability. Handoff explicitly unwraps only `net.Connection`
and `ssl.Connection` owners and rebuilds that capability in the destination;
other Interface implementations are rejected before ownership changes. Its
private schema carries prefix, transport kind and child bytes.

`UpgradedStream.discard_transfer_payload` and
`Exchange.discard_transfer_payload` decode their schema and delegate to
`discard_transfer_transport`, which retires the known TCP/TLS child directly.
Neither reconstructs a parser or adopts a handle, so failed delivery can retire
a packet without a live Runtime. WebSocket uses the `UpgradedStream` form.

## Native build and provider composition

The Makefile pins llhttp 9.4.3 (`LLHTTP_VERSION`) and verifies its source
tarball. The three generated sources `llhttp.c`, `http.c`, and `api.c`
(`LLHTTP_SOURCE_NAMES`) compile as hidden PIC objects in the private
deterministic `llhttp-build/libtitan-llhttp.a`. Those three objects are the
complete metadata-free llhttp payload; there is no adapter object, because the
eight callback definitions live in the generated `titan.http` object. There is
no system-llhttp mode, and neither the private archive nor its headers are
installed as runtime-SDK files. Its position in the `-X` payload order and the
rest of the standard-library image are described in
[the standard-library image](multi-module-libraries.md#reserved-titan-and-the-standard-library-image).

## Verification

Focused standard-library tests run outside LuaCov. They fragment protocol
input down to individual bytes, exercise fixed/chunked/EOF bodies, duplicate
headers, token/value byte boundaries, decimal overflow, opaque inbound reason
rejection, structured Host errors, rejected non-origin request targets,
streaming handlers, unread-body draining, clean idle versus partial keep-alive
EOF, and next-request suffix retention when buffered input survives a serial
keep-alive parser reset. Idle-timeout cases validate the public configuration,
require completion before an unrelated-listener watchdog can wake the loop,
send periodic partial headers to distinguish the absolute deadline from an
inactivity timeout, and keep handler-side body reads and automatic draining
outside that deadline. A buffered follow-up request proves that reader success
does not wait for the cancelled timer, while timeout coverage proves that the
connection does wait for reader cancellation before teardown. Plain and TLS
cases cover initial and keep-alive waits; TLS additionally proves partial-header
cancellation and the peer's exact `TLS_TRUNCATED_EOF`. They also prove
listener/response close completion under cancellation without a retry. The
focused sanitizer boundary drives the same timeout-induced SSL-read
cancellation and serial HTTP path through public TLS and llhttp, rather than a
private test transport.
