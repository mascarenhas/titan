# TLS-library implementation

The public API and observable behavior are documented in the
[TLS standard-library chapter](../language/standard-library-ssl.md). This
chapter describes the high-level `titan.ssl` state machine, its narrow OpenSSL
boundary, and how it is packaged.

## Layering boundary

`titan/ssl.titan` is an ordinary logical standard module. Each public
`Connection` contains a public-layer `net.Connection`; each public `Server`
contains a `net.Server` and an OpenSSL server context. The module imports
`titan.net` and drives only its public `read`, `write`, `shutdown`, `close`,
and `accept` methods.

This feature makes no change to `titan.uv`, adds no TLS call to its private
continuation union, and does not import it. The existing networking module is
treated as fixed language-level substrate. A TLS operation suspends only when
the wrapped high-level `net.Connection` suspends.

`titan/ssl.titan` imports one source-only integration header containing exactly
OpenSSL's `ssl.h`, `err.h`, and `x509v3.h` includes. It has no declarations or
definitions and produces no object or provider payload; it is a compile-time
include aggregator, not an API shim.

The aggregator is a performance choice, not an FFI correctness workaround.
Independent extraction of the three large overlapping header closures repeats
guarded glibc declarations containing a prototype-local `struct sched_attr`.
The FFI checker recognizes the same physical declaration by source provenance,
requires the configured C compiler to accept the final ordered include context,
and canonicalizes that repeat without inventing two prototype scopes.
Same-spelled tags from distinct source declarations remain nominally distinct.
The three direct imports therefore typecheck, but their hundreds of independent
declaration-pair probes take minutes rather than the aggregator's seconds.

There is no SSL-specific C translation unit, function, callback, or provider
object. Titan's C FFI does not expose function-like macros, so the module spells
the three needed macro expansions with their exported primitive calls and
object-like constants: `SSL_CTX_ctrl` for the TLS-version floor, `SSL_ctrl`
for DNS SNI, and `BIO_ctrl` for memory-BIO EOF behavior. DNS-versus-IP identity
selection and the stable `SSL_ERROR_*` name mapping are ordinary Titan control
flow; `SSL_set1_host`, `SSL_get0_param`, and
`X509_VERIFY_PARAM_set1_ip_asc` are called directly.

The `SSL_ctrl` signature uses mutable `void *` even though the SNI input is
logically read-only. The module therefore copies the already NUL-checked host
into a short GC-owned mutable byte array for that call. OpenSSL consumes the
name during the control operation; no pointer to the temporary array is
retained by Titan.

## Contexts, SSL objects, and BIO ownership

A client call allocates one temporary `SSL_CTX`, requires TLS 1.2 or newer,
enables peer verification, and loads either explicit CA locations or OpenSSL's
default paths. It then connects through `net`, allocates its `SSL`, and
configures the exact requested DNS or IP identity. DNS names additionally get
SNI and partial wildcards are disabled. `connect` drives the handshake and
checks `SSL_get_verify_result` before returning.

For a scoped IPv6 host, `net.connect` receives the original address including
its `%zone`, while certificate configuration passes only the address prefix to
`X509_VERIFY_PARAM_set1_ip_asc`. The presence of an IPv6 colon before the scope
separator selects this narrow transformation; DNS names are not stripped at a
percent byte. A successfully parsed scoped address remains in the IP branch,
so neither `SSL_set1_host` nor DNS SNI is configured.

A server retains one configured `SSL_CTX` on `ssl.Server`. Certificate-chain
and PEM-key loading and their match check happen before `net.listen` returns a
public Server. Accepting a TCP connection creates an `SSL` in accept state but
deliberately does not drive its handshake. `Server:accept` takes a context
reference before the suspending net accept, so another Task may close the
listener without invalidating the in-flight accept. `SSL_new` retains the
context it needs; the Server's own reference can therefore be released
independently after a connection has been created.

