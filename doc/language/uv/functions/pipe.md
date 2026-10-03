# pipe API reference

Complete public example: [pipe_process](../examples/pipe_process.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

The signatures use ordinary public `titan.uv` types. Read the [ownership contracts](../CONTRACT-NOTES.md) before submitting native work. Status values and callback results remain distinct.

## pipe

`uv_pipe` — **canonical exported function**

Create an anonymous pipe and return `(status, read_fd, write_fd)`. On success the caller owns both descriptors; read/write flags configure their native behavior.

```titan
function pipe(read_flags: integer, write_flags: integer): (integer, integer, integer)
```

**Inputs and outputs:** read_flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; write_flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, integer, integer). Synchronous creation; no initialized pipe_t is needed. Success returns 0 and two owned file descriptors for the read and write ends; failure returns status and -1 descriptors. These are CRT file descriptors on Windows, not native HANDLE tokens. Transfer each descriptor to a handle or close it exactly once.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L513).


## pipe_bind

`uv_pipe_bind` — **canonical exported function**

Bind the pipe to a native name/path. Use `pipe_bind2` when explicit name length and binding flags are needed.

```titan
function pipe_bind(handle: pipe_t, name: string): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized pipe_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; name: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized pipe handle; IPC mode controls transfer. Name getters use caller writable storage plus in/out size; native name may contain NUL with bind2/connect2. CREATE_PIPE policy: this operation consumes eligibility from its pipe argument when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L877).


## pipe_bind2

`uv_pipe_bind2` — **canonical exported function**

Bind a pipe using exactly `namelen` name bytes and the supplied native flags; byte-count validation happens before native handoff.

```titan
function pipe_bind2(handle: pipe_t, name: string, namelen: integer, flags: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized pipe_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; name: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.; namelen: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized pipe handle; IPC mode controls transfer. Name getters use caller writable storage plus in/out size; native name may contain NUL with bind2/connect2. CREATE_PIPE policy: this operation consumes eligibility from its pipe argument when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L878).


## pipe_chmod

`uv_pipe_chmod` — **canonical exported function**

Change native named-pipe permissions using READABLE/WRITABLE flags; support is platform-specific.

```titan
function pipe_chmod(handle: pipe_t, flags: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized pipe_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized pipe handle; IPC mode controls transfer. Name getters use caller writable storage plus in/out size; native name may contain NUL with bind2/connect2. CREATE_PIPE policy: this operation consumes eligibility from its pipe argument when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L901).


## pipe_connect

`uv_pipe_connect` — **canonical exported function**

Start the legacy void-returning pipe connect. Errors are delivered through the callback; it has no integer submission status.

```titan
function pipe_connect(req: connect_t, handle: pipe_t, name: string, callback: connect_cb)
```

**Inputs and outputs:** req: INPUT/OUTPUT allocated nonpending request owner; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; handle: INPUT/OUTPUT initialized pipe_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; name: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return.

**Result, lifetime and cleanup:** Return type: (). Requires initialized pipe handle; IPC mode controls transfer. Name getters use caller writable storage plus in/out size; native name may contain NUL with bind2/connect2. Void submission API: connection failure delivered to callback; no invented immediate negative return. Retain request/pipe until callback; name copied by native as needed. CREATE_PIPE policy: this operation consumes eligibility from its connecting pipe when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md.

**Callbacks:** deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L882).


## pipe_connect2

`uv_pipe_connect2` — **canonical exported function**

Start a pipe connect with explicit name length and flags. A negative immediate result rejects submission; an accepted request completes through its callback.

```titan
function pipe_connect2(req: connect_t, handle: pipe_t, name: string, namelen: integer, flags: integer, callback: connect_cb): integer
```

**Inputs and outputs:** req: INPUT/OUTPUT allocated nonpending request owner; accepted submission retains owner until its terminal callback returns; rejection owes no async callback.; handle: INPUT/OUTPUT initialized pipe_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; name: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.; namelen: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized pipe handle; IPC mode controls transfer. Name getters use caller writable storage plus in/out size; native name may contain NUL with bind2/connect2. Negative immediate return promises no callback; zero accepted callback. name length permits embedded NUL on supported Unix abstract sockets; NO_TRUNCATE prevents truncation. CREATE_PIPE policy: this operation consumes eligibility from its connecting pipe when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md.

**Callbacks:** deferred-once-on-success. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L886).


## pipe_getpeername

`uv_pipe_getpeername` — **canonical exported function**

Copy the local/peer pipe name into a writable buffer. Return `(status, native_length)`; capacity and terminator rules remain explicit.

```titan
function pipe_getpeername(handle: pipe_t, buffer: buf_t): (integer, integer)
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized pipe_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; buffer: OUTPUT writable buf_t; its byte length is capacity and native writes complete synchronously

