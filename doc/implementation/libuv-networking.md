# Libuv DNS and TCP implementation

The public API and semantics are documented in the [TCP networking standard
library](../language/standard-library-net.md).

The `net` facade contains no C FFI types. Each `Connection` or `Server` holds
one local `uv.uv_tcp_t` record; the `uv` module alone can unwrap its local
`*uv_tcp_t` field. Repeated calls therefore read the native pointer directly
without allocating pointer-boxing userdata.

## Ownership graph

An active Runtime adds a pending networking-owner list and a TCP resource list
to its existing task, timer, and filesystem graph. Request and handle storage
is allocated as Lua userdata using the imported libuv type's `.sizeof`, then
kept alive by one exact Titan owner record. Libuv `data` points to that owner
record, never to the separate storage userdata.

Persistent `uv_tcp_t` owners and private DNS, connect, write, and shutdown
owners keep the fixed callback layout used by `titan_uv.c`. Native callbacks
recover the Runtime main thread, module Udata, and fixed dispatcher closure and
call the dispatcher's Titan-native entry. They do not use a generated Lua entry
or a second protected-call layer.

## DNS extraction

Host text has an operation-owned NUL-terminated copy. The shim calls
asynchronous `uv_getaddrinfo` with stream/TCP hints and constructs the numeric
service locally for the submission. Compatible IPv4/IPv6 addresses are copied
in resolver order into GC-owned arrays of opaque `titan_uvshim_address` cells.
Static assertions in the shim guarantee that each cell is large and aligned
enough for the platform's `sockaddr_storage`; Titan never inspects its bytes.

The C callback passes libuv's borrowed `addrinfo` pointer directly to the
trusted Titan dispatcher. The dispatcher first copies usable addresses, then
calls `titan_uvshim_addrinfo_free`, whose C implementation invokes
`uv_freeaddrinfo`, before it drives a Task or starts a socket attempt. Its
trailing emergency catch performs the same release directly when needed. No
continuation observes or retains the borrowed pointer, and each non-null result
has one release path.

Connect and listen allocate a fresh TCP handle for every address attempt. A
failed initialized candidate is closed and drained before the next attempt.
Cancellation closes an unpublished candidate and waits for both request and
close callbacks; late success is never published.

## Stream callbacks

Connections own a GC byte buffer. The C allocation callback reads its fixed
pointer, capacity, and active-length fields and never enters Titan. A read
callback with positive length stops reading, copies exactly that many bytes to
a Titan string, clears the waiter, and directly drives its Task. A zero length
does nothing. A negative result stops reading and stores EOF or an Error before
driving arbitrary code; the stream is never restarted after that terminal
event.

Writes and shutdown use a per-Connection FIFO with one submitted request.
Every write request owns its copied bytes through the callback. The first
shutdown marks the source-level write side closed when queued, is submitted
only after earlier writes, and remains cleanup-shielded through its callback;
repeated calls are idempotent. Explicit close stops reads and rejects new
output, but preserves the submitted request and queued FIFO work. It calls
`uv_close` once only after that output drains, then waits until the close
callback has released the handle root.

Servers keep one accept waiter and a FIFO of already accepted Connections
bounded by the listen backlog. Every incoming callback performs one
`uv_accept`. A full queue closes that new client and keeps the listener active.

## Cancellation and shutdown

Task cancellation increments the existing operation epoch synchronously. DNS
uses `uv_cancel` but retains its request until callback. Connect closes its
unpublished handle. Read cancellation calls idempotent `uv_read_stop`. A
queued write is unlinked, while cancellation of an active write is logical
because libuv cannot cancel it and a shared Connection must remain open. The
first shutdown and every explicit close waiter are cleanup-shielded through
their terminal callbacks.

Runtime shutdown first cancels DNS and unpublished acquisitions, then stops
reads and retires queued operations, then closes Servers, accepted queues, and
Connections. This forced teardown is distinct from explicit close, which
preserves FIFO output. The Runtime does not release a request before its
completion callback or a handle before its close callback. Both networking
root lists must be empty before `uv_loop_close`.

## Portable shim boundary

The shim contains only callback ABI normalization, concrete-to-base libuv
casts, explicit-length byte and address copying, and small sockaddr adapters
required by public libuv APIs. All socket, resolver, stream, and close behavior
uses public libuv functions. There is no POSIX socket, read, write, or poll
fallback.

The callback dispatcher adds one opaque pointer argument for the DNS callback's
temporary `addrinfo` payload. The pointer is never converted to a Titan
`value`; callbacks without a pointer payload pass NULL. Address-family
constants remain isolated in the sockaddr adapter because libuv's public
DNS/TCP interface itself uses those host structures.

## Verification

Checker tests lock the public signatures, local wrapper fields, and serialized
interface hiding. Loopback tests use port 0 and query the bound port through a
test-only `uv_tcp_getsockname` adapter. They cover IPv4, optional IPv6,
resolver fallback, binary and NUL data, split delimiters, excess restoration,
FIFO writes, repeated and concurrent shutdown/close, bounded accepts,
exclusive waiters, cancellation, permanent read errors, GC, leaked-resource
shutdown, and sequential Runtime generations.

Fault-source variants count callback arrival, calls into the DNS-result release
shim, handle close, pending owners, and TCP resources. The DNS release counter
observes the Titan-to-C shim call; the physical `uv_freeaddrinfo` executes
synchronously inside that C helper rather than in instrumented Titan code.
Regular Linux and manual macOS CI run those variants. The focused Linux
ASan/UBSan gate instead uses the production DNS/TCP smoke, including a delayed
reader that keeps a large `uv_write_t` pending across Task cancellation,
coroutine unwind, forced GC, exact binary delivery, and a follow-up write.
Manual macOS CI also repeats the normal linkage checks.
