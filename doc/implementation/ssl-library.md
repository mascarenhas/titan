# TLS-library implementation

The public API and observable behavior are documented in the
[TLS standard-library chapter](../language/standard-library-ssl.md). This
chapter describes the `titan/ssl.native.titan` state machine, its narrow OpenSSL
boundary, and its build inputs.

## Layering boundary

Each public `Connection` contains a public `net.Connection`, and each `Server`
contains a `net.Server` and an OpenSSL server context. The module imports the
high-level `fs` and `net` modules: explicit path reads go through
`fs.read_file`, and network traffic and socket inspection/options use only
`net`'s public `read`, `write`, `shutdown`, `close`, `accept`, `local_address`,
`peer_address`, and `set_no_delay`. It imports public `titan.uv` only for the
`uv.req_t?` registrar return type; it owns no libuv handle or request and adds
no scheduler operation. Operation parents wait through public async exact
suspension and terminal listeners, and internal I/O children perform the
suspending net operations. The public `fs` and `net` surfaces are sufficient for
path loading and the whole record and handshake state machine; do not add a
direct libuv, native filesystem, or native socket escape.

The module foreign-imports OpenSSL's public `err.h`, `x509v3.h`, `pem.h`, and
`ssl.h` directly; the ordinary C FFI reconciles their overlapping declaration
closures. There is no SSL integration header, hand-written C shim, adapter
function, native callback, or provider object; the compiler emits only the
ordinary generated `titan/ssl.c`. Where the FFI cannot name a function-like or
inline-only header helper, the Titan source spells its public primitive
expansion with a comment: `SSL_CTX_ctrl` for the TLS-version floor
(`configure_context`) and retained chain certificates, `SSL_ctrl` for DNS SNI,
`BIO_ctrl` for memory-BIO EOF behavior, `CRYPTO_free` for `OPENSSL_free`, and
the `ERR_GET_LIB`/`ERR_GET_REASON` bit extraction. DNS-versus-IP identity
selection and the stable `SSL_ERROR_*` name mapping are ordinary Titan control
flow; `SSL_set1_host`, `SSL_get0_param`, and `X509_VERIFY_PARAM_set1_ip_asc` are
called directly.

`SSL_ctrl` takes a mutable `void *` even though the SNI name is read-only, so
`configure_server_name` copies the already NUL-checked host into a short
GC-owned byte array for that call. OpenSSL consumes the name during the call;
Titan keeps no pointer to the copy.

## Pending-input snapshot and input observers

`Connection:has_pending_input()` returns true unless the connection is open,
and otherwise combines retained plaintext (`excess`), `SSL_has_pending`,
`BIO_ctrl_pending` on the input BIO, and the transport's
`has_pending_input()`. The state test short-circuits before touching a freed
engine. `SSL_has_pending` also counts unprocessed or partial TLS records, so
the query is conservative; HTTP uses it only to reject dirty idle pool leases.
It does not run the engine, read the transport, or add a native callback.

