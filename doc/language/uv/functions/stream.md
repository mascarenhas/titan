# stream API reference

Complete public example: [dns_tcp](../examples/dns_tcp.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

TCP/pipe/TTY owners expose stream_t and handle_t views of one owner. Allocate before init, close explicitly after use. Listen/read notifications repeat; write/connect/shutdown requests complete once. Accepted write vectors are snapshots retaining every byte owner through callback return. Stop is not close. Allocation callbacks return writable buf_t; receive buffers cannot be immutable strings. Windows TTY read_start/set_mode may invoke callbacks synchronously, so errors rethrow after the native call returns on the main Lua thread.

## accept

`uv_accept` — **canonical exported function**

Move one pending accepted native connection from the listening stream into an initialized compatible client owner. A successful accept transfers the new connection to that client's close lifetime.

```titan
function accept(server: stream_t, client: handle_t): integer
```

**Inputs and outputs:** server: INPUT/OUTPUT initialized stream_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; client: INPUT/OUTPUT initialized handle_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Native-compatible initialized client handle on the same loop; Windows accepts TCP to TCP, non-IPC pipe to pipe, and IPC pipe to TCP. Unix preserves native TCP/pipe/UDP client support. Unsupported kinds and closing clients reject before native entry. CREATE_PIPE policy: this operation consumes eligibility from each pipe used as server or client when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L543).


## is_readable

`uv_is_readable` — **canonical exported function**

Query whether the stream currently supports the named direction. This is a native state snapshot, not readiness or a successful-operation guarantee.

```titan
function is_readable(stream: stream_t): boolean
```

**Inputs and outputs:** stream: INPUT/OUTPUT initialized stream_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: boolean. Requires initialized stream; buffer owner is writable on reads and retained on async writes. Descriptor ownership follows concrete TCP/pipe/TTY open/init. Stop does not close.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L594).


## is_writable

`uv_is_writable` — **canonical exported function**

Query whether the stream currently supports the named direction. This is a native state snapshot, not readiness or a successful-operation guarantee.

```titan
function is_writable(stream: stream_t): boolean
```

**Inputs and outputs:** stream: INPUT/OUTPUT initialized stream_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: boolean. Requires initialized stream; buffer owner is writable on reads and retained on async writes. Descriptor ownership follows concrete TCP/pipe/TTY open/init. Stop does not close.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L595).


## listen

`uv_listen` — **canonical exported function**

Start listening on an initialized stream with the requested backlog. Each callback reports connection availability/status; allocate and initialize a compatible client and call `accept` separately.

```titan
function listen(stream: stream_t, backlog: integer, callback: connection_cb): integer
```

**Inputs and outputs:** stream: INPUT/OUTPUT initialized stream_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; backlog: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized stream; buffer owner is writable on reads and retained on async writes. Descriptor ownership follows concrete TCP/pipe/TTY open/init. Stop does not close. Connection callback reports pending accept/error; accept writes into already initialized compatible client on same loop. No accepted client ownership transfers until accept success. TTY rejects with EINVAL before native dispatch. CREATE_PIPE policy: this operation consumes eligibility from its pipe server when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md.

**Callbacks:** persistent-connection. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L542).


## read_start

`uv_read_start` — **canonical exported function**

Start stream reads using `alloc_callback` to supply writable `buf_t` storage. Read callbacks report a byte count, EOF/error, or a no-data notification; retain copied/borrowed data according to the callback contract.

```titan
function read_start(stream: stream_t, alloc_callback: alloc_cb, read_callback: read_cb): integer
```

**Inputs and outputs:** stream: INPUT/OUTPUT initialized stream_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; alloc_callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return.; read_callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized stream; buffer owner is writable on reads and retained on async writes. Descriptor ownership follows concrete TCP/pipe/TTY open/init. Stop does not close. alloc_cb outputs writable buffer; read callback may return positive bytes, 0 with no data, EOF/error. The binding ends its native read-buffer borrow when delivery completes. A returned buf_t view retains the allocation and may be saved after callback return; it is not invalidated by native retirement. Negative read requires read_stop or close. The callback frame retains the allocation owner even when user code raises. Windows synchronous TTY callbacks require the main Lua thread, disallow uv.run and uv.loop_close reentry (uv.close(handle) remains allowed), isolate original-loop first-error state, and rethrow after native return while preserving accepted ownership. CREATE_PIPE policy: this operation consumes eligibility from its pipe stream when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md.

