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
recover the module-cached main thread and fixed dispatcher closure, obtain the
module Udata from that closure, and call the dispatcher's Titan-native entry.
They do not use a generated Lua entry or a second protected-call layer.

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

An outgoing Connection calls `uv_read_start` after connect succeeds and before
it is published. An accepted Connection starts reading after `uv_accept` and
before it is delivered to a waiter or placed in the accepted-client queue; a
queue-full candidate is closed without starting. A synchronous start failure
closes the unpublished Connection and fails the connect or accept operation.
Once initialized, the read watcher remains active with or without a waiter.

The C allocation callback is a thin native-Titan dispatch. It initializes
libuv's supplied `uv_buf_t` to `{ NULL, 0 }`, then the Titan dispatcher creates
a fresh `ffi.titan_ffi_char.new_array(suggested_size)`, roots that full userdata
as the Connection's current allocation, and writes its raw pointer and size to
the descriptor. The descriptor belongs to libuv; it is not the bytes' owner.
On supported Unix libuv pairs each allocation with its read callback before
requesting another for that stream, although one watcher dispatch can repeat
that pair. A POLLHUP-only EOF callback can have no preceding allocation, so
terminal handling accepts an empty current-allocation slot.

Without a waiter, a positive read callback moves the current userdata into the
Connection's `{Bytes}` queue; `Bytes.storage` is the GC edge for its raw pointer
and queued buffers are not reused. With a waiter, the callback instead converts
the current allocation directly to one binary string. It snapshots and clears
the waiter and epoch before `drive_task`, clears the current root only after the
bytes are queued or converted, and passes the string directly to the yielded
read. The resumed Task may install a replacement waiter before the callback
returns. A zero-length callback clears the current allocation and delivers
nothing.

EOF and non-EOF read errors clear any current allocation, stop reading, and
record a sticky terminal before driving arbitrary code. EOF directly resumes a
waiter with `nil` but leaves the TCP write side open. Another error stores a
the uv-owned `Error` record (publicly `async.Error`), raises it directly in a
waiter, and initiates physical close. A
later low-level read first joins and drains the entire completed queue, then
returns sticky `nil` or repeatedly raises the stored error. With no data or
terminal it only installs one waiter; it never starts or stops libuv. Explicit
close stops the physical read, and Runtime teardown may discard queued chunks.

The `net` facade serializes both `read` and `read_until` through one reader
lock. It keeps delimiter excess in stream order, implements optional delimiter
chopping and terminal-tail delivery, and preserves accumulated bytes across
cancellation. A narrow low-level identity predicate lets it recognize only the
stream's stored sticky read error when returning a nonempty terminal tail;
Task cancellation and unrelated exceptions are re-raised. There is no maximum
or high-water mark: an unread peer can grow the GC-owned queue without bound.

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
If an accepted client's read watcher cannot start, the candidate is closed and
the failure is delivered to the accept waiter or retained through the server's
terminal accept-error path.

## Cancellation and shutdown

Task cancellation increments the existing operation epoch synchronously. DNS
uses `uv_cancel` but retains its request until callback. Connect closes its
unpublished handle. Read cancellation clears only the matching waiter and
epoch; continuous reading and buffering remain active. A queued write is
unlinked, while cancellation of an active write is logical because libuv
cannot cancel it and a shared Connection must remain open. The first shutdown
and every explicit close waiter are cleanup-shielded through their terminal
callbacks.

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

Compiler tests cover the language mechanisms used by the opaque wrappers;
standard-library behavior is tested separately without compiler coverage.
Loopback tests probe a bounded range of explicit ports through the public
listen API. They cover IPv4, optional IPv6, resolver fallback, binary and NUL
data, split delimiters, excess restoration,
FIFO writes, repeated and concurrent shutdown/close, bounded accepts,
exclusive waiters, continuous background buffering, cancellation that leaves
the watcher active, sticky EOF, delimiter terminal tails, leaked-resource
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
