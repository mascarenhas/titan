# TLS-library implementation

The public API and observable behavior are documented in the
[TLS standard-library chapter](../language/standard-library-ssl.md). This
chapter describes the high-level `titan.ssl` state machine, its narrow OpenSSL
boundary, and how it is packaged.

## Layering boundary

`titan/ssl.titan` is an ordinary logical standard module. Each public
`Connection` contains a public-layer `net.Connection`; each public `Server`
contains a `net.Server` and an OpenSSL server context. The module imports the
high-level `fs` and `net` modules. Explicit path reads go through
`fs.read_file`; network traffic drives only `net`'s public `read`, `write`,
`shutdown`, `close`, and `accept` methods.

TLS imports public `titan.uv` only for the generic Completion registrar's
`uv.req_t?` type. It owns no libuv handle/request and adds no scheduler operation.
The public net resource/cleanup contracts remain the transport substrate.
Operation parents wait through public async exact suspension and terminal
listeners; internal I/O children perform the suspending net operations.

`titan/ssl.titan` directly imports OpenSSL's public `err.h`, `x509v3.h`,
`pem.h`, and `ssl.h` headers. There is no SSL-owned integration header. Their
overlapping declaration closures are reconciled by the ordinary C FFI: it
batches compatibility validation while isolating each candidate declaration
pair's scope, then relies on the configured C compiler's ordered include
context as the authority. A same-kind file-scope tag is the generated C
translation unit's tag and reuses one module-wide canonical owner regardless
of which header exposed it. Genuinely distinct tag objects, including
prototype-local tags, remain nominally distinct; only the narrow repeat of one
physical guarded declaration is reconciled by source identity.

There is no hand-written SSL shim, adapter function, callback, or native
provider object. The compiler still emits the ordinary generated
`titan/ssl.c` translation unit for the Titan module. Where the FFI cannot name
a function-like or inline-only header helper, the Titan source comments and
spells its public primitive expansion directly:
`SSL_CTX_ctrl` for the TLS-version floor and retained chain certificates,
`SSL_ctrl` for DNS SNI, `BIO_ctrl` for memory-BIO EOF behavior, and
`CRYPTO_free` for `OPENSSL_free`. The `ERR_GET_LIB`/`ERR_GET_REASON` bit
extraction used to recognize PEM EOF likewise lives in Titan. DNS-versus-IP
identity selection and the stable `SSL_ERROR_*` name mapping are ordinary
Titan control flow; `SSL_set1_host`, `SSL_get0_param`, and
`X509_VERIFY_PARAM_set1_ip_asc` are called directly.

The `SSL_ctrl` signature uses mutable `void *` even though the SNI input is
logically read-only. The module therefore copies the already NUL-checked host
into a short GC-owned mutable byte array for that call. OpenSSL consumes the
name during the control operation; no pointer to the temporary array is
retained by Titan.

`Connection:has_pending_input()` conservatively combines non-open state,
retained plaintext, `SSL_has_pending`, `BIO_ctrl_pending` on the input BIO, and
the public TCP query. The state test short-circuits before accessing a freed
engine. `SSL_has_pending` includes unprocessed or partial TLS records and does
not promise application data; this query only rejects dirty idle pool leases.
It does not run the engine, read the transport, or add a native callback.

The companion `add_input_listener` forwards to the owned TCP transport while
TLS is open. It neither creates an engine operation nor peeks at decrypted data;
partial and control ciphertext deliberately count as idle input. The listener
is removed by its borrower or the ordinary transport-close path.

## Contexts, SSL objects, and BIO ownership

The module initializer allocates one default client `SSL_CTX`, requires TLS
1.2 or newer, enables peer verification, and calls
`SSL_CTX_set_default_verify_paths` exactly once. A module-rooted private Titan
record owns that reference in an `SSL_CTX *` field; as a record, the owner is
already a full userdata with one unique nominal metatable. The owner is first
rooted with a nil field; the configured context moves into that field only
after default trust succeeds, leaving allocation and configuration failures
with their exact local cleanup. The callback itself accepts
`DefaultClientContextOwner`, reads its field directly, and contains no
`value as DefaultClientContextOwner` recovery. The module calls
`titan.gc.finalizable<|DefaultClientContextOwner|>` so the generic boundary
statically pairs that exact local record with its callback; a callback over a
different record would be rejected by the checker.

The generic body and callback formal erase to `value` at run time. Titan's
ordinary traced callable adjustment is stored as the record metatable's
`__gc`, and Lua's finalizer invocation projects the same full userdata back to
the exact owner parameter before entering the callback. This adds no second
metatable or per-value finalizer slot: every `DefaultClientContextOwner` shares
the nominal record metatable and its current raw callback. Per-value native
state therefore remains in the record field. At Lua-state shutdown the
idempotent callback clears that field and the module's borrowed fast-path
pointer before calling `SSL_CTX_free`. A no-override `connect` takes a
temporary context reference, which it releases after `SSL_new` has retained
what the connection needs.

