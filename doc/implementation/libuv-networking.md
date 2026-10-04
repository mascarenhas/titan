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
optional saved failure. Both cache their public handle and stream views once
during construction; operations still query current native initialization,
closing, and writability state. These remain private fields of the public net
records.
The TLS implementation composes over these public records and never obtains
their low-level owner; see [TLS implementation](ssl-library.md).

## One-shot request adapters

DNS, connect, write, and shutdown submit public request owners through
`async.await_with`. Each operation has a private input context, a named
registrar, and a named native callback. Registration stores the Task-owned
`Completion` and its captured suspension number in that context, then attaches
the context to the exclusive request's userdata. Concrete request data methods
avoid allocating generic request views. A negative immediate native status
clears that attachment and rejects without expecting a callback. Accepted
requests retain their context and native inputs through terminal completion.
Cancellation remains pending until that native retirement; it does not release
borrowed buffers early or change the public method's result into a native
cancellation API.

Every terminal callback snapshots its context, Completion, and captured number,
then clears request userdata and the context's Completion reference before
settlement can resume the Task. It wraps result handling and settlement in a
catch that calls `completion:fatal(number, error, traceback)` and bare rethrows.
An unexpected callback exception therefore reaches both the owning wait and the
outer native-driver boundary, preserving the original error and trace. It is
not converted into an ordinary operation error. Callbacks never read a later
operation's number from the reusable Completion.

The contexts replace the input captures of the former registrars; they are
still one allocation per operation. Writes keep independent contexts and
requests, so an overlapping call cannot overwrite another callback's number.

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

Each write owns one fresh `uv.write_t` and submits its immutable Titan string
through `uv.write_string`. The public request retains the string and contains
its scalar native descriptor, avoiding the buffer view and descriptor Arrays
needed by a vector write. Net calls the nonallocating `uv.buf_check_length`
before ordinary await admission, retaining the previous native-range error
precedence even for an already cancelled Task. The terminal UV callback roots the old string before
clearing request fields or calling Titan code. Overlapping writes retain
independent requests and payloads; cancellation never recycles a live request.
Libuv provides write ordering, so net adds no writer queue.
Shutdown uses one `uv.shutdown_t`; subsequent shutdown is a no-op once the
native stream is no longer writable.

## Persistent reads

A connection constructs its subscription and producer callbacks before native
TCP initialization. It starts `uv.read_start` only when the first ordinary read
needs native input. The allocation callback lazily creates a writable
`uv.buf_t` and reuses it across callbacks, growing only to a maximum retained
capacity of 64 KiB. Suggestions outside the positive bounded range select that
cap. An idle open reader can retain at most 64 KiB of scratch storage; EOF,
error, producer stop, and explicit close drop the Connection's reference. The
public binding independently retains each allocation/read pair and handles
allocation-callback failure across the native boundary.
Runtime teardown closes raw handles without invoking Connection methods. A
retained Connection can therefore retain its bounded scratch buffer afterward;
the closed read/close paths clear that reference without native I/O.

A positive read copies the exact byte prefix into a fresh immutable Titan
string before publishing it; reusing scratch storage cannot change earlier
chunks. This scratch cap does not bound the subscription's queued strings.
Zero-byte notifications publish nothing. EOF or a negative status stops
native reading and ends or fails the subscription. Previously queued bytes
remain readable before the terminal EOF/error. Net retains only delimiter
excess outside the subscription; there is no second native-input queue or
extra reader lock. The literal delimiter algorithm still handles boundaries
split across chunks and preserves bytes after a match.

Closed/excess fast paths retain their existing order. A read which needs the
subscription validates its Task and owning Runtime, then calls
`async.checkpoint()` before checking `input:has_waiter()`. Pending cancellation
therefore wins over the existing
`Connection already has a waiting reader` diagnostic. A successful checkpoint
returns directly without a wait, status transition, or event-loop turn. The
subscription's authoritative reservation remains held through deferred wake delivery; cancellation removes
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
bytes and uses `async.await_cleanup_with` for native close completion. The
generic close path owns a private context containing the handle, Completion,
and captured number; handle userdata carries it to the named close callback.
Server close
uses the same pattern while explicitly disposing queued connections. Cleanup
waits retire ownership even when the closing Task already has sticky
cancellation. Subscription close does not provide a second join barrier for
another concurrent caller: the first closer owns its cleanup work.

Runtime teardown belongs to async. After Tasks and accepted operations have
retired, it walks remaining public native handles and closes them before closing
the loop. Net has no Runtime networking registry, operation dispatcher, raw
socket fallback, or domain-generated operation counter. The captured suspension
number belongs to async. Compiler, native library,
packaging, sanitizer, and platform gates validate their respective boundaries;
API coverage alone does not imply every native backend has been executed.
