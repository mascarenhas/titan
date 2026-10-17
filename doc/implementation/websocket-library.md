# WebSocket ownership and framing

`titan/websocket/` is one folder module with one nominal schema, native unit,
opener and Lua shim. The public boundary is documented in
[WebSocket messages](../language/standard-library-websocket.md). It composes
ordinary public `http`, `ssl`, `net`, `uv`, `async`, `timer`, `string`, `url`
and `gc` imports. It never imports private UV/async/transport state.

## Contributor responsibilities

- `websocket.titan` declares public messages, errors and validated option owners,
  imports dependencies, and initializes the weak runtime registry.
- `handshake.titan` validates opening fields/origins/extensions/subprotocols,
  composes explicit resolved TCP/TLS/HTTP ownership, and serializes pending
  openings by semantic remote address.
- `connection.titan` owns directional/public-operation reservations, frame
  priority, cancellation-aware supervisors, control deadlines and shared
  terminal retirement.
- `frames.titan` consumes arbitrary transport slices, checks framing before
  allocation, carries fragmented message state, masks bytes and dispatches
  controls while assembling complete messages.
- `utf8.titan` validates Unicode scalar prefixes across all chunk/frame splits.
- `native.titan` uses synchronous OpenSSL EVP digest/base64 operations; random
  nonces and masks go through public `uv.random`. No new native dependency or
  SSL/libuv FFI is introduced.

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

The module's ephemeron-keyed runtime buckets hold only pending attempt
supervisors. Address keys use semantic address bytes, port and effective IPv6
scope, omit flowinfo, and normalize IPv4-mapped IPv6. Resolve once, reserve only
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

Buffered payload work yields after 64 KiB, and control/empty-fragment loops
yield after 32 frames. Outgoing data uses 16 KiB fragments and yields between
fragments. `async.checkpoint` admits cancellation but is not a fairness yield.
Each client frame has its own unpredictable 4-byte mask, even when empty.
Synchronous entropy may block; there is no asynchronous mask pool.

One application reader/data writer/Ping/shutdown reservation is admitted at a
time. Internal output shares a frame reservation: Close first, pending Pong,
application Ping, then data. No header/payload fragments from different frames
can interleave. Once closing begins, the next data fragment is refused.

## Operation and terminal lifetime

Each suspending public operation owns an I/O child and a cancellation-aware
parent. Its exact parent token wakes only the parent's explicit suspension;
terminal listeners are removed on exit. This does not create a parser Task per
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

Terminal retirement has one independently runnable owner. It stops admission,
wakes reservation waiters, invokes the public upgraded stream abort, then
awaits captured operation scopes/accepted ownership. It never joins arbitrary
application Tasks, so callers may catch failures and continue unrelated work.
Only after children retire are partial-message/input buffers cleared. A valid
peer Close plus reciprocal output becomes normal message EOF; earlier
transport loss remains abnormal. Immediate close skips protocol negotiation.

## Connection transfer ownership

Only open idle WebSocket sessions can produce a transfer policy. The gate
checks every operation/frame/control reservation, the work list, partial
message owner and retirement Task before touching HTTP ownership. An idle
session has no in-flight fragmented-message builder or UTF-8 continuation.
A private anonymous-root protobuf schema carries role, subprotocol, limit and
the unread suffix of the input chunk, plus the known HTTP `UpgradedStream` bytes. Reflection unwraps the known I/O
Interface to that public concrete owner; it never copies an Interface wrapper
or captured abort closure between states.

A private pending-operation count spans each public read, write, Ping,
shutdown and close call through its final cleanup. Internal Work slots may be
released earlier to preserve frame fairness and receive takeover; their release
does not permit transfer while the public caller is still resuming or unwinding.
The transfer hook checks both the public count and the internal reservations.

The HTTP wrapper in turn owns its unread prefix and concrete net/SSL transport.
After it detaches successfully, the source WebSocket facade drops the stream,
clears input and becomes terminal without protocol output. A lexical guard
discards the detached HTTP bytes if outer protobuf encoding fails. Destination
construction allocates its StringWriter, UTF-8 state and empty work list before
adopting the HTTP wrapper. No operation Tasks, timers or source closures are
transferred. The transport's strict native-pending restrictions still apply,
including Windows overlapped reads. Payloads remain manually owned and must be
adopted once; there are no replay guards or delivery rollback owners.

## Integration and verification

The module belongs to the canonical provider and native test inventory.
Unix keeps paired providers; Windows remains DLL-only. Standard-library installation
copies the built provider and generated shims.
No Titan, ABI, SDK or language-server version marker changes are required.

Native WebSocket tests use installed public APIs and independent raw TCP/TLS
peers under `spec/stdlib/titan/websocket/tests/`. Prerequisites are tested in
the owning net/SSL/HTTP/URL suites. Parser/compiler/build/schema/publication
assertions remain in Busted. Forced GC and cancellation cover retained strings,
partial frames and concurrent retirement.

[The conformance harness](../../spec/conformance/websocket/README.md) pins both
Autobahn roles and checks exact nonempty selected-case/agent inventories plus
behavior and close behavior. Compression families 12/13 are explicit
unnegotiated exclusions; base UTF-8/Close and performance/size families remain
selected. An ordinary container exit is not conformance evidence. Preserve
configs, image/executable/provider/source identities and per-case reports.

The message cap bounds decoded-message storage. Existing net buffered reads
have no high-water mark; neither this cap nor 64 KiB processing/scratch storage
proves a bounded transport queue. Separate WebSocket allocation measurements
must leave issue 196's frozen benchmark matrix/results unchanged, and separate
setup, steady message handling, controls, fragmentation and teardown for
plain/verified TLS sessions.

The [allocation and lifetime results](websocket-allocation-results.md) record
the measured costs and collector behavior. [Timing and fairness observations](websocket-benchmark-results.md)
record the finite background-qualified scheduling and paired-body measurements.
[WebSocket validation](websocket-validation.md)
identifies the tested sources, providers, platforms and remaining gates.

Protocol references: [RFC 6455](https://www.rfc-editor.org/rfc/rfc6455.html),
[case-sensitive subprotocols](https://www.rfc-editor.org/rfc/rfc7936.html),
[close registry](https://www.iana.org/assignments/websocket/websocket.xhtml),
and [OpenSSL EVP](https://docs.openssl.org/3.5/man3/EVP_DigestInit/).

## Discarding undelivered handoffs

`Connection.discard_transfer_payload` decodes the existing schema's first
stream-payload field and delegates to `http.UpgradedStream`'s public discard
operation. It does not reconstruct WebSocket state or require a Runtime.
The close attempt consumes the payload even when its returned native status
reports an error; delivery supervisors must choose exactly one adoption or
discard path.
