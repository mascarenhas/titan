# Continuous stream reads

This document is the implementation contract for replacing the one-shot,
size-limited stream reads in `titan.uv`, `titan.net`, and `titan.os`. It is a
focused addendum to `libuv-async-io-standard-library.md`; where that older plan
describes `read_some`, `read_exactly`, size-limited `read_until`, or starting
and stopping libuv for each read request, this document takes precedence.

## Goals

- Start reading a connected stream as soon as the stream is successfully
  initialized and owned by the Runtime.
- Keep libuv reading continuously, even when no Task is waiting, and buffer
  completed chunks in GC-traced Titan state.
- Make one low-level read return all bytes currently buffered, or wait for the
  next positive read callback when no bytes or terminal condition is present.
- Make EOF and read errors sticky: EOF reads keep returning `nil`; caught read
  errors are raised again on every later read with the same or equivalent
  `uv.Error`.
- Replace the high-level size-oriented APIs with `read()` and delimiter reads
  that have no artificial maximum.

## Streams and when reading starts

Only readable data streams start reading. The Runtime calls `uv_read_start`
exactly once for each successfully published stream at these points:

- an outgoing TCP connection, after the connect callback succeeds;
- an accepted TCP connection, after `uv_accept` succeeds and only when the
  client will be delivered to a waiter or retained in the accepted-client
  queue;
- a spawned process's stdout and stderr pipes, after `uv_spawn` succeeds.

Listening TCP handles and process stdin do not start reading. A synchronously
failing `uv_read_start` is part of stream initialization: the stream is not
published, its native ownership is closed or rolled back, and the operation
that would have published it fails. This cleanup is atomic across the owning
operation:

- an outgoing connection is closed and its connect operation fails;
- an accepted client is closed and the failure is delivered to the waiting
  accept Task or retained as the server's terminal accept error through the
  existing server-callback-failure path;
- if either output pipe fails after `uv_spawn` succeeds, any already-started
  sibling read is stopped, all three pipes are closed, the child is terminated
  and reaped through the ordinary grace/kill path, and the process handle is
  closed before the original spawn Task receives the failure.

Once initialization succeeds, ordinary
`_net_read`, `_os_process_read_stdout`, and `_os_process_read_stderr` calls do
not call `uv_read_start` or `uv_read_stop`.

Continuous reading remains active with no reader Task. A cancelled read only
detaches the matching waiter and epoch; it does not stop the physical read.
Explicit close, Runtime shutdown, EOF, and non-EOF read error stop the read
side. EOF on TCP does not automatically close the whole TCP handle because its
write side can remain usable. A non-EOF read error initiates physical close.

## Native allocation and callback path

The C shim's `alloc_cb` is a thin dispatcher to a trusted native Titan entry,
like the other libuv callbacks. The Titan dispatcher allocates a fresh
`ffi.titan_ffi_char.new_array(suggested_size)` for every `alloc_cb`, stores the
full userdata in the stream owner/control as the current allocation, and
writes only its raw data pointer and length into libuv's supplied `uv_buf_t`.
The `uv_buf_t *` belongs to libuv and is not the object that owns the bytes.

The shim initializes the output descriptor to `{ NULL, 0 }` before dispatch.
The Titan entry has the normal outer `catch`/longjmp fence. If allocation or
dispatcher work fails, it records a fatal Runtime failure and returns the
zeroed descriptor so no longjmp crosses libuv. On the supported Unix path,
libuv then reports `UV_ENOBUFS` through the read callback; that callback safely
stops the read side without clearing the callback before libuv invokes it.

libuv's Unix stream implementation, used on supported Linux and macOS, pairs
each allocation with its read callback before requesting another allocation
for that stream. A single watcher dispatch may repeat the pair many times, so
the current allocation must be consumed or cleared by `read_cb` before the next
`alloc_cb`. A POLLHUP-only EOF callback may arrive with no preceding
allocation; terminal handling must tolerate an absent current allocation.

Completed chunks use the existing representation:

```titan
local record Bytes
  local data: *ffi.titan_ffi_char
  local storage: value
  local length: integer
end
```

The completed queue is `{Bytes}`. There is no second `ReadChunk` type and no
parallel queue of strings. `Bytes.storage` is the GC edge that keeps `data`
valid. Queued buffers are immutable and are not reused. Ownership moves in
this order: publish a positive allocation as a queued `Bytes`, or convert it
directly to the waiter payload, before clearing the current-allocation root.

`read_cb` behaves as follows:

- `nread > 0`, waiter present: snapshot and clear waiter/epoch, convert the
  current allocation to one binary string, clear the current root, and resume
  the Task directly with that string.
- `nread > 0`, no waiter: append a `Bytes` containing the current userdata and
  `nread` to the completed queue, then clear the current root.
- `nread == 0`: queue and resume nothing; clear the current root.
- `nread == UV_EOF`: clear any current root, record sticky EOF, stop the read
  side, and directly resume a waiter with `nil`.
- other `nread < 0`: clear any current root, record a sticky `uv.Error`, stop
  reading, initiate physical close, and directly raise that error in a waiter.

Successfully completed queued bytes are never discarded by EOF or error. They
remain readable before the terminal condition is observed.

The callback snapshots and clears waiter and epoch before calling
`drive_task`. The resumed Task may install a replacement waiter before the
original callback returns, so callback code must not perform a generic waiter
clear after `drive_task`. A libuv callback may resume user code directly; this
is the intended continuation model. Wakes initiated by an explicit close while
another Task is already running use the scheduled-drive path and do not nest a
second `drive_task`.