**Callbacks:** persistent-alloc-read; Windows TTY allocation/read callbacks can occur inline before return. owning main Lua thread; immediate inline failures rethrow only after native call returns; no run reentry

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L545).


## read_stop

`uv_read_stop` — **canonical exported function**

Stop future stream reads. It does not close the stream or discard data the caller already copied.

```titan
function read_stop(stream: stream_t): integer
```

**Inputs and outputs:** stream: INPUT/OUTPUT initialized stream_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized stream; buffer owner is writable on reads and retained on async writes. Descriptor ownership follows concrete TCP/pipe/TTY open/init. Stop does not close. CREATE_PIPE policy: this operation consumes eligibility from its pipe stream when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L548).


## shutdown

`uv_shutdown` — **canonical exported function**

Queue write-side shutdown behind preceding writes. Completion leaves the read side available; the handle still needs close.

```titan
function shutdown(req: shutdown_t, stream: stream_t, callback: shutdown_cb?): integer
```

**Inputs and outputs:** req: INPUT/OUTPUT allocated nonpending request owner; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; stream: INPUT/OUTPUT initialized stream_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized stream; buffer owner is writable on reads and retained on async writes. Descriptor ownership follows concrete TCP/pipe/TTY open/init. Stop does not close. Shuts write side after pending writes; retain initialized stream and request until callback. Not uv_cancel cancellable. CREATE_PIPE policy: this operation consumes eligibility from its pipe stream when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md.

**Callbacks:** deferred-once-on-success. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L451).


## stream_get_write_queue_size

`uv_stream_get_write_queue_size` — **canonical exported function**

Return the number of bytes still queued for writing on this stream.

```titan
function stream_get_write_queue_size(stream: stream_t): integer
```

**Inputs and outputs:** stream: INPUT/OUTPUT initialized stream_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized stream; buffer owner is writable on reads and retained on async writes. Descriptor ownership follows concrete TCP/pipe/TTY open/init. Stop does not close.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L540).


## stream_set_blocking

`uv_stream_set_blocking` — **canonical exported function**

Change the stream's native blocking mode. It does not turn Titan callbacks or a cooperative Task into a foreign-thread operation.

```titan
function stream_set_blocking(stream: stream_t, blocking: integer): integer
```

**Inputs and outputs:** stream: INPUT/OUTPUT initialized stream_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; blocking: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized stream; buffer owner is writable on reads and retained on async writes. Descriptor ownership follows concrete TCP/pipe/TTY open/init. Stop does not close. CREATE_PIPE policy: this operation consumes eligibility from its pipe stream when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L597).


## try_write

`uv_try_write` — **canonical exported function**

Attempt an immediate vector write without queuing a request. The result is bytes written or a negative status; a short positive result leaves the remaining bytes for the caller.

```titan
function try_write(stream: stream_t, buffers: {buf_t}): integer
```

**Inputs and outputs:** stream: INPUT/OUTPUT initialized stream_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; buffers: INPUT byte owner or vector; immutable strings are valid only for input; async submission snapshots descriptors and retains owners, so Array edits cannot alter accepted I/O; do not mutate borrowed byte contents before completion.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized stream; buffer owner is writable on reads and retained on async writes. Descriptor ownership follows concrete TCP/pipe/TTY open/init. Stop does not close. CREATE_PIPE policy: this operation consumes eligibility from its destination pipe stream when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L561).


## try_write2

`uv_try_write2` — **canonical exported function**

Attempt an immediate IPC-capable write with an optional borrowed send handle. No request is queued; byte-count/negative-status results and fresh-pipe eligibility follow the process policy.

```titan
function try_write2(stream: stream_t, buffers: {buf_t}, send_handle: handle_t?): integer
```

**Inputs and outputs:** stream: INPUT/OUTPUT initialized stream_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; buffers: INPUT byte owner or vector; immutable strings are valid only for input; async submission snapshots descriptors and retains owners, so Array edits cannot alter accepted I/O; do not mutate borrowed byte contents before completion.; send_handle: INPUT/OUTPUT initialized handle_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized stream; buffer owner is writable on reads and retained on async writes. Descriptor ownership follows concrete TCP/pipe/TTY open/init. Stop does not close. A closing transferred handle rejects before request registration/native entry. CREATE_PIPE policy: this operation consumes eligibility from its destination pipe stream when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md. A pipe used only as borrowed send_handle keeps its own eligibility. On Unix, a nonnil borrowed source first undergoes native fileno validation; a negative descriptor status returns before destination handoff and preserves its eligibility. Windows keeps native EAGAIN for transfers without this Unix preflight, so an attempted native write consumes destination eligibility.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L564).


