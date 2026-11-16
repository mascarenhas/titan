# WebSocket ownership and framing

`titan/websocket/` is one folder module with one nominal schema per target.
The public boundary is documented in
[WebSocket messages](../language/standard-library-websocket.md). The native
composition is a protocol implementation over ordinary public `http`, `ssl`,
`net`, `uv`, `async`, `timer`, `string`, `url` and `gc` imports; the browser
composition is a client over the host's `WebSocket` through `titan.browser`.
Neither imports private UV, async, or transport state.

## Contributor responsibilities

Shared by both targets:

- `types.titan` imports `http` and `string` and declares the public message
  kinds and constants, `Error`, `HandshakeError`, `DialOptions` and its
  validating constructor, the shared defaults (`DEFAULT_LIMIT`,
  `OPEN_TIMEOUT`, `CONTROL_TIMEOUT`, `WORK_BYTES`), and the option, header,
  token, and error helpers (`positive`, `copy_protocols`, `copy_dial_headers`,
  `state_error`, `wire_error`, `timeout_error`).
- `utf8.titan` validates Unicode scalar prefixes across all chunk/frame splits.

Native (`*.native.titan`):

- `websocket.native.titan` is the native main. It imports the native
  dependencies, declares `AcceptOptions`, the transfer schema and the protocol
  budgets (`FRAME_BYTES`, `FRAME_BUDGET`), and makes the `openings` registry an
  ephemeron in its initializer.
- `handshake.native.titan` validates opening fields/origins/extensions/subprotocols,
  composes explicit resolved TCP/TLS/HTTP ownership, and serializes pending
  openings by semantic remote address.
- `connection.native.titan` owns directional/public-operation reservations, frame
  priority, cancellation-aware supervisors, control deadlines and shared
  terminal retirement.
- `frames.native.titan` consumes arbitrary transport slices, checks framing before
  allocation, carries fragmented message state, masks bytes and dispatches
  controls while assembling complete messages.
- `crypto.native.titan` uses synchronous OpenSSL EVP digest/base64 operations
  (`accept_digest`, `base64`); `random_bytes` draws keys, masks and Ping tokens
  from public synchronous `uv.random`. It adds no native dependency or SSL/libuv
  FFI.

Browser (`*.browser.titan`):

- `websocket.browser.titan` is the browser main and imports the browser
  composition's dependencies.
