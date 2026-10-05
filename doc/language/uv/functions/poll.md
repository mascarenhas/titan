# poll API reference

Complete public example: [signal_poll_tty](../examples/signal_poll_tty.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

The signatures use ordinary public `titan.uv` types. Read the [ownership contracts](../CONTRACT-NOTES.md) before submitting native work. Status values and callback results remain distinct.

## poll_init

`uv_poll_init` — **canonical exported function**

Initialize readiness polling for a borrowed descriptor/socket. The poll owner does not own that descriptor. A native partial-init failure can still establish handle close ownership; check `as_handle_t():is_initialized()`.

```titan
function poll_init(loop: loop_t, handle: poll_t, file: integer): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; handle: INPUT/OUTPUT final poll_t owner in fresh or retired state, before this native initialization; successful initialization establishes a close obligation. Follow the explicit rejection rule for this operation.; file: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop and a concrete owner in fresh or retired state; an uninitialized loop or currently initialized/closing handle returns EINVAL. Successful initialization establishes the native lifetime and close obligation, even if no event is ever started. The file descriptor remains caller-owned: poll never closes it. Windows may return an error after native registration; use the fresh-owner is_initialized/close recipe in CONTRACT-NOTES.md. Such partial owners reject poll_start until closed and initialized again.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L933).


## poll_init_socket

`uv_poll_init_socket` — **canonical exported function**

Initialize readiness polling for a borrowed descriptor/socket. The poll owner does not own that descriptor. A native partial-init failure can still establish handle close ownership; check `as_handle_t():is_initialized()`.

```titan
function poll_init_socket(loop: loop_t, handle: poll_t, socket: os_sock_t): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; handle: INPUT/OUTPUT final poll_t owner in fresh or retired state, before this native initialization; successful initialization establishes a close obligation. Follow the explicit rejection rule for this operation.; socket: INPUT exact-width borrowed native identifier token; collecting the token never closes/adopts its resource; see this operation's transfer rule.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop and a concrete owner in fresh or retired state; an uninitialized loop or currently initialized/closing handle returns EINVAL. Successful initialization establishes the native lifetime and close obligation, even if no event is ever started. The exact-width socket token remains borrowed: poll never closes its resource. Windows may return an error after native registration; use the fresh-owner is_initialized/close recipe in CONTRACT-NOTES.md. Such partial owners reject poll_start until closed and initialized again.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L934).


## poll_start

`uv_poll_start` — **canonical exported function**

Watch the requested readiness bits and call `(owner, status, events)`. Readiness is permission to attempt nonblocking I/O, not a completed read/write.

```titan
function poll_start(handle: poll_t, callback: function (poll_t, integer, integer): (), events: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized poll_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return.; events: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Poll observes caller-owned fd/socket without taking close ownership; callback on loop thread; invalid descriptor and OS constraints return status. Events flags; status <0 is error. Descriptor is externally owned and must stay open; poll does not own/close it. Multiple poll handles on same fd unsafe; regular files not supported.

**Callbacks:** persistent-poll. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L937).


## poll_stop

`uv_poll_stop` — **canonical exported function**

Stop readiness notifications without closing the poll handle or its borrowed descriptor.

```titan
function poll_stop(handle: poll_t): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized poll_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Poll observes caller-owned fd/socket without taking close ownership; callback on loop thread; invalid descriptor and OS constraints return status.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L938).