An explicit `ca_file` instead goes through `fs.read_file` before `net.connect`.
The call allocates a private client context and adds every certificate decoded
from the GC-owned in-memory bytes to its `X509_STORE`; the store retains each
certificate before the decoder reference is released. It rejects empty input,
input with no certificates, and malformed PEM rather than falling through to
default trust. Both paths then connect through `net`, allocate an `SSL`, and
configure the exact requested DNS or IP identity. DNS names additionally get
SNI and partial wildcards are disabled. `connect` drives the handshake and
checks `SSL_get_verify_result` before returning.

For a scoped IPv6 host, `net.connect` receives the original address including
its `%zone`, while certificate configuration passes only the address prefix to
`X509_VERIFY_PARAM_set1_ip_asc`. The presence of an IPv6 colon before the scope
separator selects this narrow transformation; DNS names are not stripped at a
percent byte. A successfully parsed scoped address remains in the IP branch,
so neither `SSL_set1_host` nor DNS SNI is configured.

A server reads its certificate path and optional distinct key path through
`fs.read_file` before creating an OpenSSL context or calling `net.listen`. An
absent key path reuses the already-read certificate bytes, supporting one
combined PEM bundle without a second filesystem operation. The first decoded
certificate becomes the leaf and later certificates are retained as the
transmitted chain. The first decoded unencrypted private key is retained by
the context, then checked against the leaf. Encrypted keys are rejected because
the API has no password input.

`Connection:read_ahead(enabled?)` delegates directly to its public TCP
transport. A lazy accepted TLS connection can select demand-driven reading
before any handshake input. TLS engine serialization and operation admission
are unchanged; the TCP transfer packet carries this policy across states.

The configured `SSL_CTX` is retained on `ssl.Server`. The optional backlog and
`reuse_port` are delegated to `net.listen`, which supplies 128 and false when
absent. Reuse changes only the bind flags; it adds no shared TLS context or
listener ownership. An unsupported bind follows the existing failure path
that releases this Server's unpublished `SSL_CTX`. Accepting a TCP
connection creates an `SSL` in accept state but deliberately does not drive its
handshake. `Server:accept` takes a context reference before the suspending net
accept, so another Task may close the listener without invalidating the
in-flight accept. `SSL_new` retains the context it needs; the Server's own
reference can therefore be released independently after a connection has been
created.

OpenSSL's typed `PEM_X509_INFO_read_bio` and generated
`PEM_read_bio_X509`/`PEM_read_bio_PrivateKey` declarations are not currently
representable by Titan's C-header parser. That FFI surface limitation stays in
Titan rather than justifying a C shim. The implementation calls the exported
generic `PEM_read_bio`, classifies each block name in Titan, and decodes the
borrowed DER span with `d2i_X509`, `d2i_X509_AUX`, or
`d2i_AutoPrivateKey`.

Each successful generic read transfers three OpenSSL-allocated buffers—name,
header, and DER data—to one local `PemBlock`. Every exit frees all three through
the exported `CRYPTO_free` primitive underlying `OPENSSL_free`. The DER buffer
remains live while the `d2i_*` cursor advances, and decoding must consume its
exact length. A failed read is clean EOF only when direct public
`ERR_GET_LIB`/`ERR_GET_REASON` masking identifies
`ERR_LIB_PEM`/`PEM_R_NO_START_LINE`; every other failure, including a malformed
trailing PEM block, is reported. `PemBlock` and the pointer-result owners are
local records and therefore do not enter `titan.ssl`'s public type metadata.

Every connection creates one input and one output memory BIO. `SSL_set0_rbio`
and `SSL_set0_wbio` transfer both BIO references to the SSL object. The
Connection retains borrowed pointers only while its SSL is live; `SSL_free`
owns the final BIO release and the Titan fields are cleared together. No BIO
or OpenSSL pointer crosses the module's public interface.

Bytes read from `net.Connection` are copied into the input BIO with exact
lengths. Bytes pending in the output BIO are copied into GC-owned Titan strings
as one complete immutable engine-step batch before one immediate
`net.Connection:write` submission. Neither path
uses NUL termination for application data.

## Driving the state machine

The Connection has explicit handshaking, open, write-shutdown, peer-closed,
shutdown, terminating, failed, and closed states. Its first server-side I/O calls the same
handshake driver as explicit `handshake`, as does the first I/O on an adopted
client. A client reaches open state inside `connect`.

Each OpenSSL action follows one loop:

1. clear the per-thread OpenSSL error queue;
2. invoke `SSL_do_handshake`, `SSL_read_ex`, `SSL_write_ex`, or `SSL_shutdown`;
3. on failure, call `SSL_get_error` immediately, before any other OpenSSL call;
4. drain every byte already produced by the output BIO;
5. for `SSL_ERROR_WANT_READ`, read encrypted bytes through `net` and feed the
   input BIO; or
6. for `SSL_ERROR_WANT_WRITE`, require that draining made progress, then retry.

This ordering is part of the implementation contract: `SSL_get_error` is
defined relative to the exact failed operation and the current error queue.
The error value is captured before output draining can call OpenSSL again.

Plaintext writes are split into at most 16 KiB pieces. A retry retains the
same Titan string, pointer, and length until OpenSSL accepts that complete
piece. A partial successful `SSL_write_ex` is treated as an invariant failure
rather than silently changing call semantics.

`read_until` is ordinary high-level composition over repeated TLS reads. It
retains only the suffix after a matched delimiter on the Connection. It does
not inspect TCP or TLS record boundaries.

## Duplex admission, cancellation, and failure

The Connection owns reader, writer and exclusive control operation slots.
Each public admission reserves its slot until its parent wrapper epilogue.
Each internal child independently marks engine access live or retired; this
single scope fact, rather than user Task termination, controls SSL/BIO freeing.
One child per public call includes all record pieces and retries. There is no
per-record worker, persistent pump or second TLS output queue.

OpenSSL engine calls, immediate `SSL_get_error`, saved diagnostics and complete
output-BIO detachment run synchronously without yielding. A complete immutable
ciphertext batch goes directly to one net.write before a Task switch, preserving
submission order. Detaching output followed by failed admission is terminal.
One operation owns the lazy handshake. One encrypted-input feeder reads TCP;
other directions install exact cancellable ResumeToken reservations. Feeding
clears ownership and wakes them to retry the engine, without promising that
another engine step has left input unread. WANT_WRITE reserves an exclusive
retry owner across yields; other operations may complete an already admitted
input feed and relinquish feeder ownership before waiting on that retry gate.
The exact plaintext piece, pointer and length survive every write retry.

A public parent waits on its child's terminal listener with one private token,
checks already-terminal status, and removes the exact listener on every exit.
Its cancellation action only detaches that wait. When resumed by cancellation,
the parent elects or joins terminal cleanup, cancels its child, closes TCP
before draining engine scopes, then shield-drains its owned child. This makes
accepted backpressured writes interruptible even though their native callback
cannot be abandoned. Original external cancellation remains sticky.
An internal operation saves its nominal error and original traceback in
`async.Error` before cleanup yields. The public parent uses `Error:raise()`
after coordinated cleanup, preserving the failing engine frame without
reporting a caught operation error as an uncaught internal Task failure.
Client adoption and trust-context setup likewise save the traced error before
freeing the partial engine/context or closing TCP, then hand it back after
cleanup. The `connect` convenience wrapper preserves a handshake failure
through its final abort.

The first terminal caller publishes terminating before yielding and wakes all
progress waits. Every child retires feeder/retry/handshake permissions and its
engine scope before waiting for shared cleanup. The elected owner alone closes
TCP, waits through named `await_cleanup_with` registrars for scopes to retire,
frees SSL/BIO once, clears buffers and publishes closed after graceful close or
failed after abort/failure. Followers wait on that
same completion. No cleanup owner joins a child whose epilogue can wait for
cleanup; public abort drains captured children only after publication. User
Tasks may catch their SSL error and continue without delaying cleanup.

Graceful shutdown/close stay exclusive. Authenticated peer EOF stops new writers
but preserves an already admitted writer's exact retry. The reader waits for
that writer scope before reciprocal alert/TCP half-close. WANT_READ after peer
EOF cannot make future progress and becomes terminal. Explicit abort skips the
alert exchange and reports stable `TLS_INTERRUPTED` on sibling operations.

On transport EOF, the input memory BIO changes from retry semantics to a real
zero return. OpenSSL `SSL_ERROR_ZERO_RETURN` records an authenticated peer
`close_notify` and becomes ordinary Reader EOF. An underlying EOF observed
while OpenSSL still needs protected bytes becomes the distinct
`TLS_TRUNCATED_EOF` failure.

`ECONNRESET` from `net.read` is converted directly to that same failure with
`SSL_ERROR_SYSCALL` and the active TLS operation. It is not fed back through
the memory BIO as EOF: OpenSSL turns unexpected BIO EOF into a fatal decode
alert, and attempting to drain that alert to an already reset transport could
replace the authoritative truncation error with a second network failure.
Other network failures remain their original `async.OperationError`. Shutdown
drains the local alert before asking the public net connection to half-close
its write side. During terminal `close` only, `ENOTCONN` from that half-close
is benign once the alert output has already been drained: it means the peer
won the close race. Explicit `shutdown` and every other failure remain
observable.