- `client.browser.titan` declares the browser `Connection` and `connect` and
  implements `read`, `write`, `shutdown`, `close`, `subprotocol`, and
  `close_status` over the SDK's `titan:websocket` source
  ([browser client](#browser-client)).

The [member inventory](browser-target.md#interface-derived-member-inventory)
records `accept`, `AcceptOptions`, `Connection:ping`, and the three transfer
hooks as browser omissions and keeps `Connection` opaque.

Portable foreign byte accesses borrow immutable strings only while their
owning Titan locals remain rooted. Mask output uses a counted native owner;
no writable view into returned or transport strings escapes. EVP output
lengths/statuses are checked, base64 storage includes the trailing NUL, and
only intended bytes become the public string. Key syntax and canonical padding
are checked in Titan before hashing the trimmed encoded key plus the RFC GUID.

## Opening ownership

URL policy admits ws/wss while ordinary HTTP entrypoints retain explicit
http/https validation. WebSocket uses the original normalized authority and
target for HTTP and original hostname for TLS identity; resolved socket
addresses are never substituted for either.

`handshake.native.titan` `openings` maps each Runtime loop (ephemeron key) to buckets
of pending attempt supervisors. `destination_key` builds the bucket key from
semantic address bytes, port and effective IPv6 scope, omits flowinfo, and
normalizes IPv4-mapped IPv6. Resolve once, reserve only
the current candidate, and release after validated Upgrade or retired failure.
Contenders join the incumbent without owning/cancelling its result. Empty
buckets are deleted eagerly. TCP failure alone permits resolver-order fallback;
TLS trust/handshake and HTTP protocol failures remain terminal.

`net.Connection()` exposes the owner before a pending connect; `ssl.client`
adopts it without handshake. Supervision records the currently owned endpoint
before suspension. Cancellation/deadline aborts before shielded drain; DNS
retirement may outlast the deadline. The attempt supervisor retains its gate
through that cleanup. A completed but untransferred session is disposed of if
its public caller cancels before handoff.

HTTP owns its parser/transport while validating or writing 101. Its public
upgrade APIs retain binary `input_excess`, build the owning wrapper before
output, and commit transfer without yielding after success. The wrapper
captures net close or SSL abort while the concrete owner is known. Ordinary
HTTP cleanup is disarmed after transfer. `reject_upgrade` validates the live
Request/Response pairing and finishes one bounded bodyless rejection. See
[HTTP implementation](http-library.md) and [TLS duplex ownership](ssl-library.md).

## Protocol state and fairness

The connection holds one input chunk/cursor, fragmented-message kind and byte
count, a StringWriter, and the incremental UTF-8 state. It never repeatedly
concatenates the accumulated message. Returned strings are independent
immutable values. A frame header is at most 14 bytes; lengths are canonical,
64-bit high-bit values are rejected, and cumulative length is compared with
`limit - accumulated` before allocation. Controls have an independent 125-byte
limit and do not consume the message budget.

UTF-8 stores remaining continuation count and its allowed interval. E0, ED,
F0 and F4 restrict the first continuation to eliminate overlong values,
surrogates and out-of-range scalars. An impossible prefix fails immediately;
an incomplete prefix is permitted only until data FIN. Close reasons use the
same scalar rules. Outgoing text/reasons are checked before emission.

Buffered payload work yields after `WORK_BYTES` (64 KiB), and control/empty-fragment
loops yield after `FRAME_BUDGET` (32) frames (`Connection:read_message`).
Outgoing data uses `FRAME_BYTES` (16 KiB) fragments and yields between
fragments. `async.checkpoint` admits cancellation but is not a fairness yield.
Each client frame has its own unpredictable 4-byte mask, even when empty.
Synchronous entropy may block; there is no asynchronous mask pool.

One application reader/data writer/Ping/shutdown reservation is admitted at a
time. Internal output shares a frame reservation (`Connection:take_frame`):
Close first, pending Pong, application Ping, then data. No header/payload
fragments from different frames can interleave. Once closing begins, the next
data fragment is refused.

These yields are the only fairness mechanism. There is no generic
buffered-work fairness bound or starvation guarantee: a peer that keeps the
transport full still competes with other Tasks only at these points. The
measurements behind this design (archived in
[benchmark archives](benchmark-archives.md#retired-evidence-records)) were
Linux-only observations and do not establish macOS or Windows behavior.

## Operation and terminal lifetime

Each suspending public operation owns an I/O child and a cancellation-aware
parent (`new_work`, `Work:execute`). Its exact parent token wakes only the
parent's explicit suspension; terminal listeners are removed on exit. This does not create a parser Task per
frame. TLS's own public-write supervision adds a child per transport write;
measure these nested costs rather than claiming no fragment-proportional Task
allocations.

Control deadlines wake the parent and record timeout intent; they never cancel
the caller Task. The parent can abort a transport whose child waits on an
accepted native write, then drain that child cancellation-insensitively. The
first meaningful error remains the terminal cause as an `async.Error` carrier:
cleanup and later valid operations preserve its exact value and captured
origin traceback. Cancellation before both
protocol progress and transport admission detaches only reservations.
Admitted idle reads and committed shutdown are terminal on cancellation.

Shutdown marks closing before output and gives an existing reader the receive
reservation until its normal release. Reader release and shutdown wake occur
in one nonyielding step. Shutdown then drains/discards data and handles
controls until peer Close, yielding after 32 discarded complete messages even
when each message is empty. Ping never takes receive ownership: applications
must concurrently read.

Terminal retirement (`Connection:retire`) has one independently runnable owner. It stops admission,
wakes reservation waiters, invokes the public upgraded stream abort, then
awaits captured operation scopes/accepted ownership. It never joins arbitrary
application Tasks, so callers may catch failures and continue unrelated work.
Only after children retire are partial-message/input buffers cleared. A valid
peer Close plus reciprocal output becomes normal message EOF; earlier
transport loss remains abnormal. Immediate close skips protocol negotiation.

A closed endpoint is not reclaimed by one collection. Each Task's `Coroutine`
record (`titan/coroutine.titan`) has a finalizer and roots its thread and
callback in its fields, and the callbacks capture `Work` and message state or
TLS operation results. The first collection after release finalizes the
records while the graphs they reference
survive; a later cycle frees those graphs. Tests and diagnostics that check
release must run several collections (or check a weak slot after settling)
rather than assume single-cycle release.

## Connection transfer ownership

The generic manual-handoff rules (exactly-once adoption, explicit discard,
lossy carriers, stream eligibility including Windows pending reads) are in
[manual resource handoff](transfer-library.md#manual-resource-handoff). This
section covers the WebSocket gate and schema.

Only an open idle session can be transferred (`Connection:to_transfer_payload`).
The gate rejects a closed or closing session, a nonzero private
`pending_operations` count, an active reader, writer or frame reservation, a
nonempty work list, and a partial message before it touches HTTP ownership. An
idle session therefore has no in-flight fragmented-message builder or UTF-8
continuation. `pending_operations` spans each public read, write, Ping,
shutdown and close call through its final cleanup. Internal Work slots may be
released earlier to preserve frame fairness and receive takeover, so the count
keeps a caller that is still resuming or unwinding from transferring.

`connection_transfer_fields` (`websocket.native.titan`) is a private anonymous-root
protobuf schema: the HTTP `UpgradedStream` payload bytes, client role,
subprotocol, read limit, and the unread suffix of the input chunk. Reflection
unwraps the known I/O Interface to that concrete owner; no Interface wrapper or
captured abort closure is copied between states. The `UpgradedStream` owns its
unread prefix and concrete net/SSL transport
([cross-state exchange ownership](http-library.md#cross-state-exchange-ownership)).
After it detaches, the source facade drops the stream, clears input and
becomes terminal without protocol output. A lexical guard discards the detached
HTTP bytes if the outer encoding fails. Destination construction allocates its
StringWriter, UTF-8 state and empty work list before adopting the HTTP wrapper.
No operation Tasks, timers or source closures are transferred.

## Discarding undelivered handoffs

`Connection.discard_transfer_payload` decodes the first (stream payload) field
of the same schema and delegates to `http.UpgradedStream.discard_transfer_payload`.
It does not reconstruct WebSocket state or require a Runtime.

## Browser client

`client.browser.titan` drives one host `WebSocket` per `Connection` through
the SDK's `titan:websocket` source
([browser bridge](browser-bridge.md#javascript-files)). The JavaScript
constructs the socket with `binaryType = 'arraybuffer'`, installs named
`open`, `message`, and `close` listeners, and reads `bufferedAmount` and
`readyState`; state, limits, backpressure, and error policy are Titan's.

**Opening.** `connect` calls `async.checkpoint()` (so a `lua.new()` state
raises `"async Runtime is not active"`), raises the `url.Error` of a failed
`url.parse`, requires `ws` or `wss` (the host constructor would otherwise
rewrite `http` and `https`), and rejects a `DialOptions` with any header or a
`ca_file`, before any host call. It registers an `async.add_close_listener`
that closes the connection with its Runtime, then listens on `connect` with
the URL and each subprotocol as a trailing string argument. The source emits
`open` with the socket handle and the selected subprotocol, `text` and
`binary` with the message length and a holder object of its bytes (text is
UTF-8 encoded by the host), and `close` with the code, reason, and
`wasClean`; it ignores `error`, which Chromium omits on a reset after `open`.
Unregistering removes all three listeners and then calls `socket.close()`.
Titan races the opening against `timer.sleep` of the handshake timeout,
which raises `Error("timeout", "websocket.open", ...)`, and maps any `close`
before `open` to `HandshakeError("WebSocket opening handshake failed", nil,
nil)`; a listener failure or a host exception before `open` becomes
`HandshakeError(message, nil, nil)` with the host's message. After `open`
and before adoption, `connect` compares the selected subprotocol with the
immutable offer: no selection when protocols were offered, or a selection
that was not offered, raises the same fixed `HandshakeError` and retires the
socket through the adoption guard. Chromium refuses an opening that selects
none of the offered protocols, but Firefox and WebKit open it with an empty
protocol. A native client fails only the unoffered selection and returns a
nil `subprotocol()` when none is selected.

**State.** The connection moves from connecting to open, closing (after
`shutdown` sends Close), and terminal. The first failure latches as an
`async.Error` carrier that every later operation raises again. After `open`,
a `close` event with code 1006 or 1015, which no Close frame can carry, latches
`Error("abnormal", operation, "transport ended before WebSocket Close", nil)`;
any other code is a valid peer Close, including 1005 for an empty Close.
An unclean transport teardown can still report a valid peer Close code:
`close_status()` records the code and reason of every `close` event except
1005, 1006, and 1015, whatever `wasClean` says. A host
exception from a later source call becomes `Error("abnormal", operation,
message, nil)`; `BrowserError` never escapes the WebSocket API.

**Lazy read limit.** Message events queue holders, not bytes. `read` compares
the reported length, which is the length after `permessage-deflate`
decompression, with the read limit before it asks for the bytes. A message
over the limit closes its holder without `take`, retires the connection, and
raises `Error("limit", "websocket.read", ..., 1009)`; the message is never
copied into Wasm memory. Otherwise `take` returns the bytes, the holder
closes, and `read` returns the message. Earlier queued messages are delivered
first. Consumed slots are cleared; after at least 32 slots have been consumed
and that prefix can pay for the unread suffix, the queue copies that suffix before
replacing the old FIFO. Retained queue storage therefore follows the unread
backlog rather than the connection's message history. The unread queue itself
is not bounded: browsers expose no stream backpressure for `WebSocket`
(`WebSocketStream` is Chromium-only).

**Write backpressure.** `write` admits one writer, validates text with the
shared `validate_text` before JavaScript could replace invalid UTF-8 with
U+FFFD, and calls `async.yield()` once for fairness. It rechecks the
connection state at entry, after the yield, and after every poll: a latched
failure raises again, and a closing or terminal connection, or a `buffered`
result of -1 (the socket is no longer open), raises
`Error("state", "websocket.write", ...)`. `send` returns false without
calling `WebSocket.send` when the socket is no longer open, which covers a
peer Close that the engine has received but not yet dispatched; Titan then
raises the same state error rather than let the browser discard the message.
After a successful `send`, while `buffered` reports more than 262,144 bytes,
`write` polls with `timer.sleep(2)` until 65,536 bytes or fewer remain, and a
failure or retirement during the wait raises. A state error leaves the
connection to the operation that closed it; any other failure after `send`
(including cancellation) or an abnormal loss terminalizes it.
These checks observe the host's current state, not remote delivery. Node may
report a paused peer's FIN only after the peer resumes reading. WebKit can
drain output to low water before reporting a remote Close or reset. Even with
the final state check, an admitted write can therefore succeed while the host
still reports OPEN; a subsequent write raises after the host reports loss.

**Shutdown and close.** `shutdown` defaults to code 1000 and an empty reason,
admits only 1000 and 3000 through 4999 (the browser's `close()` refuses 1001
through 1014), validates the reason's length and UTF-8, keeps an admitted
reader admitted and refuses new readers, calls `close` with the code and
reason, and waits for the `close` event up to its deadline. The host drops
messages that arrive after `close()`, so the admitted reader completes with the
closing EOF. `Connection:close()` is
synchronous, idempotent, local retirement: it closes the listener request
(removing the listeners and closing the socket), closes the queued holders
and the socket handle, and wakes waiters with the state error or the latched
failure. An `OPEN` socket then queues an empty Close frame behind its
buffered sends, and the engine finishes the closing handshake. Cancelling an
admitted `read` terminalizes the connection.

## Integration and verification

The module belongs to the canonical provider and native test inventory, and
its browser composition to the browser provider. Unix keeps paired providers;
Windows remains DLL-only.

Native WebSocket tests use installed public APIs and independent raw TCP/TLS
peers under `spec/stdlib/titan/websocket/tests/`. Prerequisites are tested in
the owning net/SSL/HTTP/URL suites. Parser/compiler/build/schema/publication
assertions remain in Busted. Forced GC and cancellation cover retained strings,
partial frames and concurrent retirement.

`websocket.tests` runs on both targets. Its shared `portable.titan` checks the
message kinds and error records, `DialOptions` limits, subprotocol tokens and
reserved headers, a non-WebSocket scheme, and the `url.Error` identity; its
browser contributor `validation.browser.titan` checks the refusal of dial
headers and `ca_file` and the `lua.new()` refusal. Framing, UTF-8 wire,
server, and transfer cases stay in `.native.titan` contributors. The browser
client's network behavior runs against real engines in the live browser
network harness ([browser target](browser-target.md#the-live-browser-network-harness)).

The Close-then-reset fixture sends Close(1000, `"bye"`) and waits for the client's
Close reply before resetting TCP. This establishes that the client parsed Close,
which a local write callback cannot prove. After five seconds without a reply,
the peer records the timeout and resets anyway; the driver requires a timely
reply. Every engine must still return `(nil, nil)` on both reads and preserve
`close_status() == (1000, "bye")`.

Buffered-write loss tests require the exact admitted write to fail, except for
FIN on every engine and remote Close/reset on WebKit, where host loss reporting
may follow output drainage. These late-loss cases check that each successful
write observes OPEN. If all eight 8 MiB writes finish first, a bounded wait for
non-OPEN must succeed, then the next write must fail without another host send.
The wait does not extend the payload cap or relax the other loss oracles.

[The conformance harness](../../spec/conformance/websocket/README.md) pins both
Autobahn roles and checks exact nonempty selected-case/agent inventories plus
behavior and close behavior. Compression families 12/13 are explicit
unnegotiated exclusions; base UTF-8/Close and performance/size families remain
selected. An ordinary container exit is not conformance evidence. The harness
runs the Linux amd64 image only and makes no native Windows, macOS, arm64 or
verified-WSS conformance claim.

The message cap bounds decoded-message storage. Existing net buffered reads
have no high-water mark; neither this cap nor 64 KiB processing/scratch storage
proves a bounded transport queue.

Protocol references: [RFC 6455](https://www.rfc-editor.org/rfc/rfc6455.html),
[case-sensitive subprotocols](https://www.rfc-editor.org/rfc/rfc7936.html),
[close registry](https://www.iana.org/assignments/websocket/websocket.xhtml),
and [OpenSSL EVP](https://docs.openssl.org/3.5/man3/EVP_DigestInit/).
