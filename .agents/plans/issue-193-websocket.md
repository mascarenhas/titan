# Durable implementation goal for issue 193

The maintainer authorized implementation on 2026-10-04. Implement the complete
researched WebSocket contract below in a new `codex/issue-193-websocket` branch
split from `codex/issue-196-async-allocations` at
`06c3bec954dc2b7da7e19d16e3191cf0b84f17fc`. Deliver a pull request targeting that
base branch as the next unmerged member of the existing stack. WebSocket is the
first module designed from the outset on the public libuv/async stack; preserve
that ownership and layering rather than introducing a separate scheduler.

Include public resolved-address TCP dialing, lazy verified TLS adoption and
full-duplex TLS with independent abort, bounded HTTP upgrade parsing and exact
prefix/transport ownership transfer, strict RFC 6455 framing and UTF-8, opening
serialization, cancellation/timeout retirement, and the specified client/server
policy. Follow the issue's detailed design/review/conformance amendments as the
implementation baseline; historical research-only statements below describe
that earlier session and do not restrict this implementation authorization.

Do not change Titan release numbers, the generated-code ABI, the SDK layout
version, or the prerelease language-server API marker. Integrate the logical
module into every exact source/provider/shim/archive/test-root inventory and
publication contract. Keep issue-196's frozen benchmark matrix and historical
results unchanged; measure WebSocket allocation, retention, timing and fairness
separately with source/provider provenance.

Deliver both human documentation in `doc/language` and implementation
documentation, linked from their indexes, plus a tailored `titan-websocket`
agent skill referenced by the main Titan programmer cartridge. Update affected
TLS, HTTP, networking, URL and tester contracts and checked examples.

Validate locally: focused native regression and ownership tests, both pinned
Autobahn roles with strict exact reports, applicable sanitizer checks, the full
Linux suite, complete macOS VM gates including both OpenSSL production modes
with the tested architecture recorded, and real Windows VM shared native,
publication/rollback and PE-import gates. Never substitute a VM boot or source
probe for executed tests. Hosted macOS dispatch remains unauthorized.

Obtain independent implementation and documentation/skill reviews, resolve
findings, commit and push the focused branch, create/attach the stacked PR, and
read back Linux CI at its actual final head. Preserve all existing stacked PRs
and the new PR unmerged. The maintainer explicitly authorized information
sharing with concierge Oobii and agents Oobii recruits. Report evidence and
remaining platform limitations accurately. Mark the session goal complete only
when the requested delivery and validation are achieved.

---

# Preserved research baseline

Add a new `titan.websocket` stdlib module (short name `websocket`) that implements websocket server and clients. The server should be pluggable into a `titan.http` server as a handler (for either the regular or SSL server).

Instead of being event-based like Node.js websocket API the interfaces for both the server and the client should look more like a regular Titan network sockets, with "blocking" reads and writes.

The client should also work with SSL `wss` URLs.

See https://github.com/coder/websocket for a Go implementation that is likely closest in spirit to what an idiomatic Titan implementation would be.

Use https://github.com/crossbario/autobahn-testsuite for conformance testing.

---

## Researched implementation plan