Every connection creates one input and one output memory BIO. `SSL_set0_rbio`
and `SSL_set0_wbio` transfer both BIO references to the SSL object. The
Connection retains borrowed pointers only while its SSL is live; `SSL_free`
owns the final BIO release and the Titan fields are cleared together. No BIO
or OpenSSL pointer crosses the module's public interface.

Bytes read from `net.Connection` are copied into the input BIO with exact
lengths. Bytes pending in the output BIO are copied into GC-owned Titan strings
in bounded pieces before being passed to `net.Connection:write`. Neither path
uses NUL termination for application data.

## Driving the state machine

The Connection has explicit handshaking, open, write-shutdown, peer-closed,
shutdown, failed, and closed states. Its first server-side I/O calls the same
handshake driver as explicit `handshake`; a client reaches open state inside
`connect`.

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

## Serialization, cancellation, and failure

One `busy` bit admits exactly one public TLS operation. It is set across every
OpenSSL transition and every suspending `net` call, so another Task cannot
advance the same SSL/BIO pair concurrently. This is intentionally not a
reader/writer split: handshake and post-handshake traffic can make either
nominal direction consume input and produce output.

A raised OpenSSL, network, or cancellation value moves the connection to the
failed state, frees its SSL/BIO engine, and best-effort closes the net
transport. Cancellation is sticky in the async runtime, so that cleanup close
may itself be cancelled; the original failure remains authoritative and the
net Runtime still owns eventual native-handle cleanup.

On transport EOF, the input memory BIO changes from retry semantics to a real
zero return. OpenSSL `SSL_ERROR_ZERO_RETURN` records authenticated peer
`close_notify` and becomes ordinary Reader EOF. An underlying EOF observed
while OpenSSL still needs protected bytes becomes the distinct
`TLS_TRUNCATED_EOF` failure. Shutdown drains the local alert before asking the
public net connection to half-close its write side. During terminal `close`
only, `ENOTCONN` from that half-close is benign once the alert output has
already been drained: it means the peer won the close race. Explicit
`shutdown` and every other failure remain observable.

## Trust-path boundary

The no-override branch uses `SSL_CTX_set_default_verify_paths`. In bundled
mode these remain the defaults compiled into Titan's OpenSSL build, together
with OpenSSL's documented environment overrides. The implementation does not
translate a platform Keychain or other native trust database into certificates
and must not be documented as a portable operating-system trust abstraction.
Explicit `ca_file` and `ca_directory` use
`SSL_CTX_load_verify_locations` instead of first loading those defaults.

## Build and provider composition

The default build pins OpenSSL 3.5.7, verifies its release tarball, and builds
static PIC `libssl.a` and `libcrypto.a` with the OpenSSL 3.0 API floor. They are
private standard-provider payload: their objects are force-carried into the
combined DSO and flattened into the corresponding static provider rather than
installed as Titan runtime-SDK archives.

`OPENSSL_MODE=system` instead requires `pkg-config` metadata for OpenSSL 3.0 or
newer. Its ordered link result remains a final-link input and must be repeated
by static consumers; it is not copied into `titan.a`. Because the module uses
OpenSSL directly, neither mode builds, carries, or installs an SSL adapter
object or API header. The include-only integration header ships only as source
for compilation and never enters the runtime SDK or provider payload.

The SSL root is compiled in the same source invocation as the other standard
modules. It adds one logical ABI/types protocol, one static metadata key, one
generated Lua shim, and `luaopen_titan_ssl` to the coordinated provider.

## High-level composition limits

The public `net` surface is sufficient for the entire TLS record and handshake
state machine. No blocker required a direct libuv operation or a native socket
escape hatch. The deliberate limitation is concurrency: without a higher-level
duplex coordination abstraction, the SSL record serializes the one state
machine rather than promising simultaneous reader and writer Tasks.

The focused non-LuaCov standard-library tests use checked-in local CA and
certificate fixtures to exercise DNS/IP identity, fragmented and binary
records, lazy server handshake, authenticated versus truncated EOF, and
interface-shaped I/O. Sanitizer coverage crosses the same high-level HTTPS
path; it does not create a separate uv-backed TLS implementation.