## Connection transfer ownership

TLS handoff moves the `SSL *` and its owned memory BIOs intact, together with
the known TCP connection byte payload and copied scalar/plaintext state. OpenSSL's
`SSL_new` retains its context; the engine owns both BIOs. The implementation
installs no Lua-state callbacks or Lua-bearing native ex-data on these objects.
Consequently, closing the source Lua state after detachment does not invalidate
the engine or its context. Encrypted input has already been copied into a BIO;
retry pointers and borrowed output batches are excluded by the idle gate.

The encoder rejects every reader/writer/control/handshake/feeder/retry owner and
cleanup or scope waiter. It snapshots scalar state before transferring TCP,
then clears the source engine/BIO/transport references and marks it closed.
A private protobuf schema encodes the child bytes, fixed64 engine pointer and
copied state. Successful encoding preserves the engine; if serialization raises
after detachment, a lexical guard calls `SSL_free` and discards the TCP packet.
Public `Connection.discard_transfer_payload` performs the same terminal cleanup
for a known unadopted packet without a Runtime. The destination decodes the schema and
allocates an empty wrapper before adopting TCP, attaches the native engine,
and obtains its BIO pointers with `SSL_get_rbio`/`SSL_get_wbio`. All operation
slots and waiter Arrays are fresh destination-owned objects. TLS transfer
inherits native-pending and half-close rejection from the TCP layer.

This is a same-process, manual exactly-once capability, not a serialized TLS
session. Replay, dropped payloads and failed delivery recovery belong to the
caller. Tests cover a lazy engine moved out of an independent Lua state,
source-state shutdown before decoding, established plaintext preservation,
and rejection during handshake, read and backpressured output.

## Trust-path boundary

The module initializer calls `SSL_CTX_set_default_verify_paths` on the one
shared, GC-finalized default client context. In bundled mode these remain the
defaults compiled into Titan's OpenSSL build, together with OpenSSL's
documented environment overrides. This is the sole OpenSSL-owned path
configuration.
The initializer may synchronously load the default CA file once. OpenSSL
registers hashed CA directories for lazy lookup, so the first verification
that needs one may synchronously read its directory and certificate file; the
shared context retains the resulting lookup cache for later connections.

The implementation does not translate a platform Keychain or other native
trust database into certificates and must not be documented as a portable
operating-system trust abstraction. An explicit `ca_file` does not call an
OpenSSL file or directory loader: high-level `fs` reads it asynchronously and
the private context receives only certificates decoded from memory. Removing
the former directory parameter is deliberate; emulating OpenSSL's hashed
directory semantics with ad hoc Titan traversal would change trust policy.

## Build and provider composition

`OPENSSL_MODE=bundled` pins OpenSSL 3.5.7, verifies its release tarball, and builds
static PIC `libssl.a` and `libcrypto.a` with the OpenSSL 3.0 API floor. They are
private standard-provider payload: their objects are force-carried into the
combined DSO and flattened into the corresponding static provider rather than
installed as Titan runtime-SDK archives.

The default `OPENSSL_MODE=system` requires `pkg-config` metadata for OpenSSL 3.0 or
newer. Its ordered link result remains a final-link input and must be repeated
by static consumers; it is not copied into `titan.a`. Because the module uses
OpenSSL directly, neither mode builds, carries, or installs an SSL adapter
object or integration header. The generated translation unit includes only the
direct public OpenSSL headers selected by the Titan foreign imports.

The SSL root is compiled in the same source invocation as the other standard
modules. It adds one logical ABI/types protocol, one static metadata key, one
generated Lua shim, and `luaopen_titan_ssl` to the coordinated provider.

## High-level composition limits

The public `fs` and `net` surfaces are sufficient for explicit path loading and
the entire TLS record and handshake state machine. No blocker required a direct
libuv operation, native filesystem escape hatch, or native socket escape hatch.
Public direction slots and exact async coordination provide simultaneous
reader/writer progress while synchronous engine access remains serialized by
the cooperative runtime. `client` factors context/identity setup from `connect`
and adopts the exact preselected transport without a handshake or second DNS
lookup; `connect` preserves trust preparation before dialing.

The focused non-LuaCov standard-library tests use checked-in local CA and
certificate fixtures to exercise combined full-chain/key and split PEM files,
high-level path errors, empty and malformed CA bundles, DNS/IP identity,
fragmented and binary records, lazy server handshake, authenticated versus
truncated EOF, and interface-shaped I/O. Sanitizer coverage crosses the same
high-level HTTPS path with `SSL_CERT_FILE` selecting the checked-in CA for the
shared default context. The fresh Lua process therefore exercises both a
default-trust connection and shutdown finalization without adding a second
sanitizer process; it does not create a separate uv-backed TLS implementation.