## write

`uv_write` — **canonical exported function**

Queue one vector write. Accepted submission retains the request, stream, callback and every buffer owner until completion; libuv orders stream writes.

```titan
function write(req: write_t, stream: stream_t, buffers: {buf_t}, callback: write_cb?): integer
```

**Inputs and outputs:** req: INPUT/OUTPUT allocated nonpending request owner; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; stream: INPUT/OUTPUT initialized stream_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; buffers: INPUT byte owner or vector; immutable strings are valid only for input; async submission snapshots descriptors and retains owners, so Array edits cannot alter accepted I/O; do not mutate borrowed byte contents before completion.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized stream; buffer owner is writable on reads and retained on async writes. Descriptor ownership follows concrete TCP/pipe/TTY open/init. Stop does not close. Native copies vector metadata as needed; buffer bytes must survive callback, may not be reused early. Request reusable only after callback begins; retire old registration before callback. CREATE_PIPE policy: this operation consumes eligibility from its destination pipe stream when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md.

**Callbacks:** deferred-once-on-success. the owning main Lua thread; timing is specified above

**Cancellation:** Native libuv supports write cancellation; Titan cancel returns EINVAL for write requests.

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L550).


## write_string

```titan
function write_string(req: write_t, stream: stream_t, data: string, callback: write_cb?): integer
```

Queue the complete immutable string as one write, including embedded NUL bytes
and an empty string. This Titan convenience function follows `write` status,
callback, ordering, pipe eligibility, and request-reuse rules. A pending request
returns `EBUSY`; an uninitialized stream returns `EINVAL`. A string longer than
native `UINT_MAX` raises `"buffer length is outside string/native range"` before
submission. Native rejection returns its negative status, releases the attempted
registration, and owes no callback.

The request embeds one buffer descriptor and retains the string until the native
callback returns, without a `buf_t` or descriptor/owner Arrays. The old string
remains rooted while a completion callback reuses the request or raises. The
request can alternate scalar and vector writes after each completion begins.
There is no handle transfer; use `write2` for that operation.

`write_t:get_data(): value` and `write_t:set_data(data: value)` access the same
public traced slot as `req_t:get_data`/`set_data`, without constructing a request
view. The slot begins as nil and is independent of native callback ownership.

`buf_check_length(base: string, length: integer)` validates `0 <= length <=
#base` and `length <= UINT_MAX` with the same error as `buf_init`, without
constructing a buffer. Adapters can use it before async admission to preserve
their input-validation precedence without retaining a temporary buffer view.

## write2

`uv_write2` — **canonical exported function**

Queue a vector write and optionally transfer a native handle over an IPC pipe. The send handle is borrowed through completion; its original ownership is not transferred out of this process.

```titan
function write2(req: write_t, stream: stream_t, buffers: {buf_t}, send_handle: handle_t?, callback: write_cb?): integer
```

**Inputs and outputs:** req: INPUT/OUTPUT allocated nonpending request owner; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; stream: INPUT/OUTPUT initialized stream_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; buffers: INPUT byte owner or vector; immutable strings are valid only for input; async submission snapshots descriptors and retains owners, so Array edits cannot alter accepted I/O; do not mutate borrowed byte contents before completion.; send_handle: INPUT/OUTPUT initialized handle_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized stream; buffer owner is writable on reads and retained on async writes. Descriptor ownership follows concrete TCP/pipe/TTY open/init. Stop does not close. Like write, plus send_handle must be TCP or pipe and target IPC pipe. Retain transferred-handle owner through completion; ownership of native descriptor remains explicit. A closing transferred handle rejects before request registration/native entry. CREATE_PIPE policy: this operation consumes eligibility from its destination pipe stream when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md. A pipe used only as borrowed send_handle keeps its own eligibility.

**Callbacks:** deferred-once-on-success. the owning main Lua thread; timing is specified above

**Cancellation:** Native libuv supports write cancellation; Titan cancel returns EINVAL for write requests.

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L555).

## write_nwritten

`uv_write_nwritten` — **not exported**

Libuv 1.53.0 adds a byte count query valid only inside the native write callback.
Titan currently has no wrapper for it; `has_api("write_nwritten")` returns false.
Titan's `cancel` continues to reject write requests with `EINVAL`, so the native
write-cancellation and partial-progress APIs are not exposed through this binding.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L582).