## Low-level read protocol

The TCP and process-pipe read operations have no byte-count argument. On each
call they apply this order:

1. If completed chunks are queued, join and remove the entire current queue and
   return the resulting nonempty binary string synchronously.
2. If the read terminal is EOF, return `nil` synchronously. EOF is not cleared;
   every subsequent read also returns `nil`.
3. If the read terminal is a non-EOF error, raise the stored `uv.Error`
   synchronously. The error is not cleared; if caught, every subsequent read
   raises the same or an equivalent error.
4. If the handle was explicitly closed without EOF/error, raise a closed-stream
   error.
5. If another Task is currently waiting, raise the concurrent-reader error.
6. Otherwise yield a read request whose scheduler arm only records the Task and
   epoch as the waiter. Reading is already active.

When a callback wakes the waiter, the yielded call receives the callback's
payload or error directly; it does not loop and inspect stream state again.
Different Tasks may read the same stream sequentially whenever no Task is
currently waiting. Avoiding semantic interference between such Tasks is the
caller's responsibility.

Explicit close may leave already completed chunks drainable. After those are
drained, EOF remains `nil`, a read error remains an error, and a plain explicit
close raises a closed-stream error. Runtime teardown may discard queues because
all handles from that Runtime generation become stale.

The low-level module exposes a narrow internal identity predicate for the
high-level delimiter reader to recognize the stream's stored sticky read error
without mistaking Task cancellation or an unrelated exception for EOF-like
termination.

## `titan.net` API

`Connection` exposes:

```titan
function Connection:read(): string?
function Connection:read_until(delimiter: string,
                               chop: boolean?): string?
```

`read_some(max_bytes)` and `read_exactly(bytes)` are removed.
`read_until(delimiter, max_bytes)` is replaced by the signature above.

`read()` holds the same per-Connection reader lock as `read_until`. It returns
all bytes already retained by the facade, otherwise delegates to the low-level
read. It does not combine facade excess with a low-level batch in one call: the
older retained bytes are the first batch and preserve stream order. A low-level
positive batch is timing-dependent: it is all completed native chunks present
when that low-level call is serviced, or the next positive callback payload.
`read()` returns `nil` only for EOF.

`read_until` rejects an empty delimiter and holds the Connection's reader lock
for the entire composite operation. It consumes through the first delimiter
and retains any bytes after it for the next call. With `chop` absent or false,
the returned string includes an actual delimiter; with `chop == true`, it does
not. An empty string is a valid successful result when the delimiter occurs at
the start and is chopped, and is distinct from EOF `nil`.

If EOF arrives after a nonempty unterminated tail, `read_until` returns that
tail unchanged and the next call returns sticky `nil`. If a read error arrives
after a nonempty unterminated tail, `read_until` returns that tail unchanged
and leaves the sticky error to be raised on the next and all later reads. It
never fabricates a delimiter. With no tail, EOF returns `nil` and an error is
raised immediately. Cancellation and unrelated errors are always re-raised;
they are not converted into a successful short result. Bytes accumulated
before cancellation remain retained for a later read.

There is no read maximum or facade high-water mark. Continuous buffering can
grow with unread peer output; this is an intentional policy that trades
application memory for uninterrupted kernel-stream draining.

## `titan.os` process API

`Process` exposes the same independent protocol for stdout and stderr:

```titan
function Process:read_stdout(): string?
function Process:read_stdout_until(delimiter: string,
                                   chop: boolean?): string?
function Process:read_stderr(): string?
function Process:read_stderr_until(delimiter: string,
                                   chop: boolean?): string?
```

Each pipe has its own reader lock and retained excess. Both its plain and
delimiter read methods hold that lock for their complete call. Delimiter, chop,
terminal-tail, cancellation, sticky EOF, sticky error, and unbounded-buffer
semantics match `Connection`. `communicate` drains stdout and stderr through
the new no-argument reads.

## Verification obligations

Behavioral coverage belongs under `spec/stdlib/` and runs without LuaCov. It
must cover the deterministic public behavior, for TCP and process pipes as
applicable:

- data buffered before the first user read and complete preservation across
  multiple writes and returned batches;
- replacement readers, cancellation detaching only the waiter, sequential
  Tasks, and rejection of two simultaneous waiters;
- binary/NUL data, split delimiters, multiple delimited records, `chop`
  true/false, and chopped empty strings distinct from EOF;
- EOF tail followed by repeated `nil`;
- Runtime shutdown/GC ownership while continuous reads and queued native byte
  userdata are present;
- independent process stdout and stderr behavior and `communicate` draining.

Callback batching, direct-waiter delivery, zero-byte callbacks, non-EOF stream
errors, and synchronous `uv_read_start` failures have no stable trigger or
observable path identity through the public TCP/process APIs. Their ownership,
queue joining, sticky-error ordering, error-triggered-close, and atomic
initialization-cleanup paths are source-level invariants checked by focused
review plus the ordinary and sanitizer builds. Do not add production fault
hooks or a copied standard-library variant solely to manufacture those
transitions.

Update the net/OS language chapters, the libuv runtime/networking implementation
chapters, the older async-I/O plan, inline production smoke programs, fault
fixtures, and packaging mocks that mention the removed signatures. The
authoritative verification remains an isolated-prefix build followed by
focused standard-library specs and the full `make test` suite.