`Connection:add_input_listener` requires an open connection and forwards to
the TCP transport's `add_input_listener`
([networking](libuv-networking.md#records)). It neither creates an engine
operation nor inspects decrypted data, so partial and control ciphertext count
as input. The borrower or the ordinary transport-close path removes the
listener.

## Socket addresses and `TCP_NODELAY` delegation

Socket address queries and `TCP_NODELAY` configuration delegate straight to
`net` without touching OpenSSL:

- `Server:local_address()` checks `self.closed or self.listener_closed`
  (raising `"ssl.local_address: Server is closed"`) and returns
  `self.listener:local_address()`.
- `Connection:local_address()` and `Connection:peer_address()` check
  `self.transport == nil` or terminal state (`STATE_CLOSED`, `STATE_FAILED`,
  `STATE_TERMINATING`), raising `"ssl.local_address: SSL Connection is closed"`
  / `"ssl.peer_address: SSL Connection is closed"`, and otherwise delegate to
  `self.transport:local_address()` / `self.transport:peer_address()`.
- `Connection:set_no_delay(enabled)` checks `self.transport == nil or
  self.transport_closed` or terminal state (`STATE_CLOSED`, `STATE_FAILED`,
  `STATE_TERMINATING`), raising `"ssl.set_no_delay: SSL Connection is closed"`,
  and otherwise delegates to `self.transport:set_no_delay(enabled)`.

None of these `Connection` methods touch `self.handle` (`SSL *`), the memory
BIOs, or any OpenSSL engine `Operation` slot. They therefore work before and
after a lazy `handshake()`, across `ssl.Connection` transfer, and without
contending with active TLS reader or writer operations. `ssl.connect` and
`ssl.Server:accept` construct their `net.Connection` directly and inherit
default `TCP_NODELAY = true`, while `ssl.client(transport, ...)` preserves
whatever `TCP_NODELAY` setting was already configured on `transport`.

## Contexts and trust

`new_client_context` allocates a client `SSL_CTX`, applies the TLS 1.2 floor
through `configure_context`, and enables peer verification. The module
initializer creates one default client context and calls
`SSL_CTX_set_default_verify_paths` on it exactly once. The private record
`DefaultClientContextOwner` holds that context in an `SSL_CTX *` field: the
owner is rooted with a nil field first, and the context moves into it only after
default trust succeeds, so every failure path has one cleanup owner. The owner
is registered with `gc.finalizable<|DefaultClientContextOwner|>`
([finalizer mechanics](gc-library.md#finalizer-stack-ledger)); at Lua-state
shutdown its idempotent callback clears the field and the module's borrowed
fast-path pointer before `SSL_CTX_free`. A default-trust `connect` takes a
temporary context reference and releases it after `SSL_new` has retained what
the connection needs.

The default verify paths are the only OpenSSL-owned trust configuration. In
bundled mode they are the defaults compiled into Titan's OpenSSL build, with
OpenSSL's `SSL_CERT_FILE`/`SSL_CERT_DIR` environment overrides. The initializer
may synchronously load the default CA file. OpenSSL registers hashed CA
directories for lazy lookup, so the first verification that needs one may
synchronously read the directory and certificate file; the shared context keeps
the resulting cache. Titan does not translate a platform Keychain or other
native trust store, so this is not a portable operating-system trust
abstraction.

An explicit `ca_file` is read through `fs.read_file` before `net.connect`. A
private client context receives every certificate decoded from those bytes in
its `X509_STORE`, which retains each certificate before the decoder reference
is released. Empty input, input without certificates, and malformed PEM are
rejected instead of falling back to default trust. No OpenSSL file or directory
loader is called, and there is no CA-directory parameter: emulating hashed
directory lookup with ad hoc Titan traversal would change trust policy.

Both paths connect through `net`, allocate an `SSL`, and configure the
requested DNS or IP identity. DNS names also get SNI, and partial wildcards are
disabled. `connect` drives the handshake and checks `SSL_get_verify_result`
before returning. `client` performs the same context and identity setup but
adopts an already connected transport without a handshake or second DNS lookup.
For a scoped IPv6 host, `verification_host` strips the `%zone` suffix (only
when a colon precedes the `%`) before `X509_VERIFY_PARAM_set1_ip_asc`, while
`net.connect` receives the original address. A scoped address stays in the IP
branch, so neither `SSL_set1_host` nor SNI is configured; DNS names are never
cut at a percent byte.

A server reads its certificate path and optional separate key path through
`fs.read_file` before creating an OpenSSL context or calling `net.listen`. An
absent key path reuses the certificate bytes, which supports one combined PEM
bundle. The first decoded certificate is the leaf and later ones are retained
as the transmitted chain. The first unencrypted private key is retained and
checked against the leaf; encrypted keys are rejected because the API has no
password input. `ssl.Server` keeps the configured `SSL_CTX`. `backlog` and
`reuse_port` go to `net.listen`; a failed bind releases the Server's
unpublished `SSL_CTX`. `Server:accept` calls `SSL_CTX_up_ref` before the
suspending net accept, so another Task may close the listener during an
in-flight accept, and creates an `SSL` in accept state without driving its
handshake.

## PEM decoding

Titan's C-header parser cannot represent OpenSSL's typed
`PEM_X509_INFO_read_bio` or the generated `PEM_read_bio_X509` and
`PEM_read_bio_PrivateKey` declarations. That limitation stays in Titan rather
than justifying a C shim: `read_pem_block` calls the exported generic
`PEM_read_bio`, classifies each block name in Titan, and decodes the borrowed
DER span with `d2i_X509`, `d2i_X509_AUX` (`TRUSTED CERTIFICATE`), or
`d2i_AutoPrivateKey`.

Each successful read transfers three OpenSSL-allocated buffers (name, header,
and DER data) to one local `PemBlock`, and every exit frees all three with
`CRYPTO_free`. The DER buffer stays live while the `d2i_*` cursor advances, and
decoding must consume its exact length. A failed read is clean EOF only when
`ERR_LIB_PEM`/`PEM_R_NO_START_LINE` is on the error queue; every other failure,
including a malformed trailing block, is reported. `PemBlock` and the
pointer-result owners are local records, so they do not enter `titan.ssl`'s
public type metadata.

## Engine objects and BIO ownership

Every connection creates one input and one output memory BIO and transfers both
references to the SSL object with `SSL_set0_rbio` and `SSL_set0_wbio`. The
Connection holds borrowed BIO pointers only while its SSL is live; `SSL_free`
releases the BIOs and the Titan fields are cleared together. No BIO or OpenSSL
pointer crosses the public interface.

Bytes read from `net.Connection` are copied into the input BIO with exact
lengths. Bytes pending in the output BIO are copied into GC-owned strings as
one immutable batch per engine step and submitted with one immediate
`net.Connection:write`. Neither direction relies on NUL termination.
`read_ahead(enabled?)` delegates to the TCP transport, so a lazy accepted
connection can select demand-driven reading before any handshake input.

## Driving the state machine

The connection states are `handshaking`, `open`, `write-shutdown`,
`peer-closed`, `shutdown`, `terminating`, `failed`, and `closed`. A client
reaches `open` inside `connect`. The first I/O on an accepted server connection
or an adopted client runs the same handshake driver as explicit `handshake`.

Each OpenSSL action follows one loop:

1. clear the thread's OpenSSL error queue;
2. call `SSL_do_handshake`, `SSL_read_ex`, `SSL_write_ex`, or `SSL_shutdown`;
3. on failure, call `SSL_get_error` immediately, before any other OpenSSL call;
4. drain every byte the output BIO has produced;
5. on `SSL_ERROR_WANT_READ`, read ciphertext through `net` into the input BIO;
6. on `SSL_ERROR_WANT_WRITE`, require that draining made progress, then retry.

`SSL_get_error` is defined relative to the failed call and the current error
queue, so its result is captured before output draining can call OpenSSL again.

Plaintext writes are split into `TLS_RECORD_BYTES` (16 KiB) pieces, and
`write_piece_locked` retries with the same string, pointer and length until
OpenSSL accepts the whole piece. A partial `SSL_write_ex` success raises
`TLS_PARTIAL_WRITE` instead of changing write semantics. `read_until` is
ordinary composition over TLS reads that keeps only the suffix after a matched
delimiter; it ignores TCP and TLS record boundaries.

## Duplex admission, cancellation, and failure

A Connection has `reader`, `writer`, and exclusive `control` operation slots,
plus `handshaker`, `feeder`, and `retry` owners. `begin_operation` reserves a
slot until the public wrapper's epilogue. Each internal child separately
records whether its engine access is live or retired; that scope fact, not
user Task termination, decides when SSL and BIOs may be freed. One child per
public call covers all record pieces and retries. There is no per-record
worker, persistent pump, or second output queue.

Engine calls, the immediate `SSL_get_error`, saved diagnostics, and complete
output-BIO detachment run synchronously without yielding. The ciphertext batch
goes to one `net.write` before any Task switch, preserving submission order;
detaching output and then failing admission is terminal. One operation owns
the lazy handshake. One input feeder reads TCP; other directions wait on
cancellable `ResumeToken` reservations (`ProgressWait`). Feeding clears the
feeder and wakes them to retry the engine, without promising that another
engine step left input unread. `SSL_ERROR_WANT_WRITE` makes the operation the
exclusive `retry` owner across yields; other operations may finish an admitted
input feed and give up feeder ownership before waiting on that retry gate.

A public parent waits on its child's terminal listener with one private token,
checks for an already terminal status first, and removes its listener on every
exit; its cancellation action only detaches that wait. When cancellation
resumes it, the parent elects or joins terminal cleanup, cancels its child,
closes TCP before draining engine scopes, and then shield-drains the child.
This keeps backpressured accepted writes interruptible although their native
callback cannot be abandoned; the external cancellation stays sticky. An
internal operation saves its error and traceback in an `async.Error` before
cleanup yields, and the parent calls `Error:raise()` after coordinated cleanup,
so the failing engine frame survives without an uncaught-Task report. Client
adoption and trust-context setup likewise save the error before freeing a
partial engine or context or closing TCP. `connect` preserves a handshake
failure through its final abort.

`terminate` implements termination. The first terminal caller publishes
`terminating` before yielding and wakes every progress wait. Each child retires
its feeder, retry and handshake permissions and its engine scope before waiting
for shared cleanup. The elected owner alone closes TCP, waits through named
`async.await_cleanup_with` registrars for scopes to retire, frees SSL and BIOs
once, clears buffers, and publishes `closed` after graceful close or `failed`
after abort or failure. Followers wait on the same completion. No cleanup owner
joins a child whose epilogue could wait for cleanup; public `abort` drains
captured children only after publication. User Tasks may catch their SSL error
and continue without delaying cleanup.

## Shutdown and EOF

Graceful `shutdown` and `close` are exclusive. An authenticated peer EOF stops
new writers but lets an already admitted writer finish its retry; the reader
waits for that writer's scope before sending its reciprocal alert and TCP
half-close. `SSL_ERROR_WANT_READ` after peer EOF cannot progress and is
terminal. Explicit `abort` skips the alert exchange and reports
`TLS_INTERRUPTED` to sibling operations.

On transport EOF the input memory BIO switches from retry semantics to a real
zero return. `SSL_ERROR_ZERO_RETURN` records an authenticated `close_notify`
and becomes ordinary Reader EOF. A transport EOF while OpenSSL still needs
protected bytes becomes `TLS_TRUNCATED_EOF`.

`ECONNRESET` from `net.read` becomes that same failure directly, with
`SSL_ERROR_SYSCALL` and the active operation. It is not fed to the BIO as EOF:
OpenSSL would turn unexpected BIO EOF into a fatal decode alert, and draining
that alert to a reset transport could replace the truncation error with a
second network failure. Other network failures keep their
`async.OperationError`. Shutdown drains the local alert before asking `net` to
half-close the write side. `ENOTCONN` from that `net.shutdown` is benign in
two places only, once the alert has been drained: graceful `close`, and the
reader's reciprocal alert after an authenticated peer `close_notify`. It means
the peer won the close race. Explicit `shutdown` and every other failure stay
observable.

## Lua-state close

Graceful close and abort both need Tasks: `close` runs a supervised child, and
termination awaits TCP close and engine-scope retirement. Nothing can run or
await while the Lua state closes, so `terminate` tests `titan_state_closing`
right after its terminal-state check. During close it frees the engine with
`free_engine` and publishes `failed`, as an abort would, and leaves the TCP
handle to `uv.loop_abandon` in the Runtime finalizer. `close` and `abort` take
that branch before operation admission and child draining, so a lexical
`defer connection:close()` in an unwinding Task completes. Freeing the engine is
safe whatever the unwinding Tasks were doing: engine calls never span a
suspension, no unwinding `defer` touches the SSL object or its BIOs, and the
ciphertext batches handed to `net` are GC-owned copies that outlive the drain.

`new_connection` registers `finalize_connection` with `gc.finalizable` before
`SSL_new`, and `from_transfer_payload` registers it before adopting the engine.
`listen` registers `finalize_server` before the Server holds its `SSL_CTX`.
Both finalizers return at once unless the state is closing, so ordinary
collection never frees TLS state. During close they call `close`. For a
Connection that frees the engine, together with the last reference to a
private trust context. For a Server, `Server:close` frees the `SSL_CTX` and,
during close, leaves the listener to the abandoned loop. A transferred-out
Connection has no engine, so its finalizer releases nothing. Idle pooled HTTP
connections and WebSocket transports are `ssl.Connection` owners, so the same
finalizer releases them. The Runtime-close listener that normally retires idle
pooled connections does not run at state close.

## Connection transfer ownership

The generic rules are in
[manual resource handoff](transfer-library.md#manual-resource-handoff). TLS
handoff moves the `SSL *` with its two memory BIOs intact, together with the
TCP child payload and copied scalar and plaintext state; the engine keeps its
`SSL_CTX` reference. Titan installs no Lua-state callback or Lua-bearing native
ex-data on these objects, so closing the source Lua state after detachment does
not invalidate the engine. Encrypted input is already in the BIO, and retry
pointers and borrowed output batches are excluded by the idle gate.

`to_transfer_payload` rejects a closed or terminating connection and any
reader, writer, control, handshake, feeder or retry owner or cleanup/scope
waiter. It snapshots scalar state before transferring TCP, then clears the
source engine, BIO and transport references and marks the source closed. The
private `connection_transfer_fields` schema carries the TCP child payload, the
engine pointer (a foreign pointer, encoded as fixed64) and the copied state.
If serialization raises after detachment, a lexical guard calls `SSL_free` and
discards the TCP payload; `Connection.discard_transfer_payload` performs the
same cleanup for a known unadopted payload without a Runtime. The destination
decodes the schema, allocates an empty wrapper before adopting TCP, attaches
the engine, and recovers its BIOs with `SSL_get_rbio`/`SSL_get_wbio`. Operation
slots and waiter Arrays are fresh destination objects, `connection_transfer_fields`
carries no address or `no_delay` fields, and destination `local_address()`,
`peer_address()`, and `set_no_delay()` delegate to the adopted TCP transport.
Native-pending and half-close rejection come from the TCP layer
([networking transfer](libuv-networking.md#connection-transfer-ownership)).
This is a same-process capability, not a serialized TLS session.

## Build and provider composition

How the bundled archives join the standard provider and how static consumers
pass system link inputs is in
[the standard-library image](multi-module-libraries.md#reserved-titan-and-the-standard-library-image).
TLS-specific build facts live in the `Makefile` OpenSSL variables:

- `OPENSSL_MODE=system` (the default) requires `pkg-config` metadata for
  OpenSSL `OPENSSL_MIN_VERSION` (3.0.0) or newer, checked with
  `--atleast-version`.
- `OPENSSL_MODE=bundled` downloads OpenSSL `OPENSSL_VERSION` (3.5.7), verifies
  `OPENSSL_SHA256` before extraction, and builds static PIC `libssl.a` and
  `libcrypto.a` with `--api=3.0`. They are private provider payload, not
  installed runtime-SDK archives.
- Both modes compile with `OPENSSL_API_COMPAT=30000`. Neither builds, carries,
  or installs an SSL adapter object or integration header; the generated
  translation unit includes only the OpenSSL headers named by the foreign
  imports.

## Tests

The non-LuaCov native tests in `spec/stdlib/titan/ssl/tests/` use checked-in
local CA and certificate fixtures for combined full-chain/key and split PEM
files, path errors, empty and malformed CA bundles, DNS/IP identity, fragmented
and binary records, lazy server handshake, authenticated versus truncated EOF,
Interface-shaped I/O, and transfer (a lazy engine
moved out of an independent Lua state, source shutdown before decoding,
plaintext preservation, and rejection during handshake, reads and
backpressured output). Sanitizer coverage runs the high-level HTTPS path with
`SSL_CERT_FILE` selecting the checked-in CA, so one fresh Lua process exercises
default-trust connection and shutdown finalization. State-close cases close an
independent state holding a Task parked in a handshake and an unclosed Server.
In the aggregate they check that `close` and `abort` complete during the close.
The allocator child's `state_close` scenario counts OpenSSL's live allocations
through its `CRYPTO_set_mem_functions` hooks and requires a second such close
to return to the balance after the first.

The rejected-SNI case uses a 256-byte host name made of one- and two-byte
labels. `configure_client` configures peer-name verification before SNI.
OpenSSL 4 validates the name in `SSL_set1_host`: it accepts at most 256 bytes
and rejects any label longer than 63 bytes, so a single 256-byte label would
fail there as `ssl.connect.verify-host`. OpenSSL 3 copies the name without
that validation. SNI configuration rejects a name that exceeds 255 bytes on
both versions, so the short-label name passes verification setup and fails at
SNI. Exactly 256 bytes is required: a shorter name is a valid SNI name, and a
longer one fails verification setup on OpenSSL 4. The test therefore requires
`OPENSSL` from `ssl.connect.sni` rather than accepting another configuration
failure. The adopted TCP peer must read EOF before any bytes and finish
successfully, proving that the failed configuration retired its transport
without TLS traffic.
