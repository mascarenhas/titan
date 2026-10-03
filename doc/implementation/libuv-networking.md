# DNS and TCP implementation

`titan.net` implements the [TCP API](../language/standard-library-net.md) with
ordinary imports of public `uv`, `async`, and `string`. It has no C FFI import
or source-private UV dependency. The [UV binding](../language/standard-library-uv.md)
owns native storage, callback frames, and native registration lifetimes;
[async](libuv-runtime.md) owns Tasks, registration waits, delivery, cancellation,
and subscriptions. Net owns socket policy, DNS result selection, buffering,
delimiter parsing, and application-visible errors.

A `Connection` retains one `uv.tcp_t`, its owning loop, delimiter excess, a
`BufferedSubscription<|string, value|>`, and lazy-read state. A `Server` retains
one `uv.tcp_t`, its loop, a `BufferedSubscription<|Connection, value|>`, and an
optional saved failure. These remain private fields of the public net records.
The TLS implementation composes over these public records and never obtains
their low-level owner; see [TLS implementation](ssl-library.md).

## One-shot request adapters

DNS, connect, write, and shutdown submit public request owners through
`async.await`. Each registration receives typed `resolve` and `reject`
capabilities plus `fatal(error, traceback)`. A negative immediate native status
rejects the operation without expecting a callback. Accepted requests retain
all native owners and callback captures through their terminal completion.
Cancellation remains pending until that native retirement; it does not release
borrowed buffers early or change the public method's result into a native
cancellation API.

Every terminal callback wraps its result handling and resolver/rejecter call in
a catch that calls the exact registration's `fatal` capability and then bare
rethrows. An unexpected callback exception therefore reaches both the owning
Wait and the outer native-driver boundary, preserving the original error and
trace. It is not converted into an ordinary operation error.

DNS validates host text and submits `uv.getaddrinfo` with `AF_UNSPEC`,
`SOCK_STREAM`, `IPPROTO_TCP`, and `AI_NUMERICSERV`. The public binding copies
native address entries into ordinary owned values. Net selects IPv4/IPv6
entries in resolver order and frees the native result before settlement. A
lexical release also asks the request for its retained result and frees it;
that idempotent path covers failure inside the binding's result copy before
net's callback begins. Returned `uv.sockaddr_t` values survive that cleanup.

Connect and listen try the copied addresses in order with a fresh TCP owner per
attempt. A candidate stays lexically owned until successful publication. A
failed attempt or a cancelled native success starts close on its unpublished
socket; the native owner remains rooted until close completion. `listen`
selects backlog 128 when absent and validates the positive native integer range
before submission.

Each write owns one `uv.write_t` and a buffer view retaining the immutable
Titan string. Async writes snapshot the native vector descriptors and retain
the payload owners; mutating the descriptor Array later cannot retarget a
submitted write. Libuv provides write ordering, so net adds no writer queue.
Shutdown uses one `uv.shutdown_t`; subsequent shutdown is a no-op once the
native stream is no longer writable.

## Persistent reads

A connection constructs its subscription and producer callbacks before native
TCP initialization. It starts `uv.read_start` only when the first ordinary read
needs native input. The allocation callback returns a writable `uv.buf_t`; the
public binding retains the paired buffer and handles allocation-callback
failure across the native boundary.

A positive read copies the exact byte prefix into a Titan string and publishes
it. Zero-byte notifications publish nothing. EOF or a negative status stops
native reading and ends or fails the subscription. Previously queued bytes
remain readable before the terminal EOF/error. Net retains only delimiter
excess outside the subscription; there is no second native-input queue or
extra reader lock. The literal delimiter algorithm still handles boundaries
split across chunks and preserves bytes after a match.

Closed/excess fast paths retain their existing order. A read which needs the
subscription validates its Task and owning Runtime, then uses an inline
ordinary await as its cancellation checkpoint before checking
`input:has_waiter()`. Pending cancellation therefore wins over the existing
`Connection already has a waiting reader` diagnostic. A live checkpoint
settles inline without an event-loop turn. The subscription's authoritative
reservation remains held through deferred wake delivery; cancellation removes
that reservation synchronously, allowing a replacement reader immediately.
Cancelling one reader leaves the shared native read source active.

## Accept delivery and unread sockets

A listener's connection callback creates and accepts one new `Connection`.
A lexical cleanup owns that socket until `publish(client)` returns true.
Publishing transfers ownership to the subscription queue; rejection or an
exception closes the unpublished socket. Accepted connections also start their
read watcher lazily.

Server failure takes precedence over unread accepted clients. It saves the
failure, drains and closes every queued socket, closes the listening handle,
and stops delivery. `accept` checks that saved failure before validation and
after waking. Otherwise it performs the ordinary cancellation checkpoint before
its authoritative reservation check and preserves the existing duplicate-wait
diagnostic. Closing a server also drains and closes every unread accepted
connection; a generic queue cannot infer that these values own sockets.

## Close and Runtime ownership

A native owner is closed when it is no longer initialized or libuv reports it
closing. Checking initialization first avoids a native query outside the valid
handle lifetime. Public close methods retain idempotent terminal behavior,
while live I/O checks the current Task and exact owning Runtime.

Connection close discards delimiter excess and closes its subscription. The
producer's stop action ends native reading; its close action drains unread
bytes and uses `async.await_cleanup` for native close completion. Server close
uses the same pattern while explicitly disposing queued connections. Cleanup
waits retire ownership even when the closing Task already has sticky
cancellation. Subscription close does not provide a second join barrier for
another concurrent caller: the first closer owns its cleanup work.

Runtime teardown belongs to async. After Tasks and accepted operations have
retired, it walks remaining public native handles and closes them before closing
the loop. Net has no Runtime networking registry, operation dispatcher, raw
socket fallback, or per-operation generation counter. Compiler, native library,
packaging, sanitizer, and platform gates validate their respective boundaries;
API coverage alone does not imply every native backend has been executed.