Research for [issue 193](https://github.com/mascarenhas/titan/issues/193), based on `codex/issue-196-async-allocations` at `06c3bec954dc2b7da7e19d16e3191cf0b84f17fc`, 2026-10-04. This is a proposed implementation contract and work sequence. No production implementation has begun. Revised after two independent reviews arranged by Oobii; see the [review synthesis and delivery appendix](https://github.com/mascarenhas/titan/issues/193#issuecomment-5976748176) for the independent findings, dispositions and amendment-check scope.

The recommended result is a message-oriented `titan.websocket` module, imported as `websocket`, with direct Task-blocking calls, an `accept` call usable inside an ordinary HTTP handler, and verified `ws`/`wss` clients. Build it on a real HTTP upgrade handoff and full-duplex TLS. The largest prerequisite is TLS ownership, not frame encoding.

## Maintainer decisions

**D1 resolved:** the maintainer selected "Include full-duplex TLS prerequisite" on 2026-10-04. Plan for one TLS reader and one TLS writer to progress concurrently, with serialized synchronous OpenSSL engine access. This is approval of the plan's scope; the research session remained research-only and did not authorize implementation.

Current `ssl.Connection` holds one `busy` bit throughout read, write, handshake and close, including network waits ([`titan/ssl.titan:278`](https://github.com/mascarenhas/titan/blob/06c3bec954dc2b7da7e19d16e3191cf0b84f17fc/titan/ssl.titan#L278), `:1202`, `:1212`, `:1273`, `:1295`). A reader awaiting peer input therefore excludes an unsolicited write. Cancelling that read frees the TLS engine and closes TCP (`:265`); it cannot be used as a reusable interrupt. A WebSocket-level queue or pump around this API would preserve that deadlock. The TLS contract change is a first-class prerequisite, not a private bypass from WebSocket.

**D2 resolved:** after independent review identified RFC 6455 opening serialization, the maintainer selected a public resolved-address dialing boundary and per-destination serialization, including the broader net/SSL/HTTP scope. Preserve the original hostname for SNI and certificate validation; select and dial an already resolved address without a second DNS query. See [opening composition](https://github.com/mascarenhas/titan/issues/193#issuecomment-5976747788). This also remains design authorization only.

## Scope and public behavior

Support RFC 6455 version 13 over HTTP/1.1: client and server roles, text and binary messages, fragmentation, masking, Ping/Pong, close handshake, subprotocol negotiation, origin policy and finite message limits. Server use is `websocket.accept(request, response, options?)` inside the existing `http.Handler`, equally for `http.listen` and `http.listen_tls`. No separate listener/server hierarchy is necessary.

First release does not negotiate extensions or compression. It ignores valid extension offers on the server, emits no extension offer on the client, and rejects an unsolicited extension in a 101 response. Nonzero RSV bits therefore fail. HTTP/2 extended CONNECT, HTTP/3, proxies, redirects, cookies, reconnect, automatic heartbeat, JSON convenience methods and streaming per-message Reader/Writer objects are separate future work. These omissions do not remove base framing/UTF-8/closing conformance tests.

Proposed API inventory (signatures are design notation, not compiled examples):

```text
union MessageType: text(), binary()
const TEXT, BINARY: MessageType
opaque Connection
DialOptions(headers?, ca_file?, subprotocols?, read_limit?, handshake_timeout?)
AcceptOptions(subprotocols?, allowed_origins?, read_limit?, handshake_timeout?)

connect(source_url: string, options: DialOptions?): Connection
accept(request: http.Request, response: http.Response,
       options: AcceptOptions?): Connection

Connection:read(): (MessageType?, string?)
Connection:write(kind: MessageType, data: string)
Connection:ping(timeout_ms: integer?)
Connection:shutdown(code: integer?, reason: string?, timeout_ms: integer?)
Connection:close()
Connection:subprotocol(): string?
Connection:close_status(): (integer?, string?)
```

Option records have validated constructors with nil-filled defaults; copy supplied headers and option arrays so later caller mutation cannot alter an accepted connection. Default incoming message limit: 1 MiB; callers may choose a larger finite positive limit. Default client opening deadline: 10 seconds, including destination-admission waiting; server `accept` also gets a 10-second budget for validation and response output after HTTP supplies headers. Default Ping and graceful shutdown deadline: 5 seconds. A deadline initiates abort/cancellation; safe native DNS/connect/callback retirement may extend return latency, so these are not hard wall-clock return bounds. Names and defaults are proposed policy, not existing Titan APIs.

`read` returns one complete message. The pair is either nonnil type plus a string (including empty), or `(nil, nil)` after a valid peer Close and reciprocal close handling. A transport EOF without peer Close is abnormal, not ordinary end of messages. `close_status` reports the peer's actual status and reason; nil status distinguishes no received status code, including an empty Close payload. Local abnormal closure is reported as an error, never synthesized as an on-wire 1006. Preserve lower-level `ssl.Error`, `async.OperationError` and cancellation identities; add a nominal `websocket.Error` for protocol/limit/state failures with stable `kind`, `operation`, `message`, and optional `close_code`, and `HandshakeError` with status/headers when an HTTP rejection is available.

`close()` is immediate, idempotent resource retirement, requires no peer cooperation, works during pending cancellation, and does not promise a WebSocket or TLS close handshake. It is the lexical `defer` cleanup. `shutdown()` stops new data writes, sends a validated Close, waits at most its deadline for peer Close, then retires the transport; a timeout raises after cleanup without cancelling the caller Task. The owned timer records timeout intent and wakes the parent reservation; only genuine external Task cancellation is sticky. It defaults to code 1000 and empty reason. The API deliberately separates graceful protocol work from unconditional resource cleanup.

One application reader and one application data writer may operate concurrently. A second active reader or data writer fails clearly; do not add an unbounded caller queue. Internal Ping/Pong/Close writes share a frame-level serialization point with data writes. Large outgoing messages are fragmented into at most 16 KiB data-frame payloads, allowing controls between frames; no two data messages interleave. This serialization belongs to WebSocket framing, not a second TCP write scheduler.

`read` processes incoming control frames before returning data. It replies to Ping with the identical payload, records matching Pong, ignores unsolicited Pong, and handles peer Close. There is no hidden perpetual reader Task or decoded-message queue. `ping` sends a fresh token and waits for the corresponding Pong; the application must concurrently service `read`. Only one Ping waiter is allowed. Document this prominently for write-only applications. `shutdown` uses an existing reader if one owns receive progress; otherwise it takes that reservation and processes/discards incoming data until Close or its deadline. Neither operation starts a second raw reader. When an active read returns a data message during pending shutdown, its nonyielding reservation release transfers receive progress to shutdown; new reads cannot steal it. The message is delivered once, then shutdown drains/discards further data until Close. Explicit `close` wakes all protocol waiters and drains operation scopes before native release. Never join unrelated application Tasks. The complete state/priority/deadline rules and deterministic counterexamples are in [the lifecycle design appendix](https://github.com/mascarenhas/titan/issues/193#issuecomment-5976747788).

Cancellation while waiting only for admission/reservations does not touch a healthy connection. Once an operation has consumed/emitted protocol bytes or admitted transport I/O, cancellation makes the WebSocket terminal, even if that I/O has moved zero WebSocket bytes. This applies equally to an idle admitted ws or wss read; it does not promise detachable TLS reads. Cancellation before both boundaries removes only the exact reservations. Shutdown has already committed closing state and therefore terminalizes on cancellation. Cleanup aborts and retires accepted native ownership before publishing Task cancellation. Cancellation while native output is pending must be observed by an independently runnable owner, not by an unreachable catch after that output. Keep the first meaningful failure as the stored terminal cause; cleanup errors must not replace it. Use an owned I/O child per public suspending operation and a cancellation-aware parent wait where needed: the parent can abort the transport before cancellation-insensitive child retirement. Do not create a parser or codec Task per frame. Ownership supervision is per public I/O operation; a TLS worker per transport write can therefore scale with outgoing fragments. Measure that real nested TLS/WebSocket cost rather than promising zero per-frame Task allocations.

## HTTP upgrade boundary

Current HTTP code rejects llhttp's upgrade indication ([`titan/http/native.titan:430`](https://github.com/mascarenhas/titan/blob/06c3bec954dc2b7da7e19d16e3191cf0b84f17fc/titan/http/native.titan#L430), `:491`, `:513`), forces client `Connection: close` (`client.titan:55`), treats all 1xx as interim (`:59`), restricts response status to 200 and above (`server.titan:154`), and always finishes/drains/resets after a handler (`:379`). All of these participate in the change; merely allowing status 101 is insufficient.

Introduce an explicit public upgrade path in `http`, with no dependency back to `websocket`:

```text
http.request_upgrade_on(connection: io.ReaderWriterCloser,
                     abort: function (): (), source_url: string, protocol: string,
                     supplied_headers: http.Headers?): http.ClientResponse
http.ClientResponse:take_upgrade(): io.ReaderWriterCloser
http.Response:upgrade(request: http.Request, protocol: string,
                      supplied_headers: http.Headers?): io.ReaderWriterCloser
```

The client call adopts the explicitly supplied transport and public abort action after validating its arguments; it performs no DNS, TCP or TLS setup. It performs one bodyless GET, preserves the controlled Upgrade/Connection headers, stops at 101 instead of consuming it as an interim response, and returns ordinary non-101 responses for rejection inspection. Existing `http.request/get` keep their existing one-use HTTP contract and continue rejecting protocol upgrades. A 101 response is pending ownership transfer: ordinary body reads fail; `close` can abort it; `take_upgrade` succeeds once after validation. The WebSocket client validates the full handshake before taking it. Rejected or malformed openings always close the parser and transport.

The server method verifies that request and response belong to the same live exchange, that no response bytes have been sent, and that this is a legal HTTP/1.1 upgrade without a request body. It writes exactly one validated 101 header block, with no body framing, then transfers ownership. The handler normally checks routing/authentication before `accept`. Upgrade candidates must reach the handler instead of being rejected by llhttp's event drain. An unaccepted candidate receives an ordinary rejection response and closes; do not drain it or try to reuse an upgraded llhttp parser.

The returned opaque HTTP stream owns the underlying `io.ReaderWriterCloser`, an explicit public abort capability, and the unread prefix retained in `Parser.input_excess`. HTTP captures that capability while the concrete type is known (`net.close` or the proposed `ssl.abort`), before Interface erasure. Its `close` means unconditional, cancellation-insensitive transport retirement. Keep the same capability available to the HTTP-owned pre-transfer operation for opening cancellation and partial-101 rollback; do not rediscover transport identity or reach through private fields. Its first reads consume that prefix, including embedded NUL, before requesting more transport bytes. Its `read_until` must search across the prefix/transport boundary. Retain existing lower-level TCP/TLS excess; do not duplicate or discard it. HTTP never reads, resets, or resumes the parser into the WebSocket suffix after takeover.

Ownership has three meaningful phases: HTTP owned; 101 being written with rollback still HTTP owned; transferred. Allocate the new owning wrapper and fallible metadata before sending 101, and make the final transfer a nonyielding commit after successful write. A cancelled/failed write aborts under the old owner. Its cancellation-aware supervisor must remain runnable while the I/O child waits on accepted output; abort precedes the shielded drain. Once transferred, invalidate request-body and response-output operations, skip response finish/body drain/parser reset, and disarm the HTTP outer transport close. The handler may return after deliberately transferring the WebSocket to another owned Task. It must immediately defer close or establish that new owner. `http.Server:close` continues stopping only its listener; it does not acquire a WebSocket session registry.

Opening limits must be enforced while parsing, not after an unbounded header string exists. Account raw consumed opening bytes, including leading lines and punctuation, and bound llhttp input spans before callback/event copying; stop at the headers pause so a coalesced frame suffix is not charged. The default is 64 KiB per start-line-plus-header block; expose a `Server:header_limit(limit?)` setting for deployments needing a different finite bound. Apply a 64 KiB cap to `request_upgrade_on` responses, plus a finite count of interim responses (proposed 16). The server's new default cap is an intentional HTTP behavior change and needs ordinary HTTP regressions and documentation. Existing server idle timeout still ends when request headers are obtained; the `accept` response budget and WebSocket session deadlines are separate. A configurable nonzero HTTP idle timeout is the documented slow-handshake policy.

The llhttp 9.4.3 research oracle swept 164 request and 138 response split positions. The header pause consumed exactly the HTTP preamble and preserved an eight-byte binary suffix. At an exact boundary, resuming with empty input later reaches message completion and then upgrade pause. This supports taking the suffix directly at the first header boundary. It does not validate a Titan handoff implementation; see the [sources, captured logs and reproduction commands](https://github.com/mascarenhas/titan/issues/193#issuecomment-5976748632).

## TLS prerequisite under D1

Implement and independently validate this prerequisite before promising full-duplex `wss`. Retain public `net` composition, memory BIOs, certificate verification, lazy server handshake and a single Lua-thread OpenSSL engine. No native threads, private net/uv imports, WebSocket-owned TLS loop or polling timeouts.

Separate application read/write admission from synchronous engine access. Engine steps, `SSL_get_error`, input BIO feeding and ciphertext extraction must not yield. Network waits occur only after their state and immutable borrowed buffers have been committed. One application reader and one writer may wait; the two directions share exactly one underlying TCP input feed and ordered output submission: detach the complete output of each synchronous step as one immutable batch and immediately call public net.write before another Task can run. Each admitted operation retains its own submitted batch until completion; there is no second output queue. Handshake is a shared phase, not two simultaneous handshakes.

Do not merely replace `busy` with two booleans. An SSL write may need input; an SSL read may produce output. Both must make progress without competing net readers or reordering ciphertext. A write retry retains exactly its original pointer, bytes and length; capture the SSL error immediately. Respect OpenSSL's special WANT_WRITE retry restriction before running unrelated SSL I/O. Serialize record extraction/submission; do not let one continuation hold ciphertext while another submits later ciphertext first. Bound retained plaintext/ciphertext and owned pending operations.

Add public `ssl.Connection:abort()` for immediate, idempotent, cancellation-insensitive retirement with concurrent operations. Preserve `close` and `shutdown` as explicit graceful/exclusive operations; do not change ordinary TLS callers silently. The abort owner must be independently runnable while an I/O child is blocked. It stops admission and closes TCP before draining accepted operations, then frees the engine exactly once. Every exiting operation releases its directional/feeder reservations before waiting on shared terminal completion, including the elected owner; wait for operation scopes, not arbitrary user Task termination. Preserve the first cancellation/error and authenticated `close_notify` versus truncation distinction. HTTP stores this public abort capability before transport erasure.

Use the explicit state table and ownership protocol in [the TLS design appendix](https://github.com/mascarenhas/titan/issues/193#issuecomment-5976747788) as the prerequisite design. Validate that table with focused native tests before downstream layers depend on it. The recorded C-only memory-BIO oracle passed six combinations of TLS 1.2/1.3 and ciphertext fragments of 1/7/257 bytes: a pending read returned WANT_READ, two subsequent writes reached the peer in order, and replies reached the original reader. It used a verified local CA/identity and system OpenSSL 3.5.8. This establishes narrow engine feasibility, not Titan scheduling, cancellation, output backpressure, write-side WANT retries, shutdown or complete duplex correctness. Extend that oracle where needed and require native Titan tests for those remaining obligations.

## URL and opening handshake

Extend the existing URL parser's scheme policy to `ws`/`wss` with effective ports 80/443 while preserving scheme, normalized host, authority, query and origin-form target. Keep all existing rejection rules for userinfo, fragments, malformed escapes, controls and invalid ports. Add explicit HTTP-only scheme validation at ordinary HTTP entry points so accepting new URL schemes cannot route `wss` through plain TCP. WebSocket translates the parsed scheme to an HTTP(S) opening request without reparsing/splitting authority itself. Maintain meaningful source byte positions in URL errors. URL grammar changes require the PEG skill and focused URL tests.

Server opening checks: exact GET/HTTP 1.1, one valid Host, Upgrade and Connection token lists with case-insensitive tokens, exactly one version 13, exactly one strictly valid base64 key decoding to 16 bytes, and no Transfer-Encoding/nonzero Content-Length or Expect body flow. Reject malformed framing before 101. `accept` owns protocol rejection after validating its options and live Request/Response pair: malformed openings get 400, origin denial 403, unsupported WebSocket version 426 with `Sec-WebSocket-Version: 13`. It sends one bounded rejection, marks the response complete/nonreusable, then raises `HandshakeError`. Failed rejection output aborts and preserves the transport error. Invalid API options or an already committed Response fail before writing; the application still owns its ordinary response in those cases. Caught and uncaught failures must neither emit a default 200 nor permit a second response. Validate extra application response headers and reserve all handshake/framing fields so options cannot override them. Accept computes SHA-1 over the trimmed key text plus the RFC GUID, not over the decoded nonce.

Default origin policy accepts absent Origin for non-browser clients and same-origin browser requests; it rejects malformed/multiple origins and literal `null`. Compare normalized scheme/host/effective port against the HTTP request origin, not just host text. `allowed_origins` is an exact normalized origin allowlist, without wildcard matching or implicit forwarded-header trust. Applications behind a proxy must supply explicit allowed public origins and authenticate before acceptance. Origin checks are browser cross-site protection, not authentication of native clients.

Subprotocol tokens are case-sensitive. Select the first server-preferred exact token offered by the client; no intersection means no subprotocol unless the application rejects it before upgrade. Reject invalid/empty/duplicate offered tokens and multiple selected response values. The client rejects any unoffered selection. Header names and Upgrade/Connection tokens remain case-insensitive; do not apply that rule to subprotocols.

Client opening uses a fresh cryptographic 16-byte nonce, validates exact 101, HTTP version, Upgrade/Connection, singleton exact accept digest, negotiated protocol, lack of unsolicited extensions, and lack of body framing. No automatic redirect/credential forwarding. TLS uses the proposed public client-adoption boundary with the original hostname and ordinary verification/CA semantics; existing `ssl.connect` delegates to the same owner and identity rules. The overall opening deadline includes destination admission, DNS, TCP, TLS and HTTP; D2 assigns per-address admission and explicit transport composition as described in [opening-serialization.md](https://github.com/mascarenhas/titan/issues/193#issuecomment-5976747788). On cancellation, the supervisor first invokes any available transport abort, then drains native setup and its state-owning child. Native resolver retirement may outlast the deadline; no unsupported hard bound is promised. Server TLS/header deadlines stay with HTTP.

Use public `uv.random` for nonce/mask entropy; every client frame, including control and empty frames, gets a fresh unpredictable four-byte mask. Do not use `math.random`. Initially use the synchronous public UV form for these 16/4-byte requests, check its return, and document that entropy acquisition can block. Measure the cost. A future asynchronous entropy buffer requires a separate bounded ownership design; it is not part of this implementation plan. For the tiny handshake computation, prefer private synchronous OpenSSL EVP digest/base64 calls in one `websocket` contributor, using the already selected libcrypto dependency. This is a deliberate crypto-only native boundary, with no SSL engine or libuv FFI access and no public generic crypto API. Check all status/length results, allocate space for base64's trailing NUL, and return only the intended binary/string span. Strict base64 syntax/padding validation remains Titan-owned. Check both OpenSSL production modes and Windows imports; no new native dependency is intended.

## Frame and message engine

Keep the frame parser, connection state and private record methods in one folder module. Suggested contributors are `websocket.titan` (public API), `handshake.titan`, `connection.titan`, `frames.titan`, `utf8.titan`, and `native.titan` (only the small digest/base64 bridge). Do not create public submodules or add a central async operation dispatcher.

Maintain an input chunk plus cursor, partial-header state, fragmentation kind, cumulative message length and incremental UTF-8 state. Treat transport chunks as arbitrary; consume multiple frames from one chunk and headers/payloads split at every byte. Consume retained slices with offsets; avoid repeatedly concatenating growing messages. Use `string.writer` or an equivalent existing owner for whole-message assembly. Returned strings own immutable bytes through later reads and collection.

Validate opcode/FIN/RSV/masking and canonical length encoding before allocating from length. Reject a 64-bit length with high bit set, nonminimal length encoding, and addition overflow. Apply `read_limit` only to text/binary payload and their continuations; reject a data message above that cumulative limit before allocating from it. Ping/Pong/Close instead have their own 125-byte limit and never consume the data-message budget. Control frames are final, at most 125 bytes, and legal between data fragments. Continuation requires an active message; a new text/binary opcode cannot interrupt one. Bound total message bytes, not only each frame. Empty messages and empty continuation fragments are valid.

Validate text incrementally across frames and chunks: accept only Unicode scalar UTF-8, including completion at FIN; reject overlong forms, surrogates, out-of-range scalars and incomplete final sequences with 1007. Validate outgoing text before any frame is sent. Binary data permits all bytes. Close payload is either empty or at least two bytes; validate its code and UTF-8 reason before exposing it. Accept current standardized codes 1000–1003 and 1007–1014, plus application/private codes 3000–4999; reject 1004/1005/1006/1015, unassigned 1016–2999 and out-of-range values. Never originate or echo 1010 as a server: reply to a client 1010 with 1000. Tolerate a received 1010 on the client and handle it as an ordinary valid Close; RFC 6455 does not explicitly require rejecting it on receipt. Test send and receive policies separately. Reasons fit the remaining 123 control bytes. The current [IANA close-code registry](https://www.iana.org/assignments/websocket#close-code-number) supplies the modern 1012/1013/1014 assignments, which need native tests.

On protocol failure attempt a bounded Close with 1002, on invalid UTF-8 1007, on excess size 1009, then retire transport. Once Close is sent, no further application data is emitted. Handle peer-initiated and simultaneous close; echo an empty Close as empty. A truncated frame and TCP/TLS loss before valid close are abnormal. Keep WebSocket closing separate from subsequent TLS/transport teardown; a valid WebSocket close must not be overwritten accidentally by a benign already-closed transport error.

Process controls promptly during fragmented data, including during shutdown drain. Put a bounded byte/frame work budget on long buffered parse/mask loops, then yield explicitly for fairness. `async.checkpoint` is cancellation admission, not a scheduling yield. State must be valid before every yield. Do not create per-frame parser Tasks or per-byte temporary strings. TLS ownership supervision can still add a Task per transport write; include that cost in fragmentation measurements.

The message limit bounds decoded-message accumulation. It does **not** bound the existing `net.Connection` queue: its active read watcher buffers immutable strings without a high-water mark. Document this inherited limitation and measure it. If deployment acceptance requires bounded memory with a peer sending while application reads stop, a separate public transport-backpressure prerequisite is needed; neither a WebSocket queue limit nor the branch's 64 KiB scratch cap proves that property.

## Implementation stages and completion gates

1. **Freeze contracts under resolved D1 and D2.** Review public signatures, close semantics, transfer lifetime, origin/extension policy and the TLS transition table. Preserve this plan as the baseline. Confirm the implementation checkout still contains the researched prerequisite commits.
2. **TLS duplex prerequisite.** Land its source, native regressions, both manuals and networking/async skill changes as a separately reviewable change. Add the public TLS client-adoption boundary needed by D2, with original-host identity and exact transport ownership. Require progress with a blocked read plus write, reverse dependency through WANT_READ, handshake contention, ordered output, simultaneous shutdown/failure and cancellation of either/both operations. Existing HTTPS, TLS verification/truncation and parent-cancellation tests must pass before WebSocket layers rely on it.
3. **Resolved dialing, HTTP handoff and bounded opening.** Expose the existing net resolver and a preowned TCP endpoint with a single-address connect method as public APIs, then add verified TLS adoption and HTTP upgrade over a supplied owned transport under D2. Add the explicit client/server APIs and retained-prefix owner; test plain/TLS 101, non-101 rejection, all boundary splits, exact header terminator, interim responses, handshake failure/cancellation, no use after transfer, handler return after transfer and unaccepted candidates. Preserve keep-alive/body/Expect/timeout behavior for ordinary requests. Add URL scheme support and HTTP guards together.
4. **WebSocket wire core and lifecycle.** Add the module, validated API/options, handshake, role-specific framing, messages, controls, close, limits and cancellation. Test through public installed APIs and raw network peers, not private UV/parser hooks. Install/build graph integration accompanies the first production module, so each stage can build the canonical provider.
5. **Independent peers and Autobahn.** Add standalone echo-server and case-driver fixtures, both client/server roles, verified wss interoperability and raw malformed-peer tests. Run the pinned conformance matrix and archive machine-readable reports. Fix protocol failures before optimizing.
6. **Allocation, lifetime and delivery closure.** Validate the branch's ownership/allocation invariants, focused sanitizer gates, full Linux suite, complete local macOS VM gates with architecture and both OpenSSL modes, and shared native Windows gates. Finish docs/skills/examples and exact provider fixtures, then obtain implementation reviews when implementation is separately authorized.

Dependencies are TLS -> full-duplex secure handoff/session; HTTP+URL -> opening; wire core + both boundaries -> complete module; all -> conformance/delivery. Frame-vector work and packaging preparation can proceed independently after contracts are fixed. D2 adds public net, SSL and HTTP surfaces and corresponding exact metadata fixtures, but no new compiler feature, ABI change, SDK version change or language-server marker change is indicated; only standard-import normalization is an established compiler edit.

## Validation matrix

| Area | Required evidence |
| --- | --- |
| Opening | Resolved-address identity/alias serialization, independent destinations and admission cancellation; RFC accept vector, mixed-case HTTP tokens, duplicate/split headers, wrong method/version/key/accept, body/Expect rejection, origin policy including ports/proxies, exact subprotocol case, non-101 HTTP errors, interim caps, header byte limits, ws/wss URL edge cases |
| Byte handoff | 101 and first frame coalesced; terminator/extended length/mask/payload split at every byte; several frames per read; embedded NUL; HTTP parser never consumes frame suffix; transfer and failure close exactly once |
| Frames | Both role mask rules, all length widths/boundaries, nonminimal and invalid 64-bit lengths, all reserved bits/opcodes, control size/FIN, continuation order, zero lengths, interleaved controls, cumulative limits and overflow |
| Unicode | Valid scalar boundaries split across chunks/fragments; invalid continuation/overlong/surrogate/>U+10FFFF/incomplete FIN; close reasons; binary transparency; outgoing validation before output |
| Lifecycle | Shutdown takeover after a reader returns data; blocked-output cancellation/abort before drain; Ping match/unmatched Pong, reader requirement and timeout, peer/local/simultaneous close, empty/invalid Close, no data after close, explicit abort, read/write/handshake cancellation and failure at each ownership boundary |
| Concurrency | One reader + one writer progress on ws/wss, duplicate same-direction rejection, control-frame serialization, large write with inbound Ping, close while reads/writes wait, FIFO ciphertext, no engine free under suspended work |
| Ownership | Forced GC during reads/writes/close; previous message strings stable; callback/context roots released after terminal completion; pending accepted writes survive cancellation; repeated session cleanup before Runtime exit |
| Integration | Shared native inventory/discovery, source-free dynamic/static Unix consumers, Windows DLL exports/imports, short alias, exact schema/opener/shim lists, publication rollback, both OpenSSL modes |

Ordinary behavior tests live in `spec/stdlib/titan/websocket/tests/`, using `support.runtime` and owned peer Tasks. Reuse existing CA fixtures; retry loopback ports only on EADDRINUSE. Add TLS/HTTP/URL prerequisite cases to their owners. Busted owns import normalization/build/provider/packaging, not WebSocket protocol behavior. No test-only public hooks, no duplicated standard provider, and no Lua boundary suite for ordinary API coverage.

After installing the current source into an isolated prefix, build the aggregate once and run focused `websocket.tests`, `ssl.tests`, `http.tests`, `url.tests`, `net.tests` and affected async cases. Then run `make stdlib-test` and canonical `make test` with the documented clean environment. Full native test discovery becomes 27 roots. Add focused sanitizer selections for handshake/handoff, partial-frame cancellation, duplex TLS and close with retained bytes, using the existing failure-log symbolization path. Native Windows compiles all shared roots/fixtures before runtime skip evaluation. Local macOS is the required pre-merge route; do not dispatch hosted macOS CI without explicit authorization.

## Autobahn gate

Use both fuzzingclient against the Titan server and a Titan client case driver against fuzzingserver. Pin the runner to `docker.io/crossbario/autobahn-testsuite@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074` (tag 25.10.1, linux/amd64, source `6ed6f439dc7ed0d7432fe2cf7481b110905ecc5c`). Current upstream research snapshot is `aa9099a4eaa38b3298a72bd24c824f507c9424fa`; this is not the image's source identity. Archive configs, executable/provider identities, image digest, report index and per-case JSON/HTML with the result.

Use wstest modes `fuzzingclient` and `fuzzingserver` with explicit config paths/report directories and a distinct agent name for each role/build. The client driver fetches case count, opens one connection for each `/runCase?case=N&agent=...`, echoes text/binary preserving message type, observes terminal closure, then requests `/updateReports?agent=...`. It must not skip later cases because a malformed-frame case correctly raises. Parent supervision bounds the run and kills/joins all owned child processes on exit.

Select all base cases, including UTF-8, 7.5.1 and 7.7.8; the explicit 1010 policy above is compatible with the pinned suite without a role-wide waiver. Accept valid extension-offer syntax but reject malformed extension grammar even though no extension is negotiated. Native tests cover modern 1012/1013/1014 codes absent from that suite. Do not assume an obsolete-code conflict without a demonstrated case. For the selected base cases, do not copy coder/websocket's exclusions. Compression families 12/13 are recorded as outside v1 because no extension is negotiated, with exact case inventory and reasons rather than a silent pass. Limits/performance families 9/10 remain selected under a separate documented test-profile message cap large enough for their defined payloads (category 9 reaches 16 MiB); native tests separately prove the production default limit. Treat any non-strict result explicitly: FAIL, NON-STRICT, UNCLEAN, MISSING, UNIMPLEMENTED and unexpected skipped/unavailable cases fail the intended gate; INFORMATIONAL cases require separate recorded classification. Check close behavior as well as overall behavior.

Process exit zero alone does not pass. Assert the expected agent, exact selected case IDs, result presence, `behavior` and `behaviorClose` for every applicable case, and detect empty reports. Validate the result checker against known bad/missing results. Pin time/size budgets after measuring the runner; some category 9 case deadlines reach 480 seconds, so a blanket five-minute wrapper is insufficient. Keep budgets generous enough to avoid timing-dependent correctness. Do not turn performance score variance into a protocol pass criterion. Native tests cover opening/security/TLS details not proven by Autobahn. Initial full conformance is a delivery gate; add a bounded deterministic subset to regular CI if a full run cannot fit the existing job budget without silently deleting cases.

## Packaging and allocation integration

The detailed file/line inventory is [the delivery appendix](https://github.com/mascarenhas/titan/issues/193#issuecomment-5976748176). Adding one logical module changes the installed set from 21 to 22, public openers plus bare support from 22 to 23, and native roots from 26 to 27. For Windows, explicitly admit the intact immediately preceding same-layout 21-module provider as one bounded predecessor alongside the exact new 22-module provider. Validate each inventory against its own exports/protocols/shims; never admit arbitrary subsets. Require 21-to-22 success, repeated publication and injected rollback restoring the exact old DLL/shims and absence of the new shim. This is a current-layout inventory transition, not migration from a pre-reset installation. Update Unix/Windows source ensembles and direct import DAG, publisher exact module lists, all generated shims, source-rock contents, source-free smokes, macOS snapshot/restore lists, CI shim cleanup and the mechanically extracted public schema. Preserve paired Unix providers and Windows DLL-only ownership. Do not weaken exact inventory assertions or change unrelated numeric test counts.

Preserve issue-196's reusable numbered Completion, one Runtime wake queue, ordinary public UV imports, immutable native borrowed bytes and cancellation-insensitive retirement. Prefer named `_with` registrars for new one-shot adapters if any are necessary; most WebSocket work composes existing network calls. A frame is not an async scheduler event. Count context/adapter/control allocations honestly.

Add separate WebSocket benchmarks; leave the frozen 122-case issue-196 matrix and historical measurements unchanged. Separate setup/handshake, steady read/write, and teardown. Measure masking, fragmentation, controls, ws/wss, small/large payloads, 0/100/1000-operation allocation slopes, live/peak memory and after-close/after-GC retention. Use immutable prepared prefixes, optimized uninstrumented timing lanes, raw TCP/TLS controls and provider/source provenance. Check event-loop fairness under continuously buffered messages. Never infer total queue bounds from scratch storage or zero-copy behavior from reduced allocation counts.

Add linked language and implementation WebSocket chapters, examples for HTTP/TLS handlers and verified clients, exact cancellation/EOF/close/origin/reader-duty documentation, and affected HTTP/SSL/URL documentation. Update the networking skill plus programmer routing/import inventory, tester inventory, and async/FFI skills where contracts actually change. Keep documentation in the same implementation stages as their behavior.

## Evidence and review status

Research assistants supplied independent source/protocol/inventory investigations; they are not the two final-plan reviewers. Oobii arranged separate protocol/API and architecture/ownership reviewers. Both verified the identical frozen draft (SHA256 `bd2c397db130b54e087b25953e5dd489f3979ba3bdc69be9ecbf008d2ca9a81d`) and source snapshot and recorded reports before reading each other. The [review synthesis](https://github.com/mascarenhas/titan/issues/193#issuecomment-5976748176) records accepted, modified and rejected suggestions, severity/context and resulting obligations. The on-issue review appendix records all substantive findings and final dispositions without requiring access to local review files. This issue body and its detailed design appendix are the final recommendation and supersede the frozen draft. The bounded amendment checks did not constitute another full review of every final edit; the owner incorporated the documented final corrections.

Primary references: [issue 193](https://github.com/mascarenhas/titan/issues/193), [RFC 6455](https://www.rfc-editor.org/rfc/rfc6455.html), [RFC 7936](https://www.rfc-editor.org/rfc/rfc7936.html), [coder/websocket](https://github.com/coder/websocket/tree/9c8faadccd1b679e811a79ce506f8a10237251ad), [Autobahn](https://github.com/crossbario/autobahn-testsuite/tree/aa9099a4eaa38b3298a72bd24c824f507c9424fa), [OpenSSL write retry](https://docs.openssl.org/3.5/man3/SSL_write/), [OpenSSL error/retry rules](https://docs.openssl.org/3.5/man3/SSL_get_error/), [memory BIOs](https://docs.openssl.org/3.5/man3/BIO_s_mem/), and the exact branch source paths cited above. Upstream API inspiration is not a proof of Titan semantics or conformance. Only the narrow experiments whose sources and logs are in the [evidence appendix](https://github.com/mascarenhas/titan/issues/193#issuecomment-5976748632) have run; no new Titan WebSocket/TLS implementation, conformance run or platform validation is claimed.


### On-issue appendices

- [Detailed TLS, resolved opening and WebSocket lifecycle contracts](https://github.com/mascarenhas/titan/issues/193#issuecomment-5976747788)
- [Independent review synthesis, amendments, delivery and allocation inventory](https://github.com/mascarenhas/titan/issues/193#issuecomment-5976748176)
- [Experiment sources/logs, reproduction instructions and pinned upstream evidence](https://github.com/mascarenhas/titan/issues/193#issuecomment-5976748632)
