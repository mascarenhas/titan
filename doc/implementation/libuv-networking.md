# Libuv DNS and TCP implementation

The public API and semantics are documented in the [TCP networking standard
library](../language/standard-library-net.md). The common Task, callback, and
shutdown protocol is documented in [Libuv runtime](libuv-runtime.md).
Contributor recipes for adding callback operations and handle types are in
[Extending the libuv binding](libuv-extension-guide.md).

The public `net` facade contains no C FFI types. Each `Connection` or `Server`
holds one opaque `uv.uv_tcp_t` wrapper, and only the private `uv` module can
reach its native handle. There is no network control layer, Runtime network
registry, ready queue, or per-operation generation number.

The TLS layer wraps these public `net.Connection` and `net.Server` records with
OpenSSL memory BIOs. It does not extend this module or obtain the private TCP
owner; see [TLS-library implementation](ssl-library.md).

## Native owners and callbacks

Each callback-taking libuv operation has one small Titan owner containing its
native request and exact callback. That callback captures the suspended Task
directly. A write owner additionally retains the original Titan string through
`write_cb`; libuv copies the submitted `uv_buf_t`, and Titan does not allocate
a second payload string.
DNS, connect, and shutdown need no common control record.

The persistent TCP owner is the multi-shot exception. A private union gives a
connection and a server disjoint state: connections keep read buffering and
one reader, while servers keep accepted clients and one accept waiter. Libuv's
handle queries remain authoritative for live close and write-side state.

Each plain-C callback shim follows its libuv callback shape. A small common C
helper obtains the loop's captured main `lua_State *`, the exact callback
closure, its module Udata, and its native Titan entry. The particular shim
then passes that closure as the hidden `_fn`, casts and calls the exact entry,
and supplies the owner plus its actual callback parameters. There is no
event-kind argument and no common event dispatcher. The record layout that
supports this private bridge is an implementation detail, not an owner shape
to reproduce elsewhere.

## DNS extraction and connection attempts

Host text is checked for an embedded NUL, and the decimal port is built as a
Titan string. `uv_getaddrinfo` receives an `AF_UNSPEC`, `SOCK_STREAM`,
`IPPROTO_TCP`, `AI_NUMERICSERV` hint and copies those text arguments during
submission. Its result chain is borrowed only for the callback.

The callback accepts IPv4 and IPv6 entries whose addresses fit the opaque
`titan_uvshim_address` cell, copies them in resolver order into a GC-owned
array, and calls `uv_freeaddrinfo` before resuming the Task. No continuation
retains a pointer into libuv's result chain. The opaque cell is aligned and
large enough for `sockaddr_storage`; Titan never interprets its bytes except
to pass one selected cell back to libuv as `const sockaddr *`.

Connect and listen try copied addresses in resolver order. Each attempt owns a
fresh TCP handle. Failure initiates that candidate's ordinary `uv_close`
before the continuation moves to the next address; the close callback may run
later. A successful outgoing or accepted connection starts its read watcher
lazily when its first read is dispatched.

The public `net.listen` facade substitutes backlog 128 when its trailing
argument is absent, validates the resulting value, and passes an ordinary
required integer to private `uv._net_listen`. Defaulting therefore adds no
optional type or policy to `titan.uv`.

## Multi-shot reads and accepts

The allocation callback receives libuv's `uv_buf_t` destination. The Titan
handler allocates a GC-owned byte array, stores it as the TCP owner's current
buffer, and fills that descriptor. A direct C callback cannot unwind an
allocation exception through libuv, so failure returns a zero buffer and
preserves that exact exception for the required paired read callback. The
read callback still trusts libuv's alloc/read pairing: it transports that
exception to the waiter, or logs it and stops an unwaited read, without a
second recovery status or a defensive missing-allocation branch.

For an ordinary allocation, the read callback clears the field and either
delivers the logical prefix to the one waiting Task or appends the resulting
string to the owner's buffered chunks. Zero-length notifications deliver
nothing. EOF and errors stop reading and set sticky terminal read state before
resuming a waiter.

A low-level read returns the oldest buffered chunk, otherwise returns sticky
EOF or error, otherwise installs one waiter. A second waiter is rejected. The
public facade implements delimiter reads by repeatedly calling that primitive
and retains only bytes after a matched delimiter. It does not add a reader-lock
record, cancellation rollback, or special error-tail identity. There is
deliberately no buffer high-water mark in this initial API.

A listener similarly keeps at most one accept waiter plus already accepted
clients. Each connection callback accepts exactly one client and either
resumes the waiter or buffers the client. That client's read watcher remains
lazy. Closing the server closes buffered clients as well.

These arrays buffer results from genuinely multi-shot callbacks; they are not
operation queues or a scheduler. Writes need no Titan queue: every call
submits its own `uv_write_t`, and libuv supplies stream write ordering.

## Cancellation, shutdown, and close

Cancellation of DNS, connect, write, or shutdown does not release its owner
early. The native callback still performs cleanup, and the Task's next resume
injects its sticky cancellation. Cancelling a read or accept only detaches the
matching waiter from the shared multi-shot handle. A private zero-duration
timer wakes that Task on a later loop turn, preserving the non-reentrant
callback model while the TCP watcher remains active.

`Connection:shutdown` submits one `uv_shutdown_t`; libuv's writable-state
query makes later calls no-ops once the write side is shut down.
`Connection:close` and `Server:close` submit one `uv_close`; libuv stops the
handle's active watcher and its handle state answers later close checks. The
closer is that callback's sole continuation. Any reader or acceptor detached
by explicit close is woken by an independent zero timer rather than being
resumed synchronously or attached to the close callback.

Final Runtime cleanup does not traverse a Titan networking registry. Its
cleanup Task discovers the remaining `uv_tcp_t` handles through `uv_walk` and
closes them through the same callback protocol. GC root tables only keep
native owners live until callbacks; they are not the source of traversal.

## Portable native boundary

Titan calls the public libuv request, stream, handle, and request-data APIs
directly through the host's `uv.h`. The C support layer contains the
libuv-shaped callback shims, the opaque normalized-address cell, and one tiny
helper that initializes a `uv_buf_t` from rooted const string bytes. There is
no POSIX socket, read, write, poll, or resolver fallback.

Compiler tests cover the FFI and callback mechanisms. The focused
standard-library suite, run outside LuaCov, covers binary listen/connect/
accept/read/write/EOF behavior, endpoint validation, and closing a server with
a pending accept. Runtime cleanup has a separate native-handle behavior gate.