**Result, lifetime and cleanup:** Return type: (integer, integer). Requires a live pipe handle and writable buf_t. Its length supplies native capacity; the function synchronously writes the name bytes and returns status plus native actual/required size. Names may contain NUL bytes; obtain a copied string with to_string using the successful size. No asynchronous borrow remains.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L895).


## pipe_getsockname

`uv_pipe_getsockname` — **canonical exported function**

Copy the local/peer pipe name into a writable buffer. Return `(status, native_length)`; capacity and terminator rules remain explicit.

```titan
function pipe_getsockname(handle: pipe_t, buffer: buf_t): (integer, integer)
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized pipe_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; buffer: OUTPUT writable buf_t; its byte length is capacity and native writes complete synchronously

**Result, lifetime and cleanup:** Return type: (integer, integer). Requires a live pipe handle and writable buf_t. Its length supplies native capacity; the function synchronously writes the name bytes and returns status plus native actual/required size. Names may contain NUL bytes; obtain a copied string with to_string using the successful size. No asynchronous borrow remains.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L892).


## pipe_init

`uv_pipe_init` — **canonical exported function**

Initialize a pipe owner on a loop; nonzero `ipc` permits native handle transfer. Successful init also begins its CREATE_PIPE eligibility lifetime.

```titan
function pipe_init(loop: loop_t, handle: pipe_t, ipc: integer): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; handle: INPUT/OUTPUT final pipe_t owner in fresh or retired state, before this native initialization; successful initialization establishes a close obligation. Follow the explicit rejection rule for this operation.; ipc: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop and a concrete owner in fresh or retired state; an uninitialized loop or currently initialized/closing handle returns EINVAL. Successful initialization establishes the native lifetime and close obligation, even if no event is ever started. ipc is the native integer IPC mode. Initialization does not open a pipe descriptor; pipe_open or another operation establishes it separately. A rejected initialization establishes no new native lifetime. Successful initialization starts a CREATE_PIPE-eligible pipe lifetime. Native I/O operations listed in PROCESS-POLICY.md consume that eligibility at native handoff; queries/views/data/ref/unref/buffer-size operations and borrowed-source uses do not. Close retirement ends it; a later successful pipe_init starts another eligible lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L875).


## pipe_open

`uv_pipe_open` — **canonical exported function**

Adopt a descriptor into the pipe. Successful adoption gives the pipe its close obligation; native handoff consumes CREATE_PIPE eligibility.

```titan
function pipe_open(handle: pipe_t, file: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized pipe_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; file: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized pipe handle; IPC mode controls transfer. Name getters use caller writable storage plus in/out size; native name may contain NUL with bind2/connect2. CREATE_PIPE policy: this operation consumes eligibility from its pipe argument when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L876).


## pipe_pending_count

`uv_pipe_pending_count` — **canonical exported function**

Return how many native handles are pending receipt on an IPC pipe.

```titan
function pipe_pending_count(handle: pipe_t): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized pipe_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized pipe handle; IPC mode controls transfer. Name getters use caller writable storage plus in/out size; native name may contain NUL with bind2/connect2.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L899).


## pipe_pending_instances

`uv_pipe_pending_instances` — **canonical exported function**

Set the number of pending pipe instances used by the native listener where supported.

```titan
function pipe_pending_instances(handle: pipe_t, count: integer)
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized pipe_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; count: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (). Requires initialized pipe handle; IPC mode controls transfer. Name getters use caller writable storage plus in/out size; native name may contain NUL with bind2/connect2. CREATE_PIPE policy: this operation consumes eligibility from its pipe argument when binding validation completes and the native operation is attempted. A native error or no-op does not restore eligibility; a binding preflight failure leaves it unchanged. See PROCESS-POLICY.md.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L898).


## pipe_pending_type

`uv_pipe_pending_type` — **canonical exported function**

Return the type of the next native handle pending receipt on an IPC pipe; initialize a compatible owner before accepting it.

```titan
function pipe_pending_type(handle: pipe_t): handle_type
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized pipe_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: handle_type. Requires initialized pipe handle; IPC mode controls transfer. Name getters use caller writable storage plus in/out size; native name may contain NUL with bind2/connect2.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L900).

